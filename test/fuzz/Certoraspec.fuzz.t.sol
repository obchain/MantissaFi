// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { Certoraspec } from "../../src/libraries/Certoraspec.sol";
import { CumulativeNormal } from "../../src/libraries/CumulativeNormal.sol";

/// @title CertoraspecFuzzTest
/// @notice Fuzz tests for CDF invariants: bounds, symmetry, and monotonicity
/// @dev Tests mathematical invariants across random inputs within safe range
contract CertoraspecFuzzTest is Test {
    /// @notice Maximum safe input magnitude (10σ) matching Certoraspec.MAX_INPUT_MAGNITUDE
    int256 internal constant MAX_ABS = 10e18;

    /// @notice Default epsilon for symmetry checks
    int256 internal constant DEFAULT_EPSILON = 1e10;

    // =========================================================================
    // CDF Bounds Fuzz Tests
    // =========================================================================

    /// @notice ∀ x ∈ [-10, 10]: 0 ≤ cdf(x) ≤ 1e18
    function testFuzz_cdfBounds_alwaysInRange(int256 xRaw) public pure {
        xRaw = bound(xRaw, -MAX_ABS, MAX_ABS);
        SD59x18 x = sd(xRaw);

        int256 cdfValue = Certoraspec.assertCdfBounds(x);
        assertGe(cdfValue, 0, "CDF must be >= 0");
        assertLe(cdfValue, 1e18, "CDF must be <= 1e18");
    }

    /// @notice Bounds check passes for extreme positive inputs near the boundary
    function testFuzz_cdfBounds_nearMaxPositive(uint256 offset) public pure {
        // x ∈ [8, 10]
        offset = bound(offset, 0, 2e18);
        int256 xRaw = 8e18 + int256(offset);
        SD59x18 x = sd(xRaw);

        int256 cdfValue = Certoraspec.assertCdfBounds(x);
        assertGe(cdfValue, 0, "CDF must be >= 0 near max");
        assertLe(cdfValue, 1e18, "CDF must be <= 1e18 near max");
    }

    /// @notice Bounds check passes for extreme negative inputs near the boundary
    function testFuzz_cdfBounds_nearMaxNegative(uint256 offset) public pure {
        // x ∈ [-10, -8]
        offset = bound(offset, 0, 2e18);
        int256 xRaw = -8e18 - int256(offset);
        SD59x18 x = sd(xRaw);

        int256 cdfValue = Certoraspec.assertCdfBounds(x);
        assertGe(cdfValue, 0, "CDF must be >= 0 near min");
        assertLe(cdfValue, 1e18, "CDF must be <= 1e18 near min");
    }

    /// @notice Bounds residual is always non-negative for in-range inputs
    function testFuzz_cdfBoundsResidual_neverNegative(int256 xRaw) public pure {
        xRaw = bound(xRaw, -MAX_ABS, MAX_ABS);
        SD59x18 x = sd(xRaw);

        int256 residual = Certoraspec.cdfBoundsResidual(x);
        assertGe(residual, 0, "Bounds residual must be >= 0");
    }

    // =========================================================================
    // CDF Symmetry Fuzz Tests
    // =========================================================================

    /// @notice ∀ x ∈ [-10, 10]: |cdf(x) + cdf(-x) - 1e18| < ε
    function testFuzz_cdfSymmetry_holdsForAllInputs(int256 xRaw) public pure {
        xRaw = bound(xRaw, -MAX_ABS, MAX_ABS);
        SD59x18 x = sd(xRaw);

        int256 deviation = Certoraspec.assertCdfSymmetry(x);
        assertLt(deviation, DEFAULT_EPSILON, "Symmetry deviation must be < epsilon");
    }

    /// @notice Symmetry deviation is always non-negative (absolute value property)
    function testFuzz_symmetryDeviation_alwaysNonNegative(int256 xRaw) public pure {
        xRaw = bound(xRaw, -MAX_ABS, MAX_ABS);
        SD59x18 x = sd(xRaw);

        int256 deviation = Certoraspec.symmetryDeviation(x);
        assertGe(deviation, 0, "Symmetry deviation must be >= 0");
    }

    /// @notice Symmetry deviation is the same for x and -x
    function testFuzz_symmetryDeviation_sameForXandNegX(int256 xRaw) public pure {
        // Avoid overflow at the boundaries
        xRaw = bound(xRaw, -MAX_ABS + 1, MAX_ABS - 1);
        SD59x18 x = sd(xRaw);
        SD59x18 negX = sd(-xRaw);

        int256 devX = Certoraspec.symmetryDeviation(x);
        int256 devNegX = Certoraspec.symmetryDeviation(negX);

        assertEq(devX, devNegX, "Symmetry deviation must be same for x and -x");
    }

    /// @notice Symmetry holds with a custom epsilon for moderate inputs
    function testFuzz_cdfSymmetryWithEpsilon_moderateInputs(int256 xRaw) public pure {
        // x ∈ [-5, 5] where approximation is most accurate
        xRaw = bound(xRaw, -5e18, 5e18);
        SD59x18 x = sd(xRaw);

        // Use a tighter epsilon for the moderate range
        int256 deviation = Certoraspec.assertCdfSymmetryWithEpsilon(x, 5e9);
        assertLt(deviation, 5e9, "Symmetry should be tighter in moderate range");
    }

    // =========================================================================
    // CDF Monotonicity Fuzz Tests
    // =========================================================================

    /// @notice ∀ x, y ∈ [-10, 10]: x > y → cdf(x) ≥ cdf(y)
    function testFuzz_cdfMonotonicity_holdsForAllPairs(int256 xRaw, int256 yRaw) public pure {
        xRaw = bound(xRaw, -MAX_ABS, MAX_ABS);
        yRaw = bound(yRaw, -MAX_ABS, MAX_ABS);

        // Ensure x > y (skip if equal)
        if (xRaw <= yRaw) {
            (xRaw, yRaw) = (yRaw + 1, xRaw);
            // After swap, xRaw might exceed MAX_ABS
            if (xRaw > MAX_ABS) return;
        }

        SD59x18 x = sd(xRaw);
        SD59x18 y = sd(yRaw);

        (int256 cdfX, int256 cdfY) = Certoraspec.assertCdfMonotonicity(x, y);
        assertGe(cdfX, cdfY, "CDF must be monotonically non-decreasing");
    }

    /// @notice Monotonicity residual is non-negative for x > y
    function testFuzz_monotonicityResidual_neverNegative(int256 xRaw, int256 yRaw) public pure {
        xRaw = bound(xRaw, -MAX_ABS, MAX_ABS);
        yRaw = bound(yRaw, -MAX_ABS, MAX_ABS);

        // Ensure x > y
        if (xRaw <= yRaw) {
            (xRaw, yRaw) = (yRaw + 1, xRaw);
            if (xRaw > MAX_ABS) return;
        }

        SD59x18 x = sd(xRaw);
        SD59x18 y = sd(yRaw);

        int256 residual = Certoraspec.monotonicityResidual(x, y);
        assertGe(residual, 0, "Monotonicity residual must be >= 0 when x > y");
    }

    /// @notice Monotonicity holds for adjacent values with small step
    function testFuzz_cdfMonotonicity_smallStep(int256 xRaw, uint256 stepRaw) public pure {
        xRaw = bound(xRaw, -MAX_ABS + 1e15, MAX_ABS);
        stepRaw = bound(stepRaw, 1, 1e15); // Very small steps

        int256 yRaw = xRaw - int256(stepRaw);
        if (yRaw < -MAX_ABS) return;

        SD59x18 x = sd(xRaw);
        SD59x18 y = sd(yRaw);

        (int256 cdfX, int256 cdfY) = Certoraspec.assertCdfMonotonicity(x, y);
        assertGe(cdfX, cdfY, "CDF must be monotonic even for tiny steps");
    }

    // =========================================================================
    // Combined Invariants Fuzz Tests
    // =========================================================================

    /// @notice All three invariants hold simultaneously for any input
    function testFuzz_allInvariants_holdSimultaneously(int256 xRaw) public pure {
        xRaw = bound(xRaw, -MAX_ABS + 1e17, MAX_ABS);
        SD59x18 x = sd(xRaw);
        SD59x18 step = sd(1e17); // 0.1 step for monotonicity

        (int256 cdfValue, int256 symDev) = Certoraspec.assertAllInvariants(x, step);

        // Bounds
        assertGe(cdfValue, 0, "CDF must be >= 0");
        assertLe(cdfValue, 1e18, "CDF must be <= 1e18");

        // Symmetry
        assertLt(symDev, DEFAULT_EPSILON, "Symmetry deviation must be < epsilon");
    }

    /// @notice CDF value at x=0 is approximately 0.5 under fuzz
    function testFuzz_cdfAtZero_isApproxHalf(uint256 noise) public pure {
        // Add tiny noise around zero to test neighborhood
        noise = bound(noise, 0, 1e15);
        SD59x18 x = sd(int256(noise));

        int256 cdfValue = Certoraspec.assertCdfBounds(x);
        // cdf(0 + tiny) should be close to 0.5
        assertApproxEqAbs(cdfValue, 5e17, 1e15, "CDF near 0 should be approximately 0.5");
    }
}
