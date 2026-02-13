// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Multichaindeploymentwithcrosschainsettlement
} from "../../src/core/Multichaindeploymentwithcrosschainsettlement.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";

/// @title MultichaindeploymentwithcrosschainsettlementFuzzTest
/// @notice Fuzz tests for cross-chain settlement invariants
contract MultichaindeploymentwithcrosschainsettlementFuzzTest is Test {
    Multichaindeploymentwithcrosschainsettlement public hub;
    Multichaindeploymentwithcrosschainsettlement public spoke;
    ERC20Mock public collateral;

    address public relayer = address(0x10);
    address public alice = address(0x1);

    uint64 public constant HUB_CHAIN_ID = 1;
    uint64 public constant SPOKE_CHAIN_ID = 42161;

    function setUp() public {
        vm.warp(1_000_000);

        collateral = new ERC20Mock("USD Coin", "USDC", 18);

        hub = new Multichaindeploymentwithcrosschainsettlement(HUB_CHAIN_ID, true, address(collateral));
        spoke = new Multichaindeploymentwithcrosschainsettlement(SPOKE_CHAIN_ID, false, address(collateral));

        hub.setRelayer(relayer, true);
        spoke.setRelayer(relayer, true);

        hub.registerChain(SPOKE_CHAIN_ID, address(spoke));
        spoke.registerChain(HUB_CHAIN_ID, address(hub));

        // Mint large supply to alice
        collateral.mint(alice, type(uint128).max);

        vm.prank(alice);
        collateral.approve(address(hub), type(uint256).max);
        vm.prank(alice);
        collateral.approve(address(spoke), type(uint256).max);

        // Advance past sync interval
        vm.warp(block.timestamp + hub.MIN_SYNC_INTERVAL() + 1);
    }

    // =========================================================================
    // Collateral Invariants
    // =========================================================================

    /// @notice Locked collateral always matches contract balance after deposits
    function testFuzz_lockCollateral_balanceTracking(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);

        uint256 balanceBefore = collateral.balanceOf(address(hub));

        vm.prank(alice);
        hub.lockCollateral(1, amount);

        uint256 balanceAfter = collateral.balanceOf(address(hub));
        assertEq(balanceAfter - balanceBefore, amount, "Balance should increase by locked amount");
        assertEq(hub.totalLocalCollateral(), amount, "Total local collateral tracking mismatch");
    }

    /// @notice Multiple deposits to same series are additive
    function testFuzz_lockCollateral_additive(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 500_000e18);
        amount2 = bound(amount2, 1, 500_000e18);

        vm.startPrank(alice);
        hub.lockCollateral(1, amount1);
        hub.lockCollateral(1, amount2);
        vm.stopPrank();

        assertEq(hub.totalLocalCollateral(), amount1 + amount2, "Deposits should be additive");

        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos = hub.getAggregatedPosition(1);
        assertEq(pos.totalCollateralAcrossChains, amount1 + amount2, "Aggregated collateral mismatch");
    }

    /// @notice Collateral deposits across different series are independent
    function testFuzz_lockCollateral_seriesIndependence(
        uint256 amount1,
        uint256 amount2,
        uint256 seriesId1,
        uint256 seriesId2
    ) public {
        amount1 = bound(amount1, 1, 500_000e18);
        amount2 = bound(amount2, 1, 500_000e18);
        seriesId1 = bound(seriesId1, 1, 1000);
        seriesId2 = bound(seriesId2, 1001, 2000);

        vm.startPrank(alice);
        hub.lockCollateral(seriesId1, amount1);
        hub.lockCollateral(seriesId2, amount2);
        vm.stopPrank();

        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos1 =
            hub.getAggregatedPosition(seriesId1);
        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos2 =
            hub.getAggregatedPosition(seriesId2);

        assertEq(pos1.totalCollateralAcrossChains, amount1, "Series 1 collateral mismatch");
        assertEq(pos2.totalCollateralAcrossChains, amount2, "Series 2 collateral mismatch");
        assertEq(hub.totalLocalCollateral(), amount1 + amount2, "Total collateral mismatch");
    }

    // =========================================================================
    // Position Sync Invariants
    // =========================================================================

    /// @notice Synced position values are preserved correctly
    function testFuzz_syncPosition_valuesPreserved(uint256 longAmount, uint256 shortAmount) public {
        longAmount = bound(longAmount, 0, 1_000_000e18);
        shortAmount = bound(shortAmount, 0, 1_000_000e18);

        vm.prank(relayer);
        hub.syncPosition(1, longAmount, shortAmount);

        Multichaindeploymentwithcrosschainsettlement.ChainPositionSnapshot memory snapshot =
            hub.getChainSnapshot(1, HUB_CHAIN_ID);
        assertEq(snapshot.longAmount, longAmount, "Long amount not preserved");
        assertEq(snapshot.shortAmount, shortAmount, "Short amount not preserved");
    }

    /// @notice Aggregation sums positions across chains correctly
    function testFuzz_receivePositionSync_aggregation(
        uint256 hubLong,
        uint256 hubShort,
        uint256 spokeLong,
        uint256 spokeShort
    ) public {
        hubLong = bound(hubLong, 0, 500_000e18);
        hubShort = bound(hubShort, 0, 500_000e18);
        spokeLong = bound(spokeLong, 0, 500_000e18);
        spokeShort = bound(spokeShort, 0, 500_000e18);

        // Sync hub's own position
        vm.prank(relayer);
        hub.syncPosition(1, hubLong, hubShort);

        // Receive spoke position
        vm.prank(relayer);
        hub.receivePositionSync(SPOKE_CHAIN_ID, 1, spokeLong, spokeShort, 0);

        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos = hub.getAggregatedPosition(1);
        assertEq(pos.totalLongAcrossChains, hubLong + spokeLong, "Aggregated longs mismatch");
        assertEq(pos.totalShortAcrossChains, hubShort + spokeShort, "Aggregated shorts mismatch");
    }

    // =========================================================================
    // Settlement Invariants
    // =========================================================================

    /// @notice Balanced positions (long == short on same chain) produce zero net settlement delta
    function testFuzz_settlement_balancedPositionsZeroDelta(uint256 positionSize, int256 settlementPrice) public {
        positionSize = bound(positionSize, 1e18, 100_000e18);
        settlementPrice = bound(settlementPrice, 1e18, 100_000e18);

        vm.prank(alice);
        hub.lockCollateral(1, positionSize * 10);

        vm.prank(relayer);
        hub.syncPosition(1, positionSize, positionSize);

        hub.initiateSettlement(1, settlementPrice, 3000e18, true);

        int256 delta = hub.getSettlementDelta(1, HUB_CHAIN_ID);
        assertEq(delta, 0, "Balanced positions should have zero delta");
    }

    /// @notice Settlement marks the series as settled
    function testFuzz_settlement_marksSettled(int256 settlementPrice, bool isCall) public {
        settlementPrice = bound(settlementPrice, 1e18, 100_000e18);

        vm.prank(alice);
        hub.lockCollateral(1, 1_000_000e18);

        vm.prank(relayer);
        hub.syncPosition(1, 100e18, 100e18);

        hub.initiateSettlement(1, settlementPrice, 3000e18, isCall);

        Multichaindeploymentwithcrosschainsettlement.AggregatedPosition memory pos = hub.getAggregatedPosition(1);
        assertTrue(pos.isSettled, "Series should be settled");
    }

    /// @notice Cannot lock collateral after settlement
    function testFuzz_settlement_preventsNewLocks(uint256 lockAmount, int256 settlementPrice) public {
        lockAmount = bound(lockAmount, 1, 1_000_000e18);
        settlementPrice = bound(settlementPrice, 1e18, 100_000e18);

        vm.prank(alice);
        hub.lockCollateral(1, 100e18);

        vm.prank(relayer);
        hub.syncPosition(1, 10e18, 10e18);

        hub.initiateSettlement(1, settlementPrice, 3000e18, true);

        vm.prank(alice);
        vm.expectRevert();
        hub.lockCollateral(1, lockAmount);
    }

    // =========================================================================
    // Rebalance Invariants
    // =========================================================================

    /// @notice Rebalance IDs are always unique and incrementing
    function testFuzz_rebalance_idIncrement(uint8 count) public {
        count = uint8(bound(count, 1, 20));

        uint256 lastId = 0;
        for (uint8 i = 0; i < count; i++) {
            uint256 id = hub.requestRebalance(HUB_CHAIN_ID, SPOKE_CHAIN_ID, 100e18 + uint256(i));
            assertGt(id, lastId, "ID should always increment");
            lastId = id;
        }
    }

    /// @notice Rebalance amount is preserved
    function testFuzz_rebalance_amountPreserved(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);

        uint256 rebalanceId = hub.requestRebalance(HUB_CHAIN_ID, SPOKE_CHAIN_ID, amount);

        Multichaindeploymentwithcrosschainsettlement.RebalanceRequest memory req = hub.getRebalanceRequest(rebalanceId);
        assertEq(req.amount, amount, "Rebalance amount not preserved");
        assertEq(req.fromChainId, HUB_CHAIN_ID, "From chain mismatch");
        assertEq(req.toChainId, SPOKE_CHAIN_ID, "To chain mismatch");
        assertFalse(req.executed, "Should not be executed yet");
    }

    // =========================================================================
    // Message Nonce Invariants
    // =========================================================================

    /// @notice Message nonce increments with each message sent
    function testFuzz_messageNonce_increment(uint8 count) public {
        count = uint8(bound(count, 1, 20));

        uint256 initialNonce = spoke.messageNonce();

        for (uint8 i = 0; i < count; i++) {
            vm.prank(alice);
            spoke.lockCollateral(uint256(i) + 1, 1e18);
        }

        uint256 finalNonce = spoke.messageNonce();
        assertEq(finalNonce, initialNonce + count, "Nonce should increment by message count");
    }

    /// @notice Chain registration count never exceeds MAX_CHAINS
    function testFuzz_chainRegistration_bounded(uint8 count) public {
        count = uint8(bound(count, 1, 35));

        uint256 registered = 0;
        for (uint8 i = 0; i < count; i++) {
            uint64 chainId = uint64(100 + i);
            if (hub.getRegisteredChainCount() < hub.MAX_CHAINS()) {
                hub.registerChain(chainId, address(uint160(0xDEAD + i)));
                registered++;
            } else {
                vm.expectRevert();
                hub.registerChain(chainId, address(uint160(0xDEAD + i)));
            }
        }

        assertLe(hub.getRegisteredChainCount(), hub.MAX_CHAINS(), "Should never exceed MAX_CHAINS");
    }
}
