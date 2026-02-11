// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { Certoraspec } from "../../src/libraries/Certoraspec.sol";

/// @title CertoraspecFuzzTest
/// @notice Fuzz tests for Certoraspec library invariants
/// @dev Tests the no-value-extraction invariant across random inputs
contract CertoraspecFuzzTest is Test {
    // Bounds for realistic option prices (in whole units)
    uint256 internal constant MIN_PRICE = 1; // $1
    uint256 internal constant MAX_PRICE = 1_000_000; // $1M
    uint256 internal constant MIN_AMOUNT = 1;
    uint256 internal constant MAX_AMOUNT = 10_000;
    uint256 internal constant MIN_PREMIUM = 1; // $1
    uint256 internal constant MAX_PREMIUM = 100_000; // $100K

    // =========================================================================
    // Core Invariant: payout ≤ intrinsicValue
    // =========================================================================

    /// @notice Payout never exceeds intrinsic value for calls
    function testFuzz_payoutBoundedByIntrinsic_call(uint256 spotRaw, uint256 strikeRaw, uint256 amount) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 payout = Certoraspec.computePayout(spot, strike, true, amount);
        SD59x18 intrinsic = Certoraspec.computeIntrinsicValue(spot, strike, true, amount);

        assertLe(SD59x18.unwrap(payout), SD59x18.unwrap(intrinsic), "Call payout must never exceed intrinsic value");
    }

    /// @notice Payout never exceeds intrinsic value for puts
    function testFuzz_payoutBoundedByIntrinsic_put(uint256 spotRaw, uint256 strikeRaw, uint256 amount) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 payout = Certoraspec.computePayout(spot, strike, false, amount);
        SD59x18 intrinsic = Certoraspec.computeIntrinsicValue(spot, strike, false, amount);

        assertLe(SD59x18.unwrap(payout), SD59x18.unwrap(intrinsic), "Put payout must never exceed intrinsic value");
    }

    // =========================================================================
    // Core Invariant: full mint→exercise validation
    // =========================================================================

    /// @notice Full mint→exercise invariant holds for any valid position
    function testFuzz_validateNoValueExtraction_alwaysHoldsWithPremium(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 premiumRaw,
        uint256 amount,
        bool isCall
    ) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        premiumRaw = bound(premiumRaw, MIN_PREMIUM, MAX_PREMIUM);
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));
        SD59x18 premium = sd(int256(premiumRaw * 1e18));

        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: premium,
            collateralLocked: sd(int256(strikeRaw * amount * 1e18)),
            amountMinted: amount,
            amountExercised: 0
        });

        Certoraspec.ExerciseParams memory params =
            Certoraspec.ExerciseParams({ spot: spot, strike: strike, isCall: isCall, exerciseAmount: amount });

        Certoraspec.InvariantResult memory result = Certoraspec.validateNoValueExtraction(pos, params);

        assertTrue(result.isValid, "Invariant must hold when premium > 0 and payout <= intrinsic");
    }

    /// @notice Invariant always fails with zero premium
    function testFuzz_validateNoValueExtraction_failsWithZeroPremium(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 amount,
        bool isCall
    ) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: ZERO,
            collateralLocked: sd(int256(strikeRaw * amount * 1e18)),
            amountMinted: amount,
            amountExercised: 0
        });

        Certoraspec.ExerciseParams memory params =
            Certoraspec.ExerciseParams({ spot: spot, strike: strike, isCall: isCall, exerciseAmount: amount });

        Certoraspec.InvariantResult memory result = Certoraspec.validateNoValueExtraction(pos, params);

        assertFalse(result.isValid, "Invariant must fail when premium is zero");
    }

    // =========================================================================
    // Payout Non-negativity
    // =========================================================================

    /// @notice Payout is always >= 0
    function testFuzz_payout_neverNegative(uint256 spotRaw, uint256 strikeRaw, uint256 amount, bool isCall)
        public
        pure
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 payout = Certoraspec.computePayout(spot, strike, isCall, amount);
        assertGe(SD59x18.unwrap(payout), 0, "Payout must never be negative");
    }

    // =========================================================================
    // Intrinsic Value Properties
    // =========================================================================

    /// @notice Intrinsic value scales linearly with amount
    function testFuzz_intrinsicValue_linearScaling(uint256 spotRaw, uint256 strikeRaw, uint256 amount, bool isCall)
        public
        pure
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        amount = bound(amount, 2, 100);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 valueSingle = Certoraspec.computeIntrinsicValue(spot, strike, isCall, 1);
        SD59x18 valueMultiple = Certoraspec.computeIntrinsicValue(spot, strike, isCall, amount);

        // valueMultiple should equal valueSingle * amount
        int256 expected = SD59x18.unwrap(valueSingle) * int256(amount);
        assertEq(SD59x18.unwrap(valueMultiple), expected, "Intrinsic value must scale linearly");
    }

    /// @notice Call and put intrinsic values are mutually exclusive
    function testFuzz_intrinsicValue_mutuallyExclusive(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 callValue = Certoraspec.computeIntrinsicValue(spot, strike, true, 1);
        SD59x18 putValue = Certoraspec.computeIntrinsicValue(spot, strike, false, 1);

        bool callPositive = SD59x18.unwrap(callValue) > 0;
        bool putPositive = SD59x18.unwrap(putValue) > 0;

        assertFalse(callPositive && putPositive, "Call and put cannot both have positive intrinsic value");
    }

    // =========================================================================
    // Collateral Sufficiency Properties
    // =========================================================================

    /// @notice Over-collateralized positions always pass sufficiency check
    function testFuzz_collateral_overCollateralizedAlwaysSufficient(
        uint256 strikeRaw,
        uint256 amount,
        uint256 extraRaw,
        bool isCall
    ) public pure {
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        amount = bound(amount, MIN_AMOUNT, 100);
        extraRaw = bound(extraRaw, 0, MAX_PRICE);

        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        // Compute exact required collateral, then add extra
        SD59x18 scaledAmount = sd(int256(amount) * 1e18);
        SD59x18 required;
        if (isCall) {
            required = scaledAmount;
        } else {
            required = strike.mul(scaledAmount);
        }
        SD59x18 collateral = required.add(sd(int256(extraRaw * 1e18)));

        bool sufficient = Certoraspec.verifyCollateralSufficiency(collateral, strike, isCall, amount);
        assertTrue(sufficient, "Over-collateralized positions must always be sufficient");
    }

    // =========================================================================
    // Collateral Ratio Properties
    // =========================================================================

    /// @notice Collateral ratio is always >= 1.0 when exactly collateralized
    function testFuzz_collateralRatio_atLeastOneWhenExact(uint256 strikeRaw, uint256 amount, bool isCall) public pure {
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        amount = bound(amount, MIN_AMOUNT, 100);

        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        // Compute exact required collateral
        SD59x18 scaledAmount = sd(int256(amount) * 1e18);
        SD59x18 required;
        if (isCall) {
            required = scaledAmount;
        } else {
            required = strike.mul(scaledAmount);
        }

        SD59x18 ratio = Certoraspec.computeCollateralRatio(required, strike, isCall, amount);
        assertGe(SD59x18.unwrap(ratio), 1e18, "Exact collateralization ratio must be >= 1.0");
    }

    // =========================================================================
    // Position Tracking Invariants
    // =========================================================================

    /// @notice Exercised amount never exceeds minted amount through any sequence
    function testFuzz_position_exercisedNeverExceedsMinted(
        uint256 premiumRaw,
        uint256 collateralRaw,
        uint256 mintAmount,
        uint256 exerciseAmount
    ) public pure {
        premiumRaw = bound(premiumRaw, MIN_PREMIUM, MAX_PREMIUM);
        collateralRaw = bound(collateralRaw, MIN_PRICE, MAX_PRICE);
        mintAmount = bound(mintAmount, 1, MAX_AMOUNT);

        SD59x18 premium = sd(int256(premiumRaw * 1e18));
        SD59x18 collateral = sd(int256(collateralRaw * 1e18));

        // Start with empty position, mint, then exercise
        Certoraspec.MintPosition memory pos = Certoraspec.MintPosition({
            premiumPaid: ZERO, collateralLocked: ZERO, amountMinted: 0, amountExercised: 0
        });

        pos = Certoraspec.recordMint(pos, premium, collateral, mintAmount);

        // Bound exercise to valid range
        exerciseAmount = bound(exerciseAmount, 1, mintAmount);
        pos = Certoraspec.recordExercise(pos, exerciseAmount);

        assertLe(pos.amountExercised, pos.amountMinted, "Exercised must never exceed minted");
        assertEq(
            Certoraspec.remainingExercisable(pos),
            mintAmount - exerciseAmount,
            "Remaining must equal minted - exercised"
        );
    }

    /// @notice Net value extraction check is consistent with invariant validation
    function testFuzz_netExtraction_consistentWithInvariant(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 premiumRaw,
        bool isCall
    ) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        premiumRaw = bound(premiumRaw, MIN_PREMIUM, MAX_PREMIUM);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));
        SD59x18 premium = sd(int256(premiumRaw * 1e18));

        SD59x18 payout = Certoraspec.computePayout(spot, strike, isCall, 1);
        SD59x18 intrinsic = Certoraspec.computeIntrinsicValue(spot, strike, isCall, 1);

        bool bounded = Certoraspec.isNetExtractionBounded(payout, premium, intrinsic);

        // Since payout always equals intrinsic and premium > 0, should always be bounded
        assertTrue(bounded, "With positive premium and valid payout, extraction must be bounded");
    }

    /// @notice Max profit equals intrinsic minus premium
    function testFuzz_maxProfit_equalsIntrinsicMinusPremium(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 premiumRaw,
        bool isCall
    ) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        premiumRaw = bound(premiumRaw, MIN_PREMIUM, MAX_PREMIUM);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));
        SD59x18 premium = sd(int256(premiumRaw * 1e18));

        SD59x18 maxProfit = Certoraspec.computeMaxProfit(spot, strike, isCall, 1, premium);
        SD59x18 intrinsic = Certoraspec.computeIntrinsicValue(spot, strike, isCall, 1);

        int256 expected = SD59x18.unwrap(intrinsic) - SD59x18.unwrap(premium);
        assertEq(SD59x18.unwrap(maxProfit), expected, "Max profit must equal intrinsic - premium");
    }
}
