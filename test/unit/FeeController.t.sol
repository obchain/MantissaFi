// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import { FeeController } from "../../src/core/FeeController.sol";

/// @title FeeControllerTest
/// @notice Unit tests for FeeController dynamic fee model
contract FeeControllerTest is Test {
    FeeController public controller;

    address public owner = address(this);
    address public feeRecipient = address(0xFEE);
    address public alice = address(0xA11CE);

    // Default parameters: 30 bps base, 500 bps spread, 1M pool cap
    int256 public constant DEFAULT_BASE_FEE = 3e15; // 0.003 (30 bps)
    int256 public constant DEFAULT_SPREAD_FEE = 5e16; // 0.05 (500 bps)
    uint256 public constant DEFAULT_POOL_CAP = 1_000_000e18; // 1M tokens

    uint256 public constant SERIES_1 = 1;
    uint256 public constant SERIES_2 = 2;

    function setUp() public {
        controller = new FeeController(feeRecipient, DEFAULT_BASE_FEE, DEFAULT_SPREAD_FEE, DEFAULT_POOL_CAP);
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_setsOwner() public view {
        assertEq(controller.owner(), owner, "Owner should be deployer");
    }

    function test_constructor_setsFeeRecipient() public view {
        assertEq(controller.feeRecipient(), feeRecipient, "Fee recipient mismatch");
    }

    function test_constructor_setsDefaults() public view {
        assertEq(controller.defaultBaseFee().unwrap(), DEFAULT_BASE_FEE, "Default base fee mismatch");
        assertEq(controller.defaultSpreadFee().unwrap(), DEFAULT_SPREAD_FEE, "Default spread fee mismatch");
        assertEq(controller.defaultPoolCap(), DEFAULT_POOL_CAP, "Default pool cap mismatch");
    }

    function test_constructor_revertsOnZeroRecipient() public {
        vm.expectRevert(FeeController.FeeController__ZeroAddress.selector);
        new FeeController(address(0), DEFAULT_BASE_FEE, DEFAULT_SPREAD_FEE, DEFAULT_POOL_CAP);
    }

    function test_constructor_revertsOnNegativeBaseFee() public {
        vm.expectRevert(abi.encodeWithSelector(FeeController.FeeController__NegativeFee.selector, int256(-1)));
        new FeeController(feeRecipient, -1, DEFAULT_SPREAD_FEE, DEFAULT_POOL_CAP);
    }

    function test_constructor_revertsOnExcessiveBaseFee() public {
        int256 excessiveBase = 2e17; // 20%, max is 10%
        vm.expectRevert(
            abi.encodeWithSelector(FeeController.FeeController__BaseFeeExceedsMaximum.selector, excessiveBase)
        );
        new FeeController(feeRecipient, excessiveBase, DEFAULT_SPREAD_FEE, DEFAULT_POOL_CAP);
    }

    function test_constructor_revertsOnPoolCapTooLow() public {
        vm.expectRevert(abi.encodeWithSelector(FeeController.FeeController__PoolCapTooLow.selector, uint256(100)));
        new FeeController(feeRecipient, DEFAULT_BASE_FEE, DEFAULT_SPREAD_FEE, 100);
    }

    // =========================================================================
    // calculateFee Tests
    // =========================================================================

    function test_calculateFee_zeroUtilization() public view {
        // At 0% utilization: fee = amount × baseFee = 100e18 × 0.003 = 0.3e18
        uint256 fee = controller.calculateFee(SERIES_1, 100e18, 0);
        assertEq(fee, 300000000000000000, "Fee at zero util should equal baseFee * amount");
    }

    function test_calculateFee_fullUtilization() public view {
        // At 100% utilization: fee = amount × (baseFee + spreadFee × 1²)
        // = 100e18 × (0.003 + 0.05) = 100e18 × 0.053 = 5.3e18
        uint256 fee = controller.calculateFee(SERIES_1, 100e18, DEFAULT_POOL_CAP);
        assertEq(fee, 5300000000000000000, "Fee at full util should include spread");
    }

    function test_calculateFee_halfUtilization() public view {
        // At 50% utilization: fee = amount × (baseFee + spreadFee × 0.25)
        // = 100e18 × (0.003 + 0.05 × 0.25) = 100e18 × 0.0155 = 1.55e18
        uint256 totalMinted = DEFAULT_POOL_CAP / 2;
        uint256 fee = controller.calculateFee(SERIES_1, 100e18, totalMinted);
        assertEq(fee, 1550000000000000000, "Fee at 50% util should include quadratic spread");
    }

    function test_calculateFee_lowUtilization() public view {
        // At 10% utilization: fee = amount × (0.003 + 0.05 × 0.01) = amount × 0.0035
        uint256 totalMinted = DEFAULT_POOL_CAP / 10;
        uint256 fee = controller.calculateFee(SERIES_1, 100e18, totalMinted);
        assertEq(fee, 350000000000000000, "Fee at 10% util");
    }

    function test_calculateFee_revertsOnZeroAmount() public {
        vm.expectRevert(FeeController.FeeController__ZeroAmount.selector);
        controller.calculateFee(SERIES_1, 0, 0);
    }

    function test_calculateFee_capsUtilizationAtOne() public view {
        // Even if totalMinted exceeds poolCap, utilization is capped at 1.0
        uint256 overMinted = DEFAULT_POOL_CAP * 2;
        uint256 fee = controller.calculateFee(SERIES_1, 100e18, overMinted);
        uint256 feeAtMax = controller.calculateFee(SERIES_1, 100e18, DEFAULT_POOL_CAP);
        assertEq(fee, feeAtMax, "Fee should cap at 100% utilization");
    }

    // =========================================================================
    // calculateFeeWithUtilization Tests
    // =========================================================================

    function test_calculateFeeWithUtilization_zero() public view {
        uint256 fee = controller.calculateFeeWithUtilization(SERIES_1, 100e18, 0);
        assertEq(fee, 300000000000000000, "Fee at zero util via explicit util");
    }

    function test_calculateFeeWithUtilization_full() public view {
        uint256 fee = controller.calculateFeeWithUtilization(SERIES_1, 100e18, 1e18);
        assertEq(fee, 5300000000000000000, "Fee at full util via explicit util");
    }

    function test_calculateFeeWithUtilization_clampsNegative() public view {
        // Negative utilization should be treated as zero
        uint256 fee = controller.calculateFeeWithUtilization(SERIES_1, 100e18, -1e18);
        uint256 feeAtZero = controller.calculateFeeWithUtilization(SERIES_1, 100e18, 0);
        assertEq(fee, feeAtZero, "Negative util should be clamped to zero");
    }

    function test_calculateFeeWithUtilization_clampsAboveOne() public view {
        uint256 fee = controller.calculateFeeWithUtilization(SERIES_1, 100e18, 2e18);
        uint256 feeAtFull = controller.calculateFeeWithUtilization(SERIES_1, 100e18, 1e18);
        assertEq(fee, feeAtFull, "Util above 1 should be clamped to 1");
    }

    // =========================================================================
    // getFeeRate Tests
    // =========================================================================

    function test_getFeeRate_zeroUtil() public view {
        int256 rate = controller.getFeeRate(SERIES_1, 0);
        assertEq(rate, DEFAULT_BASE_FEE, "Fee rate at zero util should be baseFee");
    }

    function test_getFeeRate_fullUtil() public view {
        int256 rate = controller.getFeeRate(SERIES_1, DEFAULT_POOL_CAP);
        assertEq(rate, DEFAULT_BASE_FEE + DEFAULT_SPREAD_FEE, "Fee rate at full util should be baseFee + spreadFee");
    }

    // =========================================================================
    // getUtilization Tests
    // =========================================================================

    function test_getUtilization_zero() public view {
        int256 util = controller.getUtilization(0, DEFAULT_POOL_CAP);
        assertEq(util, 0, "Zero minted should give zero utilization");
    }

    function test_getUtilization_full() public view {
        int256 util = controller.getUtilization(DEFAULT_POOL_CAP, DEFAULT_POOL_CAP);
        assertEq(util, 1e18, "Full capacity should give 100% utilization");
    }

    function test_getUtilization_half() public view {
        int256 util = controller.getUtilization(DEFAULT_POOL_CAP / 2, DEFAULT_POOL_CAP);
        assertEq(util, 5e17, "Half capacity should give 50% utilization");
    }

    function test_getUtilization_capsAtOne() public view {
        int256 util = controller.getUtilization(DEFAULT_POOL_CAP * 2, DEFAULT_POOL_CAP);
        assertEq(util, 1e18, "Over-utilized should cap at 100%");
    }

    function test_getUtilization_revertsOnLowCap() public {
        vm.expectRevert(abi.encodeWithSelector(FeeController.FeeController__PoolCapTooLow.selector, uint256(100)));
        controller.getUtilization(50, 100);
    }

    // =========================================================================
    // Series Configuration Tests
    // =========================================================================

    function test_setFeeConfig_setsCustomConfig() public {
        int256 customBase = 1e16; // 1%
        int256 customSpread = 1e17; // 10%
        uint256 customCap = 500_000e18;

        controller.setFeeConfig(SERIES_1, customBase, customSpread, customCap);

        (int256 baseFee, int256 spreadFee, uint256 poolCap) = controller.getEffectiveConfig(SERIES_1);
        assertEq(baseFee, customBase, "Custom base fee mismatch");
        assertEq(spreadFee, customSpread, "Custom spread fee mismatch");
        assertEq(poolCap, customCap, "Custom pool cap mismatch");
    }

    function test_setFeeConfig_emitsEvent() public {
        int256 customBase = 1e16;
        int256 customSpread = 1e17;
        uint256 customCap = 500_000e18;

        vm.expectEmit(true, false, false, true);
        emit FeeController.FeeConfigSet(SERIES_1, customBase, customSpread, customCap);

        controller.setFeeConfig(SERIES_1, customBase, customSpread, customCap);
    }

    function test_setFeeConfig_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        controller.setFeeConfig(SERIES_1, DEFAULT_BASE_FEE, DEFAULT_SPREAD_FEE, DEFAULT_POOL_CAP);
    }

    function test_removeFeeConfig_fallsBackToDefaults() public {
        // Set custom config
        controller.setFeeConfig(SERIES_1, 1e16, 1e17, 500_000e18);
        assertTrue(controller.hasCustomConfig(SERIES_1), "Should have custom config");

        // Remove it
        controller.removeFeeConfig(SERIES_1);
        assertFalse(controller.hasCustomConfig(SERIES_1), "Should no longer have custom config");

        (int256 baseFee, int256 spreadFee, uint256 poolCap) = controller.getEffectiveConfig(SERIES_1);
        assertEq(baseFee, DEFAULT_BASE_FEE, "Should fallback to default base fee");
        assertEq(spreadFee, DEFAULT_SPREAD_FEE, "Should fallback to default spread fee");
        assertEq(poolCap, DEFAULT_POOL_CAP, "Should fallback to default pool cap");
    }

    function test_setFeeConfig_customConfigUsedInFeeCalc() public {
        // Set a higher fee for SERIES_1
        int256 highBase = 1e16; // 1%
        int256 highSpread = 2e17; // 20%
        controller.setFeeConfig(SERIES_1, highBase, highSpread, DEFAULT_POOL_CAP);

        // Fee at zero util: 100e18 × 0.01 = 1e18
        uint256 fee = controller.calculateFee(SERIES_1, 100e18, 0);
        assertEq(fee, 1e18, "Custom config base fee should apply");

        // SERIES_2 still uses defaults
        uint256 fee2 = controller.calculateFee(SERIES_2, 100e18, 0);
        assertEq(fee2, 300000000000000000, "Default config should apply to unconfigured series");
    }

    // =========================================================================
    // Default Configuration Tests
    // =========================================================================

    function test_setDefaults_updatesGlobalDefaults() public {
        int256 newBase = 5e15;
        int256 newSpread = 1e17;
        uint256 newCap = 2_000_000e18;

        controller.setDefaults(newBase, newSpread, newCap);

        assertEq(controller.defaultBaseFee().unwrap(), newBase, "Default base fee not updated");
        assertEq(controller.defaultSpreadFee().unwrap(), newSpread, "Default spread fee not updated");
        assertEq(controller.defaultPoolCap(), newCap, "Default pool cap not updated");
    }

    function test_setDefaults_emitsEvent() public {
        int256 newBase = 5e15;
        int256 newSpread = 1e17;
        uint256 newCap = 2_000_000e18;

        vm.expectEmit(false, false, false, true);
        emit FeeController.DefaultsUpdated(newBase, newSpread, newCap);

        controller.setDefaults(newBase, newSpread, newCap);
    }

    function test_setDefaults_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        controller.setDefaults(DEFAULT_BASE_FEE, DEFAULT_SPREAD_FEE, DEFAULT_POOL_CAP);
    }

    // =========================================================================
    // Fee Recipient Tests
    // =========================================================================

    function test_setFeeRecipient_updates() public {
        address newRecipient = address(0xBEEF);

        vm.expectEmit(true, true, false, false);
        emit FeeController.FeeRecipientUpdated(feeRecipient, newRecipient);

        controller.setFeeRecipient(newRecipient);
        assertEq(controller.feeRecipient(), newRecipient, "Fee recipient not updated");
    }

    function test_setFeeRecipient_revertsOnZero() public {
        vm.expectRevert(FeeController.FeeController__ZeroAddress.selector);
        controller.setFeeRecipient(address(0));
    }

    function test_setFeeRecipient_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        controller.setFeeRecipient(address(0xBEEF));
    }

    // =========================================================================
    // Fee Recording Tests
    // =========================================================================

    function test_recordFee_accumulatesFees() public {
        controller.recordFee(SERIES_1, alice, 100e18, 3e17);
        controller.recordFee(SERIES_1, alice, 200e18, 6e17);

        (uint256 totalCollected, uint256 totalTrades) = controller.getAccumulatedFees(SERIES_1);
        assertEq(totalCollected, 9e17, "Total collected mismatch");
        assertEq(totalTrades, 2, "Total trades mismatch");
    }

    function test_recordFee_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit FeeController.FeeCharged(SERIES_1, alice, 100e18, 3e17);

        controller.recordFee(SERIES_1, alice, 100e18, 3e17);
    }

    function test_recordFee_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        controller.recordFee(SERIES_1, alice, 100e18, 3e17);
    }

    function test_recordFee_independentPerSeries() public {
        controller.recordFee(SERIES_1, alice, 100e18, 3e17);
        controller.recordFee(SERIES_2, alice, 200e18, 6e17);

        (uint256 collected1, uint256 trades1) = controller.getAccumulatedFees(SERIES_1);
        (uint256 collected2, uint256 trades2) = controller.getAccumulatedFees(SERIES_2);

        assertEq(collected1, 3e17, "Series 1 collected mismatch");
        assertEq(trades1, 1, "Series 1 trades mismatch");
        assertEq(collected2, 6e17, "Series 2 collected mismatch");
        assertEq(trades2, 1, "Series 2 trades mismatch");
    }

    // =========================================================================
    // hasCustomConfig Tests
    // =========================================================================

    function test_hasCustomConfig_falseByDefault() public view {
        assertFalse(controller.hasCustomConfig(SERIES_1), "Should not have custom config by default");
    }

    function test_hasCustomConfig_trueAfterSet() public {
        controller.setFeeConfig(SERIES_1, DEFAULT_BASE_FEE, DEFAULT_SPREAD_FEE, DEFAULT_POOL_CAP);
        assertTrue(controller.hasCustomConfig(SERIES_1), "Should have custom config after setting");
    }

    // =========================================================================
    // Quadratic Fee Curve Shape Tests
    // =========================================================================

    function test_feeRate_monotonicallyIncreasing() public view {
        // Fee rate should increase as utilization increases
        int256 rate0 = controller.getFeeRate(SERIES_1, 0);
        int256 rate25 = controller.getFeeRate(SERIES_1, DEFAULT_POOL_CAP / 4);
        int256 rate50 = controller.getFeeRate(SERIES_1, DEFAULT_POOL_CAP / 2);
        int256 rate75 = controller.getFeeRate(SERIES_1, DEFAULT_POOL_CAP * 3 / 4);
        int256 rate100 = controller.getFeeRate(SERIES_1, DEFAULT_POOL_CAP);

        assertLt(rate0, rate25, "rate at 0% < rate at 25%");
        assertLt(rate25, rate50, "rate at 25% < rate at 50%");
        assertLt(rate50, rate75, "rate at 50% < rate at 75%");
        assertLt(rate75, rate100, "rate at 75% < rate at 100%");
    }

    function test_feeRate_quadraticShape() public view {
        // The spread component is proportional to utilization²
        // At 50% util: spreadComponent = 0.05 × 0.25 = 0.0125
        // At 100% util: spreadComponent = 0.05 × 1.0 = 0.05
        // Ratio should be 4:1
        int256 rateAt50 = controller.getFeeRate(SERIES_1, DEFAULT_POOL_CAP / 2);
        int256 rateAt100 = controller.getFeeRate(SERIES_1, DEFAULT_POOL_CAP);

        int256 spreadAt50 = rateAt50 - DEFAULT_BASE_FEE;
        int256 spreadAt100 = rateAt100 - DEFAULT_BASE_FEE;

        // spreadAt100 / spreadAt50 = 4
        assertApproxEqRel(uint256(spreadAt100), uint256(spreadAt50) * 4, 1e14, "Quadratic shape: 4:1 ratio");
    }

    // =========================================================================
    // VERSION Test
    // =========================================================================

    function test_version() public view {
        assertEq(keccak256(bytes(controller.VERSION())), keccak256("1.0.0"), "Version should be 1.0.0");
    }
}
