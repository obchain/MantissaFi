// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";

/// @title BacktestLSIVSagainsthistoricalDeribitIVdata
/// @notice Library for backtesting Liquidity-Sensitive Implied Volatility Surface (LSIVS)
///         against historical Deribit IV data
/// @dev Implements LSIVS model: σ_implied(K,T) = σ_realized(T) × [1 + skew(K,S) + utilization_premium(u)]
///      with statistical error metrics (RMSE, MAE, Max Deviation) for calibration
library BacktestLSIVSagainsthistoricalDeribitIVdata {
    // ═══════════════════════════════════════════════════════════════════════════
    // CUSTOM ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when the realized volatility is zero or negative
    error InvalidRealizedVolatility();

    /// @notice Thrown when the spot price is zero or negative
    error InvalidSpotPrice();

    /// @notice Thrown when the strike price is zero or negative
    error InvalidStrikePrice();

    /// @notice Thrown when time to expiry is zero or negative
    error InvalidTimeToExpiry();

    /// @notice Thrown when utilization ratio is out of bounds [0, 1)
    error InvalidUtilizationRatio();

    /// @notice Thrown when array lengths do not match
    error ArrayLengthMismatch();

    /// @notice Thrown when arrays are empty
    error EmptyArrays();

    /// @notice Thrown when skew coefficient is invalid
    error InvalidSkewCoefficient();

    /// @notice Thrown when gamma coefficient is out of bounds
    error InvalidGammaCoefficient();

    /// @notice Thrown when computing sqrt of negative number
    error NegativeSqrtInput();

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fixed-point representation of 1.0
    int256 private constant ONE = 1e18;

    /// @notice Fixed-point representation of 0.5
    int256 private constant HALF = 5e17;

    /// @notice Fixed-point representation of 2.0
    int256 private constant TWO = 2e18;

    /// @notice Default skew coefficient for ATM options (0.25)
    int256 internal constant DEFAULT_SKEW_COEFFICIENT = 25e16;

    /// @notice Default gamma for utilization premium (0.1)
    int256 internal constant DEFAULT_GAMMA = 1e17;

    /// @notice Maximum utilization ratio (0.999 to prevent division by zero)
    int256 internal constant MAX_UTILIZATION = 999e15;

    /// @notice Minimum IV floor (1% annualized)
    int256 internal constant MIN_IV = 1e16;

    /// @notice Maximum IV ceiling (500% annualized)
    int256 internal constant MAX_IV = 5e18;

    // ═══════════════════════════════════════════════════════════════════════════
    // DATA STRUCTURES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Parameters for LSIVS model calibration
    /// @param skewCoefficient Controls the magnitude of volatility skew
    /// @param gamma Controls the utilization premium sensitivity
    /// @param atmAdjustment Additive adjustment for ATM volatility
    /// @param termStructureCoeff Coefficient for time-dependent vol adjustment
    struct CalibrationParams {
        SD59x18 skewCoefficient;
        SD59x18 gamma;
        SD59x18 atmAdjustment;
        SD59x18 termStructureCoeff;
    }

    /// @notice Input data point for backtesting
    /// @param spotPrice Current underlying price
    /// @param strikePrice Option strike price
    /// @param timeToExpiry Time to expiration in years (SD59x18)
    /// @param realizedVol Realized volatility (annualized, SD59x18)
    /// @param utilization Pool utilization ratio [0, 1)
    /// @param deribitIV Historical Deribit IV for comparison
    struct DataPoint {
        SD59x18 spotPrice;
        SD59x18 strikePrice;
        SD59x18 timeToExpiry;
        SD59x18 realizedVol;
        SD59x18 utilization;
        SD59x18 deribitIV;
    }

    /// @notice Error metrics from backtesting
    /// @param rmse Root Mean Squared Error
    /// @param mae Mean Absolute Error
    /// @param maxDeviation Maximum absolute deviation observed
    /// @param meanBias Mean signed error (positive = overestimate)
    struct ErrorMetrics {
        SD59x18 rmse;
        SD59x18 mae;
        SD59x18 maxDeviation;
        SD59x18 meanBias;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE LSIVS MODEL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes LSIVS implied volatility for given parameters
    /// @dev σ_implied = σ_realized × [1 + skew(K,S) + util_premium(u)] + atm_adj + term_adj
    /// @param spotPrice Current spot price of underlying
    /// @param strikePrice Strike price of the option
    /// @param timeToExpiry Time to expiration in years
    /// @param realizedVol Annualized realized volatility
    /// @param utilization Pool utilization ratio [0, 1)
    /// @param params Calibration parameters
    /// @return impliedVol The computed implied volatility (clamped to [MIN_IV, MAX_IV])
    function computeLSIVS(
        SD59x18 spotPrice,
        SD59x18 strikePrice,
        SD59x18 timeToExpiry,
        SD59x18 realizedVol,
        SD59x18 utilization,
        CalibrationParams memory params
    ) internal pure returns (SD59x18 impliedVol) {
        // Validate inputs
        if (realizedVol.lte(ZERO)) revert InvalidRealizedVolatility();
        if (spotPrice.lte(ZERO)) revert InvalidSpotPrice();
        if (strikePrice.lte(ZERO)) revert InvalidStrikePrice();
        if (timeToExpiry.lte(ZERO)) revert InvalidTimeToExpiry();
        if (utilization.lt(ZERO) || utilization.gte(sd(ONE))) revert InvalidUtilizationRatio();

        // Compute moneyness: ln(K/S)
        SD59x18 moneyness = strikePrice.div(spotPrice).ln();

        // Compute skew component: skewCoeff × moneyness²
        // This creates a smile with higher IV for OTM options
        SD59x18 skewComponent = computeSkew(moneyness, params.skewCoefficient);

        // Compute utilization premium: γ × u / (1 - u)
        SD59x18 utilPremium = computeUtilizationPremium(utilization, params.gamma);

        // Compute term structure adjustment: termCoeff × √T
        SD59x18 termAdjustment = computeTermStructureAdjustment(timeToExpiry, params.termStructureCoeff);

        // Combine all components
        // σ_implied = σ_realized × (1 + skew + util_premium) + atm_adj + term_adj
        SD59x18 multiplier = sd(ONE).add(skewComponent).add(utilPremium);
        impliedVol = realizedVol.mul(multiplier).add(params.atmAdjustment).add(termAdjustment);

        // Clamp to valid IV range
        impliedVol = clampIV(impliedVol);
    }

    /// @notice Computes implied volatility with default calibration parameters
    /// @param spotPrice Current spot price
    /// @param strikePrice Option strike price
    /// @param timeToExpiry Time to expiration in years
    /// @param realizedVol Annualized realized volatility
    /// @param utilization Pool utilization ratio
    /// @return impliedVol The computed implied volatility
    function computeLSIVSDefault(
        SD59x18 spotPrice,
        SD59x18 strikePrice,
        SD59x18 timeToExpiry,
        SD59x18 realizedVol,
        SD59x18 utilization
    ) internal pure returns (SD59x18 impliedVol) {
        CalibrationParams memory defaultParams = CalibrationParams({
            skewCoefficient: sd(DEFAULT_SKEW_COEFFICIENT),
            gamma: sd(DEFAULT_GAMMA),
            atmAdjustment: ZERO,
            termStructureCoeff: ZERO
        });
        return computeLSIVS(spotPrice, strikePrice, timeToExpiry, realizedVol, utilization, defaultParams);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPONENT FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes the volatility skew component based on moneyness
    /// @dev Uses quadratic skew model: skewCoeff × moneyness²
    /// @param moneyness Log-moneyness ln(K/S)
    /// @param skewCoeff Skew coefficient (controls smile steepness)
    /// @return skew The skew adjustment
    function computeSkew(SD59x18 moneyness, SD59x18 skewCoeff) internal pure returns (SD59x18 skew) {
        // Quadratic skew creates a symmetric smile
        // For put skew dominance, could add linear term: skewCoeff × (α × m + β × m²)
        skew = skewCoeff.mul(moneyness.mul(moneyness));
    }

    /// @notice Computes the utilization premium component
    /// @dev util_premium = γ × u / (1 - u)
    ///      This creates convex increase as utilization approaches 1
    /// @param utilization Pool utilization ratio [0, 1)
    /// @param gamma Sensitivity coefficient
    /// @return premium The utilization premium
    function computeUtilizationPremium(SD59x18 utilization, SD59x18 gamma) internal pure returns (SD59x18 premium) {
        if (utilization.gte(sd(MAX_UTILIZATION))) {
            utilization = sd(MAX_UTILIZATION);
        }

        // premium = γ × u / (1 - u)
        SD59x18 denominator = sd(ONE).sub(utilization);
        premium = gamma.mul(utilization).div(denominator);
    }

    /// @notice Computes term structure adjustment
    /// @dev Adjusts IV based on time to expiry: termCoeff × √T
    /// @param timeToExpiry Time to expiration in years
    /// @param termCoeff Term structure coefficient
    /// @return adjustment The term structure adjustment
    function computeTermStructureAdjustment(SD59x18 timeToExpiry, SD59x18 termCoeff)
        internal
        pure
        returns (SD59x18 adjustment)
    {
        // √T scaling for term structure
        SD59x18 sqrtT = timeToExpiry.sqrt();
        adjustment = termCoeff.mul(sqrtT);
    }

    /// @notice Clamps implied volatility to valid bounds
    /// @param iv Input implied volatility
    /// @return clamped IV within [MIN_IV, MAX_IV]
    function clampIV(SD59x18 iv) internal pure returns (SD59x18) {
        if (iv.lt(sd(MIN_IV))) {
            return sd(MIN_IV);
        }
        if (iv.gt(sd(MAX_IV))) {
            return sd(MAX_IV);
        }
        return iv;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BACKTESTING FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Runs backtest on a batch of data points and computes error metrics
    /// @param dataPoints Array of historical data points to test against
    /// @param params Calibration parameters to use
    /// @return metrics Computed error metrics (RMSE, MAE, Max Deviation, Mean Bias)
    function runBacktest(DataPoint[] memory dataPoints, CalibrationParams memory params)
        internal
        pure
        returns (ErrorMetrics memory metrics)
    {
        uint256 n = dataPoints.length;
        if (n == 0) revert EmptyArrays();

        SD59x18 sumSquaredError = ZERO;
        SD59x18 sumAbsError = ZERO;
        SD59x18 sumError = ZERO;
        SD59x18 maxDev = ZERO;

        for (uint256 i = 0; i < n; i++) {
            DataPoint memory dp = dataPoints[i];

            // Compute LSIVS prediction
            SD59x18 predicted =
                computeLSIVS(dp.spotPrice, dp.strikePrice, dp.timeToExpiry, dp.realizedVol, dp.utilization, params);

            // Compute error
            SD59x18 error = predicted.sub(dp.deribitIV);
            SD59x18 absError = error.abs();

            // Accumulate metrics
            sumSquaredError = sumSquaredError.add(error.mul(error));
            sumAbsError = sumAbsError.add(absError);
            sumError = sumError.add(error);

            // Track max deviation
            if (absError.gt(maxDev)) {
                maxDev = absError;
            }
        }

        SD59x18 count = sd(int256(n) * ONE);

        // RMSE = √(Σ(error²) / n)
        metrics.rmse = sumSquaredError.div(count).sqrt();

        // MAE = Σ|error| / n
        metrics.mae = sumAbsError.div(count);

        // Max Deviation
        metrics.maxDeviation = maxDev;

        // Mean Bias = Σ(error) / n
        metrics.meanBias = sumError.div(count);
    }

    /// @notice Computes error metrics for arrays of predicted and actual IVs
    /// @param predictedIVs Array of LSIVS predictions
    /// @param actualIVs Array of historical Deribit IVs
    /// @return metrics Computed error metrics
    function computeErrorMetrics(SD59x18[] memory predictedIVs, SD59x18[] memory actualIVs)
        internal
        pure
        returns (ErrorMetrics memory metrics)
    {
        uint256 n = predictedIVs.length;
        if (n == 0) revert EmptyArrays();
        if (n != actualIVs.length) revert ArrayLengthMismatch();

        SD59x18 sumSquaredError = ZERO;
        SD59x18 sumAbsError = ZERO;
        SD59x18 sumError = ZERO;
        SD59x18 maxDev = ZERO;

        for (uint256 i = 0; i < n; i++) {
            SD59x18 error = predictedIVs[i].sub(actualIVs[i]);
            SD59x18 absError = error.abs();

            sumSquaredError = sumSquaredError.add(error.mul(error));
            sumAbsError = sumAbsError.add(absError);
            sumError = sumError.add(error);

            if (absError.gt(maxDev)) {
                maxDev = absError;
            }
        }

        SD59x18 count = sd(int256(n) * ONE);

        metrics.rmse = sumSquaredError.div(count).sqrt();
        metrics.mae = sumAbsError.div(count);
        metrics.maxDeviation = maxDev;
        metrics.meanBias = sumError.div(count);
    }

    /// @notice Computes Root Mean Squared Error between predictions and actuals
    /// @param predictedIVs Array of predicted IVs
    /// @param actualIVs Array of actual IVs
    /// @return rmse The RMSE value
    function computeRMSE(SD59x18[] memory predictedIVs, SD59x18[] memory actualIVs)
        internal
        pure
        returns (SD59x18 rmse)
    {
        uint256 n = predictedIVs.length;
        if (n == 0) revert EmptyArrays();
        if (n != actualIVs.length) revert ArrayLengthMismatch();

        SD59x18 sumSquaredError = ZERO;
        for (uint256 i = 0; i < n; i++) {
            SD59x18 error = predictedIVs[i].sub(actualIVs[i]);
            sumSquaredError = sumSquaredError.add(error.mul(error));
        }

        rmse = sumSquaredError.div(sd(int256(n) * ONE)).sqrt();
    }

    /// @notice Computes Mean Absolute Error between predictions and actuals
    /// @param predictedIVs Array of predicted IVs
    /// @param actualIVs Array of actual IVs
    /// @return mae The MAE value
    function computeMAE(SD59x18[] memory predictedIVs, SD59x18[] memory actualIVs)
        internal
        pure
        returns (SD59x18 mae)
    {
        uint256 n = predictedIVs.length;
        if (n == 0) revert EmptyArrays();
        if (n != actualIVs.length) revert ArrayLengthMismatch();

        SD59x18 sumAbsError = ZERO;
        for (uint256 i = 0; i < n; i++) {
            SD59x18 absError = predictedIVs[i].sub(actualIVs[i]).abs();
            sumAbsError = sumAbsError.add(absError);
        }

        mae = sumAbsError.div(sd(int256(n) * ONE));
    }

    /// @notice Computes maximum absolute deviation between predictions and actuals
    /// @param predictedIVs Array of predicted IVs
    /// @param actualIVs Array of actual IVs
    /// @return maxDev The maximum deviation
    function computeMaxDeviation(SD59x18[] memory predictedIVs, SD59x18[] memory actualIVs)
        internal
        pure
        returns (SD59x18 maxDev)
    {
        uint256 n = predictedIVs.length;
        if (n == 0) revert EmptyArrays();
        if (n != actualIVs.length) revert ArrayLengthMismatch();

        maxDev = ZERO;
        for (uint256 i = 0; i < n; i++) {
            SD59x18 absError = predictedIVs[i].sub(actualIVs[i]).abs();
            if (absError.gt(maxDev)) {
                maxDev = absError;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CALIBRATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Creates default calibration parameters
    /// @return params Default CalibrationParams struct
    function defaultCalibrationParams() internal pure returns (CalibrationParams memory params) {
        params = CalibrationParams({
            skewCoefficient: sd(DEFAULT_SKEW_COEFFICIENT),
            gamma: sd(DEFAULT_GAMMA),
            atmAdjustment: ZERO,
            termStructureCoeff: ZERO
        });
    }

    /// @notice Validates calibration parameters
    /// @param params The parameters to validate
    /// @return valid True if parameters are within acceptable bounds
    function validateCalibrationParams(CalibrationParams memory params) internal pure returns (bool valid) {
        // Skew coefficient should be non-negative and reasonable
        if (params.skewCoefficient.lt(ZERO) || params.skewCoefficient.gt(sd(ONE))) {
            return false;
        }

        // Gamma should be non-negative and bounded
        if (params.gamma.lt(ZERO) || params.gamma.gt(sd(ONE))) {
            return false;
        }

        // ATM adjustment shouldn't be extreme (±50%)
        if (params.atmAdjustment.lt(sd(-HALF)) || params.atmAdjustment.gt(sd(HALF))) {
            return false;
        }

        // Term structure coefficient bounded
        if (params.termStructureCoeff.lt(sd(-HALF)) || params.termStructureCoeff.gt(sd(HALF))) {
            return false;
        }

        return true;
    }

    /// @notice Computes moneyness (log-moneyness) for an option
    /// @param spotPrice Current spot price
    /// @param strikePrice Option strike price
    /// @return moneyness ln(K/S) value
    function computeMoneyness(SD59x18 spotPrice, SD59x18 strikePrice) internal pure returns (SD59x18 moneyness) {
        if (spotPrice.lte(ZERO)) revert InvalidSpotPrice();
        if (strikePrice.lte(ZERO)) revert InvalidStrikePrice();

        moneyness = strikePrice.div(spotPrice).ln();
    }

    /// @notice Computes forward moneyness accounting for time value
    /// @param spotPrice Current spot price
    /// @param strikePrice Option strike price
    /// @param timeToExpiry Time to expiration in years
    /// @param realizedVol Realized volatility (annualized)
    /// @return fwdMoneyness Forward log-moneyness normalized by vol√T
    function computeForwardMoneyness(SD59x18 spotPrice, SD59x18 strikePrice, SD59x18 timeToExpiry, SD59x18 realizedVol)
        internal
        pure
        returns (SD59x18 fwdMoneyness)
    {
        if (spotPrice.lte(ZERO)) revert InvalidSpotPrice();
        if (strikePrice.lte(ZERO)) revert InvalidStrikePrice();
        if (timeToExpiry.lte(ZERO)) revert InvalidTimeToExpiry();
        if (realizedVol.lte(ZERO)) revert InvalidRealizedVolatility();

        SD59x18 logMoneyness = strikePrice.div(spotPrice).ln();
        SD59x18 volSqrtT = realizedVol.mul(timeToExpiry.sqrt());

        fwdMoneyness = logMoneyness.div(volSqrtT);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STATISTICAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes the mean of an array of values
    /// @param values Array of SD59x18 values
    /// @return mean The arithmetic mean
    function computeMean(SD59x18[] memory values) internal pure returns (SD59x18 mean) {
        uint256 n = values.length;
        if (n == 0) revert EmptyArrays();

        SD59x18 sum = ZERO;
        for (uint256 i = 0; i < n; i++) {
            sum = sum.add(values[i]);
        }

        mean = sum.div(sd(int256(n) * ONE));
    }

    /// @notice Computes the variance of an array of values
    /// @param values Array of SD59x18 values
    /// @return variance The sample variance
    function computeVariance(SD59x18[] memory values) internal pure returns (SD59x18 variance) {
        uint256 n = values.length;
        if (n == 0) revert EmptyArrays();

        SD59x18 mean = computeMean(values);

        SD59x18 sumSquaredDiff = ZERO;
        for (uint256 i = 0; i < n; i++) {
            SD59x18 diff = values[i].sub(mean);
            sumSquaredDiff = sumSquaredDiff.add(diff.mul(diff));
        }

        // Sample variance: Σ(x - μ)² / (n - 1)
        // Use n for population variance when n is large
        variance = sumSquaredDiff.div(sd(int256(n) * ONE));
    }

    /// @notice Computes the standard deviation of an array of values
    /// @param values Array of SD59x18 values
    /// @return stdDev The standard deviation
    function computeStdDev(SD59x18[] memory values) internal pure returns (SD59x18 stdDev) {
        SD59x18 variance = computeVariance(values);
        stdDev = variance.sqrt();
    }

    /// @notice Computes correlation coefficient between two arrays
    /// @param x First array of values
    /// @param y Second array of values
    /// @return correlation Pearson correlation coefficient [-1, 1]
    function computeCorrelation(SD59x18[] memory x, SD59x18[] memory y) internal pure returns (SD59x18 correlation) {
        uint256 n = x.length;
        if (n == 0) revert EmptyArrays();
        if (n != y.length) revert ArrayLengthMismatch();

        SD59x18 meanX = computeMean(x);
        SD59x18 meanY = computeMean(y);

        SD59x18 sumXY = ZERO;
        SD59x18 sumX2 = ZERO;
        SD59x18 sumY2 = ZERO;

        for (uint256 i = 0; i < n; i++) {
            SD59x18 dx = x[i].sub(meanX);
            SD59x18 dy = y[i].sub(meanY);

            sumXY = sumXY.add(dx.mul(dy));
            sumX2 = sumX2.add(dx.mul(dx));
            sumY2 = sumY2.add(dy.mul(dy));
        }

        SD59x18 denominator = sumX2.mul(sumY2).sqrt();

        // Handle edge case where one array is constant
        if (denominator.eq(ZERO)) {
            return ZERO;
        }

        correlation = sumXY.div(denominator);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BATCH PROCESSING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes LSIVS for a batch of options with same params
    /// @param spotPrices Array of spot prices
    /// @param strikePrices Array of strike prices
    /// @param timesToExpiry Array of times to expiry
    /// @param realizedVols Array of realized volatilities
    /// @param utilizations Array of utilization ratios
    /// @param params Calibration parameters
    /// @return impliedVols Array of computed implied volatilities
    function computeLSIVSBatch(
        SD59x18[] memory spotPrices,
        SD59x18[] memory strikePrices,
        SD59x18[] memory timesToExpiry,
        SD59x18[] memory realizedVols,
        SD59x18[] memory utilizations,
        CalibrationParams memory params
    ) internal pure returns (SD59x18[] memory impliedVols) {
        uint256 n = spotPrices.length;
        if (n == 0) revert EmptyArrays();
        if (
            strikePrices.length != n || timesToExpiry.length != n || realizedVols.length != n
                || utilizations.length != n
        ) {
            revert ArrayLengthMismatch();
        }

        impliedVols = new SD59x18[](n);

        for (uint256 i = 0; i < n; i++) {
            impliedVols[i] =
                computeLSIVS(spotPrices[i], strikePrices[i], timesToExpiry[i], realizedVols[i], utilizations[i], params);
        }
    }

    /// @notice Computes percentage errors for analysis
    /// @param predictedIVs Array of predicted IVs
    /// @param actualIVs Array of actual IVs
    /// @return percentErrors Array of percentage errors ((pred - actual) / actual)
    function computePercentageErrors(SD59x18[] memory predictedIVs, SD59x18[] memory actualIVs)
        internal
        pure
        returns (SD59x18[] memory percentErrors)
    {
        uint256 n = predictedIVs.length;
        if (n == 0) revert EmptyArrays();
        if (n != actualIVs.length) revert ArrayLengthMismatch();

        percentErrors = new SD59x18[](n);

        for (uint256 i = 0; i < n; i++) {
            if (actualIVs[i].eq(ZERO)) {
                percentErrors[i] = ZERO;
            } else {
                percentErrors[i] = predictedIVs[i].sub(actualIVs[i]).div(actualIVs[i]);
            }
        }
    }

    /// @notice Computes Mean Absolute Percentage Error (MAPE)
    /// @param predictedIVs Array of predicted IVs
    /// @param actualIVs Array of actual IVs
    /// @return mape The MAPE value
    function computeMAPE(SD59x18[] memory predictedIVs, SD59x18[] memory actualIVs)
        internal
        pure
        returns (SD59x18 mape)
    {
        uint256 n = predictedIVs.length;
        if (n == 0) revert EmptyArrays();
        if (n != actualIVs.length) revert ArrayLengthMismatch();

        SD59x18 sumAbsPercentError = ZERO;
        uint256 validCount = 0;

        for (uint256 i = 0; i < n; i++) {
            if (actualIVs[i].gt(ZERO)) {
                SD59x18 absPercentError = predictedIVs[i].sub(actualIVs[i]).abs().div(actualIVs[i]);
                sumAbsPercentError = sumAbsPercentError.add(absPercentError);
                validCount++;
            }
        }

        if (validCount == 0) {
            return ZERO;
        }

        mape = sumAbsPercentError.div(sd(int256(validCount) * ONE));
    }
}
