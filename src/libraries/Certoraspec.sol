// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import { Constants } from "./Constants.sol";
import { CumulativeNormal } from "./CumulativeNormal.sol";

/// @title Certoraspec
/// @author MantissaFi Team
/// @notice Library encoding pricing monotonicity invariants for formal verification
/// @dev Proves three core Black-Scholes partial derivatives:
///      - ∂C/∂S > 0  (call delta is positive → call price increases with spot)
///      - ∂P/∂S < 0  (put delta is negative → put price decreases with spot)
///      - ∂C/∂σ > 0  (vega is positive → option price increases with volatility)
///
///      Each invariant is encoded as a discrete finite-difference check:
///          f(x + ε) ≥ f(x)  (or ≤ for puts w.r.t. spot)
///      with an analytical closed-form verifier that computes the exact Greek.

// ═══════════════════════════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Thrown when spot price is not strictly positive
error Certoraspec__InvalidSpotPrice(SD59x18 spot);

/// @notice Thrown when strike price is not strictly positive
error Certoraspec__InvalidStrikePrice(SD59x18 strike);

/// @notice Thrown when volatility is not strictly positive
error Certoraspec__InvalidVolatility(SD59x18 volatility);

/// @notice Thrown when time to expiry is not strictly positive
error Certoraspec__InvalidTimeToExpiry(SD59x18 timeToExpiry);

/// @notice Thrown when the bump size epsilon is not strictly positive
error Certoraspec__InvalidEpsilon(SD59x18 epsilon);

/// @notice Thrown when risk-free rate is negative
error Certoraspec__InvalidRiskFreeRate(SD59x18 riskFreeRate);

/// @notice Thrown when the call-delta-positive invariant is violated
/// @param spot The spot price used
/// @param delta The computed call delta (expected > 0)
error Certoraspec__CallDeltaNotPositive(SD59x18 spot, SD59x18 delta);

/// @notice Thrown when the put-delta-negative invariant is violated
/// @param spot The spot price used
/// @param delta The computed put delta (expected < 0)
error Certoraspec__PutDeltaNotNegative(SD59x18 spot, SD59x18 delta);

/// @notice Thrown when the vega-positive invariant is violated
/// @param volatility The volatility used
/// @param vega The computed vega (expected > 0)
error Certoraspec__VegaNotPositive(SD59x18 volatility, SD59x18 vega);

/// @notice Thrown when the finite-difference monotonicity check fails for calls
/// @param priceLow Price at lower spot
/// @param priceHigh Price at higher spot
error Certoraspec__CallNotMonotonicInSpot(SD59x18 priceLow, SD59x18 priceHigh);

/// @notice Thrown when the finite-difference monotonicity check fails for puts
/// @param priceLow Price at lower spot
/// @param priceHigh Price at higher spot
error Certoraspec__PutNotMonotonicInSpot(SD59x18 priceLow, SD59x18 priceHigh);

/// @notice Thrown when the finite-difference vega check fails
/// @param priceLowVol Price at lower volatility
/// @param priceHighVol Price at higher volatility
error Certoraspec__PriceNotMonotonicInVol(SD59x18 priceLowVol, SD59x18 priceHighVol);

// ═══════════════════════════════════════════════════════════════════════════════
// STRUCTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Pricing inputs for monotonicity verification
/// @param spot Current spot price S > 0
/// @param strike Strike price K > 0
/// @param volatility Implied volatility σ > 0
/// @param riskFreeRate Risk-free interest rate r ≥ 0
/// @param timeToExpiry Time to expiry in years T > 0
struct PricingParams {
    SD59x18 spot;
    SD59x18 strike;
    SD59x18 volatility;
    SD59x18 riskFreeRate;
    SD59x18 timeToExpiry;
}

/// @notice Result of a monotonicity verification
/// @param holds True if the invariant holds
/// @param lowerValue The function value at the lower input
/// @param upperValue The function value at the upper input
/// @param greekValue The analytical Greek value (delta or vega)
struct MonotonicityResult {
    bool holds;
    SD59x18 lowerValue;
    SD59x18 upperValue;
    SD59x18 greekValue;
}

library Certoraspec {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Default bump size for finite-difference checks (0.01 = 1%)
    SD59x18 internal constant DEFAULT_EPSILON = SD59x18.wrap(10000000000000000);

    /// @notice Minimum allowed volatility for verification (0.1%)
    SD59x18 internal constant MIN_VOLATILITY = SD59x18.wrap(1000000000000000);

    /// @notice Maximum allowed volatility for verification (500%)
    SD59x18 internal constant MAX_VOLATILITY = SD59x18.wrap(5_000000000000000000);

    /// @notice Minimum spot/strike price (0.001)
    SD59x18 internal constant MIN_PRICE = SD59x18.wrap(1000000000000000);

    /// @notice Maximum spot/strike price (10 million)
    SD59x18 internal constant MAX_PRICE = SD59x18.wrap(10_000_000_000000000000000000);

    /// @notice Minimum time to expiry (1 second annualized ≈ 3.17e-8 years)
    SD59x18 internal constant MIN_TIME = SD59x18.wrap(31709791983);

    /// @notice Maximum time to expiry (10 years)
    SD59x18 internal constant MAX_TIME = SD59x18.wrap(10_000000000000000000);

    /// @notice Numerical tolerance for monotonicity checks (1e-12 = 0.0000001%)
    /// @dev Accounts for floating-point precision errors in BSM calculations
    SD59x18 internal constant NUMERICAL_TOLERANCE = SD59x18.wrap(1000000);

    // ═══════════════════════════════════════════════════════════════════════════
    // BSM CORE FUNCTIONS (self-contained for verification)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes d1 for Black-Scholes
    /// @dev d1 = [ln(S/K) + (r + σ²/2) · T] / (σ · √T)
    /// @param p Pricing parameters
    /// @return d1 The d1 value
    function computeD1(PricingParams memory p) internal pure returns (SD59x18 d1) {
        SD59x18 logMoneyness = p.spot.div(p.strike).ln();
        SD59x18 halfVar = p.volatility.mul(p.volatility).div(sd(2e18));
        SD59x18 drift = p.riskFreeRate.add(halfVar).mul(p.timeToExpiry);
        SD59x18 volSqrtT = p.volatility.mul(p.timeToExpiry.sqrt());
        d1 = logMoneyness.add(drift).div(volSqrtT);
    }

    /// @notice Computes d2 for Black-Scholes
    /// @dev d2 = d1 − σ · √T
    /// @param p Pricing parameters
    /// @param d1 Pre-computed d1
    /// @return d2 The d2 value
    function computeD2(PricingParams memory p, SD59x18 d1) internal pure returns (SD59x18 d2) {
        d2 = d1.sub(p.volatility.mul(p.timeToExpiry.sqrt()));
    }

    /// @notice Prices a European call option via Black-Scholes
    /// @dev C = S · Φ(d1) − K · e^(−rT) · Φ(d2)
    /// @param p Validated pricing parameters
    /// @return price The call premium (≥ 0)
    function priceCall(PricingParams memory p) internal pure returns (SD59x18 price) {
        SD59x18 d1 = computeD1(p);
        SD59x18 d2 = computeD2(p, d1);

        SD59x18 cdfD1 = CumulativeNormal.cdf(d1);
        SD59x18 cdfD2 = CumulativeNormal.cdf(d2);
        SD59x18 discount = p.riskFreeRate.mul(p.timeToExpiry).mul(sd(-1e18)).exp();

        price = p.spot.mul(cdfD1).sub(p.strike.mul(discount).mul(cdfD2));

        if (price.lt(ZERO)) {
            price = ZERO;
        }
    }

    /// @notice Prices a European put option via Black-Scholes
    /// @dev P = K · e^(−rT) · Φ(−d2) − S · Φ(−d1)
    /// @param p Validated pricing parameters
    /// @return price The put premium (≥ 0)
    function pricePut(PricingParams memory p) internal pure returns (SD59x18 price) {
        SD59x18 d1 = computeD1(p);
        SD59x18 d2 = computeD2(p, d1);

        SD59x18 cdfNegD1 = CumulativeNormal.cdf(d1.mul(sd(-1e18)));
        SD59x18 cdfNegD2 = CumulativeNormal.cdf(d2.mul(sd(-1e18)));
        SD59x18 discount = p.riskFreeRate.mul(p.timeToExpiry).mul(sd(-1e18)).exp();

        price = p.strike.mul(discount).mul(cdfNegD2).sub(p.spot.mul(cdfNegD1));

        if (price.lt(ZERO)) {
            price = ZERO;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ANALYTICAL GREEKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes call delta: Δ_call = Φ(d1)
    /// @dev By Black-Scholes, ∂C/∂S = Φ(d1) ∈ (0, 1)
    /// @param p Pricing parameters
    /// @return delta The call delta
    function callDelta(PricingParams memory p) internal pure returns (SD59x18 delta) {
        SD59x18 d1 = computeD1(p);
        delta = CumulativeNormal.cdf(d1);
    }

    /// @notice Computes put delta: Δ_put = Φ(d1) − 1
    /// @dev By Black-Scholes, ∂P/∂S = Φ(d1) − 1 ∈ (−1, 0)
    /// @param p Pricing parameters
    /// @return delta The put delta
    function putDelta(PricingParams memory p) internal pure returns (SD59x18 delta) {
        SD59x18 d1 = computeD1(p);
        delta = CumulativeNormal.cdf(d1).sub(sd(1e18));
    }

    /// @notice Computes vega: ν = S · √T · φ(d1)
    /// @dev Vega is identical for calls and puts; always positive
    /// @param p Pricing parameters
    /// @return v The option vega
    function vega(PricingParams memory p) internal pure returns (SD59x18 v) {
        SD59x18 d1 = computeD1(p);
        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);
        v = p.spot.mul(p.timeToExpiry.sqrt()).mul(pdfD1);
    }

    /// @notice Computes gamma: Γ = φ(d1) / (S · σ · √T)
    /// @dev Gamma is identical for calls and puts; always positive
    /// @param p Pricing parameters
    /// @return g The option gamma
    function gamma(PricingParams memory p) internal pure returns (SD59x18 g) {
        SD59x18 d1 = computeD1(p);
        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);
        SD59x18 denom = p.spot.mul(p.volatility).mul(p.timeToExpiry.sqrt());
        g = pdfD1.div(denom);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INVARIANT: ∂C/∂S > 0  (Call price increases with spot)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies ∂C/∂S > 0 analytically via call delta
    /// @dev Checks that Φ(d1) > 0, which always holds for finite d1
    /// @param p Pricing parameters
    /// @return result True if call delta is strictly positive
    function verifyCallDeltaPositive(PricingParams memory p) internal pure returns (bool result) {
        _validateParams(p);
        SD59x18 delta = callDelta(p);
        result = delta.gt(ZERO);
    }

    /// @notice Verifies ∂C/∂S > 0 via finite difference: C(S+ε) ≥ C(S)
    /// @dev Bumps spot by epsilon and checks monotonicity
    /// @param p Pricing parameters
    /// @param epsilon The spot bump size (absolute, in SD59x18)
    /// @return result Monotonicity verification result
    function verifyCallMonotonicInSpot(PricingParams memory p, SD59x18 epsilon)
        internal
        pure
        returns (MonotonicityResult memory result)
    {
        _validateParams(p);
        _validateEpsilon(epsilon);

        SD59x18 priceLow = priceCall(p);

        PricingParams memory pBumped = _copyParams(p);
        pBumped.spot = p.spot.add(epsilon);
        SD59x18 priceHigh = priceCall(pBumped);

        result.lowerValue = priceLow;
        result.upperValue = priceHigh;
        result.greekValue = callDelta(p);
        // Allow for numerical tolerance in monotonicity check
        result.holds = priceHigh.add(NUMERICAL_TOLERANCE).gte(priceLow);
    }

    /// @notice Asserts ∂C/∂S > 0; reverts if violated
    /// @param p Pricing parameters
    /// @param epsilon The spot bump size
    function assertCallMonotonicInSpot(PricingParams memory p, SD59x18 epsilon) internal pure {
        MonotonicityResult memory res = verifyCallMonotonicInSpot(p, epsilon);
        if (!res.holds) {
            revert Certoraspec__CallNotMonotonicInSpot(res.lowerValue, res.upperValue);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INVARIANT: ∂P/∂S < 0  (Put price decreases with spot)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies ∂P/∂S < 0 analytically via put delta
    /// @dev Checks that Φ(d1) − 1 < 0, which always holds for finite d1
    /// @param p Pricing parameters
    /// @return result True if put delta is strictly negative
    function verifyPutDeltaNegative(PricingParams memory p) internal pure returns (bool result) {
        _validateParams(p);
        SD59x18 delta = putDelta(p);
        result = delta.lt(ZERO);
    }

    /// @notice Verifies ∂P/∂S < 0 via finite difference: P(S+ε) ≤ P(S)
    /// @dev Bumps spot by epsilon and checks monotonicity
    /// @param p Pricing parameters
    /// @param epsilon The spot bump size (absolute, in SD59x18)
    /// @return result Monotonicity verification result
    function verifyPutMonotonicInSpot(PricingParams memory p, SD59x18 epsilon)
        internal
        pure
        returns (MonotonicityResult memory result)
    {
        _validateParams(p);
        _validateEpsilon(epsilon);

        SD59x18 priceLow = pricePut(p);

        PricingParams memory pBumped = _copyParams(p);
        pBumped.spot = p.spot.add(epsilon);
        SD59x18 priceHigh = pricePut(pBumped);

        result.lowerValue = priceLow;
        result.upperValue = priceHigh;
        result.greekValue = putDelta(p);
        // Put price should decrease when spot increases: priceHigh <= priceLow
        // Allow for numerical tolerance
        result.holds = priceLow.add(NUMERICAL_TOLERANCE).gte(priceHigh);
    }

    /// @notice Asserts ∂P/∂S < 0; reverts if violated
    /// @param p Pricing parameters
    /// @param epsilon The spot bump size
    function assertPutMonotonicInSpot(PricingParams memory p, SD59x18 epsilon) internal pure {
        MonotonicityResult memory res = verifyPutMonotonicInSpot(p, epsilon);
        if (!res.holds) {
            revert Certoraspec__PutNotMonotonicInSpot(res.lowerValue, res.upperValue);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INVARIANT: ∂C/∂σ > 0 and ∂P/∂σ > 0  (Vega is positive)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies vega > 0 analytically
    /// @dev Checks S · √T · φ(d1) > 0. Since S > 0, T > 0, and φ > 0, this always holds.
    /// @param p Pricing parameters
    /// @return result True if vega is strictly positive
    function verifyVegaPositive(PricingParams memory p) internal pure returns (bool result) {
        _validateParams(p);
        SD59x18 v = vega(p);
        result = v.gt(ZERO);
    }

    /// @notice Verifies ∂C/∂σ > 0 via finite difference: C(σ+ε) ≥ C(σ)
    /// @param p Pricing parameters
    /// @param epsilon The volatility bump size
    /// @return result Monotonicity verification result
    function verifyCallMonotonicInVol(PricingParams memory p, SD59x18 epsilon)
        internal
        pure
        returns (MonotonicityResult memory result)
    {
        _validateParams(p);
        _validateEpsilon(epsilon);

        SD59x18 priceLow = priceCall(p);

        PricingParams memory pBumped = _copyParams(p);
        pBumped.volatility = p.volatility.add(epsilon);
        SD59x18 priceHigh = priceCall(pBumped);

        result.lowerValue = priceLow;
        result.upperValue = priceHigh;
        result.greekValue = vega(p);
        // Allow for numerical tolerance
        result.holds = priceHigh.add(NUMERICAL_TOLERANCE).gte(priceLow);
    }

    /// @notice Verifies ∂P/∂σ > 0 via finite difference: P(σ+ε) ≥ P(σ)
    /// @param p Pricing parameters
    /// @param epsilon The volatility bump size
    /// @return result Monotonicity verification result
    function verifyPutMonotonicInVol(PricingParams memory p, SD59x18 epsilon)
        internal
        pure
        returns (MonotonicityResult memory result)
    {
        _validateParams(p);
        _validateEpsilon(epsilon);

        SD59x18 priceLow = pricePut(p);

        PricingParams memory pBumped = _copyParams(p);
        pBumped.volatility = p.volatility.add(epsilon);
        SD59x18 priceHigh = pricePut(pBumped);

        result.lowerValue = priceLow;
        result.upperValue = priceHigh;
        result.greekValue = vega(p);
        // Allow for numerical tolerance
        result.holds = priceHigh.add(NUMERICAL_TOLERANCE).gte(priceLow);
    }

    /// @notice Asserts call vega monotonicity; reverts if violated
    /// @param p Pricing parameters
    /// @param epsilon The volatility bump size
    function assertCallMonotonicInVol(PricingParams memory p, SD59x18 epsilon) internal pure {
        MonotonicityResult memory res = verifyCallMonotonicInVol(p, epsilon);
        if (!res.holds) {
            revert Certoraspec__PriceNotMonotonicInVol(res.lowerValue, res.upperValue);
        }
    }

    /// @notice Asserts put vega monotonicity; reverts if violated
    /// @param p Pricing parameters
    /// @param epsilon The volatility bump size
    function assertPutMonotonicInVol(PricingParams memory p, SD59x18 epsilon) internal pure {
        MonotonicityResult memory res = verifyPutMonotonicInVol(p, epsilon);
        if (!res.holds) {
            revert Certoraspec__PriceNotMonotonicInVol(res.lowerValue, res.upperValue);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPOSITE VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Runs all three monotonicity invariants for a given parameter set
    /// @dev Convenience function that checks all invariants in one call
    /// @param p Pricing parameters
    /// @param epsilon Bump size for finite-difference checks
    /// @return callSpotOk True if ∂C/∂S > 0 holds
    /// @return putSpotOk True if ∂P/∂S < 0 holds
    /// @return vegaOk True if ∂/∂σ > 0 holds (both call and put)
    function verifyAllInvariants(PricingParams memory p, SD59x18 epsilon)
        internal
        pure
        returns (bool callSpotOk, bool putSpotOk, bool vegaOk)
    {
        _validateParams(p);
        _validateEpsilon(epsilon);

        MonotonicityResult memory callSpot = verifyCallMonotonicInSpot(p, epsilon);
        MonotonicityResult memory putSpot = verifyPutMonotonicInSpot(p, epsilon);
        MonotonicityResult memory callVol = verifyCallMonotonicInVol(p, epsilon);
        MonotonicityResult memory putVol = verifyPutMonotonicInVol(p, epsilon);

        callSpotOk = callSpot.holds;
        putSpotOk = putSpot.holds;
        vegaOk = callVol.holds && putVol.holds;
    }

    /// @notice Asserts all three invariants; reverts on first violation
    /// @param p Pricing parameters
    /// @param epsilon Bump size for finite-difference checks
    function assertAllInvariants(PricingParams memory p, SD59x18 epsilon) internal pure {
        assertCallMonotonicInSpot(p, epsilon);
        assertPutMonotonicInSpot(p, epsilon);
        assertCallMonotonicInVol(p, epsilon);
        assertPutMonotonicInVol(p, epsilon);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PUT-CALL PARITY CHECK
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies put-call parity: C − P = S − K·e^(−rT)
    /// @dev Checks |C − P − (S − K·e^(−rT))| ≤ tolerance
    /// @param p Pricing parameters
    /// @param tolerance Maximum acceptable deviation (in SD59x18)
    /// @return holds True if parity holds within tolerance
    /// @return deviation The actual absolute deviation
    function verifyPutCallParity(PricingParams memory p, SD59x18 tolerance)
        internal
        pure
        returns (bool holds, SD59x18 deviation)
    {
        _validateParams(p);

        SD59x18 callPrice = priceCall(p);
        SD59x18 putPrice = pricePut(p);
        SD59x18 discount = p.riskFreeRate.mul(p.timeToExpiry).mul(sd(-1e18)).exp();

        // C - P should equal S - K * e^(-rT)
        SD59x18 lhs = callPrice.sub(putPrice);
        SD59x18 rhs = p.spot.sub(p.strike.mul(discount));

        deviation = lhs.sub(rhs).abs();
        holds = deviation.lte(tolerance);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DELTA BOUNDS VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies call delta is in (0, 1)
    /// @param p Pricing parameters
    /// @return inBounds True if 0 < Δ_call < 1
    /// @return delta The computed call delta
    function verifyCallDeltaBounds(PricingParams memory p) internal pure returns (bool inBounds, SD59x18 delta) {
        _validateParams(p);
        delta = callDelta(p);
        inBounds = delta.gt(ZERO) && delta.lt(sd(1e18));
    }

    /// @notice Verifies put delta is in (−1, 0)
    /// @param p Pricing parameters
    /// @return inBounds True if −1 < Δ_put < 0
    /// @return delta The computed put delta
    function verifyPutDeltaBounds(PricingParams memory p) internal pure returns (bool inBounds, SD59x18 delta) {
        _validateParams(p);
        delta = putDelta(p);
        inBounds = delta.gt(sd(-1e18)) && delta.lt(ZERO);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GAMMA POSITIVITY VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies gamma > 0 (option convexity)
    /// @dev Γ = φ(d1) / (S·σ·√T) > 0 since all components are positive
    /// @param p Pricing parameters
    /// @return result True if gamma is strictly positive
    /// @return gammaValue The computed gamma
    function verifyGammaPositive(PricingParams memory p) internal pure returns (bool result, SD59x18 gammaValue) {
        _validateParams(p);
        gammaValue = gamma(p);
        result = gammaValue.gt(ZERO);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER: PARAMETER VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates all pricing parameters
    /// @param p The pricing parameters to validate
    function validateParams(PricingParams memory p) internal pure {
        _validateParams(p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Internal parameter validation
    function _validateParams(PricingParams memory p) private pure {
        if (p.spot.lte(ZERO)) {
            revert Certoraspec__InvalidSpotPrice(p.spot);
        }
        if (p.strike.lte(ZERO)) {
            revert Certoraspec__InvalidStrikePrice(p.strike);
        }
        if (p.volatility.lte(ZERO)) {
            revert Certoraspec__InvalidVolatility(p.volatility);
        }
        if (p.timeToExpiry.lte(ZERO)) {
            revert Certoraspec__InvalidTimeToExpiry(p.timeToExpiry);
        }
        if (p.riskFreeRate.lt(ZERO)) {
            revert Certoraspec__InvalidRiskFreeRate(p.riskFreeRate);
        }
    }

    /// @notice Internal epsilon validation
    function _validateEpsilon(SD59x18 epsilon) private pure {
        if (epsilon.lte(ZERO)) {
            revert Certoraspec__InvalidEpsilon(epsilon);
        }
    }

    /// @notice Deep-copies pricing params to avoid mutating the original
    function _copyParams(PricingParams memory p) private pure returns (PricingParams memory copy) {
        copy = PricingParams({
            spot: p.spot,
            strike: p.strike,
            volatility: p.volatility,
            riskFreeRate: p.riskFreeRate,
            timeToExpiry: p.timeToExpiry
        });
    }
}
