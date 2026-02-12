// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    AcademicPaperBenchmarks,
    BSMParams,
    BSMResult,
    PrecisionResult,
    VolSurfacePoint,
    InvariantCheckResult,
    AcademicBenchmark__InvalidSpotPrice,
    AcademicBenchmark__InvalidStrikePrice,
    AcademicBenchmark__InvalidVolatility,
    AcademicBenchmark__InvalidTimeToExpiry,
    AcademicBenchmark__InvalidRiskFreeRate,
    AcademicBenchmark__EmptyReturnsArray,
    AcademicBenchmark__InvalidDecayFactor,
    AcademicBenchmark__UtilizationTooHigh,
    AcademicBenchmark__ZeroReferenceValue,
    AcademicBenchmark__PutCallParityViolation
} from "../../src/libraries/WriteacademicpaperLaTeX.sol";

/// @notice Wrapper contract to test library revert behavior via external calls
contract AcademicBenchmarkWrapper {
    function computeD1D2(BSMParams memory p) external pure returns (SD59x18 d1, SD59x18 d2) {
        return AcademicPaperBenchmarks.computeD1D2(p);
    }

    function priceCall(BSMParams memory p) external pure returns (SD59x18) {
        return AcademicPaperBenchmarks.priceCall(p);
    }

    function pricePut(BSMParams memory p) external pure returns (SD59x18) {
        return AcademicPaperBenchmarks.pricePut(p);
    }

    function priceBSM(BSMParams memory p) external pure returns (BSMResult memory) {
        return AcademicPaperBenchmarks.priceBSM(p);
    }

    function ewmaVolatility(SD59x18[] memory logReturns, SD59x18 lambda) external pure returns (SD59x18) {
        return AcademicPaperBenchmarks.ewmaVolatility(logReturns, lambda);
    }

    function volatilitySkew(SD59x18 spot, SD59x18 strike, SD59x18 a, SD59x18 b) external pure returns (SD59x18) {
        return AcademicPaperBenchmarks.volatilitySkew(spot, strike, a, b);
    }

    function utilizationPremium(SD59x18 baseIV, SD59x18 utilization, SD59x18 k) external pure returns (SD59x18) {
        return AcademicPaperBenchmarks.utilizationPremium(baseIV, utilization, k);
    }

    function checkInvariants(BSMParams memory p, SD59x18 tolerance)
        external
        pure
        returns (InvariantCheckResult memory)
    {
        return AcademicPaperBenchmarks.checkInvariants(p, tolerance);
    }

    function assertPutCallParity(BSMParams memory p, SD59x18 tolerance) external pure {
        AcademicPaperBenchmarks.assertPutCallParity(p, tolerance);
    }

    function measurePrecision(SD59x18 computed, SD59x18 refValue) external pure returns (PrecisionResult memory) {
        return AcademicPaperBenchmarks.measurePrecision(computed, refValue);
    }

    function compareProtocolErrors(SD59x18 computedPrice, SD59x18 referencePrice)
        external
        pure
        returns (SD59x18, SD59x18, SD59x18)
    {
        return AcademicPaperBenchmarks.compareProtocolErrors(computedPrice, referencePrice);
    }

    function agreesWithinBps(SD59x18 a, SD59x18 b, uint256 basisPoints) external pure returns (bool) {
        return AcademicPaperBenchmarks.agreesWithinBps(a, b, basisPoints);
    }
}

/// @title WriteacademicpaperLaTeXTest
/// @notice Unit tests for AcademicPaperBenchmarks library
contract WriteacademicpaperLaTeXTest is Test {
    AcademicBenchmarkWrapper internal wrapper;

    // Standard ETH option parameters:
    // S = 3000, K = 3000, σ = 0.8 (80%), r = 0.05 (5%), T = 0.25 (3 months)
    BSMParams internal stdParams;

    function setUp() public {
        wrapper = new AcademicBenchmarkWrapper();
        stdParams = BSMParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000), // 0.8
            riskFreeRate: sd(50_000_000_000_000_000), // 0.05
            timeToExpiry: sd(250_000_000_000_000_000) // 0.25
        });
    }

    // =========================================================================
    // Section 3: BSM Pricing — d1/d2
    // =========================================================================

    function test_computeD1D2_ATM() public pure {
        // ATM with zero rate: d1 = σ√T / 2, d2 = -σ√T / 2
        BSMParams memory p = BSMParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000), // 0.8
            riskFreeRate: ZERO,
            timeToExpiry: sd(250_000_000_000_000_000) // 0.25
        });
        (SD59x18 d1, SD59x18 d2) = AcademicPaperBenchmarks.computeD1D2(p);

        // d1 = (0 + 0.8²/2 * 0.25) / (0.8 * 0.5) = 0.08 / 0.4 = 0.2
        assertApproxEqRel(SD59x18.unwrap(d1), 200_000_000_000_000_000, 1e15, "d1 should be ~0.2");
        // d2 = d1 - 0.4 = -0.2
        assertApproxEqRel(SD59x18.unwrap(d2), -200_000_000_000_000_000, 1e15, "d2 should be ~-0.2");
    }

    function test_computeD1D2_d1GreaterThanD2() public pure {
        (SD59x18 d1, SD59x18 d2) = AcademicPaperBenchmarks.computeD1D2(
            BSMParams({
                spot: sd(3000e18),
                strike: sd(3000e18),
                volatility: sd(800_000_000_000_000_000),
                riskFreeRate: sd(50_000_000_000_000_000),
                timeToExpiry: sd(250_000_000_000_000_000)
            })
        );
        // d1 > d2 always since d2 = d1 - σ√T and σ√T > 0
        assertGt(SD59x18.unwrap(d1), SD59x18.unwrap(d2), "d1 must be > d2");
    }

    // =========================================================================
    // Section 3: BSM Pricing — Call Price
    // =========================================================================

    function test_priceCall_ATM_positive() public pure {
        SD59x18 price = AcademicPaperBenchmarks.priceCall(
            BSMParams({
                spot: sd(3000e18),
                strike: sd(3000e18),
                volatility: sd(800_000_000_000_000_000),
                riskFreeRate: sd(50_000_000_000_000_000),
                timeToExpiry: sd(250_000_000_000_000_000)
            })
        );
        assertGt(SD59x18.unwrap(price), 0, "ATM call should have positive price");
    }

    function test_priceCall_deepITM() public pure {
        // Deep ITM: S = 5000, K = 3000 => call ≈ S - K·e^(-rT)
        BSMParams memory p = BSMParams({
            spot: sd(5000e18),
            strike: sd(3000e18),
            volatility: sd(200_000_000_000_000_000), // 0.2 low vol
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        SD59x18 price = AcademicPaperBenchmarks.priceCall(p);
        // Intrinsic value ≈ 5000 - 3000 = 2000; call should be near 2000
        assertGt(SD59x18.unwrap(price), 1900e18, "Deep ITM call should be near intrinsic");
    }

    function test_priceCall_deepOTM() public pure {
        // Deep OTM: S = 1000, K = 3000
        BSMParams memory p = BSMParams({
            spot: sd(1000e18),
            strike: sd(3000e18),
            volatility: sd(200_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        SD59x18 price = AcademicPaperBenchmarks.priceCall(p);
        // Deep OTM call → ≈ 0
        assertLt(SD59x18.unwrap(price), 1e18, "Deep OTM call should be near zero");
    }

    // =========================================================================
    // Section 3: BSM Pricing — Put Price
    // =========================================================================

    function test_pricePut_ATM_positive() public pure {
        SD59x18 price = AcademicPaperBenchmarks.pricePut(
            BSMParams({
                spot: sd(3000e18),
                strike: sd(3000e18),
                volatility: sd(800_000_000_000_000_000),
                riskFreeRate: sd(50_000_000_000_000_000),
                timeToExpiry: sd(250_000_000_000_000_000)
            })
        );
        assertGt(SD59x18.unwrap(price), 0, "ATM put should have positive price");
    }

    function test_pricePut_deepITM() public pure {
        // Deep ITM put: S = 1000, K = 3000
        BSMParams memory p = BSMParams({
            spot: sd(1000e18),
            strike: sd(3000e18),
            volatility: sd(200_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        SD59x18 price = AcademicPaperBenchmarks.pricePut(p);
        assertGt(SD59x18.unwrap(price), 1900e18, "Deep ITM put should be near intrinsic");
    }

    // =========================================================================
    // Section 3: Put-Call Parity
    // =========================================================================

    function test_putCallParity_holds() public pure {
        BSMParams memory p = BSMParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });

        BSMResult memory result = AcademicPaperBenchmarks.priceBSM(p);

        // C - P should equal S - K·e^(-rT)
        SD59x18 discount = sd(-50_000_000_000_000_000).mul(sd(250_000_000_000_000_000)).exp();
        SD59x18 lhs = result.callPrice.sub(result.putPrice);
        SD59x18 rhs = sd(3000e18).sub(sd(3000e18).mul(discount));

        int256 gap = SD59x18.unwrap(lhs.sub(rhs).abs());
        // Allow tolerance for fixed-point rounding
        assertLt(gap, 1e12, "Put-call parity gap should be tiny");
    }

    // =========================================================================
    // Section 4: EWMA Volatility
    // =========================================================================

    function test_ewmaVolatility_singleReturn() public pure {
        SD59x18[] memory returns_ = new SD59x18[](1);
        returns_[0] = sd(10_000_000_000_000_000); // 0.01 daily return

        SD59x18 vol = AcademicPaperBenchmarks.ewmaVolatility(returns_, sd(940_000_000_000_000_000));
        // Single return: variance = r², vol_annual = |r| * √252
        // 0.01 * √252 ≈ 0.1587
        assertGt(SD59x18.unwrap(vol), 0, "EWMA vol must be positive");
        assertApproxEqRel(SD59x18.unwrap(vol), 158_745_078_663_875_435, 1e16, "EWMA vol for single return");
    }

    function test_ewmaVolatility_multipleReturns() public pure {
        SD59x18[] memory returns_ = new SD59x18[](5);
        returns_[0] = sd(10_000_000_000_000_000); // 0.01
        returns_[1] = sd(-15_000_000_000_000_000); // -0.015
        returns_[2] = sd(5_000_000_000_000_000); // 0.005
        returns_[3] = sd(-8_000_000_000_000_000); // -0.008
        returns_[4] = sd(12_000_000_000_000_000); // 0.012

        SD59x18 vol = AcademicPaperBenchmarks.ewmaVolatility(returns_, sd(940_000_000_000_000_000));
        assertGt(SD59x18.unwrap(vol), 0, "EWMA vol must be positive for mixed returns");
    }

    function test_ewmaVolatility_revertsOnEmptyArray() public {
        SD59x18[] memory returns_ = new SD59x18[](0);
        vm.expectRevert(AcademicBenchmark__EmptyReturnsArray.selector);
        wrapper.ewmaVolatility(returns_, sd(940_000_000_000_000_000));
    }

    function test_ewmaVolatility_revertsOnInvalidLambda() public {
        SD59x18[] memory returns_ = new SD59x18[](1);
        returns_[0] = sd(10_000_000_000_000_000);

        // lambda = 0 is invalid
        vm.expectRevert(abi.encodeWithSelector(AcademicBenchmark__InvalidDecayFactor.selector, ZERO));
        wrapper.ewmaVolatility(returns_, ZERO);

        // lambda = 1.0 is invalid
        vm.expectRevert(abi.encodeWithSelector(AcademicBenchmark__InvalidDecayFactor.selector, sd(1e18)));
        wrapper.ewmaVolatility(returns_, sd(1e18));
    }

    // =========================================================================
    // Section 4: Volatility Skew
    // =========================================================================

    function test_volatilitySkew_ATM_isZero() public pure {
        // At the money: m = S/K = 1, deviation = 0, skew = 0
        SD59x18 skew = AcademicPaperBenchmarks.volatilitySkew(
            sd(3000e18), sd(3000e18), sd(500_000_000_000_000_000), sd(-200_000_000_000_000_000)
        );
        assertEq(SD59x18.unwrap(skew), 0, "ATM skew should be zero");
    }

    function test_volatilitySkew_OTM_put() public pure {
        // OTM put: S = 3000, K = 3300 => m = 0.909, deviation < 0
        // a = 0.5, b = -0.2
        SD59x18 skew = AcademicPaperBenchmarks.volatilitySkew(
            sd(3000e18), sd(3300e18), sd(500_000_000_000_000_000), sd(-200_000_000_000_000_000)
        );
        // deviation ≈ -0.091, quadratic term = 0.5 * 0.0083 = 0.004
        // linear term = -0.2 * -0.091 = 0.018
        // skew ≈ 0.022 (positive for OTM puts → "smirk")
        assertGt(SD59x18.unwrap(skew), 0, "OTM put skew should be positive (smirk)");
    }

    function test_volatilitySkew_revertsOnZeroStrike() public {
        vm.expectRevert(abi.encodeWithSelector(AcademicBenchmark__InvalidStrikePrice.selector, ZERO));
        wrapper.volatilitySkew(sd(3000e18), ZERO, sd(500_000_000_000_000_000), sd(-200_000_000_000_000_000));
    }

    // =========================================================================
    // Section 4: Utilization Premium
    // =========================================================================

    function test_utilizationPremium_zeroUtilization() public pure {
        SD59x18 prem =
            AcademicPaperBenchmarks.utilizationPremium(sd(800_000_000_000_000_000), ZERO, sd(500_000_000_000_000_000));
        assertEq(SD59x18.unwrap(prem), 0, "Zero utilization should give zero premium");
    }

    function test_utilizationPremium_halfUtilization() public pure {
        // u = 0.5, k = 0.5, baseIV = 0.8
        // premium = 0.8 * 0.5 * 0.5 / (1 - 0.5) = 0.2 / 0.5 = 0.4
        SD59x18 prem = AcademicPaperBenchmarks.utilizationPremium(
            sd(800_000_000_000_000_000), sd(500_000_000_000_000_000), sd(500_000_000_000_000_000)
        );
        assertApproxEqRel(SD59x18.unwrap(prem), 400_000_000_000_000_000, 1e15, "Premium at 50% util");
    }

    function test_utilizationPremium_revertsAt100Percent() public {
        vm.expectRevert(abi.encodeWithSelector(AcademicBenchmark__UtilizationTooHigh.selector, sd(1e18)));
        wrapper.utilizationPremium(sd(800_000_000_000_000_000), sd(1e18), sd(500_000_000_000_000_000));
    }

    // =========================================================================
    // Section 6: Invariant Checks
    // =========================================================================

    function test_checkInvariants_allPass() public pure {
        BSMParams memory p = BSMParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });

        InvariantCheckResult memory result = AcademicPaperBenchmarks.checkInvariants(p, sd(1e12));
        assertTrue(result.premiumNonNegative, "Premiums should be non-negative");
        assertTrue(result.putCallParityHolds, "Put-call parity should hold");
        assertTrue(result.cdfInUnitInterval, "CDF values should be in [0, 1]");
    }

    function test_assertPutCallParity_doesNotRevert() public view {
        BSMParams memory p = BSMParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        // Should not revert with reasonable tolerance
        wrapper.assertPutCallParity(p, sd(1e12));
    }

    // =========================================================================
    // Section 7: Precision Measurement
    // =========================================================================

    function test_measurePrecision_exactMatch() public pure {
        PrecisionResult memory result = AcademicPaperBenchmarks.measurePrecision(sd(100e18), sd(100e18));
        assertEq(SD59x18.unwrap(result.absoluteError), 0, "Exact match: zero absolute error");
        assertEq(SD59x18.unwrap(result.relativeError), 0, "Exact match: zero relative error");
        assertEq(SD59x18.unwrap(result.bitsOfPrecision), 59e18, "Exact match: max bits of precision");
    }

    function test_measurePrecision_smallError() public pure {
        // computed = 100.001, reference = 100 => relError = 0.00001
        PrecisionResult memory result =
            AcademicPaperBenchmarks.measurePrecision(sd(100_001_000_000_000_000_000), sd(100e18));
        assertApproxEqRel(
            SD59x18.unwrap(result.absoluteError), 1_000_000_000_000_000, 1e15, "Abs error should be 0.001"
        );
        assertGt(SD59x18.unwrap(result.bitsOfPrecision), 0, "Should have positive bits of precision");
    }

    function test_measurePrecision_revertsOnZeroRef() public {
        vm.expectRevert(AcademicBenchmark__ZeroReferenceValue.selector);
        wrapper.measurePrecision(sd(100e18), ZERO);
    }

    // =========================================================================
    // Section 7: Protocol Error Comparison
    // =========================================================================

    function test_compareProtocolErrors_ordering() public pure {
        // MantissaFi computed = 100.0001, ref = 100
        // Mantissa error = 0.0001
        // Lyra estimated error = 1e-7 * 100 = 1e-5
        // Primitive estimated error = 5e-7 * 100 = 5e-5
        (SD59x18 mantissa, SD59x18 lyra, SD59x18 primitive) =
            AcademicPaperBenchmarks.compareProtocolErrors(sd(100_000_100_000_000_000_000), sd(100e18));

        assertGt(SD59x18.unwrap(mantissa), 0, "MantissaFi error should be positive");
        assertGt(SD59x18.unwrap(lyra), 0, "Lyra error estimate should be positive");
        assertGt(SD59x18.unwrap(primitive), 0, "Primitive error estimate should be positive");
        // Primitive error > Lyra error (5e-7 > 1e-7)
        assertGt(SD59x18.unwrap(primitive), SD59x18.unwrap(lyra), "Primitive error > Lyra error");
    }

    function test_compareProtocolErrors_revertsOnZeroRef() public {
        vm.expectRevert(AcademicBenchmark__ZeroReferenceValue.selector);
        wrapper.compareProtocolErrors(sd(100e18), ZERO);
    }

    // =========================================================================
    // Section 7: agreesWithinBps
    // =========================================================================

    function test_agreesWithinBps_exact() public pure {
        assertTrue(AcademicPaperBenchmarks.agreesWithinBps(sd(100e18), sd(100e18), 1), "Exact match within 1bp");
    }

    function test_agreesWithinBps_withinTolerance() public pure {
        // a = 100.005, b = 100 => relError = 0.00005 = 0.5bp
        assertTrue(
            AcademicPaperBenchmarks.agreesWithinBps(sd(100_005_000_000_000_000_000), sd(100e18), 1),
            "0.5bp error within 1bp tolerance"
        );
    }

    function test_agreesWithinBps_outsideTolerance() public pure {
        // a = 101, b = 100 => relError = 0.01 = 100bp
        assertFalse(
            AcademicPaperBenchmarks.agreesWithinBps(sd(101e18), sd(100e18), 1),
            "100bp error should exceed 1bp tolerance"
        );
    }

    function test_agreesWithinBps_zeroReference() public pure {
        // b = 0: only agrees if a = 0 too
        assertTrue(AcademicPaperBenchmarks.agreesWithinBps(ZERO, ZERO, 1), "Zero agrees with zero");
        assertFalse(AcademicPaperBenchmarks.agreesWithinBps(sd(1e18), ZERO, 1), "Non-zero does not agree with zero");
    }

    // =========================================================================
    // Section 7: Greeks
    // =========================================================================

    function test_callDelta_ATM() public pure {
        BSMParams memory p = BSMParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        SD59x18 delta = AcademicPaperBenchmarks.callDelta(p);
        // ATM delta should be roughly 0.5 (slightly above due to drift)
        assertGt(SD59x18.unwrap(delta), 400_000_000_000_000_000, "ATM delta > 0.4");
        assertLt(SD59x18.unwrap(delta), 700_000_000_000_000_000, "ATM delta < 0.7");
    }

    function test_gamma_positive() public pure {
        BSMParams memory p = BSMParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        SD59x18 g = AcademicPaperBenchmarks.gamma(p);
        assertGt(SD59x18.unwrap(g), 0, "Gamma should be positive");
    }

    function test_vega_positive() public pure {
        BSMParams memory p = BSMParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        SD59x18 v = AcademicPaperBenchmarks.vega(p);
        assertGt(SD59x18.unwrap(v), 0, "Vega should be positive");
    }

    function test_callTheta_negative() public pure {
        BSMParams memory p = BSMParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(250_000_000_000_000_000)
        });
        SD59x18 t = AcademicPaperBenchmarks.callTheta(p);
        assertLt(SD59x18.unwrap(t), 0, "Theta should be negative (time decay)");
    }

    // =========================================================================
    // Section 3: CDF Analysis
    // =========================================================================

    function test_cdfSymmetryError_nearZero() public pure {
        SD59x18 err = AcademicPaperBenchmarks.cdfSymmetryError(sd(1e18));
        // Symmetry error should be very small
        assertLt(SD59x18.unwrap(err), 1e12, "CDF symmetry error should be tiny");
    }

    function test_cdfWithComplement_sumsToOne() public pure {
        (SD59x18 cdfVal, SD59x18 comp) = AcademicPaperBenchmarks.cdfWithComplement(sd(500_000_000_000_000_000));
        int256 sum = SD59x18.unwrap(cdfVal) + SD59x18.unwrap(comp);
        assertApproxEqAbs(sum, 1e18, 1e10, "CDF + complement should sum to 1");
    }

    // =========================================================================
    // Validation Revert Tests
    // =========================================================================

    function test_priceCall_revertsOnZeroSpot() public {
        BSMParams memory p = stdParams;
        p.spot = ZERO;
        vm.expectRevert(abi.encodeWithSelector(AcademicBenchmark__InvalidSpotPrice.selector, ZERO));
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnZeroStrike() public {
        BSMParams memory p = stdParams;
        p.strike = ZERO;
        vm.expectRevert(abi.encodeWithSelector(AcademicBenchmark__InvalidStrikePrice.selector, ZERO));
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnZeroVolatility() public {
        BSMParams memory p = stdParams;
        p.volatility = ZERO;
        vm.expectRevert(abi.encodeWithSelector(AcademicBenchmark__InvalidVolatility.selector, ZERO));
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnZeroTimeToExpiry() public {
        BSMParams memory p = stdParams;
        p.timeToExpiry = ZERO;
        vm.expectRevert(abi.encodeWithSelector(AcademicBenchmark__InvalidTimeToExpiry.selector, ZERO));
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnNegativeRate() public {
        BSMParams memory p = stdParams;
        p.riskFreeRate = sd(-1e18);
        vm.expectRevert(abi.encodeWithSelector(AcademicBenchmark__InvalidRiskFreeRate.selector, sd(-1e18)));
        wrapper.priceCall(p);
    }

    // =========================================================================
    // Vol Surface Point Integration
    // =========================================================================

    function test_computeVolSurfacePoint_ATM() public pure {
        VolSurfacePoint memory point = AcademicPaperBenchmarks.computeVolSurfacePoint(
            sd(800_000_000_000_000_000), // baseIV = 0.8
            sd(3000e18), // spot
            sd(3000e18), // strike (ATM)
            sd(500_000_000_000_000_000), // a = 0.5
            sd(-200_000_000_000_000_000), // b = -0.2
            sd(300_000_000_000_000_000), // utilization = 0.3
            sd(500_000_000_000_000_000) // k = 0.5
        );

        // ATM: skew should be zero
        assertEq(SD59x18.unwrap(point.skew), 0, "ATM skew should be zero");
        assertEq(SD59x18.unwrap(point.baseIV), 800_000_000_000_000_000, "Base IV preserved");
        assertGt(SD59x18.unwrap(point.utilizationPremium), 0, "Utilization premium > 0 at 30%");
        // totalIV = baseIV + 0 + premium
        assertGt(SD59x18.unwrap(point.totalIV), 800_000_000_000_000_000, "Total IV > base IV due to premium");
    }
}
