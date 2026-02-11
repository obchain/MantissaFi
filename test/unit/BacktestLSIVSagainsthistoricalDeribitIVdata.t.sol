// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    BacktestLSIVSagainsthistoricalDeribitIVdata as Backtest
} from "../../src/libraries/BacktestLSIVSagainsthistoricalDeribitIVdata.sol";

/// @notice Wrapper contract to enable revert testing for library internal functions
contract BacktestWrapper {
    function computeLSIVS(
        SD59x18 spotPrice,
        SD59x18 strikePrice,
        SD59x18 timeToExpiry,
        SD59x18 realizedVol,
        SD59x18 utilization,
        Backtest.CalibrationParams memory params
    ) external pure returns (SD59x18) {
        return Backtest.computeLSIVS(spotPrice, strikePrice, timeToExpiry, realizedVol, utilization, params);
    }

    function computeRMSE(SD59x18[] memory predictedIVs, SD59x18[] memory actualIVs) external pure returns (SD59x18) {
        return Backtest.computeRMSE(predictedIVs, actualIVs);
    }

    function runBacktest(Backtest.DataPoint[] memory dataPoints, Backtest.CalibrationParams memory params)
        external
        pure
        returns (Backtest.ErrorMetrics memory)
    {
        return Backtest.runBacktest(dataPoints, params);
    }

    function computeMoneyness(SD59x18 spotPrice, SD59x18 strikePrice) external pure returns (SD59x18) {
        return Backtest.computeMoneyness(spotPrice, strikePrice);
    }

    function defaultCalibrationParams() external pure returns (Backtest.CalibrationParams memory) {
        return Backtest.defaultCalibrationParams();
    }
}

/// @title BacktestLSIVSagainsthistoricalDeribitIVdataTest
/// @notice Unit tests for the LSIVS backtesting library
contract BacktestLSIVSagainsthistoricalDeribitIVdataTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS FOR TESTING
    // ═══════════════════════════════════════════════════════════════════════════

    int256 constant ONE = 1e18;
    int256 constant HALF = 5e17;

    BacktestWrapper wrapper;

    function setUp() public {
        wrapper = new BacktestWrapper();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LSIVS COMPUTATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_computeLSIVS_ATMOption() public pure {
        // ATM option should return vol close to realized vol (no skew effect)
        SD59x18 spot = sd(2000e18);
        SD59x18 strike = sd(2000e18);
        SD59x18 timeToExpiry = sd(ONE / 12);
        SD59x18 realVol = sd(8e17); // 80%
        SD59x18 util = sd(1e17); // 10%

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        SD59x18 iv = Backtest.computeLSIVS(spot, strike, timeToExpiry, realVol, util, params);

        // IV should be positive and within reasonable bounds
        assertTrue(iv.gt(ZERO), "IV should be positive");
        assertTrue(iv.lt(sd(5e18)), "IV should be below 500%");
    }

    function test_computeLSIVS_OTMCall() public pure {
        // OTM call (strike > spot) should have higher IV due to skew
        SD59x18 spot = sd(2000e18);
        SD59x18 strikeAtm = sd(2000e18);
        SD59x18 strikeOtm = sd(2200e18); // 10% OTM
        SD59x18 timeToExpiry = sd(ONE / 12);
        SD59x18 realVol = sd(8e17);
        SD59x18 util = sd(1e17);

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        SD59x18 ivAtm = Backtest.computeLSIVS(spot, strikeAtm, timeToExpiry, realVol, util, params);
        SD59x18 ivOtm = Backtest.computeLSIVS(spot, strikeOtm, timeToExpiry, realVol, util, params);

        // OTM should have higher IV due to positive skew term (moneyness² > 0)
        assertTrue(ivOtm.gt(ivAtm), "OTM IV should be higher than ATM IV");
    }

    function test_computeLSIVS_ITMCall() public pure {
        // ITM call (strike < spot) should also have higher IV due to skew
        SD59x18 spot = sd(2000e18);
        SD59x18 strikeAtm = sd(2000e18);
        SD59x18 strikeItm = sd(1800e18); // 10% ITM
        SD59x18 timeToExpiry = sd(ONE / 12);
        SD59x18 realVol = sd(8e17);
        SD59x18 util = sd(1e17);

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        SD59x18 ivAtm = Backtest.computeLSIVS(spot, strikeAtm, timeToExpiry, realVol, util, params);
        SD59x18 ivItm = Backtest.computeLSIVS(spot, strikeItm, timeToExpiry, realVol, util, params);

        // ITM should have higher IV due to symmetric skew (moneyness² > 0)
        assertTrue(ivItm.gt(ivAtm), "ITM IV should be higher than ATM IV");
    }

    function test_computeLSIVS_HighUtilizationIncreasesIV() public pure {
        SD59x18 spot = sd(2000e18);
        SD59x18 strike = sd(2000e18);
        SD59x18 timeToExpiry = sd(ONE / 12);
        SD59x18 realVol = sd(8e17);
        SD59x18 lowUtil = sd(1e17); // 10%
        SD59x18 highUtil = sd(8e17); // 80%

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        SD59x18 ivLow = Backtest.computeLSIVS(spot, strike, timeToExpiry, realVol, lowUtil, params);
        SD59x18 ivHigh = Backtest.computeLSIVS(spot, strike, timeToExpiry, realVol, highUtil, params);

        // Higher utilization should increase IV due to utilization premium
        assertTrue(ivHigh.gt(ivLow), "Higher utilization should increase IV");
    }

    function test_computeLSIVS_ZeroUtilization() public pure {
        SD59x18 spot = sd(2000e18);
        SD59x18 strike = sd(2000e18);
        SD59x18 timeToExpiry = sd(ONE / 12);
        SD59x18 realVol = sd(8e17);
        SD59x18 zeroUtil = ZERO;

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        SD59x18 iv = Backtest.computeLSIVS(spot, strike, timeToExpiry, realVol, zeroUtil, params);

        // Should work with zero utilization
        assertTrue(iv.gt(ZERO), "IV should be positive with zero utilization");
    }

    function test_computeLSIVSDefault() public pure {
        SD59x18 iv = Backtest.computeLSIVSDefault(
            sd(2000e18), // spot
            sd(2000e18), // strike
            sd(ONE / 12), // 1 month
            sd(8e17), // 80% vol
            sd(1e17) // 10% util
        );

        assertTrue(iv.gt(ZERO), "Default LSIVS should return positive IV");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPONENT FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_computeSkew_ZeroMoneyness() public pure {
        // ATM: moneyness = 0, skew should be 0
        SD59x18 moneyness = ZERO;
        SD59x18 skewCoeff = sd(25e16); // 0.25

        SD59x18 skew = Backtest.computeSkew(moneyness, skewCoeff);

        assertEq(skew.unwrap(), 0, "Skew should be 0 for ATM options");
    }

    function test_computeSkew_PositiveMoneyness() public pure {
        // OTM call: moneyness > 0
        SD59x18 moneyness = sd(1e17); // 0.1
        SD59x18 skewCoeff = sd(25e16); // 0.25

        SD59x18 skew = Backtest.computeSkew(moneyness, skewCoeff);

        // skew = 0.25 * 0.1² = 0.25 * 0.01 = 0.0025
        assertTrue(skew.gt(ZERO), "Skew should be positive for OTM");
    }

    function test_computeSkew_NegativeMoneyness() public pure {
        // ITM call: moneyness < 0
        SD59x18 moneyness = sd(-1e17); // -0.1
        SD59x18 skewCoeff = sd(25e16); // 0.25

        SD59x18 skew = Backtest.computeSkew(moneyness, skewCoeff);

        // skew = 0.25 * (-0.1)² = 0.25 * 0.01 = 0.0025
        assertTrue(skew.gt(ZERO), "Skew should be positive for ITM (symmetric)");
    }

    function test_computeUtilizationPremium_LowUtil() public pure {
        SD59x18 util = sd(1e17); // 10%
        SD59x18 gamma = sd(1e17); // 0.1

        SD59x18 premium = Backtest.computeUtilizationPremium(util, gamma);

        // premium = 0.1 * 0.1 / (1 - 0.1) = 0.01 / 0.9 ≈ 0.0111
        assertTrue(premium.gt(ZERO), "Premium should be positive");
        assertTrue(premium.lt(sd(2e16)), "Premium should be small for low util");
    }

    function test_computeUtilizationPremium_HighUtil() public pure {
        SD59x18 util = sd(9e17); // 90%
        SD59x18 gamma = sd(1e17); // 0.1

        SD59x18 premium = Backtest.computeUtilizationPremium(util, gamma);

        // premium = 0.1 * 0.9 / (1 - 0.9) = 0.09 / 0.1 = 0.9
        assertTrue(premium.gt(sd(5e17)), "Premium should be high for high util");
    }

    function test_computeTermStructureAdjustment() public pure {
        SD59x18 timeToExpiry = sd(ONE); // 1 year
        SD59x18 termCoeff = sd(1e17); // 0.1

        SD59x18 adjustment = Backtest.computeTermStructureAdjustment(timeToExpiry, termCoeff);

        // adjustment = 0.1 * √1 = 0.1
        assertApproxEqRel(adjustment.unwrap(), 1e17, 1e15, "Term adjustment should be ~0.1");
    }

    function test_clampIV_BelowMin() public pure {
        SD59x18 lowIv = sd(5e15); // 0.5%

        SD59x18 clamped = Backtest.clampIV(lowIv);

        assertEq(clamped.unwrap(), 1e16, "IV should be clamped to MIN_IV (1%)");
    }

    function test_clampIV_AboveMax() public pure {
        SD59x18 highIv = sd(6e18); // 600%

        SD59x18 clamped = Backtest.clampIV(highIv);

        assertEq(clamped.unwrap(), 5e18, "IV should be clamped to MAX_IV (500%)");
    }

    function test_clampIV_WithinBounds() public pure {
        SD59x18 normalIv = sd(8e17); // 80%

        SD59x18 clamped = Backtest.clampIV(normalIv);

        assertEq(clamped.unwrap(), 8e17, "IV within bounds should not change");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERROR METRICS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_computeRMSE_PerfectPrediction() public pure {
        SD59x18[] memory predicted = new SD59x18[](3);
        SD59x18[] memory actual = new SD59x18[](3);

        predicted[0] = sd(8e17);
        predicted[1] = sd(85e16);
        predicted[2] = sd(9e17);

        actual[0] = sd(8e17);
        actual[1] = sd(85e16);
        actual[2] = sd(9e17);

        SD59x18 rmse = Backtest.computeRMSE(predicted, actual);

        assertEq(rmse.unwrap(), 0, "RMSE should be 0 for perfect prediction");
    }

    function test_computeRMSE_WithErrors() public pure {
        SD59x18[] memory predicted = new SD59x18[](2);
        SD59x18[] memory actual = new SD59x18[](2);

        predicted[0] = sd(8e17); // 0.80
        predicted[1] = sd(9e17); // 0.90

        actual[0] = sd(7e17); // 0.70, error = 0.10
        actual[1] = sd(1e18); // 1.00, error = -0.10

        SD59x18 rmse = Backtest.computeRMSE(predicted, actual);

        // RMSE = √((0.1² + 0.1²) / 2) = √(0.02 / 2) = √0.01 = 0.1
        assertApproxEqRel(rmse.unwrap(), 1e17, 1e15, "RMSE should be ~0.1");
    }

    function test_computeMAE_PerfectPrediction() public pure {
        SD59x18[] memory predicted = new SD59x18[](3);
        SD59x18[] memory actual = new SD59x18[](3);

        predicted[0] = sd(8e17);
        predicted[1] = sd(85e16);
        predicted[2] = sd(9e17);

        actual[0] = sd(8e17);
        actual[1] = sd(85e16);
        actual[2] = sd(9e17);

        SD59x18 mae = Backtest.computeMAE(predicted, actual);

        assertEq(mae.unwrap(), 0, "MAE should be 0 for perfect prediction");
    }

    function test_computeMAE_WithErrors() public pure {
        SD59x18[] memory predicted = new SD59x18[](2);
        SD59x18[] memory actual = new SD59x18[](2);

        predicted[0] = sd(8e17);
        predicted[1] = sd(9e17);

        actual[0] = sd(7e17); // error = 0.10
        actual[1] = sd(1e18); // error = -0.10

        SD59x18 mae = Backtest.computeMAE(predicted, actual);

        // MAE = (0.1 + 0.1) / 2 = 0.1
        assertApproxEqRel(mae.unwrap(), 1e17, 1e15, "MAE should be ~0.1");
    }

    function test_computeMaxDeviation() public pure {
        SD59x18[] memory predicted = new SD59x18[](3);
        SD59x18[] memory actual = new SD59x18[](3);

        predicted[0] = sd(8e17);
        predicted[1] = sd(9e17);
        predicted[2] = sd(1e18);

        actual[0] = sd(8e17); // error = 0
        actual[1] = sd(85e16); // error = 0.05
        actual[2] = sd(85e16); // error = 0.15

        SD59x18 maxDev = Backtest.computeMaxDeviation(predicted, actual);

        assertApproxEqRel(maxDev.unwrap(), 15e16, 1e15, "Max deviation should be ~0.15");
    }

    function test_computeErrorMetrics() public pure {
        SD59x18[] memory predicted = new SD59x18[](3);
        SD59x18[] memory actual = new SD59x18[](3);

        predicted[0] = sd(8e17);
        predicted[1] = sd(85e16);
        predicted[2] = sd(9e17);

        actual[0] = sd(75e16); // error = +0.05
        actual[1] = sd(9e17); // error = -0.05
        actual[2] = sd(85e16); // error = +0.05

        Backtest.ErrorMetrics memory metrics = Backtest.computeErrorMetrics(predicted, actual);

        assertTrue(metrics.rmse.gt(ZERO), "RMSE should be positive");
        assertTrue(metrics.mae.gt(ZERO), "MAE should be positive");
        assertTrue(metrics.maxDeviation.gt(ZERO), "Max deviation should be positive");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BACKTEST FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_runBacktest_SingleDataPoint() public pure {
        Backtest.DataPoint[] memory dataPoints = new Backtest.DataPoint[](1);
        dataPoints[0] = Backtest.DataPoint({
            spotPrice: sd(2000e18),
            strikePrice: sd(2000e18),
            timeToExpiry: sd(ONE / 12),
            realizedVol: sd(8e17),
            utilization: sd(1e17),
            deribitIV: sd(82e16) // Deribit shows 82%
        });

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        Backtest.ErrorMetrics memory metrics = Backtest.runBacktest(dataPoints, params);

        // Should compute without errors
        assertTrue(metrics.rmse.gte(ZERO), "RMSE should be non-negative");
        assertTrue(metrics.mae.gte(ZERO), "MAE should be non-negative");
    }

    function test_runBacktest_MultipleDataPoints() public pure {
        Backtest.DataPoint[] memory dataPoints = new Backtest.DataPoint[](3);

        // ATM ETH option
        dataPoints[0] = Backtest.DataPoint({
            spotPrice: sd(2000e18),
            strikePrice: sd(2000e18),
            timeToExpiry: sd(ONE / 12),
            realizedVol: sd(8e17),
            utilization: sd(1e17),
            deribitIV: sd(82e16)
        });

        // OTM ETH option
        dataPoints[1] = Backtest.DataPoint({
            spotPrice: sd(2000e18),
            strikePrice: sd(2200e18),
            timeToExpiry: sd(ONE / 12),
            realizedVol: sd(8e17),
            utilization: sd(1e17),
            deribitIV: sd(9e17)
        });

        // ITM ETH option
        dataPoints[2] = Backtest.DataPoint({
            spotPrice: sd(2000e18),
            strikePrice: sd(1800e18),
            timeToExpiry: sd(ONE / 12),
            realizedVol: sd(8e17),
            utilization: sd(1e17),
            deribitIV: sd(88e16)
        });

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        Backtest.ErrorMetrics memory metrics = Backtest.runBacktest(dataPoints, params);

        assertTrue(metrics.rmse.gte(ZERO), "RMSE should be non-negative");
        assertTrue(metrics.mae.gte(ZERO), "MAE should be non-negative");
        assertTrue(metrics.maxDeviation.gte(ZERO), "Max deviation should be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CALIBRATION PARAMETER TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_defaultCalibrationParams() public pure {
        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        assertEq(params.skewCoefficient.unwrap(), 25e16, "Default skew coeff should be 0.25");
        assertEq(params.gamma.unwrap(), 1e17, "Default gamma should be 0.1");
        assertEq(params.atmAdjustment.unwrap(), 0, "Default ATM adjustment should be 0");
        assertEq(params.termStructureCoeff.unwrap(), 0, "Default term coeff should be 0");
    }

    function test_validateCalibrationParams_Valid() public pure {
        Backtest.CalibrationParams memory params = Backtest.CalibrationParams({
            skewCoefficient: sd(3e17), gamma: sd(15e16), atmAdjustment: sd(1e16), termStructureCoeff: sd(5e16)
        });

        bool valid = Backtest.validateCalibrationParams(params);

        assertTrue(valid, "Valid params should pass validation");
    }

    function test_validateCalibrationParams_InvalidSkew() public pure {
        Backtest.CalibrationParams memory params = Backtest.CalibrationParams({
            skewCoefficient: sd(2e18), gamma: sd(1e17), atmAdjustment: ZERO, termStructureCoeff: ZERO
        });

        bool valid = Backtest.validateCalibrationParams(params);

        assertFalse(valid, "Skew > 1 should be invalid");
    }

    function test_validateCalibrationParams_NegativeGamma() public pure {
        Backtest.CalibrationParams memory params = Backtest.CalibrationParams({
            skewCoefficient: sd(25e16), gamma: sd(-1e17), atmAdjustment: ZERO, termStructureCoeff: ZERO
        });

        bool valid = Backtest.validateCalibrationParams(params);

        assertFalse(valid, "Negative gamma should be invalid");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MONEYNESS COMPUTATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_computeMoneyness_ATM() public pure {
        SD59x18 moneyness = Backtest.computeMoneyness(sd(2000e18), sd(2000e18));

        // ln(1) = 0
        assertEq(moneyness.unwrap(), 0, "ATM moneyness should be 0");
    }

    function test_computeMoneyness_OTM() public pure {
        SD59x18 moneyness = Backtest.computeMoneyness(sd(2000e18), sd(2200e18));

        // ln(2200/2000) = ln(1.1) > 0
        assertTrue(moneyness.gt(ZERO), "OTM call moneyness should be positive");
    }

    function test_computeMoneyness_ITM() public pure {
        SD59x18 moneyness = Backtest.computeMoneyness(sd(2000e18), sd(1800e18));

        // ln(1800/2000) = ln(0.9) < 0
        assertTrue(moneyness.lt(ZERO), "ITM call moneyness should be negative");
    }

    function test_computeForwardMoneyness() public pure {
        SD59x18 fwdMoneyness = Backtest.computeForwardMoneyness(sd(2000e18), sd(2200e18), sd(ONE), sd(8e17)); // 1 year, 80% vol

        // fwdMoneyness = ln(2200/2000) / (0.8 * √1) = ln(1.1) / 0.8
        assertTrue(fwdMoneyness.gt(ZERO), "Forward moneyness should be positive for OTM");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STATISTICAL HELPER TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_computeMean() public pure {
        SD59x18[] memory values = new SD59x18[](3);
        values[0] = sd(1e18);
        values[1] = sd(2e18);
        values[2] = sd(3e18);

        SD59x18 mean = Backtest.computeMean(values);

        assertEq(mean.unwrap(), 2e18, "Mean of [1,2,3] should be 2");
    }

    function test_computeVariance() public pure {
        SD59x18[] memory values = new SD59x18[](3);
        values[0] = sd(1e18);
        values[1] = sd(2e18);
        values[2] = sd(3e18);

        SD59x18 variance = Backtest.computeVariance(values);

        // Var = ((1-2)² + (2-2)² + (3-2)²) / 3 = (1 + 0 + 1) / 3 = 2/3
        assertApproxEqRel(variance.unwrap(), 666666666666666666, 1e15, "Variance should be ~2/3");
    }

    function test_computeStdDev() public pure {
        SD59x18[] memory values = new SD59x18[](3);
        values[0] = sd(1e18);
        values[1] = sd(2e18);
        values[2] = sd(3e18);

        SD59x18 stdDev = Backtest.computeStdDev(values);

        // StdDev = √(2/3) ≈ 0.816
        assertTrue(stdDev.gt(sd(8e17)), "StdDev should be > 0.8");
        assertTrue(stdDev.lt(sd(9e17)), "StdDev should be < 0.9");
    }

    function test_computeCorrelation_Perfect() public pure {
        SD59x18[] memory x = new SD59x18[](3);
        SD59x18[] memory y = new SD59x18[](3);

        x[0] = sd(1e18);
        x[1] = sd(2e18);
        x[2] = sd(3e18);

        y[0] = sd(1e18);
        y[1] = sd(2e18);
        y[2] = sd(3e18);

        SD59x18 corr = Backtest.computeCorrelation(x, y);

        assertApproxEqRel(corr.unwrap(), ONE, 1e15, "Perfect correlation should be 1");
    }

    function test_computeCorrelation_NegativePerfect() public pure {
        SD59x18[] memory x = new SD59x18[](3);
        SD59x18[] memory y = new SD59x18[](3);

        x[0] = sd(1e18);
        x[1] = sd(2e18);
        x[2] = sd(3e18);

        y[0] = sd(3e18);
        y[1] = sd(2e18);
        y[2] = sd(1e18);

        SD59x18 corr = Backtest.computeCorrelation(x, y);

        assertApproxEqRel(corr.unwrap(), -ONE, 1e15, "Perfect negative correlation should be -1");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BATCH PROCESSING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_computeLSIVSBatch() public pure {
        SD59x18[] memory spots = new SD59x18[](2);
        SD59x18[] memory strikes = new SD59x18[](2);
        SD59x18[] memory times = new SD59x18[](2);
        SD59x18[] memory vols = new SD59x18[](2);
        SD59x18[] memory utils = new SD59x18[](2);

        spots[0] = sd(2000e18);
        spots[1] = sd(2000e18);
        strikes[0] = sd(2000e18);
        strikes[1] = sd(2200e18);
        times[0] = sd(ONE / 12);
        times[1] = sd(ONE / 12);
        vols[0] = sd(8e17);
        vols[1] = sd(8e17);
        utils[0] = sd(1e17);
        utils[1] = sd(1e17);

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        SD59x18[] memory ivs = Backtest.computeLSIVSBatch(spots, strikes, times, vols, utils, params);

        assertEq(ivs.length, 2, "Should return 2 IVs");
        assertTrue(ivs[0].gt(ZERO), "First IV should be positive");
        assertTrue(ivs[1].gt(ZERO), "Second IV should be positive");
    }

    function test_computePercentageErrors() public pure {
        SD59x18[] memory predicted = new SD59x18[](2);
        SD59x18[] memory actual = new SD59x18[](2);

        predicted[0] = sd(88e16); // 0.88
        predicted[1] = sd(95e16); // 0.95

        actual[0] = sd(8e17); // 0.80
        actual[1] = sd(1e18); // 1.00

        SD59x18[] memory percentErrors = Backtest.computePercentageErrors(predicted, actual);

        // (0.88 - 0.80) / 0.80 = 0.10
        assertApproxEqRel(percentErrors[0].unwrap(), 1e17, 1e15, "First % error should be ~10%");

        // (0.95 - 1.00) / 1.00 = -0.05
        assertApproxEqRel(percentErrors[1].unwrap(), -5e16, 1e15, "Second % error should be ~-5%");
    }

    function test_computeMAPE() public pure {
        SD59x18[] memory predicted = new SD59x18[](2);
        SD59x18[] memory actual = new SD59x18[](2);

        predicted[0] = sd(88e16); // 0.88
        predicted[1] = sd(95e16); // 0.95

        actual[0] = sd(8e17); // 0.80
        actual[1] = sd(1e18); // 1.00

        SD59x18 mape = Backtest.computeMAPE(predicted, actual);

        // MAPE = (|10%| + |-5%|) / 2 = 7.5%
        assertApproxEqRel(mape.unwrap(), 75e15, 1e15, "MAPE should be ~7.5%");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REVERT TESTS (using wrapper contract for external calls)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_computeLSIVS_RevertOnZeroRealizedVol() public {
        Backtest.CalibrationParams memory params = wrapper.defaultCalibrationParams();

        vm.expectRevert(Backtest.InvalidRealizedVolatility.selector);
        wrapper.computeLSIVS(sd(2000e18), sd(2000e18), sd(ONE / 12), ZERO, sd(1e17), params);
    }

    function test_computeLSIVS_RevertOnZeroSpot() public {
        Backtest.CalibrationParams memory params = wrapper.defaultCalibrationParams();

        vm.expectRevert(Backtest.InvalidSpotPrice.selector);
        wrapper.computeLSIVS(ZERO, sd(2000e18), sd(ONE / 12), sd(8e17), sd(1e17), params);
    }

    function test_computeLSIVS_RevertOnZeroStrike() public {
        Backtest.CalibrationParams memory params = wrapper.defaultCalibrationParams();

        vm.expectRevert(Backtest.InvalidStrikePrice.selector);
        wrapper.computeLSIVS(sd(2000e18), ZERO, sd(ONE / 12), sd(8e17), sd(1e17), params);
    }

    function test_computeLSIVS_RevertOnZeroTime() public {
        Backtest.CalibrationParams memory params = wrapper.defaultCalibrationParams();

        vm.expectRevert(Backtest.InvalidTimeToExpiry.selector);
        wrapper.computeLSIVS(sd(2000e18), sd(2000e18), ZERO, sd(8e17), sd(1e17), params);
    }

    function test_computeLSIVS_RevertOnNegativeUtilization() public {
        Backtest.CalibrationParams memory params = wrapper.defaultCalibrationParams();

        vm.expectRevert(Backtest.InvalidUtilizationRatio.selector);
        wrapper.computeLSIVS(sd(2000e18), sd(2000e18), sd(ONE / 12), sd(8e17), sd(-1e17), params);
    }

    function test_computeLSIVS_RevertOnUtilizationAtOne() public {
        Backtest.CalibrationParams memory params = wrapper.defaultCalibrationParams();

        vm.expectRevert(Backtest.InvalidUtilizationRatio.selector);
        wrapper.computeLSIVS(sd(2000e18), sd(2000e18), sd(ONE / 12), sd(8e17), sd(ONE), params);
    }

    function test_computeRMSE_RevertOnEmptyArrays() public {
        SD59x18[] memory empty = new SD59x18[](0);

        vm.expectRevert(Backtest.EmptyArrays.selector);
        wrapper.computeRMSE(empty, empty);
    }

    function test_computeRMSE_RevertOnLengthMismatch() public {
        SD59x18[] memory arr2 = new SD59x18[](2);
        SD59x18[] memory arr3 = new SD59x18[](3);

        arr2[0] = sd(1e18);
        arr2[1] = sd(2e18);
        arr3[0] = sd(1e18);
        arr3[1] = sd(2e18);
        arr3[2] = sd(3e18);

        vm.expectRevert(Backtest.ArrayLengthMismatch.selector);
        wrapper.computeRMSE(arr2, arr3);
    }

    function test_runBacktest_RevertOnEmptyDataPoints() public {
        Backtest.DataPoint[] memory empty = new Backtest.DataPoint[](0);
        Backtest.CalibrationParams memory params = wrapper.defaultCalibrationParams();

        vm.expectRevert(Backtest.EmptyArrays.selector);
        wrapper.runBacktest(empty, params);
    }

    function test_computeMoneyness_RevertOnZeroSpot() public {
        vm.expectRevert(Backtest.InvalidSpotPrice.selector);
        wrapper.computeMoneyness(ZERO, sd(2000e18));
    }

    function test_computeMoneyness_RevertOnZeroStrike() public {
        vm.expectRevert(Backtest.InvalidStrikePrice.selector);
        wrapper.computeMoneyness(sd(2000e18), ZERO);
    }
}
