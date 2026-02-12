// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { OptionVault } from "../../src/core/OptionVault.sol";
import { OptionLens } from "../../src/core/OptionLens.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";

/// @title OptionLensFuzzTest
/// @notice Fuzz tests for OptionLens invariants
contract OptionLensFuzzTest is Test {
    OptionVault public vault;
    OptionLens public lens;
    ERC20Mock public underlying;
    ERC20Mock public collateral;

    address public alice = address(0x1);

    function setUp() public {
        vault = new OptionVault();
        lens = new OptionLens(address(vault));
        underlying = new ERC20Mock("Wrapped ETH", "WETH", 18);
        collateral = new ERC20Mock("USD Coin", "USDC", 18);

        collateral.mint(alice, type(uint128).max);

        vm.prank(alice);
        collateral.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // getSeriesData Invariants
    // =========================================================================

    /// @notice getSeriesData always returns consistent data matching vault state
    function testFuzz_getSeriesData_matchesVault(int256 strike, bool isCall) public {
        strike = bound(strike, 100e18, 100_000e18);
        uint64 expiry = uint64(block.timestamp + 30 days);

        uint256 seriesId = vault.createSeries(
            OptionVault.OptionSeries({
                underlying: address(underlying),
                collateral: address(collateral),
                strike: strike,
                expiry: expiry,
                isCall: isCall
            })
        );

        OptionLens.OptionData memory data = lens.getSeriesData(seriesId);

        assertEq(data.seriesId, seriesId, "seriesId mismatch");
        assertEq(data.underlying, address(underlying), "underlying mismatch");
        assertEq(data.strike, strike, "strike mismatch");
        assertEq(data.expiry, expiry, "expiry mismatch");
        assertEq(data.isCall, isCall, "isCall mismatch");
        assertEq(uint256(data.state), uint256(OptionVault.SeriesState.ACTIVE), "state mismatch");
        assertFalse(data.isExpired, "should not be expired");
        assertGt(data.timeToExpiry, 0, "should have time to expiry");
    }

    /// @notice timeToExpiry in OptionData matches vault.timeToExpiry
    function testFuzz_getSeriesData_timeToExpiryConsistent(uint64 expiryOffset, uint64 warpOffset) public {
        expiryOffset = uint64(bound(expiryOffset, 2 hours, 365 days));
        warpOffset = uint64(bound(warpOffset, 0, 400 days));

        uint64 expiry = uint64(block.timestamp) + expiryOffset;
        uint256 seriesId = vault.createSeries(
            OptionVault.OptionSeries({
                underlying: address(underlying),
                collateral: address(collateral),
                strike: 3000e18,
                expiry: expiry,
                isCall: true
            })
        );

        vm.warp(block.timestamp + warpOffset);

        OptionLens.OptionData memory data = lens.getSeriesData(seriesId);
        uint256 vaultTTE = vault.timeToExpiry(seriesId);

        assertEq(data.timeToExpiry, vaultTTE, "timeToExpiry mismatch");
        assertEq(data.isExpired, vault.isExpired(seriesId), "isExpired mismatch");
    }

    // =========================================================================
    // getAccountPositions Invariants
    // =========================================================================

    /// @notice getAccountPositions returns exactly the positions that have non-zero amounts
    function testFuzz_getAccountPositions_correctCount(uint256 mintAmount) public {
        mintAmount = bound(mintAmount, 1, 1000e18);
        uint64 expiry = uint64(block.timestamp + 30 days);

        uint256 s1 = vault.createSeries(_createConfig(3000e18, expiry, false));
        uint256 s2 = vault.createSeries(_createConfig(4000e18, expiry, true));
        // s3 is created but alice doesn't mint in it
        vault.createSeries(_createConfig(5000e18, expiry, false));

        vm.startPrank(alice);
        vault.mint(s1, mintAmount);
        vault.mint(s2, mintAmount);
        vm.stopPrank();

        OptionLens.AccountPosition[] memory positions = lens.getAccountPositions(alice);
        assertEq(positions.length, 2, "should have exactly 2 positions");

        // Verify amounts match
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].longAmount, mintAmount, "longAmount mismatch");
            assertEq(positions[i].shortAmount, mintAmount, "shortAmount mismatch");
        }
    }

    /// @notice Positions returned match individual getPosition calls from vault
    function testFuzz_getAccountPositions_matchVault(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 500e18);
        amount2 = bound(amount2, 1, 500e18);
        uint64 expiry = uint64(block.timestamp + 30 days);

        uint256 s1 = vault.createSeries(_createConfig(3000e18, expiry, false));
        uint256 s2 = vault.createSeries(_createConfig(4000e18, expiry, false));

        vm.startPrank(alice);
        vault.mint(s1, amount1);
        vault.mint(s2, amount2);
        vm.stopPrank();

        OptionLens.AccountPosition[] memory positions = lens.getAccountPositions(alice);

        for (uint256 i = 0; i < positions.length; i++) {
            OptionVault.Position memory vaultPos = vault.getPosition(positions[i].seriesId, alice);
            assertEq(positions[i].longAmount, vaultPos.longAmount, "long mismatch");
            assertEq(positions[i].shortAmount, vaultPos.shortAmount, "short mismatch");
            assertEq(positions[i].hasClaimed, vaultPos.hasClaimed, "hasClaimed mismatch");
        }
    }

    // =========================================================================
    // getPoolStats Invariants
    // =========================================================================

    /// @notice totalSeries always equals nextSeriesId - 1
    function testFuzz_getPoolStats_totalSeriesCount(uint8 count) public {
        count = uint8(bound(count, 1, 20));
        uint64 expiry = uint64(block.timestamp + 30 days);

        for (uint8 i = 0; i < count; i++) {
            vault.createSeries(_createConfig(int256(uint256(3000e18) + uint256(i) * 100e18), expiry, true));
        }

        OptionLens.PoolStats memory stats = lens.getPoolStats();
        assertEq(stats.totalSeries, count, "totalSeries mismatch");
        assertEq(stats.activeSeries + stats.expiredSeries + stats.settledSeries, count, "state counts don't sum");
    }

    /// @notice Total minted across pool stats matches sum of individual series
    function testFuzz_getPoolStats_totalMintedConsistent(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1e18, 100e18);
        amount2 = bound(amount2, 1e18, 100e18);
        uint64 expiry = uint64(block.timestamp + 30 days);

        uint256 s1 = vault.createSeries(_createConfig(3000e18, expiry, false));
        uint256 s2 = vault.createSeries(_createConfig(4000e18, expiry, false));

        vm.startPrank(alice);
        vault.mint(s1, amount1);
        vault.mint(s2, amount2);
        vm.stopPrank();

        OptionLens.PoolStats memory stats = lens.getPoolStats();
        assertEq(stats.totalMintedAllSeries, amount1 + amount2, "totalMinted mismatch");

        // Verify collateral is tracked
        OptionVault.SeriesData memory d1 = vault.getSeries(s1);
        OptionVault.SeriesData memory d2 = vault.getSeries(s2);
        assertEq(stats.totalCollateralLocked, d1.collateralLocked + d2.collateralLocked, "collateral mismatch");
    }

    // =========================================================================
    // quoteOption Invariants
    // =========================================================================

    /// @notice Call intrinsic value = max(spot - strike, 0)
    function testFuzz_quoteOption_callIntrinsicValue(int256 spotPrice) public {
        spotPrice = bound(spotPrice, 1e18, 100_000e18);
        uint64 expiry = uint64(block.timestamp + 30 days);
        uint256 seriesId = vault.createSeries(_createConfig(3000e18, expiry, true));

        OptionLens.Quote memory q = lens.quoteOption(seriesId, 1e18, spotPrice);

        if (spotPrice > 3000e18) {
            assertEq(q.intrinsicValue, spotPrice - 3000e18, "ITM call intrinsic wrong");
        } else {
            assertEq(q.intrinsicValue, 0, "OTM call intrinsic should be 0");
        }
    }

    /// @notice Put intrinsic value = max(strike - spot, 0)
    function testFuzz_quoteOption_putIntrinsicValue(int256 spotPrice) public {
        spotPrice = bound(spotPrice, 1e18, 100_000e18);
        uint64 expiry = uint64(block.timestamp + 30 days);
        uint256 seriesId = vault.createSeries(_createConfig(3000e18, expiry, false));

        OptionLens.Quote memory q = lens.quoteOption(seriesId, 1e18, spotPrice);

        if (3000e18 > spotPrice) {
            assertEq(q.intrinsicValue, 3000e18 - spotPrice, "ITM put intrinsic wrong");
        } else {
            assertEq(q.intrinsicValue, 0, "OTM put intrinsic should be 0");
        }
    }

    /// @notice Collateral in quote matches vault.calculateCollateral
    function testFuzz_quoteOption_collateralMatchesVault(uint256 amount, int256 strike) public {
        amount = bound(amount, 1, 1000e18);
        strike = bound(strike, 100e18, 100_000e18);
        uint64 expiry = uint64(block.timestamp + 30 days);
        uint256 seriesId = vault.createSeries(_createConfig(strike, expiry, false));

        OptionLens.Quote memory q = lens.quoteOption(seriesId, amount, 3000e18);
        uint256 vaultCollateral = vault.calculateCollateral(seriesId, amount);

        assertEq(q.collateralRequired, vaultCollateral, "collateral mismatch with vault");
    }

    // =========================================================================
    // getOptionChain Invariants
    // =========================================================================

    /// @notice getOptionChain returns only series matching the filter
    function testFuzz_getOptionChain_filterAccuracy(uint8 matchCount, uint8 noMatchCount) public {
        matchCount = uint8(bound(matchCount, 1, 10));
        noMatchCount = uint8(bound(noMatchCount, 0, 10));

        uint64 targetExpiry = uint64(block.timestamp + 30 days);
        uint64 otherExpiry = uint64(block.timestamp + 60 days);

        for (uint8 i = 0; i < matchCount; i++) {
            vault.createSeries(_createConfig(int256(uint256(3000e18) + uint256(i) * 100e18), targetExpiry, true));
        }
        for (uint8 i = 0; i < noMatchCount; i++) {
            vault.createSeries(_createConfig(int256(uint256(3000e18) + uint256(i) * 100e18), otherExpiry, false));
        }

        OptionLens.OptionData[] memory chain = lens.getOptionChain(address(underlying), targetExpiry);
        assertEq(chain.length, matchCount, "filter count mismatch");

        // Verify every result matches filter
        for (uint256 i = 0; i < chain.length; i++) {
            assertEq(chain[i].underlying, address(underlying), "underlying mismatch in result");
            assertEq(chain[i].expiry, targetExpiry, "expiry mismatch in result");
        }
    }

    // =========================================================================
    // isITM / getIntrinsicValue Invariants
    // =========================================================================

    /// @notice isITM and intrinsicValue are consistent: ITM ⟺ intrinsic > 0
    function testFuzz_isITM_intrinsicValueConsistent(int256 spotPrice, bool isCall) public {
        spotPrice = bound(spotPrice, 1e18, 100_000e18);
        uint64 expiry = uint64(block.timestamp + 30 days);
        uint256 seriesId = vault.createSeries(_createConfig(3000e18, expiry, isCall));

        bool itm = lens.isITM(seriesId, spotPrice);
        int256 intrinsic = lens.getIntrinsicValue(seriesId, spotPrice);

        if (itm) {
            assertGt(intrinsic, 0, "ITM should have positive intrinsic");
        } else {
            assertEq(intrinsic, 0, "OTM should have zero intrinsic");
        }
    }

    /// @notice Moneyness > 1 ⟺ call is ITM; moneyness < 1 ⟺ put is ITM
    function testFuzz_moneyness_itmConsistency(int256 spotPrice) public {
        spotPrice = bound(spotPrice, 1e18, 100_000e18);
        uint64 expiry = uint64(block.timestamp + 30 days);

        uint256 callId = vault.createSeries(_createConfig(3000e18, expiry, true));
        uint256 putId = vault.createSeries(_createConfig(3000e18, expiry, false));

        int256 ratio = lens.getMoneyness(callId, spotPrice);
        bool callITM = lens.isITM(callId, spotPrice);
        bool putITM = lens.isITM(putId, spotPrice);

        if (ratio > 1e18) {
            assertTrue(callITM, "moneyness > 1 means call ITM");
        }
        if (ratio < 1e18) {
            assertTrue(putITM, "moneyness < 1 means put ITM");
        }
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _createConfig(int256 strike, uint64 expiry, bool isCall)
        internal
        view
        returns (OptionVault.OptionSeries memory)
    {
        return OptionVault.OptionSeries({
            underlying: address(underlying),
            collateral: address(collateral),
            strike: strike,
            expiry: expiry,
            isCall: isCall
        });
    }
}
