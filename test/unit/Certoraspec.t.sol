// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { Certoraspec } from "../../src/libraries/Certoraspec.sol";
import { CumulativeNormal } from "../../src/libraries/CumulativeNormal.sol";

/// @notice Wrapper contract to expose library functions and test revert behavior
contract CertoraspecWrapper {
    function assertCdfBounds(SD59x18 x) external pure returns (int256) {
        return Certoraspec.assertCdfBounds(x);
    }

    function assertCdfSymmetry(SD59x18 x) external pure returns (int256) {
        return Certoraspec.assertCdfSymmetry(x);
    }

    function assertCdfSymmetryWithEpsilon(SD59x18 x, int256 epsilon) external pure returns (int256) {
        return Certoraspec.assertCdfSymmetryWithEpsilon(x, epsilon);
    }

    function assertCdfMonotonicity(SD59x18 x, SD59x18 y) external pure returns (int256, int256) {
        return Certoraspec.assertCdfMonotonicity(x, y);
    }

    function assertAllInvariants(SD59x18 x, SD59x18 step) external pure returns (int256, int256) {
        return Certoraspec.assertAllInvariants(x, step);
    }

    function cdfBoundsResidual(SD59x18 x) external pure returns (int256) {
        return Certoraspec.cdfBoundsResidual(x);
    }

    function symmetryDeviation(SD59x18 x) external pure returns (int256) {
        return Certoraspec.symmetryDeviation(x);
    }

    function monotonicityResidual(SD59x18 x, SD59x18 y) external pure returns (int256) {
        return Certoraspec.monotonicityResidual(x, y);
    }
}

/// @title CertoraspecTest
/// @notice Unit tests for Certoraspec CDF invariant verification library
contract CertoraspecTest is Test {
    CertoraspecWrapper internal wrapper;

    int256 internal constant ONE = 1e18;

    function setUp() public {
        wrapper = new CertoraspecWrapper();
    }

    // =========================================================================
    // assertCdfBounds Tests
    // =========================================================================

    function test_assertCdfBounds_atZero() public pure {
        // Φ(0) = 0.5, well within [0, 1]
        int256 cdfValue = Certoraspec.assertCdfBounds(ZERO);
        assertApproxEqRel(cdfValue, 5e17, 1e14, "CDF(0) should be ~0.5");
    }

    function test_assertCdfBounds_positiveInput() public pure {
        // Φ(1) ≈ 0.8413
        int256 cdfValue = Certoraspec.assertCdfBounds(sd(1e18));
        assertGt(cdfValue, 5e17, "CDF(1) should be > 0.5");
        assertLe(cdfValue, ONE, "CDF(1) should be <= 1");
    }

    function test_assertCdfBounds_negativeInput() public pure {
        // Φ(-1) ≈ 0.1587
        int256 cdfValue = Certoraspec.assertCdfBounds(sd(-1e18));
        assertGe(cdfValue, 0, "CDF(-1) should be >= 0");
        assertLt(cdfValue, 5e17, "CDF(-1) should be < 0.5");
    }

    function test_assertCdfBounds_largePositive() public pure {
        // Φ(5) ≈ 0.999999713
        int256 cdfValue = Certoraspec.assertCdfBounds(sd(5e18));
        assertGt(cdfValue, 999e15, "CDF(5) should be very close to 1");
        assertLe(cdfValue, ONE, "CDF(5) should be <= 1");
    }

    function test_assertCdfBounds_largeNegative() public pure {
        // Φ(-5) ≈ 0.000000287
        int256 cdfValue = Certoraspec.assertCdfBounds(sd(-5e18));
        assertGe(cdfValue, 0, "CDF(-5) should be >= 0");
        assertLt(cdfValue, 1e15, "CDF(-5) should be very close to 0");
    }

    function test_assertCdfBounds_maxPositiveInput() public pure {
        // Φ(10) should still be within bounds
        int256 cdfValue = Certoraspec.assertCdfBounds(sd(10e18));
        assertGe(cdfValue, 0, "CDF(10) should be >= 0");
        assertLe(cdfValue, ONE, "CDF(10) should be <= 1");
    }

    function test_assertCdfBounds_maxNegativeInput() public pure {
        // Φ(-10) should still be within bounds
        int256 cdfValue = Certoraspec.assertCdfBounds(sd(-10e18));
        assertGe(cdfValue, 0, "CDF(-10) should be >= 0");
        assertLe(cdfValue, ONE, "CDF(-10) should be <= 1");
    }

    function test_assertCdfBounds_revertsOnInputOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(Certoraspec.Certoraspec__InputOutOfRange.selector, int256(11e18)));
        wrapper.assertCdfBounds(sd(11e18));
    }

    function test_assertCdfBounds_revertsOnNegativeOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(Certoraspec.Certoraspec__InputOutOfRange.selector, int256(-11e18)));
        wrapper.assertCdfBounds(sd(-11e18));
    }

    // =========================================================================
    // assertCdfSymmetry Tests
    // =========================================================================

    function test_assertCdfSymmetry_atZero() public pure {
        // Φ(0) + Φ(-0) = 2*Φ(0) ≈ 1.0 (within approximation error)
        int256 deviation = Certoraspec.assertCdfSymmetry(ZERO);
        assertLt(deviation, 1e10, "Symmetry deviation at 0 should be within epsilon");
    }

    function test_assertCdfSymmetry_smallPositive() public pure {
        // Φ(0.5) + Φ(-0.5) ≈ 1.0
        int256 deviation = Certoraspec.assertCdfSymmetry(sd(5e17));
        assertLt(deviation, 1e10, "Symmetry deviation at 0.5 should be tiny");
    }

    function test_assertCdfSymmetry_unitPositive() public pure {
        // Φ(1) + Φ(-1) ≈ 1.0
        int256 deviation = Certoraspec.assertCdfSymmetry(sd(1e18));
        assertLt(deviation, 1e10, "Symmetry deviation at 1 should be tiny");
    }

    function test_assertCdfSymmetry_atThree() public pure {
        // Φ(3) + Φ(-3) ≈ 1.0
        int256 deviation = Certoraspec.assertCdfSymmetry(sd(3e18));
        assertLt(deviation, 1e10, "Symmetry deviation at 3 should be tiny");
    }

    function test_assertCdfSymmetry_negativeInput() public pure {
        // Should work the same for negative inputs
        int256 deviation = Certoraspec.assertCdfSymmetry(sd(-2e18));
        assertLt(deviation, 1e10, "Symmetry deviation at -2 should be tiny");
    }

    // =========================================================================
    // assertCdfSymmetryWithEpsilon Tests
    // =========================================================================

    function test_assertCdfSymmetryWithEpsilon_tightEpsilon() public pure {
        // The Hart approximation has ~1e9 error at x=0, so use 2e9 as a tight epsilon
        int256 deviation = Certoraspec.assertCdfSymmetryWithEpsilon(ZERO, 2e9);
        assertLt(deviation, 2e9, "Deviation at 0 should be within tight epsilon");
    }

    function test_assertCdfSymmetryWithEpsilon_revertsOnZeroEpsilon() public {
        vm.expectRevert(Certoraspec.Certoraspec__InvalidEpsilon.selector);
        wrapper.assertCdfSymmetryWithEpsilon(sd(1e18), 0);
    }

    function test_assertCdfSymmetryWithEpsilon_revertsOnNegativeEpsilon() public {
        vm.expectRevert(Certoraspec.Certoraspec__InvalidEpsilon.selector);
        wrapper.assertCdfSymmetryWithEpsilon(sd(1e18), -1);
    }

    // =========================================================================
    // assertCdfMonotonicity Tests
    // =========================================================================

    function test_assertCdfMonotonicity_basicPair() public pure {
        // cdf(1) ≥ cdf(0)
        (int256 cdfX, int256 cdfY) = Certoraspec.assertCdfMonotonicity(sd(1e18), ZERO);
        assertGe(cdfX, cdfY, "CDF(1) should be >= CDF(0)");
    }

    function test_assertCdfMonotonicity_negativePair() public pure {
        // cdf(-1) ≥ cdf(-2)
        (int256 cdfX, int256 cdfY) = Certoraspec.assertCdfMonotonicity(sd(-1e18), sd(-2e18));
        assertGe(cdfX, cdfY, "CDF(-1) should be >= CDF(-2)");
    }

    function test_assertCdfMonotonicity_wideSpan() public pure {
        // cdf(5) ≥ cdf(-5)
        (int256 cdfX, int256 cdfY) = Certoraspec.assertCdfMonotonicity(sd(5e18), sd(-5e18));
        assertGt(cdfX, cdfY, "CDF(5) should be > CDF(-5)");
    }

    function test_assertCdfMonotonicity_adjacentValues() public pure {
        // cdf(0.01) ≥ cdf(0)
        (int256 cdfX, int256 cdfY) = Certoraspec.assertCdfMonotonicity(sd(1e16), ZERO);
        assertGe(cdfX, cdfY, "CDF(0.01) should be >= CDF(0)");
    }

    function test_assertCdfMonotonicity_revertsOnEqualInputs() public {
        vm.expectRevert(Certoraspec.Certoraspec__InvalidMonotonicityInputs.selector);
        wrapper.assertCdfMonotonicity(sd(1e18), sd(1e18));
    }

    function test_assertCdfMonotonicity_revertsOnReversedInputs() public {
        vm.expectRevert(Certoraspec.Certoraspec__InvalidMonotonicityInputs.selector);
        wrapper.assertCdfMonotonicity(ZERO, sd(1e18));
    }

    // =========================================================================
    // assertAllInvariants Tests
    // =========================================================================

    function test_assertAllInvariants_atZero() public pure {
        (int256 cdfValue, int256 symDev) = Certoraspec.assertAllInvariants(ZERO, sd(1e17));
        assertApproxEqRel(cdfValue, 5e17, 1e14, "CDF(0) should be ~0.5");
        assertLt(symDev, 1e10, "Symmetry deviation at 0 should be within epsilon");
    }

    function test_assertAllInvariants_withZeroStep() public pure {
        // Zero step skips monotonicity check but still checks bounds and symmetry
        (int256 cdfValue,) = Certoraspec.assertAllInvariants(sd(1e18), ZERO);
        assertGt(cdfValue, 5e17, "CDF(1) should be > 0.5");
    }

    // =========================================================================
    // cdfBoundsResidual Tests
    // =========================================================================

    function test_cdfBoundsResidual_atZero() public pure {
        // Φ(0) = 0.5, distance to nearest bound = 0.5
        int256 residual = Certoraspec.cdfBoundsResidual(ZERO);
        assertApproxEqRel(residual, 5e17, 1e14, "Residual at 0 should be ~0.5");
    }

    function test_cdfBoundsResidual_farPositive() public pure {
        // Φ(5) ≈ 1, distance to nearest bound (1) is tiny
        int256 residual = Certoraspec.cdfBoundsResidual(sd(5e18));
        assertGe(residual, 0, "Residual should be non-negative");
        assertLt(residual, 1e15, "Residual at 5 should be very small");
    }

    function test_cdfBoundsResidual_farNegative() public pure {
        // Φ(-5) ≈ 0, distance to nearest bound (0) is tiny
        int256 residual = Certoraspec.cdfBoundsResidual(sd(-5e18));
        assertGe(residual, 0, "Residual should be non-negative");
        assertLt(residual, 1e15, "Residual at -5 should be very small");
    }

    // =========================================================================
    // symmetryDeviation Tests
    // =========================================================================

    function test_symmetryDeviation_atZero() public pure {
        // Hart approximation: cdf(0) ≈ 0.5 with ~1e-9 relative error
        int256 deviation = Certoraspec.symmetryDeviation(ZERO);
        assertLt(deviation, 2e9, "Deviation at 0 should be within approximation error");
    }

    function test_symmetryDeviation_atOne() public pure {
        int256 deviation = Certoraspec.symmetryDeviation(sd(1e18));
        assertLt(deviation, 1e10, "Deviation at 1 should be < epsilon");
    }

    function test_symmetryDeviation_isNonNegative() public pure {
        int256 deviation = Certoraspec.symmetryDeviation(sd(-3e18));
        assertGe(deviation, 0, "Deviation should always be non-negative");
    }

    // =========================================================================
    // monotonicityResidual Tests
    // =========================================================================

    function test_monotonicityResidual_positive() public pure {
        // cdf(1) - cdf(0) should be positive
        int256 residual = Certoraspec.monotonicityResidual(sd(1e18), ZERO);
        assertGt(residual, 0, "Monotonicity residual should be positive for x > y");
    }

    function test_monotonicityResidual_wideGap() public pure {
        // cdf(5) - cdf(-5) should be large
        int256 residual = Certoraspec.monotonicityResidual(sd(5e18), sd(-5e18));
        assertGt(residual, 9e17, "CDF(5) - CDF(-5) should be close to 1");
    }

    function test_monotonicityResidual_smallGap() public pure {
        // Adjacent values should still have non-negative residual
        int256 residual = Certoraspec.monotonicityResidual(sd(1e16), ZERO);
        assertGe(residual, 0, "Monotonicity residual should be >= 0");
    }
}
