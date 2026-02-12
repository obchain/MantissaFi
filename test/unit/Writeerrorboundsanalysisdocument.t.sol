// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    ErrorBoundsAnalysis,
    ErrorBoundsParams,
    ErrorDecomposition,
    ErrorBounds__InvalidSpotPrice,
    ErrorBounds__InvalidStrikePrice,
    ErrorBounds__InvalidVolatility,
    ErrorBounds__InvalidTimeToExpiry,
    ErrorBounds__InvalidRiskFreeRate,
    ErrorBounds__ErrorExceedsThreshold,
    ErrorBounds__ZeroReferenceValue
} from "../../src/libraries/Writeerrorboundsanalysisdocument.sol";

/// @notice Wrapper contract to test library revert behavior via external calls
contract ErrorBoundsWrapper {
    function decomposeError(ErrorBoundsParams memory p) external pure returns (ErrorDecomposition memory) {
        return ErrorBoundsAnalysis.decomposeError(p);
    }

    function assertErrorWithinBounds(ErrorBoundsParams memory p, SD59x18 threshold) external pure {
        ErrorBoundsAnalysis.assertErrorWithinBounds(p, threshold);
    }

    function relativeError(SD59x18 measured, SD59x18 refVal) external pure returns (SD59x18) {
        return ErrorBoundsAnalysis.relativeError(measured, refVal);
    }

    function cdfErrorImpactOnPrice(ErrorBoundsParams memory p) external pure returns (SD59x18) {
        return ErrorBoundsAnalysis.cdfErrorImpactOnPrice(p);
    }
}

/// @title WriteerrorboundsanalysisdocumentTest
/// @notice Unit tests for ErrorBoundsAnalysis library
contract WriteerrorboundsanalysisdocumentTest is Test {
    ErrorBoundsWrapper internal wrapper;

    // Standard test parameters: ETH $3000, ATM, 80% vol, 5% rate, 30 days
    ErrorBoundsParams internal standardParams;

    // Deep OTM parameters
    ErrorBoundsParams internal deepOtmParams;

    // Short expiry parameters
    ErrorBoundsParams internal shortExpiryParams;

    function setUp() public {
        wrapper = new ErrorBoundsWrapper();

        standardParams = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000), // 0.8 = 80%
            riskFreeRate: sd(50_000_000_000_000_000), // 0.05 = 5%
            timeToExpiry: sd(82_191_780_821_917_808) // 30/365.25 ≈ 0.0822 years
        });

        deepOtmParams = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(5000e18), // deep OTM call
            volatility: sd(300_000_000_000_000_000), // 30% vol
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });

        shortExpiryParams = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(2_739_726_027_397_260) // 1 day = 1/365.25 years
        });
    }

    // =========================================================================
    // CDF Approximation Error Bound Tests
    // =========================================================================

    function test_cdfApproximationErrorBound_centralRegion() public pure {
        // For |x| < 3, error bound should be tighter (1e-8)
        SD59x18 bound = ErrorBoundsAnalysis.cdfApproximationErrorBound(sd(0));
        assertEq(SD59x18.unwrap(bound), 10_000_000_000, "Central region should have 1e-8 bound");
    }

    function test_cdfApproximationErrorBound_tailRegion() public pure {
        // For |x| in [3, 6], error bound should be max (7.5e-8)
        SD59x18 bound = ErrorBoundsAnalysis.cdfApproximationErrorBound(sd(4e18));
        assertEq(SD59x18.unwrap(bound), 75_000_000_000, "Tail region should have 7.5e-8 bound");
    }

    function test_cdfApproximationErrorBound_deepTail() public pure {
        // For |x| >= 6, max error bound
        SD59x18 bound = ErrorBoundsAnalysis.cdfApproximationErrorBound(sd(10e18));
        assertEq(SD59x18.unwrap(bound), 75_000_000_000, "Deep tail should have max bound");
    }

    function test_cdfApproximationErrorBound_negativeInput() public pure {
        // Negative inputs should use absolute value
        SD59x18 boundPos = ErrorBoundsAnalysis.cdfApproximationErrorBound(sd(1e18));
        SD59x18 boundNeg = ErrorBoundsAnalysis.cdfApproximationErrorBound(sd(-1e18));
        assertEq(SD59x18.unwrap(boundPos), SD59x18.unwrap(boundNeg), "Error bound should be symmetric");
    }

    // =========================================================================
    // CDF Symmetry Error Tests
    // =========================================================================

    function test_measureCdfSymmetryError_atZero() public pure {
        // Φ(0) should be 0.5, so Φ(0) + Φ(0) = 1.0
        SD59x18 err = ErrorBoundsAnalysis.measureCdfSymmetryError(sd(0));
        // Symmetry error at 0 should be very small
        assertLt(SD59x18.unwrap(err), 1e10, "Symmetry error at 0 should be tiny");
    }

    function test_measureCdfSymmetryError_atOne() public pure {
        SD59x18 err = ErrorBoundsAnalysis.measureCdfSymmetryError(sd(1e18));
        // Should be small — the CDF implementation preserves symmetry reasonably well
        assertLt(SD59x18.unwrap(err), 1e12, "Symmetry error at 1.0 should be small");
    }

    function test_measureCdfSymmetryError_atTwo() public pure {
        SD59x18 err = ErrorBoundsAnalysis.measureCdfSymmetryError(sd(2e18));
        assertLt(SD59x18.unwrap(err), 1e12, "Symmetry error at 2.0 should be small");
    }

    // =========================================================================
    // CDF Error Impact on Price Tests
    // =========================================================================

    function test_cdfErrorImpactOnPrice_standard() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });
        SD59x18 err = ErrorBoundsAnalysis.cdfErrorImpactOnPrice(p);
        // CDF error * price should be in range [0, some small number]
        assertGt(SD59x18.unwrap(err), 0, "CDF error impact should be positive");
        // Should be much less than 1 dollar for a $3000 asset
        assertLt(SD59x18.unwrap(err), 1e18, "CDF error impact should be < $1");
    }

    function test_cdfErrorImpactOnPrice_scalesWithSpot() public pure {
        ErrorBoundsParams memory p1 = ErrorBoundsParams({
            spot: sd(1000e18),
            strike: sd(1000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });
        ErrorBoundsParams memory p2 = ErrorBoundsParams({
            spot: sd(10_000e18),
            strike: sd(10_000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });
        SD59x18 err1 = ErrorBoundsAnalysis.cdfErrorImpactOnPrice(p1);
        SD59x18 err2 = ErrorBoundsAnalysis.cdfErrorImpactOnPrice(p2);
        // Higher spot should produce proportionally higher absolute CDF error
        assertGt(SD59x18.unwrap(err2), SD59x18.unwrap(err1), "CDF error should scale with spot");
    }

    // =========================================================================
    // Arithmetic Error Bound Tests
    // =========================================================================

    function test_d1ArithmeticErrorBound_isPositive() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });
        SD59x18 err = ErrorBoundsAnalysis.d1ArithmeticErrorBound(p);
        assertGt(SD59x18.unwrap(err), 0, "d1 arithmetic error should be positive");
    }

    function test_bsmArithmeticErrorBound_isPositive() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });
        SD59x18 err = ErrorBoundsAnalysis.bsmArithmeticErrorBound(p);
        assertGt(SD59x18.unwrap(err), 0, "BSM arithmetic error should be positive");
    }

    // =========================================================================
    // Error Decomposition Tests
    // =========================================================================

    function test_decomposeError_standard() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });
        ErrorDecomposition memory decomp = ErrorBoundsAnalysis.decomposeError(p);

        assertGt(SD59x18.unwrap(decomp.cdfError), 0, "CDF error should be positive");
        assertGt(SD59x18.unwrap(decomp.arithmeticError), 0, "Arithmetic error should be positive");
        // Total = cdf + arith
        assertEq(
            SD59x18.unwrap(decomp.totalAbsoluteError),
            SD59x18.unwrap(decomp.cdfError) + SD59x18.unwrap(decomp.arithmeticError),
            "Total should be sum of components"
        );
    }

    function test_decomposeError_relativeErrorIsSmall() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });
        ErrorDecomposition memory decomp = ErrorBoundsAnalysis.decomposeError(p);

        // Relative error should be less than 1 basis point for standard params
        assertLt(
            SD59x18.unwrap(decomp.totalRelativeError),
            100_000_000_000_000, // 1e-4 = 1bp
            "Relative error should be < 1bp for standard params"
        );
    }

    // =========================================================================
    // Assert Error Within Bounds Tests
    // =========================================================================

    function test_assertErrorWithinBounds_passes() public view {
        // Standard params should pass with a generous threshold
        wrapper.assertErrorWithinBounds(standardParams, sd(1e16)); // 1% threshold
    }

    function test_assertErrorWithinBounds_reverts() public {
        // Set an impossibly tight threshold
        vm.expectRevert();
        wrapper.assertErrorWithinBounds(standardParams, sd(1)); // 1e-18 threshold — too tight
    }

    // =========================================================================
    // Error Regime Assessment Tests
    // =========================================================================

    function test_assessErrorRegime_standard() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000) // ~3 months
        });
        (bool isHigh, SD59x18 factor) = ErrorBoundsAnalysis.assessErrorRegime(p);
        // ATM with reasonable vol and T — should not be high error
        assertFalse(isHigh, "Standard ATM should not be high-error");
        assertEq(SD59x18.unwrap(factor), 1e18, "Risk factor should be 1.0 for standard");
    }

    function test_assessErrorRegime_shortExpiry() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(2_739_726_027_397_260) // 1 day
        });
        (bool isHigh, SD59x18 factor) = ErrorBoundsAnalysis.assessErrorRegime(p);
        assertTrue(isHigh, "Short expiry should be high-error");
        assertGt(SD59x18.unwrap(factor), 1e18, "Risk factor should be > 1.0 for short expiry");
    }

    function test_assessErrorRegime_deepOTM() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(10_000e18), // very deep OTM call
            volatility: sd(300_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });
        (bool isHigh,) = ErrorBoundsAnalysis.assessErrorRegime(p);
        assertTrue(isHigh, "Deep OTM should be high-error regime");
    }

    // =========================================================================
    // Worst Case Error Tests
    // =========================================================================

    function test_worstCaseError_standard() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        (SD59x18 worstAbs, SD59x18 worstRel) = ErrorBoundsAnalysis.worstCaseError(p);
        assertGt(SD59x18.unwrap(worstAbs), 0, "Worst abs error should be positive");
        assertGe(SD59x18.unwrap(worstRel), 0, "Worst rel error should be >= 0");
    }

    // =========================================================================
    // Protocol Comparison Tests
    // =========================================================================

    function test_compareWithLyra_returnsValidRatio() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        (SD59x18 mantissa, SD59x18 lyra, SD59x18 ratio) = ErrorBoundsAnalysis.compareWithLyra(p);
        assertGt(SD59x18.unwrap(mantissa), 0, "MantissaFi error should be positive");
        assertGt(SD59x18.unwrap(lyra), 0, "Lyra error should be positive");
        assertGt(SD59x18.unwrap(ratio), 0, "Ratio should be positive");
    }

    function test_compareWithPrimitive_returnsValidRatio() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        (SD59x18 mantissa, SD59x18 primitive, SD59x18 ratio) = ErrorBoundsAnalysis.compareWithPrimitive(p);
        assertGt(SD59x18.unwrap(mantissa), 0, "MantissaFi error should be positive");
        assertGt(SD59x18.unwrap(primitive), 0, "Primitive error should be positive");
        assertGt(SD59x18.unwrap(ratio), 0, "Ratio should be positive");
    }

    function test_protocolErrorComparison_ordering() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        (SD59x18 mantissa, SD59x18 lyra, SD59x18 primitive) = ErrorBoundsAnalysis.protocolErrorComparison(p);
        // Primitive should have higher error than Lyra (5x the relative error constant)
        assertGt(SD59x18.unwrap(primitive), SD59x18.unwrap(lyra), "Primitive error > Lyra error");
        // All should be positive
        assertGt(SD59x18.unwrap(mantissa), 0, "Mantissa error positive");
    }

    // =========================================================================
    // Gas vs Accuracy Tradeoff Tests
    // =========================================================================

    function test_gasAccuracyTradeoff_ordering() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        (SD59x18 fast, SD59x18 standard, SD59x18 precise) = ErrorBoundsAnalysis.gasAccuracyTradeoff(p);
        // Fast should have highest error, precise should have lowest
        assertGt(SD59x18.unwrap(fast), SD59x18.unwrap(standard), "Fast error > Standard error");
        assertLt(SD59x18.unwrap(precise), SD59x18.unwrap(standard), "Precise error < Standard error");
    }

    function test_gasMultipliers_ordering() public pure {
        (SD59x18 fast, SD59x18 standard, SD59x18 precise) = ErrorBoundsAnalysis.gasMultipliers();
        assertLt(SD59x18.unwrap(fast), SD59x18.unwrap(standard), "Fast gas < Standard gas");
        assertEq(SD59x18.unwrap(standard), 1e18, "Standard gas = 1.0");
        assertGt(SD59x18.unwrap(precise), SD59x18.unwrap(standard), "Precise gas > Standard gas");
    }

    // =========================================================================
    // Greek Error Bound Tests
    // =========================================================================

    function test_deltaErrorBound_isPositive() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        SD59x18 err = ErrorBoundsAnalysis.deltaErrorBound(p);
        assertGt(SD59x18.unwrap(err), 0, "Delta error should be positive");
        // Delta error should be much less than 1.0 (delta range is [0,1])
        assertLt(SD59x18.unwrap(err), 1e17, "Delta error should be << 1.0");
    }

    function test_vegaErrorBound_isPositive() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        SD59x18 err = ErrorBoundsAnalysis.vegaErrorBound(p);
        assertGt(SD59x18.unwrap(err), 0, "Vega error should be positive");
    }

    function test_gammaErrorBound_isPositive() public pure {
        ErrorBoundsParams memory p = ErrorBoundsParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        SD59x18 err = ErrorBoundsAnalysis.gammaErrorBound(p);
        assertGt(SD59x18.unwrap(err), 0, "Gamma error should be positive");
    }

    // =========================================================================
    // Utility Function Tests
    // =========================================================================

    function test_absoluteError_basic() public pure {
        SD59x18 err = ErrorBoundsAnalysis.absoluteError(sd(105e16), sd(100e16));
        assertEq(SD59x18.unwrap(err), 5e16, "Absolute error should be 0.05");
    }

    function test_absoluteError_symmetric() public pure {
        SD59x18 err1 = ErrorBoundsAnalysis.absoluteError(sd(105e16), sd(100e16));
        SD59x18 err2 = ErrorBoundsAnalysis.absoluteError(sd(100e16), sd(105e16));
        assertEq(SD59x18.unwrap(err1), SD59x18.unwrap(err2), "Absolute error should be symmetric");
    }

    function test_relativeError_basic() public pure {
        // 105/100 - 1 = 5%
        SD59x18 err = ErrorBoundsAnalysis.relativeError(sd(105e16), sd(100e16));
        assertApproxEqRel(SD59x18.unwrap(err), 50_000_000_000_000_000, 1e14, "Relative error should be ~5%");
    }

    function test_relativeError_revertsOnZeroRef() public {
        vm.expectRevert(ErrorBounds__ZeroReferenceValue.selector);
        wrapper.relativeError(sd(1e18), sd(0));
    }

    function test_agreesWithinBps_true() public pure {
        // 1000.0 vs 1000.05 = 0.005% = 0.5 bps — should pass with 1 bps tolerance
        bool result = ErrorBoundsAnalysis.agreesWithinBps(sd(1000_050_000_000_000_000_000), sd(1000e18), 1);
        assertTrue(result, "Should agree within 1bp");
    }

    function test_agreesWithinBps_false() public pure {
        // 1000.0 vs 1010.0 = 1% = 100 bps — should fail with 1 bps tolerance
        bool result = ErrorBoundsAnalysis.agreesWithinBps(sd(1010e18), sd(1000e18), 1);
        assertFalse(result, "Should not agree within 1bp");
    }

    // =========================================================================
    // Validation Revert Tests
    // =========================================================================

    function test_decomposeError_revertsOnZeroSpot() public {
        ErrorBoundsParams memory p = standardParams;
        p.spot = sd(0);
        vm.expectRevert();
        wrapper.decomposeError(p);
    }

    function test_decomposeError_revertsOnZeroStrike() public {
        ErrorBoundsParams memory p = standardParams;
        p.strike = sd(0);
        vm.expectRevert();
        wrapper.decomposeError(p);
    }

    function test_decomposeError_revertsOnZeroVol() public {
        ErrorBoundsParams memory p = standardParams;
        p.volatility = sd(0);
        vm.expectRevert();
        wrapper.decomposeError(p);
    }

    function test_decomposeError_revertsOnZeroTime() public {
        ErrorBoundsParams memory p = standardParams;
        p.timeToExpiry = sd(0);
        vm.expectRevert();
        wrapper.decomposeError(p);
    }

    function test_decomposeError_revertsOnNegativeRate() public {
        ErrorBoundsParams memory p = standardParams;
        p.riskFreeRate = sd(-1e18);
        vm.expectRevert();
        wrapper.decomposeError(p);
    }
}
