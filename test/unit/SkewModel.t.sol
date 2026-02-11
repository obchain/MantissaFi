// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { SkewModel } from "../../src/libraries/SkewModel.sol";

/// @title SkewModelHarness
/// @notice Harness contract to expose internal library functions for testing
contract SkewModelHarness {
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

    function maxAlpha() external pure returns (SD59x18) {
        return SkewModel.maxAlpha();
    }

    function maxBeta() external pure returns (SD59x18) {
        return SkewModel.maxBeta();
    }

    function minBeta() external pure returns (SD59x18) {
        return SkewModel.minBeta();
    }
}

/// @title SkewModelTest
/// @notice Unit tests for the SkewModel library
contract SkewModelTest is Test {
    SkewModelHarness harness;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    int256 constant ONE = 1e18;
    int256 constant HALF = 5e17;

    // ═══════════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════════

    function setUp() public {
        harness = new SkewModelHarness();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Helper to create SkewParams
    function _createParams(int256 alpha, int256 beta) internal pure returns (SkewModel.SkewParams memory) {
        return SkewModel.SkewParams({ alpha: sd(alpha), beta: sd(beta) });
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // calculateSkew TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test skew at-the-money (K = S) should be zero
    function test_calculateSkew_AtTheMoney() public view {
        SD59x18 strike = sd(100e18);
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(2e18, -1e18); // α=2, β=-1

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        // At K=S, moneyness = 0, so skew = α·0² + β·0 = 0
        assertEq(skew.unwrap(), 0);
    }

    /// @notice Test skew for out-of-the-money put (K < S)
    function test_calculateSkew_OTMPut() public view {
        SD59x18 strike = sd(90e18);
        SD59x18 spot = sd(100e18);
        // α=2, β=-1 (typical put skew)
        SkewModel.SkewParams memory params = _createParams(2e18, -1e18);

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        // m = 90/100 - 1 = -0.1
        // skew = 2·(-0.1)² + (-1)·(-0.1) = 2·0.01 + 0.1 = 0.02 + 0.1 = 0.12
        int256 expected = 12e16; // 0.12
        assertApproxEqAbs(skew.unwrap(), expected, 1e10);
    }

    /// @notice Test skew for out-of-the-money call (K > S)
    function test_calculateSkew_OTMCall() public view {
        SD59x18 strike = sd(110e18);
        SD59x18 spot = sd(100e18);
        // α=2, β=-1 (typical put skew)
        SkewModel.SkewParams memory params = _createParams(2e18, -1e18);

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        // m = 110/100 - 1 = 0.1
        // skew = 2·(0.1)² + (-1)·(0.1) = 2·0.01 - 0.1 = 0.02 - 0.1 = -0.08
        int256 expected = -8e16; // -0.08
        assertApproxEqAbs(skew.unwrap(), expected, 1e10);
    }

    /// @notice Test skew with zero alpha (linear-only model)
    function test_calculateSkew_ZeroAlpha() public view {
        SD59x18 strike = sd(90e18);
        SD59x18 spot = sd(100e18);
        // α=0, β=-2 (pure linear skew)
        SkewModel.SkewParams memory params = _createParams(0, -2e18);

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        // m = -0.1
        // skew = 0 + (-2)·(-0.1) = 0.2
        int256 expected = 2e17; // 0.2
        assertApproxEqAbs(skew.unwrap(), expected, 1e10);
    }

    /// @notice Test skew with zero beta (pure smile, no directional skew)
    function test_calculateSkew_ZeroBeta() public view {
        SD59x18 strike = sd(90e18);
        SD59x18 spot = sd(100e18);
        // α=3, β=0 (symmetric smile)
        SkewModel.SkewParams memory params = _createParams(3e18, 0);

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        // m = -0.1
        // skew = 3·(-0.1)² + 0 = 3·0.01 = 0.03
        int256 expected = 3e16; // 0.03
        assertApproxEqAbs(skew.unwrap(), expected, 1e10);
    }

    /// @notice Test skew with both zero parameters
    function test_calculateSkew_ZeroParams() public view {
        SD59x18 strike = sd(80e18);
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(0, 0);

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        assertEq(skew.unwrap(), 0);
    }

    /// @notice Test skew is bounded at maximum
    function test_calculateSkew_BoundedAtMax() public view {
        SD59x18 strike = sd(200e18); // Very deep OTM call
        SD59x18 spot = sd(100e18);
        // Large alpha to push skew above max
        SkewModel.SkewParams memory params = _createParams(10e18, 0);

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        // m = 200/100 - 1 = 1
        // Unbounded: skew = 10·1² = 10 > MAX_SKEW (1.0)
        assertEq(skew.unwrap(), 1e18); // Should be capped at 1.0
    }

    /// @notice Test skew is bounded at minimum
    function test_calculateSkew_BoundedAtMin() public view {
        SD59x18 strike = sd(150e18);
        SD59x18 spot = sd(100e18);
        // Large negative beta to push skew below min
        SkewModel.SkewParams memory params = _createParams(0, -5e18);

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        // m = 150/100 - 1 = 0.5
        // Unbounded: skew = 0 + (-5)·0.5 = -2.5 < MIN_SKEW (-0.5)
        assertEq(skew.unwrap(), -5e17); // Should be capped at -0.5
    }

    /// @notice Test skew with positive beta (call skew)
    function test_calculateSkew_PositiveBeta() public view {
        SD59x18 strike = sd(110e18);
        SD59x18 spot = sd(100e18);
        // α=1, β=2 (call skew)
        SkewModel.SkewParams memory params = _createParams(1e18, 2e18);

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        // m = 0.1
        // skew = 1·(0.1)² + 2·0.1 = 0.01 + 0.2 = 0.21
        int256 expected = 21e16; // 0.21
        assertApproxEqAbs(skew.unwrap(), expected, 1e10);
    }

    /// @notice Test skew reverts on zero spot price
    function test_calculateSkew_RevertOnZeroSpot() public {
        SD59x18 strike = sd(100e18);
        SD59x18 spot = ZERO;
        SkewModel.SkewParams memory params = _createParams(1e18, -1e18);

        vm.expectRevert(SkewModel.SkewModel__InvalidSpotPrice.selector);
        harness.calculateSkew(strike, spot, params);
    }

    /// @notice Test skew reverts on negative spot price
    function test_calculateSkew_RevertOnNegativeSpot() public {
        SD59x18 strike = sd(100e18);
        SD59x18 spot = sd(-100e18);
        SkewModel.SkewParams memory params = _createParams(1e18, -1e18);

        vm.expectRevert(SkewModel.SkewModel__InvalidSpotPrice.selector);
        harness.calculateSkew(strike, spot, params);
    }

    /// @notice Test skew reverts on zero strike price
    function test_calculateSkew_RevertOnZeroStrike() public {
        SD59x18 strike = ZERO;
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(1e18, -1e18);

        vm.expectRevert(SkewModel.SkewModel__InvalidStrikePrice.selector);
        harness.calculateSkew(strike, spot, params);
    }

    /// @notice Test skew reverts on negative strike price
    function test_calculateSkew_RevertOnNegativeStrike() public {
        SD59x18 strike = sd(-100e18);
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(1e18, -1e18);

        vm.expectRevert(SkewModel.SkewModel__InvalidStrikePrice.selector);
        harness.calculateSkew(strike, spot, params);
    }

    /// @notice Test skew with extreme moneyness (deep OTM put)
    function test_calculateSkew_DeepOTMPut() public view {
        SD59x18 strike = sd(50e18); // 50% of spot
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(1e18, -1e18);

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        // m = 50/100 - 1 = -0.5
        // skew = 1·(-0.5)² + (-1)·(-0.5) = 0.25 + 0.5 = 0.75
        int256 expected = 75e16;
        assertApproxEqAbs(skew.unwrap(), expected, 1e10);
    }

    /// @notice Test skew with extreme moneyness (deep OTM call)
    function test_calculateSkew_DeepOTMCall() public view {
        SD59x18 strike = sd(150e18); // 150% of spot
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(1e18, -1e18);

        SD59x18 skew = harness.calculateSkew(strike, spot, params);

        // m = 150/100 - 1 = 0.5
        // skew = 1·(0.5)² + (-1)·(0.5) = 0.25 - 0.5 = -0.25
        int256 expected = -25e16;
        assertApproxEqAbs(skew.unwrap(), expected, 1e10);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // applySkew TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test applying skew to base IV at-the-money
    function test_applySkew_AtTheMoney() public view {
        SD59x18 baseIV = sd(8e17); // 80% IV
        SD59x18 strike = sd(100e18);
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(2e18, -1e18);

        SD59x18 adjustedIV = harness.applySkew(baseIV, strike, spot, params);

        // At-the-money, skew = 0, so adjustedIV = baseIV * (1 + 0) = baseIV
        assertEq(adjustedIV.unwrap(), 8e17);
    }

    /// @notice Test applying skew increases IV for OTM puts
    function test_applySkew_IncreasesIVForOTMPut() public view {
        SD59x18 baseIV = sd(5e17); // 50% IV
        SD59x18 strike = sd(90e18);
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(2e18, -1e18);

        SD59x18 adjustedIV = harness.applySkew(baseIV, strike, spot, params);

        // skew ≈ 0.12, adjustedIV = 0.5 * (1 + 0.12) = 0.56
        int256 expected = 56e16;
        assertApproxEqAbs(adjustedIV.unwrap(), expected, 1e12);
    }

    /// @notice Test applying skew decreases IV for OTM calls (with put skew)
    function test_applySkew_DecreasesIVForOTMCall() public view {
        SD59x18 baseIV = sd(5e17); // 50% IV
        SD59x18 strike = sd(110e18);
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(2e18, -1e18);

        SD59x18 adjustedIV = harness.applySkew(baseIV, strike, spot, params);

        // skew ≈ -0.08, adjustedIV = 0.5 * (1 - 0.08) = 0.46
        int256 expected = 46e16;
        assertApproxEqAbs(adjustedIV.unwrap(), expected, 1e12);
    }

    /// @notice Test applying skew does not produce negative IV
    function test_applySkew_FloorAtZero() public view {
        SD59x18 baseIV = sd(1e17); // 10% IV (low)
        SD59x18 strike = sd(150e18);
        SD59x18 spot = sd(100e18);
        // Very negative beta to try to make IV negative
        SkewModel.SkewParams memory params = _createParams(0, -4e18);

        SD59x18 adjustedIV = harness.applySkew(baseIV, strike, spot, params);

        // Skew would be large negative (bounded to -0.5)
        // adjustedIV = 0.1 * (1 - 0.5) = 0.05 >= 0
        assertTrue(adjustedIV.gte(ZERO));
    }

    /// @notice Test applying skew with high base IV
    function test_applySkew_HighBaseIV() public view {
        SD59x18 baseIV = sd(15e17); // 150% IV
        SD59x18 strike = sd(90e18);
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(2e18, -1e18);

        SD59x18 adjustedIV = harness.applySkew(baseIV, strike, spot, params);

        // skew ≈ 0.12, adjustedIV = 1.5 * (1 + 0.12) = 1.68
        int256 expected = 168e16;
        assertApproxEqAbs(adjustedIV.unwrap(), expected, 1e12);
    }

    /// @notice Test applying skew with zero base IV
    function test_applySkew_ZeroBaseIV() public view {
        SD59x18 baseIV = ZERO;
        SD59x18 strike = sd(90e18);
        SD59x18 spot = sd(100e18);
        SkewModel.SkewParams memory params = _createParams(2e18, -1e18);

        SD59x18 adjustedIV = harness.applySkew(baseIV, strike, spot, params);

        // 0 * anything = 0
        assertEq(adjustedIV.unwrap(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // calculateMoneyness TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test moneyness calculation at-the-money
    function test_calculateMoneyness_AtTheMoney() public view {
        SD59x18 strike = sd(100e18);
        SD59x18 spot = sd(100e18);

        SD59x18 moneyness = harness.calculateMoneyness(strike, spot);

        assertEq(moneyness.unwrap(), 1e18); // K/S = 1
    }

    /// @notice Test moneyness calculation for OTM put
    function test_calculateMoneyness_OTMPut() public view {
        SD59x18 strike = sd(90e18);
        SD59x18 spot = sd(100e18);

        SD59x18 moneyness = harness.calculateMoneyness(strike, spot);

        assertEq(moneyness.unwrap(), 9e17); // K/S = 0.9
    }

    /// @notice Test moneyness calculation for OTM call
    function test_calculateMoneyness_OTMCall() public view {
        SD59x18 strike = sd(110e18);
        SD59x18 spot = sd(100e18);

        SD59x18 moneyness = harness.calculateMoneyness(strike, spot);

        assertEq(moneyness.unwrap(), 11e17); // K/S = 1.1
    }

    /// @notice Test moneyness reverts on zero spot
    function test_calculateMoneyness_RevertOnZeroSpot() public {
        SD59x18 strike = sd(100e18);
        SD59x18 spot = ZERO;

        vm.expectRevert(SkewModel.SkewModel__InvalidSpotPrice.selector);
        harness.calculateMoneyness(strike, spot);
    }

    /// @notice Test moneyness reverts on zero strike
    function test_calculateMoneyness_RevertOnZeroStrike() public {
        SD59x18 strike = ZERO;
        SD59x18 spot = sd(100e18);

        vm.expectRevert(SkewModel.SkewModel__InvalidStrikePrice.selector);
        harness.calculateMoneyness(strike, spot);
    }

    /// @notice Test moneyness with small values
    function test_calculateMoneyness_SmallValues() public view {
        SD59x18 strike = sd(1e15); // 0.001
        SD59x18 spot = sd(1e16); // 0.01

        SD59x18 moneyness = harness.calculateMoneyness(strike, spot);

        assertEq(moneyness.unwrap(), 1e17); // K/S = 0.1
    }

    /// @notice Test moneyness with large values
    function test_calculateMoneyness_LargeValues() public view {
        SD59x18 strike = sd(1e27); // 1 billion
        SD59x18 spot = sd(1e26); // 100 million

        SD59x18 moneyness = harness.calculateMoneyness(strike, spot);

        assertEq(moneyness.unwrap(), 10e18); // K/S = 10
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // validateParams TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test valid parameters pass validation
    function test_validateParams_ValidParams() public view {
        SkewModel.SkewParams memory params = _createParams(2e18, -1e18);
        harness.validateParams(params); // Should not revert
    }

    /// @notice Test validation passes for zero parameters
    function test_validateParams_ZeroParams() public view {
        SkewModel.SkewParams memory params = _createParams(0, 0);
        harness.validateParams(params); // Should not revert
    }

    /// @notice Test validation passes at maximum alpha
    function test_validateParams_MaxAlpha() public view {
        SkewModel.SkewParams memory params = _createParams(10e18, 0);
        harness.validateParams(params); // Should not revert
    }

    /// @notice Test validation passes at maximum beta
    function test_validateParams_MaxBeta() public view {
        SkewModel.SkewParams memory params = _createParams(0, 5e18);
        harness.validateParams(params); // Should not revert
    }

    /// @notice Test validation passes at minimum beta
    function test_validateParams_MinBeta() public view {
        SkewModel.SkewParams memory params = _createParams(0, -5e18);
        harness.validateParams(params); // Should not revert
    }

    /// @notice Test validation reverts on negative alpha
    function test_validateParams_RevertOnNegativeAlpha() public {
        SkewModel.SkewParams memory params = _createParams(-1e18, 0);

        vm.expectRevert(SkewModel.SkewModel__AlphaNegative.selector);
        harness.validateParams(params);
    }

    /// @notice Test validation reverts on alpha exceeding maximum
    function test_validateParams_RevertOnAlphaExceedsMax() public {
        SkewModel.SkewParams memory params = _createParams(11e18, 0); // > 10

        vm.expectRevert(SkewModel.SkewModel__AlphaExceedsMaximum.selector);
        harness.validateParams(params);
    }

    /// @notice Test validation reverts on beta exceeding maximum
    function test_validateParams_RevertOnBetaExceedsMax() public {
        SkewModel.SkewParams memory params = _createParams(0, 6e18); // > 5

        vm.expectRevert(SkewModel.SkewModel__BetaExceedsMaximum.selector);
        harness.validateParams(params);
    }

    /// @notice Test validation reverts on beta below minimum
    function test_validateParams_RevertOnBetaBelowMin() public {
        SkewModel.SkewParams memory params = _createParams(0, -6e18); // < -5

        vm.expectRevert(SkewModel.SkewModel__BetaBelowMinimum.selector);
        harness.validateParams(params);
    }

    /// @notice Test validation at exact boundary values
    function test_validateParams_ExactBoundaries() public view {
        // All boundary values
        SkewModel.SkewParams memory params1 = _createParams(0, 0);
        SkewModel.SkewParams memory params2 = _createParams(10e18, 5e18);
        SkewModel.SkewParams memory params3 = _createParams(10e18, -5e18);

        harness.validateParams(params1);
        harness.validateParams(params2);
        harness.validateParams(params3);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // createParams TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test createParams with valid values
    function test_createParams_Valid() public view {
        SkewModel.SkewParams memory params = harness.createParams(2e18, -1e18);

        assertEq(params.alpha.unwrap(), 2e18);
        assertEq(params.beta.unwrap(), -1e18);
    }

    /// @notice Test createParams reverts on invalid alpha
    function test_createParams_RevertOnInvalidAlpha() public {
        vm.expectRevert(SkewModel.SkewModel__AlphaNegative.selector);
        harness.createParams(-1e18, 0);
    }

    /// @notice Test createParams reverts on invalid beta
    function test_createParams_RevertOnInvalidBeta() public {
        vm.expectRevert(SkewModel.SkewModel__BetaExceedsMaximum.selector);
        harness.createParams(0, 10e18);
    }

    /// @notice Test createParams with zero values
    function test_createParams_ZeroValues() public view {
        SkewModel.SkewParams memory params = harness.createParams(0, 0);

        assertEq(params.alpha.unwrap(), 0);
        assertEq(params.beta.unwrap(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANT ACCESSOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Test maxSkew returns correct value
    function test_maxSkew() public view {
        assertEq(harness.maxSkew().unwrap(), 1e18);
    }

    /// @notice Test minSkew returns correct value
    function test_minSkew() public view {
        assertEq(harness.minSkew().unwrap(), -5e17);
    }

    /// @notice Test maxAlpha returns correct value
    function test_maxAlpha() public view {
        assertEq(harness.maxAlpha().unwrap(), 10e18);
    }

    /// @notice Test maxBeta returns correct value
    function test_maxBeta() public view {
        assertEq(harness.maxBeta().unwrap(), 5e18);
    }

    /// @notice Test minBeta returns correct value
    function test_minBeta() public view {
        assertEq(harness.minBeta().unwrap(), -5e18);
    }
}
