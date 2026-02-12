// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { OptionVault } from "../../src/core/OptionVault.sol";
import { OptionLens } from "../../src/core/OptionLens.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";

/// @title OptionLensTest
/// @notice Unit tests for the OptionLens read-only view contract
contract OptionLensTest is Test {
    OptionVault public vault;
    OptionLens public lens;
    ERC20Mock public underlying;
    ERC20Mock public underlying2;
    ERC20Mock public collateral;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);

    int256 public constant STRIKE = 3000e18;
    int256 public constant STRIKE_2 = 4000e18;
    uint64 public constant EXPIRY_OFFSET = 30 days;

    function setUp() public {
        vault = new OptionVault();
        lens = new OptionLens(address(vault));
        underlying = new ERC20Mock("Wrapped ETH", "WETH", 18);
        underlying2 = new ERC20Mock("Wrapped BTC", "WBTC", 18);
        collateral = new ERC20Mock("USD Coin", "USDC", 18);

        // Mint tokens to users
        collateral.mint(alice, 10_000_000e18);
        collateral.mint(bob, 10_000_000e18);

        // Approve vault
        vm.prank(alice);
        collateral.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        collateral.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_setsVault() public view {
        assertEq(address(lens.vault()), address(vault));
    }

    function test_constructor_revertZeroAddress() public {
        vm.expectRevert(OptionLens.OptionLens__ZeroAddress.selector);
        new OptionLens(address(0));
    }

    // =========================================================================
    // getOptionChain Tests
    // =========================================================================

    function test_getOptionChain_emptyVault() public view {
        OptionLens.OptionData[] memory chain =
            lens.getOptionChain(address(underlying), uint64(block.timestamp + EXPIRY_OFFSET));
        assertEq(chain.length, 0);
    }

    function test_getOptionChain_filtersByUnderlying() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        // Create series with underlying1
        vault.createSeries(_config(address(underlying), STRIKE, expiry, true));
        // Create series with underlying2
        vault.createSeries(_config(address(underlying2), STRIKE, expiry, true));

        OptionLens.OptionData[] memory chain = lens.getOptionChain(address(underlying), expiry);
        assertEq(chain.length, 1);
        assertEq(chain[0].underlying, address(underlying));
    }

    function test_getOptionChain_filtersByExpiry() public {
        uint64 expiry1 = uint64(block.timestamp + EXPIRY_OFFSET);
        uint64 expiry2 = uint64(block.timestamp + 60 days);

        vault.createSeries(_config(address(underlying), STRIKE, expiry1, true));
        vault.createSeries(_config(address(underlying), STRIKE, expiry2, true));

        OptionLens.OptionData[] memory chain = lens.getOptionChain(address(underlying), expiry1);
        assertEq(chain.length, 1);
        assertEq(chain[0].expiry, expiry1);
    }

    function test_getOptionChain_multipleMatches() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);

        // Create call and put at same expiry for same underlying
        vault.createSeries(_config(address(underlying), STRIKE, expiry, true));
        vault.createSeries(_config(address(underlying), STRIKE_2, expiry, false));
        vault.createSeries(_config(address(underlying), STRIKE, expiry, false));

        OptionLens.OptionData[] memory chain = lens.getOptionChain(address(underlying), expiry);
        assertEq(chain.length, 3);
    }

    function test_getOptionChain_returnsCorrectData() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        // Mint some options
        vm.prank(alice);
        vault.mint(seriesId, 5e18);

        OptionLens.OptionData[] memory chain = lens.getOptionChain(address(underlying), expiry);
        assertEq(chain.length, 1);
        assertEq(chain[0].seriesId, seriesId);
        assertEq(chain[0].strike, STRIKE);
        assertTrue(chain[0].isCall);
        assertEq(chain[0].totalMinted, 5e18);
        assertFalse(chain[0].isExpired);
        assertEq(uint256(chain[0].state), uint256(OptionVault.SeriesState.ACTIVE));
    }

    function test_getOptionChain_noMatchReturnsEmpty() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        // Query for a different underlying
        OptionLens.OptionData[] memory chain = lens.getOptionChain(address(underlying2), expiry);
        assertEq(chain.length, 0);
    }

    // =========================================================================
    // getAllSeries Tests
    // =========================================================================

    function test_getAllSeries_emptyVault() public view {
        OptionLens.OptionData[] memory all = lens.getAllSeries();
        assertEq(all.length, 0);
    }

    function test_getAllSeries_returnAll() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        vault.createSeries(_config(address(underlying), STRIKE, expiry, true));
        vault.createSeries(_config(address(underlying2), STRIKE_2, expiry, false));

        OptionLens.OptionData[] memory all = lens.getAllSeries();
        assertEq(all.length, 2);
        assertEq(all[0].seriesId, 1);
        assertEq(all[1].seriesId, 2);
    }

    // =========================================================================
    // getAccountPositions Tests
    // =========================================================================

    function test_getAccountPositions_emptyVault() public view {
        OptionLens.AccountPosition[] memory positions = lens.getAccountPositions(alice);
        assertEq(positions.length, 0);
    }

    function test_getAccountPositions_noPositions() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        // Carol never minted
        OptionLens.AccountPosition[] memory positions = lens.getAccountPositions(carol);
        assertEq(positions.length, 0);
    }

    function test_getAccountPositions_singlePosition() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, false));

        vm.prank(alice);
        vault.mint(seriesId, 10e18);

        OptionLens.AccountPosition[] memory positions = lens.getAccountPositions(alice);
        assertEq(positions.length, 1);
        assertEq(positions[0].seriesId, seriesId);
        assertEq(positions[0].longAmount, 10e18);
        assertEq(positions[0].shortAmount, 10e18);
        assertFalse(positions[0].hasClaimed);
        assertEq(positions[0].strike, STRIKE);
    }

    function test_getAccountPositions_multiplePositions() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 s1 = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));
        uint256 s2 = vault.createSeries(_config(address(underlying), STRIKE_2, expiry, false));

        vm.startPrank(alice);
        vault.mint(s1, 5e18);
        vault.mint(s2, 3e18);
        vm.stopPrank();

        OptionLens.AccountPosition[] memory positions = lens.getAccountPositions(alice);
        assertEq(positions.length, 2);
        assertEq(positions[0].longAmount, 5e18);
        assertEq(positions[1].longAmount, 3e18);
    }

    function test_getAccountPositions_differentUsers() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 s1 = vault.createSeries(_config(address(underlying), STRIKE, expiry, false));

        vm.prank(alice);
        vault.mint(s1, 10e18);

        vm.prank(bob);
        vault.mint(s1, 7e18);

        OptionLens.AccountPosition[] memory alicePositions = lens.getAccountPositions(alice);
        OptionLens.AccountPosition[] memory bobPositions = lens.getAccountPositions(bob);

        assertEq(alicePositions.length, 1);
        assertEq(bobPositions.length, 1);
        assertEq(alicePositions[0].longAmount, 10e18);
        assertEq(bobPositions[0].longAmount, 7e18);
    }

    // =========================================================================
    // getPoolStats Tests
    // =========================================================================

    function test_getPoolStats_emptyVault() public view {
        OptionLens.PoolStats memory stats = lens.getPoolStats();
        assertEq(stats.totalSeries, 0);
        assertEq(stats.activeSeries, 0);
    }

    function test_getPoolStats_activeSeries() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        vault.createSeries(_config(address(underlying), STRIKE, expiry, true));
        vault.createSeries(_config(address(underlying), STRIKE_2, expiry, false));

        OptionLens.PoolStats memory stats = lens.getPoolStats();
        assertEq(stats.totalSeries, 2);
        assertEq(stats.activeSeries, 2);
        assertEq(stats.expiredSeries, 0);
        assertEq(stats.settledSeries, 0);
    }

    function test_getPoolStats_tracksCollateralAndMinted() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 s1 = vault.createSeries(_config(address(underlying), STRIKE, expiry, false));

        vm.prank(alice);
        vault.mint(s1, 10e18);

        OptionLens.PoolStats memory stats = lens.getPoolStats();
        assertEq(stats.totalMintedAllSeries, 10e18);
        assertGt(stats.totalCollateralLocked, 0);
    }

    function test_getPoolStats_settledSeries() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 s1 = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        vm.prank(alice);
        vault.mint(s1, 5e18);

        // Warp past expiry + grace period
        vm.warp(block.timestamp + EXPIRY_OFFSET + 25 hours);
        vault.settle(s1);

        OptionLens.PoolStats memory stats = lens.getPoolStats();
        assertEq(stats.settledSeries, 1);
        assertEq(stats.activeSeries, 0);
    }

    // =========================================================================
    // quoteOption Tests
    // =========================================================================

    function test_quoteOption_callITM() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        // Spot 3500 > Strike 3000 → ITM call
        OptionLens.Quote memory q = lens.quoteOption(seriesId, 10e18, 3500e18);

        assertEq(q.seriesId, seriesId);
        assertEq(q.amount, 10e18);
        assertGt(q.intrinsicValue, 0);
        // intrinsic = spot - strike = 500e18
        assertEq(q.intrinsicValue, 500e18);
        assertFalse(q.isExpired);
        assertGt(q.timeToExpiry, 0);
    }

    function test_quoteOption_callOTM() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        // Spot 2500 < Strike 3000 → OTM call
        OptionLens.Quote memory q = lens.quoteOption(seriesId, 10e18, 2500e18);

        assertEq(q.intrinsicValue, 0);
    }

    function test_quoteOption_putITM() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, false));

        // Spot 2500 < Strike 3000 → ITM put
        OptionLens.Quote memory q = lens.quoteOption(seriesId, 10e18, 2500e18);

        // intrinsic = strike - spot = 500e18
        assertEq(q.intrinsicValue, 500e18);
    }

    function test_quoteOption_collateralCalculation() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, false));

        uint256 amount = 10e18;
        OptionLens.Quote memory q = lens.quoteOption(seriesId, amount, 3000e18);

        // Put collateral: strike * amount / 1e18 = 3000e18 * 10e18 / 1e18 = 30000e18
        uint256 expectedCollateral = (uint256(STRIKE) * amount) / 1e18;
        assertEq(q.collateralRequired, expectedCollateral);
    }

    function test_quoteOption_revertZeroAmount() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        vm.expectRevert(OptionLens.OptionLens__InvalidAmount.selector);
        lens.quoteOption(seriesId, 0, 3000e18);
    }

    function test_quoteOption_revertInvalidSpotPrice() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        vm.expectRevert(OptionLens.OptionLens__InvalidSpotPrice.selector);
        lens.quoteOption(seriesId, 10e18, 0);

        vm.expectRevert(OptionLens.OptionLens__InvalidSpotPrice.selector);
        lens.quoteOption(seriesId, 10e18, -100e18);
    }

    function test_quoteOption_revertSeriesNotFound() public {
        vm.expectRevert(OptionVault.OptionVault__SeriesNotFound.selector);
        lens.quoteOption(999, 10e18, 3000e18);
    }

    // =========================================================================
    // getSeriesData Tests
    // =========================================================================

    function test_getSeriesData_returnsCorrectData() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        OptionLens.OptionData memory data = lens.getSeriesData(seriesId);

        assertEq(data.seriesId, seriesId);
        assertEq(data.underlying, address(underlying));
        assertEq(data.collateral, address(collateral));
        assertEq(data.strike, STRIKE);
        assertEq(data.expiry, expiry);
        assertTrue(data.isCall);
        assertEq(uint256(data.state), uint256(OptionVault.SeriesState.ACTIVE));
        assertFalse(data.isExpired);
        assertFalse(data.canExercise);
        assertGt(data.timeToExpiry, 0);
    }

    function test_getSeriesData_revertNonExistent() public {
        vm.expectRevert(OptionVault.OptionVault__SeriesNotFound.selector);
        lens.getSeriesData(999);
    }

    // =========================================================================
    // getAccountPosition Tests
    // =========================================================================

    function test_getAccountPosition_withPosition() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, false));

        vm.prank(alice);
        vault.mint(seriesId, 5e18);

        OptionLens.AccountPosition memory pos = lens.getAccountPosition(seriesId, alice);
        assertEq(pos.seriesId, seriesId);
        assertEq(pos.longAmount, 5e18);
        assertEq(pos.shortAmount, 5e18);
        assertFalse(pos.hasClaimed);
        assertEq(pos.strike, STRIKE);
        assertFalse(pos.isCall);
    }

    function test_getAccountPosition_emptyPosition() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        OptionLens.AccountPosition memory pos = lens.getAccountPosition(seriesId, carol);
        assertEq(pos.longAmount, 0);
        assertEq(pos.shortAmount, 0);
    }

    // =========================================================================
    // getIntrinsicValue Tests
    // =========================================================================

    function test_getIntrinsicValue_callITM() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        int256 value = lens.getIntrinsicValue(seriesId, 3500e18);
        assertEq(value, 500e18);
    }

    function test_getIntrinsicValue_callOTM() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        int256 value = lens.getIntrinsicValue(seriesId, 2500e18);
        assertEq(value, 0);
    }

    function test_getIntrinsicValue_putITM() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, false));

        int256 value = lens.getIntrinsicValue(seriesId, 2500e18);
        assertEq(value, 500e18);
    }

    function test_getIntrinsicValue_revertInvalidSpot() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        vm.expectRevert(OptionLens.OptionLens__InvalidSpotPrice.selector);
        lens.getIntrinsicValue(seriesId, 0);
    }

    // =========================================================================
    // isITM Tests
    // =========================================================================

    function test_isITM_callAboveStrike() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        assertTrue(lens.isITM(seriesId, 3500e18));
    }

    function test_isITM_callBelowStrike() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        assertFalse(lens.isITM(seriesId, 2500e18));
    }

    function test_isITM_putBelowStrike() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, false));

        assertTrue(lens.isITM(seriesId, 2500e18));
    }

    function test_isITM_revertInvalidSpot() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        vm.expectRevert(OptionLens.OptionLens__InvalidSpotPrice.selector);
        lens.isITM(seriesId, -100e18);
    }

    // =========================================================================
    // getMoneyness Tests
    // =========================================================================

    function test_getMoneyness_atTheMoney() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        int256 ratio = lens.getMoneyness(seriesId, 3000e18);
        // S/K = 3000/3000 = 1.0
        assertEq(ratio, 1e18);
    }

    function test_getMoneyness_ITM() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        int256 ratio = lens.getMoneyness(seriesId, 6000e18);
        // S/K = 6000/3000 = 2.0
        assertEq(ratio, 2e18);
    }

    function test_getMoneyness_revertInvalidSpot() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        vm.expectRevert(OptionLens.OptionLens__InvalidSpotPrice.selector);
        lens.getMoneyness(seriesId, 0);
    }

    // =========================================================================
    // Expiry-related View Tests
    // =========================================================================

    function test_getSeriesData_afterExpiry() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        // Warp past expiry
        vm.warp(block.timestamp + EXPIRY_OFFSET + 1);

        OptionLens.OptionData memory data = lens.getSeriesData(seriesId);
        assertTrue(data.isExpired);
        assertEq(data.timeToExpiry, 0);
    }

    function test_getSeriesData_canExerciseDuringGracePeriod() public {
        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        uint256 seriesId = vault.createSeries(_config(address(underlying), STRIKE, expiry, true));

        vm.prank(alice);
        vault.mint(seriesId, 5e18);

        // Warp to within grace period
        vm.warp(block.timestamp + EXPIRY_OFFSET + 1 hours);

        OptionLens.OptionData memory data = lens.getSeriesData(seriesId);
        assertTrue(data.canExercise);
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _config(address underlying_, int256 strike, uint64 expiry, bool isCall)
        internal
        view
        returns (OptionVault.OptionSeries memory)
    {
        return OptionVault.OptionSeries({
            underlying: underlying_, collateral: address(collateral), strike: strike, expiry: expiry, isCall: isCall
        });
    }
}
