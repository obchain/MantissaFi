// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { CertoraspecPricing } from "../../src/libraries/CertoraspecPricing.sol";
import { PricingParams, MonotonicityResult } from "../../src/libraries/CertoraspecPricing.sol";

/// @title CertoraspecHarness
/// @notice Harness contract to expose internal library functions and test reverts via external calls
contract CertoraspecHarness {
    function computeD1(PricingParams memory p) external pure returns (SD59x18) {
        return CertoraspecPricing.computeD1(p);
    }

    function computeD2(PricingParams memory p, SD59x18 d1) external pure returns (SD59x18) {
        return CertoraspecPricing.computeD2(p, d1);
    }

    function priceCall(PricingParams memory p) external pure returns (SD59x18) {
        return CertoraspecPricing.priceCall(p);
    }

    function pricePut(PricingParams memory p) external pure returns (SD59x18) {
        return CertoraspecPricing.pricePut(p);
    }

    function callDelta(PricingParams memory p) external pure returns (SD59x18) {
        return CertoraspecPricing.callDelta(p);
    }

    function putDelta(PricingParams memory p) external pure returns (SD59x18) {
        return CertoraspecPricing.putDelta(p);
    }

    function vega(PricingParams memory p) external pure returns (SD59x18) {
        return CertoraspecPricing.vega(p);
    }

    function gamma(PricingParams memory p) external pure returns (SD59x18) {
        return CertoraspecPricing.gamma(p);
    }

    function verifyCallDeltaPositive(PricingParams memory p) external pure returns (bool) {
        return CertoraspecPricing.verifyCallDeltaPositive(p);
    }

    function verifyPutDeltaNegative(PricingParams memory p) external pure returns (bool) {
        return CertoraspecPricing.verifyPutDeltaNegative(p);
    }

    function verifyVegaPositive(PricingParams memory p) external pure returns (bool) {
        return CertoraspecPricing.verifyVegaPositive(p);
    }

    function verifyCallMonotonicInSpot(PricingParams memory p, SD59x18 epsilon)
        external
        pure
        returns (MonotonicityResult memory)
    {
        return CertoraspecPricing.verifyCallMonotonicInSpot(p, epsilon);
    }

    function verifyPutMonotonicInSpot(PricingParams memory p, SD59x18 epsilon)
        external
        pure
        returns (MonotonicityResult memory)
    {
        return CertoraspecPricing.verifyPutMonotonicInSpot(p, epsilon);
    }

    function verifyCallMonotonicInVol(PricingParams memory p, SD59x18 epsilon)
        external
        pure
        returns (MonotonicityResult memory)
    {
        return CertoraspecPricing.verifyCallMonotonicInVol(p, epsilon);
    }

    function verifyPutMonotonicInVol(PricingParams memory p, SD59x18 epsilon)
        external
        pure
        returns (MonotonicityResult memory)
    {
        return CertoraspecPricing.verifyPutMonotonicInVol(p, epsilon);
    }

    function assertCallMonotonicInSpot(PricingParams memory p, SD59x18 epsilon) external pure {
        CertoraspecPricing.assertCallMonotonicInSpot(p, epsilon);
    }

    function assertPutMonotonicInSpot(PricingParams memory p, SD59x18 epsilon) external pure {
        CertoraspecPricing.assertPutMonotonicInSpot(p, epsilon);
    }

    function assertCallMonotonicInVol(PricingParams memory p, SD59x18 epsilon) external pure {
        CertoraspecPricing.assertCallMonotonicInVol(p, epsilon);
    }

    function assertPutMonotonicInVol(PricingParams memory p, SD59x18 epsilon) external pure {
        CertoraspecPricing.assertPutMonotonicInVol(p, epsilon);
    }

    function verifyAllInvariants(PricingParams memory p, SD59x18 epsilon) external pure returns (bool, bool, bool) {
        return CertoraspecPricing.verifyAllInvariants(p, epsilon);
    }

    function assertAllInvariants(PricingParams memory p, SD59x18 epsilon) external pure {
        CertoraspecPricing.assertAllInvariants(p, epsilon);
    }

    function verifyPutCallParity(PricingParams memory p, SD59x18 tolerance) external pure returns (bool, SD59x18) {
        return CertoraspecPricing.verifyPutCallParity(p, tolerance);
    }

    function verifyCallDeltaBounds(PricingParams memory p) external pure returns (bool, SD59x18) {
        return CertoraspecPricing.verifyCallDeltaBounds(p);
    }

    function verifyPutDeltaBounds(PricingParams memory p) external pure returns (bool, SD59x18) {
        return CertoraspecPricing.verifyPutDeltaBounds(p);
    }

    function verifyGammaPositive(PricingParams memory p) external pure returns (bool, SD59x18) {
        return CertoraspecPricing.verifyGammaPositive(p);
    }

    function validateParams(PricingParams memory p) external pure {
        CertoraspecPricing.validateParams(p);
    }
}

/// @title CertoraspecTest
/// @notice Unit tests for Certoraspec pricing monotonicity invariant library
contract CertoraspecTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    //                              TEST CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    int256 private constant ONE = 1e18;

    // Typical ETH option parameters
    int256 private constant ETH_SPOT = 2000e18;
    int256 private constant ETH_STRIKE_ATM = 2000e18;
    int256 private constant ETH_STRIKE_OTM_CALL = 2200e18;
    int256 private constant ETH_STRIKE_OTM_PUT = 1800e18;
    int256 private constant ETH_STRIKE_DEEP_ITM_CALL = 1000e18;
    int256 private constant ETH_STRIKE_DEEP_OTM_CALL = 4000e18;

    int256 private constant VOL_20 = 200000000000000000; // 20%
    int256 private constant VOL_50 = 500000000000000000; // 50%
    int256 private constant VOL_80 = 800000000000000000; // 80%
    int256 private constant VOL_150 = 1_500000000000000000; // 150%

    int256 private constant RATE_5 = 50000000000000000; // 5%
    int256 private constant RATE_0 = 0;

    int256 private constant TIME_1Y = 1e18;
    int256 private constant TIME_6M = 500000000000000000;
    int256 private constant TIME_1M = 83333333333333333; // 1/12
    int256 private constant TIME_1W = 19178082191780822; // 7/365

    int256 private constant EPSILON_1PCT = 10000000000000000; // 0.01
    int256 private constant EPSILON_SMALL = 1000000000000000; // 0.001

    CertoraspecHarness harness;

    function setUp() public {
        harness = new CertoraspecHarness();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                      HELPER: Build standard params
    // ═══════════════════════════════════════════════════════════════════════════

    function _params(int256 spot, int256 strike, int256 vol, int256 rate, int256 time)
        private
        pure
        returns (PricingParams memory)
    {
        return PricingParams({
            spot: sd(spot), strike: sd(strike), volatility: sd(vol), riskFreeRate: sd(rate), timeToExpiry: sd(time)
        });
    }

    function _defaultParams() private pure returns (PricingParams memory) {
        return _params(ETH_SPOT, ETH_STRIKE_ATM, VOL_50, RATE_5, TIME_1Y);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VALIDATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_validateParams_RevertsOnZeroSpot() public {
        PricingParams memory p = _params(0, ETH_STRIKE_ATM, VOL_50, RATE_5, TIME_1Y);
        vm.expectRevert();
        harness.validateParams(p);
    }

    function test_validateParams_RevertsOnNegativeSpot() public {
        PricingParams memory p = _params(-1e18, ETH_STRIKE_ATM, VOL_50, RATE_5, TIME_1Y);
        vm.expectRevert();
        harness.validateParams(p);
    }

    function test_validateParams_RevertsOnZeroStrike() public {
        PricingParams memory p = _params(ETH_SPOT, 0, VOL_50, RATE_5, TIME_1Y);
        vm.expectRevert();
        harness.validateParams(p);
    }

    function test_validateParams_RevertsOnZeroVolatility() public {
        PricingParams memory p = _params(ETH_SPOT, ETH_STRIKE_ATM, 0, RATE_5, TIME_1Y);
        vm.expectRevert();
        harness.validateParams(p);
    }

    function test_validateParams_RevertsOnZeroTimeToExpiry() public {
        PricingParams memory p = _params(ETH_SPOT, ETH_STRIKE_ATM, VOL_50, RATE_5, 0);
        vm.expectRevert();
        harness.validateParams(p);
    }

    function test_validateParams_RevertsOnNegativeRate() public {
        PricingParams memory p = _params(ETH_SPOT, ETH_STRIKE_ATM, VOL_50, -1e18, TIME_1Y);
        vm.expectRevert();
        harness.validateParams(p);
    }

    function test_validateParams_AcceptsZeroRate() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: ZERO,
            timeToExpiry: sd(TIME_1Y)
        });
        CertoraspecPricing.validateParams(p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                     BSM PRICING: BASIC SANITY
    // ═══════════════════════════════════════════════════════════════════════════

    function test_priceCall_ATM_IsPositive() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        SD59x18 price = CertoraspecPricing.priceCall(p);
        assertTrue(price.gt(ZERO), "ATM call price should be positive");
    }

    function test_pricePut_ATM_IsPositive() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        SD59x18 price = CertoraspecPricing.pricePut(p);
        assertTrue(price.gt(ZERO), "ATM put price should be positive");
    }

    function test_priceCall_DeepITM_ApproachesIntrinsic() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_DEEP_ITM_CALL),
            volatility: sd(VOL_20),
            riskFreeRate: ZERO,
            timeToExpiry: sd(TIME_1W)
        });
        SD59x18 price = CertoraspecPricing.priceCall(p);
        SD59x18 intrinsic = sd(ETH_SPOT).sub(sd(ETH_STRIKE_DEEP_ITM_CALL));
        // Deep ITM short-dated call should be close to intrinsic
        assertTrue(price.gte(intrinsic), "Deep ITM call should be >= intrinsic");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //              INVARIANT 1: ∂C/∂S > 0 (Call delta positive)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_verifyCallDeltaPositive_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        assertTrue(CertoraspecPricing.verifyCallDeltaPositive(p), "ATM call delta should be positive");
    }

    function test_verifyCallDeltaPositive_OTM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_OTM_CALL),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_6M)
        });
        assertTrue(CertoraspecPricing.verifyCallDeltaPositive(p), "OTM call delta should be positive");
    }

    function test_verifyCallMonotonicInSpot_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        MonotonicityResult memory res = CertoraspecPricing.verifyCallMonotonicInSpot(p, sd(EPSILON_1PCT));
        assertTrue(res.holds, "Call should be monotonic in spot");
        assertTrue(res.upperValue.gt(res.lowerValue), "Higher spot should give higher call price");
        assertTrue(res.greekValue.gt(ZERO), "Call delta should be positive");
    }

    function test_verifyCallMonotonicInSpot_OTMCall() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_OTM_CALL),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_6M)
        });
        MonotonicityResult memory res = CertoraspecPricing.verifyCallMonotonicInSpot(p, sd(EPSILON_1PCT));
        assertTrue(res.holds, "OTM call should be monotonic in spot");
    }

    function test_assertCallMonotonicInSpot_DoesNotRevert() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        CertoraspecPricing.assertCallMonotonicInSpot(p, sd(EPSILON_1PCT));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //              INVARIANT 2: ∂P/∂S < 0 (Put delta negative)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_verifyPutDeltaNegative_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        assertTrue(CertoraspecPricing.verifyPutDeltaNegative(p), "ATM put delta should be negative");
    }

    function test_verifyPutDeltaNegative_OTMPut() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_OTM_PUT),
            volatility: sd(VOL_20),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1M)
        });
        assertTrue(CertoraspecPricing.verifyPutDeltaNegative(p), "OTM put delta should be negative");
    }

    function test_verifyPutMonotonicInSpot_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        MonotonicityResult memory res = CertoraspecPricing.verifyPutMonotonicInSpot(p, sd(EPSILON_1PCT));
        assertTrue(res.holds, "Put should be anti-monotonic in spot");
        assertTrue(res.upperValue.lte(res.lowerValue), "Higher spot should give lower put price");
        assertTrue(res.greekValue.lt(ZERO), "Put delta should be negative");
    }

    function test_verifyPutMonotonicInSpot_OTMPut() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_OTM_PUT),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_6M)
        });
        MonotonicityResult memory res = CertoraspecPricing.verifyPutMonotonicInSpot(p, sd(EPSILON_1PCT));
        assertTrue(res.holds, "OTM put should be anti-monotonic in spot");
    }

    function test_assertPutMonotonicInSpot_DoesNotRevert() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        CertoraspecPricing.assertPutMonotonicInSpot(p, sd(EPSILON_1PCT));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //              INVARIANT 3: ∂/∂σ > 0 (Vega positive)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_verifyVegaPositive_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        assertTrue(CertoraspecPricing.verifyVegaPositive(p), "ATM vega should be positive");
    }

    function test_verifyVegaPositive_OTM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_OTM_CALL),
            volatility: sd(VOL_20),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1M)
        });
        assertTrue(CertoraspecPricing.verifyVegaPositive(p), "OTM vega should be positive");
    }

    function test_verifyCallMonotonicInVol_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        MonotonicityResult memory res = CertoraspecPricing.verifyCallMonotonicInVol(p, sd(EPSILON_1PCT));
        assertTrue(res.holds, "Call should be monotonic in vol");
        assertTrue(res.upperValue.gt(res.lowerValue), "Higher vol should give higher call price");
    }

    function test_verifyPutMonotonicInVol_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        MonotonicityResult memory res = CertoraspecPricing.verifyPutMonotonicInVol(p, sd(EPSILON_1PCT));
        assertTrue(res.holds, "Put should be monotonic in vol");
        assertTrue(res.upperValue.gt(res.lowerValue), "Higher vol should give higher put price");
    }

    function test_assertCallMonotonicInVol_DoesNotRevert() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        CertoraspecPricing.assertCallMonotonicInVol(p, sd(EPSILON_1PCT));
    }

    function test_assertPutMonotonicInVol_DoesNotRevert() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        CertoraspecPricing.assertPutMonotonicInVol(p, sd(EPSILON_1PCT));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                     COMPOSITE VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_verifyAllInvariants_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        (bool callOk, bool putOk, bool vegaOk) = CertoraspecPricing.verifyAllInvariants(p, sd(EPSILON_1PCT));
        assertTrue(callOk, "Call spot monotonicity should hold");
        assertTrue(putOk, "Put spot monotonicity should hold");
        assertTrue(vegaOk, "Vega monotonicity should hold");
    }

    function test_assertAllInvariants_DoesNotRevert_HighVol() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_OTM_CALL),
            volatility: sd(VOL_150),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_6M)
        });
        CertoraspecPricing.assertAllInvariants(p, sd(EPSILON_1PCT));
    }

    function test_assertAllInvariants_DoesNotRevert_ZeroRate() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: ZERO,
            timeToExpiry: sd(TIME_1Y)
        });
        CertoraspecPricing.assertAllInvariants(p, sd(EPSILON_1PCT));
    }

    function test_assertAllInvariants_DoesNotRevert_ShortDated() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1W)
        });
        CertoraspecPricing.assertAllInvariants(p, sd(EPSILON_SMALL));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                      PUT-CALL PARITY
    // ═══════════════════════════════════════════════════════════════════════════

    function test_verifyPutCallParity_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        // Tolerance of 1e15 (0.001 in SD59x18) for numerical imprecision
        (bool holds, SD59x18 deviation) = CertoraspecPricing.verifyPutCallParity(p, sd(1e15));
        assertTrue(holds, "Put-call parity should hold at ATM");
        assertTrue(deviation.lt(sd(1e15)), "Deviation should be small");
    }

    function test_verifyPutCallParity_OTM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_OTM_CALL),
            volatility: sd(VOL_80),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_6M)
        });
        (bool holds,) = CertoraspecPricing.verifyPutCallParity(p, sd(1e15));
        assertTrue(holds, "Put-call parity should hold OTM");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        DELTA BOUNDS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_verifyCallDeltaBounds_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        (bool inBounds, SD59x18 delta) = CertoraspecPricing.verifyCallDeltaBounds(p);
        assertTrue(inBounds, "Call delta should be in (0, 1)");
        // ATM call delta should be around 0.5-0.6
        assertTrue(delta.gt(sd(400000000000000000)), "ATM call delta should be > 0.4");
        assertTrue(delta.lt(sd(700000000000000000)), "ATM call delta should be < 0.7");
    }

    function test_verifyPutDeltaBounds_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        (bool inBounds, SD59x18 delta) = CertoraspecPricing.verifyPutDeltaBounds(p);
        assertTrue(inBounds, "Put delta should be in (-1, 0)");
        // ATM put delta should be around -0.4 to -0.5
        assertTrue(delta.lt(sd(-300000000000000000)), "ATM put delta should be < -0.3");
        assertTrue(delta.gt(sd(-600000000000000000)), "ATM put delta should be > -0.6");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        GAMMA POSITIVITY
    // ═══════════════════════════════════════════════════════════════════════════

    function test_verifyGammaPositive_ATM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        (bool isPositive, SD59x18 gammaVal) = CertoraspecPricing.verifyGammaPositive(p);
        assertTrue(isPositive, "Gamma should be positive");
        assertTrue(gammaVal.gt(ZERO), "Gamma value should be > 0");
    }

    function test_verifyGammaPositive_OTM() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_OTM_CALL),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_6M)
        });
        (bool isPositive,) = CertoraspecPricing.verifyGammaPositive(p);
        assertTrue(isPositive, "OTM gamma should be positive");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                   EPSILON VALIDATION (edge cases)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_verifyCallMonotonicInSpot_RevertsOnZeroEpsilon() public {
        PricingParams memory p = _defaultParams();
        vm.expectRevert();
        harness.verifyCallMonotonicInSpot(p, ZERO);
    }

    function test_verifyCallMonotonicInSpot_RevertsOnNegativeEpsilon() public {
        PricingParams memory p = _defaultParams();
        vm.expectRevert();
        harness.verifyCallMonotonicInSpot(p, sd(-1e18));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //               CROSS-REGIME: low price, high vol, short time
    // ═══════════════════════════════════════════════════════════════════════════

    function test_assertAllInvariants_LowPrice() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(1e18),
            strike: sd(1e18),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        CertoraspecPricing.assertAllInvariants(p, sd(EPSILON_SMALL));
    }

    function test_assertAllInvariants_HighPrice() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(100_000e18),
            strike: sd(100_000e18),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        CertoraspecPricing.assertAllInvariants(p, sd(100e18));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                     GREEKS: analytical values
    // ═══════════════════════════════════════════════════════════════════════════

    function test_callDelta_DeepITM_NearOne() public pure {
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_DEEP_ITM_CALL),
            volatility: sd(VOL_20),
            riskFreeRate: ZERO,
            timeToExpiry: sd(TIME_1W)
        });
        SD59x18 delta = CertoraspecPricing.callDelta(p);
        // Deep ITM short-dated call delta should be near 1.0
        assertTrue(delta.gt(sd(950000000000000000)), "Deep ITM call delta should be > 0.95");
    }

    function test_putDelta_DeepITMPut_NearNegOne() public pure {
        // Deep ITM put: strike >> spot
        PricingParams memory p = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_DEEP_OTM_CALL), // 4000 strike = deep ITM put
            volatility: sd(VOL_20),
            riskFreeRate: ZERO,
            timeToExpiry: sd(TIME_1W)
        });
        SD59x18 delta = CertoraspecPricing.putDelta(p);
        // Deep ITM short-dated put delta should be near -1.0
        assertTrue(delta.lt(sd(-950000000000000000)), "Deep ITM put delta should be < -0.95");
    }

    function test_vega_ATM_IsMaximal() public pure {
        // Vega is highest at ATM
        PricingParams memory pATM = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_ATM),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });
        PricingParams memory pOTM = PricingParams({
            spot: sd(ETH_SPOT),
            strike: sd(ETH_STRIKE_DEEP_OTM_CALL),
            volatility: sd(VOL_50),
            riskFreeRate: sd(RATE_5),
            timeToExpiry: sd(TIME_1Y)
        });

        SD59x18 vegaATM = CertoraspecPricing.vega(pATM);
        SD59x18 vegaOTM = CertoraspecPricing.vega(pOTM);

        assertTrue(vegaATM.gt(vegaOTM), "ATM vega should be greater than OTM vega");
    }
}
