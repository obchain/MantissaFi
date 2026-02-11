// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { SkewModel } from "../../src/libraries/SkewModel.sol";

/// @title SkewModelFuzzHarness
/// @notice Harness contract to expose internal library functions for fuzz testing
contract SkewModelFuzzHarness {
    function calculateSkew(SD59x18 strike, SD59x18 spot, SkewModel.SkewParams memory params)
        external
        pure
        returns (SD59x18)
    {
        return SkewModel.calculateSkew(strike, spot, params);
    }

    function applySkew(SD59x18 baseIV, SD59x18 strike, SD59x18 spot, SkewModel.SkewParams memory params)
        external
        pure
        returns (SD59x18)
    {
        return SkewModel.applySkew(baseIV, strike, spot, params);
    }

    function calculateMoneyness(SD59x18 strike, SD59x18 spot) external pure returns (SD59x18) {
        return SkewModel.calculateMoneyness(strike, spot);
    }

    function validateParams(SkewModel.SkewParams memory params) external pure {
        SkewModel.validateParams(params);
    }

    function createParams(int256 alpha, int256 beta) external pure returns (SkewModel.SkewParams memory) {
        return SkewModel.createParams(alpha, beta);
    }

    function maxSkew() external pure returns (SD59x18) {
        return SkewModel.maxSkew();
    }

    function minSkew() external pure returns (SD59x18) {
        return SkewModel.minSkew();
    }
}

/// @title SkewModelFuzzTest
/// @notice Fuzz tests for the SkewModel library invariants
contract SkewModelFuzzTest is Test {
    SkewModelFuzzHarness harness;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    int256 constant ONE = 1e18;
    int256 constant MAX_SKEW = 1e18;
    int256 constant MIN_SKEW = -5e17;
    int256 constant MAX_ALPHA = 10e18;
    int256 constant MAX_BETA = 5e18;
    int256 constant MIN_BETA = -5e18;

    // Reasonable bounds for prices to avoid PRBMath overflow
    // Strike/Spot ratio should be within [0.01, 100] to prevent overflow
    // Using 1e16 to 1e22 as price range (0.01 to 10000 in 18 decimals)
    int256 constant MIN_PRICE = 1e16;
    int256 constant MAX_PRICE = 1e22;

    // ═══════════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════════

    function setUp() public {
        harness = new SkewModelFuzzHarness();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Helper to create valid SkewParams within bounds
    function _boundParams(int256 alpha, int256 beta) internal pure returns (SkewModel.SkewParams memory) {
        // Bound alpha to [0, MAX_ALPHA]
        alpha = bound(alpha, 0, MAX_ALPHA);
        // Bound beta to [MIN_BETA, MAX_BETA]
        beta = bound(beta, MIN_BETA, MAX_BETA);

        return SkewModel.SkewParams({ alpha: sd(alpha), beta: sd(beta) });
    }

    /// @notice Helper to bound prices to valid positive range with reasonable ratio
    function _boundPrice(int256 price) internal pure returns (int256) {
        return bound(price, MIN_PRICE, MAX_PRICE);
    }

    /// @notice Helper to bound strike and spot to ensure reasonable moneyness ratio
    /// @dev Ensures K/S is within [0.1, 10] to prevent overflow
    function _boundPricesWithRatio(int256 strike, int256 spot) internal pure returns (int256, int256) {
        // First bound spot
        spot = bound(spot, 1e17, 1e21);

        // Bound strike relative to spot: K/S between 0.1 and 10
        int256 minStrike = spot / 10; // 0.1 * spot
        int256 maxStrike = spot * 10; // 10 * spot

        strike = bound(strike, minStrike, maxStrike);

        return (strike, spot);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: Skew is always bounded between MIN_SKEW and MAX_SKEW
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: skew is always within bounds for any valid inputs
    function testFuzz_SkewAlwaysBounded(int256 strike, int256 spot, int256 alpha, int256 beta) public view {
        // Bound inputs to valid ranges with reasonable ratio
        (strike, spot) = _boundPricesWithRatio(strike, spot);
        SkewModel.SkewParams memory params = _boundParams(alpha, beta);

        SD59x18 skew = harness.calculateSkew(sd(strike), sd(spot), params);

        // Invariant: skew must be within [MIN_SKEW, MAX_SKEW]
        assertTrue(skew.gte(sd(MIN_SKEW)), "Skew below minimum");
        assertTrue(skew.lte(sd(MAX_SKEW)), "Skew above maximum");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: At-the-money (K = S) skew is always zero
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: when strike equals spot, skew is zero
    function testFuzz_AtTheMoneySkewIsZero(int256 price, int256 alpha, int256 beta) public view {
        // Use same price for both strike and spot
        price = _boundPrice(price);
        SkewModel.SkewParams memory params = _boundParams(alpha, beta);

        SD59x18 skew = harness.calculateSkew(sd(price), sd(price), params);

        // Invariant: at-the-money skew = 0
        assertEq(skew.unwrap(), 0, "ATM skew should be zero");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: Adjusted IV is non-negative
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: adjusted IV is never negative
    function testFuzz_AdjustedIVNonNegative(int256 baseIV, int256 strike, int256 spot, int256 alpha, int256 beta)
        public
        view
    {
        // Bound inputs
        baseIV = bound(baseIV, 0, 10e18); // IV between 0% and 1000%
        (strike, spot) = _boundPricesWithRatio(strike, spot);
        SkewModel.SkewParams memory params = _boundParams(alpha, beta);

        SD59x18 adjustedIV = harness.applySkew(sd(baseIV), sd(strike), sd(spot), params);

        // Invariant: adjusted IV >= 0
        assertTrue(adjustedIV.gte(ZERO), "Adjusted IV must be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: Skew formula correctness
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: skew formula produces expected mathematical result
    function testFuzz_SkewFormulaCorrectness(int256 strike, int256 spot, int256 alpha, int256 beta) public view {
        // Use moderate values to avoid overflow in manual calculation
        spot = bound(spot, 1e17, 1e21);
        strike = bound(strike, spot / 5, spot * 5); // K/S in [0.2, 5]
        alpha = bound(alpha, 0, 5e18); // Keep alpha smaller to avoid overflow
        beta = bound(beta, -3e18, 3e18);

        SkewModel.SkewParams memory params = SkewModel.SkewParams({ alpha: sd(alpha), beta: sd(beta) });

        SD59x18 skew = harness.calculateSkew(sd(strike), sd(spot), params);

        // Calculate expected skew manually: α · (K/S - 1)² + β · (K/S - 1)
        SD59x18 strikeSD = sd(strike);
        SD59x18 spotSD = sd(spot);
        SD59x18 moneyness = strikeSD.div(spotSD).sub(sd(ONE));
        SD59x18 moneynessSquared = moneyness.mul(moneyness);

        SD59x18 expectedSkew = sd(alpha).mul(moneynessSquared).add(sd(beta).mul(moneyness));

        // Bound expected value
        if (expectedSkew.gt(sd(MAX_SKEW))) {
            expectedSkew = sd(MAX_SKEW);
        }
        if (expectedSkew.lt(sd(MIN_SKEW))) {
            expectedSkew = sd(MIN_SKEW);
        }

        // Allow small tolerance for fixed-point arithmetic
        assertApproxEqAbs(skew.unwrap(), expectedSkew.unwrap(), 1e10, "Skew formula mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: Symmetric smile with zero beta
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: with beta=0, skew is non-negative (pure smile effect)
    function testFuzz_SymmetricSmileWithZeroBeta(int256 deviation, int256 basePrice, int256 alpha) public view {
        // Bound inputs
        basePrice = bound(basePrice, 1e17, 1e21);
        deviation = bound(deviation, 1e15, basePrice / 2); // Up to 50% deviation
        alpha = bound(alpha, 0, MAX_ALPHA);

        // Create params with beta = 0 (symmetric smile)
        SkewModel.SkewParams memory params = SkewModel.SkewParams({ alpha: sd(alpha), beta: ZERO });

        // Calculate strikes equidistant from spot
        int256 strikeAbove = basePrice + deviation;
        int256 strikeBelow = basePrice - deviation;

        // Ensure strikeBelow is positive
        vm.assume(strikeBelow > 0);

        SD59x18 skewAbove = harness.calculateSkew(sd(strikeAbove), sd(basePrice), params);
        SD59x18 skewBelow = harness.calculateSkew(sd(strikeBelow), sd(basePrice), params);

        // With beta=0 and alpha>=0, both should produce non-negative skew (smile effect)
        assertTrue(skewAbove.gte(ZERO), "Skew above ATM should be non-negative with pure smile");
        assertTrue(skewBelow.gte(ZERO), "Skew below ATM should be non-negative with pure smile");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: Zero params produce zero skew
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: with alpha=0 and beta=0, skew is always zero
    function testFuzz_ZeroParamsProduceZeroSkew(int256 strike, int256 spot) public view {
        (strike, spot) = _boundPricesWithRatio(strike, spot);

        SkewModel.SkewParams memory params = SkewModel.SkewParams({ alpha: ZERO, beta: ZERO });

        SD59x18 skew = harness.calculateSkew(sd(strike), sd(spot), params);

        assertEq(skew.unwrap(), 0, "Zero params should produce zero skew");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: Moneyness calculation is correct
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: moneyness = K/S
    function testFuzz_MoneynessCalculation(int256 strike, int256 spot) public view {
        (strike, spot) = _boundPricesWithRatio(strike, spot);

        SD59x18 moneyness = harness.calculateMoneyness(sd(strike), sd(spot));

        // Calculate expected: K/S
        SD59x18 expected = sd(strike).div(sd(spot));

        assertApproxEqAbs(moneyness.unwrap(), expected.unwrap(), 1, "Moneyness calculation incorrect");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: Apply skew preserves proportionality
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: applySkew multiplies correctly
    function testFuzz_ApplySkewMultiplier(int256 baseIV, int256 strike, int256 spot, int256 alpha, int256 beta)
        public
        view
    {
        baseIV = bound(baseIV, 1e16, 5e18); // 1% to 500% IV
        (strike, spot) = _boundPricesWithRatio(strike, spot);
        SkewModel.SkewParams memory params = _boundParams(alpha, beta);

        SD59x18 skew = harness.calculateSkew(sd(strike), sd(spot), params);
        SD59x18 adjustedIV = harness.applySkew(sd(baseIV), sd(strike), sd(spot), params);

        // Expected: baseIV * (1 + skew)
        SD59x18 multiplier = sd(ONE).add(skew);
        SD59x18 expected = sd(baseIV).mul(multiplier);

        // Floor at zero
        if (expected.lt(ZERO)) {
            expected = ZERO;
        }

        assertApproxEqAbs(adjustedIV.unwrap(), expected.unwrap(), 1e10, "Apply skew multiplier incorrect");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: Parameter validation bounds
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: valid parameters always pass validation
    function testFuzz_ValidParamsPassValidation(int256 alpha, int256 beta) public view {
        // Bound to valid range
        alpha = bound(alpha, 0, MAX_ALPHA);
        beta = bound(beta, MIN_BETA, MAX_BETA);

        SkewModel.SkewParams memory params = SkewModel.SkewParams({ alpha: sd(alpha), beta: sd(beta) });

        // Should not revert
        harness.validateParams(params);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: createParams validates correctly
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: createParams with valid values succeeds
    function testFuzz_CreateParamsValid(int256 alpha, int256 beta) public view {
        // Bound to valid range
        alpha = bound(alpha, 0, MAX_ALPHA);
        beta = bound(beta, MIN_BETA, MAX_BETA);

        SkewModel.SkewParams memory params = harness.createParams(alpha, beta);

        assertEq(params.alpha.unwrap(), alpha, "Alpha mismatch");
        assertEq(params.beta.unwrap(), beta, "Beta mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: Put skew behavior (negative beta)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: with negative beta, OTM puts have higher skew than OTM calls
    function testFuzz_PutSkewBehavior(int256 spot, int256 deviation, int256 alpha, int256 negativeBeta) public view {
        // Bound inputs
        spot = bound(spot, 1e17, 1e21);
        deviation = bound(deviation, 1e15, spot / 4); // Up to 25% deviation
        alpha = bound(alpha, 0, 5e18);
        negativeBeta = bound(negativeBeta, MIN_BETA, -1e16); // Negative beta only

        int256 strikeOTMPut = spot - deviation;
        int256 strikeOTMCall = spot + deviation;

        vm.assume(strikeOTMPut > 0);

        SkewModel.SkewParams memory params = SkewModel.SkewParams({ alpha: sd(alpha), beta: sd(negativeBeta) });

        SD59x18 skewPut = harness.calculateSkew(sd(strikeOTMPut), sd(spot), params);
        SD59x18 skewCall = harness.calculateSkew(sd(strikeOTMCall), sd(spot), params);

        // With negative beta (put skew), OTM puts should have higher skew than OTM calls
        assertTrue(skewPut.gt(skewCall), "Put skew should be higher than call skew with negative beta");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: Skew monotonicity with pure linear term
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: with alpha=0, skew is monotonic with respect to moneyness
    function testFuzz_LinearSkewMonotonicity(int256 spot, int256 strike1, int256 strike2, int256 beta) public view {
        spot = bound(spot, 1e17, 1e21);
        strike1 = bound(strike1, spot / 5, spot * 5);
        strike2 = bound(strike2, spot / 5, spot * 5);
        beta = bound(beta, MIN_BETA, MAX_BETA);

        // Skip if strikes are equal
        vm.assume(strike1 != strike2);

        SkewModel.SkewParams memory params = SkewModel.SkewParams({ alpha: ZERO, beta: sd(beta) });

        SD59x18 skew1 = harness.calculateSkew(sd(strike1), sd(spot), params);
        SD59x18 skew2 = harness.calculateSkew(sd(strike2), sd(spot), params);

        // With alpha=0, skew = β * (K/S - 1)
        // If β > 0: higher strike = higher skew
        // If β < 0: higher strike = lower skew
        if (beta > 0) {
            if (strike1 > strike2) {
                assertTrue(skew1.gte(skew2), "Positive beta: higher strike should have higher or equal skew");
            } else {
                assertTrue(skew1.lte(skew2), "Positive beta: lower strike should have lower or equal skew");
            }
        } else if (beta < 0) {
            if (strike1 > strike2) {
                assertTrue(skew1.lte(skew2), "Negative beta: higher strike should have lower or equal skew");
            } else {
                assertTrue(skew1.gte(skew2), "Negative beta: lower strike should have higher or equal skew");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INVARIANT: No overflow for reasonable inputs
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: no overflow for reasonable moneyness ratios
    function testFuzz_NoOverflowForReasonableInputs(int256 strike, int256 spot, int256 alpha, int256 beta) public view {
        // Use bounded ratio to prevent overflow
        (strike, spot) = _boundPricesWithRatio(strike, spot);
        SkewModel.SkewParams memory params = _boundParams(alpha, beta);

        // This should never revert for valid inputs
        SD59x18 skew = harness.calculateSkew(sd(strike), sd(spot), params);

        // Verify result is bounded
        assertTrue(skew.gte(sd(MIN_SKEW)) && skew.lte(sd(MAX_SKEW)), "Skew out of bounds");
    }
}
