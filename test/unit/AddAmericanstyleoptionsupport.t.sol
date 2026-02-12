// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    AddAmericanstyleoptionsupport,
    AmericanOptionParams,
    AmericanOptionResult,
    LatticeConfig,
    AmericanOption__InvalidSpotPrice,
    AmericanOption__InvalidStrikePrice,
    AmericanOption__InvalidVolatility,
    AmericanOption__InvalidTimeToExpiry,
    AmericanOption__InvalidRiskFreeRate,
    AmericanOption__InvalidSteps,
    AmericanOption__InvalidProbability
} from "../../src/libraries/AddAmericanstyleoptionsupport.sol";

/// @notice Wrapper contract to test library revert behavior via external calls
contract AmericanOptionWrapper {
    function priceCallWithSteps(AmericanOptionParams memory p, uint256 steps)
        external
        pure
        returns (AmericanOptionResult memory)
    {
        return AddAmericanstyleoptionsupport.priceCallWithSteps(p, steps);
    }

    function pricePutWithSteps(AmericanOptionParams memory p, uint256 steps)
        external
        pure
        returns (AmericanOptionResult memory)
    {
        return AddAmericanstyleoptionsupport.pricePutWithSteps(p, steps);
    }

    function buildLattice(AmericanOptionParams memory p, uint256 steps) external pure returns (LatticeConfig memory) {
        return AddAmericanstyleoptionsupport.buildLattice(p, steps);
    }

    function priceEuropean(AmericanOptionParams memory p, bool isCall, uint256 steps) external pure returns (SD59x18) {
        return AddAmericanstyleoptionsupport.priceEuropean(p, isCall, steps);
    }

    function earlyExerciseBoundary(AmericanOptionParams memory p, bool isCall, uint256 steps)
        external
        pure
        returns (SD59x18[] memory)
    {
        return AddAmericanstyleoptionsupport.earlyExerciseBoundary(p, isCall, steps);
    }
}

/// @title AddAmericanstyleoptionsupportTest
/// @notice Unit tests for American option pricing via CRR binomial tree
contract AddAmericanstyleoptionsupportTest is Test {
    AmericanOptionWrapper internal wrapper;

    // Common test parameters: S=100, K=100, σ=0.20, r=0.05, T=1.0
    SD59x18 internal constant SPOT_100 = SD59x18.wrap(100e18);
    SD59x18 internal constant STRIKE_100 = SD59x18.wrap(100e18);
    SD59x18 internal constant STRIKE_80 = SD59x18.wrap(80e18);
    SD59x18 internal constant STRIKE_120 = SD59x18.wrap(120e18);
    SD59x18 internal constant VOL_20 = SD59x18.wrap(200000000000000000); // 0.20
    SD59x18 internal constant VOL_50 = SD59x18.wrap(500000000000000000); // 0.50
    SD59x18 internal constant RATE_5 = SD59x18.wrap(50000000000000000); // 0.05
    SD59x18 internal constant RATE_0 = SD59x18.wrap(0);
    SD59x18 internal constant T_1Y = SD59x18.wrap(1e18); // 1 year
    SD59x18 internal constant T_QUARTER = SD59x18.wrap(250000000000000000); // 0.25 years

    function setUp() public {
        wrapper = new AmericanOptionWrapper();
    }

    function _defaultParams() internal pure returns (AmericanOptionParams memory) {
        return AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
    }

    // =========================================================================
    // Lattice Construction Tests
    // =========================================================================

    function test_buildLattice_upDownInverse() public pure {
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        LatticeConfig memory cfg = AddAmericanstyleoptionsupport.buildLattice(p, 10);

        // u * d should equal 1.0 (CRR property)
        SD59x18 product = cfg.u.mul(cfg.d);
        assertApproxEqRel(SD59x18.unwrap(product), 1e18, 1e14, "u * d should be ~1.0");
    }

    function test_buildLattice_upGreaterThanOne() public pure {
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        LatticeConfig memory cfg = AddAmericanstyleoptionsupport.buildLattice(p, 10);

        assertGt(SD59x18.unwrap(cfg.u), 1e18, "Up factor must be > 1");
        assertLt(SD59x18.unwrap(cfg.d), 1e18, "Down factor must be < 1");
        assertGt(SD59x18.unwrap(cfg.d), 0, "Down factor must be > 0");
    }

    function test_buildLattice_probabilityInRange() public pure {
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        LatticeConfig memory cfg = AddAmericanstyleoptionsupport.buildLattice(p, 32);

        assertGt(SD59x18.unwrap(cfg.p), 0, "Probability must be > 0");
        assertLt(SD59x18.unwrap(cfg.p), 1e18, "Probability must be < 1");
    }

    function test_buildLattice_dtEqualsTimeOverSteps() public pure {
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        LatticeConfig memory cfg = AddAmericanstyleoptionsupport.buildLattice(p, 10);

        // dt = T/N = 1.0/10 = 0.1
        assertApproxEqRel(SD59x18.unwrap(cfg.dt), 100000000000000000, 1e14, "dt should be 0.1");
    }

    // =========================================================================
    // Exercise Value Tests
    // =========================================================================

    function test_exerciseValue_callITM() public pure {
        SD59x18 spot = sd(110e18);
        SD59x18 strike = sd(100e18);
        SD59x18 value = AddAmericanstyleoptionsupport.exerciseValue(spot, strike, true);
        assertEq(SD59x18.unwrap(value), 10e18, "Call exercise value should be 10");
    }

    function test_exerciseValue_callOTM() public pure {
        SD59x18 spot = sd(90e18);
        SD59x18 strike = sd(100e18);
        SD59x18 value = AddAmericanstyleoptionsupport.exerciseValue(spot, strike, true);
        assertEq(SD59x18.unwrap(value), 0, "OTM call exercise value should be 0");
    }

    function test_exerciseValue_putITM() public pure {
        SD59x18 spot = sd(90e18);
        SD59x18 strike = sd(100e18);
        SD59x18 value = AddAmericanstyleoptionsupport.exerciseValue(spot, strike, false);
        assertEq(SD59x18.unwrap(value), 10e18, "Put exercise value should be 10");
    }

    function test_exerciseValue_putOTM() public pure {
        SD59x18 spot = sd(110e18);
        SD59x18 strike = sd(100e18);
        SD59x18 value = AddAmericanstyleoptionsupport.exerciseValue(spot, strike, false);
        assertEq(SD59x18.unwrap(value), 0, "OTM put exercise value should be 0");
    }

    function test_exerciseValue_ATM() public pure {
        SD59x18 callVal = AddAmericanstyleoptionsupport.exerciseValue(SPOT_100, STRIKE_100, true);
        SD59x18 putVal = AddAmericanstyleoptionsupport.exerciseValue(SPOT_100, STRIKE_100, false);
        assertEq(SD59x18.unwrap(callVal), 0, "ATM call exercise should be 0");
        assertEq(SD59x18.unwrap(putVal), 0, "ATM put exercise should be 0");
    }

    // =========================================================================
    // Node Price Tests
    // =========================================================================

    function test_nodePrice_noMoves() public pure {
        SD59x18 u = sd(1_100000000000000000); // 1.1
        SD59x18 d = sd(909090909090909091); // ~1/1.1
        SD59x18 result = AddAmericanstyleoptionsupport.nodePrice(SPOT_100, u, d, 0, 0);
        assertEq(SD59x18.unwrap(result), 100e18, "No moves should return spot");
    }

    function test_nodePrice_oneUp() public pure {
        SD59x18 u = sd(1_100000000000000000); // 1.1
        SD59x18 d = sd(909090909090909091); // ~1/1.1
        SD59x18 result = AddAmericanstyleoptionsupport.nodePrice(SPOT_100, u, d, 1, 0);
        assertApproxEqRel(SD59x18.unwrap(result), 110e18, 1e14, "One up should give S*u");
    }

    function test_nodePrice_upThenDown() public pure {
        SD59x18 u = sd(1_100000000000000000); // 1.1
        SD59x18 d = sd(909090909090909091); // ~1/1.1
        SD59x18 result = AddAmericanstyleoptionsupport.nodePrice(SPOT_100, u, d, 1, 1);
        // S * u * d should ≈ S (recombining tree)
        assertApproxEqRel(SD59x18.unwrap(result), 100e18, 1e14, "Up then down should return ~spot");
    }

    // =========================================================================
    // isEarlyExerciseOptimal Tests
    // =========================================================================

    function test_isEarlyExerciseOptimal_true() public pure {
        bool result = AddAmericanstyleoptionsupport.isEarlyExerciseOptimal(sd(15e18), sd(10e18));
        assertTrue(result, "Exercise > continuation should be optimal");
    }

    function test_isEarlyExerciseOptimal_false() public pure {
        bool result = AddAmericanstyleoptionsupport.isEarlyExerciseOptimal(sd(5e18), sd(10e18));
        assertFalse(result, "Exercise < continuation should not be optimal");
    }

    // =========================================================================
    // American Put Pricing Tests
    // =========================================================================

    function test_pricePut_ATM_positivePrice() public pure {
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.pricePutWithSteps(p, 16);
        assertGt(SD59x18.unwrap(result.price), 0, "ATM put should have positive price");
    }

    function test_pricePut_deepITM_atLeastIntrinsic() public pure {
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: sd(80e18), strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.pricePutWithSteps(p, 16);
        // American put must be worth at least intrinsic: K - S = 20
        assertGe(SD59x18.unwrap(result.price), 20e18, "Deep ITM put >= intrinsic");
    }

    function test_pricePut_earlyExercisePremium_positive() public pure {
        // Deep ITM put with positive rates should have early exercise premium
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: sd(70e18), strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.pricePutWithSteps(p, 16);
        assertGt(SD59x18.unwrap(result.earlyExercisePremium), 0, "Deep ITM put should have early exercise premium");
    }

    function test_pricePut_americanGEuropean() public pure {
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.pricePutWithSteps(p, 16);
        SD59x18 europeanPrice = AddAmericanstyleoptionsupport.priceEuropean(p, false, 16);
        assertGe(SD59x18.unwrap(result.price), SD59x18.unwrap(europeanPrice), "American put >= European put");
    }

    // =========================================================================
    // American Call Pricing Tests
    // =========================================================================

    function test_priceCall_ATM_positivePrice() public pure {
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.priceCallWithSteps(p, 16);
        assertGt(SD59x18.unwrap(result.price), 0, "ATM call should have positive price");
    }

    function test_priceCall_noEarlyExercise_nonDividend() public pure {
        // American call on non-dividend asset has zero early exercise premium
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.priceCallWithSteps(p, 16);
        // For non-dividend paying underlying, American call ≈ European call
        SD59x18 europeanPrice = AddAmericanstyleoptionsupport.priceEuropean(p, true, 16);
        assertApproxEqRel(
            SD59x18.unwrap(result.price),
            SD59x18.unwrap(europeanPrice),
            1e16, // 1% tolerance for binomial tree convergence
            "American call ~= European call for non-dividend"
        );
    }

    function test_priceCall_americanGEuropean() public pure {
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.priceCallWithSteps(p, 16);
        SD59x18 europeanPrice = AddAmericanstyleoptionsupport.priceEuropean(p, true, 16);
        assertGe(SD59x18.unwrap(result.price), SD59x18.unwrap(europeanPrice), "American call >= European call");
    }

    // =========================================================================
    // Delta Tests
    // =========================================================================

    function test_priceCall_deltaPositive() public pure {
        AmericanOptionParams memory p = _defaultParams();
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.priceCallWithSteps(p, 16);
        assertGt(SD59x18.unwrap(result.delta), 0, "Call delta should be positive");
        assertLt(SD59x18.unwrap(result.delta), 1e18, "Call delta should be < 1");
    }

    function test_pricePut_deltaNegative() public pure {
        AmericanOptionParams memory p = _defaultParams();
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.pricePutWithSteps(p, 16);
        assertLt(SD59x18.unwrap(result.delta), 0, "Put delta should be negative");
        assertGt(SD59x18.unwrap(result.delta), -1e18, "Put delta should be > -1");
    }

    // =========================================================================
    // Default Step Count Tests
    // =========================================================================

    function test_priceCall_defaultSteps() public pure {
        AmericanOptionParams memory p = _defaultParams();
        AmericanOptionResult memory resultDefault = AddAmericanstyleoptionsupport.priceCall(p);
        AmericanOptionResult memory resultExplicit = AddAmericanstyleoptionsupport.priceCallWithSteps(p, 32);
        assertEq(
            SD59x18.unwrap(resultDefault.price), SD59x18.unwrap(resultExplicit.price), "Default should use 32 steps"
        );
    }

    function test_pricePut_defaultSteps() public pure {
        AmericanOptionParams memory p = _defaultParams();
        AmericanOptionResult memory resultDefault = AddAmericanstyleoptionsupport.pricePut(p);
        AmericanOptionResult memory resultExplicit = AddAmericanstyleoptionsupport.pricePutWithSteps(p, 32);
        assertEq(
            SD59x18.unwrap(resultDefault.price), SD59x18.unwrap(resultExplicit.price), "Default should use 32 steps"
        );
    }

    // =========================================================================
    // Early Exercise Boundary Tests
    // =========================================================================

    function test_earlyExerciseBoundary_put_returnsArray() public {
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: sd(80e18), strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_5, timeToExpiry: T_1Y
        });
        SD59x18[] memory boundary = wrapper.earlyExerciseBoundary(p, false, 8);
        assertEq(boundary.length, 8, "Boundary length should equal steps");
    }

    // =========================================================================
    // Revert Tests
    // =========================================================================

    function test_priceCall_revertsOnZeroSpot() public {
        AmericanOptionParams memory p = _defaultParams();
        p.spot = ZERO;
        vm.expectRevert(abi.encodeWithSelector(AmericanOption__InvalidSpotPrice.selector, ZERO));
        wrapper.priceCallWithSteps(p, 10);
    }

    function test_priceCall_revertsOnNegativeSpot() public {
        AmericanOptionParams memory p = _defaultParams();
        p.spot = sd(-1e18);
        vm.expectRevert(abi.encodeWithSelector(AmericanOption__InvalidSpotPrice.selector, sd(-1e18)));
        wrapper.priceCallWithSteps(p, 10);
    }

    function test_priceCall_revertsOnZeroStrike() public {
        AmericanOptionParams memory p = _defaultParams();
        p.strike = ZERO;
        vm.expectRevert(abi.encodeWithSelector(AmericanOption__InvalidStrikePrice.selector, ZERO));
        wrapper.priceCallWithSteps(p, 10);
    }

    function test_priceCall_revertsOnZeroVolatility() public {
        AmericanOptionParams memory p = _defaultParams();
        p.volatility = ZERO;
        vm.expectRevert(abi.encodeWithSelector(AmericanOption__InvalidVolatility.selector, ZERO));
        wrapper.priceCallWithSteps(p, 10);
    }

    function test_priceCall_revertsOnZeroTimeToExpiry() public {
        AmericanOptionParams memory p = _defaultParams();
        p.timeToExpiry = ZERO;
        vm.expectRevert(abi.encodeWithSelector(AmericanOption__InvalidTimeToExpiry.selector, ZERO));
        wrapper.priceCallWithSteps(p, 10);
    }

    function test_priceCall_revertsOnNegativeRate() public {
        AmericanOptionParams memory p = _defaultParams();
        p.riskFreeRate = sd(-1e18);
        vm.expectRevert(abi.encodeWithSelector(AmericanOption__InvalidRiskFreeRate.selector, sd(-1e18)));
        wrapper.priceCallWithSteps(p, 10);
    }

    function test_priceCall_revertsOnZeroSteps() public {
        AmericanOptionParams memory p = _defaultParams();
        vm.expectRevert(abi.encodeWithSelector(AmericanOption__InvalidSteps.selector, uint256(0)));
        wrapper.priceCallWithSteps(p, 0);
    }

    function test_priceCall_revertsOnTooManySteps() public {
        AmericanOptionParams memory p = _defaultParams();
        vm.expectRevert(abi.encodeWithSelector(AmericanOption__InvalidSteps.selector, uint256(65)));
        wrapper.priceCallWithSteps(p, 65);
    }

    // =========================================================================
    // Convergence / Accuracy Tests
    // =========================================================================

    function test_priceCall_moreStepsConverges() public pure {
        AmericanOptionParams memory p = _defaultParams();
        AmericanOptionResult memory r8 = AddAmericanstyleoptionsupport.priceCallWithSteps(p, 8);
        AmericanOptionResult memory r16 = AddAmericanstyleoptionsupport.priceCallWithSteps(p, 16);
        AmericanOptionResult memory r32 = AddAmericanstyleoptionsupport.priceCallWithSteps(p, 32);

        // Prices should be in a reasonable ballpark of each other (converging)
        // For ATM call: S=100, K=100, σ=0.20, r=0.05, T=1 => ~10.45 (BS)
        assertGt(SD59x18.unwrap(r8.price), 5e18, "8-step price should be > 5");
        assertLt(SD59x18.unwrap(r8.price), 20e18, "8-step price should be < 20");
        assertGt(SD59x18.unwrap(r32.price), 5e18, "32-step price should be > 5");
        assertLt(SD59x18.unwrap(r32.price), 20e18, "32-step price should be < 20");

        // Higher step counts should be closer to each other than lower ones
        int256 diff_8_16 = SD59x18.unwrap(r8.price) - SD59x18.unwrap(r16.price);
        int256 diff_16_32 = SD59x18.unwrap(r16.price) - SD59x18.unwrap(r32.price);
        int256 absDiff_8_16 = diff_8_16 >= 0 ? diff_8_16 : -diff_8_16;
        int256 absDiff_16_32 = diff_16_32 >= 0 ? diff_16_32 : -diff_16_32;
        assertLe(absDiff_16_32, absDiff_8_16 + 1e16, "Price should converge with more steps");
    }

    function test_pricePut_zeroRateEqualsEuropean() public pure {
        // With r = 0, there's no benefit to early exercise of puts (no discounting gain)
        // so American put ≈ European put
        AmericanOptionParams memory p = AmericanOptionParams({
            spot: SPOT_100, strike: STRIKE_100, volatility: VOL_20, riskFreeRate: RATE_0, timeToExpiry: T_1Y
        });
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.pricePutWithSteps(p, 16);
        SD59x18 europeanPrice = AddAmericanstyleoptionsupport.priceEuropean(p, false, 16);
        assertApproxEqRel(
            SD59x18.unwrap(result.price), SD59x18.unwrap(europeanPrice), 1e16, "With r=0, American put ~= European put"
        );
    }

    // =========================================================================
    // Edge Case: Maximum Steps
    // =========================================================================

    function test_priceCall_maxSteps() public pure {
        AmericanOptionParams memory p = _defaultParams();
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.priceCallWithSteps(p, 64);
        assertGt(SD59x18.unwrap(result.price), 0, "64-step price should be positive");
    }

    function test_priceCall_singleStep() public pure {
        AmericanOptionParams memory p = _defaultParams();
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.priceCallWithSteps(p, 1);
        assertGt(SD59x18.unwrap(result.price), 0, "1-step price should be positive");
    }
}
