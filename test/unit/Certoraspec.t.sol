// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { Certoraspec } from "../../src/libraries/Certoraspec.sol";

/// @notice Wrapper contract to test library revert behavior
contract CertoraspecWrapper {
    function enforceNoValueExtraction(
        Certoraspec.MintPosition memory position,
        Certoraspec.ExerciseParams memory params
    ) external pure returns (SD59x18) {
        return Certoraspec.enforceNoValueExtraction(position, params);
    }

    function enforceCollateralSufficiency(SD59x18 collateralLocked, SD59x18 strike, bool isCall, uint256 amount)
        external
        pure
    {
        Certoraspec.enforceCollateralSufficiency(collateralLocked, strike, isCall, amount);
    }

    function computeIntrinsicValue(SD59x18 spot, SD59x18 strike, bool isCall, uint256 amount)
        external
        pure
        returns (SD59x18)
    {
        return Certoraspec.computeIntrinsicValue(spot, strike, isCall, amount);
    }

    function recordMint(Certoraspec.MintPosition memory position, SD59x18 premium, SD59x18 collateral, uint256 amount)
        external
        pure
        returns (Certoraspec.MintPosition memory)
    {
        return Certoraspec.recordMint(position, premium, collateral, amount);
    }

    function recordExercise(Certoraspec.MintPosition memory position, uint256 exerciseAmount)
        external
        pure
        returns (Certoraspec.MintPosition memory)
    {
        return Certoraspec.recordExercise(position, exerciseAmount);
    }

    function computeCollateralRatio(SD59x18 collateralLocked, SD59x18 strike, bool isCall, uint256 amount)
        external
        pure
        returns (SD59x18)
    {
        return Certoraspec.computeCollateralRatio(collateralLocked, strike, isCall, amount);
    }
}

/// @title CertoraspecTest
/// @notice Unit tests for Certoraspec library
contract CertoraspecTest is Test {
    CertoraspecWrapper internal wrapper;

    // Test values in SD59x18 format
    SD59x18 internal constant ETH_3000 = SD59x18.wrap(3000e18);
    SD59x18 internal constant ETH_3100 = SD59x18.wrap(3100e18);
    SD59x18 internal constant ETH_2900 = SD59x18.wrap(2900e18);
    SD59x18 internal constant ETH_5000 = SD59x18.wrap(5000e18);
    SD59x18 internal constant ETH_1000 = SD59x18.wrap(1000e18);
    SD59x18 internal constant PREMIUM_50 = SD59x18.wrap(50e18);
    SD59x18 internal constant PREMIUM_100 = SD59x18.wrap(100e18);
    SD59x18 internal constant COLLATERAL_3000 = SD59x18.wrap(3000e18);
    SD59x18 internal constant ONE = SD59x18.wrap(1e18);
    SD59x18 internal constant TEN = SD59x18.wrap(10e18);

    function setUp() public {
        wrapper = new CertoraspecWrapper();
    }

    // =========================================================================
    // computeIntrinsicValue Tests
    // =========================================================================

    function test_computeIntrinsicValue_callITM() public pure {
        // Call: spot=3100, strike=3000, amount=1 -> intrinsic = 100
        SD59x18 value = Certoraspec.computeIntrinsicValue(ETH_3100, ETH_3000, true, 1);
        assertEq(SD59x18.unwrap(value), 100e18, "Call ITM intrinsic should be 100");
    }

    function test_computeIntrinsicValue_callOTM() public pure {
        // Call: spot=2900, strike=3000 -> intrinsic = 0
        SD59x18 value = Certoraspec.computeIntrinsicValue(ETH_2900, ETH_3000, true, 1);
        assertEq(SD59x18.unwrap(value), 0, "Call OTM intrinsic should be 0");
    }

    function test_computeIntrinsicValue_callATM() public pure {
        // Call: spot=3000, strike=3000 -> intrinsic = 0
        SD59x18 value = Certoraspec.computeIntrinsicValue(ETH_3000, ETH_3000, true, 1);
        assertEq(SD59x18.unwrap(value), 0, "Call ATM intrinsic should be 0");
    }

    function test_computeIntrinsicValue_putITM() public pure {
        // Put: spot=2900, strike=3000, amount=1 -> intrinsic = 100
        SD59x18 value = Certoraspec.computeIntrinsicValue(ETH_2900, ETH_3000, false, 1);
        assertEq(SD59x18.unwrap(value), 100e18, "Put ITM intrinsic should be 100");
    }

    function test_computeIntrinsicValue_putOTM() public pure {
        // Put: spot=3100, strike=3000 -> intrinsic = 0
        SD59x18 value = Certoraspec.computeIntrinsicValue(ETH_3100, ETH_3000, false, 1);
        assertEq(SD59x18.unwrap(value), 0, "Put OTM intrinsic should be 0");
    }

    function test_computeIntrinsicValue_multipleOptions() public pure {
        // Call: spot=3100, strike=3000, amount=5 -> intrinsic = 500
        SD59x18 value = Certoraspec.computeIntrinsicValue(ETH_3100, ETH_3000, true, 5);
        assertEq(SD59x18.unwrap(value), 500e18, "Intrinsic for 5 options should be 500");
    }

    function test_computeIntrinsicValue_revertsOnZeroSpot() public {
        vm.expectRevert(Certoraspec.Certoraspec__InvalidSpotPrice.selector);
        wrapper.computeIntrinsicValue(ZERO, ETH_3000, true, 1);
    }

    function test_computeIntrinsicValue_revertsOnZeroStrike() public {
        vm.expectRevert(Certoraspec.Certoraspec__InvalidStrikePrice.selector);
        wrapper.computeIntrinsicValue(ETH_3000, ZERO, true, 1);
    }

    // =========================================================================
    // computePayout Tests
    // =========================================================================

    function test_computePayout_equalsIntrinsicValue() public pure {
        // Payout must always equal intrinsic value (no excess)
        SD59x18 payout = Certoraspec.computePayout(ETH_3100, ETH_3000, true, 1);
        SD59x18 intrinsic = Certoraspec.computeIntrinsicValue(ETH_3100, ETH_3000, true, 1);
        assertEq(SD59x18.unwrap(payout), SD59x18.unwrap(intrinsic), "Payout must equal intrinsic value");
    }

    function test_computePayout_zeroForOTM() public pure {
        SD59x18 payout = Certoraspec.computePayout(ETH_2900, ETH_3000, true, 1);
        assertEq(SD59x18.unwrap(payout), 0, "OTM payout should be 0");
    }

    // =========================================================================
    // validateNoValueExtraction Tests
    // =========================================================================

    function test_validateNoValueExtraction_validCallITM() public pure {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: PREMIUM_50, collateralLocked: COLLATERAL_3000, amountMinted: 1, amountExercised: 0
        });
        Certoraspec.ExerciseParams memory params =
            Certoraspec.ExerciseParams({ spot: ETH_3100, strike: ETH_3000, isCall: true, exerciseAmount: 1 });

        Certoraspec.InvariantResult memory result = Certoraspec.validateNoValueExtraction(pos, params);

        assertTrue(result.isValid, "Invariant should hold for valid call exercise");
        assertEq(SD59x18.unwrap(result.payout), 100e18, "Payout should be 100");
        assertEq(SD59x18.unwrap(result.intrinsicValue), 100e18, "Intrinsic should be 100");
    }

    function test_validateNoValueExtraction_validPutITM() public pure {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: PREMIUM_50, collateralLocked: COLLATERAL_3000, amountMinted: 1, amountExercised: 0
        });
        Certoraspec.ExerciseParams memory params =
            Certoraspec.ExerciseParams({ spot: ETH_2900, strike: ETH_3000, isCall: false, exerciseAmount: 1 });

        Certoraspec.InvariantResult memory result = Certoraspec.validateNoValueExtraction(pos, params);

        assertTrue(result.isValid, "Invariant should hold for valid put exercise");
        assertEq(SD59x18.unwrap(result.payout), 100e18, "Put payout should be 100");
    }

    function test_validateNoValueExtraction_invalidZeroPremium() public pure {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: ZERO, collateralLocked: COLLATERAL_3000, amountMinted: 1, amountExercised: 0
        });
        Certoraspec.ExerciseParams memory params =
            Certoraspec.ExerciseParams({ spot: ETH_3100, strike: ETH_3000, isCall: true, exerciseAmount: 1 });

        Certoraspec.InvariantResult memory result = Certoraspec.validateNoValueExtraction(pos, params);

        assertFalse(result.isValid, "Invariant should fail with zero premium");
    }

    function test_validateNoValueExtraction_OTMexercise() public pure {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: PREMIUM_50, collateralLocked: COLLATERAL_3000, amountMinted: 1, amountExercised: 0
        });
        Certoraspec.ExerciseParams memory params =
            Certoraspec.ExerciseParams({ spot: ETH_2900, strike: ETH_3000, isCall: true, exerciseAmount: 1 });

        Certoraspec.InvariantResult memory result = Certoraspec.validateNoValueExtraction(pos, params);

        assertTrue(result.isValid, "OTM exercise should still satisfy invariant (payout=0)");
        assertEq(SD59x18.unwrap(result.payout), 0, "OTM call payout should be 0");
    }

    // =========================================================================
    // enforceNoValueExtraction Tests
    // =========================================================================

    function test_enforceNoValueExtraction_success() public pure {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: PREMIUM_50, collateralLocked: COLLATERAL_3000, amountMinted: 1, amountExercised: 0
        });
        Certoraspec.ExerciseParams memory params =
            Certoraspec.ExerciseParams({ spot: ETH_3100, strike: ETH_3000, isCall: true, exerciseAmount: 1 });

        SD59x18 payout = Certoraspec.enforceNoValueExtraction(pos, params);
        assertEq(SD59x18.unwrap(payout), 100e18, "Enforcement should return payout of 100");
    }

    function test_enforceNoValueExtraction_revertsOnZeroPremium() public {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: ZERO, collateralLocked: COLLATERAL_3000, amountMinted: 1, amountExercised: 0
        });
        Certoraspec.ExerciseParams memory params =
            Certoraspec.ExerciseParams({ spot: ETH_3100, strike: ETH_3000, isCall: true, exerciseAmount: 1 });

        vm.expectRevert(Certoraspec.Certoraspec__ZeroPremium.selector);
        wrapper.enforceNoValueExtraction(pos, params);
    }

    function test_enforceNoValueExtraction_revertsOnExcessExercise() public {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: PREMIUM_50, collateralLocked: COLLATERAL_3000, amountMinted: 1, amountExercised: 0
        });
        Certoraspec.ExerciseParams memory params =
            Certoraspec.ExerciseParams({ spot: ETH_3100, strike: ETH_3000, isCall: true, exerciseAmount: 2 });

        vm.expectRevert(abi.encodeWithSelector(Certoraspec.Certoraspec__ExerciseExceedsMinted.selector, 2, 1));
        wrapper.enforceNoValueExtraction(pos, params);
    }

    // =========================================================================
    // Collateral Sufficiency Tests
    // =========================================================================

    function test_verifyCollateralSufficiency_callSufficient() public pure {
        // Call: 1 underlying per option, collateral = 10, amount = 5
        bool sufficient = Certoraspec.verifyCollateralSufficiency(TEN, ETH_3000, true, 5);
        assertTrue(sufficient, "10 collateral should cover 5 call options");
    }

    function test_verifyCollateralSufficiency_callInsufficient() public pure {
        // Call: 1 underlying per option, collateral = 1, amount = 5
        bool sufficient = Certoraspec.verifyCollateralSufficiency(ONE, ETH_3000, true, 5);
        assertFalse(sufficient, "1 collateral should not cover 5 call options");
    }

    function test_verifyCollateralSufficiency_putSufficient() public pure {
        // Put: strike * amount, collateral = 3000, strike = 3000, amount = 1
        bool sufficient = Certoraspec.verifyCollateralSufficiency(COLLATERAL_3000, ETH_3000, false, 1);
        assertTrue(sufficient, "3000 collateral should cover 1 put at strike 3000");
    }

    function test_verifyCollateralSufficiency_putInsufficient() public pure {
        // Put: strike * amount, collateral = 1000, strike = 3000, amount = 1
        bool sufficient = Certoraspec.verifyCollateralSufficiency(ETH_1000, ETH_3000, false, 1);
        assertFalse(sufficient, "1000 collateral should not cover 1 put at strike 3000");
    }

    function test_enforceCollateralSufficiency_revertsOnInsufficient() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Certoraspec.Certoraspec__InsufficientCollateral.selector,
                SD59x18.unwrap(ETH_1000),
                SD59x18.unwrap(ETH_3000)
            )
        );
        wrapper.enforceCollateralSufficiency(ETH_1000, ETH_3000, false, 1);
    }

    // =========================================================================
    // Collateral Ratio Tests
    // =========================================================================

    function test_computeCollateralRatio_exactlyCollateralized() public pure {
        // Put: collateral = 3000, strike = 3000, amount = 1 -> ratio = 1.0
        SD59x18 ratio = Certoraspec.computeCollateralRatio(COLLATERAL_3000, ETH_3000, false, 1);
        assertEq(SD59x18.unwrap(ratio), 1e18, "Exactly collateralized ratio should be 1.0");
    }

    function test_computeCollateralRatio_overCollateralized() public pure {
        // Call: collateral = 10, amount = 5 -> ratio = 2.0
        SD59x18 ratio = Certoraspec.computeCollateralRatio(TEN, ETH_3000, true, 5);
        assertEq(SD59x18.unwrap(ratio), 2e18, "Over-collateralized ratio should be 2.0");
    }

    function test_computeCollateralRatio_revertsOnZeroAmount() public {
        vm.expectRevert(Certoraspec.Certoraspec__ZeroAmount.selector);
        wrapper.computeCollateralRatio(COLLATERAL_3000, ETH_3000, false, 0);
    }

    function test_validateCollateralRatio_valid() public pure {
        SD59x18 ratio = sd(1.5e18);
        assertTrue(Certoraspec.validateCollateralRatio(ratio), "1.5x ratio should be valid");
    }

    function test_validateCollateralRatio_undercollateralized() public pure {
        SD59x18 ratio = sd(0.5e18);
        assertFalse(Certoraspec.validateCollateralRatio(ratio), "0.5x ratio should be invalid");
    }

    // =========================================================================
    // Position Tracking Tests
    // =========================================================================

    function test_recordMint_updatesCorrectly() public pure {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: ZERO, collateralLocked: ZERO, amountMinted: 0, amountExercised: 0
        });

        Certoraspec.MintPosition memory updated = Certoraspec.recordMint(pos, PREMIUM_50, COLLATERAL_3000, 1);

        assertEq(SD59x18.unwrap(updated.premiumPaid), 50e18, "Premium should be 50");
        assertEq(SD59x18.unwrap(updated.collateralLocked), 3000e18, "Collateral should be 3000");
        assertEq(updated.amountMinted, 1, "Minted should be 1");
        assertEq(updated.amountExercised, 0, "Exercised should remain 0");
    }

    function test_recordMint_accumulates() public pure {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: PREMIUM_50, collateralLocked: COLLATERAL_3000, amountMinted: 1, amountExercised: 0
        });

        Certoraspec.MintPosition memory updated = Certoraspec.recordMint(pos, PREMIUM_100, COLLATERAL_3000, 2);

        assertEq(SD59x18.unwrap(updated.premiumPaid), 150e18, "Accumulated premium should be 150");
        assertEq(updated.amountMinted, 3, "Accumulated mint should be 3");
    }

    function test_recordMint_revertsOnZeroAmount() public {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: ZERO, collateralLocked: ZERO, amountMinted: 0, amountExercised: 0
        });

        vm.expectRevert(Certoraspec.Certoraspec__ZeroAmount.selector);
        wrapper.recordMint(pos, PREMIUM_50, COLLATERAL_3000, 0);
    }

    function test_recordMint_revertsOnZeroPremium() public {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: ZERO, collateralLocked: ZERO, amountMinted: 0, amountExercised: 0
        });

        vm.expectRevert(Certoraspec.Certoraspec__ZeroPremium.selector);
        wrapper.recordMint(pos, ZERO, COLLATERAL_3000, 1);
    }

    function test_recordExercise_updatesCorrectly() public pure {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: PREMIUM_50, collateralLocked: COLLATERAL_3000, amountMinted: 5, amountExercised: 0
        });

        Certoraspec.MintPosition memory updated = Certoraspec.recordExercise(pos, 3);

        assertEq(updated.amountExercised, 3, "Exercised should be 3");
        assertEq(updated.amountMinted, 5, "Minted should remain 5");
    }

    function test_recordExercise_revertsOnExcess() public {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: PREMIUM_50, collateralLocked: COLLATERAL_3000, amountMinted: 1, amountExercised: 0
        });

        vm.expectRevert(abi.encodeWithSelector(Certoraspec.Certoraspec__ExerciseExceedsMinted.selector, 2, 1));
        wrapper.recordExercise(pos, 2);
    }

    function test_remainingExercisable() public pure {
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: PREMIUM_50, collateralLocked: COLLATERAL_3000, amountMinted: 10, amountExercised: 3
        });

        uint256 remaining = Certoraspec.remainingExercisable(pos);
        assertEq(remaining, 7, "Remaining exercisable should be 7");
    }

    // =========================================================================
    // Net Value Tests
    // =========================================================================

    function test_computeNetValue_profit() public pure {
        // Payout > premium -> positive net value
        SD59x18 net = Certoraspec.computeNetValue(PREMIUM_100, PREMIUM_50);
        assertEq(SD59x18.unwrap(net), 50e18, "Net value should be +50");
    }

    function test_computeNetValue_loss() public pure {
        // Payout < premium -> negative net value
        SD59x18 net = Certoraspec.computeNetValue(PREMIUM_50, PREMIUM_100);
        assertEq(SD59x18.unwrap(net), -50e18, "Net value should be -50");
    }

    function test_computeNetValue_breakeven() public pure {
        // Payout == premium -> zero net value
        SD59x18 net = Certoraspec.computeNetValue(PREMIUM_50, PREMIUM_50);
        assertEq(SD59x18.unwrap(net), 0, "Net value should be 0 at breakeven");
    }

    function test_isNetExtractionBounded_valid() public pure {
        // payout (100) <= intrinsic (100), premium (50) > 0
        bool bounded = Certoraspec.isNetExtractionBounded(PREMIUM_100, PREMIUM_50, PREMIUM_100);
        assertTrue(bounded, "Should be bounded when payout <= intrinsic and premium > 0");
    }

    function test_isNetExtractionBounded_zeroPremium() public pure {
        // premium = 0 violates invariant
        bool bounded = Certoraspec.isNetExtractionBounded(PREMIUM_100, ZERO, PREMIUM_100);
        assertFalse(bounded, "Should not be bounded when premium is 0");
    }

    function test_computeMaxProfit_ITM() public pure {
        // ITM call: intrinsic = 100, premium = 50 -> max profit = 50
        SD59x18 maxProfit = Certoraspec.computeMaxProfit(ETH_3100, ETH_3000, true, 1, PREMIUM_50);
        assertEq(SD59x18.unwrap(maxProfit), 50e18, "Max profit should be 50");
    }

    function test_computeMaxProfit_OTM() public pure {
        // OTM call: intrinsic = 0, premium = 50 -> max profit = -50
        SD59x18 maxProfit = Certoraspec.computeMaxProfit(ETH_2900, ETH_3000, true, 1, PREMIUM_50);
        assertEq(SD59x18.unwrap(maxProfit), -50e18, "Max profit for OTM should be -50 (loss)");
    }
}
