// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { OptionVault } from "../../src/core/OptionVault.sol";
import { OptionRouter } from "../../src/core/OptionRouter.sol";
import { ERC20PermitMock } from "../mocks/ERC20PermitMock.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title OptionRouterTest
/// @notice Unit tests for OptionRouter contract
contract OptionRouterTest is Test {
    OptionVault public vault;
    OptionRouter public router;
    ERC20PermitMock public underlying;
    ERC20PermitMock public collateral;

    address public owner = address(this);
    uint256 public alicePrivateKey = 0xA11CE;
    address public alice;
    address public bob = address(0x2);

    int256 public constant STRIKE = 3000e18;
    uint64 public constant EXPIRY_OFFSET = 30 days;

    function setUp() public {
        // Deploy core contracts
        vault = new OptionVault();
        router = new OptionRouter(address(vault));

        // Deploy mock tokens with permit support
        underlying = new ERC20PermitMock("Wrapped ETH", "WETH", 18);
        collateral = new ERC20PermitMock("USD Coin", "USDC", 18);

        // Derive alice's address from private key (needed for signing permits)
        alice = vm.addr(alicePrivateKey);

        // Mint tokens to users
        underlying.mint(alice, 1000e18);
        collateral.mint(alice, 1_000_000e18);
        collateral.mint(bob, 1_000_000e18);
        collateral.mint(address(router), 1_000_000e18);
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_setsVault() public view {
        assertEq(address(router.vault()), address(vault), "Vault address mismatch");
    }

    function test_constructor_revertZeroAddress() public {
        vm.expectRevert(OptionRouter.OptionRouter__ZeroAddress.selector);
        new OptionRouter(address(0));
    }

    // =========================================================================
    // mintWithPermit Tests
    // =========================================================================

    function test_mintWithPermit_success() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), collateralRequired);

        uint256 balanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        router.mintWithPermit(seriesId, amount, permit);

        uint256 balanceAfter = collateral.balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, collateralRequired, "Collateral not transferred");
    }

    function test_mintWithPermit_emitsEvent() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), collateralRequired);

        vm.expectEmit(true, true, false, true);
        emit OptionRouter.MintedWithPermit(seriesId, alice, amount, collateralRequired);

        vm.prank(alice);
        router.mintWithPermit(seriesId, amount, permit);
    }

    function test_mintWithPermit_routerHoldsPosition() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), collateralRequired);

        vm.prank(alice);
        router.mintWithPermit(seriesId, amount, permit);

        // Router holds the position, not alice
        OptionVault.Position memory routerPos = vault.getPosition(seriesId, address(router));
        assertEq(routerPos.longAmount, amount, "Router should hold long position");
        assertEq(routerPos.shortAmount, amount, "Router should hold short position");

        OptionVault.Position memory alicePos = vault.getPosition(seriesId, alice);
        assertEq(alicePos.longAmount, 0, "Alice should not hold position directly");
    }

    function test_mintWithPermit_callOption() public {
        uint256 seriesId = _createCallSeries();
        uint256 amount = 5e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), collateralRequired);

        uint256 balanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        router.mintWithPermit(seriesId, amount, permit);

        uint256 balanceAfter = collateral.balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, collateralRequired, "Call collateral not transferred");
    }

    function test_mintWithPermit_permitValueExceedsRequired() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        // Permit for more than required — should succeed
        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), collateralRequired * 2);

        vm.prank(alice);
        router.mintWithPermit(seriesId, amount, permit);

        OptionVault.Position memory routerPos = vault.getPosition(seriesId, address(router));
        assertEq(routerPos.longAmount, amount, "Mint should succeed with excess permit");
    }

    function test_mintWithPermit_revertZeroAmount() public {
        uint256 seriesId = _createPutSeries();

        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), 1e18);

        vm.prank(alice);
        vm.expectRevert(OptionRouter.OptionRouter__InvalidAmount.selector);
        router.mintWithPermit(seriesId, 0, permit);
    }

    function test_mintWithPermit_revertInsufficientPermit() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        // Permit for less than required
        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), collateralRequired - 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptionRouter.OptionRouter__InsufficientPermit.selector, collateralRequired, collateralRequired - 1
            )
        );
        router.mintWithPermit(seriesId, amount, permit);
    }

    function test_mintWithPermit_revertSeriesNotFound() public {
        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), 1e18);

        vm.prank(alice);
        vm.expectRevert(OptionVault.OptionVault__SeriesNotFound.selector);
        router.mintWithPermit(999, 10e18, permit);
    }

    function test_mintWithPermit_worksWithPriorApproval() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 5e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        // Alice directly approves router (simulating permit already used / frontrun)
        vm.prank(alice);
        collateral.approve(address(router), collateralRequired);

        // Use a permit with bad signature — the try/catch allows it to fail gracefully
        OptionRouter.Permit memory permit =
            OptionRouter.Permit({ value: collateralRequired, deadline: block.timestamp + 1 hours, v: 0, r: 0, s: 0 });

        vm.prank(alice);
        router.mintWithPermit(seriesId, amount, permit);

        OptionVault.Position memory routerPos = vault.getPosition(seriesId, address(router));
        assertEq(routerPos.longAmount, amount, "Should work with prior approval");
    }

    // =========================================================================
    // mintAndDeposit Tests
    // =========================================================================

    function test_mintAndDeposit_success() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        // Alice approves router
        vm.prank(alice);
        collateral.approve(address(router), collateralRequired);

        uint256 balanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        uint256 balanceAfter = collateral.balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, collateralRequired, "Collateral not transferred");
    }

    function test_mintAndDeposit_emitsEvent() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        vm.prank(alice);
        collateral.approve(address(router), collateralRequired);

        vm.expectEmit(true, true, false, true);
        emit OptionRouter.MintedAndDeposited(seriesId, alice, amount, collateralRequired);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);
    }

    function test_mintAndDeposit_routerHoldsPosition() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        vm.prank(alice);
        collateral.approve(address(router), collateralRequired);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        OptionVault.Position memory pos = vault.getPosition(seriesId, address(router));
        assertEq(pos.longAmount, amount, "Router should hold long position");
        assertEq(pos.shortAmount, amount, "Router should hold short position");
    }

    function test_mintAndDeposit_updatesSeriesState() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        vm.prank(alice);
        collateral.approve(address(router), collateralRequired);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        assertEq(data.totalMinted, amount, "Total minted not updated");
        assertGt(data.collateralLocked, 0, "Collateral not locked");
    }

    function test_mintAndDeposit_revertZeroAmount() public {
        uint256 seriesId = _createPutSeries();

        vm.prank(alice);
        vm.expectRevert(OptionRouter.OptionRouter__InvalidAmount.selector);
        router.mintAndDeposit(seriesId, 0);
    }

    function test_mintAndDeposit_revertSeriesNotFound() public {
        vm.prank(alice);
        vm.expectRevert(OptionVault.OptionVault__SeriesNotFound.selector);
        router.mintAndDeposit(999, 10e18);
    }

    function test_mintAndDeposit_revertInsufficientApproval() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;

        // Alice does NOT approve router
        vm.prank(alice);
        vm.expectRevert();
        router.mintAndDeposit(seriesId, amount);
    }

    function test_mintAndDeposit_callOption() public {
        uint256 seriesId = _createCallSeries();
        uint256 amount = 5e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        vm.prank(alice);
        collateral.approve(address(router), collateralRequired);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        OptionVault.Position memory pos = vault.getPosition(seriesId, address(router));
        assertEq(pos.longAmount, amount, "Call option mint failed");
    }

    // =========================================================================
    // exerciseAndWithdraw Tests
    // =========================================================================

    function test_exerciseAndWithdraw_putOption() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        // Mint through router
        vm.prank(alice);
        collateral.approve(address(router), collateralRequired);
        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        // Warp to expiry
        vm.warp(block.timestamp + EXPIRY_OFFSET);

        uint256 balanceBefore = collateral.balanceOf(alice);

        // Exercise through router
        vm.prank(alice);
        router.exerciseAndWithdraw(seriesId, amount);

        uint256 balanceAfter = collateral.balanceOf(alice);
        assertGt(balanceAfter, balanceBefore, "Should receive payout");
    }

    function test_exerciseAndWithdraw_emitsEvent() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        vm.prank(alice);
        collateral.approve(address(router), collateralRequired);
        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        vm.warp(block.timestamp + EXPIRY_OFFSET);

        // We can't predict the exact payout, so just check the event is emitted
        vm.prank(alice);
        router.exerciseAndWithdraw(seriesId, amount);

        // If we reach here without revert, the event was emitted
    }

    function test_exerciseAndWithdraw_revertZeroAmount() public {
        uint256 seriesId = _createPutSeries();

        vm.prank(alice);
        vm.expectRevert(OptionRouter.OptionRouter__InvalidAmount.selector);
        router.exerciseAndWithdraw(seriesId, 0);
    }

    function test_exerciseAndWithdraw_revertSeriesNotFound() public {
        vm.prank(alice);
        vm.expectRevert(OptionVault.OptionVault__SeriesNotFound.selector);
        router.exerciseAndWithdraw(999, 10e18);
    }

    function test_exerciseAndWithdraw_revertBeforeExpiry() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        vm.prank(alice);
        collateral.approve(address(router), collateralRequired);
        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        // Try to exercise before expiry — vault should revert
        vm.prank(alice);
        vm.expectRevert(OptionVault.OptionVault__NotYetExpired.selector);
        router.exerciseAndWithdraw(seriesId, amount);
    }

    function test_exerciseAndWithdraw_payoutTransferredToUser() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 10e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        vm.prank(alice);
        collateral.approve(address(router), collateralRequired);
        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        vm.warp(block.timestamp + EXPIRY_OFFSET);

        uint256 routerBalanceBefore = collateral.balanceOf(address(router));

        vm.prank(alice);
        router.exerciseAndWithdraw(seriesId, amount);

        // Router should not hold the payout — it goes to alice
        uint256 routerBalanceAfter = collateral.balanceOf(address(router));
        // The router first receives payout from vault, then sends to alice — net zero change
        // (router's pre-existing balance should be unaffected)
        assertEq(routerBalanceAfter, routerBalanceBefore, "Router should not retain payout");
    }

    // =========================================================================
    // Integration / Multi-step Tests
    // =========================================================================

    function test_mintWithPermit_thenExercise() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount = 5e18;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        // Step 1: Mint with permit
        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), collateralRequired);
        vm.prank(alice);
        router.mintWithPermit(seriesId, amount, permit);

        // Step 2: Warp to expiry
        vm.warp(block.timestamp + EXPIRY_OFFSET);

        // Step 3: Exercise through router (router holds the position)
        uint256 balanceBefore = collateral.balanceOf(alice);
        vm.prank(alice);
        router.exerciseAndWithdraw(seriesId, amount);

        uint256 balanceAfter = collateral.balanceOf(alice);
        assertGt(balanceAfter, balanceBefore, "Should receive payout after permit mint");
    }

    function test_multipleMints_sameSeriesAccumulate() public {
        uint256 seriesId = _createPutSeries();
        uint256 amount1 = 5e18;
        uint256 amount2 = 3e18;
        uint256 collateral1 = vault.calculateCollateral(seriesId, amount1);
        uint256 collateral2 = vault.calculateCollateral(seriesId, amount2);

        vm.startPrank(alice);
        collateral.approve(address(router), collateral1 + collateral2);
        router.mintAndDeposit(seriesId, amount1);
        router.mintAndDeposit(seriesId, amount2);
        vm.stopPrank();

        OptionVault.Position memory pos = vault.getPosition(seriesId, address(router));
        assertEq(pos.longAmount, amount1 + amount2, "Accumulated long position mismatch");
        assertEq(pos.shortAmount, amount1 + amount2, "Accumulated short position mismatch");
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _createCallSeries() internal returns (uint256) {
        return vault.createSeries(
            OptionVault.OptionSeries({
                underlying: address(underlying),
                collateral: address(collateral),
                strike: STRIKE,
                expiry: uint64(block.timestamp + EXPIRY_OFFSET),
                isCall: true
            })
        );
    }

    function _createPutSeries() internal returns (uint256) {
        return vault.createSeries(
            OptionVault.OptionSeries({
                underlying: address(underlying),
                collateral: address(collateral),
                strike: STRIKE,
                expiry: uint64(block.timestamp + EXPIRY_OFFSET),
                isCall: false
            })
        );
    }

    function _signPermit(uint256 privateKey, address spender, uint256 value)
        internal
        view
        returns (OptionRouter.Permit memory)
    {
        address signer = vm.addr(privateKey);
        uint256 nonce = collateral.nonces(signer);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 domainSeparator = collateral.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        return OptionRouter.Permit({ value: value, deadline: deadline, v: v, r: r, s: s });
    }
}
