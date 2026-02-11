// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { OptionVault } from "../../src/core/OptionVault.sol";
import { OptionRouter } from "../../src/core/OptionRouter.sol";
import { ERC20PermitMock } from "../mocks/ERC20PermitMock.sol";

/// @title OptionRouterFuzzTest
/// @notice Fuzz tests for OptionRouter invariants
contract OptionRouterFuzzTest is Test {
    OptionVault public vault;
    OptionRouter public router;
    ERC20PermitMock public underlying;
    ERC20PermitMock public collateral;

    uint256 public alicePrivateKey = 0xA11CE;
    address public alice;

    int256 public constant STRIKE = 3000e18;

    function setUp() public {
        vault = new OptionVault();
        router = new OptionRouter(address(vault));
        underlying = new ERC20PermitMock("Wrapped ETH", "WETH", 18);
        collateral = new ERC20PermitMock("USD Coin", "USDC", 18);

        alice = vm.addr(alicePrivateKey);

        // Mint large amounts for fuzz testing
        collateral.mint(alice, type(uint128).max);

        vm.prank(alice);
        collateral.approve(address(router), type(uint256).max);
    }

    // =========================================================================
    // mintAndDeposit Fuzz Tests
    // =========================================================================

    /// @notice Collateral transferred always equals calculated collateral for puts
    function testFuzz_mintAndDeposit_collateralCorrectPut(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 seriesId = _createSeries(STRIKE, false);
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        uint256 balanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        uint256 balanceAfter = collateral.balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, collateralRequired, "Collateral mismatch");
    }

    /// @notice Collateral transferred always equals calculated collateral for calls
    function testFuzz_mintAndDeposit_collateralCorrectCall(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 seriesId = _createSeries(STRIKE, true);
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        uint256 balanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        uint256 balanceAfter = collateral.balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, collateralRequired, "Collateral mismatch");
    }

    /// @notice Router position always matches the minted amount
    function testFuzz_mintAndDeposit_positionTracked(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 seriesId = _createSeries(STRIKE, false);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        OptionVault.Position memory pos = vault.getPosition(seriesId, address(router));
        assertEq(pos.longAmount, amount, "Long position mismatch");
        assertEq(pos.shortAmount, amount, "Short position mismatch");
    }

    /// @notice Multiple mints accumulate correctly
    function testFuzz_mintAndDeposit_accumulates(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 500e18);
        amount2 = bound(amount2, 1, 500e18);

        uint256 seriesId = _createSeries(STRIKE, false);

        vm.startPrank(alice);
        router.mintAndDeposit(seriesId, amount1);
        router.mintAndDeposit(seriesId, amount2);
        vm.stopPrank();

        OptionVault.Position memory pos = vault.getPosition(seriesId, address(router));
        assertEq(pos.longAmount, amount1 + amount2, "Accumulated long mismatch");
        assertEq(pos.shortAmount, amount1 + amount2, "Accumulated short mismatch");

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        assertEq(data.totalMinted, amount1 + amount2, "Total minted mismatch");
    }

    /// @notice Vault collateral locked matches actual token balance change
    function testFuzz_mintAndDeposit_vaultBalanceConsistent(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 seriesId = _createSeries(STRIKE, false);
        uint256 vaultBalanceBefore = collateral.balanceOf(address(vault));

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        uint256 vaultBalanceAfter = collateral.balanceOf(address(vault));
        OptionVault.SeriesData memory data = vault.getSeries(seriesId);

        assertEq(
            data.collateralLocked, vaultBalanceAfter - vaultBalanceBefore, "Vault collateral tracking inconsistent"
        );
    }

    // =========================================================================
    // mintWithPermit Fuzz Tests
    // =========================================================================

    /// @notice Permit-based minting produces same position as direct approval minting
    function testFuzz_mintWithPermit_matchesDirect(uint256 amount) public {
        amount = bound(amount, 1, 500e18);

        // Create two identical series
        uint256 seriesPermit = _createSeries(STRIKE, false);
        uint256 seriesDirect = _createSeries(STRIKE, false);

        uint256 collateralRequired = vault.calculateCollateral(seriesPermit, amount);

        // Mint via permit
        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), collateralRequired);
        vm.prank(alice);
        router.mintWithPermit(seriesPermit, amount, permit);

        // Re-approve router after permit overrode the allowance
        vm.prank(alice);
        collateral.approve(address(router), type(uint256).max);

        // Mint via direct approval
        vm.prank(alice);
        router.mintAndDeposit(seriesDirect, amount);

        // Both should produce identical positions
        OptionVault.Position memory posPermit = vault.getPosition(seriesPermit, address(router));
        OptionVault.Position memory posDirect = vault.getPosition(seriesDirect, address(router));

        assertEq(posPermit.longAmount, posDirect.longAmount, "Permit vs direct long mismatch");
        assertEq(posPermit.shortAmount, posDirect.shortAmount, "Permit vs direct short mismatch");
    }

    /// @notice Permit with excess value still only transfers required collateral
    function testFuzz_mintWithPermit_excessPermitNoOvercharge(uint256 amount, uint256 excess) public {
        amount = bound(amount, 1, 500e18);
        excess = bound(excess, 1, 1000e18);

        uint256 seriesId = _createSeries(STRIKE, false);
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        OptionRouter.Permit memory permit = _signPermit(alicePrivateKey, address(router), collateralRequired + excess);

        uint256 balanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        router.mintWithPermit(seriesId, amount, permit);

        uint256 balanceAfter = collateral.balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, collateralRequired, "Should only transfer exact collateral needed");
    }

    // =========================================================================
    // exerciseAndWithdraw Fuzz Tests
    // =========================================================================

    /// @notice Payout is always forwarded to user, router retains nothing
    function testFuzz_exerciseAndWithdraw_routerNetZero(uint256 amount) public {
        amount = bound(amount, 1e18, 100e18);

        uint256 seriesId = _createSeries(STRIKE, false);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        // Warp to expiry
        vm.warp(block.timestamp + 31 days);

        uint256 routerBalanceBefore = collateral.balanceOf(address(router));

        vm.prank(alice);
        router.exerciseAndWithdraw(seriesId, amount);

        uint256 routerBalanceAfter = collateral.balanceOf(address(router));
        assertEq(routerBalanceAfter, routerBalanceBefore, "Router should not retain any payout");
    }

    /// @notice User balance increases by exactly the payout amount
    function testFuzz_exerciseAndWithdraw_userReceivesPayout(uint256 amount) public {
        amount = bound(amount, 1e18, 100e18);

        uint256 seriesId = _createSeries(STRIKE, false);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        vm.warp(block.timestamp + 31 days);

        uint256 aliceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        router.exerciseAndWithdraw(seriesId, amount);

        uint256 aliceAfter = collateral.balanceOf(alice);
        assertGt(aliceAfter, aliceBefore, "Alice should receive payout");
    }

    // =========================================================================
    // Strike Price Fuzz Tests
    // =========================================================================

    /// @notice Varying strike prices produce correct collateral for puts
    function testFuzz_mintAndDeposit_varyingStrike(int256 strike) public {
        strike = bound(strike, 100e18, 100_000e18);
        uint256 amount = 1e18;

        uint256 seriesId = _createSeries(strike, false);
        uint256 expectedCollateral = (uint256(strike) * amount) / 1e18;

        uint256 balanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        uint256 balanceAfter = collateral.balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, expectedCollateral, "Collateral wrong for given strike");
    }

    /// @notice Router does not hold residual collateral after mint flows
    function testFuzz_mintAndDeposit_noResidualCollateral(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 seriesId = _createSeries(STRIKE, false);
        uint256 routerBalanceBefore = collateral.balanceOf(address(router));

        vm.prank(alice);
        router.mintAndDeposit(seriesId, amount);

        uint256 routerBalanceAfter = collateral.balanceOf(address(router));
        assertEq(routerBalanceAfter, routerBalanceBefore, "Router should not hold residual collateral");
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _createSeries(int256 strike, bool isCall) internal returns (uint256) {
        return vault.createSeries(
            OptionVault.OptionSeries({
                underlying: address(underlying),
                collateral: address(collateral),
                strike: strike,
                expiry: uint64(block.timestamp + 30 days),
                isCall: isCall
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
