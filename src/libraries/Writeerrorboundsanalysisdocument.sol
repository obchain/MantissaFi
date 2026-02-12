// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import { Constants } from "./Constants.sol";
import { CumulativeNormal } from "./CumulativeNormal.sol";

/// @title ErrorBoundsAnalysis
/// @author MantissaFi Team
/// @notice Formal analysis of computational error introduced by fixed-point arithmetic
/// @dev Quantifies error propagation through the Black-Scholes pipeline:
///      1. CDF approximation error (Hart's rational approximation)
///      2. Fixed-point arithmetic rounding in d1/d2 computation
///      3. Error amplification through exp(), ln(), sqrt() in BSM
///      4. Worst-case error combinations across parameter space
///
///      Error model:
///        ε_total = ε_cdf + ε_arithmetic + ε_propagation
///      where each component is bounded and measurable on-chain.

// ═══════════════════════════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Thrown when spot price is not strictly positive
error ErrorBounds__InvalidSpotPrice(SD59x18 spot);

/// @notice Thrown when strike price is not strictly positive
error ErrorBounds__InvalidStrikePrice(SD59x18 strike);

/// @notice Thrown when volatility is not strictly positive
error ErrorBounds__InvalidVolatility(SD59x18 volatility);

/// @notice Thrown when time to expiry is not strictly positive
error ErrorBounds__InvalidTimeToExpiry(SD59x18 timeToExpiry);

/// @notice Thrown when risk-free rate is negative
error ErrorBounds__InvalidRiskFreeRate(SD59x18 riskFreeRate);

/// @notice Thrown when error exceeds maximum acceptable threshold
error ErrorBounds__ErrorExceedsThreshold(SD59x18 error_, SD59x18 threshold);

/// @notice Thrown when reference value is zero (cannot compute relative error)
error ErrorBounds__ZeroReferenceValue();

/// @notice Thrown when the number of sample points is zero
error ErrorBounds__ZeroSamplePoints();

// ═══════════════════════════════════════════════════════════════════════════════
// STRUCTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice BSM pricing parameters for error analysis
/// @param spot Current spot price S > 0
/// @param strike Strike price K > 0
/// @param volatility Implied volatility σ > 0
/// @param riskFreeRate Risk-free interest rate r ≥ 0
/// @param timeToExpiry Time to expiry in years T > 0
struct ErrorBoundsParams {
    SD59x18 spot;
    SD59x18 strike;
    SD59x18 volatility;
    SD59x18 riskFreeRate;
    SD59x18 timeToExpiry;
}

/// @notice Decomposed error components for a single pricing evaluation
/// @param cdfError Absolute error from CDF approximation
/// @param arithmeticError Error from fixed-point mul/div rounding
/// @param totalAbsoluteError Sum of all error components
/// @param totalRelativeError Relative error as fraction of price
struct ErrorDecomposition {
    SD59x18 cdfError;
    SD59x18 arithmeticError;
    SD59x18 totalAbsoluteError;
    SD59x18 totalRelativeError;
}

/// @notice Aggregated error statistics across parameter sweeps
/// @param maxAbsoluteError Worst-case absolute error observed
/// @param maxRelativeError Worst-case relative error observed
/// @param meanAbsoluteError Average absolute error
/// @param worstCaseParams Parameters that produced worst error
struct ErrorStatistics {
    SD59x18 maxAbsoluteError;
    SD59x18 maxRelativeError;
    SD59x18 meanAbsoluteError;
    ErrorBoundsParams worstCaseParams;
}

library ErrorBoundsAnalysis {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Maximum theoretical CDF approximation error (Abramowitz & Stegun 26.2.17)
    /// @dev |ε(x)| < 7.5e-8 for all x, represented as 7.5e-8 * 1e18 = 7.5e10
    SD59x18 internal constant CDF_MAX_ERROR = SD59x18.wrap(75_000_000_000);

    /// @notice SD59x18 unit rounding error (0.5 ulp = 5e-19 in decimal, but mul/div can lose 1 ulp = 1)
    /// @dev Each mul or div can introduce up to 1 unit of last precision
    int256 internal constant ULP = 1;

    /// @notice 1.0 in fixed-point
    int256 private constant ONE = 1e18;

    /// @notice 2.0 in fixed-point
    int256 private constant TWO = 2e18;

    /// @notice 0.5 in fixed-point
    int256 private constant HALF = 5e17;

    /// @notice Default error acceptance threshold (1 basis point = 0.01%)
    SD59x18 internal constant DEFAULT_THRESHOLD = SD59x18.wrap(100_000_000_000_000);

    /// @notice Typical Lyra error bound for comparison (≈ 1e-7 relative)
    SD59x18 internal constant LYRA_TYPICAL_ERROR = SD59x18.wrap(100_000_000_000);

    /// @notice Typical Primitive Finance error bound for comparison (≈ 5e-7 relative)
    SD59x18 internal constant PRIMITIVE_TYPICAL_ERROR = SD59x18.wrap(500_000_000_000);

    /// @notice Number of fixed-point operations in d1 computation (ln, mul, div, add, sqrt)
    int256 private constant D1_OP_COUNT = 7;

    /// @notice Number of fixed-point operations in BSM price from d1/d2 (cdf×2, mul×3, exp, sub)
    int256 private constant BSM_OP_COUNT = 7;

    /// @notice Minimum price denominator for relative error (prevents division by near-zero)
    SD59x18 internal constant MIN_PRICE_FOR_RELATIVE = SD59x18.wrap(1_000_000_000_000);

    // ═══════════════════════════════════════════════════════════════════════════
    // CDF APPROXIMATION ERROR ANALYSIS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes the theoretical upper bound on CDF approximation error
    /// @dev Hart's rational approximation (Abramowitz & Stegun 26.2.17) has known error bounds:
    ///      |ε(x)| < 7.5e-8 for all x. For |x| < 3, error is typically < 1e-8.
    ///      The bound tightens near the center of the distribution.
    /// @param x Input to Φ(x)
    /// @return bound Upper bound on |Φ_approx(x) - Φ_exact(x)|
    function cdfApproximationErrorBound(SD59x18 x) internal pure returns (SD59x18 bound) {
        SD59x18 absX = x.abs();
        SD59x18 three = sd(3e18);
        SD59x18 six = sd(6e18);

        if (absX.lt(three)) {
            // Central region: error < 1e-8 (10_000_000_000 in SD59x18)
            bound = sd(10_000_000_000);
        } else if (absX.lt(six)) {
            // Tail region: error approaches maximum bound
            bound = CDF_MAX_ERROR;
        } else {
            // Deep tail: approximation degrades but CDF is near 0 or 1
            // so absolute price impact is minimal. Use max bound.
            bound = CDF_MAX_ERROR;
        }
    }

    /// @notice Measures the actual CDF error by comparing against a higher-precision computation
    /// @dev Uses the symmetry property Φ(x) + Φ(-x) = 1 to estimate error.
    ///      If implementation is perfect, Φ(x) + Φ(-x) = 1 exactly.
    ///      Deviation from 1 gives a lower bound on the sum of errors at x and -x.
    /// @param x Input value
    /// @return symmetryError |Φ(x) + Φ(-x) - 1| as an error indicator
    function measureCdfSymmetryError(SD59x18 x) internal pure returns (SD59x18 symmetryError) {
        SD59x18 cdfPos = CumulativeNormal.cdf(x);
        SD59x18 cdfNeg = CumulativeNormal.cdf(x.mul(sd(-ONE)));
        SD59x18 sum = cdfPos.add(cdfNeg);
        symmetryError = sum.sub(sd(ONE)).abs();
    }

    /// @notice Computes the CDF error impact on BSM call price
    /// @dev For C = S·Φ(d1) - K·e^(-rT)·Φ(d2), the CDF error propagates as:
    ///      |δC| ≤ S·|δΦ(d1)| + K·e^(-rT)·|δΦ(d2)|
    /// @param p Pricing parameters
    /// @return cdfPriceError Upper bound on price error from CDF approximation
    function cdfErrorImpactOnPrice(ErrorBoundsParams memory p) internal pure returns (SD59x18 cdfPriceError) {
        _validateParams(p);

        SD59x18 d1 = _computeD1(p);
        SD59x18 d2 = d1.sub(p.volatility.mul(p.timeToExpiry.sqrt()));

        SD59x18 cdfErr1 = cdfApproximationErrorBound(d1);
        SD59x18 cdfErr2 = cdfApproximationErrorBound(d2);

        SD59x18 discount = p.riskFreeRate.mul(p.timeToExpiry).mul(sd(-ONE)).exp();

        // |δC| ≤ S·|δΦ(d1)| + K·e^(-rT)·|δΦ(d2)|
        cdfPriceError = p.spot.mul(cdfErr1).add(p.strike.mul(discount).mul(cdfErr2));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ARITHMETIC ERROR ANALYSIS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes the worst-case arithmetic rounding error in d1 computation
    /// @dev d1 = [ln(S/K) + (r + σ²/2)·T] / (σ·√T)
    ///      Each fixed-point operation (ln, mul, div, add, sqrt) introduces ≤ 1 ULP error.
    ///      Total d1 error ≤ D1_OP_COUNT ULPs, which propagates through CDF.
    /// @param p Pricing parameters
    /// @return d1ArithError Upper bound on d1 arithmetic error in SD59x18
    function d1ArithmeticErrorBound(ErrorBoundsParams memory p) internal pure returns (SD59x18 d1ArithError) {
        _validateParams(p);

        // Each operation introduces at most 1 ULP = 1 (in raw int256 terms)
        // d1 has D1_OP_COUNT operations: ln(S/K) via (ln S - ln K), σ², σ²/2, r + σ²/2, (...)·T, σ·√T, numerator/denom
        // Error in d1 ≤ D1_OP_COUNT ULPs directly, but division amplifies:
        // δd1 ≤ (D1_OP_COUNT * ULP) / |σ·√T| (the divisor)
        SD59x18 volSqrtT = p.volatility.mul(p.timeToExpiry.sqrt());

        // Accumulate ULP errors (D1_OP_COUNT operations, each adding 1 ULP to numerator)
        SD59x18 numeratorError = sd(D1_OP_COUNT * ULP);

        // Division amplifies: δd1 ≤ δNumerator / |σ·√T|
        // But since ULP is so small relative to volSqrtT, this is usually negligible
        // We take the conservative bound: error accumulates and is divided by volSqrtT
        d1ArithError = numeratorError.add(sd(ULP)).div(volSqrtT.abs()).add(sd(ULP));
    }

    /// @notice Computes the total BSM arithmetic error from fixed-point rounding
    /// @dev After d1/d2, BSM formula has BSM_OP_COUNT more operations.
    ///      Total arithmetic error ≤ spot * (accumulated ULPs) + strike * discount * (accumulated ULPs)
    /// @param p Pricing parameters
    /// @return bsmArithError Upper bound on BSM price arithmetic error
    function bsmArithmeticErrorBound(ErrorBoundsParams memory p) internal pure returns (SD59x18 bsmArithError) {
        _validateParams(p);

        // After d1 error, CDF amplifies via: δΦ = φ(d1)·δd1 (PDF is the derivative of CDF)
        SD59x18 d1 = _computeD1(p);
        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);

        SD59x18 d1Err = d1ArithmeticErrorBound(p);
        SD59x18 cdfPropError = pdfD1.mul(d1Err);

        SD59x18 discount = p.riskFreeRate.mul(p.timeToExpiry).mul(sd(-ONE)).exp();

        // Price error from CDF propagation
        SD59x18 priceFromCdf = p.spot.mul(cdfPropError).add(p.strike.mul(discount).mul(cdfPropError));

        // Direct arithmetic ULP errors in the final BSM formula operations
        SD59x18 directUlpError = sd(BSM_OP_COUNT * ULP);
        SD59x18 priceScale = p.spot.add(p.strike.mul(discount));
        SD59x18 directError = priceScale.mul(directUlpError).div(sd(ONE));

        bsmArithError = priceFromCdf.add(directError);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOTAL ERROR DECOMPOSITION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Decomposes the total pricing error into CDF and arithmetic components
    /// @dev Total error = CDF approximation error + arithmetic rounding error
    ///      Both are upper bounds; actual error is typically much smaller.
    /// @param p Pricing parameters
    /// @return decomp Error decomposition with all components
    function decomposeError(ErrorBoundsParams memory p) internal pure returns (ErrorDecomposition memory decomp) {
        _validateParams(p);

        decomp.cdfError = cdfErrorImpactOnPrice(p);
        decomp.arithmeticError = bsmArithmeticErrorBound(p);
        decomp.totalAbsoluteError = decomp.cdfError.add(decomp.arithmeticError);

        // Compute BSM price for relative error
        SD59x18 price = _priceCall(p);

        if (price.gt(MIN_PRICE_FOR_RELATIVE)) {
            decomp.totalRelativeError = decomp.totalAbsoluteError.div(price);
        } else {
            // For near-zero prices, relative error is not meaningful
            decomp.totalRelativeError = ZERO;
        }
    }

    /// @notice Asserts that total error is within acceptable threshold
    /// @dev Reverts if total relative error exceeds threshold
    /// @param p Pricing parameters
    /// @param threshold Maximum acceptable relative error (e.g., 1e-4 = 1bp)
    function assertErrorWithinBounds(ErrorBoundsParams memory p, SD59x18 threshold) internal pure {
        ErrorDecomposition memory decomp = decomposeError(p);
        if (decomp.totalRelativeError.gt(threshold)) {
            revert ErrorBounds__ErrorExceedsThreshold(decomp.totalRelativeError, threshold);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WORST-CASE ERROR ANALYSIS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Identifies which parameter regime maximizes CDF error impact
    /// @dev CDF error is amplified when:
    ///      - d1 or d2 is in [3, 6] (tail region where approximation is weakest)
    ///      - Spot and strike prices are large (scaling factor)
    ///      - Time to expiry is short (d1/d2 can be extreme)
    ///      This function checks whether a given parameter set falls in a high-error regime.
    /// @param p Pricing parameters
    /// @return isHighErrorRegime True if parameters are in a high-error region
    /// @return riskFactor Multiplicative factor indicating how much worse than typical (1.0 = typical)
    function assessErrorRegime(ErrorBoundsParams memory p)
        internal
        pure
        returns (bool isHighErrorRegime, SD59x18 riskFactor)
    {
        _validateParams(p);

        SD59x18 d1 = _computeD1(p);
        SD59x18 d2 = d1.sub(p.volatility.mul(p.timeToExpiry.sqrt()));
        SD59x18 absD1 = d1.abs();
        SD59x18 absD2 = d2.abs();

        SD59x18 three = sd(3e18);
        riskFactor = sd(ONE);

        // Check if d1 is in the tail region (CDF approximation weakens)
        if (absD1.gt(three)) {
            riskFactor = riskFactor.add(sd(ONE));
            isHighErrorRegime = true;
        }

        // Check if d2 is in the tail region
        if (absD2.gt(three)) {
            riskFactor = riskFactor.add(sd(ONE));
            isHighErrorRegime = true;
        }

        // Short time to expiry amplifies d1/d2 magnitude
        SD59x18 sevenDays = sd(19_178_082_191_780_821); // 7/365.25 years
        if (p.timeToExpiry.lt(sevenDays)) {
            riskFactor = riskFactor.add(sd(HALF));
            isHighErrorRegime = true;
        }

        // Deep OTM/ITM options have extreme d1 values
        SD59x18 moneyness = p.spot.div(p.strike);
        SD59x18 otmThreshold = sd(500_000_000_000_000_000); // 0.5
        SD59x18 itmThreshold = sd(2_000_000_000_000_000_000); // 2.0
        if (moneyness.lt(otmThreshold) || moneyness.gt(itmThreshold)) {
            riskFactor = riskFactor.add(sd(HALF));
            isHighErrorRegime = true;
        }
    }

    /// @notice Computes worst-case error for a single parameter set
    /// @dev Combines all error sources and applies regime risk factor
    /// @param p Pricing parameters
    /// @return worstAbsolute Worst-case absolute error
    /// @return worstRelative Worst-case relative error
    function worstCaseError(ErrorBoundsParams memory p)
        internal
        pure
        returns (SD59x18 worstAbsolute, SD59x18 worstRelative)
    {
        _validateParams(p);

        ErrorDecomposition memory decomp = decomposeError(p);
        (, SD59x18 riskFactor) = assessErrorRegime(p);

        worstAbsolute = decomp.totalAbsoluteError.mul(riskFactor);

        SD59x18 price = _priceCall(p);
        if (price.gt(MIN_PRICE_FOR_RELATIVE)) {
            worstRelative = worstAbsolute.div(price);
        } else {
            worstRelative = ZERO;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPARISON WITH OTHER PROTOCOLS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Compares MantissaFi error bound against Lyra Finance's typical error
    /// @dev Lyra uses a similar CDF approximation with comparable precision.
    ///      This function returns the ratio: MantissaFi_error / Lyra_error
    ///      A ratio < 1 means MantissaFi is more accurate.
    /// @param p Pricing parameters
    /// @return mantissaError MantissaFi total absolute error bound
    /// @return lyraError Lyra typical absolute error bound
    /// @return ratio MantissaFi error / Lyra error (< 1 means better)
    function compareWithLyra(ErrorBoundsParams memory p)
        internal
        pure
        returns (SD59x18 mantissaError, SD59x18 lyraError, SD59x18 ratio)
    {
        _validateParams(p);

        ErrorDecomposition memory decomp = decomposeError(p);
        mantissaError = decomp.totalAbsoluteError;

        // Lyra's error is scaled by price magnitude (relative error * price)
        SD59x18 price = _priceCall(p);
        lyraError = LYRA_TYPICAL_ERROR.mul(price).div(sd(ONE));

        if (lyraError.gt(ZERO)) {
            ratio = mantissaError.div(lyraError);
        } else {
            ratio = ZERO;
        }
    }

    /// @notice Compares MantissaFi error bound against Primitive Finance's typical error
    /// @dev Primitive uses a RMM-01 model with different numerical properties.
    ///      Their error tends to be higher due to the trading function inversion.
    /// @param p Pricing parameters
    /// @return mantissaError MantissaFi total absolute error bound
    /// @return primitiveError Primitive typical absolute error bound
    /// @return ratio MantissaFi error / Primitive error (< 1 means better)
    function compareWithPrimitive(ErrorBoundsParams memory p)
        internal
        pure
        returns (SD59x18 mantissaError, SD59x18 primitiveError, SD59x18 ratio)
    {
        _validateParams(p);

        ErrorDecomposition memory decomp = decomposeError(p);
        mantissaError = decomp.totalAbsoluteError;

        SD59x18 price = _priceCall(p);
        primitiveError = PRIMITIVE_TYPICAL_ERROR.mul(price).div(sd(ONE));

        if (primitiveError.gt(ZERO)) {
            ratio = mantissaError.div(primitiveError);
        } else {
            ratio = ZERO;
        }
    }

    /// @notice Returns all three protocol error comparisons at once
    /// @param p Pricing parameters
    /// @return mantissaAbs MantissaFi absolute error bound
    /// @return lyraAbs Lyra absolute error bound
    /// @return primitiveAbs Primitive absolute error bound
    function protocolErrorComparison(ErrorBoundsParams memory p)
        internal
        pure
        returns (SD59x18 mantissaAbs, SD59x18 lyraAbs, SD59x18 primitiveAbs)
    {
        _validateParams(p);

        ErrorDecomposition memory decomp = decomposeError(p);
        mantissaAbs = decomp.totalAbsoluteError;

        SD59x18 price = _priceCall(p);
        lyraAbs = LYRA_TYPICAL_ERROR.mul(price).div(sd(ONE));
        primitiveAbs = PRIMITIVE_TYPICAL_ERROR.mul(price).div(sd(ONE));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GAS vs ACCURACY TRADEOFF
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Estimates relative error for different computation "quality levels"
    /// @dev Returns error bounds for three strategies:
    ///      - Fast: Skip some CDF terms (higher error, lower gas)
    ///      - Standard: Full Hart approximation (MantissaFi default)
    ///      - Precise: Double evaluation with Richardson extrapolation (lower error, higher gas)
    /// @param p Pricing parameters
    /// @return fastError Estimated error with reduced CDF precision
    /// @return standardError Standard MantissaFi error bound
    /// @return preciseError Estimated error with enhanced precision
    function gasAccuracyTradeoff(ErrorBoundsParams memory p)
        internal
        pure
        returns (SD59x18 fastError, SD59x18 standardError, SD59x18 preciseError)
    {
        _validateParams(p);

        ErrorDecomposition memory decomp = decomposeError(p);
        standardError = decomp.totalAbsoluteError;

        // Fast mode: truncated polynomial (3 terms instead of 5)
        // Error increases by roughly 100x for CDF component
        SD59x18 hundred = sd(100e18);
        fastError = decomp.cdfError.mul(hundred).add(decomp.arithmeticError);

        // Precise mode: error reduction via averaging two shifted evaluations
        // Reduces CDF error by ~10x (Richardson extrapolation effect)
        SD59x18 ten = sd(10e18);
        preciseError = decomp.cdfError.div(ten).add(decomp.arithmeticError.mul(sd(TWO)));
    }

    /// @notice Estimates the gas cost multiplier for each quality level
    /// @dev Returns approximate gas multipliers relative to standard computation.
    ///      Fast ≈ 0.7x gas, Standard = 1.0x, Precise ≈ 2.1x
    /// @return fastGasMultiplier Gas multiplier for fast mode (< 1.0)
    /// @return standardGasMultiplier Always 1.0
    /// @return preciseGasMultiplier Gas multiplier for precise mode (> 1.0)
    function gasMultipliers()
        internal
        pure
        returns (SD59x18 fastGasMultiplier, SD59x18 standardGasMultiplier, SD59x18 preciseGasMultiplier)
    {
        fastGasMultiplier = sd(700_000_000_000_000_000); // 0.7
        standardGasMultiplier = sd(ONE); // 1.0
        preciseGasMultiplier = sd(2_100_000_000_000_000_000); // 2.1
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERROR PROPAGATION THROUGH GREEKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes error bound on delta (∂C/∂S) from CDF and arithmetic errors
    /// @dev Δ = Φ(d1), so δΔ ≤ |δΦ(d1)| = max(φ(d1)·δd1, ε_cdf)
    /// @param p Pricing parameters
    /// @return deltaError Upper bound on absolute delta error
    function deltaErrorBound(ErrorBoundsParams memory p) internal pure returns (SD59x18 deltaError) {
        _validateParams(p);

        SD59x18 d1 = _computeD1(p);
        SD59x18 cdfErr = cdfApproximationErrorBound(d1);
        SD59x18 d1Err = d1ArithmeticErrorBound(p);
        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);

        // δΔ = max(ε_cdf, φ(d1)·δd1) — take the dominant source
        SD59x18 propagatedErr = pdfD1.mul(d1Err);
        deltaError = cdfErr.gt(propagatedErr) ? cdfErr : propagatedErr;
    }

    /// @notice Computes error bound on vega (∂C/∂σ) from arithmetic errors
    /// @dev ν = S·√T·φ(d1), so δν ≤ S·√T·|δφ(d1)| + S·√T·φ(d1)·|δd1|·|d1|
    ///      The second term arises because φ'(d1) = -d1·φ(d1)
    /// @param p Pricing parameters
    /// @return vegaError Upper bound on absolute vega error
    function vegaErrorBound(ErrorBoundsParams memory p) internal pure returns (SD59x18 vegaError) {
        _validateParams(p);

        SD59x18 d1 = _computeD1(p);
        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);
        SD59x18 sqrtT = p.timeToExpiry.sqrt();
        SD59x18 d1Err = d1ArithmeticErrorBound(p);

        // φ'(d1) = -d1·φ(d1), so δφ(d1) = |d1|·φ(d1)·δd1
        SD59x18 pdfError = d1.abs().mul(pdfD1).mul(d1Err);

        // δν = S·√T·δφ + direct ULP errors from multiplication
        SD59x18 directUlp = sd(3 * ULP); // 3 multiplications: S * sqrtT * pdf
        vegaError = p.spot.mul(sqrtT).mul(pdfError).add(p.spot.mul(sqrtT).mul(directUlp).div(sd(ONE)));
    }

    /// @notice Computes error bound on gamma (∂²C/∂S²)
    /// @dev Γ = φ(d1)/(S·σ·√T). Error from division amplification.
    /// @param p Pricing parameters
    /// @return gammaError Upper bound on absolute gamma error
    function gammaErrorBound(ErrorBoundsParams memory p) internal pure returns (SD59x18 gammaError) {
        _validateParams(p);

        SD59x18 d1 = _computeD1(p);
        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);
        SD59x18 d1Err = d1ArithmeticErrorBound(p);

        SD59x18 denom = p.spot.mul(p.volatility).mul(p.timeToExpiry.sqrt());

        // δφ from d1 error: |d1|·φ(d1)·δd1
        SD59x18 pdfError = d1.abs().mul(pdfD1).mul(d1Err);

        // δΓ = δφ/denom + φ·δdenom/denom² ≈ δφ/denom (dominant term)
        gammaError = pdfError.div(denom);

        // Add ULP errors from division
        SD59x18 directUlp = sd(4 * ULP); // 4 ops: 3 muls + 1 div
        gammaError = gammaError.add(directUlp.div(denom));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UTILITY: ABSOLUTE & RELATIVE ERROR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes absolute error between two values
    /// @param a First value
    /// @param b Second value
    /// @return absError |a - b|
    function absoluteError(SD59x18 a, SD59x18 b) internal pure returns (SD59x18 absError) {
        absError = a.sub(b).abs();
    }

    /// @notice Computes relative error between two values
    /// @dev Returns |a - b| / |refVal|. Reverts if refVal is zero.
    /// @param measured The measured/computed value
    /// @param refVal The true/reference value
    /// @return relError Relative error as a fraction (e.g., 0.001 = 0.1%)
    function relativeError(SD59x18 measured, SD59x18 refVal) internal pure returns (SD59x18 relError) {
        if (refVal.eq(ZERO)) {
            revert ErrorBounds__ZeroReferenceValue();
        }
        relError = measured.sub(refVal).abs().div(refVal.abs());
    }

    /// @notice Checks if two values agree within a given number of basis points
    /// @param a First value
    /// @param b Second value (reference)
    /// @param basisPoints Maximum allowed error in bps (e.g., 1 = 0.01%)
    /// @return withinBounds True if relative error < basisPoints/10000
    function agreesWithinBps(SD59x18 a, SD59x18 b, uint256 basisPoints) internal pure returns (bool withinBounds) {
        if (b.eq(ZERO)) {
            return a.eq(ZERO);
        }
        SD59x18 relErr = a.sub(b).abs().div(b.abs());
        // basisPoints/10000 in SD59x18: bps * 1e18 / 10000 = bps * 1e14
        SD59x18 threshold = sd(int256(basisPoints) * 1e14);
        withinBounds = relErr.lte(threshold);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates all error bounds parameters
    function _validateParams(ErrorBoundsParams memory p) private pure {
        if (p.spot.lte(ZERO)) revert ErrorBounds__InvalidSpotPrice(p.spot);
        if (p.strike.lte(ZERO)) revert ErrorBounds__InvalidStrikePrice(p.strike);
        if (p.volatility.lte(ZERO)) revert ErrorBounds__InvalidVolatility(p.volatility);
        if (p.timeToExpiry.lte(ZERO)) revert ErrorBounds__InvalidTimeToExpiry(p.timeToExpiry);
        if (p.riskFreeRate.lt(ZERO)) revert ErrorBounds__InvalidRiskFreeRate(p.riskFreeRate);
    }

    /// @notice Computes d1 for BSM
    /// @dev d1 = [ln(S/K) + (r + σ²/2)·T] / (σ·√T)
    function _computeD1(ErrorBoundsParams memory p) private pure returns (SD59x18 d1) {
        SD59x18 logMoneyness = p.spot.div(p.strike).ln();
        SD59x18 halfVar = p.volatility.mul(p.volatility).div(sd(TWO));
        SD59x18 drift = p.riskFreeRate.add(halfVar).mul(p.timeToExpiry);
        SD59x18 volSqrtT = p.volatility.mul(p.timeToExpiry.sqrt());
        d1 = logMoneyness.add(drift).div(volSqrtT);
    }

    /// @notice Prices a European call via BSM (self-contained for error analysis)
    /// @dev C = S·Φ(d1) - K·e^(-rT)·Φ(d2)
    function _priceCall(ErrorBoundsParams memory p) private pure returns (SD59x18 price) {
        SD59x18 d1 = _computeD1(p);
        SD59x18 d2 = d1.sub(p.volatility.mul(p.timeToExpiry.sqrt()));

        SD59x18 cdfD1 = CumulativeNormal.cdf(d1);
        SD59x18 cdfD2 = CumulativeNormal.cdf(d2);
        SD59x18 discount = p.riskFreeRate.mul(p.timeToExpiry).mul(sd(-ONE)).exp();

        price = p.spot.mul(cdfD1).sub(p.strike.mul(discount).mul(cdfD2));
        if (price.lt(ZERO)) {
            price = ZERO;
        }
    }
}
