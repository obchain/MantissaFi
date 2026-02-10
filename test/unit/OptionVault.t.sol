// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { OptionVault } from "../../src/core/OptionVault.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";

/// @title OptionVaultTest
/// @notice Unit tests for OptionVault contract
contract OptionVaultTest is Test {
    OptionVault public vault;
    ERC20Mock public underlying;
    ERC20Mock public collateral;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);

    int256 public constant STRIKE = 3000e18; // $3000
    uint64 public constant EXPIRY_OFFSET = 30 days;

    function setUp() public {
        vault = new OptionVault();
        underlying = new ERC20Mock("Wrapped ETH", "WETH", 18);
        collateral = new ERC20Mock("USD Coin", "USDC", 18);

        // Mint tokens to users
        underlying.mint(alice, 1000e18);
        underlying.mint(bob, 1000e18);
        collateral.mint(alice, 1000000e18);
        collateral.mint(bob, 1000000e18);

        // Approve vault
        vm.prank(alice);
        collateral.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        collateral.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // Series Creation Tests
    // =========================================================================

    function test_createSeries_success() public {
        OptionVault.OptionSeries memory config = _createCallConfig();

        uint256 seriesId = vault.createSeries(config);

        assertEq(seriesId, 1, "First series ID should be 1");

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        assertEq(data.config.underlying, address(underlying), "Underlying mismatch");
        assertEq(data.config.strike, STRIKE, "Strike mismatch");
        assertTrue(data.config.isCall, "Should be call");
        assertEq(uint256(data.state), uint256(OptionVault.SeriesState.ACTIVE), "Should be ACTIVE");
    }

    function test_createSeries_incrementsId() public {
        OptionVault.OptionSeries memory config = _createCallConfig();

        uint256 id1 = vault.createSeries(config);
        uint256 id2 = vault.createSeries(config);

        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_createSeries_revertZeroUnderlying() public {
        OptionVault.OptionSeries memory config = _createCallConfig();
        config.underlying = address(0);

        vm.expectRevert(OptionVault.OptionVault__ZeroAddress.selector);
        vault.createSeries(config);
    }

    function test_createSeries_revertZeroCollateral() public {
        OptionVault.OptionSeries memory config = _createCallConfig();
        config.collateral = address(0);

        vm.expectRevert(OptionVault.OptionVault__ZeroAddress.selector);
        vault.createSeries(config);
    }

    function test_createSeries_revertInvalidStrike() public {
        OptionVault.OptionSeries memory config = _createCallConfig();
        config.strike = 0;

        vm.expectRevert(OptionVault.OptionVault__InvalidStrike.selector);
        vault.createSeries(config);
    }

    function test_createSeries_revertPastExpiry() public {
        OptionVault.OptionSeries memory config = _createCallConfig();
        config.expiry = uint64(block.timestamp - 1);

        vm.expectRevert(OptionVault.OptionVault__InvalidExpiry.selector);
        vault.createSeries(config);
    }

    function test_createSeries_revertExpiryTooSoon() public {
        OptionVault.OptionSeries memory config = _createCallConfig();
        config.expiry = uint64(block.timestamp + 30 minutes); // Less than MIN_TIME_TO_EXPIRY

        vm.expectRevert(OptionVault.OptionVault__ExpiryTooSoon.selector);
        vault.createSeries(config);
    }

    // =========================================================================
    // Minting Tests
    // =========================================================================

    function test_mint_success() public {
        uint256 seriesId = vault.createSeries(_createPutConfig());
        uint256 amount = 10e18;

        vm.prank(alice);
        vault.mint(seriesId, amount);

        OptionVault.Position memory pos = vault.getPosition(seriesId, alice);
        assertEq(pos.longAmount, amount, "Long amount mismatch");
        assertEq(pos.shortAmount, amount, "Short amount mismatch");
    }

    function test_mint_transfersCollateral() public {
        uint256 seriesId = vault.createSeries(_createPutConfig());
        uint256 amount = 10e18;

        uint256 balanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        vault.mint(seriesId, amount);

        uint256 balanceAfter = collateral.balanceOf(alice);
        uint256 expectedCollateral = (uint256(STRIKE) * amount) / 1e18;

        assertEq(balanceBefore - balanceAfter, expectedCollateral, "Collateral not transferred");
    }

    function test_mint_updatesSeriesState() public {
        uint256 seriesId = vault.createSeries(_createPutConfig());
        uint256 amount = 10e18;

        vm.prank(alice);
        vault.mint(seriesId, amount);

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        assertEq(data.totalMinted, amount, "Total minted not updated");
        assertGt(data.collateralLocked, 0, "Collateral not locked");
    }

    function test_mint_revertZeroAmount() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());

        vm.prank(alice);
        vm.expectRevert(OptionVault.OptionVault__InvalidAmount.selector);
        vault.mint(seriesId, 0);
    }

    function test_mint_revertSeriesNotFound() public {
        vm.prank(alice);
        vm.expectRevert(OptionVault.OptionVault__SeriesNotFound.selector);
        vault.mint(999, 10e18);
    }

    function test_mint_revertAfterExpiry() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());

        // Warp past expiry
        vm.warp(block.timestamp + EXPIRY_OFFSET + 1);

        vm.prank(alice);
        vm.expectRevert(OptionVault.OptionVault__AlreadyExpired.selector);
        vault.mint(seriesId, 10e18);
    }

    // =========================================================================
    // Exercise Tests
    // =========================================================================

    function test_exercise_success() public {
        uint256 seriesId = vault.createSeries(_createPutConfig());

        vm.prank(alice);
        vault.mint(seriesId, 10e18);

        // Warp to expiry
        vm.warp(block.timestamp + EXPIRY_OFFSET);

        uint256 balanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        vault.exercise(seriesId, 10e18);

        uint256 balanceAfter = collateral.balanceOf(alice);
        // Put is ITM (mock price is strike * 0.9)
        assertGt(balanceAfter, balanceBefore, "Should receive payout");
    }

    function test_exercise_revertBeforeExpiry() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());

        vm.prank(alice);
        vault.mint(seriesId, 10e18);

        vm.prank(alice);
        vm.expectRevert(OptionVault.OptionVault__NotYetExpired.selector);
        vault.exercise(seriesId, 10e18);
    }

    function test_exercise_revertAfterGracePeriod() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());

        vm.prank(alice);
        vault.mint(seriesId, 10e18);

        // Warp past grace period
        vm.warp(block.timestamp + EXPIRY_OFFSET + 25 hours);

        vm.prank(alice);
        vm.expectRevert(OptionVault.OptionVault__ExercisePeriodEnded.selector);
        vault.exercise(seriesId, 10e18);
    }

    function test_exercise_revertInsufficientPosition() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());

        vm.prank(alice);
        vault.mint(seriesId, 10e18);

        vm.warp(block.timestamp + EXPIRY_OFFSET);

        vm.prank(bob);
        vm.expectRevert(OptionVault.OptionVault__InsufficientPosition.selector);
        vault.exercise(seriesId, 10e18);
    }

    // =========================================================================
    // Settlement Tests
    // =========================================================================

    function test_settle_success() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());

        vm.prank(alice);
        vault.mint(seriesId, 10e18);

        // Warp past grace period
        vm.warp(block.timestamp + EXPIRY_OFFSET + 25 hours);

        vault.settle(seriesId);

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        assertEq(uint256(data.state), uint256(OptionVault.SeriesState.SETTLED), "Should be SETTLED");
    }

    function test_settle_revertTooEarly() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());

        vm.prank(alice);
        vault.mint(seriesId, 10e18);

        // Warp to expiry but not past grace period
        vm.warp(block.timestamp + EXPIRY_OFFSET);

        vm.expectRevert(OptionVault.OptionVault__SettlementTooEarly.selector);
        vault.settle(seriesId);
    }

    // =========================================================================
    // View Function Tests
    // =========================================================================

    function test_isExpired_false() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());
        assertFalse(vault.isExpired(seriesId));
    }

    function test_isExpired_true() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());
        vm.warp(block.timestamp + EXPIRY_OFFSET + 1);
        assertTrue(vault.isExpired(seriesId));
    }

    function test_canExercise_beforeExpiry() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());
        vm.prank(alice);
        vault.mint(seriesId, 10e18);

        assertFalse(vault.canExercise(seriesId));
    }

    function test_canExercise_duringGracePeriod() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());
        vm.prank(alice);
        vault.mint(seriesId, 10e18);

        vm.warp(block.timestamp + EXPIRY_OFFSET + 1 hours);
        assertTrue(vault.canExercise(seriesId));
    }

    function test_timeToExpiry() public {
        uint256 seriesId = vault.createSeries(_createCallConfig());
        uint256 tte = vault.timeToExpiry(seriesId);

        assertApproxEqAbs(tte, EXPIRY_OFFSET, 1, "Time to expiry mismatch");
    }

    function test_calculateCollateral_put() public {
        uint256 seriesId = vault.createSeries(_createPutConfig());
        uint256 collateralNeeded = vault.calculateCollateral(seriesId, 10e18);

        // Put: strike * amount
        uint256 expected = (uint256(STRIKE) * 10e18) / 1e18;
        assertEq(collateralNeeded, expected, "Collateral calculation wrong");
    }

    // =========================================================================
    // Admin Tests
    // =========================================================================

    function test_pause() public {
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_unpause() public {
        vault.pause();
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_pause_revertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }

    function test_createSeries_revertWhenPaused() public {
        vault.pause();

        vm.expectRevert();
        vault.createSeries(_createCallConfig());
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _createCallConfig() internal view returns (OptionVault.OptionSeries memory) {
        return OptionVault.OptionSeries({
            underlying: address(underlying),
            collateral: address(collateral),
            strike: STRIKE,
            expiry: uint64(block.timestamp + EXPIRY_OFFSET),
            isCall: true
        });
    }

    function _createPutConfig() internal view returns (OptionVault.OptionSeries memory) {
        return OptionVault.OptionSeries({
            underlying: address(underlying),
            collateral: address(collateral),
            strike: STRIKE,
            expiry: uint64(block.timestamp + EXPIRY_OFFSET),
            isCall: false
        });
    }
}
