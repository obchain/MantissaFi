// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { CumulativeNormal } from "./CumulativeNormal.sol";

/// @title Certoraspec
/// @notice On-chain verification helpers for CDF invariants used by Certora formal verification
/// @dev Encodes three core properties of the cumulative normal distribution Φ(x):
///      1. Bounds:     ∀ x: 0 ≤ Φ(x) ≤ 1e18
///      2. Symmetry:   ∀ x: |Φ(x) + Φ(-x) - 1e18| < ε
///      3. Monotonicity: ∀ x,y: x > y → Φ(x) ≥ Φ(y)
/// @author MantissaFi Team
library Certoraspec {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice 1.0 in SD59x18 fixed-point representation
    int256 internal constant ONE = 1e18;

    /// @notice Default epsilon tolerance for symmetry checks (1e-8 in fixed-point = 1e10)
    int256 internal constant DEFAULT_EPSILON = 1e10;

    /// @notice Maximum safe input magnitude for the CDF approximation
    /// @dev Beyond ±8σ, the Hart approximation loses precision; we clamp at 10 for safety
    int256 internal constant MAX_INPUT_MAGNITUDE = 10e18;

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when cdf(x) falls outside the valid [0, 1e18] range
    /// @param x The input value that caused the violation
    /// @param cdfValue The out-of-bounds CDF result
    error Certoraspec__CdfOutOfBounds(int256 x, int256 cdfValue);

    /// @notice Thrown when |cdf(x) + cdf(-x) - 1e18| ≥ epsilon
    /// @param x The input value that caused the violation
    /// @param deviation The absolute deviation from perfect symmetry
    /// @param epsilon The tolerance threshold that was exceeded
    error Certoraspec__SymmetryViolation(int256 x, int256 deviation, int256 epsilon);

    /// @notice Thrown when x > y but cdf(x) < cdf(y), violating monotonicity
    /// @param x The larger input value
    /// @param y The smaller input value
    /// @param cdfX The CDF value at x
    /// @param cdfY The CDF value at y
    error Certoraspec__MonotonicityViolation(int256 x, int256 y, int256 cdfX, int256 cdfY);

    /// @notice Thrown when input magnitude exceeds the safe approximation range
    /// @param x The input value that was too large
    error Certoraspec__InputOutOfRange(int256 x);

    /// @notice Thrown when epsilon is not positive
    error Certoraspec__InvalidEpsilon();

    /// @notice Thrown when x is not strictly greater than y in a monotonicity check
    error Certoraspec__InvalidMonotonicityInputs();

    // =========================================================================
    // Core Verification Functions
    // =========================================================================

    /// @notice Asserts that cdf(x) ∈ [0, 1e18]
    /// @dev Reverts with `Certoraspec__CdfOutOfBounds` if the invariant is violated.
    ///      Also reverts with `Certoraspec__InputOutOfRange` if |x| > MAX_INPUT_MAGNITUDE.
    /// @param x The input value in SD59x18 format
    /// @return cdfValue The CDF result, guaranteed to be within bounds
    function assertCdfBounds(SD59x18 x) internal pure returns (int256 cdfValue) {
        _validateInputRange(x);

        SD59x18 result = CumulativeNormal.cdf(x);
        cdfValue = SD59x18.unwrap(result);

        if (cdfValue < 0 || cdfValue > ONE) {
            revert Certoraspec__CdfOutOfBounds(SD59x18.unwrap(x), cdfValue);
        }
    }

    /// @notice Asserts that |cdf(x) + cdf(-x) - 1e18| < epsilon
    /// @dev Uses the default epsilon of 1e10 (≈ 1e-8 relative tolerance).
    ///      Reverts with `Certoraspec__SymmetryViolation` if the invariant is violated.
    /// @param x The input value in SD59x18 format
    /// @return deviation The absolute symmetry deviation
    function assertCdfSymmetry(SD59x18 x) internal pure returns (int256 deviation) {
        deviation = assertCdfSymmetryWithEpsilon(x, DEFAULT_EPSILON);
    }

    /// @notice Asserts that |cdf(x) + cdf(-x) - 1e18| < epsilon with custom tolerance
    /// @dev Reverts with `Certoraspec__SymmetryViolation` if the invariant is violated.
    /// @param x The input value in SD59x18 format
    /// @param epsilon The maximum allowed deviation (must be > 0)
    /// @return deviation The absolute symmetry deviation
    function assertCdfSymmetryWithEpsilon(SD59x18 x, int256 epsilon) internal pure returns (int256 deviation) {
        if (epsilon <= 0) {
            revert Certoraspec__InvalidEpsilon();
        }
        _validateInputRange(x);

        SD59x18 negX = ZERO.sub(x);
        SD59x18 cdfX = CumulativeNormal.cdf(x);
        SD59x18 cdfNegX = CumulativeNormal.cdf(negX);

        // deviation = |cdf(x) + cdf(-x) - 1.0|
        int256 sum = SD59x18.unwrap(cdfX) + SD59x18.unwrap(cdfNegX);
        int256 diff = sum - ONE;
        deviation = diff >= 0 ? diff : -diff;

        if (deviation >= epsilon) {
            revert Certoraspec__SymmetryViolation(SD59x18.unwrap(x), deviation, epsilon);
        }
    }

    /// @notice Asserts that x > y → cdf(x) ≥ cdf(y)
    /// @dev Reverts with `Certoraspec__MonotonicityViolation` if cdf(x) < cdf(y).
    ///      Reverts with `Certoraspec__InvalidMonotonicityInputs` if x ≤ y.
    /// @param x The larger input value in SD59x18 format
    /// @param y The smaller input value in SD59x18 format
    /// @return cdfX The CDF value at x
    /// @return cdfY The CDF value at y
    function assertCdfMonotonicity(SD59x18 x, SD59x18 y) internal pure returns (int256 cdfX, int256 cdfY) {
        if (!x.gt(y)) {
            revert Certoraspec__InvalidMonotonicityInputs();
        }
        _validateInputRange(x);
        _validateInputRange(y);

        cdfX = SD59x18.unwrap(CumulativeNormal.cdf(x));
        cdfY = SD59x18.unwrap(CumulativeNormal.cdf(y));

        if (cdfX < cdfY) {
            revert Certoraspec__MonotonicityViolation(
                SD59x18.unwrap(x), SD59x18.unwrap(y), cdfX, cdfY
            );
        }
    }

    // =========================================================================
    // Batch Verification
    // =========================================================================

    /// @notice Verifies all three CDF invariants for a single input x
    /// @dev Checks bounds on cdf(x), symmetry at x, and monotonicity between x and x - step.
    ///      Uses the default epsilon for the symmetry check.
    /// @param x The input value in SD59x18 format
    /// @param step A positive step size for the monotonicity check (x vs x - step)
    /// @return cdfValue The CDF result at x
    /// @return symDeviation The absolute symmetry deviation
    function assertAllInvariants(SD59x18 x, SD59x18 step) internal pure returns (int256 cdfValue, int256 symDeviation) {
        // 1. Bounds check
        cdfValue = assertCdfBounds(x);

        // 2. Symmetry check
        symDeviation = assertCdfSymmetry(x);

        // 3. Monotonicity check: cdf(x) ≥ cdf(x - step)
        if (step.gt(ZERO)) {
            SD59x18 y = x.sub(step);
            // Only check monotonicity if y is in range
            int256 yRaw = SD59x18.unwrap(y);
            if (yRaw >= -MAX_INPUT_MAGNITUDE && yRaw <= MAX_INPUT_MAGNITUDE) {
                assertCdfMonotonicity(x, y);
            }
        }
    }

    // =========================================================================
    // Query Functions (non-reverting)
    // =========================================================================

    /// @notice Computes the CDF bounds residual: min(cdf(x), 1e18 - cdf(x))
    /// @dev Returns 0 if cdf(x) is exactly at a boundary; negative if out of bounds.
    ///      Useful for off-chain analysis and Certora ghost variable definitions.
    /// @param x The input value in SD59x18 format
    /// @return residual The distance from the nearest bound, negative if violated
    function cdfBoundsResidual(SD59x18 x) internal pure returns (int256 residual) {
        int256 cdfValue = SD59x18.unwrap(CumulativeNormal.cdf(x));
        int256 distFromZero = cdfValue;
        int256 distFromOne = ONE - cdfValue;
        residual = distFromZero < distFromOne ? distFromZero : distFromOne;
    }

    /// @notice Computes the symmetry deviation |cdf(x) + cdf(-x) - 1e18|
    /// @dev Non-reverting version for off-chain analysis and Certora property checks.
    /// @param x The input value in SD59x18 format
    /// @return deviation The absolute symmetry deviation
    function symmetryDeviation(SD59x18 x) internal pure returns (int256 deviation) {
        SD59x18 negX = ZERO.sub(x);
        int256 sum = SD59x18.unwrap(CumulativeNormal.cdf(x)) + SD59x18.unwrap(CumulativeNormal.cdf(negX));
        int256 diff = sum - ONE;
        deviation = diff >= 0 ? diff : -diff;
    }

    /// @notice Computes the monotonicity residual cdf(x) - cdf(y) for x > y
    /// @dev Returns a non-negative value if monotonicity holds, negative if violated.
    ///      Does not revert; caller is responsible for ensuring x > y.
    /// @param x The larger input value in SD59x18 format
    /// @param y The smaller input value in SD59x18 format
    /// @return residual cdf(x) - cdf(y), non-negative if monotonicity holds
    function monotonicityResidual(SD59x18 x, SD59x18 y) internal pure returns (int256 residual) {
        int256 cdfX = SD59x18.unwrap(CumulativeNormal.cdf(x));
        int256 cdfY = SD59x18.unwrap(CumulativeNormal.cdf(y));
        residual = cdfX - cdfY;
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @notice Validates that the input magnitude is within the safe range
    /// @param x The input value to validate
    function _validateInputRange(SD59x18 x) private pure {
        int256 xRaw = SD59x18.unwrap(x);
        int256 absX = xRaw >= 0 ? xRaw : -xRaw;
        if (absX > MAX_INPUT_MAGNITUDE) {
            revert Certoraspec__InputOutOfRange(xRaw);
        }
    }
}
