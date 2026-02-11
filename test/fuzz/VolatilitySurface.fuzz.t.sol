// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { VolatilitySurface } from "../../src/libraries/VolatilitySurface.sol";

/// @title VolatilitySurfaceFuzzTest
/// @notice Fuzz tests for VolatilitySurface library invariants
contract VolatilitySurfaceFuzzTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    int256 private constant ONE = 1e18;

    // Bounds for fuzzing
    int256 private constant MIN_PRICE = 1e15; // 0.001 (very small price)
    int256 private constant MAX_PRICE = 1_000_000e18; // 1 million (very large price)

    int256 private constant MIN_VOL = 1e16; // 1%
    int256 private constant MAX_VOL = 3e18; // 300%

    int256 private constant MIN_UTIL = 0; // 0%
    int256 private constant MAX_UTIL = 98e16; // 98% (before circuit breaker)

    int256 private constant MIN_TIME = 1e15; // ~0.001 years
    int256 private constant MAX_TIME = 2e18; // 2 years

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                    INVARIANT: IV ALWAYS WITHIN BOUNDS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice IV is always clamped within floor and ceiling
    function testFuzz_getImpliedVolatility_AlwaysWithinBounds(
        int256 spotRaw,
        int256 strikeRaw,
        int256 realizedVolRaw,
        uint256 lockedCollateral,
        uint256 totalAssets
    ) public pure {
        // Bound inputs to valid ranges
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        realizedVolRaw = bound(realizedVolRaw, MIN_VOL, MAX_VOL);

        // Ensure valid pool state
        totalAssets = bound(totalAssets, 1e6, 1_000_000_000e6);
        lockedCollateral = bound(lockedCollateral, 0, totalAssets * 98 / 100); // Max 98%

        VolatilitySurface.IVParams memory params = VolatilitySurface.IVParams({
            spot: sd(spotRaw),
            strike: sd(strikeRaw),
            realizedVol: sd(realizedVolRaw),
            timeToExpiry: sd(ONE)
        });

        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: totalAssets, lockedCollateral: lockedCollateral });

        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        SD59x18 iv = VolatilitySurface.getImpliedVolatility(params, poolState, config);

        // INVARIANT: IV must be within bounds
        assertTrue(iv.gte(config.ivFloor), "IV below floor");
        assertTrue(iv.lte(config.ivCeiling), "IV above ceiling");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                               INVARIANT: ATM SKEW IS ALWAYS ZERO
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice When strike equals spot, skew is always zero
    function testFuzz_calculateSkew_ATMAlwaysZero(int256 price, int256 coeffRaw) public pure {
        price = bound(price, MIN_PRICE, MAX_PRICE);
        coeffRaw = bound(coeffRaw, 0, ONE); // Coefficient between 0 and 1

        SD59x18 skew = VolatilitySurface.calculateSkew(sd(price), sd(price), sd(coeffRaw));

        // INVARIANT: ATM skew is zero
        assertEq(SD59x18.unwrap(skew), 0, "ATM skew should be zero");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                           INVARIANT: SKEW ALWAYS NON-NEGATIVE (SMILE SHAPE)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Skew is always non-negative for any strike
    function testFuzz_calculateSkew_AlwaysNonNegative(int256 spotRaw, int256 strikeRaw, int256 coeffRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        coeffRaw = bound(coeffRaw, 0, ONE);

        SD59x18 skew = VolatilitySurface.calculateSkew(sd(spotRaw), sd(strikeRaw), sd(coeffRaw));

        // INVARIANT: Skew is always >= 0 (smile shape)
        assertTrue(skew.gte(ZERO), "Skew must be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                        INVARIANT: UTILIZATION PREMIUM ALWAYS NON-NEGATIVE
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Utilization premium is always non-negative
    function testFuzz_calculateUtilizationPremium_AlwaysNonNegative(int256 utilRaw, int256 gammaRaw) public pure {
        utilRaw = bound(utilRaw, 0, MAX_UTIL);
        gammaRaw = bound(gammaRaw, 0, 2e18); // Gamma between 0 and 2

        SD59x18 premium = VolatilitySurface.calculateUtilizationPremium(sd(utilRaw), sd(gammaRaw));

        // INVARIANT: Premium is always >= 0
        assertTrue(premium.gte(ZERO), "Premium must be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                     INVARIANT: UTILIZATION PREMIUM MONOTONICALLY INCREASING
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Higher utilization always means higher premium (monotonic)
    function testFuzz_calculateUtilizationPremium_Monotonic(int256 util1Raw, int256 util2Raw, int256 gammaRaw)
        public
        pure
    {
        util1Raw = bound(util1Raw, 0, MAX_UTIL - 1e16);
        util2Raw = bound(util2Raw, util1Raw + 1e16, MAX_UTIL);
        gammaRaw = bound(gammaRaw, 1e16, 2e18); // Positive gamma

        SD59x18 premium1 = VolatilitySurface.calculateUtilizationPremium(sd(util1Raw), sd(gammaRaw));
        SD59x18 premium2 = VolatilitySurface.calculateUtilizationPremium(sd(util2Raw), sd(gammaRaw));

        // INVARIANT: Higher utilization => higher premium
        assertTrue(premium2.gt(premium1), "Premium must increase with utilization");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                        INVARIANT: LINEAR INTERPOLATION IS MONOTONIC
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Linear interpolation maintains monotonicity between iv1 and iv2
    function testFuzz_interpolateLinear_Monotonic(
        int256 strike1Raw,
        int256 strike2Raw,
        int256 iv1Raw,
        int256 iv2Raw,
        int256 strikeARaw,
        int256 strikeBRaw
    ) public pure {
        // Ensure strike1 < strike2
        strike1Raw = bound(strike1Raw, MIN_PRICE, MAX_PRICE - 100e18);
        strike2Raw = bound(strike2Raw, strike1Raw + 1e18, MAX_PRICE);

        // Bound IVs
        iv1Raw = bound(iv1Raw, MIN_VOL, MAX_VOL);
        iv2Raw = bound(iv2Raw, MIN_VOL, MAX_VOL);

        // Two strikes within range
        strikeARaw = bound(strikeARaw, strike1Raw, strike2Raw);
        strikeBRaw = bound(strikeBRaw, strikeARaw, strike2Raw);

        SD59x18 ivA =
            VolatilitySurface.interpolateLinear(sd(strikeARaw), sd(strike1Raw), sd(strike2Raw), sd(iv1Raw), sd(iv2Raw));

        SD59x18 ivB =
            VolatilitySurface.interpolateLinear(sd(strikeBRaw), sd(strike1Raw), sd(strike2Raw), sd(iv1Raw), sd(iv2Raw));

        // INVARIANT: If iv1 <= iv2 and strikeA <= strikeB, then ivA <= ivB
        if (iv1Raw <= iv2Raw) {
            assertTrue(ivA.lte(ivB), "Interpolation should be monotonically increasing");
        } else {
            assertTrue(ivA.gte(ivB), "Interpolation should be monotonically decreasing");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                        INVARIANT: INTERPOLATION BOUNDS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Interpolated IV is always between iv1 and iv2
    function testFuzz_interpolateLinear_BoundedByEndpoints(
        int256 strike1Raw,
        int256 strike2Raw,
        int256 iv1Raw,
        int256 iv2Raw,
        int256 strikeRaw
    ) public pure {
        strike1Raw = bound(strike1Raw, MIN_PRICE, MAX_PRICE - 100e18);
        strike2Raw = bound(strike2Raw, strike1Raw + 1e18, MAX_PRICE);
        strikeRaw = bound(strikeRaw, strike1Raw, strike2Raw);

        iv1Raw = bound(iv1Raw, MIN_VOL, MAX_VOL);
        iv2Raw = bound(iv2Raw, MIN_VOL, MAX_VOL);

        SD59x18 iv =
            VolatilitySurface.interpolateLinear(sd(strikeRaw), sd(strike1Raw), sd(strike2Raw), sd(iv1Raw), sd(iv2Raw));

        int256 minIV = iv1Raw < iv2Raw ? iv1Raw : iv2Raw;
        int256 maxIV = iv1Raw > iv2Raw ? iv1Raw : iv2Raw;

        // INVARIANT: Result is bounded by endpoints
        assertTrue(SD59x18.unwrap(iv) >= minIV, "IV below minimum endpoint");
        assertTrue(SD59x18.unwrap(iv) <= maxIV, "IV above maximum endpoint");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                            INVARIANT: UTILIZATION CALCULATION
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Utilization is always between 0 and 1
    function testFuzz_calculateUtilization_BoundedZeroToOne(uint256 totalAssets, uint256 lockedCollateral)
        public
        pure
    {
        totalAssets = bound(totalAssets, 1, type(uint128).max);
        lockedCollateral = bound(lockedCollateral, 0, totalAssets);

        VolatilitySurface.PoolState memory poolState =
            VolatilitySurface.PoolState({ totalAssets: totalAssets, lockedCollateral: lockedCollateral });

        SD59x18 utilization = VolatilitySurface.calculateUtilization(poolState);

        // INVARIANT: 0 <= utilization <= 1
        assertTrue(utilization.gte(ZERO), "Utilization below zero");
        assertTrue(utilization.lte(sd(ONE)), "Utilization above one");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                            INVARIANT: MONEYNESS CALCULATION
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Moneyness is always positive for positive inputs
    function testFuzz_getMoneyness_AlwaysPositive(int256 spotRaw, int256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 moneyness = VolatilitySurface.getMoneyness(sd(spotRaw), sd(strikeRaw));

        // INVARIANT: Moneyness is always positive
        assertTrue(moneyness.gt(ZERO), "Moneyness must be positive");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                       INVARIANT: CLAMP IV ALWAYS PRODUCES VALID OUTPUT
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice clampIV always produces IV within bounds
    function testFuzz_clampIV_AlwaysWithinBounds(int256 ivRaw, int256 floorRaw, int256 ceilingRaw) public pure {
        // Ensure floor < ceiling
        floorRaw = bound(floorRaw, 1e16, ONE);
        ceilingRaw = bound(ceilingRaw, floorRaw + 1e16, 10e18);
        ivRaw = bound(ivRaw, -10e18, 20e18); // Allow extreme values

        SD59x18 clamped = VolatilitySurface.clampIV(sd(ivRaw), sd(floorRaw), sd(ceilingRaw));

        // INVARIANT: Result is always within [floor, ceiling]
        assertTrue(clamped.gte(sd(floorRaw)), "Clamped IV below floor");
        assertTrue(clamped.lte(sd(ceilingRaw)), "Clamped IV above ceiling");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                            INVARIANT: SKEW SYMMETRY (APPROXIMATE)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Symmetric strikes (K1 = S/x and K2 = S*x) have similar skew values
    function testFuzz_calculateSkew_ApproximateSymmetry(int256 spotRaw, int256 multiplierRaw, int256 coeffRaw)
        public
        pure
    {
        spotRaw = bound(spotRaw, 100e18, 10_000e18);
        // Multiplier between 1.01 and 2.0
        multiplierRaw = bound(multiplierRaw, 101e16, 2e18);
        coeffRaw = bound(coeffRaw, 1e16, ONE);

        // Calculate symmetric strikes
        // K1 = S * m, K2 = S / m
        int256 strike1Raw = (spotRaw * multiplierRaw) / ONE;
        int256 strike2Raw = (spotRaw * ONE) / multiplierRaw;

        SD59x18 skew1 = VolatilitySurface.calculateSkew(sd(spotRaw), sd(strike1Raw), sd(coeffRaw));
        SD59x18 skew2 = VolatilitySurface.calculateSkew(sd(spotRaw), sd(strike2Raw), sd(coeffRaw));

        // INVARIANT: Skews should be approximately equal for symmetric strikes
        // Due to log-moneyness^2, they should be exactly equal
        // Allow small tolerance for rounding
        int256 diff = SD59x18.unwrap(skew1) - SD59x18.unwrap(skew2);
        if (diff < 0) diff = -diff;

        assertTrue(diff < 1e12, "Symmetric strikes should have equal skew");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                     INVARIANT: IV INCREASES WITH UTILIZATION
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Higher utilization always results in higher or equal IV
    function testFuzz_getImpliedVolatility_IncreasesWithUtilization(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        uint256 util1,
        uint256 util2,
        uint256 totalAssets
    ) public pure {
        spotRaw = bound(spotRaw, 100e18, 10_000e18);
        strikeRaw = bound(strikeRaw, 100e18, 10_000e18);
        volRaw = bound(volRaw, 5e16, 2e18); // 5% to 200%
        totalAssets = bound(totalAssets, 1_000_000e6, 100_000_000e6);

        // Ensure util1 < util2, both under 98%
        util1 = bound(util1, 0, 96);
        util2 = bound(util2, util1 + 1, 98);

        VolatilitySurface.IVParams memory params = VolatilitySurface.IVParams({
            spot: sd(spotRaw),
            strike: sd(strikeRaw),
            realizedVol: sd(volRaw),
            timeToExpiry: sd(ONE)
        });

        VolatilitySurface.PoolState memory lowUtil =
            VolatilitySurface.PoolState({ totalAssets: totalAssets, lockedCollateral: totalAssets * util1 / 100 });

        VolatilitySurface.PoolState memory highUtil =
            VolatilitySurface.PoolState({ totalAssets: totalAssets, lockedCollateral: totalAssets * util2 / 100 });

        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        SD59x18 ivLow = VolatilitySurface.getImpliedVolatility(params, lowUtil, config);
        SD59x18 ivHigh = VolatilitySurface.getImpliedVolatility(params, highUtil, config);

        // INVARIANT: Higher utilization => higher or equal IV
        assertTrue(ivHigh.gte(ivLow), "IV should increase with utilization");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                          INVARIANT: CUBIC INTERPOLATION BOUNDARY VALUES
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Cubic interpolation matches endpoint values at boundaries
    function testFuzz_interpolateCubic_MatchesEndpoints(
        int256 strike1Raw,
        int256 strike2Raw,
        int256 iv1Raw,
        int256 iv2Raw,
        int256 slope1Raw,
        int256 slope2Raw
    ) public pure {
        strike1Raw = bound(strike1Raw, MIN_PRICE, MAX_PRICE - 100e18);
        strike2Raw = bound(strike2Raw, strike1Raw + 1e18, MAX_PRICE);
        iv1Raw = bound(iv1Raw, MIN_VOL, MAX_VOL);
        iv2Raw = bound(iv2Raw, MIN_VOL, MAX_VOL);
        slope1Raw = bound(slope1Raw, -ONE, ONE);
        slope2Raw = bound(slope2Raw, -ONE, ONE);

        SD59x18 ivAtLower = VolatilitySurface.interpolateCubic(
            sd(strike1Raw), sd(strike1Raw), sd(strike2Raw), sd(iv1Raw), sd(iv2Raw), sd(slope1Raw), sd(slope2Raw)
        );

        SD59x18 ivAtUpper = VolatilitySurface.interpolateCubic(
            sd(strike2Raw), sd(strike1Raw), sd(strike2Raw), sd(iv1Raw), sd(iv2Raw), sd(slope1Raw), sd(slope2Raw)
        );

        // INVARIANT: Cubic interpolation matches endpoints exactly
        assertEq(SD59x18.unwrap(ivAtLower), iv1Raw, "Lower boundary mismatch");
        assertEq(SD59x18.unwrap(ivAtUpper), iv2Raw, "Upper boundary mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                 INVARIANT: CONFIG VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Default config is always valid
    function testFuzz_validateConfig_DefaultIsValid() public pure {
        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.getDefaultConfig();

        // INVARIANT: Default config is always valid
        assertTrue(VolatilitySurface.validateConfig(config), "Default config must be valid");
    }

    /// @notice Config with floor >= ceiling is always invalid
    function testFuzz_validateConfig_InvalidWhenFloorGteCeiling(
        int256 floorRaw,
        int256 ceilingRaw,
        int256 gammaRaw,
        int256 skewRaw
    ) public pure {
        // Make floor >= ceiling
        floorRaw = bound(floorRaw, 1e16, 10e18);
        ceilingRaw = bound(ceilingRaw, 1e16, floorRaw);

        gammaRaw = bound(gammaRaw, 0, 2e18);
        skewRaw = bound(skewRaw, 0, ONE);

        VolatilitySurface.SurfaceConfig memory config = VolatilitySurface.SurfaceConfig({
            ivFloor: sd(floorRaw),
            ivCeiling: sd(ceilingRaw),
            gamma: sd(gammaRaw),
            skewCoefficient: sd(skewRaw)
        });

        // INVARIANT: Config with floor >= ceiling is invalid
        assertFalse(VolatilitySurface.validateConfig(config), "Config with floor >= ceiling must be invalid");
    }
}
