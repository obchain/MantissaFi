// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import { Constants } from "./Constants.sol";
import { CumulativeNormal } from "./CumulativeNormal.sol";

/// @title AcademicPaperBenchmarks
/// @author MantissaFi Team
/// @notice On-chain verifiable benchmarks for the MantissaFi academic paper
/// @dev Implements reproducible computations for each paper section:
///
///      Section 3 (Mathematical Framework):
///        - BSM call/put pricing in SD59x18 fixed-point
///        - d1/d2 computation with bounded rounding error
///        - Put-call parity verification
///
///      Section 4 (Volatility Surface):
///        - EWMA realized volatility estimator
///        - Moneyness-dependent skew (quadratic model)
///        - Utilization-adjusted implied volatility
///
///      Section 5 (System Design):
///        - Gas-metered pricing for benchmarking tables
///
///      Section 6 (Formal Verification):
///        - Invariant predicates (non-negative premium, put-call parity, CDF bounds)
///
///      Section 7 (Evaluation):
///        - Absolute/relative precision measurement against known reference values
///        - Protocol error comparison (Lyra, Primitive)
///
///      All functions are pure/view and produce deterministic, auditable results
///      suitable for inclusion in IEEE ICBC / Financial Cryptography submissions.

// ═══════════════════════════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Thrown when spot price is not strictly positive
error AcademicBenchmark__InvalidSpotPrice(SD59x18 spot);

/// @notice Thrown when strike price is not strictly positive
error AcademicBenchmark__InvalidStrikePrice(SD59x18 strike);

/// @notice Thrown when volatility is not strictly positive
error AcademicBenchmark__InvalidVolatility(SD59x18 volatility);

/// @notice Thrown when time to expiry is not strictly positive
error AcademicBenchmark__InvalidTimeToExpiry(SD59x18 timeToExpiry);

/// @notice Thrown when risk-free rate is negative
error AcademicBenchmark__InvalidRiskFreeRate(SD59x18 riskFreeRate);

/// @notice Thrown when return array length is zero
error AcademicBenchmark__EmptyReturnsArray();

/// @notice Thrown when EWMA decay factor is outside (0, 1)
error AcademicBenchmark__InvalidDecayFactor(SD59x18 lambda);

/// @notice Thrown when utilization ratio exceeds 1.0
error AcademicBenchmark__UtilizationTooHigh(SD59x18 utilization);

/// @notice Thrown when reference value is zero (cannot compute relative error)
error AcademicBenchmark__ZeroReferenceValue();

/// @notice Thrown when put-call parity violation exceeds tolerance
error AcademicBenchmark__PutCallParityViolation(SD59x18 gap, SD59x18 tolerance);

// ═══════════════════════════════════════════════════════════════════════════════
// STRUCTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice BSM pricing parameters used throughout the benchmark suite
/// @param spot Current spot price S > 0
/// @param strike Strike price K > 0
/// @param volatility Implied volatility σ > 0
/// @param riskFreeRate Risk-free interest rate r ≥ 0
/// @param timeToExpiry Time to expiry in years T > 0
struct BSMParams {
    SD59x18 spot;
    SD59x18 strike;
    SD59x18 volatility;
    SD59x18 riskFreeRate;
    SD59x18 timeToExpiry;
}

/// @notice Complete BSM pricing result for a single parameter set
/// @param callPrice European call price
/// @param putPrice European put price
/// @param d1 First intermediary variable
/// @param d2 Second intermediary variable
struct BSMResult {
    SD59x18 callPrice;
    SD59x18 putPrice;
    SD59x18 d1;
    SD59x18 d2;
}

/// @notice Precision measurement against a known reference value
/// @param absoluteError |computed − reference|
/// @param relativeError |computed − reference| / |reference|
/// @param bitsOfPrecision −log₂(relativeError), i.e. number of correct binary digits
struct PrecisionResult {
    SD59x18 absoluteError;
    SD59x18 relativeError;
    SD59x18 bitsOfPrecision;
}

/// @notice Volatility surface point with base IV, skew, and utilization premium
/// @param baseIV EWMA-estimated realized volatility (annualized)
/// @param skew Moneyness-dependent skew adjustment
/// @param utilizationPremium Capacity-based premium
/// @param totalIV Final implied volatility = baseIV + skew + utilizationPremium
struct VolSurfacePoint {
    SD59x18 baseIV;
    SD59x18 skew;
    SD59x18 utilizationPremium;
    SD59x18 totalIV;
}

/// @notice Invariant check results for formal verification section
/// @param premiumNonNegative True if call and put prices ≥ 0
/// @param putCallParityHolds True if |C − P − S + K·e^(−rT)| < tolerance
/// @param cdfInUnitInterval True if Φ(d1), Φ(d2) ∈ [0, 1]
/// @param parityGap Absolute put-call parity deviation
struct InvariantCheckResult {
    bool premiumNonNegative;
    bool putCallParityHolds;
    bool cdfInUnitInterval;
    SD59x18 parityGap;
}

library AcademicPaperBenchmarks {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice 1.0 in fixed-point
    int256 private constant ONE = 1e18;

    /// @notice 2.0 in fixed-point
    int256 private constant TWO = 2e18;

    /// @notice 0.5 in fixed-point
    int256 private constant HALF = 5e17;

    /// @notice Default put-call parity tolerance (1e-8 in SD59x18 = 10_000_000_000)
    SD59x18 internal constant DEFAULT_PARITY_TOLERANCE = SD59x18.wrap(10_000_000_000);

    /// @notice Lyra CDF approximation typical relative error (≈ 1e-7)
    SD59x18 internal constant LYRA_RELATIVE_ERROR = SD59x18.wrap(100_000_000_000);

    /// @notice Primitive RMM-01 typical relative error (≈ 5e-7)
    SD59x18 internal constant PRIMITIVE_RELATIVE_ERROR = SD59x18.wrap(500_000_000_000);

    /// @notice ln(2) for bits-of-precision conversion
    SD59x18 internal constant LN2 = SD59x18.wrap(693_147_180_559_945_309);

    /// @notice Seconds per year (365 days) as SD59x18
    SD59x18 internal constant YEAR_SECONDS = SD59x18.wrap(31_536_000_000_000_000_000_000_000);

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3: MATHEMATICAL FRAMEWORK — BSM IN FIXED-POINT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes d1 and d2 for Black-Scholes-Merton
    /// @dev d1 = [ln(S/K) + (r + σ²/2)·T] / (σ·√T)
    ///      d2 = d1 − σ·√T
    /// @param p BSM pricing parameters
    /// @return d1 First intermediary variable
    /// @return d2 Second intermediary variable
    function computeD1D2(BSMParams memory p) internal pure returns (SD59x18 d1, SD59x18 d2) {
        _validateParams(p);

        SD59x18 logMoneyness = p.spot.div(p.strike).ln();
        SD59x18 halfVar = p.volatility.mul(p.volatility).div(sd(TWO));
        SD59x18 drift = p.riskFreeRate.add(halfVar).mul(p.timeToExpiry);
        SD59x18 volSqrtT = p.volatility.mul(p.timeToExpiry.sqrt());

        d1 = logMoneyness.add(drift).div(volSqrtT);
        d2 = d1.sub(volSqrtT);
    }

    /// @notice Prices a European call option via BSM
    /// @dev C = S·Φ(d1) − K·e^(−rT)·Φ(d2)
    /// @param p BSM pricing parameters
    /// @return price Call option price (floored at zero)
    function priceCall(BSMParams memory p) internal pure returns (SD59x18 price) {
        _validateParams(p);

        (SD59x18 d1, SD59x18 d2) = computeD1D2(p);
        SD59x18 discount = _discount(p.riskFreeRate, p.timeToExpiry);

        price = p.spot.mul(CumulativeNormal.cdf(d1)).sub(p.strike.mul(discount).mul(CumulativeNormal.cdf(d2)));

        if (price.lt(ZERO)) {
            price = ZERO;
        }
    }

    /// @notice Prices a European put option via BSM
    /// @dev P = K·e^(−rT)·Φ(−d2) − S·Φ(−d1)
    /// @param p BSM pricing parameters
    /// @return price Put option price (floored at zero)
    function pricePut(BSMParams memory p) internal pure returns (SD59x18 price) {
        _validateParams(p);

        (SD59x18 d1, SD59x18 d2) = computeD1D2(p);
        SD59x18 discount = _discount(p.riskFreeRate, p.timeToExpiry);

        SD59x18 negD1 = d1.mul(sd(-ONE));
        SD59x18 negD2 = d2.mul(sd(-ONE));

        price = p.strike.mul(discount).mul(CumulativeNormal.cdf(negD2)).sub(p.spot.mul(CumulativeNormal.cdf(negD1)));

        if (price.lt(ZERO)) {
            price = ZERO;
        }
    }

    /// @notice Computes both call and put prices with intermediary variables
    /// @param p BSM pricing parameters
    /// @return result Complete BSM pricing result
    function priceBSM(BSMParams memory p) internal pure returns (BSMResult memory result) {
        _validateParams(p);

        (result.d1, result.d2) = computeD1D2(p);
        SD59x18 discount = _discount(p.riskFreeRate, p.timeToExpiry);

        SD59x18 cdfD1 = CumulativeNormal.cdf(result.d1);
        SD59x18 cdfD2 = CumulativeNormal.cdf(result.d2);
        SD59x18 cdfNegD1 = CumulativeNormal.cdf(result.d1.mul(sd(-ONE)));
        SD59x18 cdfNegD2 = CumulativeNormal.cdf(result.d2.mul(sd(-ONE)));

        result.callPrice = p.spot.mul(cdfD1).sub(p.strike.mul(discount).mul(cdfD2));
        result.putPrice = p.strike.mul(discount).mul(cdfNegD2).sub(p.spot.mul(cdfNegD1));

        if (result.callPrice.lt(ZERO)) result.callPrice = ZERO;
        if (result.putPrice.lt(ZERO)) result.putPrice = ZERO;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 4: VOLATILITY SURFACE — EWMA, SKEW, UTILIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes EWMA realized volatility from an array of log-returns
    /// @dev σ²_t = λ·σ²_{t−1} + (1−λ)·r²_t  (exponentially weighted moving average)
    ///      Annualized: σ_annual = σ_daily · √252
    /// @param logReturns Array of daily log-returns in SD59x18 (must be non-empty)
    /// @param lambda Decay factor ∈ (0, 1), typically 0.94 (RiskMetrics)
    /// @return annualizedVol EWMA-estimated annualized volatility
    function ewmaVolatility(SD59x18[] memory logReturns, SD59x18 lambda) internal pure returns (SD59x18 annualizedVol) {
        if (logReturns.length == 0) {
            revert AcademicBenchmark__EmptyReturnsArray();
        }
        if (lambda.lte(ZERO) || lambda.gte(sd(ONE))) {
            revert AcademicBenchmark__InvalidDecayFactor(lambda);
        }

        SD59x18 oneMinusLambda = sd(ONE).sub(lambda);

        // Initialize variance with first return squared
        SD59x18 variance = logReturns[0].mul(logReturns[0]);

        // EWMA recursion
        for (uint256 i = 1; i < logReturns.length; i++) {
            SD59x18 returnSq = logReturns[i].mul(logReturns[i]);
            variance = lambda.mul(variance).add(oneMinusLambda.mul(returnSq));
        }

        // Annualize: σ_annual = σ_daily · √252
        SD59x18 sqrt252 = sd(252e18).sqrt();
        annualizedVol = variance.sqrt().mul(sqrt252);
    }

    /// @notice Computes moneyness-dependent volatility skew using a quadratic model
    /// @dev skew(m) = a·(m − 1)² + b·(m − 1)
    ///      where m = S/K is the moneyness ratio.
    ///      Coefficient a > 0 produces a volatility smile; b ≠ 0 introduces asymmetry (smirk).
    /// @param spot Current spot price
    /// @param strike Strike price
    /// @param a Quadratic coefficient (curvature of the smile)
    /// @param b Linear coefficient (skew/smirk direction)
    /// @return skew Volatility skew adjustment (additive to base IV)
    function volatilitySkew(SD59x18 spot, SD59x18 strike, SD59x18 a, SD59x18 b) internal pure returns (SD59x18 skew) {
        if (strike.lte(ZERO)) {
            revert AcademicBenchmark__InvalidStrikePrice(strike);
        }

        SD59x18 moneyness = spot.div(strike);
        SD59x18 deviation = moneyness.sub(sd(ONE));

        // skew = a·(m−1)² + b·(m−1)
        skew = a.mul(deviation).mul(deviation).add(b.mul(deviation));
    }

    /// @notice Computes utilization-based implied volatility premium
    /// @dev premium = baseIV · k · u / (1 − u)  where u is utilization ratio ∈ [0, 1)
    ///      This captures the increased risk price when pool capacity is high.
    ///      The hyperbolic form ensures the premium → ∞ as u → 1.
    /// @param baseIV Base implied volatility
    /// @param utilization Pool utilization ratio ∈ [0, 1)
    /// @param k Scaling factor for the premium (protocol parameter)
    /// @return premium Utilization premium (additive to IV)
    function utilizationPremium(SD59x18 baseIV, SD59x18 utilization, SD59x18 k)
        internal
        pure
        returns (SD59x18 premium)
    {
        if (utilization.gte(sd(ONE))) {
            revert AcademicBenchmark__UtilizationTooHigh(utilization);
        }

        if (utilization.lte(ZERO)) {
            return ZERO;
        }

        // premium = baseIV · k · u / (1 − u)
        SD59x18 denominator = sd(ONE).sub(utilization);
        premium = baseIV.mul(k).mul(utilization).div(denominator);
    }

    /// @notice Computes a complete volatility surface point
    /// @param baseIV EWMA base volatility
    /// @param spot Current spot price
    /// @param strike Option strike price
    /// @param a Skew quadratic coefficient
    /// @param b Skew linear coefficient
    /// @param utilization Pool utilization ratio ∈ [0, 1)
    /// @param k Utilization premium scaling factor
    /// @return point Full volatility surface point with all components
    function computeVolSurfacePoint(
        SD59x18 baseIV,
        SD59x18 spot,
        SD59x18 strike,
        SD59x18 a,
        SD59x18 b,
        SD59x18 utilization,
        SD59x18 k
    ) internal pure returns (VolSurfacePoint memory point) {
        point.baseIV = baseIV;
        point.skew = volatilitySkew(spot, strike, a, b);
        point.utilizationPremium = utilizationPremium(baseIV, utilization, k);
        point.totalIV = baseIV.add(point.skew).add(point.utilizationPremium);

        // Floor total IV at a small positive value to prevent pathological pricing
        SD59x18 minIV = sd(1e16); // 0.01 = 1%
        if (point.totalIV.lt(minIV)) {
            point.totalIV = minIV;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 6: FORMAL VERIFICATION — INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies all BSM pricing invariants for a given parameter set
    /// @dev Checks:
    ///   1. Non-negative premiums: C ≥ 0, P ≥ 0
    ///   2. Put-call parity: C − P = S − K·e^(−rT)  (within tolerance)
    ///   3. CDF bounds: Φ(d1), Φ(d2) ∈ [0, 1]
    /// @param p BSM pricing parameters
    /// @param tolerance Maximum allowed put-call parity deviation
    /// @return result Invariant check results
    function checkInvariants(BSMParams memory p, SD59x18 tolerance)
        internal
        pure
        returns (InvariantCheckResult memory result)
    {
        _validateParams(p);

        BSMResult memory bsm = priceBSM(p);
        SD59x18 discount = _discount(p.riskFreeRate, p.timeToExpiry);

        // 1. Non-negative premiums
        result.premiumNonNegative = bsm.callPrice.gte(ZERO) && bsm.putPrice.gte(ZERO);

        // 2. Put-call parity: C − P = S − K·e^(−rT)
        SD59x18 lhs = bsm.callPrice.sub(bsm.putPrice);
        SD59x18 rhs = p.spot.sub(p.strike.mul(discount));
        result.parityGap = lhs.sub(rhs).abs();
        result.putCallParityHolds = result.parityGap.lte(tolerance);

        // 3. CDF in [0, 1]
        SD59x18 cdfD1 = CumulativeNormal.cdf(bsm.d1);
        SD59x18 cdfD2 = CumulativeNormal.cdf(bsm.d2);
        result.cdfInUnitInterval = cdfD1.gte(ZERO) && cdfD1.lte(sd(ONE)) && cdfD2.gte(ZERO) && cdfD2.lte(sd(ONE));
    }

    /// @notice Verifies put-call parity and reverts if violated beyond tolerance
    /// @param p BSM pricing parameters
    /// @param tolerance Maximum allowed deviation
    function assertPutCallParity(BSMParams memory p, SD59x18 tolerance) internal pure {
        InvariantCheckResult memory result = checkInvariants(p, tolerance);
        if (!result.putCallParityHolds) {
            revert AcademicBenchmark__PutCallParityViolation(result.parityGap, tolerance);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 7: EVALUATION — PRECISION MEASUREMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Measures precision of a computed value against a known reference
    /// @dev Computes absolute error, relative error, and bits of precision.
    ///      Bits of precision = −log₂(relativeError) = −ln(relError) / ln(2)
    /// @param computed The on-chain computed value
    /// @param refValue The known reference value (e.g., from high-precision off-chain BSM)
    /// @return result Precision measurement
    function measurePrecision(SD59x18 computed, SD59x18 refValue)
        internal
        pure
        returns (PrecisionResult memory result)
    {
        if (refValue.eq(ZERO)) {
            revert AcademicBenchmark__ZeroReferenceValue();
        }

        result.absoluteError = computed.sub(refValue).abs();
        result.relativeError = result.absoluteError.div(refValue.abs());

        // Bits of precision = −log₂(relativeError) = −ln(relError) / ln(2)
        // Guard: if relativeError = 0, we have "perfect" precision; cap at 59 bits (SD59x18 limit)
        if (result.relativeError.eq(ZERO)) {
            result.bitsOfPrecision = sd(59e18);
        } else {
            // −ln(relError) / ln(2)
            SD59x18 negLnRel = result.relativeError.ln().mul(sd(-ONE));
            result.bitsOfPrecision = negLnRel.div(LN2);
        }
    }

    /// @notice Compares MantissaFi pricing error against Lyra and Primitive error estimates
    /// @dev Uses known typical relative errors from each protocol's CDF/pricing implementation.
    ///      Returns scaled absolute errors for a given price magnitude.
    /// @param computedPrice MantissaFi computed call price
    /// @param referencePrice Known reference call price
    /// @return mantissaAbsError MantissaFi absolute error
    /// @return lyraEstError Estimated Lyra absolute error at same price scale
    /// @return primitiveEstError Estimated Primitive absolute error at same price scale
    function compareProtocolErrors(SD59x18 computedPrice, SD59x18 referencePrice)
        internal
        pure
        returns (SD59x18 mantissaAbsError, SD59x18 lyraEstError, SD59x18 primitiveEstError)
    {
        if (referencePrice.eq(ZERO)) {
            revert AcademicBenchmark__ZeroReferenceValue();
        }

        mantissaAbsError = computedPrice.sub(referencePrice).abs();
        lyraEstError = LYRA_RELATIVE_ERROR.mul(referencePrice.abs()).div(sd(ONE));
        primitiveEstError = PRIMITIVE_RELATIVE_ERROR.mul(referencePrice.abs()).div(sd(ONE));
    }

    /// @notice Checks whether two values agree within a given number of basis points
    /// @param a First value
    /// @param b Second value (reference)
    /// @param basisPoints Maximum allowed error in bps (1 bp = 0.01%)
    /// @return withinBounds True if relative error ≤ basisPoints / 10_000
    function agreesWithinBps(SD59x18 a, SD59x18 b, uint256 basisPoints) internal pure returns (bool withinBounds) {
        if (b.eq(ZERO)) {
            return a.eq(ZERO);
        }
        SD59x18 relErr = a.sub(b).abs().div(b.abs());
        SD59x18 threshold = sd(int256(basisPoints) * 1e14);
        withinBounds = relErr.lte(threshold);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 7 (continued): GREEKS FOR EVALUATION TABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes BSM delta (∂C/∂S) for call options
    /// @dev Δ_call = Φ(d1)
    /// @param p BSM pricing parameters
    /// @return delta Call delta ∈ [0, 1]
    function callDelta(BSMParams memory p) internal pure returns (SD59x18 delta) {
        _validateParams(p);
        (SD59x18 d1,) = computeD1D2(p);
        delta = CumulativeNormal.cdf(d1);
    }

    /// @notice Computes BSM gamma (∂²C/∂S²)
    /// @dev Γ = φ(d1) / (S·σ·√T)
    /// @param p BSM pricing parameters
    /// @return gamma_ Option gamma (same for call and put)
    function gamma(BSMParams memory p) internal pure returns (SD59x18 gamma_) {
        _validateParams(p);
        (SD59x18 d1,) = computeD1D2(p);
        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);
        SD59x18 denom = p.spot.mul(p.volatility).mul(p.timeToExpiry.sqrt());
        gamma_ = pdfD1.div(denom);
    }

    /// @notice Computes BSM vega (∂C/∂σ)
    /// @dev ν = S·√T·φ(d1)
    /// @param p BSM pricing parameters
    /// @return vega_ Option vega (same for call and put)
    function vega(BSMParams memory p) internal pure returns (SD59x18 vega_) {
        _validateParams(p);
        (SD59x18 d1,) = computeD1D2(p);
        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);
        vega_ = p.spot.mul(p.timeToExpiry.sqrt()).mul(pdfD1);
    }

    /// @notice Computes BSM theta (∂C/∂T) for call options
    /// @dev Θ_call = −[S·φ(d1)·σ / (2√T)] − r·K·e^(−rT)·Φ(d2)
    /// @param p BSM pricing parameters
    /// @return theta Call option theta (typically negative)
    function callTheta(BSMParams memory p) internal pure returns (SD59x18 theta) {
        _validateParams(p);
        (SD59x18 d1, SD59x18 d2) = computeD1D2(p);

        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);
        SD59x18 sqrtT = p.timeToExpiry.sqrt();
        SD59x18 discount = _discount(p.riskFreeRate, p.timeToExpiry);

        // −S·φ(d1)·σ / (2√T)
        SD59x18 term1 = p.spot.mul(pdfD1).mul(p.volatility).div(sd(TWO).mul(sqrtT)).mul(sd(-ONE));

        // −r·K·e^(−rT)·Φ(d2)
        SD59x18 term2 = p.riskFreeRate.mul(p.strike).mul(discount).mul(CumulativeNormal.cdf(d2)).mul(sd(-ONE));

        theta = term1.add(term2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3 (continued): CDF ANALYSIS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Measures CDF symmetry error: |Φ(x) + Φ(−x) − 1|
    /// @dev A perfect CDF implementation satisfies Φ(x) + Φ(−x) = 1 exactly.
    ///      Any deviation indicates approximation or rounding error.
    /// @param x Input value
    /// @return symmetryError Absolute symmetry deviation
    function cdfSymmetryError(SD59x18 x) internal pure returns (SD59x18 symmetryError) {
        SD59x18 cdfPos = CumulativeNormal.cdf(x);
        SD59x18 cdfNeg = CumulativeNormal.cdf(x.mul(sd(-ONE)));
        symmetryError = cdfPos.add(cdfNeg).sub(sd(ONE)).abs();
    }

    /// @notice Evaluates CDF at a point and returns both the value and its complement
    /// @dev Returns (Φ(x), 1 − Φ(x)) for numerical analysis of tail behavior
    /// @param x Input value
    /// @return cdfValue Φ(x)
    /// @return complement 1 − Φ(x) = Φ(−x) using direct evaluation (not subtraction)
    function cdfWithComplement(SD59x18 x) internal pure returns (SD59x18 cdfValue, SD59x18 complement) {
        cdfValue = CumulativeNormal.cdf(x);
        complement = CumulativeNormal.cdf(x.mul(sd(-ONE)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates all BSM parameters
    function _validateParams(BSMParams memory p) private pure {
        if (p.spot.lte(ZERO)) revert AcademicBenchmark__InvalidSpotPrice(p.spot);
        if (p.strike.lte(ZERO)) revert AcademicBenchmark__InvalidStrikePrice(p.strike);
        if (p.volatility.lte(ZERO)) revert AcademicBenchmark__InvalidVolatility(p.volatility);
        if (p.timeToExpiry.lte(ZERO)) revert AcademicBenchmark__InvalidTimeToExpiry(p.timeToExpiry);
        if (p.riskFreeRate.lt(ZERO)) revert AcademicBenchmark__InvalidRiskFreeRate(p.riskFreeRate);
    }

    /// @notice Computes the discount factor e^(−r·T)
    function _discount(SD59x18 r, SD59x18 t) private pure returns (SD59x18) {
        return r.mul(t).mul(sd(-ONE)).exp();
    }
}
