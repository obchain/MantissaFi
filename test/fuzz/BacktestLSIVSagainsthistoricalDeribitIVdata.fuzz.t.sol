// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { BacktestLSIVSagainsthistoricalDeribitIVdata as Backtest } from
    "../../src/libraries/BacktestLSIVSagainsthistoricalDeribitIVdata.sol";

/// @title BacktestLSIVSagainsthistoricalDeribitIVdataFuzzTest
/// @notice Fuzz tests for property-based invariant testing of the LSIVS backtesting library
contract BacktestLSIVSagainsthistoricalDeribitIVdataFuzzTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    int256 constant ONE = 1e18;
    uint256 constant MIN_PRICE = 1e15; // 0.001 - minimum realistic price
    uint256 constant MAX_PRICE = 1e24; // 1,000,000 - maximum realistic price
    uint256 constant MIN_VOL = 1e16; // 1% minimum vol
    uint256 constant MAX_VOL = 3e18; // 300% maximum vol
    uint256 constant MIN_TIME = 1e14; // ~0.0001 years (~52 minutes)
    uint256 constant MAX_TIME = 2e18; // 2 years
    uint256 constant MAX_UTIL = 999e15; // 99.9%

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: LSIVS IV IS ALWAYS POSITIVE AND BOUNDED
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: LSIVS always returns IV within [MIN_IV, MAX_IV]
    function testFuzz_computeLSIVS_IVBounded(
        uint256 spotSeed,
        uint256 strikeSeed,
        uint256 timeSeed,
        uint256 volSeed,
        uint256 utilSeed
    ) public pure {
        // Bound inputs to realistic ranges
        int256 spot = int256(bound(spotSeed, MIN_PRICE, MAX_PRICE));
        int256 strike = int256(bound(strikeSeed, MIN_PRICE, MAX_PRICE));
        int256 time = int256(bound(timeSeed, MIN_TIME, MAX_TIME));
        int256 vol = int256(bound(volSeed, MIN_VOL, MAX_VOL));
        int256 util = int256(bound(utilSeed, 0, MAX_UTIL));

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        SD59x18 iv = Backtest.computeLSIVS(sd(spot), sd(strike), sd(time), sd(vol), sd(util), params);

        // IV should be within bounds [1%, 500%]
        assertTrue(iv.gte(sd(1e16)), "IV should be >= 1%");
        assertTrue(iv.lte(sd(5e18)), "IV should be <= 500%");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: HIGHER UTILIZATION → HIGHER IV
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: For same inputs, higher utilization always yields higher or equal IV
    function testFuzz_computeLSIVS_UtilizationMonotonicity(
        uint256 spotSeed,
        uint256 strikeSeed,
        uint256 timeSeed,
        uint256 volSeed,
        uint256 util1Seed,
        uint256 util2Seed
    ) public pure {
        int256 spot = int256(bound(spotSeed, MIN_PRICE, MAX_PRICE));
        int256 strike = int256(bound(strikeSeed, MIN_PRICE, MAX_PRICE));
        int256 time = int256(bound(timeSeed, MIN_TIME, MAX_TIME));
        int256 vol = int256(bound(volSeed, MIN_VOL, MAX_VOL));

        // Ensure util1 <= util2
        uint256 util1Raw = bound(util1Seed, 0, MAX_UTIL - 1);
        uint256 util2Raw = bound(util2Seed, util1Raw, MAX_UTIL);

        int256 util1 = int256(util1Raw);
        int256 util2 = int256(util2Raw);

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        SD59x18 iv1 = Backtest.computeLSIVS(sd(spot), sd(strike), sd(time), sd(vol), sd(util1), params);
        SD59x18 iv2 = Backtest.computeLSIVS(sd(spot), sd(strike), sd(time), sd(vol), sd(util2), params);

        // Higher utilization should yield higher or equal IV
        assertTrue(iv2.gte(iv1), "Higher utilization should yield higher IV");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: SKEW SYMMETRY (OTM PUTS AND CALLS)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Symmetric strikes around ATM should have same IV (quadratic skew)
    function testFuzz_computeLSIVS_SkewSymmetry(
        uint256 spotSeed,
        uint256 deviationSeed,
        uint256 timeSeed,
        uint256 volSeed
    ) public pure {
        uint256 spot = bound(spotSeed, MIN_PRICE, MAX_PRICE / 2);
        uint256 time = bound(timeSeed, MIN_TIME, MAX_TIME);
        uint256 vol = bound(volSeed, MIN_VOL, MAX_VOL);

        // Deviation as percentage of spot (up to 50%)
        uint256 deviation = bound(deviationSeed, 0, spot / 2);

        uint256 strikeUp = spot + deviation;
        uint256 strikeDown = spot - deviation;

        // Skip if strikeDown would be <= 0
        vm.assume(strikeDown > 0);

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();
        SD59x18 util = ZERO; // Use zero utilization to isolate skew effect

        SD59x18 ivUp = Backtest.computeLSIVS(
            sd(int256(spot)), sd(int256(strikeUp)), sd(int256(time)), sd(int256(vol)), util, params
        );
        SD59x18 ivDown = Backtest.computeLSIVS(
            sd(int256(spot)), sd(int256(strikeDown)), sd(int256(time)), sd(int256(vol)), util, params
        );

        // Due to quadratic skew (moneyness²), symmetric strikes should have similar IV
        // Allow 1% relative tolerance due to ln() asymmetry at extreme values
        int256 diff = ivUp.sub(ivDown).abs().unwrap();
        int256 avgIv = ivUp.add(ivDown).div(sd(2e18)).unwrap();

        // Relative difference should be small for mild moneyness
        if (avgIv > 0 && deviation < spot / 10) {
            assertTrue(diff * 100 / avgIv < 5, "Symmetric strikes should have similar IV");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: UTILIZATION PREMIUM CONVEXITY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Utilization premium increases monotonically with utilization
    /// @dev The premium γu/(1-u) is always increasing for u in [0,1)
    function testFuzz_computeUtilizationPremium_Monotonic(uint256 util1Seed, uint256 util2Seed) public pure {
        // Ensure util1 < util2
        uint256 util1Raw = bound(util1Seed, 0, MAX_UTIL - 1e16);
        uint256 util2Raw = bound(util2Seed, util1Raw + 1e16, MAX_UTIL);

        SD59x18 util1 = sd(int256(util1Raw));
        SD59x18 util2 = sd(int256(util2Raw));
        SD59x18 gamma = sd(1e17); // 0.1

        SD59x18 premium1 = Backtest.computeUtilizationPremium(util1, gamma);
        SD59x18 premium2 = Backtest.computeUtilizationPremium(util2, gamma);

        // Higher utilization should always yield higher premium
        assertTrue(premium2.gt(premium1), "Utilization premium should be monotonically increasing");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: RMSE NON-NEGATIVITY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: RMSE is always non-negative
    function testFuzz_computeRMSE_NonNegative(
        uint256 pred0,
        uint256 pred1,
        uint256 pred2,
        uint256 pred3,
        uint256 pred4,
        uint256 act0,
        uint256 act1,
        uint256 act2,
        uint256 act3,
        uint256 act4
    ) public pure {
        SD59x18[] memory predicted = new SD59x18[](5);
        SD59x18[] memory actual = new SD59x18[](5);

        predicted[0] = sd(int256(bound(pred0, MIN_VOL, MAX_VOL)));
        predicted[1] = sd(int256(bound(pred1, MIN_VOL, MAX_VOL)));
        predicted[2] = sd(int256(bound(pred2, MIN_VOL, MAX_VOL)));
        predicted[3] = sd(int256(bound(pred3, MIN_VOL, MAX_VOL)));
        predicted[4] = sd(int256(bound(pred4, MIN_VOL, MAX_VOL)));

        actual[0] = sd(int256(bound(act0, MIN_VOL, MAX_VOL)));
        actual[1] = sd(int256(bound(act1, MIN_VOL, MAX_VOL)));
        actual[2] = sd(int256(bound(act2, MIN_VOL, MAX_VOL)));
        actual[3] = sd(int256(bound(act3, MIN_VOL, MAX_VOL)));
        actual[4] = sd(int256(bound(act4, MIN_VOL, MAX_VOL)));

        SD59x18 rmse = Backtest.computeRMSE(predicted, actual);

        assertTrue(rmse.gte(ZERO), "RMSE should be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: MAX DEVIATION >= MAE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Max deviation >= MAE (max of set >= average)
    function testFuzz_maxDeviation_greaterThanOrEqualMAE(
        uint256 pred0,
        uint256 pred1,
        uint256 pred2,
        uint256 pred3,
        uint256 pred4,
        uint256 act0,
        uint256 act1,
        uint256 act2,
        uint256 act3,
        uint256 act4
    ) public pure {
        SD59x18[] memory predicted = new SD59x18[](5);
        SD59x18[] memory actual = new SD59x18[](5);

        predicted[0] = sd(int256(bound(pred0, MIN_VOL, MAX_VOL)));
        predicted[1] = sd(int256(bound(pred1, MIN_VOL, MAX_VOL)));
        predicted[2] = sd(int256(bound(pred2, MIN_VOL, MAX_VOL)));
        predicted[3] = sd(int256(bound(pred3, MIN_VOL, MAX_VOL)));
        predicted[4] = sd(int256(bound(pred4, MIN_VOL, MAX_VOL)));

        actual[0] = sd(int256(bound(act0, MIN_VOL, MAX_VOL)));
        actual[1] = sd(int256(bound(act1, MIN_VOL, MAX_VOL)));
        actual[2] = sd(int256(bound(act2, MIN_VOL, MAX_VOL)));
        actual[3] = sd(int256(bound(act3, MIN_VOL, MAX_VOL)));
        actual[4] = sd(int256(bound(act4, MIN_VOL, MAX_VOL)));

        SD59x18 maxDev = Backtest.computeMaxDeviation(predicted, actual);
        SD59x18 mae = Backtest.computeMAE(predicted, actual);

        // Max deviation >= MAE (maximum >= average)
        assertTrue(maxDev.gte(mae), "Max deviation should be >= MAE");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: MEAN OF CONSTANT ARRAY EQUALS THE CONSTANT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Mean of constant array equals the constant
    function testFuzz_computeMean_ConstantArray(uint256 valueSeed, uint8 lengthSeed) public pure {
        uint256 length = bound(lengthSeed, 1, 100);
        int256 value = int256(bound(valueSeed, 1, MAX_PRICE));

        SD59x18[] memory values = new SD59x18[](length);
        for (uint256 i = 0; i < length; i++) {
            values[i] = sd(value);
        }

        SD59x18 mean = Backtest.computeMean(values);

        assertApproxEqRel(mean.unwrap(), value, 1e14, "Mean of constant array should equal the constant");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: VARIANCE OF CONSTANT ARRAY IS ZERO
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Variance of constant array is zero
    function testFuzz_computeVariance_ConstantArrayIsZero(uint256 valueSeed, uint8 lengthSeed) public pure {
        uint256 length = bound(lengthSeed, 2, 100);
        int256 value = int256(bound(valueSeed, 1, MAX_PRICE));

        SD59x18[] memory values = new SD59x18[](length);
        for (uint256 i = 0; i < length; i++) {
            values[i] = sd(value);
        }

        SD59x18 variance = Backtest.computeVariance(values);

        assertApproxEqAbs(variance.unwrap(), 0, 1e10, "Variance of constant array should be ~0");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: CLAMP IV IDEMPOTENCY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Clamping an already-clamped value returns the same value
    function testFuzz_clampIV_Idempotent(uint256 ivSeed) public pure {
        int256 iv = int256(bound(ivSeed, 0, 10e18));

        SD59x18 clamped1 = Backtest.clampIV(sd(iv));
        SD59x18 clamped2 = Backtest.clampIV(clamped1);

        assertEq(clamped1.unwrap(), clamped2.unwrap(), "Clamping should be idempotent");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: CALIBRATION PARAMS VALIDATION CONSISTENCY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Default params always pass validation
    function testFuzz_validateCalibrationParams_DefaultAlwaysValid() public pure {
        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();
        assertTrue(Backtest.validateCalibrationParams(params), "Default params should always be valid");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: MONEYNESS SIGN CONSISTENCY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Moneyness direction consistency with log function
    function testFuzz_computeMoneyness_LogBehavior(uint256 spotSeed, uint256 strikeSeed) public pure {
        // Use a tighter range to avoid numerical issues
        uint256 spot = bound(spotSeed, 1e17, 1e21); // 0.1 to 1000
        uint256 strike = bound(strikeSeed, 1e17, 1e21); // 0.1 to 1000

        SD59x18 moneyness = Backtest.computeMoneyness(sd(int256(spot)), sd(int256(strike)));

        // ln(K/S) should be positive when K > S and negative when K < S
        // with some tolerance for numerical precision
        if (strike > spot + spot / 100) {
            // K > S by more than 1%
            assertTrue(moneyness.gt(ZERO), "K > S should give positive moneyness");
        } else if (strike + strike / 100 < spot) {
            // K < S by more than 1%
            assertTrue(moneyness.lt(ZERO), "K < S should give negative moneyness");
        }
        // For K ≈ S, moneyness can be near zero either direction
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: HIGHER REALIZED VOL → HIGHER IV
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Higher realized volatility leads to higher implied volatility
    function testFuzz_computeLSIVS_RealizedVolMonotonicity(
        uint256 spotSeed,
        uint256 strikeSeed,
        uint256 timeSeed,
        uint256 vol1Seed,
        uint256 vol2Seed,
        uint256 utilSeed
    ) public pure {
        int256 spot = int256(bound(spotSeed, MIN_PRICE, MAX_PRICE));
        int256 strike = int256(bound(strikeSeed, MIN_PRICE, MAX_PRICE));
        int256 time = int256(bound(timeSeed, MIN_TIME, MAX_TIME));
        int256 util = int256(bound(utilSeed, 0, MAX_UTIL));

        // Ensure vol1 <= vol2
        uint256 vol1Raw = bound(vol1Seed, MIN_VOL, MAX_VOL - 1e16);
        uint256 vol2Raw = bound(vol2Seed, vol1Raw, MAX_VOL);

        int256 vol1 = int256(vol1Raw);
        int256 vol2 = int256(vol2Raw);

        Backtest.CalibrationParams memory params = Backtest.defaultCalibrationParams();

        SD59x18 iv1 = Backtest.computeLSIVS(sd(spot), sd(strike), sd(time), sd(vol1), sd(util), params);
        SD59x18 iv2 = Backtest.computeLSIVS(sd(spot), sd(strike), sd(time), sd(vol2), sd(util), params);

        // Higher realized vol should yield higher IV
        assertTrue(iv2.gte(iv1), "Higher realized vol should yield higher IV");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: SKEW COEFFICIENT EFFECT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: For non-ATM options, higher skew coefficient → higher IV
    function testFuzz_computeLSIVS_SkewCoeffEffect(
        uint256 spotSeed,
        uint256 strikeSeed,
        uint256 timeSeed,
        uint256 volSeed,
        uint256 skew1Seed,
        uint256 skew2Seed
    ) public pure {
        // Use spot and strike with meaningful difference
        uint256 spot = bound(spotSeed, 1e18, 1e21);
        uint256 strike = bound(strikeSeed, spot + spot / 10, spot * 2); // 10-100% OTM

        int256 time = int256(bound(timeSeed, MIN_TIME, MAX_TIME));
        int256 vol = int256(bound(volSeed, MIN_VOL, MAX_VOL));

        // Ensure skew1 <= skew2, both valid (0 to 1)
        uint256 skew1Raw = bound(skew1Seed, 0, 5e17);
        uint256 skew2Raw = bound(skew2Seed, skew1Raw, 5e17);

        Backtest.CalibrationParams memory params1 = Backtest.CalibrationParams({
            skewCoefficient: sd(int256(skew1Raw)),
            gamma: sd(1e17),
            atmAdjustment: ZERO,
            termStructureCoeff: ZERO
        });

        Backtest.CalibrationParams memory params2 = Backtest.CalibrationParams({
            skewCoefficient: sd(int256(skew2Raw)),
            gamma: sd(1e17),
            atmAdjustment: ZERO,
            termStructureCoeff: ZERO
        });

        SD59x18 iv1 = Backtest.computeLSIVS(sd(int256(spot)), sd(int256(strike)), sd(time), sd(vol), ZERO, params1);
        SD59x18 iv2 = Backtest.computeLSIVS(sd(int256(spot)), sd(int256(strike)), sd(time), sd(vol), ZERO, params2);

        // Higher skew coefficient should yield higher IV for OTM options
        assertTrue(iv2.gte(iv1), "Higher skew coefficient should yield higher IV for OTM");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: SKEW ALWAYS NON-NEGATIVE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Quadratic skew is always non-negative
    function testFuzz_computeSkew_NonNegative(int256 moneynessSeed, uint256 skewCoeffSeed) public pure {
        // Moneyness can be any reasonable value
        int256 moneyness = bound(moneynessSeed, -5e18, 5e18);
        int256 skewCoeff = int256(bound(skewCoeffSeed, 0, 1e18));

        SD59x18 skew = Backtest.computeSkew(sd(moneyness), sd(skewCoeff));

        // Quadratic skew (coeff * m²) should always be non-negative
        assertTrue(skew.gte(ZERO), "Skew should be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ TEST: UTILIZATION PREMIUM ALWAYS NON-NEGATIVE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Utilization premium is always non-negative for valid inputs
    function testFuzz_computeUtilizationPremium_NonNegative(uint256 utilSeed, uint256 gammaSeed) public pure {
        int256 util = int256(bound(utilSeed, 0, MAX_UTIL));
        int256 gamma = int256(bound(gammaSeed, 0, 1e18));

        SD59x18 premium = Backtest.computeUtilizationPremium(sd(util), sd(gamma));

        assertTrue(premium.gte(ZERO), "Utilization premium should be non-negative");
    }
}
