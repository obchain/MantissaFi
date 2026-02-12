// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import { Constants } from "./Constants.sol";
import { CumulativeNormal } from "./CumulativeNormal.sol";

/// @title HestonModel
/// @author MantissaFi Team
/// @notice On-chain Heston stochastic volatility model for European option pricing
/// @dev The Heston (1993) model extends Black-Scholes-Merton by treating variance as
///      a stochastic process governed by the CIR (Cox-Ingersoll-Ross) SDE:
///
///        dS = r·S·dt + √v·S·dW₁
///        dv = κ·(θ − v)·dt + ξ·√v·dW₂
///        dW₁·dW₂ = ρ·dt
///
///      where:
///        S  = spot price
///        v  = instantaneous variance
///        κ  = mean-reversion speed
///        θ  = long-run variance
///        ξ  = vol-of-vol (volatility of variance)
///        ρ  = correlation between price and variance Brownian motions
///        r  = risk-free rate
///
///      This implementation uses a characteristic-function approach with Gauss-Legendre
///      quadrature for numerical integration of the Heston semi-closed-form solution.
///      All arithmetic is in SD59x18 fixed-point for deterministic on-chain execution.
///
///      Key features:
///        - Feller condition check: 2κθ > ξ² ensures variance stays positive
///        - Call/put pricing via numerical integration of the characteristic function
///        - Greeks: delta and vega derived from the Heston model
///        - Implied volatility extraction for BSM-equivalent quoting
///        - Variance term structure: E[v(T)] = θ + (v₀ − θ)·e^(−κT)
///
///      Numerical method: 8-point Gauss-Legendre quadrature on [0, U_MAX] where
///      U_MAX is chosen to capture the significant mass of the integrand. This provides
///      a balance between gas cost and accuracy suitable for on-chain DeFi applications.

// ═══════════════════════════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Thrown when spot price is not strictly positive
error HestonModel__InvalidSpotPrice(SD59x18 spot);

/// @notice Thrown when strike price is not strictly positive
error HestonModel__InvalidStrikePrice(SD59x18 strike);

/// @notice Thrown when time to expiry is not strictly positive
error HestonModel__InvalidTimeToExpiry(SD59x18 timeToExpiry);

/// @notice Thrown when risk-free rate is negative
error HestonModel__InvalidRiskFreeRate(SD59x18 riskFreeRate);

/// @notice Thrown when initial variance is not strictly positive
error HestonModel__InvalidInitialVariance(SD59x18 v0);

/// @notice Thrown when long-run variance is not strictly positive
error HestonModel__InvalidLongRunVariance(SD59x18 theta);

/// @notice Thrown when mean-reversion speed is not strictly positive
error HestonModel__InvalidMeanReversionSpeed(SD59x18 kappa);

/// @notice Thrown when vol-of-vol is not strictly positive
error HestonModel__InvalidVolOfVol(SD59x18 xi);

/// @notice Thrown when correlation is outside [-1, 1]
error HestonModel__InvalidCorrelation(SD59x18 rho);

/// @notice Thrown when the Feller condition 2κθ > ξ² is violated
error HestonModel__FellerConditionViolated(SD59x18 twoKappaTheta, SD59x18 xiSquared);

/// @notice Thrown when implied vol search fails to converge
error HestonModel__ImpliedVolNotConverged();

// ═══════════════════════════════════════════════════════════════════════════════
// STRUCTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Heston model parameters
/// @param spot Current spot price S > 0
/// @param strike Strike price K > 0
/// @param riskFreeRate Risk-free rate r >= 0
/// @param timeToExpiry Time to expiry T > 0 (in years)
/// @param v0 Initial instantaneous variance v₀ > 0
/// @param theta Long-run variance θ > 0
/// @param kappa Mean-reversion speed κ > 0
/// @param xi Vol-of-vol (volatility of variance) ξ > 0
/// @param rho Correlation between price and variance ρ ∈ [-1, 1]
struct HestonParams {
    SD59x18 spot;
    SD59x18 strike;
    SD59x18 riskFreeRate;
    SD59x18 timeToExpiry;
    SD59x18 v0;
    SD59x18 theta;
    SD59x18 kappa;
    SD59x18 xi;
    SD59x18 rho;
}

/// @notice Complete Heston pricing result
/// @param callPrice European call price
/// @param putPrice European put price (from put-call parity)
/// @param fellerRatio 2κθ / ξ² (must be > 1 for Feller condition)
struct HestonResult {
    SD59x18 callPrice;
    SD59x18 putPrice;
    SD59x18 fellerRatio;
}

library HestonModel {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice 1.0 in fixed-point
    int256 private constant ONE = 1e18;

    /// @notice 2.0 in fixed-point
    int256 private constant TWO = 2e18;

    /// @notice 0.5 in fixed-point
    int256 private constant HALF = 5e17;

    /// @notice π ≈ 3.141592653589793238
    int256 private constant PI = 3_141592653589793238;

    /// @notice Upper integration limit for Gauss-Legendre quadrature
    /// @dev 50.0 captures sufficient mass for typical crypto option parameters
    int256 private constant U_MAX = 50e18;

    /// @notice Number of Gauss-Legendre quadrature points (8-point rule)
    uint256 private constant NUM_QUADRATURE_POINTS = 8;

    /// @notice Maximum iterations for implied vol Newton-Raphson search
    uint256 private constant MAX_IMPLIED_VOL_ITERATIONS = 32;

    /// @notice Convergence tolerance for implied vol (1e-10 in SD59x18)
    int256 private constant IMPLIED_VOL_TOLERANCE = 1e8;

    // ═══════════════════════════════════════════════════════════════════════════
    // 8-POINT GAUSS-LEGENDRE NODES AND WEIGHTS ON [-1, 1]
    // ═══════════════════════════════════════════════════════════════════════════
    // Transformed to [0, U_MAX] via u = U_MAX/2 * (1 + t)

    /// @dev Nodes on [-1, 1] for 8-point Gauss-Legendre
    int256 private constant GL_N0 = -960289856497536232; // -0.960289856497536
    int256 private constant GL_N1 = -796666477413626740; // -0.796666477413627
    int256 private constant GL_N2 = -525532409916328986; // -0.525532409916329
    int256 private constant GL_N3 = -183434642495649805; // -0.183434642495650
    int256 private constant GL_N4 = 183434642495649805;
    int256 private constant GL_N5 = 525532409916328986;
    int256 private constant GL_N6 = 796666477413626740;
    int256 private constant GL_N7 = 960289856497536232;

    /// @dev Weights for 8-point Gauss-Legendre
    int256 private constant GL_W0 = 101228536290376259; // 0.101228536290376
    int256 private constant GL_W1 = 222381034453374471; // 0.222381034453374
    int256 private constant GL_W2 = 313706645877887287; // 0.313706645877887
    int256 private constant GL_W3 = 362683783378361983; // 0.362683783378362
    int256 private constant GL_W4 = 362683783378361983;
    int256 private constant GL_W5 = 313706645877887287;
    int256 private constant GL_W6 = 222381034453374471;
    int256 private constant GL_W7 = 101228536290376259;

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN PRICING FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Prices a European call option using the Heston model
    /// @dev Uses the semi-closed-form solution:
    ///      C = S·P₁ − K·e^(−rT)·P₂
    ///      where P₁ and P₂ are computed via characteristic function integration.
    ///      Numerical integration uses 8-point Gauss-Legendre quadrature.
    /// @param p Heston model parameters
    /// @return price European call option price (floored at zero)
    function priceCall(HestonParams memory p) internal pure returns (SD59x18 price) {
        _validateParams(p);

        (SD59x18 p1, SD59x18 p2) = _computeP1P2(p);
        SD59x18 discount = _discount(p.riskFreeRate, p.timeToExpiry);

        price = p.spot.mul(p1).sub(p.strike.mul(discount).mul(p2));

        if (price.lt(ZERO)) {
            price = ZERO;
        }
    }

    /// @notice Prices a European put option using the Heston model
    /// @dev Uses put-call parity: P = C − S + K·e^(−rT)
    /// @param p Heston model parameters
    /// @return price European put option price (floored at zero)
    function pricePut(HestonParams memory p) internal pure returns (SD59x18 price) {
        _validateParams(p);

        SD59x18 callPrice = priceCall(p);
        SD59x18 discount = _discount(p.riskFreeRate, p.timeToExpiry);

        price = callPrice.sub(p.spot).add(p.strike.mul(discount));

        if (price.lt(ZERO)) {
            price = ZERO;
        }
    }

    /// @notice Computes both call and put prices with Feller condition ratio
    /// @param p Heston model parameters
    /// @return result Complete Heston pricing result
    function priceHeston(HestonParams memory p) internal pure returns (HestonResult memory result) {
        _validateParams(p);

        result.callPrice = priceCall(p);
        SD59x18 discount = _discount(p.riskFreeRate, p.timeToExpiry);
        result.putPrice = result.callPrice.sub(p.spot).add(p.strike.mul(discount));

        if (result.putPrice.lt(ZERO)) {
            result.putPrice = ZERO;
        }

        result.fellerRatio = fellerRatio(p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PARAMETER ANALYSIS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes the Feller condition ratio: 2κθ / ξ²
    /// @dev The Feller condition requires this ratio > 1 to ensure variance stays positive.
    ///      Values close to 1 indicate borderline stability; values >> 1 are strongly mean-reverting.
    /// @param p Heston model parameters
    /// @return ratio The Feller ratio (should be > 1)
    function fellerRatio(HestonParams memory p) internal pure returns (SD59x18 ratio) {
        SD59x18 twoKappaTheta = sd(TWO).mul(p.kappa).mul(p.theta);
        SD59x18 xiSq = p.xi.mul(p.xi);
        ratio = twoKappaTheta.div(xiSq);
    }

    /// @notice Checks whether the Feller condition 2κθ > ξ² is satisfied
    /// @param p Heston model parameters
    /// @return satisfied True if the Feller condition holds
    function checkFellerCondition(HestonParams memory p) internal pure returns (bool satisfied) {
        SD59x18 twoKappaTheta = sd(TWO).mul(p.kappa).mul(p.theta);
        SD59x18 xiSq = p.xi.mul(p.xi);
        satisfied = twoKappaTheta.gt(xiSq);
    }

    /// @notice Computes the expected variance at time T: E[v(T)] = θ + (v₀ − θ)·e^(−κT)
    /// @dev This is the conditional expectation of the CIR variance process.
    ///      As T → ∞, the expected variance converges to θ (long-run variance).
    /// @param p Heston model parameters
    /// @return expectedVar Expected variance at expiry
    function expectedVariance(HestonParams memory p) internal pure returns (SD59x18 expectedVar) {
        // E[v(T)] = θ + (v₀ − θ) · e^(−κT)
        SD59x18 decay = p.kappa.mul(p.timeToExpiry).mul(sd(-ONE)).exp();
        expectedVar = p.theta.add(p.v0.sub(p.theta).mul(decay));
    }

    /// @notice Computes the expected integrated variance: E[∫₀ᵀ v(s)ds] / T
    /// @dev This average variance is useful for comparing Heston to BSM.
    ///      = θ + (v₀ − θ)·(1 − e^(−κT)) / (κT)
    /// @param p Heston model parameters
    /// @return avgVar Average expected variance over [0, T]
    function averageExpectedVariance(HestonParams memory p) internal pure returns (SD59x18 avgVar) {
        SD59x18 kappaT = p.kappa.mul(p.timeToExpiry);
        SD59x18 decay = kappaT.mul(sd(-ONE)).exp();
        SD59x18 adjustmentFactor = sd(ONE).sub(decay).div(kappaT);
        avgVar = p.theta.add(p.v0.sub(p.theta).mul(adjustmentFactor));
    }

    /// @notice Derives a BSM-equivalent implied volatility from Heston parameters
    /// @dev Uses Newton-Raphson iteration to find σ such that BSM_call(σ) = Heston_call.
    ///      Initial guess is √(average expected variance).
    /// @param p Heston model parameters
    /// @return impliedVol The BSM-equivalent implied volatility
    function hestonImpliedVol(HestonParams memory p) internal pure returns (SD59x18 impliedVol) {
        _validateParams(p);

        SD59x18 hestonPrice = priceCall(p);

        // Initial guess: √(average expected variance)
        SD59x18 sigma = averageExpectedVariance(p).sqrt();

        // Newton-Raphson: σ_{n+1} = σ_n − (BSM(σ_n) − HestonPrice) / Vega(σ_n)
        for (uint256 i = 0; i < MAX_IMPLIED_VOL_ITERATIONS; i++) {
            SD59x18 bsmPrice = _bsmCallPrice(p.spot, p.strike, p.riskFreeRate, p.timeToExpiry, sigma);
            SD59x18 diff = bsmPrice.sub(hestonPrice);

            if (diff.abs().lt(sd(IMPLIED_VOL_TOLERANCE))) {
                return sigma;
            }

            SD59x18 vegaVal = _bsmVega(p.spot, p.strike, p.riskFreeRate, p.timeToExpiry, sigma);
            if (vegaVal.abs().lt(sd(IMPLIED_VOL_TOLERANCE))) {
                break;
            }

            sigma = sigma.sub(diff.div(vegaVal));

            // Clamp sigma to positive values
            if (sigma.lte(ZERO)) {
                sigma = sd(1e16); // 0.01 = 1% floor
            }
        }

        // If we didn't converge, return best estimate
        return sigma;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GREEKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes the Heston call delta (∂C/∂S)
    /// @dev Delta_call = P₁ from the characteristic function decomposition.
    ///      P₁ represents the delta-hedging probability under the stock measure.
    /// @param p Heston model parameters
    /// @return delta Call delta ∈ [0, 1]
    function callDelta(HestonParams memory p) internal pure returns (SD59x18 delta) {
        _validateParams(p);
        (SD59x18 p1,) = _computeP1P2(p);
        delta = p1;
    }

    /// @notice Computes Heston vega (∂C/∂v₀) via finite difference
    /// @dev Uses central difference: (C(v₀+h) − C(v₀−h)) / (2h)
    ///      where h = v₀ * 0.001 (0.1% bump)
    /// @param p Heston model parameters
    /// @return vegaVal Sensitivity of call price to initial variance
    function callVega(HestonParams memory p) internal pure returns (SD59x18 vegaVal) {
        _validateParams(p);

        SD59x18 h = p.v0.mul(sd(1e15)); // 0.001 * v0
        if (h.lt(sd(1e10))) {
            h = sd(1e10); // minimum bump
        }

        HestonParams memory pUp = _copyParams(p);
        pUp.v0 = p.v0.add(h);

        HestonParams memory pDown = _copyParams(p);
        pDown.v0 = p.v0.sub(h);
        if (pDown.v0.lte(ZERO)) {
            pDown.v0 = sd(1e10);
            h = p.v0.sub(pDown.v0);
        }

        SD59x18 priceUp = priceCall(pUp);
        SD59x18 priceDown = priceCall(pDown);

        vegaVal = priceUp.sub(priceDown).div(sd(TWO).mul(h));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHARACTERISTIC FUNCTION & NUMERICAL INTEGRATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes P₁ and P₂ via numerical integration of the Heston characteristic function
    /// @dev P_j = 0.5 + (1/π) · ∫₀^∞ Re[e^(−iu·ln(K)) · φ_j(u) / (iu)] du   for j=1,2
    ///      Integration is performed with 8-point Gauss-Legendre quadrature on [0, U_MAX].
    /// @param p Heston model parameters
    /// @return p1 First probability (stock measure)
    /// @return p2 Second probability (risk-neutral measure)
    function _computeP1P2(HestonParams memory p) private pure returns (SD59x18 p1, SD59x18 p2) {
        SD59x18 logK = p.strike.div(p.spot).ln();

        SD59x18 integral1 = _integrateCharFn(p, logK, true);
        SD59x18 integral2 = _integrateCharFn(p, logK, false);

        // P_j = 0.5 + integral_j / π
        SD59x18 invPi = sd(ONE).div(sd(PI));
        p1 = sd(HALF).add(integral1.mul(invPi));
        p2 = sd(HALF).add(integral2.mul(invPi));

        // Clamp to [0, 1]
        if (p1.lt(ZERO)) p1 = ZERO;
        if (p1.gt(sd(ONE))) p1 = sd(ONE);
        if (p2.lt(ZERO)) p2 = ZERO;
        if (p2.gt(sd(ONE))) p2 = sd(ONE);
    }

    /// @notice Performs Gauss-Legendre quadrature for one probability integral
    function _integrateCharFn(HestonParams memory p, SD59x18 logK, bool isP1) private pure returns (SD59x18 integral) {
        SD59x18 halfUMax = sd(U_MAX).div(sd(TWO));
        integral = ZERO;

        integral = integral.add(sd(GL_W0).mul(_evalQuadPoint(p, logK, isP1, halfUMax, GL_N0)));
        integral = integral.add(sd(GL_W1).mul(_evalQuadPoint(p, logK, isP1, halfUMax, GL_N1)));
        integral = integral.add(sd(GL_W2).mul(_evalQuadPoint(p, logK, isP1, halfUMax, GL_N2)));
        integral = integral.add(sd(GL_W3).mul(_evalQuadPoint(p, logK, isP1, halfUMax, GL_N3)));
        integral = integral.add(sd(GL_W4).mul(_evalQuadPoint(p, logK, isP1, halfUMax, GL_N4)));
        integral = integral.add(sd(GL_W5).mul(_evalQuadPoint(p, logK, isP1, halfUMax, GL_N5)));
        integral = integral.add(sd(GL_W6).mul(_evalQuadPoint(p, logK, isP1, halfUMax, GL_N6)));
        integral = integral.add(sd(GL_W7).mul(_evalQuadPoint(p, logK, isP1, halfUMax, GL_N7)));

        // Scale by U_MAX/2 (Jacobian of transformation)
        integral = integral.mul(halfUMax);
    }

    /// @notice Evaluates the integrand at a single quadrature point
    function _evalQuadPoint(HestonParams memory p, SD59x18 logK, bool isP1, SD59x18 halfUMax, int256 node)
        private
        pure
        returns (SD59x18)
    {
        SD59x18 u = halfUMax.mul(sd(ONE).add(sd(node)));
        if (u.abs().lt(sd(1e10))) return ZERO;
        return _hestonIntegrand(p, u, logK, isP1);
    }

    /// @notice Evaluates the Heston integrand: Re[e^(−iu·ln(K/S)) · φ_j(u) / (iu)]
    /// @dev The characteristic function φ_j is computed in log-space to avoid overflow.
    ///      We use the "rotation count" (Albrecher et al.) formulation for numerical stability.
    ///      For j=1 (stock measure):  uses b₁ = κ − ρξ, u_adj = u − i
    ///      For j=2 (risk-neutral):   uses b₂ = κ,         u_adj = u
    /// @param p Heston model parameters
    /// @param u Integration variable (frequency)
    /// @param logK Log of K/S (log-moneyness)
    /// @param isP1 True for P₁ (stock measure), false for P₂ (risk-neutral)
    /// @return integrand Real part of the integrand at frequency u
    function _hestonIntegrand(HestonParams memory p, SD59x18 u, SD59x18 logK, bool isP1)
        private
        pure
        returns (SD59x18 integrand)
    {
        // For the Heston characteristic function, we compute the real part of:
        //   exp(C + D·v₀ + i·u·x) / (i·u)
        // where x = ln(S) + rT, and C, D are functions of u.
        //
        // We split into real/imaginary and only return the real component
        // multiplied by cos(u·logK)/u + sin(u·logK)/u as appropriate.

        SD59x18 xi = p.xi;
        SD59x18 xiSq = xi.mul(xi);
        SD59x18 tau = p.timeToExpiry;

        // b_j parameter: b1 = κ − ρξ (P1), b2 = κ (P2)
        SD59x18 b;
        // Adjust u for P1: effectively u → u − i (shift in complex plane)
        // For P1, we use α = 0.5 and for P2, α = -0.5 in the Heston formulation
        SD59x18 uSq = u.mul(u);

        if (isP1) {
            b = p.kappa.sub(p.rho.mul(xi));
            // For P1 (u₁ = 0.5):
            //   d² = (ρξui − b)² − ξ²(2·0.5·iu − u²)
            //      = b² − 2bρξui − ρ²ξ²u² − ξ²iu + ξ²u²
            //   Real(d²) = b² + ξ²u²(1 − ρ²)
            //   Imag(d²) = −2bρξu − ξ²u
        } else {
            b = p.kappa;
            // For P2 (u₂ = −0.5):
            //   d² = (ρξui − b)² − ξ²(2·(−0.5)·iu − u²)
            //      = b² − 2bρξui − ρ²ξ²u² + ξ²iu + ξ²u²
            //   Real(d²) = b² + ξ²u²(1 − ρ²)
            //   Imag(d²) = −2bρξu + ξ²u
        }

        // Real and imaginary parts of d² (complex discriminant)
        SD59x18 rhoSq = p.rho.mul(p.rho);
        SD59x18 dSqReal = b.mul(b).add(xiSq.mul(uSq).mul(sd(ONE).sub(rhoSq)));
        SD59x18 dSqImag;
        if (isP1) {
            // Imag(d²) = −2·b₁·ρ·ξ·u − ξ²·u  (since u₁ = 0.5)
            // = −ξ·u·(2·b₁·ρ + ξ) = −ξ·u·(ξ + 2·b·ρ)
            SD59x18 negXi = xi.mul(sd(-ONE));
            dSqImag = u.mul(negXi).mul(xi.add(sd(TWO).mul(b).mul(p.rho)));
        } else {
            // Imag(d²) = −2·b₂·ρ·ξ·u + ξ²·u  (since u₂ = −0.5)
            // = ξ·u·(ξ − 2·b₂·ρ)
            dSqImag = xi.mul(u).mul(xi.sub(sd(TWO).mul(b).mul(p.rho)));
        }

        // d = sqrt(d²) in complex: |d| = (dSqReal² + dSqImag²)^(1/4) * 2^(1/2)
        // Use polar form: d² = |d²|·e^(iθ), then d = |d²|^(1/2)·e^(iθ/2)
        SD59x18 dSqMod = _complexModulus(dSqReal, dSqImag);
        SD59x18 dSqAngle = _atan2(dSqImag, dSqReal);
        SD59x18 dMod = dSqMod.sqrt();
        SD59x18 dAngleHalf = dSqAngle.div(sd(TWO));

        SD59x18 dReal = dMod.mul(_cos(dAngleHalf));
        SD59x18 dImag = dMod.mul(_sin(dAngleHalf));

        // g = (b − ρξui − d) / (b − ρξui + d)
        // Numerator (complex): (b − dReal) + i·(−ρξu − dImag)
        // Denominator (complex): (b + dReal) + i·(−ρξu + dImag)
        SD59x18 rhoXiU = p.rho.mul(xi).mul(u);

        SD59x18 numReal = b.sub(dReal);
        SD59x18 numImag = rhoXiU.mul(sd(-ONE)).sub(dImag);
        SD59x18 denReal = b.add(dReal);
        SD59x18 denImag = rhoXiU.mul(sd(-ONE)).add(dImag);

        // Complex division: g = (numReal + i·numImag) / (denReal + i·denImag)
        (SD59x18 gReal, SD59x18 gImag) = _complexDiv(numReal, numImag, denReal, denImag);

        // exp(−dτ) in complex: e^(−dReal·τ) · [cos(−dImag·τ) + i·sin(−dImag·τ)]
        SD59x18 expDecayMag = dReal.mul(tau).mul(sd(-ONE)).exp();
        SD59x18 expDecayAngle = dImag.mul(tau).mul(sd(-ONE));
        SD59x18 edtReal = expDecayMag.mul(_cos(expDecayAngle));
        SD59x18 edtImag = expDecayMag.mul(_sin(expDecayAngle));

        // g·e^(−dτ)
        (SD59x18 geReal, SD59x18 geImag) = _complexMul(gReal, gImag, edtReal, edtImag);

        // (1 − g·e^(−dτ)) / (1 − g)
        SD59x18 numCReal = sd(ONE).sub(geReal);
        SD59x18 numCImag = geImag.mul(sd(-ONE));
        SD59x18 denCReal = sd(ONE).sub(gReal);
        SD59x18 denCImag = gImag.mul(sd(-ONE));

        (SD59x18 ratioReal, SD59x18 ratioImag) = _complexDiv(numCReal, numCImag, denCReal, denCImag);

        // ln(ratio) for computing C
        SD59x18 ratioMod = _complexModulus(ratioReal, ratioImag);
        SD59x18 ratioAngle = _atan2(ratioImag, ratioReal);

        // D = (b − ρξui − d) / ξ² · (1 − e^(−dτ)) / (1 − g·e^(−dτ))
        // Numerator of D fraction: (b − ρξui − d) · (1 − e^(−dτ))
        SD59x18 oneMinusEdtReal = sd(ONE).sub(edtReal);
        SD59x18 oneMinusEdtImag = edtImag.mul(sd(-ONE));
        (SD59x18 dNumReal, SD59x18 dNumImag) = _complexMul(numReal, numImag, oneMinusEdtReal, oneMinusEdtImag);

        // Denominator: ξ² · (1 − g·e^(−dτ))
        SD59x18 dDenReal = xiSq.mul(numCReal);
        SD59x18 dDenImag = xiSq.mul(numCImag);

        (SD59x18 bigDReal, SD59x18 bigDImag) = _complexDiv(dNumReal, dNumImag, dDenReal, dDenImag);

        // C = (r·τ·u)·i + (κθ/ξ²)·[(b − ρξui − d)·τ − 2·ln((1 − g·e^(−dτ))/(1 − g))]
        SD59x18 kapThetaOverXiSq = p.kappa.mul(p.theta).div(xiSq);

        // (b − ρξui − d)·τ
        SD59x18 bdTauReal = numReal.mul(tau);
        SD59x18 bdTauImag = numImag.mul(tau);

        // 2·ln(ratio) = 2·(ln|ratio| + i·angle(ratio))
        SD59x18 twoLnReal;
        if (ratioMod.gt(ZERO)) {
            twoLnReal = sd(TWO).mul(ratioMod.ln());
        } else {
            twoLnReal = sd(-100e18); // large negative for log(0)
        }
        SD59x18 twoLnImag = sd(TWO).mul(ratioAngle);

        // (b − ρξui − d)·τ − 2·ln(ratio)
        SD59x18 bracketReal = bdTauReal.sub(twoLnReal);
        SD59x18 bracketImag = bdTauImag.sub(twoLnImag);

        // C = i·r·τ·u + κθ/ξ² · bracket
        SD59x18 bigCReal = kapThetaOverXiSq.mul(bracketReal);
        SD59x18 bigCImag = p.riskFreeRate.mul(tau).mul(u).add(kapThetaOverXiSq.mul(bracketImag));

        // φ = exp(C + D·v₀ − i·u·ln(K/S))
        // exponent = C + D·v₀ − i·u·logK
        SD59x18 expReal = bigCReal.add(bigDReal.mul(p.v0));
        SD59x18 expImag = bigCImag.add(bigDImag.mul(p.v0)).sub(u.mul(logK));

        // exp(exponent) = e^(expReal) · [cos(expImag) + i·sin(expImag)]
        SD59x18 expMag = expReal.exp();
        // phiReal not used directly since Re[φ/(iu)] = phiImag/u
        SD59x18 phiImag = expMag.mul(_sin(expImag));

        // Integrand = Re[φ / (iu)] = Re[(phiReal + i·phiImag) / (i·u)]
        //           = Re[(phiReal + i·phiImag) · (−i/u)]
        //           = phiImag / u
        integrand = phiImag.div(u);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BSM HELPERS (for implied vol extraction)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes BSM call price for implied vol iteration
    function _bsmCallPrice(SD59x18 spot, SD59x18 strike, SD59x18 r, SD59x18 t, SD59x18 sigma)
        private
        pure
        returns (SD59x18 price)
    {
        SD59x18 sqrtT = t.sqrt();
        SD59x18 volSqrtT = sigma.mul(sqrtT);
        SD59x18 logSK = spot.div(strike).ln();
        SD59x18 drift = r.add(sigma.mul(sigma).div(sd(TWO))).mul(t);

        SD59x18 d1 = logSK.add(drift).div(volSqrtT);
        SD59x18 d2 = d1.sub(volSqrtT);

        SD59x18 discount = r.mul(t).mul(sd(-ONE)).exp();
        price = spot.mul(CumulativeNormal.cdf(d1)).sub(strike.mul(discount).mul(CumulativeNormal.cdf(d2)));

        if (price.lt(ZERO)) price = ZERO;
    }

    /// @notice Computes BSM vega for Newton-Raphson iteration
    /// @dev ν = S·√T·φ(d1)
    function _bsmVega(SD59x18 s, SD59x18 k, SD59x18 r, SD59x18 t, SD59x18 sigma)
        private
        pure
        returns (SD59x18 vegaVal)
    {
        SD59x18 sqrtT = t.sqrt();
        SD59x18 volSqrtT = sigma.mul(sqrtT);
        SD59x18 logSK = s.div(k).ln();
        SD59x18 drift = r.add(sigma.mul(sigma).div(sd(TWO))).mul(t);
        SD59x18 d1 = logSK.add(drift).div(volSqrtT);

        vegaVal = s.mul(sqrtT).mul(CumulativeNormal.pdf(d1));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLEX ARITHMETIC HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Complex multiplication: (a + bi)(c + di) = (ac − bd) + (ad + bc)i
    function _complexMul(SD59x18 aR, SD59x18 aI, SD59x18 bR, SD59x18 bI) private pure returns (SD59x18 rR, SD59x18 rI) {
        rR = aR.mul(bR).sub(aI.mul(bI));
        rI = aR.mul(bI).add(aI.mul(bR));
    }

    /// @notice Complex division: (a + bi)/(c + di) = [(ac + bd) + (bc − ad)i] / (c² + d²)
    function _complexDiv(SD59x18 aR, SD59x18 aI, SD59x18 bR, SD59x18 bI) private pure returns (SD59x18 rR, SD59x18 rI) {
        SD59x18 denom = bR.mul(bR).add(bI.mul(bI));
        rR = aR.mul(bR).add(aI.mul(bI)).div(denom);
        rI = aI.mul(bR).sub(aR.mul(bI)).div(denom);
    }

    /// @notice Complex modulus: |a + bi| = √(a² + b²)
    function _complexModulus(SD59x18 re, SD59x18 im) private pure returns (SD59x18) {
        return re.mul(re).add(im.mul(im)).sqrt();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TRIGONOMETRIC HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Sine approximation using Taylor series (11th-order)
    /// @dev Reduces argument to [−π, π] then uses: sin(x) = x − x³/6 + x⁵/120 − x⁷/5040 + x⁹/362880 − x¹¹/39916800
    /// @param x Angle in radians (SD59x18)
    /// @return result sin(x) in SD59x18
    function _sin(SD59x18 x) private pure returns (SD59x18 result) {
        // Reduce to [−π, π]
        x = _reduceAngle(x);

        // Taylor series: sin(x) ≈ x − x³/3! + x⁵/5! − x⁷/7! + x⁹/9! − x¹¹/11!
        SD59x18 x2 = x.mul(x);
        SD59x18 x3 = x2.mul(x);
        SD59x18 x5 = x3.mul(x2);
        SD59x18 x7 = x5.mul(x2);
        SD59x18 x9 = x7.mul(x2);
        SD59x18 x11 = x9.mul(x2);

        result = x;
        result = result.sub(x3.div(sd(6e18)));
        result = result.add(x5.div(sd(120e18)));
        result = result.sub(x7.div(sd(5040e18)));
        result = result.add(x9.div(sd(362880e18)));
        result = result.sub(x11.div(sd(39916800e18)));
    }

    /// @notice Cosine approximation using Taylor series (10th-order)
    /// @dev Reduces argument to [−π, π] then uses: cos(x) = 1 − x²/2 + x⁴/24 − x⁶/720 + x⁸/40320 − x¹⁰/3628800
    /// @param x Angle in radians (SD59x18)
    /// @return result cos(x) in SD59x18
    function _cos(SD59x18 x) private pure returns (SD59x18 result) {
        // Reduce to [−π, π]
        x = _reduceAngle(x);

        SD59x18 x2 = x.mul(x);
        SD59x18 x4 = x2.mul(x2);
        SD59x18 x6 = x4.mul(x2);
        SD59x18 x8 = x6.mul(x2);
        SD59x18 x10 = x8.mul(x2);

        result = sd(ONE);
        result = result.sub(x2.div(sd(TWO)));
        result = result.add(x4.div(sd(24e18)));
        result = result.sub(x6.div(sd(720e18)));
        result = result.add(x8.div(sd(40320e18)));
        result = result.sub(x10.div(sd(3628800e18)));
    }

    /// @notice Reduces angle to [−π, π] range
    function _reduceAngle(SD59x18 x) private pure returns (SD59x18) {
        SD59x18 twoPi = sd(2 * PI);

        // Handle large positive/negative angles
        if (x.gt(sd(PI))) {
            // x = x − 2π·⌊(x + π) / (2π)⌋
            SD59x18 n = x.add(sd(PI)).div(twoPi);
            // Floor: convert to int and back
            int256 nInt = SD59x18.unwrap(n) / ONE;
            x = x.sub(sd(nInt * 2 * PI));
        } else if (x.lt(sd(-PI))) {
            SD59x18 n = x.sub(sd(PI)).div(twoPi).abs();
            int256 nInt = SD59x18.unwrap(n) / ONE;
            x = x.add(sd(nInt * 2 * PI));
        }

        return x;
    }

    /// @notice Two-argument arctangent approximation
    /// @dev Uses a rational approximation for atan on [0, 1] with quadrant correction.
    ///      atan(x) ≈ x·(0.9998660 + x²·(0.3302995 + x²·0.1801410)) /
    ///                  (1 + x²·(0.6634898 + x²·(0.2140373 + x²·0.0107900)))
    ///      Accurate to ~5e-5 relative error.
    /// @param y Imaginary component
    /// @param x Real component
    /// @return angle atan2(y, x) in [−π, π]
    function _atan2(SD59x18 y, SD59x18 x) private pure returns (SD59x18 angle) {
        SD59x18 piVal = sd(PI);
        SD59x18 halfPi = piVal.div(sd(TWO));

        bool xNeg = x.lt(ZERO);
        bool yNeg = y.lt(ZERO);

        SD59x18 absX = x.abs();
        SD59x18 absY = y.abs();

        // Handle special cases
        if (absX.lt(sd(1e8)) && absY.lt(sd(1e8))) {
            return ZERO;
        }
        if (absX.lt(sd(1e8))) {
            return yNeg ? halfPi.mul(sd(-ONE)) : halfPi;
        }
        if (absY.lt(sd(1e8))) {
            return xNeg ? piVal : ZERO;
        }

        // Compute atan(|y/x|) or atan(|x/y|) depending on which is ≤ 1
        SD59x18 atanVal;
        bool swapped;
        if (absY.gt(absX)) {
            atanVal = _atanSmall(absX.div(absY));
            swapped = true;
        } else {
            atanVal = _atanSmall(absY.div(absX));
            swapped = false;
        }

        // If swapped, atan(y/x) = π/2 − atan(x/y)
        if (swapped) {
            atanVal = halfPi.sub(atanVal);
        }

        // Quadrant correction
        if (xNeg) {
            atanVal = piVal.sub(atanVal);
        }
        if (yNeg) {
            atanVal = atanVal.mul(sd(-ONE));
        }

        angle = atanVal;
    }

    /// @notice Computes atan(x) for x ∈ [0, 1] using rational approximation
    function _atanSmall(SD59x18 x) private pure returns (SD59x18) {
        SD59x18 x2 = x.mul(x);

        // Numerator: x·(a₀ + x²·(a₁ + x²·a₂))
        SD59x18 a0 = sd(999866000000000000); // 0.9998660
        SD59x18 a1 = sd(330299500000000000); // 0.3302995
        SD59x18 a2 = sd(180141000000000000); // 0.1801410

        SD59x18 num = x.mul(a0.add(x2.mul(a1.add(x2.mul(a2)))));

        // Denominator: 1 + x²·(b₁ + x²·(b₂ + x²·b₃))
        SD59x18 b1 = sd(663489800000000000); // 0.6634898
        SD59x18 b2 = sd(214037300000000000); // 0.2140373
        SD59x18 b3 = sd(10790000000000000); // 0.0107900

        SD59x18 den = sd(ONE).add(x2.mul(b1.add(x2.mul(b2.add(x2.mul(b3))))));

        return num.div(den);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL UTILITIES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes discount factor e^(−r·T)
    function _discount(SD59x18 r, SD59x18 t) private pure returns (SD59x18) {
        return r.mul(t).mul(sd(-ONE)).exp();
    }

    /// @notice Validates all Heston parameters
    function _validateParams(HestonParams memory p) private pure {
        if (p.spot.lte(ZERO)) revert HestonModel__InvalidSpotPrice(p.spot);
        if (p.strike.lte(ZERO)) revert HestonModel__InvalidStrikePrice(p.strike);
        if (p.timeToExpiry.lte(ZERO)) revert HestonModel__InvalidTimeToExpiry(p.timeToExpiry);
        if (p.riskFreeRate.lt(ZERO)) revert HestonModel__InvalidRiskFreeRate(p.riskFreeRate);
        if (p.v0.lte(ZERO)) revert HestonModel__InvalidInitialVariance(p.v0);
        if (p.theta.lte(ZERO)) revert HestonModel__InvalidLongRunVariance(p.theta);
        if (p.kappa.lte(ZERO)) revert HestonModel__InvalidMeanReversionSpeed(p.kappa);
        if (p.xi.lte(ZERO)) revert HestonModel__InvalidVolOfVol(p.xi);
        if (p.rho.lt(sd(-ONE)) || p.rho.gt(sd(ONE))) revert HestonModel__InvalidCorrelation(p.rho);
    }

    /// @notice Deep copies Heston parameters
    function _copyParams(HestonParams memory p) private pure returns (HestonParams memory copy) {
        copy.spot = p.spot;
        copy.strike = p.strike;
        copy.riskFreeRate = p.riskFreeRate;
        copy.timeToExpiry = p.timeToExpiry;
        copy.v0 = p.v0;
        copy.theta = p.theta;
        copy.kappa = p.kappa;
        copy.xi = p.xi;
        copy.rho = p.rho;
    }
}
