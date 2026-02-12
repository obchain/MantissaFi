// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    ErrorBoundsAnalysis,
    ErrorBoundsParams,
    ErrorDecomposition
} from "../../src/libraries/Writeerrorboundsanalysisdocument.sol";

/// @title WriteerrorboundsanalysisdocumentFuzzTest
/// @notice Fuzz tests for ErrorBoundsAnalysis library
/// @dev Tests mathematical invariants across randomized inputs
contract WriteerrorboundsanalysisdocumentFuzzTest is Test {
    // Bounds for realistic parameters
    uint256 internal constant MIN_PRICE = 1; // $1
    uint256 internal constant MAX_PRICE = 100_000; // $100k
    uint256 internal constant MIN_VOL_BPS = 50; // 0.5% vol
    uint256 internal constant MAX_VOL_BPS = 3000; // 300% vol
    uint256 internal constant MIN_TIME_DAYS = 1; // 1 day
    uint256 internal constant MAX_TIME_DAYS = 730; // 2 years
    uint256 internal constant MAX_RATE_BPS = 200; // 20% rate

    /// @dev Creates bounded ErrorBoundsParams from raw fuzz inputs
    function _makeParams(uint256 spotRaw, uint256 strikeRaw, uint256 volRaw, uint256 timeRaw, uint256 rateRaw)
        internal
        pure
        returns (ErrorBoundsParams memory p)
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        volRaw = bound(volRaw, MIN_VOL_BPS, MAX_VOL_BPS);
        timeRaw = bound(timeRaw, MIN_TIME_DAYS, MAX_TIME_DAYS);
        rateRaw = bound(rateRaw, 0, MAX_RATE_BPS);

        p = ErrorBoundsParams({
            spot: sd(int256(spotRaw * 1e18)),
            strike: sd(int256(strikeRaw * 1e18)),
            volatility: sd(int256(volRaw) * 1e14), // bps * 1e14 = fractional * 1e18
            riskFreeRate: sd(int256(rateRaw) * 1e14),
            timeToExpiry: sd(int256(timeRaw) * 2_739_726_027_397_260) // days * (1/365.25) in SD59x18
        });
    }

    // =========================================================================
    // Invariant: Total error is sum of components
    // =========================================================================

    /// @notice Error decomposition components must sum to total
    function testFuzz_decomposeError_sumOfComponents(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        ErrorBoundsParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);
        ErrorDecomposition memory decomp = ErrorBoundsAnalysis.decomposeError(p);

        int256 expected = SD59x18.unwrap(decomp.cdfError) + SD59x18.unwrap(decomp.arithmeticError);
        assertEq(
            SD59x18.unwrap(decomp.totalAbsoluteError), expected, "Total error must equal cdfError + arithmeticError"
        );
    }

    // =========================================================================
    // Invariant: All error bounds are non-negative
    // =========================================================================

    /// @notice CDF error impact on price is always >= 0
    function testFuzz_cdfErrorImpact_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        ErrorBoundsParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);
        SD59x18 err = ErrorBoundsAnalysis.cdfErrorImpactOnPrice(p);
        assertGe(SD59x18.unwrap(err), 0, "CDF error impact must be >= 0");
    }

    /// @notice BSM arithmetic error bound is always >= 0
    function testFuzz_bsmArithError_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        ErrorBoundsParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);
        SD59x18 err = ErrorBoundsAnalysis.bsmArithmeticErrorBound(p);
        assertGe(SD59x18.unwrap(err), 0, "BSM arithmetic error must be >= 0");
    }

    /// @notice Total absolute error is always >= 0
    function testFuzz_totalAbsoluteError_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        ErrorBoundsParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);
        ErrorDecomposition memory decomp = ErrorBoundsAnalysis.decomposeError(p);
        assertGe(SD59x18.unwrap(decomp.totalAbsoluteError), 0, "Total absolute error must be >= 0");
    }

    /// @notice Relative error is always >= 0
    function testFuzz_totalRelativeError_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        ErrorBoundsParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);
        ErrorDecomposition memory decomp = ErrorBoundsAnalysis.decomposeError(p);
        assertGe(SD59x18.unwrap(decomp.totalRelativeError), 0, "Total relative error must be >= 0");
    }

    // =========================================================================
    // Invariant: CDF error bound is symmetric in x
    // =========================================================================

    /// @notice CDF approximation error bound is identical for +x and -x
    function testFuzz_cdfErrorBound_symmetric(int128 xRaw) public pure {
        // Bound x to [-10, 10] to avoid extreme values
        int256 x = bound(int256(xRaw), -10e18, 10e18);
        SD59x18 boundPos = ErrorBoundsAnalysis.cdfApproximationErrorBound(sd(x));
        SD59x18 boundNeg = ErrorBoundsAnalysis.cdfApproximationErrorBound(sd(-x));
        assertEq(SD59x18.unwrap(boundPos), SD59x18.unwrap(boundNeg), "CDF error bound must be symmetric");
    }

    // =========================================================================
    // Invariant: CDF symmetry error is small
    // =========================================================================

    /// @notice CDF symmetry error Φ(x) + Φ(-x) ≈ 1 for all x in reasonable range
    function testFuzz_cdfSymmetryError_bounded(int128 xRaw) public pure {
        // Bound to [-5, 5] for meaningful CDF values
        int256 x = bound(int256(xRaw), -5e18, 5e18);
        SD59x18 err = ErrorBoundsAnalysis.measureCdfSymmetryError(sd(x));
        // Symmetry error should be very small — less than 1e-6
        assertLt(SD59x18.unwrap(err), 1e12, "CDF symmetry error must be < 1e-6");
    }

    // =========================================================================
    // Invariant: Error regime risk factor >= 1.0
    // =========================================================================

    /// @notice Risk factor is always >= 1.0 (base risk)
    function testFuzz_riskFactor_atLeastOne(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        ErrorBoundsParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);
        (, SD59x18 riskFactor) = ErrorBoundsAnalysis.assessErrorRegime(p);
        assertGe(SD59x18.unwrap(riskFactor), 1e18, "Risk factor must be >= 1.0");
    }

    // =========================================================================
    // Invariant: Worst-case error >= standard error
    // =========================================================================

    /// @notice Worst-case absolute error >= decomposed total absolute error
    function testFuzz_worstCase_geDecomposed(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        ErrorBoundsParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);
        ErrorDecomposition memory decomp = ErrorBoundsAnalysis.decomposeError(p);
        (SD59x18 worstAbs,) = ErrorBoundsAnalysis.worstCaseError(p);
        assertGe(
            SD59x18.unwrap(worstAbs),
            SD59x18.unwrap(decomp.totalAbsoluteError),
            "Worst-case error must be >= standard total error"
        );
    }

    // =========================================================================
    // Invariant: Gas-accuracy tradeoff ordering
    // =========================================================================

    /// @notice Fast error >= Standard error >= Precise error (for CDF-dominated scenarios)
    function testFuzz_gasAccuracy_ordering(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        ErrorBoundsParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);
        (SD59x18 fast, SD59x18 standard, SD59x18 precise) = ErrorBoundsAnalysis.gasAccuracyTradeoff(p);
        assertGe(SD59x18.unwrap(fast), SD59x18.unwrap(standard), "Fast error must be >= Standard error");
        assertLe(SD59x18.unwrap(precise), SD59x18.unwrap(standard), "Precise error must be <= Standard error");
    }

    // =========================================================================
    // Invariant: Primitive error > Lyra error (by construction)
    // =========================================================================

    /// @notice Primitive's error bound is always > Lyra's (5x the relative error constant)
    function testFuzz_primitiveError_gtLyraError(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        ErrorBoundsParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);
        (, SD59x18 lyra, SD59x18 primitive) = ErrorBoundsAnalysis.protocolErrorComparison(p);
        assertGe(SD59x18.unwrap(primitive), SD59x18.unwrap(lyra), "Primitive error must be >= Lyra error");
    }

    // =========================================================================
    // Invariant: Absolute error is symmetric
    // =========================================================================

    /// @notice absoluteError(a, b) == absoluteError(b, a)
    function testFuzz_absoluteError_symmetric(int128 aRaw, int128 bRaw) public pure {
        SD59x18 a = sd(int256(aRaw));
        SD59x18 b = sd(int256(bRaw));
        SD59x18 err1 = ErrorBoundsAnalysis.absoluteError(a, b);
        SD59x18 err2 = ErrorBoundsAnalysis.absoluteError(b, a);
        assertEq(SD59x18.unwrap(err1), SD59x18.unwrap(err2), "Absolute error must be symmetric");
    }

    // =========================================================================
    // Invariant: agreesWithinBps monotonic in tolerance
    // =========================================================================

    /// @notice If values agree within N bps, they also agree within M bps for M > N
    function testFuzz_agreesWithinBps_monotonicInTolerance(int128 aRaw, int128 bRaw, uint256 bps1, uint256 bps2)
        public
        pure
    {
        // Bound to reasonable ranges
        int256 a = bound(int256(aRaw), 1e18, 1_000_000e18);
        int256 b = bound(int256(bRaw), 1e18, 1_000_000e18);
        bps1 = bound(bps1, 1, 1000);
        bps2 = bound(bps2, bps1, 10_000); // bps2 >= bps1

        bool tight = ErrorBoundsAnalysis.agreesWithinBps(sd(a), sd(b), bps1);
        bool loose = ErrorBoundsAnalysis.agreesWithinBps(sd(a), sd(b), bps2);

        // If tight tolerance passes, loose must also pass
        if (tight) {
            assertTrue(loose, "If agrees within tighter bps, must agree within looser bps");
        }
    }

    // =========================================================================
    // Invariant: Delta error bound is always < 1.0
    // =========================================================================

    /// @notice Delta error should be much less than delta range [0, 1]
    function testFuzz_deltaError_lessThanOne(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        ErrorBoundsParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);
        SD59x18 err = ErrorBoundsAnalysis.deltaErrorBound(p);
        assertLt(SD59x18.unwrap(err), 1e18, "Delta error must be < 1.0");
    }
}
