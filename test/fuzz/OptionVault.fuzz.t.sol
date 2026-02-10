// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { OptionVault } from "../../src/core/OptionVault.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";

/// @title OptionVaultFuzzTest
/// @notice Fuzz tests for OptionVault invariants
contract OptionVaultFuzzTest is Test {
    OptionVault public vault;
    ERC20Mock public underlying;
    ERC20Mock public collateral;

    address public alice = address(0x1);

    function setUp() public {
        vault = new OptionVault();
        underlying = new ERC20Mock("Wrapped ETH", "WETH", 18);
        collateral = new ERC20Mock("USD Coin", "USDC", 18);

        // Mint large amounts to alice
        collateral.mint(alice, type(uint128).max);

        vm.prank(alice);
        collateral.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // Series Creation Fuzz Tests
    // =========================================================================

    /// @notice Series ID always increments
    function testFuzz_createSeries_idIncrement(uint8 count) public {
        count = uint8(bound(count, 1, 50));

        uint256 lastId = 0;
        for (uint8 i = 0; i < count; i++) {
            OptionVault.OptionSeries memory config = _createConfig(int256(3000e18 + uint256(i) * 100e18), true);
            uint256 id = vault.createSeries(config);
            assertGt(id, lastId, "ID should always increment");
            lastId = id;
        }
    }

    /// @notice Strike price is preserved correctly
    function testFuzz_createSeries_strikePreserved(int256 strike) public {
        strike = bound(strike, 1, type(int128).max);

        OptionVault.OptionSeries memory config = _createConfig(strike, true);
        uint256 seriesId = vault.createSeries(config);

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        assertEq(data.config.strike, strike, "Strike not preserved");
    }

    // =========================================================================
    // Minting Fuzz Tests
    // =========================================================================

    /// @notice Minted amount is tracked correctly
    function testFuzz_mint_amountTracked(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        uint256 seriesId = vault.createSeries(_createConfig(3000e18, false));

        vm.prank(alice);
        vault.mint(seriesId, amount);

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        assertEq(data.totalMinted, amount, "Minted amount not tracked");

        OptionVault.Position memory pos = vault.getPosition(seriesId, alice);
        assertEq(pos.longAmount, amount, "Long position not tracked");
        assertEq(pos.shortAmount, amount, "Short position not tracked");
    }

    /// @notice Collateral calculation is correct for puts
    function testFuzz_mint_putCollateral(int256 strike, uint256 amount) public {
        strike = bound(strike, 100e18, 100000e18);
        amount = bound(amount, 1e18, 100e18);

        uint256 seriesId = vault.createSeries(_createConfig(strike, false));
        uint256 expectedCollateral = (uint256(strike) * amount) / 1e18;

        uint256 calculated = vault.calculateCollateral(seriesId, amount);
        assertEq(calculated, expectedCollateral, "Collateral calculation wrong");
    }

    /// @notice Total minted equals sum of individual mints
    function testFuzz_mint_totalEqualsSum(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 100e18);
        amount2 = bound(amount2, 1, 100e18);

        uint256 seriesId = vault.createSeries(_createConfig(3000e18, false));

        vm.startPrank(alice);
        vault.mint(seriesId, amount1);
        vault.mint(seriesId, amount2);
        vm.stopPrank();

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        assertEq(data.totalMinted, amount1 + amount2, "Total doesn't match sum");
    }

    // =========================================================================
    // Expiry Fuzz Tests
    // =========================================================================

    /// @notice Time to expiry is calculated correctly
    function testFuzz_timeToExpiry_correct(uint64 expiryOffset) public {
        expiryOffset = uint64(bound(expiryOffset, 2 hours, 365 days));

        uint64 expiry = uint64(block.timestamp) + expiryOffset;
        OptionVault.OptionSeries memory config = OptionVault.OptionSeries({
            underlying: address(underlying),
            collateral: address(collateral),
            strike: 3000e18,
            expiry: expiry,
            isCall: true
        });

        uint256 seriesId = vault.createSeries(config);
        uint256 tte = vault.timeToExpiry(seriesId);

        assertApproxEqAbs(tte, expiryOffset, 1, "Time to expiry incorrect");
    }

    /// @notice isExpired changes at expiry boundary
    function testFuzz_isExpired_boundary(uint64 expiryOffset, uint64 warpOffset) public {
        expiryOffset = uint64(bound(expiryOffset, 2 hours, 30 days));
        warpOffset = uint64(bound(warpOffset, 0, 60 days));

        uint64 expiry = uint64(block.timestamp) + expiryOffset;
        OptionVault.OptionSeries memory config = OptionVault.OptionSeries({
            underlying: address(underlying),
            collateral: address(collateral),
            strike: 3000e18,
            expiry: expiry,
            isCall: true
        });

        uint256 seriesId = vault.createSeries(config);

        vm.warp(block.timestamp + warpOffset);

        bool expired = vault.isExpired(seriesId);
        bool shouldBeExpired = block.timestamp >= expiry;

        assertEq(expired, shouldBeExpired, "isExpired mismatch");
    }

    // =========================================================================
    // Invariant Tests
    // =========================================================================

    /// @notice Collateral locked <= total collateral transferred
    function testFuzz_invariant_collateralConsistency(uint256 amount) public {
        amount = bound(amount, 1e18, 100e18);

        uint256 seriesId = vault.createSeries(_createConfig(3000e18, false));

        uint256 balanceBefore = collateral.balanceOf(address(vault));

        vm.prank(alice);
        vault.mint(seriesId, amount);

        uint256 balanceAfter = collateral.balanceOf(address(vault));
        OptionVault.SeriesData memory data = vault.getSeries(seriesId);

        assertEq(data.collateralLocked, balanceAfter - balanceBefore, "Collateral tracking mismatch");
    }

    /// @notice Position amounts are always non-negative
    function testFuzz_invariant_positionNonNegative(uint256 mintAmount) public {
        mintAmount = bound(mintAmount, 1, 1000e18);

        uint256 seriesId = vault.createSeries(_createConfig(3000e18, false));

        vm.prank(alice);
        vault.mint(seriesId, mintAmount);

        OptionVault.Position memory pos = vault.getPosition(seriesId, alice);
        assertGe(pos.longAmount, 0, "Long amount negative");
        assertGe(pos.shortAmount, 0, "Short amount negative");
    }

    /// @notice Series state transitions are valid
    function testFuzz_invariant_stateTransition(uint256 mintAmount) public {
        mintAmount = bound(mintAmount, 1e18, 100e18);

        uint256 seriesId = vault.createSeries(_createConfig(3000e18, false));

        // Initially ACTIVE
        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        assertEq(uint256(data.state), uint256(OptionVault.SeriesState.ACTIVE));

        vm.prank(alice);
        vault.mint(seriesId, mintAmount);

        // Warp past expiry + grace period
        vm.warp(block.timestamp + 31 days);

        vault.settle(seriesId);

        // After settlement, should be SETTLED
        data = vault.getSeries(seriesId);
        assertEq(uint256(data.state), uint256(OptionVault.SeriesState.SETTLED));
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _createConfig(int256 strike, bool isCall) internal view returns (OptionVault.OptionSeries memory) {
        return OptionVault.OptionSeries({
            underlying: address(underlying),
            collateral: address(collateral),
            strike: strike,
            expiry: uint64(block.timestamp + 30 days),
            isCall: isCall
        });
    }
}
