// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Multichaindeploymentwithcrosschainsettlement
} from "../../src/core/Multichaindeploymentwithcrosschainsettlement.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";

/// @title MultichaindeploymentwithcrosschainsettlementTest
/// @notice Unit tests for Multichaindeploymentwithcrosschainsettlement contract
contract MultichaindeploymentwithcrosschainsettlementTest is Test {
    Multichaindeploymentwithcrosschainsettlement public hub;
    Multichaindeploymentwithcrosschainsettlement public spoke;
    ERC20Mock public collateral;

    address public owner = address(this);
    address public relayer = address(0x10);
    address public alice = address(0x1);
    address public bob = address(0x2);

    uint64 public constant HUB_CHAIN_ID = 1;
    uint64 public constant SPOKE_CHAIN_ID = 42161; // Arbitrum
    uint64 public constant SPOKE2_CHAIN_ID = 10; // Optimism

    int256 public constant STRIKE = 3000e18;
    int256 public constant SETTLEMENT_PRICE = 3500e18;

    function setUp() public {
        // Warp to a reasonable timestamp so MIN_SYNC_INTERVAL checks pass
        vm.warp(1_000_000);

        collateral = new ERC20Mock("USD Coin", "USDC", 18);

        // Deploy hub on chain 1
        hub = new Multichaindeploymentwithcrosschainsettlement(HUB_CHAIN_ID, true, address(collateral));

        // Deploy spoke on chain 42161
        spoke = new Multichaindeploymentwithcrosschainsettlement(SPOKE_CHAIN_ID, false, address(collateral));

        // Authorize relayer on both
        hub.setRelayer(relayer, true);
        spoke.setRelayer(relayer, true);

        // Register spoke on hub
        hub.registerChain(SPOKE_CHAIN_ID, address(spoke));

        // Register hub on spoke
        spoke.registerChain(HUB_CHAIN_ID, address(hub));

        // Mint collateral to users
        collateral.mint(alice, 1_000_000e18);
        collateral.mint(bob, 1_000_000e18);

        // Approve contracts
        vm.prank(alice);
        collateral.approve(address(hub), type(uint256).max);
        vm.prank(alice);
        collateral.approve(address(spoke), type(uint256).max);
        vm.prank(bob);
        collateral.approve(address(hub), type(uint256).max);

        // Advance past the sync interval so first syncPosition call succeeds
        vm.warp(block.timestamp + hub.MIN_SYNC_INTERVAL() + 1);
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_setsLocalChainId() public view {
        assertEq(hub.localChainId(), HUB_CHAIN_ID);
        assertEq(spoke.localChainId(), SPOKE_CHAIN_ID);
    }

    function test_constructor_setsIsHub() public view {
        assertTrue(hub.isHub());
        assertFalse(spoke.isHub());
    }

    function test_constructor_setsCollateralToken() public view {
        assertEq(hub.collateralToken(), address(collateral));
    }

    function test_constructor_registersSelf() public view {
        assertEq(hub.getRegisteredChainCount(), 2); // self + spoke
        Multichaindeploymentwithcrosschainsettlement.ChainDeployment memory deployment =
            hub.getChainDeployment(HUB_CHAIN_ID);
        assertEq(deployment.deploymentAddress, address(hub));
        assertTrue(deployment.isActive);
    }

    function test_constructor_revertZeroCollateral() public {
        vm.expectRevert(Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__ZeroAddress.selector);
        new Multichaindeploymentwithcrosschainsettlement(1, true, address(0));
    }

    // =========================================================================
    // Chain Registration Tests
    // =========================================================================

    function test_registerChain_success() public {
        hub.registerChain(SPOKE2_CHAIN_ID, address(0xDEAD));

        Multichaindeploymentwithcrosschainsettlement.ChainDeployment memory deployment =
            hub.getChainDeployment(SPOKE2_CHAIN_ID);
        assertEq(deployment.chainId, SPOKE2_CHAIN_ID);
        assertEq(deployment.deploymentAddress, address(0xDEAD));
        assertTrue(deployment.isActive);
    }

    function test_registerChain_revertZeroAddress() public {
        vm.expectRevert(Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__ZeroAddress.selector);
        hub.registerChain(SPOKE2_CHAIN_ID, address(0));
    }

    function test_registerChain_revertAlreadyRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__ChainAlreadyRegistered.selector,
                SPOKE_CHAIN_ID
            )
        );
        hub.registerChain(SPOKE_CHAIN_ID, address(0xBEEF));
    }

    function test_registerChain_revertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        hub.registerChain(SPOKE2_CHAIN_ID, address(0xDEAD));
    }

    function test_deactivateChain_success() public {
        hub.deactivateChain(SPOKE_CHAIN_ID);

        (, bool active) = hub.isChainActive(SPOKE_CHAIN_ID);
        assertFalse(active);
    }

    function test_deactivateChain_revertNotRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__ChainNotRegistered.selector, 999
            )
        );
        hub.deactivateChain(999);
    }

    function test_activateChain_success() public {
        hub.deactivateChain(SPOKE_CHAIN_ID);
        hub.activateChain(SPOKE_CHAIN_ID);

        (, bool active) = hub.isChainActive(SPOKE_CHAIN_ID);
        assertTrue(active);
    }

    // =========================================================================
    // Relayer Management Tests
    // =========================================================================

    function test_setRelayer_authorize() public {
        address newRelayer = address(0x99);
        hub.setRelayer(newRelayer, true);
        assertTrue(hub.authorizedRelayers(newRelayer));
    }

    function test_setRelayer_deauthorize() public {
        hub.setRelayer(relayer, false);
        assertFalse(hub.authorizedRelayers(relayer));
    }

    function test_setRelayer_revertZeroAddress() public {
        vm.expectRevert(Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__ZeroAddress.selector);
        hub.setRelayer(address(0), true);
    }

    // =========================================================================
    // Collateral Operations Tests
    // =========================================================================

    function test_lockCollateral_success() public {
        uint256 seriesId = 1;
        uint256 amount = 100e18;

        vm.prank(alice);
        hub.lockCollateral(seriesId, amount);

        assertEq(hub.totalLocalCollateral(), amount);
        assertEq(collateral.balanceOf(address(hub)), amount);

        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos = hub.getAggregatedPosition(seriesId);
        assertEq(pos.totalCollateralAcrossChains, amount);
    }

    function test_lockCollateral_revertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__ZeroAmount.selector);
        hub.lockCollateral(1, 0);
    }

    function test_lockCollateral_multipleDeposits() public {
        uint256 seriesId = 1;

        vm.prank(alice);
        hub.lockCollateral(seriesId, 50e18);

        vm.prank(bob);
        hub.lockCollateral(seriesId, 75e18);

        assertEq(hub.totalLocalCollateral(), 125e18);

        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos = hub.getAggregatedPosition(seriesId);
        assertEq(pos.totalCollateralAcrossChains, 125e18);
    }

    function test_lockCollateral_revertAlreadySettled() public {
        uint256 seriesId = 1;

        // Lock collateral and set up positions for settlement
        vm.prank(alice);
        hub.lockCollateral(seriesId, 100e18);

        // Sync positions
        vm.prank(relayer);
        hub.syncPosition(seriesId, 10e18, 10e18);

        // Settle
        hub.initiateSettlement(seriesId, SETTLEMENT_PRICE, STRIKE, true);

        // Try to lock more - should revert
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__AlreadySettled.selector, seriesId
            )
        );
        hub.lockCollateral(seriesId, 50e18);
    }

    function test_releaseCollateral_success() public {
        uint256 seriesId = 1;
        uint256 lockAmount = 100e18;
        uint256 releaseAmount = 60e18;

        // Lock collateral
        vm.prank(alice);
        hub.lockCollateral(seriesId, lockAmount);

        // Sync and settle
        vm.prank(relayer);
        hub.syncPosition(seriesId, 10e18, 10e18);
        hub.initiateSettlement(seriesId, SETTLEMENT_PRICE, STRIKE, true);

        // Release collateral
        uint256 bobBalanceBefore = collateral.balanceOf(bob);
        vm.prank(relayer);
        hub.releaseCollateral(seriesId, releaseAmount, bob);

        assertEq(collateral.balanceOf(bob) - bobBalanceBefore, releaseAmount);
        assertEq(hub.totalLocalCollateral(), lockAmount - releaseAmount);
    }

    function test_releaseCollateral_revertNotSettled() public {
        uint256 seriesId = 1;
        vm.prank(alice);
        hub.lockCollateral(seriesId, 100e18);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__NotSettled.selector, seriesId
            )
        );
        hub.releaseCollateral(seriesId, 50e18, bob);
    }

    function test_releaseCollateral_revertInsufficientCollateral() public {
        uint256 seriesId = 1;
        vm.prank(alice);
        hub.lockCollateral(seriesId, 100e18);

        vm.prank(relayer);
        hub.syncPosition(seriesId, 10e18, 10e18);
        hub.initiateSettlement(seriesId, SETTLEMENT_PRICE, STRIKE, true);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__InsufficientCollateral.selector,
                100e18,
                200e18
            )
        );
        hub.releaseCollateral(seriesId, 200e18, bob);
    }

    // =========================================================================
    // Position Synchronization Tests
    // =========================================================================

    function test_syncPosition_success() public {
        uint256 seriesId = 1;

        vm.prank(relayer);
        hub.syncPosition(seriesId, 100e18, 100e18);

        Multichaindeploymentwithcrosschainsettlement.ChainPositionSnapshot memory snapshot =
            hub.getChainSnapshot(seriesId, HUB_CHAIN_ID);
        assertEq(snapshot.longAmount, 100e18);
        assertEq(snapshot.shortAmount, 100e18);
    }

    function test_syncPosition_revertTooFrequent() public {
        uint256 seriesId = 1;

        vm.prank(relayer);
        hub.syncPosition(seriesId, 50e18, 50e18);

        // Try again immediately - should fail
        vm.prank(relayer);
        vm.expectRevert();
        hub.syncPosition(seriesId, 60e18, 60e18);
    }

    function test_syncPosition_succeedsAfterInterval() public {
        uint256 seriesId = 1;

        vm.prank(relayer);
        hub.syncPosition(seriesId, 50e18, 50e18);

        // Advance time past min interval
        vm.warp(block.timestamp + hub.MIN_SYNC_INTERVAL() + 1);

        vm.prank(relayer);
        hub.syncPosition(seriesId, 100e18, 100e18);

        Multichaindeploymentwithcrosschainsettlement.ChainPositionSnapshot memory snapshot =
            hub.getChainSnapshot(seriesId, HUB_CHAIN_ID);
        assertEq(snapshot.longAmount, 100e18);
    }

    function test_receivePositionSync_success() public {
        uint256 seriesId = 1;

        vm.prank(relayer);
        hub.receivePositionSync(SPOKE_CHAIN_ID, seriesId, 200e18, 200e18, 600000e18);

        Multichaindeploymentwithcrosschainsettlement.ChainPositionSnapshot memory snapshot =
            hub.getChainSnapshot(seriesId, SPOKE_CHAIN_ID);
        assertEq(snapshot.longAmount, 200e18);
        assertEq(snapshot.shortAmount, 200e18);
        assertEq(snapshot.lockedCollateral, 600000e18);

        // Check aggregation
        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos = hub.getAggregatedPosition(seriesId);
        assertEq(pos.totalLongAcrossChains, 200e18);
        assertEq(pos.totalShortAcrossChains, 200e18);
    }

    function test_receivePositionSync_revertNotHub() public {
        vm.prank(relayer);
        vm.expectRevert(Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__NotHub.selector);
        spoke.receivePositionSync(HUB_CHAIN_ID, 1, 100e18, 100e18, 300000e18);
    }

    function test_receivePositionSync_revertUnknownChain() public {
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__ChainNotRegistered.selector, 999
            )
        );
        hub.receivePositionSync(999, 1, 100e18, 100e18, 300000e18);
    }

    // =========================================================================
    // Settlement Tests
    // =========================================================================

    function test_initiateSettlement_callITM() public {
        uint256 seriesId = 1;

        // Lock collateral
        vm.prank(alice);
        hub.lockCollateral(seriesId, 10000e18);

        // Sync positions on hub chain
        vm.prank(relayer);
        hub.syncPosition(seriesId, 100e18, 100e18);

        // Settle: call option, spot > strike => ITM
        hub.initiateSettlement(seriesId, SETTLEMENT_PRICE, STRIKE, true);

        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos = hub.getAggregatedPosition(seriesId);
        assertTrue(pos.isSettled);
    }

    function test_initiateSettlement_callOTM() public {
        uint256 seriesId = 2;

        vm.prank(alice);
        hub.lockCollateral(seriesId, 10000e18);

        // Need to advance time for syncPosition since we already synced once (for series 1 possibly)
        vm.warp(block.timestamp + hub.MIN_SYNC_INTERVAL() + 1);

        vm.prank(relayer);
        hub.syncPosition(seriesId, 100e18, 100e18);

        // Settle: call option, spot < strike => OTM (payoff = 0)
        hub.initiateSettlement(seriesId, 2500e18, STRIKE, true);

        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos = hub.getAggregatedPosition(seriesId);
        assertTrue(pos.isSettled);
        // Net settlement should be 0 for balanced positions with zero payoff
        assertEq(pos.netSettlementAmount, 0);
    }

    function test_initiateSettlement_putITM() public {
        uint256 seriesId = 3;

        vm.prank(alice);
        hub.lockCollateral(seriesId, 10000e18);

        vm.prank(relayer);
        hub.syncPosition(seriesId, 50e18, 50e18);

        // Settle: put option, spot < strike => ITM
        hub.initiateSettlement(seriesId, 2500e18, STRIKE, false);

        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos = hub.getAggregatedPosition(seriesId);
        assertTrue(pos.isSettled);
    }

    function test_initiateSettlement_revertInvalidPrice() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__InvalidSettlementPrice.selector, 0
            )
        );
        hub.initiateSettlement(1, 0, STRIKE, true);
    }

    function test_initiateSettlement_revertAlreadySettled() public {
        uint256 seriesId = 1;
        vm.prank(alice);
        hub.lockCollateral(seriesId, 100e18);

        vm.prank(relayer);
        hub.syncPosition(seriesId, 10e18, 10e18);

        hub.initiateSettlement(seriesId, SETTLEMENT_PRICE, STRIKE, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__AlreadySettled.selector, seriesId
            )
        );
        hub.initiateSettlement(seriesId, SETTLEMENT_PRICE, STRIKE, true);
    }

    function test_initiateSettlement_revertNotHub() public {
        vm.expectRevert(Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__NotHub.selector);
        spoke.initiateSettlement(1, SETTLEMENT_PRICE, STRIKE, true);
    }

    function test_executeSettlement_spoke() public {
        uint256 seriesId = 1;

        vm.prank(relayer);
        spoke.executeSettlement(seriesId, SETTLEMENT_PRICE, 500e18);

        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos =
            spoke.getAggregatedPosition(seriesId);
        assertTrue(pos.isSettled);
        assertEq(pos.netSettlementAmount, 500e18);
    }

    // =========================================================================
    // Liquidity Rebalancing Tests
    // =========================================================================

    function test_requestRebalance_success() public {
        uint256 rebalanceId = hub.requestRebalance(HUB_CHAIN_ID, SPOKE_CHAIN_ID, 1000e18);

        assertEq(rebalanceId, 1);

        Multichaindeploymentwithcrosschainsettlement.RebalanceRequest memory req = hub.getRebalanceRequest(rebalanceId);
        assertEq(req.fromChainId, HUB_CHAIN_ID);
        assertEq(req.toChainId, SPOKE_CHAIN_ID);
        assertEq(req.amount, 1000e18);
        assertFalse(req.executed);
    }

    function test_requestRebalance_revertSelfTarget() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__SelfTarget.selector, HUB_CHAIN_ID
            )
        );
        hub.requestRebalance(HUB_CHAIN_ID, HUB_CHAIN_ID, 1000e18);
    }

    function test_requestRebalance_revertZeroAmount() public {
        vm.expectRevert(Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__ZeroAmount.selector);
        hub.requestRebalance(HUB_CHAIN_ID, SPOKE_CHAIN_ID, 0);
    }

    function test_executeRebalance_success() public {
        uint256 rebalanceId = hub.requestRebalance(HUB_CHAIN_ID, SPOKE_CHAIN_ID, 1000e18);

        vm.prank(relayer);
        hub.executeRebalance(rebalanceId);

        Multichaindeploymentwithcrosschainsettlement.RebalanceRequest memory req = hub.getRebalanceRequest(rebalanceId);
        assertTrue(req.executed);
    }

    function test_executeRebalance_revertAlreadyExecuted() public {
        uint256 rebalanceId = hub.requestRebalance(HUB_CHAIN_ID, SPOKE_CHAIN_ID, 1000e18);

        vm.prank(relayer);
        hub.executeRebalance(rebalanceId);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__RebalanceAlreadyExecuted.selector,
                rebalanceId
            )
        );
        hub.executeRebalance(rebalanceId);
    }

    // =========================================================================
    // Message Management Tests
    // =========================================================================

    function test_confirmMessage_success() public {
        // Lock collateral on hub to generate a message (hub doesn't send messages to itself)
        // Instead, use spoke to generate a message since spoke sends to hub
        uint256 nonceBefore = spoke.messageNonce();
        uint256 ts = block.timestamp;

        vm.prank(alice);
        spoke.lockCollateral(1, 100e18);

        // The message was sent from SPOKE_CHAIN_ID to the hub chain (registeredChains[0] on spoke = SPOKE_CHAIN_ID)
        // spoke._getHubChainId() returns registeredChains[0] which is SPOKE_CHAIN_ID (self-registered in constructor)
        // So the message is: source=SPOKE_CHAIN_ID, dest=SPOKE_CHAIN_ID, nonce=nonceBefore, timestamp=ts
        bytes32 messageId = keccak256(abi.encodePacked(SPOKE_CHAIN_ID, SPOKE_CHAIN_ID, nonceBefore, ts));

        vm.prank(relayer);
        spoke.confirmMessage(messageId);

        Multichaindeploymentwithcrosschainsettlement.CrossChainMessage memory msg_ = spoke.getMessage(messageId);
        assertEq(uint256(msg_.status), uint256(Multichaindeploymentwithcrosschainsettlement.MessageStatus.CONFIRMED));
    }

    function test_confirmMessage_revertNotFound() public {
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__MessageNotFound.selector,
                bytes32(uint256(0x123))
            )
        );
        hub.confirmMessage(bytes32(uint256(0x123)));
    }

    function test_failMessage_success() public {
        uint256 nonceBefore = spoke.messageNonce();
        uint256 ts = block.timestamp;

        vm.prank(alice);
        spoke.lockCollateral(1, 100e18);

        bytes32 messageId = keccak256(abi.encodePacked(SPOKE_CHAIN_ID, SPOKE_CHAIN_ID, nonceBefore, ts));

        vm.prank(relayer);
        spoke.failMessage(messageId);

        Multichaindeploymentwithcrosschainsettlement.CrossChainMessage memory msg_ = spoke.getMessage(messageId);
        assertEq(uint256(msg_.status), uint256(Multichaindeploymentwithcrosschainsettlement.MessageStatus.FAILED));
    }

    function test_confirmMessage_revertAlreadyProcessed() public {
        uint256 nonceBefore = spoke.messageNonce();
        uint256 ts = block.timestamp;

        vm.prank(alice);
        spoke.lockCollateral(1, 100e18);

        bytes32 messageId = keccak256(abi.encodePacked(SPOKE_CHAIN_ID, SPOKE_CHAIN_ID, nonceBefore, ts));

        vm.prank(relayer);
        spoke.confirmMessage(messageId);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__MessageAlreadyProcessed.selector,
                messageId
            )
        );
        spoke.confirmMessage(messageId);
    }

    function test_confirmMessage_revertExpired() public {
        uint256 nonceBefore = spoke.messageNonce();
        uint256 ts = block.timestamp;

        vm.prank(alice);
        spoke.lockCollateral(1, 100e18);

        bytes32 messageId = keccak256(abi.encodePacked(SPOKE_CHAIN_ID, SPOKE_CHAIN_ID, nonceBefore, ts));

        // Warp past message expiry
        vm.warp(block.timestamp + spoke.MESSAGE_EXPIRY() + 1);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__MessageExpired.selector, messageId
            )
        );
        spoke.confirmMessage(messageId);
    }

    // =========================================================================
    // View Function Tests
    // =========================================================================

    function test_getRegisteredChains() public view {
        uint64[] memory chains = hub.getRegisteredChains();
        assertEq(chains.length, 2);
        assertEq(chains[0], HUB_CHAIN_ID);
        assertEq(chains[1], SPOKE_CHAIN_ID);
    }

    function test_getTotalCollateralAcrossChains() public {
        vm.prank(alice);
        hub.lockCollateral(1, 500e18);

        uint256 total = hub.getTotalCollateralAcrossChains();
        assertEq(total, 500e18);
    }

    function test_isChainActive_registered() public view {
        (bool registered, bool active) = hub.isChainActive(SPOKE_CHAIN_ID);
        assertTrue(registered);
        assertTrue(active);
    }

    function test_isChainActive_unregistered() public view {
        (bool registered, bool active) = hub.isChainActive(999);
        assertFalse(registered);
        assertFalse(active);
    }

    function test_getSettlementDelta() public {
        uint256 seriesId = 1;

        vm.prank(alice);
        hub.lockCollateral(seriesId, 10000e18);

        vm.prank(relayer);
        hub.syncPosition(seriesId, 100e18, 100e18);

        hub.initiateSettlement(seriesId, SETTLEMENT_PRICE, STRIKE, true);

        int256 delta = hub.getSettlementDelta(seriesId, HUB_CHAIN_ID);
        // With balanced long/short, delta should be 0
        assertEq(delta, 0);
    }

    // =========================================================================
    // Admin Tests
    // =========================================================================

    function test_pause_unpause() public {
        hub.pause();
        assertTrue(hub.paused());

        hub.unpause();
        assertFalse(hub.paused());
    }

    function test_setCollateralToken() public {
        ERC20Mock newToken = new ERC20Mock("DAI", "DAI", 18);
        hub.setCollateralToken(address(newToken));
        assertEq(hub.collateralToken(), address(newToken));
    }

    function test_setCollateralToken_revertZero() public {
        vm.expectRevert(Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__ZeroAddress.selector);
        hub.setCollateralToken(address(0));
    }

    function test_emergencyWithdraw() public {
        // Send tokens to contract
        collateral.mint(address(hub), 500e18);

        uint256 balBefore = collateral.balanceOf(owner);
        hub.emergencyWithdraw(address(collateral), 500e18);
        uint256 balAfter = collateral.balanceOf(owner);

        assertEq(balAfter - balBefore, 500e18);
    }

    function test_lockCollateral_revertWhenPaused() public {
        hub.pause();

        vm.prank(alice);
        vm.expectRevert();
        hub.lockCollateral(1, 100e18);
    }

    // =========================================================================
    // Access Control Tests
    // =========================================================================

    function test_syncPosition_revertUnauthorizedRelayer() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__UnauthorizedRelayer.selector, alice
            )
        );
        hub.syncPosition(1, 100e18, 100e18);
    }

    function test_releaseCollateral_revertUnauthorizedRelayer() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Multichaindeploymentwithcrosschainsettlement.CrossChainSettlement__UnauthorizedRelayer.selector, alice
            )
        );
        hub.releaseCollateral(1, 100e18, bob);
    }
}
