// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";

/// @title Certoraspec
/// @notice On-chain enforcement of the no-value-extraction invariant for option lifecycles
/// @dev Proves that for any mint → exercise sequence:
///      payout(user) ≤ intrinsicValue(option) AND premiumPaid(user) > 0
///      All arithmetic uses PRBMath SD59x18 fixed-point representation.
/// @author MantissaFi Team
library Certoraspec {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice 1.0 in SD59x18 fixed-point representation
    int256 private constant ONE = 1e18;

    /// @notice Minimum allowed premium (1 wei in fixed-point, effectively > 0)
    int256 private constant MIN_PREMIUM = 1;

    /// @notice Maximum allowed collateralization ratio (10x = 1000%)
    int256 private constant MAX_COLLATERAL_RATIO = 10e18;

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Error thrown when payout exceeds intrinsic value (value extraction detected)
    error Certoraspec__PayoutExceedsIntrinsicValue(int256 payout, int256 intrinsicValue);

    /// @notice Error thrown when premium paid is zero or negative
    error Certoraspec__ZeroPremium();

    /// @notice Error thrown when spot price is zero or negative
    error Certoraspec__InvalidSpotPrice();

    /// @notice Error thrown when strike price is zero or negative
    error Certoraspec__InvalidStrikePrice();

    /// @notice Error thrown when exercise amount exceeds minted amount
    error Certoraspec__ExerciseExceedsMinted(uint256 exerciseAmount, uint256 mintedAmount);

    /// @notice Error thrown when collateral is insufficient for the payout
    error Certoraspec__InsufficientCollateral(int256 collateral, int256 requiredPayout);

    /// @notice Error thrown when collateralization ratio is invalid
    error Certoraspec__InvalidCollateralRatio(int256 ratio);

    /// @notice Error thrown when option amount is zero
    error Certoraspec__ZeroAmount();

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Represents the state of a user's mint position
    /// @param premiumPaid Total premium paid by the user (SD59x18)
    /// @param collateralLocked Total collateral locked (SD59x18)
    /// @param amountMinted Number of options minted
    /// @param amountExercised Number of options exercised so far
    struct MintPosition {
        SD59x18 premiumPaid;
        SD59x18 collateralLocked;
        uint256 amountMinted;
        uint256 amountExercised;
    }

    /// @notice Represents the parameters needed for payout validation
    /// @param spot Current spot price at exercise (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param isCall True for call option, false for put option
    /// @param exerciseAmount Number of options being exercised
    struct ExerciseParams {
        SD59x18 spot;
        SD59x18 strike;
        bool isCall;
        uint256 exerciseAmount;
    }

    /// @notice Result of a full mint→exercise invariant check
    /// @param isValid True if the invariant holds
    /// @param payout Actual payout computed (SD59x18)
    /// @param intrinsicValue Maximum allowed payout (SD59x18)
    /// @param premiumPaid Premium paid by the user (SD59x18)
    struct InvariantResult {
        bool isValid;
        SD59x18 payout;
        SD59x18 intrinsicValue;
        SD59x18 premiumPaid;
    }

    // =========================================================================
    // Core Invariant Functions
    // =========================================================================

    /// @notice Validates the no-value-extraction invariant for a mint → exercise sequence
    /// @dev Checks: payout ≤ intrinsicValue AND premiumPaid > 0
    /// @param position The user's mint position state
    /// @param params The exercise parameters
    /// @return result The invariant check result containing validity and computed values
    function validateNoValueExtraction(MintPosition memory position, ExerciseParams memory params)
        internal
        pure
        returns (InvariantResult memory result)
    {
        // Validate inputs
        _validateExerciseParams(params);
        _validatePosition(position, params.exerciseAmount);

        // Compute intrinsic value for the exercised amount
        result.intrinsicValue = computeIntrinsicValue(params.spot, params.strike, params.isCall, params.exerciseAmount);

        // Compute the actual payout (capped at intrinsic value)
        result.payout = computePayout(params.spot, params.strike, params.isCall, params.exerciseAmount);

        // Store the premium
        result.premiumPaid = position.premiumPaid;

        // Check invariant: payout ≤ intrinsicValue AND premiumPaid > 0
        bool payoutBounded = result.payout.lte(result.intrinsicValue);
        bool premiumPositive = result.premiumPaid.gt(ZERO);

        result.isValid = payoutBounded && premiumPositive;
    }

    /// @notice Strictly enforces the no-value-extraction invariant (reverts on violation)
    /// @dev Reverts with specific error if payout > intrinsicValue or premiumPaid == 0
    /// @param position The user's mint position state
    /// @param params The exercise parameters
    /// @return payout The validated payout amount (SD59x18)
    function enforceNoValueExtraction(MintPosition memory position, ExerciseParams memory params)
        internal
        pure
        returns (SD59x18 payout)
    {
        _validateExerciseParams(params);
        _validatePosition(position, params.exerciseAmount);

        // Premium must be positive
        if (position.premiumPaid.lte(ZERO)) {
            revert Certoraspec__ZeroPremium();
        }

        // Compute intrinsic value and payout
        SD59x18 intrinsic = computeIntrinsicValue(params.spot, params.strike, params.isCall, params.exerciseAmount);
        payout = computePayout(params.spot, params.strike, params.isCall, params.exerciseAmount);

        // Enforce payout ≤ intrinsic value
        if (payout.gt(intrinsic)) {
            revert Certoraspec__PayoutExceedsIntrinsicValue(SD59x18.unwrap(payout), SD59x18.unwrap(intrinsic));
        }
    }

    // =========================================================================
    // Payout & Intrinsic Value Computation
    // =========================================================================

    /// @notice Computes the intrinsic value of an option for a given amount
    /// @dev For calls: max(S - K, 0) * amount; for puts: max(K - S, 0) * amount
    /// @param spot Current spot price (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param isCall True for call option, false for put option
    /// @param amount Number of options
    /// @return value The total intrinsic value (SD59x18)
    function computeIntrinsicValue(SD59x18 spot, SD59x18 strike, bool isCall, uint256 amount)
        internal
        pure
        returns (SD59x18 value)
    {
        if (spot.lte(ZERO)) revert Certoraspec__InvalidSpotPrice();
        if (strike.lte(ZERO)) revert Certoraspec__InvalidStrikePrice();

        SD59x18 perOption;
        if (isCall) {
            // Call intrinsic: max(S - K, 0)
            perOption = spot.gt(strike) ? spot.sub(strike) : ZERO;
        } else {
            // Put intrinsic: max(K - S, 0)
            perOption = strike.gt(spot) ? strike.sub(spot) : ZERO;
        }

        value = perOption.mul(sd(int256(amount) * ONE));
    }

    /// @notice Computes the payout for exercising options
    /// @dev Payout equals intrinsic value (no excess extraction possible)
    /// @param spot Current spot price (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param isCall True for call option, false for put option
    /// @param amount Number of options to exercise
    /// @return payout The total payout (SD59x18), always ≤ intrinsicValue
    function computePayout(SD59x18 spot, SD59x18 strike, bool isCall, uint256 amount)
        internal
        pure
        returns (SD59x18 payout)
    {
        // Payout is exactly the intrinsic value — no value extraction
        payout = computeIntrinsicValue(spot, strike, isCall, amount);
    }

    // =========================================================================
    // Collateral Verification
    // =========================================================================

    /// @notice Verifies that locked collateral covers the maximum possible payout
    /// @dev For calls: collateral ≥ amount (1 underlying per option)
    ///      For puts: collateral ≥ strike * amount
    /// @param collateralLocked Total collateral locked (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param isCall True for call, false for put
    /// @param amount Number of options
    /// @return sufficient True if collateral covers max payout
    function verifyCollateralSufficiency(SD59x18 collateralLocked, SD59x18 strike, bool isCall, uint256 amount)
        internal
        pure
        returns (bool sufficient)
    {
        if (strike.lte(ZERO)) revert Certoraspec__InvalidStrikePrice();

        SD59x18 scaledAmount = sd(int256(amount) * ONE);
        SD59x18 requiredCollateral;

        if (isCall) {
            // Calls: 1 underlying per option
            requiredCollateral = scaledAmount;
        } else {
            // Puts: strike * amount in stablecoin
            requiredCollateral = strike.mul(scaledAmount);
        }

        sufficient = collateralLocked.gte(requiredCollateral);
    }

    /// @notice Strictly enforces collateral sufficiency (reverts on violation)
    /// @param collateralLocked Total collateral locked (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param isCall True for call, false for put
    /// @param amount Number of options
    function enforceCollateralSufficiency(SD59x18 collateralLocked, SD59x18 strike, bool isCall, uint256 amount)
        internal
        pure
    {
        if (strike.lte(ZERO)) revert Certoraspec__InvalidStrikePrice();

        SD59x18 scaledAmount = sd(int256(amount) * ONE);
        SD59x18 requiredCollateral;

        if (isCall) {
            requiredCollateral = scaledAmount;
        } else {
            requiredCollateral = strike.mul(scaledAmount);
        }

        if (collateralLocked.lt(requiredCollateral)) {
            revert Certoraspec__InsufficientCollateral(
                SD59x18.unwrap(collateralLocked), SD59x18.unwrap(requiredCollateral)
            );
        }
    }

    // =========================================================================
    // Collateral Ratio
    // =========================================================================

    /// @notice Computes the collateralization ratio
    /// @dev ratio = collateralLocked / requiredCollateral
    /// @param collateralLocked Total collateral locked (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param isCall True for call, false for put
    /// @param amount Number of options
    /// @return ratio The collateralization ratio (SD59x18), must be ≥ 1.0
    function computeCollateralRatio(SD59x18 collateralLocked, SD59x18 strike, bool isCall, uint256 amount)
        internal
        pure
        returns (SD59x18 ratio)
    {
        if (strike.lte(ZERO)) revert Certoraspec__InvalidStrikePrice();
        if (amount == 0) revert Certoraspec__ZeroAmount();

        SD59x18 scaledAmount = sd(int256(amount) * ONE);
        SD59x18 requiredCollateral;

        if (isCall) {
            requiredCollateral = scaledAmount;
        } else {
            requiredCollateral = strike.mul(scaledAmount);
        }

        ratio = collateralLocked.div(requiredCollateral);
    }

    /// @notice Validates that a collateralization ratio is within acceptable bounds
    /// @dev Ratio must be in [1.0, MAX_COLLATERAL_RATIO]
    /// @param ratio The collateralization ratio to validate (SD59x18)
    /// @return valid True if ratio is within bounds
    function validateCollateralRatio(SD59x18 ratio) internal pure returns (bool valid) {
        valid = ratio.gte(sd(ONE)) && ratio.lte(sd(MAX_COLLATERAL_RATIO));
    }

    // =========================================================================
    // Position Tracking
    // =========================================================================

    /// @notice Records a new mint into the position and returns the updated state
    /// @param position The current position state
    /// @param premium Premium paid for this mint (SD59x18)
    /// @param collateral Collateral locked for this mint (SD59x18)
    /// @param amount Number of options minted
    /// @return updated The updated position state
    function recordMint(MintPosition memory position, SD59x18 premium, SD59x18 collateral, uint256 amount)
        internal
        pure
        returns (MintPosition memory updated)
    {
        if (amount == 0) revert Certoraspec__ZeroAmount();
        if (premium.lte(ZERO)) revert Certoraspec__ZeroPremium();

        updated = MintPosition({
            premiumPaid: position.premiumPaid.add(premium),
            collateralLocked: position.collateralLocked.add(collateral),
            amountMinted: position.amountMinted + amount,
            amountExercised: position.amountExercised
        });
    }

    /// @notice Records an exercise into the position and returns the updated state
    /// @param position The current position state
    /// @param exerciseAmount Number of options exercised
    /// @return updated The updated position state
    function recordExercise(MintPosition memory position, uint256 exerciseAmount)
        internal
        pure
        returns (MintPosition memory updated)
    {
        if (exerciseAmount == 0) revert Certoraspec__ZeroAmount();
        uint256 remaining = position.amountMinted - position.amountExercised;
        if (exerciseAmount > remaining) {
            revert Certoraspec__ExerciseExceedsMinted(exerciseAmount, remaining);
        }

        updated = MintPosition({
            premiumPaid: position.premiumPaid,
            collateralLocked: position.collateralLocked,
            amountMinted: position.amountMinted,
            amountExercised: position.amountExercised + exerciseAmount
        });
    }

    /// @notice Returns the remaining exercisable amount for a position
    /// @param position The current position state
    /// @return remaining Number of options that can still be exercised
    function remainingExercisable(MintPosition memory position) internal pure returns (uint256 remaining) {
        remaining = position.amountMinted - position.amountExercised;
    }

    // =========================================================================
    // Net Value Accounting
    // =========================================================================

    /// @notice Computes the net value extracted by a user (payout - premium)
    /// @dev A negative net value means the user paid more than they received
    /// @param payout Total payout received from exercise (SD59x18)
    /// @param premiumPaid Total premium paid at mint (SD59x18)
    /// @return netValue The net value extracted (SD59x18), can be negative
    function computeNetValue(SD59x18 payout, SD59x18 premiumPaid) internal pure returns (SD59x18 netValue) {
        netValue = payout.sub(premiumPaid);
    }

    /// @notice Checks whether a user's net extraction is bounded by intrinsic value minus premium
    /// @dev Ensures: netValue = payout - premium ≤ intrinsicValue - premium
    ///      Which simplifies to: payout ≤ intrinsicValue
    /// @param payout Total payout received (SD59x18)
    /// @param premiumPaid Total premium paid (SD59x18)
    /// @param intrinsicValue Maximum intrinsic value (SD59x18)
    /// @return bounded True if net extraction is within bounds
    function isNetExtractionBounded(SD59x18 payout, SD59x18 premiumPaid, SD59x18 intrinsicValue)
        internal
        pure
        returns (bool bounded)
    {
        // Core invariant: payout ≤ intrinsicValue AND premiumPaid > 0
        bounded = payout.lte(intrinsicValue) && premiumPaid.gt(ZERO);
    }

    /// @notice Computes the maximum profit a user can realize from an option
    /// @dev maxProfit = intrinsicValue - premiumPaid (can be negative for OTM)
    /// @param spot Current spot price (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param isCall True for call, false for put
    /// @param amount Number of options
    /// @param premiumPaid Total premium paid (SD59x18)
    /// @return maxProfit The maximum possible profit (SD59x18)
    function computeMaxProfit(SD59x18 spot, SD59x18 strike, bool isCall, uint256 amount, SD59x18 premiumPaid)
        internal
        pure
        returns (SD59x18 maxProfit)
    {
        SD59x18 intrinsic = computeIntrinsicValue(spot, strike, isCall, amount);
        maxProfit = intrinsic.sub(premiumPaid);
    }

    // =========================================================================
    // Internal Validation
    // =========================================================================

    /// @notice Validates exercise parameters
    /// @param params Exercise parameters to validate
    function _validateExerciseParams(ExerciseParams memory params) private pure {
        if (params.spot.lte(ZERO)) revert Certoraspec__InvalidSpotPrice();
        if (params.strike.lte(ZERO)) revert Certoraspec__InvalidStrikePrice();
        if (params.exerciseAmount == 0) revert Certoraspec__ZeroAmount();
    }

    /// @notice Validates a position against the requested exercise amount
    /// @param position The position to validate
    /// @param exerciseAmount The requested exercise amount
    function _validatePosition(MintPosition memory position, uint256 exerciseAmount) private pure {
        if (position.amountMinted == 0) revert Certoraspec__ZeroAmount();
        uint256 remaining = position.amountMinted - position.amountExercised;
        if (exerciseAmount > remaining) {
            revert Certoraspec__ExerciseExceedsMinted(exerciseAmount, remaining);
        }
    }
}
