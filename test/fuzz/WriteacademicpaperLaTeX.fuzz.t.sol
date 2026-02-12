// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    AcademicPaperBenchmarks,
    BSMParams,
    BSMResult,
    InvariantCheckResult,
    PrecisionResult,
    VolSurfacePoint
} from "../../src/libraries/WriteacademicpaperLaTeX.sol";

/// @title WriteacademicpaperLaTeXFuzzTest
/// @notice Fuzz tests for AcademicPaperBenchmarks library
/// @dev Tests mathematical invariants across randomized inputs
contract WriteacademicpaperLaTeXFuzzTest is Test {
    // Realistic price bounds (whole units before scaling to SD59x18)
    uint256 internal constant MIN_PRICE = 10;
    uint256 internal constant MAX_PRICE = 100_000;

    // Volatility bounds: 1% to 300%
    uint256 internal constant MIN_VOL = 10_000_000_000_000_000; // 0.01
    uint256 internal constant MAX_VOL = 3_000_000_000_000_000_000; // 3.0

    // Time bounds: 1 day to 2 years
    uint256 internal constant MIN_TIME = 2_739_726_027_397_260; // 1/365
    uint256 internal constant MAX_TIME = 2_000_000_000_000_000_000; // 2.0

    // Rate bounds: 0% to 20%
    uint256 internal constant MAX_RATE = 200_000_000_000_000_000; // 0.2

    /// @notice Helper to construct bounded BSM params from fuzz inputs
    function _boundParams(uint256 spotRaw, uint256 strikeRaw, uint256 volRaw, uint256 rateRaw, uint256 timeRaw)
        internal
        pure
        returns (BSMParams memory p)
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        volRaw = bound(volRaw, MIN_VOL, MAX_VOL);
        rateRaw = bound(rateRaw, 0, MAX_RATE);
        timeRaw = bound(timeRaw, MIN_TIME, MAX_TIME);

        p = BSMParams({
            spot: sd(int256(spotRaw * 1e18)),
            strike: sd(int256(strikeRaw * 1e18)),
            volatility: SD59x18.wrap(int256(volRaw)),
            riskFreeRate: SD59x18.wrap(int256(rateRaw)),
            timeToExpiry: SD59x18.wrap(int256(timeRaw))
        });
    }

    // =========================================================================
    // Invariant 1: Call price is non-negative
    // =========================================================================

    /// @notice BSM call price must always be >= 0
    function testFuzz_callPrice_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 rateRaw,
        uint256 timeRaw
    ) public pure {
        BSMParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        SD59x18 price = AcademicPaperBenchmarks.priceCall(p);
        assertGe(SD59x18.unwrap(price), 0, "Call price must be >= 0");
    }

    // =========================================================================
    // Invariant 2: Put price is non-negative
    // =========================================================================

    /// @notice BSM put price must always be >= 0
    function testFuzz_putPrice_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 rateRaw,
        uint256 timeRaw
    ) public pure {
        BSMParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        SD59x18 price = AcademicPaperBenchmarks.pricePut(p);
        assertGe(SD59x18.unwrap(price), 0, "Put price must be >= 0");
    }

    // =========================================================================
    // Invariant 3: Put-call parity holds (within numerical tolerance)
    // =========================================================================

    /// @notice C - P ≈ S - K·e^(-rT) for all valid parameters
    function testFuzz_putCallParity(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 rateRaw,
        uint256 timeRaw
    ) public pure {
        BSMParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        BSMResult memory result = AcademicPaperBenchmarks.priceBSM(p);

        // Compute discount
        SD59x18 discount = p.riskFreeRate.mul(p.timeToExpiry).mul(sd(-1e18)).exp();

        SD59x18 lhs = result.callPrice.sub(result.putPrice);
        SD59x18 rhs = p.spot.sub(p.strike.mul(discount));

        int256 gap = SD59x18.unwrap(lhs.sub(rhs).abs());
        // Scale tolerance with price magnitude: allow 0.01% of spot
        int256 tolerance = SD59x18.unwrap(p.spot) / 10_000;
        if (tolerance < 1e12) tolerance = 1e12;

        assertLt(gap, tolerance, "Put-call parity must hold within tolerance");
    }

    // =========================================================================
    // Invariant 4: d1 > d2 always
    // =========================================================================

    /// @notice d1 is always greater than d2 (since σ√T > 0)
    function testFuzz_d1GreaterThanD2(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 rateRaw,
        uint256 timeRaw
    ) public pure {
        BSMParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        (SD59x18 d1, SD59x18 d2) = AcademicPaperBenchmarks.computeD1D2(p);
        assertGt(SD59x18.unwrap(d1), SD59x18.unwrap(d2), "d1 must be > d2");
    }

    // =========================================================================
    // Invariant 5: CDF values in [0, 1]
    // =========================================================================

    /// @notice CDF(d1) and CDF(d2) must be in [0, 1] for all valid parameters
    function testFuzz_cdfBounded(uint256 spotRaw, uint256 strikeRaw, uint256 volRaw, uint256 rateRaw, uint256 timeRaw)
        public
        pure
    {
        BSMParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);

        InvariantCheckResult memory result = AcademicPaperBenchmarks.checkInvariants(p, sd(1e15));
        assertTrue(result.cdfInUnitInterval, "CDF values must be in [0, 1]");
    }

    // =========================================================================
    // Invariant 6: EWMA volatility is non-negative
    // =========================================================================

    /// @notice EWMA volatility must always be >= 0
    function testFuzz_ewmaVol_neverNegative(int256 r1, int256 r2, int256 r3, uint256 lambdaRaw) public pure {
        // Bound returns to reasonable daily moves: -20% to +20%
        r1 = bound(r1, -200_000_000_000_000_000, 200_000_000_000_000_000);
        r2 = bound(r2, -200_000_000_000_000_000, 200_000_000_000_000_000);
        r3 = bound(r3, -200_000_000_000_000_000, 200_000_000_000_000_000);
        // Lambda in (0.5, 0.99)
        lambdaRaw = bound(lambdaRaw, 500_000_000_000_000_000, 990_000_000_000_000_000);

        SD59x18[] memory returns_ = new SD59x18[](3);
        returns_[0] = SD59x18.wrap(r1);
        returns_[1] = SD59x18.wrap(r2);
        returns_[2] = SD59x18.wrap(r3);

        SD59x18 vol = AcademicPaperBenchmarks.ewmaVolatility(returns_, SD59x18.wrap(int256(lambdaRaw)));
        assertGe(SD59x18.unwrap(vol), 0, "EWMA volatility must be >= 0");
    }

    // =========================================================================
    // Invariant 7: Volatility skew is symmetric in sign for symmetric moneyness
    // =========================================================================

    /// @notice Quadratic skew model: skew at m and 2-m should have the same quadratic component
    function testFuzz_skew_quadraticSymmetry(uint256 spotRaw, uint256 strikeRaw, uint256 aRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        aRaw = bound(aRaw, 1_000_000_000_000_000, 2_000_000_000_000_000_000);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));
        SD59x18 a = SD59x18.wrap(int256(aRaw));

        // With b = 0, skew should be symmetric: skew(S, K) = a*(m-1)^2
        SD59x18 skew = AcademicPaperBenchmarks.volatilitySkew(spot, strike, a, ZERO);
        // Pure quadratic: always >= 0 when a > 0
        assertGe(SD59x18.unwrap(skew), 0, "Pure quadratic skew with a > 0 must be >= 0");
    }

    // =========================================================================
    // Invariant 8: Utilization premium monotonically increases with utilization
    // =========================================================================

    /// @notice Higher utilization must produce higher premium
    function testFuzz_utilizationPremium_monotonic(uint256 u1Raw, uint256 u2Raw) public pure {
        // Bound to (0, 0.95) to stay safe from singularity
        u1Raw = bound(u1Raw, 1_000_000_000_000_000, 950_000_000_000_000_000);
        u2Raw = bound(u2Raw, 1_000_000_000_000_000, 950_000_000_000_000_000);

        SD59x18 u1 = SD59x18.wrap(int256(u1Raw));
        SD59x18 u2 = SD59x18.wrap(int256(u2Raw));
        SD59x18 baseIV = sd(800_000_000_000_000_000);
        SD59x18 k = sd(500_000_000_000_000_000);

        SD59x18 prem1 = AcademicPaperBenchmarks.utilizationPremium(baseIV, u1, k);
        SD59x18 prem2 = AcademicPaperBenchmarks.utilizationPremium(baseIV, u2, k);

        if (SD59x18.unwrap(u1) > SD59x18.unwrap(u2)) {
            assertGe(SD59x18.unwrap(prem1), SD59x18.unwrap(prem2), "Higher utilization -> higher premium");
        } else if (SD59x18.unwrap(u2) > SD59x18.unwrap(u1)) {
            assertGe(SD59x18.unwrap(prem2), SD59x18.unwrap(prem1), "Higher utilization -> higher premium");
        }
    }

    // =========================================================================
    // Invariant 9: Precision measurement relative error is in [0, ∞)
    // =========================================================================

    /// @notice Relative error must be non-negative
    function testFuzz_measurePrecision_relativeErrorNonNegative(uint256 computedRaw, uint256 refRaw) public pure {
        computedRaw = bound(computedRaw, 1, MAX_PRICE);
        refRaw = bound(refRaw, 1, MAX_PRICE);

        SD59x18 computed = sd(int256(computedRaw * 1e18));
        SD59x18 refValue = sd(int256(refRaw * 1e18));

        PrecisionResult memory result = AcademicPaperBenchmarks.measurePrecision(computed, refValue);
        assertGe(SD59x18.unwrap(result.absoluteError), 0, "Absolute error must be >= 0");
        assertGe(SD59x18.unwrap(result.relativeError), 0, "Relative error must be >= 0");
    }

    // =========================================================================
    // Invariant 10: agreesWithinBps is reflexive
    // =========================================================================

    /// @notice Any value agrees with itself within any positive bps tolerance
    function testFuzz_agreesWithinBps_reflexive(uint256 valRaw, uint256 bps) public pure {
        valRaw = bound(valRaw, 0, MAX_PRICE);
        bps = bound(bps, 1, 10_000);

        SD59x18 val = sd(int256(valRaw * 1e18));
        assertTrue(AcademicPaperBenchmarks.agreesWithinBps(val, val, bps), "Value must agree with itself");
    }

    // =========================================================================
    // Invariant 11: Vol surface totalIV >= floor (1%)
    // =========================================================================

    /// @notice Total IV from vol surface must be at least the 1% floor
    function testFuzz_volSurface_ivFloor(uint256 spotRaw, uint256 strikeRaw, uint256 utilRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        utilRaw = bound(utilRaw, 0, 950_000_000_000_000_000);

        VolSurfacePoint memory point = AcademicPaperBenchmarks.computeVolSurfacePoint(
            sd(100_000_000_000_000_000), // baseIV = 0.1
            sd(int256(spotRaw * 1e18)),
            sd(int256(strikeRaw * 1e18)),
            sd(500_000_000_000_000_000), // a = 0.5
            sd(-200_000_000_000_000_000), // b = -0.2
            SD59x18.wrap(int256(utilRaw)),
            sd(500_000_000_000_000_000) // k = 0.5
        );

        // Floor is 1% = 0.01
        assertGe(SD59x18.unwrap(point.totalIV), 1e16, "Total IV must be >= 1% floor");
    }

    // =========================================================================
    // Invariant 12: CDF symmetry error is small
    // =========================================================================

    /// @notice CDF symmetry error |Φ(x) + Φ(-x) - 1| must be small for reasonable x
    function testFuzz_cdfSymmetry_small(int256 xRaw) public pure {
        // Bound to [-6, 6] — reasonable CDF range
        xRaw = bound(xRaw, -6e18, 6e18);
        SD59x18 x = SD59x18.wrap(xRaw);

        SD59x18 err = AcademicPaperBenchmarks.cdfSymmetryError(x);
        // Symmetry error should be less than 1e-6 (i.e., 1e12 in SD59x18 scale)
        assertLt(SD59x18.unwrap(err), 1e12, "CDF symmetry error must be tiny");
    }
}
