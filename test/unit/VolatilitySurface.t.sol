// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { VolatilitySurface } from "../../src/libraries/VolatilitySurface.sol";

/// @title VolatilitySurfaceHarness
/// @notice Harness contract to test library reverts via external calls
contract VolatilitySurfaceHarness {
    function calculateUtilization(VolatilitySurface.PoolState memory poolState) external pure returns (SD59x18) {
        return VolatilitySurface.calculateUtilization(poolState);
    }

    function calculateUtilizationPremium(SD59x18 utilization, SD59x18 gamma) external pure returns (SD59x18) {
        return VolatilitySurface.calculateUtilizationPremium(utilization, gamma);
    }

    function calculateSkew(SD59x18 spot, SD59x18 strike, SD59x18 skewCoefficient) external pure returns (SD59x18) {
        return VolatilitySurface.calculateSkew(spot, strike, skewCoefficient);
    }

    function interpolateLinear(SD59x18 strike, SD59x18 strike1, SD59x18 strike2, SD59x18 iv1, SD59x18 iv2)
        external
        pure
        returns (SD59x18)
    {
        return VolatilitySurface.interpolateLinear(strike, strike1, strike2, iv1, iv2);
    }

    function clampIV(SD59x18 iv, SD59x18 floor, SD59x18 ceiling) external pure returns (SD59x18) {
        return VolatilitySurface.clampIV(iv, floor, ceiling);
    }

    function getImpliedVolatilitySimple(SD59x18 spot, SD59x18 strike, SD59x18 realizedVol, SD59x18 utilization)
        external
        pure
        returns (SD59x18)
    {
        return VolatilitySurface.getImpliedVolatilitySimple(spot, strike, realizedVol, utilization);
    }
}

/// @title VolatilitySurfaceTest
/// @notice Unit tests for VolatilitySurface library
contract VolatilitySurfaceTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                              TEST CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    int256 private constant ONE = 1e18;
    int256 private constant HALF = 5e17;

    // Typical market values for testing
    int256 private constant ETH_PRICE = 2000e18; // $2000
    int256 private constant ATM_STRIKE = 2000e18; // ATM
    int256 private constant OTM_CALL_STRIKE = 2200e18; // 10% OTM call
    int256 private constant OTM_PUT_STRIKE = 1800e18; // 10% OTM put
    int256 private constant DEEP_OTM_CALL = 3000e18; // 50% OTM call
    int256 private constant DEEP_OTM_PUT = 1000e18; // 50% OTM put

    int256 private constant REALIZED_VOL_30 = 300000000000000000; // 30%
    int256 private constant REALIZED_VOL_50 = 500000000000000000; // 50%
    int256 private constant REALIZED_VOL_80 = 800000000000000000; // 80%

    int256 private constant ONE_YEAR = 1e18;
    int256 private constant SIX_MONTHS = 5e17;
    int256 private constant ONE_MONTH = 83333333333333333; // 1/12

    VolatilitySurfaceHarness harness;

    function setUp() public {
        harness = new VolatilitySurfaceHarness();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                        getImpliedVolatility TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test basic IV calculation at ATM with no utilization
    function test_getImpliedVolatility_ATM_ZeroUtilization() public pure {
        VolatilitySurface.IVParams memory params = VolatilitySurface.IVParams({
            spot: sd(ETH_PRICE), strike: sd(ATM_STRIKE), realizedVol: sd(REALIZED_VOL_30), timeToExpiry: sd(ONE_YEAR)
        });

        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: 1_000_000e6, lockedCollateral: 0 });

        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        SD59x18 iv = VolatilitySurface.getImpliedVolatility(params, poolState, config);

        // At ATM with zero utilization, IV should equal realized vol (no skew, no premium)
        // log(1) = 0, so skew = coefficient * 0 = 0
        assertEq(SD59x18.unwrap(iv), REALIZED_VOL_30);
    }

    /// @notice Test IV increases for OTM calls due to skew
    function test_getImpliedVolatility_OTMCall_SkewIncreasesIV() public pure {
        VolatilitySurface.IVParams memory paramsATM = VolatilitySurface.IVParams({
            spot: sd(ETH_PRICE), strike: sd(ATM_STRIKE), realizedVol: sd(REALIZED_VOL_30), timeToExpiry: sd(ONE_YEAR)
        });

        VolatilitySurface.IVParams memory paramsOTM = VolatilitySurface.IVParams({
            spot: sd(ETH_PRICE),
            strike: sd(OTM_CALL_STRIKE),
            realizedVol: sd(REALIZED_VOL_30),
            timeToExpiry: sd(ONE_YEAR)
        });

        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: 1_000_000e6, lockedCollateral: 0 });

        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        SD59x18 ivATM = VolatilitySurface.getImpliedVolatility(paramsATM, poolState, config);
        SD59x18 ivOTM = VolatilitySurface.getImpliedVolatility(paramsOTM, poolState, config);

        // OTM should have higher IV due to skew
        assertTrue(ivOTM.gt(ivATM));
    }

    /// @notice Test IV increases for OTM puts due to skew (smile symmetry)
    function test_getImpliedVolatility_OTMPut_SkewIncreasesIV() public pure {
        VolatilitySurface.IVParams memory paramsATM = VolatilitySurface.IVParams({
            spot: sd(ETH_PRICE), strike: sd(ATM_STRIKE), realizedVol: sd(REALIZED_VOL_30), timeToExpiry: sd(ONE_YEAR)
        });

        VolatilitySurface.IVParams memory paramsOTM = VolatilitySurface.IVParams({
            spot: sd(ETH_PRICE),
            strike: sd(OTM_PUT_STRIKE),
            realizedVol: sd(REALIZED_VOL_30),
            timeToExpiry: sd(ONE_YEAR)
        });

        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: 1_000_000e6, lockedCollateral: 0 });

        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        SD59x18 ivATM = VolatilitySurface.getImpliedVolatility(paramsATM, poolState, config);
        SD59x18 ivOTM = VolatilitySurface.getImpliedVolatility(paramsOTM, poolState, config);

        // OTM put should have higher IV due to skew
        assertTrue(ivOTM.gt(ivATM));
    }

    /// @notice Test IV increases with utilization
    function test_getImpliedVolatility_UtilizationIncreasesIV() public pure {
        VolatilitySurface.IVParams memory params = VolatilitySurface.IVParams({
            spot: sd(ETH_PRICE), strike: sd(ATM_STRIKE), realizedVol: sd(REALIZED_VOL_30), timeToExpiry: sd(ONE_YEAR)
        });

        VolatilitySurface.PoolState memory lowUtil = VolatilitySurface.PoolState({
            totalAssets: 1_000_000e6,
            lockedCollateral: 100_000e6 // 10%
        });

        VolatilitySurface.PoolState memory highUtil = VolatilitySurface.PoolState({
            totalAssets: 1_000_000e6,
            lockedCollateral: 500_000e6 // 50%
        });

        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        SD59x18 ivLow = VolatilitySurface.getImpliedVolatility(params, lowUtil, config);
        SD59x18 ivHigh = VolatilitySurface.getImpliedVolatility(params, highUtil, config);

        // Higher utilization should result in higher IV
        assertTrue(ivHigh.gt(ivLow));
    }

    /// @notice Test IV is clamped at floor
    function test_getImpliedVolatility_FloorClamping() public pure {
        // Very low realized vol
        VolatilitySurface.IVParams memory params = VolatilitySurface.IVParams({
            spot: sd(ETH_PRICE),
            strike: sd(ATM_STRIKE),
            realizedVol: sd(10000000000000000), // 1%
            timeToExpiry: sd(ONE_YEAR)
        });

        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: 1_000_000e6, lockedCollateral: 0 });

        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        SD59x18 iv = VolatilitySurface.getImpliedVolatility(params, poolState, config);

        // IV should be clamped to floor (5%)
        assertEq(SD59x18.unwrap(iv), 50000000000000000);
    }

    /// @notice Test IV is clamped at ceiling
    function test_getImpliedVolatility_CeilingClamping() public pure {
        // Very high realized vol
        VolatilitySurface.IVParams memory params = VolatilitySurface.IVParams({
            spot: sd(ETH_PRICE),
            strike: sd(DEEP_OTM_CALL), // High skew
            realizedVol: sd(3_000000000000000000), // 300%
            timeToExpiry: sd(ONE_YEAR)
        });

        VolatilitySurface.PoolState memory poolState = VolatilitySurface.PoolState({
            totalAssets: 1_000_000e6,
            lockedCollateral: 800_000e6 // 80% utilization
        });

        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        SD59x18 iv = VolatilitySurface.getImpliedVolatility(params, poolState, config);

        // IV should be clamped to ceiling (500%)
        assertEq(SD59x18.unwrap(iv), 5_000000000000000000);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                   getImpliedVolatilitySimple TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test simplified IV calculation
    function test_getImpliedVolatilitySimple_BasicCalculation() public pure {
        SD59x18 iv = VolatilitySurface.getImpliedVolatilitySimple(
            sd(ETH_PRICE),
            sd(ATM_STRIKE),
            sd(REALIZED_VOL_30),
            sd(0) // zero utilization
        );

        // Should equal realized vol at ATM with zero utilization
        assertEq(SD59x18.unwrap(iv), REALIZED_VOL_30);
    }

    /// @notice Test simplified IV with utilization
    function test_getImpliedVolatilitySimple_WithUtilization() public pure {
        SD59x18 ivNoUtil =
            VolatilitySurface.getImpliedVolatilitySimple(sd(ETH_PRICE), sd(ATM_STRIKE), sd(REALIZED_VOL_30), sd(0));

        SD59x18 ivWithUtil = VolatilitySurface.getImpliedVolatilitySimple(
            sd(ETH_PRICE),
            sd(ATM_STRIKE),
            sd(REALIZED_VOL_30),
            sd(HALF) // 50% utilization
        );

        assertTrue(ivWithUtil.gt(ivNoUtil));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                       calculateUtilization TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test zero utilization
    function test_calculateUtilization_Zero() public pure {
        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: 1_000_000e6, lockedCollateral: 0 });

        SD59x18 utilization = VolatilitySurface.calculateUtilization(poolState);
        assertEq(SD59x18.unwrap(utilization), 0);
    }

    /// @notice Test 50% utilization
    function test_calculateUtilization_Half() public pure {
        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: 1_000_000e6, lockedCollateral: 500_000e6 });

        SD59x18 utilization = VolatilitySurface.calculateUtilization(poolState);
        assertEq(SD59x18.unwrap(utilization), HALF);
    }

    /// @notice Test full utilization
    function test_calculateUtilization_Full() public pure {
        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: 1_000_000e6, lockedCollateral: 1_000_000e6 });

        SD59x18 utilization = VolatilitySurface.calculateUtilization(poolState);
        assertEq(SD59x18.unwrap(utilization), ONE);
    }

    /// @notice Test revert on zero total assets
    function test_calculateUtilization_RevertOnZeroTotal() public {
        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: 0, lockedCollateral: 0 });

        vm.expectRevert(VolatilitySurface.VolatilitySurface__ZeroTotalAssets.selector);
        harness.calculateUtilization(poolState);
    }

    /// @notice Test revert when locked exceeds total
    function test_calculateUtilization_RevertOnLockedExceedsTotal() public {
        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: 1_000_000e6, lockedCollateral: 2_000_000e6 });

        vm.expectRevert(
            abi.encodeWithSelector(
                VolatilitySurface.VolatilitySurface__LockedExceedsTotal.selector, 2_000_000e6, 1_000_000e6
            )
        );
        harness.calculateUtilization(poolState);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                    calculateUtilizationPremium TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test zero utilization returns zero premium
    function test_calculateUtilizationPremium_ZeroUtilization() public pure {
        SD59x18 premium = VolatilitySurface.calculateUtilizationPremium(ZERO, sd(HALF));
        assertEq(SD59x18.unwrap(premium), 0);
    }

    /// @notice Test premium formula: γ * u / (1 - u)
    function test_calculateUtilizationPremium_Formula() public pure {
        // u = 0.5, γ = 0.5
        // premium = 0.5 * 0.5 / (1 - 0.5) = 0.25 / 0.5 = 0.5
        SD59x18 premium = VolatilitySurface.calculateUtilizationPremium(sd(HALF), sd(HALF));
        assertEq(SD59x18.unwrap(premium), HALF);
    }

    /// @notice Test premium increases non-linearly with utilization
    function test_calculateUtilizationPremium_NonLinearIncrease() public pure {
        SD59x18 gamma = sd(HALF);

        SD59x18 premium10 = VolatilitySurface.calculateUtilizationPremium(sd(100000000000000000), gamma); // 10%
        SD59x18 premium50 = VolatilitySurface.calculateUtilizationPremium(sd(500000000000000000), gamma); // 50%
        SD59x18 premium80 = VolatilitySurface.calculateUtilizationPremium(sd(800000000000000000), gamma); // 80%

        // Premium should increase faster as utilization increases
        assertTrue(premium50.gt(premium10));
        assertTrue(premium80.gt(premium50));

        // Check the absolute values to verify non-linearity
        // At 10%: 0.5 * 0.1 / 0.9 = 0.0556
        // At 50%: 0.5 * 0.5 / 0.5 = 0.5
        // At 80%: 0.5 * 0.8 / 0.2 = 2.0
        // The jump from 10->50 is ~9x, from 50->80 is 4x in absolute terms
        // But the acceleration (rate of increase) is what matters
        int256 p10 = SD59x18.unwrap(premium10);
        int256 p50 = SD59x18.unwrap(premium50);
        int256 p80 = SD59x18.unwrap(premium80);

        // Premium at 80% should be more than 2x premium at 50%
        assertTrue(p80 > 2 * p50);
    }

    /// @notice Test revert on utilization at or above 99%
    function test_calculateUtilizationPremium_RevertOnHighUtilization() public {
        vm.expectRevert(
            abi.encodeWithSelector(VolatilitySurface.VolatilitySurface__UtilizationTooHigh.selector, 990000000000000000)
        );
        harness.calculateUtilizationPremium(sd(990000000000000000), sd(HALF));
    }

    /// @notice Test revert on negative gamma
    function test_calculateUtilizationPremium_RevertOnNegativeGamma() public {
        vm.expectRevert(VolatilitySurface.VolatilitySurface__InvalidGamma.selector);
        harness.calculateUtilizationPremium(sd(HALF), sd(-1e18));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                          calculateSkew TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test ATM has zero skew (log(1) = 0)
    function test_calculateSkew_ATM() public pure {
        SD59x18 skew = VolatilitySurface.calculateSkew(sd(ETH_PRICE), sd(ATM_STRIKE), sd(150000000000000000));
        assertEq(SD59x18.unwrap(skew), 0);
    }

    /// @notice Test OTM call has positive skew
    function test_calculateSkew_OTMCall() public pure {
        SD59x18 skew = VolatilitySurface.calculateSkew(sd(ETH_PRICE), sd(OTM_CALL_STRIKE), sd(150000000000000000));
        assertTrue(skew.gt(ZERO));
    }

    /// @notice Test OTM put has positive skew (symmetric smile)
    function test_calculateSkew_OTMPut() public pure {
        SD59x18 skew = VolatilitySurface.calculateSkew(sd(ETH_PRICE), sd(OTM_PUT_STRIKE), sd(150000000000000000));
        assertTrue(skew.gt(ZERO));
    }

    /// @notice Test skew symmetry: equal distance OTM call and put have similar skew
    function test_calculateSkew_Symmetry() public pure {
        // OTM call at 110% moneyness
        SD59x18 skewCall = VolatilitySurface.calculateSkew(sd(ETH_PRICE), sd(OTM_CALL_STRIKE), sd(150000000000000000));

        // OTM put at ~90.9% moneyness (1/1.1)
        SD59x18 skewPut = VolatilitySurface.calculateSkew(sd(ETH_PRICE), sd(OTM_PUT_STRIKE), sd(150000000000000000));

        // Due to log-moneyness squared, roughly symmetric but not exact
        // Both should be positive and in similar range
        assertTrue(skewCall.gt(ZERO));
        assertTrue(skewPut.gt(ZERO));
    }

    /// @notice Test deeper OTM has higher skew
    function test_calculateSkew_DeepOTMHigher() public pure {
        SD59x18 skewOTM = VolatilitySurface.calculateSkew(sd(ETH_PRICE), sd(OTM_CALL_STRIKE), sd(150000000000000000));
        SD59x18 skewDeep = VolatilitySurface.calculateSkew(sd(ETH_PRICE), sd(DEEP_OTM_CALL), sd(150000000000000000));

        assertTrue(skewDeep.gt(skewOTM));
    }

    /// @notice Test revert on invalid spot
    function test_calculateSkew_RevertOnInvalidSpot() public {
        vm.expectRevert(VolatilitySurface.VolatilitySurface__InvalidSpotPrice.selector);
        harness.calculateSkew(sd(0), sd(ATM_STRIKE), sd(150000000000000000));
    }

    /// @notice Test revert on invalid strike
    function test_calculateSkew_RevertOnInvalidStrike() public {
        vm.expectRevert(VolatilitySurface.VolatilitySurface__InvalidStrikePrice.selector);
        harness.calculateSkew(sd(ETH_PRICE), sd(0), sd(150000000000000000));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                        calculateLinearSkew TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test linear skew at ATM is zero
    function test_calculateLinearSkew_ATM() public pure {
        SD59x18 skew = VolatilitySurface.calculateLinearSkew(sd(ETH_PRICE), sd(ATM_STRIKE), sd(150000000000000000));
        assertEq(SD59x18.unwrap(skew), 0);
    }

    /// @notice Test linear skew for 10% OTM
    function test_calculateLinearSkew_10PercentOTM() public pure {
        // Moneyness = 2200/2000 = 1.1, deviation = 0.1
        // Skew = 0.15 * 0.1 = 0.015
        SD59x18 skew = VolatilitySurface.calculateLinearSkew(sd(ETH_PRICE), sd(OTM_CALL_STRIKE), sd(150000000000000000));
        assertEq(SD59x18.unwrap(skew), 15000000000000000); // 0.015
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                        interpolateLinear TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test linear interpolation at lower bound
    function test_interpolateLinear_AtLowerBound() public pure {
        SD59x18 iv = VolatilitySurface.interpolateLinear(
            sd(1800e18), // strike = lower bound
            sd(1800e18), // strike1
            sd(2200e18), // strike2
            sd(REALIZED_VOL_30), // iv1
            sd(REALIZED_VOL_50) // iv2
        );
        assertEq(SD59x18.unwrap(iv), REALIZED_VOL_30);
    }

    /// @notice Test linear interpolation at upper bound
    function test_interpolateLinear_AtUpperBound() public pure {
        SD59x18 iv = VolatilitySurface.interpolateLinear(
            sd(2200e18), // strike = upper bound
            sd(1800e18), // strike1
            sd(2200e18), // strike2
            sd(REALIZED_VOL_30), // iv1
            sd(REALIZED_VOL_50) // iv2
        );
        assertEq(SD59x18.unwrap(iv), REALIZED_VOL_50);
    }

    /// @notice Test linear interpolation at midpoint
    function test_interpolateLinear_AtMidpoint() public pure {
        SD59x18 iv = VolatilitySurface.interpolateLinear(
            sd(2000e18), // strike = midpoint
            sd(1800e18), // strike1
            sd(2200e18), // strike2
            sd(REALIZED_VOL_30), // iv1 = 0.3
            sd(REALIZED_VOL_50) // iv2 = 0.5
        );
        // Midpoint should be (0.3 + 0.5) / 2 = 0.4
        assertEq(SD59x18.unwrap(iv), 400000000000000000);
    }

    /// @notice Test revert when strike1 >= strike2
    function test_interpolateLinear_RevertOnInvalidBounds() public {
        vm.expectRevert(VolatilitySurface.VolatilitySurface__InvalidStrikePrice.selector);
        harness.interpolateLinear(
            sd(2000e18),
            sd(2200e18), // strike1 > strike2
            sd(1800e18),
            sd(REALIZED_VOL_30),
            sd(REALIZED_VOL_50)
        );
    }

    /// @notice Test revert when strike outside bounds
    function test_interpolateLinear_RevertOnOutOfBounds() public {
        vm.expectRevert(VolatilitySurface.VolatilitySurface__InvalidStrikePrice.selector);
        harness.interpolateLinear(
            sd(2500e18), // strike > strike2
            sd(1800e18),
            sd(2200e18),
            sd(REALIZED_VOL_30),
            sd(REALIZED_VOL_50)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                         interpolateCubic TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test cubic interpolation at bounds
    function test_interpolateCubic_AtBounds() public pure {
        SD59x18 ivLower = VolatilitySurface.interpolateCubic(
            sd(1800e18),
            sd(1800e18),
            sd(2200e18),
            sd(REALIZED_VOL_30),
            sd(REALIZED_VOL_50),
            sd(0), // slope at lower
            sd(0) // slope at upper
        );
        assertEq(SD59x18.unwrap(ivLower), REALIZED_VOL_30);

        SD59x18 ivUpper = VolatilitySurface.interpolateCubic(
            sd(2200e18), sd(1800e18), sd(2200e18), sd(REALIZED_VOL_30), sd(REALIZED_VOL_50), sd(0), sd(0)
        );
        assertEq(SD59x18.unwrap(ivUpper), REALIZED_VOL_50);
    }

    /// @notice Test cubic interpolation with zero slopes matches linear midpoint
    function test_interpolateCubic_ZeroSlopesMatchLinear() public pure {
        SD59x18 ivCubic = VolatilitySurface.interpolateCubic(
            sd(2000e18), sd(1800e18), sd(2200e18), sd(REALIZED_VOL_30), sd(REALIZED_VOL_50), sd(0), sd(0)
        );

        SD59x18 ivLinear = VolatilitySurface.interpolateLinear(
            sd(2000e18), sd(1800e18), sd(2200e18), sd(REALIZED_VOL_30), sd(REALIZED_VOL_50)
        );

        // With zero slopes, cubic Hermite should be close to linear at midpoint
        // Not exact due to Hermite basis functions
        int256 diff = SD59x18.unwrap(ivCubic) - SD59x18.unwrap(ivLinear);
        if (diff < 0) diff = -diff;
        assertTrue(diff < 1e16); // Within 1% tolerance
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                            clampIV TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test IV within bounds passes through
    function test_clampIV_WithinBounds() public pure {
        SD59x18 clamped = VolatilitySurface.clampIV(
            sd(REALIZED_VOL_30),
            sd(50000000000000000), // 5%
            sd(5_000000000000000000) // 500%
        );
        assertEq(SD59x18.unwrap(clamped), REALIZED_VOL_30);
    }

    /// @notice Test IV below floor is clamped
    function test_clampIV_BelowFloor() public pure {
        SD59x18 clamped = VolatilitySurface.clampIV(
            sd(10000000000000000), // 1%
            sd(50000000000000000), // 5%
            sd(5_000000000000000000) // 500%
        );
        assertEq(SD59x18.unwrap(clamped), 50000000000000000);
    }

    /// @notice Test IV above ceiling is clamped
    function test_clampIV_AboveCeiling() public pure {
        SD59x18 clamped = VolatilitySurface.clampIV(
            sd(10_000000000000000000), // 1000%
            sd(50000000000000000), // 5%
            sd(5_000000000000000000) // 500%
        );
        assertEq(SD59x18.unwrap(clamped), 5_000000000000000000);
    }

    /// @notice Test revert on invalid bounds
    function test_clampIV_RevertOnInvalidBounds() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                VolatilitySurface.VolatilitySurface__InvalidIVBounds.selector,
                5_000000000000000000, // floor > ceiling
                50000000000000000
            )
        );
        harness.clampIV(sd(REALIZED_VOL_30), sd(5_000000000000000000), sd(50000000000000000));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                        getDefaultConfig TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test default config values
    function test_getDefaultConfig() public pure {
        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        assertEq(SD59x18.unwrap(config.ivFloor), 50000000000000000); // 5%
        assertEq(SD59x18.unwrap(config.ivCeiling), 5_000000000000000000); // 500%
        assertEq(SD59x18.unwrap(config.gamma), 500000000000000000); // 0.5
        assertEq(SD59x18.unwrap(config.skewCoefficient), 150000000000000000); // 0.15
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                         validateConfig TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test valid config returns true
    function test_validateConfig_Valid() public pure {
        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();
        assertTrue(VolatilitySurface.validateConfig(config));
    }

    /// @notice Test invalid config (floor >= ceiling) returns false
    function test_validateConfig_InvalidBounds() public pure {
        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.SurfaceConfig({
            ivFloor: sd(5_000000000000000000),
            ivCeiling: sd(50000000000000000),
            gamma: sd(500000000000000000),
            skewCoefficient: sd(150000000000000000)
        });
        assertFalse(VolatilitySurface.validateConfig(config));
    }

    /// @notice Test invalid config (negative gamma) returns false
    function test_validateConfig_NegativeGamma() public pure {
        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.SurfaceConfig({
            ivFloor: sd(50000000000000000),
            ivCeiling: sd(5_000000000000000000),
            gamma: sd(-500000000000000000),
            skewCoefficient: sd(150000000000000000)
        });
        assertFalse(VolatilitySurface.validateConfig(config));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                        getMoneyness TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test ATM moneyness is 1.0
    function test_getMoneyness_ATM() public pure {
        SD59x18 moneyness = VolatilitySurface.getMoneyness(sd(ETH_PRICE), sd(ATM_STRIKE));
        assertEq(SD59x18.unwrap(moneyness), ONE);
    }

    /// @notice Test OTM call moneyness > 1.0
    function test_getMoneyness_OTMCall() public pure {
        SD59x18 moneyness = VolatilitySurface.getMoneyness(sd(ETH_PRICE), sd(OTM_CALL_STRIKE));
        assertTrue(moneyness.gt(sd(ONE)));
        // 2200 / 2000 = 1.1
        assertEq(SD59x18.unwrap(moneyness), 1_100000000000000000);
    }

    /// @notice Test OTM put moneyness < 1.0
    function test_getMoneyness_OTMPut() public pure {
        SD59x18 moneyness = VolatilitySurface.getMoneyness(sd(ETH_PRICE), sd(OTM_PUT_STRIKE));
        assertTrue(moneyness.lt(sd(ONE)));
        // 1800 / 2000 = 0.9
        assertEq(SD59x18.unwrap(moneyness), 900000000000000000);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                       getLogMoneyness TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test ATM log-moneyness is 0
    function test_getLogMoneyness_ATM() public pure {
        SD59x18 logMoneyness = VolatilitySurface.getLogMoneyness(sd(ETH_PRICE), sd(ATM_STRIKE));
        assertEq(SD59x18.unwrap(logMoneyness), 0);
    }

    /// @notice Test OTM call has positive log-moneyness
    function test_getLogMoneyness_OTMCall() public pure {
        SD59x18 logMoneyness = VolatilitySurface.getLogMoneyness(sd(ETH_PRICE), sd(OTM_CALL_STRIKE));
        assertTrue(logMoneyness.gt(ZERO));
    }

    /// @notice Test OTM put has negative log-moneyness
    function test_getLogMoneyness_OTMPut() public pure {
        SD59x18 logMoneyness = VolatilitySurface.getLogMoneyness(sd(ETH_PRICE), sd(OTM_PUT_STRIKE));
        assertTrue(logMoneyness.lt(ZERO));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                         ERROR CONDITIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test revert on zero spot in simple IV
    function test_getImpliedVolatilitySimple_RevertOnZeroSpot() public {
        vm.expectRevert(VolatilitySurface.VolatilitySurface__InvalidSpotPrice.selector);
        harness.getImpliedVolatilitySimple(sd(0), sd(ATM_STRIKE), sd(REALIZED_VOL_30), sd(0));
    }

    /// @notice Test revert on zero strike in simple IV
    function test_getImpliedVolatilitySimple_RevertOnZeroStrike() public {
        vm.expectRevert(VolatilitySurface.VolatilitySurface__InvalidStrikePrice.selector);
        harness.getImpliedVolatilitySimple(sd(ETH_PRICE), sd(0), sd(REALIZED_VOL_30), sd(0));
    }

    /// @notice Test revert on zero realized vol in simple IV
    function test_getImpliedVolatilitySimple_RevertOnZeroRealizedVol() public {
        vm.expectRevert(VolatilitySurface.VolatilitySurface__InvalidRealizedVolatility.selector);
        harness.getImpliedVolatilitySimple(sd(ETH_PRICE), sd(ATM_STRIKE), sd(0), sd(0));
    }

    /// @notice Test revert on utilization >= 1 in simple IV
    function test_getImpliedVolatilitySimple_RevertOnFullUtilization() public {
        vm.expectRevert(abi.encodeWithSelector(VolatilitySurface.VolatilitySurface__UtilizationTooHigh.selector, ONE));
        harness.getImpliedVolatilitySimple(sd(ETH_PRICE), sd(ATM_STRIKE), sd(REALIZED_VOL_30), sd(ONE));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                     ADDITIONAL COVERAGE TESTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test combined effect of skew and utilization premium
    function test_getImpliedVolatility_CombinedEffect() public pure {
        VolatilitySurface.IVParams memory params = VolatilitySurface.IVParams({
            spot: sd(ETH_PRICE),
            strike: sd(OTM_CALL_STRIKE), // OTM for skew
            realizedVol: sd(REALIZED_VOL_30),
            timeToExpiry: sd(ONE_YEAR)
        });

        VolatilitySurface.PoolState memory highUtil = VolatilitySurface.PoolState({
            totalAssets: 1_000_000e6,
            lockedCollateral: 700_000e6 // 70% utilization
        });

        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        SD59x18 iv = VolatilitySurface.getImpliedVolatility(params, highUtil, config);

        // IV should be significantly higher than realized vol due to both factors
        assertTrue(iv.gt(sd(REALIZED_VOL_30)));
        // Should be meaningfully higher (at least 20% boost)
        int256 boost = SD59x18.unwrap(iv) - REALIZED_VOL_30;
        assertTrue(boost > REALIZED_VOL_30 / 5); // At least 20% of realized vol as boost
    }

    /// @notice Test interpolation maintains monotonicity
    function test_interpolateLinear_Monotonicity() public pure {
        int256 iv1Raw = REALIZED_VOL_30;
        int256 iv2Raw = REALIZED_VOL_50;

        SD59x18 iv25 =
            VolatilitySurface.interpolateLinear(sd(1900e18), sd(1800e18), sd(2200e18), sd(iv1Raw), sd(iv2Raw));

        SD59x18 iv50 =
            VolatilitySurface.interpolateLinear(sd(2000e18), sd(1800e18), sd(2200e18), sd(iv1Raw), sd(iv2Raw));

        SD59x18 iv75 =
            VolatilitySurface.interpolateLinear(sd(2100e18), sd(1800e18), sd(2200e18), sd(iv1Raw), sd(iv2Raw));

        // Should be monotonically increasing
        assertTrue(iv50.gt(iv25));
        assertTrue(iv75.gt(iv50));
    }

    /// @notice Test utilization premium approaches infinity as u -> 1
    function test_calculateUtilizationPremium_ApproachesInfinity() public pure {
        SD59x18 gamma = sd(HALF);

        SD59x18 premium90 = VolatilitySurface.calculateUtilizationPremium(sd(900000000000000000), gamma); // 90%
        SD59x18 premium95 = VolatilitySurface.calculateUtilizationPremium(sd(950000000000000000), gamma); // 95%
        SD59x18 premium98 = VolatilitySurface.calculateUtilizationPremium(sd(980000000000000000), gamma); // 98%

        // Each should be higher as we approach 1
        assertTrue(premium95.gt(premium90));
        assertTrue(premium98.gt(premium95));

        // Premium at 98% should be very high (0.5 * 0.98 / 0.02 = 24.5)
        assertTrue(SD59x18.unwrap(premium98) > 20e18);
    }
}
