// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { InvariantFuzzTestingWithFoundry } from "../../src/libraries/InvariantfuzztestingwithFoundry.sol";

/// @notice Wrapper contract to expose library functions for testing (including reverts)
contract InvariantFuzzWrapper {
    function checkSolvency(InvariantFuzzTestingWithFoundry.PoolState memory pool) external pure returns (bool) {
        return InvariantFuzzTestingWithFoundry.checkSolvency(pool);
    }

    function enforceSolvency(InvariantFuzzTestingWithFoundry.PoolState memory pool) external pure {
        InvariantFuzzTestingWithFoundry.enforceSolvency(pool);
    }

    function availableLiquidity(InvariantFuzzTestingWithFoundry.PoolState memory pool) external pure returns (SD59x18) {
        return InvariantFuzzTestingWithFoundry.availableLiquidity(pool);
    }

    function computeUtilization(InvariantFuzzTestingWithFoundry.PoolState memory pool) external pure returns (SD59x18) {
        return InvariantFuzzTestingWithFoundry.computeUtilization(pool);
    }

    function checkSupplyConsistency(InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot)
        external
        pure
        returns (bool)
    {
        return InvariantFuzzTestingWithFoundry.checkSupplyConsistency(snapshot);
    }

    function enforceSupplyConsistency(InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot) external pure {
        InvariantFuzzTestingWithFoundry.enforceSupplyConsistency(snapshot);
    }

    function buildSupplySnapshot(
        InvariantFuzzTestingWithFoundry.SeriesSupply[] memory seriesArray,
        uint256 vaultRecordedMinted,
        uint256 vaultRecordedExercised
    ) external pure returns (InvariantFuzzTestingWithFoundry.SupplySnapshot memory) {
        return InvariantFuzzTestingWithFoundry.buildSupplySnapshot(
                seriesArray, vaultRecordedMinted, vaultRecordedExercised
            );
    }

    function checkSeriesExerciseBound(InvariantFuzzTestingWithFoundry.SeriesSupply memory supply)
        external
        pure
        returns (bool)
    {
        return InvariantFuzzTestingWithFoundry.checkSeriesExerciseBound(supply);
    }

    function checkCdfBounds(SD59x18 x) external pure returns (bool) {
        return InvariantFuzzTestingWithFoundry.checkCdfBounds(x);
    }

    function enforceCdfBounds(SD59x18 x) external pure returns (SD59x18) {
        return InvariantFuzzTestingWithFoundry.enforceCdfBounds(x);
    }

    function checkCdfMonotonicity(SD59x18 a, SD59x18 b) external pure returns (bool) {
        return InvariantFuzzTestingWithFoundry.checkCdfMonotonicity(a, b);
    }

    function checkCdfSymmetry(SD59x18 x) external pure returns (bool) {
        return InvariantFuzzTestingWithFoundry.checkCdfSymmetry(x);
    }

    function applyDeposit(InvariantFuzzTestingWithFoundry.PoolState memory pool, SD59x18 amount)
        external
        pure
        returns (InvariantFuzzTestingWithFoundry.PoolState memory)
    {
        return InvariantFuzzTestingWithFoundry.applyDeposit(pool, amount);
    }

    function applyWithdrawal(InvariantFuzzTestingWithFoundry.PoolState memory pool, SD59x18 amount)
        external
        pure
        returns (InvariantFuzzTestingWithFoundry.PoolState memory)
    {
        return InvariantFuzzTestingWithFoundry.applyWithdrawal(pool, amount);
    }

    function applyMint(
        InvariantFuzzTestingWithFoundry.PoolState memory pool,
        SD59x18 collateralAmount,
        SD59x18 premiumReceived
    ) external pure returns (InvariantFuzzTestingWithFoundry.PoolState memory) {
        return InvariantFuzzTestingWithFoundry.applyMint(pool, collateralAmount, premiumReceived);
    }

    function applyExercise(
        InvariantFuzzTestingWithFoundry.PoolState memory pool,
        SD59x18 payoutAmount,
        SD59x18 collateralReleased
    ) external pure returns (InvariantFuzzTestingWithFoundry.PoolState memory) {
        return InvariantFuzzTestingWithFoundry.applyExercise(pool, payoutAmount, collateralReleased);
    }

    function applyExpiry(InvariantFuzzTestingWithFoundry.PoolState memory pool, SD59x18 collateralReleased)
        external
        pure
        returns (InvariantFuzzTestingWithFoundry.PoolState memory)
    {
        return InvariantFuzzTestingWithFoundry.applyExpiry(pool, collateralReleased);
    }

    function checkAllInvariants(
        InvariantFuzzTestingWithFoundry.PoolState memory pool,
        InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot,
        SD59x18 cdfInput
    ) external pure returns (InvariantFuzzTestingWithFoundry.InvariantCheckResult memory) {
        return InvariantFuzzTestingWithFoundry.checkAllInvariants(pool, snapshot, cdfInput);
    }

    function enforceAllInvariants(
        InvariantFuzzTestingWithFoundry.PoolState memory pool,
        InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot,
        SD59x18 cdfInput
    ) external pure {
        InvariantFuzzTestingWithFoundry.enforceAllInvariants(pool, snapshot, cdfInput);
    }

    function validatePoolState(InvariantFuzzTestingWithFoundry.PoolState memory pool) external pure {
        InvariantFuzzTestingWithFoundry.validatePoolState(pool);
    }

    function checkUtilizationBound(InvariantFuzzTestingWithFoundry.PoolState memory pool) external pure returns (bool) {
        return InvariantFuzzTestingWithFoundry.checkUtilizationBound(pool);
    }

    function enforceUtilizationBound(InvariantFuzzTestingWithFoundry.PoolState memory pool) external pure {
        InvariantFuzzTestingWithFoundry.enforceUtilizationBound(pool);
    }

    function emptyPool() external pure returns (InvariantFuzzTestingWithFoundry.PoolState memory) {
        return InvariantFuzzTestingWithFoundry.emptyPool();
    }

    function createPool(SD59x18 totalAssets, SD59x18 lockedCollateral, SD59x18 totalShares)
        external
        pure
        returns (InvariantFuzzTestingWithFoundry.PoolState memory)
    {
        return InvariantFuzzTestingWithFoundry.createPool(totalAssets, lockedCollateral, totalShares);
    }

    function createConsistentSnapshot(uint256 minted, uint256 exercised)
        external
        pure
        returns (InvariantFuzzTestingWithFoundry.SupplySnapshot memory)
    {
        return InvariantFuzzTestingWithFoundry.createConsistentSnapshot(minted, exercised);
    }
}

/// @title InvariantfuzztestingwithFoundryTest
/// @notice Unit tests for InvariantFuzzTestingWithFoundry library
contract InvariantfuzztestingwithFoundryTest is Test {
    InvariantFuzzWrapper internal wrapper;

    SD59x18 internal constant ASSETS_1000 = SD59x18.wrap(1000e18);
    SD59x18 internal constant ASSETS_500 = SD59x18.wrap(500e18);
    SD59x18 internal constant COLLATERAL_300 = SD59x18.wrap(300e18);
    SD59x18 internal constant COLLATERAL_500 = SD59x18.wrap(500e18);
    SD59x18 internal constant SHARES_100 = SD59x18.wrap(100e18);
    SD59x18 internal constant DEPOSIT_200 = SD59x18.wrap(200e18);
    SD59x18 internal constant PREMIUM_10 = SD59x18.wrap(10e18);
    SD59x18 internal constant ONE = SD59x18.wrap(1e18);

    function setUp() public {
        wrapper = new InvariantFuzzWrapper();
    }

    // =========================================================================
    // Solvency Invariant Tests
    // =========================================================================

    function test_checkSolvency_holdsWhenAssetsExceedCollateral() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        assertTrue(wrapper.checkSolvency(pool));
    }

    function test_checkSolvency_holdsWhenEqual() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_500, lockedCollateral: ASSETS_500, totalShares: SHARES_100
        });
        assertTrue(wrapper.checkSolvency(pool));
    }

    function test_checkSolvency_failsWhenCollateralExceedsAssets() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: COLLATERAL_300, lockedCollateral: ASSETS_1000, totalShares: SHARES_100
        });
        assertFalse(wrapper.checkSolvency(pool));
    }

    function test_enforceSolvency_revertsOnViolation() public {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: COLLATERAL_300, lockedCollateral: ASSETS_1000, totalShares: SHARES_100
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                InvariantFuzzTestingWithFoundry.InvariantFuzz__SolvencyViolation.selector,
                SD59x18.unwrap(COLLATERAL_300),
                SD59x18.unwrap(ASSETS_1000)
            )
        );
        wrapper.enforceSolvency(pool);
    }

    function test_enforceSolvency_doesNotRevertWhenValid() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        wrapper.enforceSolvency(pool);
    }

    function test_availableLiquidity_computesCorrectly() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        SD59x18 available = wrapper.availableLiquidity(pool);
        assertEq(SD59x18.unwrap(available), 700e18);
    }

    function test_availableLiquidity_returnsZeroWhenInsolvent() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: COLLATERAL_300, lockedCollateral: ASSETS_1000, totalShares: SHARES_100
        });
        SD59x18 available = wrapper.availableLiquidity(pool);
        assertEq(SD59x18.unwrap(available), 0);
    }

    function test_computeUtilization_computesCorrectly() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        SD59x18 util = wrapper.computeUtilization(pool);
        // 300 / 1000 = 0.3
        assertEq(SD59x18.unwrap(util), 300000000000000000);
    }

    function test_computeUtilization_returnsZeroForEmptyPool() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool =
            InvariantFuzzTestingWithFoundry.PoolState({ totalAssets: ZERO, lockedCollateral: ZERO, totalShares: ZERO });
        SD59x18 util = wrapper.computeUtilization(pool);
        assertEq(SD59x18.unwrap(util), 0);
    }

    // =========================================================================
    // Supply Consistency Invariant Tests
    // =========================================================================

    function test_checkSupplyConsistency_holdsWhenMatching() public view {
        InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot = InvariantFuzzTestingWithFoundry.SupplySnapshot({
            seriesCount: 2,
            totalMintedAcrossAll: 100,
            totalExercisedAcrossAll: 50,
            vaultRecordedMinted: 100,
            vaultRecordedExercised: 50
        });
        assertTrue(wrapper.checkSupplyConsistency(snapshot));
    }

    function test_checkSupplyConsistency_failsOnMintMismatch() public view {
        InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot = InvariantFuzzTestingWithFoundry.SupplySnapshot({
            seriesCount: 1,
            totalMintedAcrossAll: 100,
            totalExercisedAcrossAll: 50,
            vaultRecordedMinted: 90,
            vaultRecordedExercised: 50
        });
        assertFalse(wrapper.checkSupplyConsistency(snapshot));
    }

    function test_checkSupplyConsistency_failsOnExerciseMismatch() public view {
        InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot = InvariantFuzzTestingWithFoundry.SupplySnapshot({
            seriesCount: 1,
            totalMintedAcrossAll: 100,
            totalExercisedAcrossAll: 50,
            vaultRecordedMinted: 100,
            vaultRecordedExercised: 40
        });
        assertFalse(wrapper.checkSupplyConsistency(snapshot));
    }

    function test_enforceSupplyConsistency_revertsOnMismatch() public {
        InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot = InvariantFuzzTestingWithFoundry.SupplySnapshot({
            seriesCount: 1,
            totalMintedAcrossAll: 100,
            totalExercisedAcrossAll: 50,
            vaultRecordedMinted: 90,
            vaultRecordedExercised: 50
        });
        vm.expectRevert(
            abi.encodeWithSelector(InvariantFuzzTestingWithFoundry.InvariantFuzz__SupplyMismatch.selector, 100, 90)
        );
        wrapper.enforceSupplyConsistency(snapshot);
    }

    function test_buildSupplySnapshot_aggregatesCorrectly() public view {
        InvariantFuzzTestingWithFoundry.SeriesSupply[] memory seriesArray =
            new InvariantFuzzTestingWithFoundry.SeriesSupply[](3);
        seriesArray[0] = InvariantFuzzTestingWithFoundry.SeriesSupply({
            seriesId: 1, totalMinted: 10, totalExercised: 2, collateralPerOption: ONE
        });
        seriesArray[1] = InvariantFuzzTestingWithFoundry.SeriesSupply({
            seriesId: 2, totalMinted: 20, totalExercised: 5, collateralPerOption: ONE
        });
        seriesArray[2] = InvariantFuzzTestingWithFoundry.SeriesSupply({
            seriesId: 3, totalMinted: 30, totalExercised: 10, collateralPerOption: ONE
        });

        InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot =
            wrapper.buildSupplySnapshot(seriesArray, 60, 17);
        assertEq(snapshot.totalMintedAcrossAll, 60);
        assertEq(snapshot.totalExercisedAcrossAll, 17);
        assertEq(snapshot.seriesCount, 3);
    }

    function test_checkSeriesExerciseBound_holdsWhenExercisedLessThanMinted() public view {
        InvariantFuzzTestingWithFoundry.SeriesSupply memory supply = InvariantFuzzTestingWithFoundry.SeriesSupply({
            seriesId: 1, totalMinted: 100, totalExercised: 50, collateralPerOption: ONE
        });
        assertTrue(wrapper.checkSeriesExerciseBound(supply));
    }

    function test_checkSeriesExerciseBound_failsWhenExercisedExceedsMinted() public view {
        InvariantFuzzTestingWithFoundry.SeriesSupply memory supply = InvariantFuzzTestingWithFoundry.SeriesSupply({
            seriesId: 1, totalMinted: 50, totalExercised: 100, collateralPerOption: ONE
        });
        assertFalse(wrapper.checkSeriesExerciseBound(supply));
    }

    // =========================================================================
    // CDF Bounds Invariant Tests
    // =========================================================================

    function test_checkCdfBounds_holdsAtZero() public view {
        assertTrue(wrapper.checkCdfBounds(ZERO));
    }

    function test_checkCdfBounds_holdsAtPositiveValues() public view {
        assertTrue(wrapper.checkCdfBounds(sd(1e18)));
        assertTrue(wrapper.checkCdfBounds(sd(2e18)));
        assertTrue(wrapper.checkCdfBounds(sd(5e18)));
    }

    function test_checkCdfBounds_holdsAtNegativeValues() public view {
        assertTrue(wrapper.checkCdfBounds(sd(-1e18)));
        assertTrue(wrapper.checkCdfBounds(sd(-2e18)));
        assertTrue(wrapper.checkCdfBounds(sd(-5e18)));
    }

    function test_checkCdfMonotonicity_holdsForOrderedInputs() public view {
        assertTrue(wrapper.checkCdfMonotonicity(sd(-2e18), sd(2e18)));
        assertTrue(wrapper.checkCdfMonotonicity(sd(0), sd(1e18)));
        assertTrue(wrapper.checkCdfMonotonicity(sd(-3e18), sd(-1e18)));
    }

    function test_checkCdfMonotonicity_holdsForReversedInputs() public view {
        // The function auto-swaps, so reversed inputs should also pass
        assertTrue(wrapper.checkCdfMonotonicity(sd(2e18), sd(-2e18)));
    }

    function test_checkCdfSymmetry_holdsAtZero() public view {
        assertTrue(wrapper.checkCdfSymmetry(ZERO));
    }

    function test_checkCdfSymmetry_holdsAtOne() public view {
        assertTrue(wrapper.checkCdfSymmetry(sd(1e18)));
    }

    function test_checkCdfSymmetry_holdsAtNegativeValue() public view {
        assertTrue(wrapper.checkCdfSymmetry(sd(-2e18)));
    }

    // =========================================================================
    // Pool State Transition Tests
    // =========================================================================

    function test_applyDeposit_increasesAssets() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        InvariantFuzzTestingWithFoundry.PoolState memory updated = wrapper.applyDeposit(pool, DEPOSIT_200);
        assertEq(SD59x18.unwrap(updated.totalAssets), 1200e18);
        assertEq(SD59x18.unwrap(updated.lockedCollateral), 300e18);
    }

    function test_applyDeposit_revertsOnZeroAmount() public {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = wrapper.emptyPool();
        vm.expectRevert(InvariantFuzzTestingWithFoundry.InvariantFuzz__InvalidDepositAmount.selector);
        wrapper.applyDeposit(pool, ZERO);
    }

    function test_applyDeposit_firstDepositSharesEqualAmount() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = wrapper.emptyPool();
        InvariantFuzzTestingWithFoundry.PoolState memory updated = wrapper.applyDeposit(pool, DEPOSIT_200);
        assertEq(SD59x18.unwrap(updated.totalShares), 200e18);
        assertEq(SD59x18.unwrap(updated.totalAssets), 200e18);
    }

    function test_applyWithdrawal_decreasesAssets() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        SD59x18 withdrawAmount = sd(200e18);
        InvariantFuzzTestingWithFoundry.PoolState memory updated = wrapper.applyWithdrawal(pool, withdrawAmount);
        assertEq(SD59x18.unwrap(updated.totalAssets), 800e18);
        assertEq(SD59x18.unwrap(updated.lockedCollateral), 300e18);
    }

    function test_applyWithdrawal_revertsWhenExceedingAvailable() public {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        // Available is 700, trying to withdraw 800
        vm.expectRevert(
            abi.encodeWithSelector(
                InvariantFuzzTestingWithFoundry.InvariantFuzz__InsufficientLiquidity.selector, 800e18, 700e18
            )
        );
        wrapper.applyWithdrawal(pool, sd(800e18));
    }

    function test_applyMint_locksCollateral() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        SD59x18 collateral = sd(200e18);
        InvariantFuzzTestingWithFoundry.PoolState memory updated = wrapper.applyMint(pool, collateral, PREMIUM_10);
        assertEq(SD59x18.unwrap(updated.lockedCollateral), 500e18);
        assertEq(SD59x18.unwrap(updated.totalAssets), 1010e18);
    }

    function test_applyMint_revertsWhenInsufficientLiquidity() public {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        // Available is 700, trying to lock 800
        vm.expectRevert(
            abi.encodeWithSelector(
                InvariantFuzzTestingWithFoundry.InvariantFuzz__InsufficientLiquidity.selector, 800e18, 700e18
            )
        );
        wrapper.applyMint(pool, sd(800e18), PREMIUM_10);
    }

    function test_applyMint_revertsOnZeroCollateral() public {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        vm.expectRevert(InvariantFuzzTestingWithFoundry.InvariantFuzz__ZeroMintAmount.selector);
        wrapper.applyMint(pool, ZERO, PREMIUM_10);
    }

    function test_applyExercise_releasesCollateralAndPaysOut() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_500, totalShares: SHARES_100
        });
        SD59x18 payout = sd(100e18);
        SD59x18 collateralReleased = sd(200e18);
        InvariantFuzzTestingWithFoundry.PoolState memory updated =
            wrapper.applyExercise(pool, payout, collateralReleased);
        assertEq(SD59x18.unwrap(updated.totalAssets), 900e18);
        assertEq(SD59x18.unwrap(updated.lockedCollateral), 300e18);
    }

    function test_applyExpiry_releasesCollateralWithoutPayout() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_500, totalShares: SHARES_100
        });
        SD59x18 collateralReleased = sd(200e18);
        InvariantFuzzTestingWithFoundry.PoolState memory updated = wrapper.applyExpiry(pool, collateralReleased);
        assertEq(SD59x18.unwrap(updated.totalAssets), 1000e18);
        assertEq(SD59x18.unwrap(updated.lockedCollateral), 300e18);
    }

    // =========================================================================
    // Combined Invariant Check Tests
    // =========================================================================

    function test_checkAllInvariants_allHoldForValidState() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot = InvariantFuzzTestingWithFoundry.SupplySnapshot({
            seriesCount: 1,
            totalMintedAcrossAll: 100,
            totalExercisedAcrossAll: 50,
            vaultRecordedMinted: 100,
            vaultRecordedExercised: 50
        });
        InvariantFuzzTestingWithFoundry.InvariantCheckResult memory result =
            wrapper.checkAllInvariants(pool, snapshot, ZERO);
        assertTrue(result.solvencyHolds);
        assertTrue(result.supplyConsistent);
        assertTrue(result.cdfBounded);
        assertTrue(result.allHold);
    }

    function test_checkAllInvariants_failsOnSolvencyViolation() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: COLLATERAL_300, lockedCollateral: ASSETS_1000, totalShares: SHARES_100
        });
        InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot =
            InvariantFuzzTestingWithFoundry.createConsistentSnapshot(100, 50);
        InvariantFuzzTestingWithFoundry.InvariantCheckResult memory result =
            wrapper.checkAllInvariants(pool, snapshot, ZERO);
        assertFalse(result.solvencyHolds);
        assertFalse(result.allHold);
    }

    // =========================================================================
    // Utility Function Tests
    // =========================================================================

    function test_emptyPool_returnsAllZeros() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = wrapper.emptyPool();
        assertEq(SD59x18.unwrap(pool.totalAssets), 0);
        assertEq(SD59x18.unwrap(pool.lockedCollateral), 0);
        assertEq(SD59x18.unwrap(pool.totalShares), 0);
    }

    function test_createPool_setsValues() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool =
            wrapper.createPool(ASSETS_1000, COLLATERAL_300, SHARES_100);
        assertEq(SD59x18.unwrap(pool.totalAssets), 1000e18);
        assertEq(SD59x18.unwrap(pool.lockedCollateral), 300e18);
        assertEq(SD59x18.unwrap(pool.totalShares), 100e18);
    }

    function test_createConsistentSnapshot_matchesValues() public view {
        InvariantFuzzTestingWithFoundry.SupplySnapshot memory snapshot = wrapper.createConsistentSnapshot(100, 50);
        assertEq(snapshot.totalMintedAcrossAll, 100);
        assertEq(snapshot.vaultRecordedMinted, 100);
        assertEq(snapshot.totalExercisedAcrossAll, 50);
        assertEq(snapshot.vaultRecordedExercised, 50);
        assertTrue(wrapper.checkSupplyConsistency(snapshot));
    }

    function test_validatePoolState_revertsOnNegativeAssets() public {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: sd(-1e18), lockedCollateral: ZERO, totalShares: ZERO
        });
        vm.expectRevert(
            abi.encodeWithSelector(InvariantFuzzTestingWithFoundry.InvariantFuzz__NegativeTotalAssets.selector, -1e18)
        );
        wrapper.validatePoolState(pool);
    }

    function test_validatePoolState_revertsOnNegativeCollateral() public {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: sd(-1e18), totalShares: SHARES_100
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                InvariantFuzzTestingWithFoundry.InvariantFuzz__NegativeLockedCollateral.selector, -1e18
            )
        );
        wrapper.validatePoolState(pool);
    }

    function test_checkUtilizationBound_holdsForValidPool() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: ASSETS_1000, lockedCollateral: COLLATERAL_300, totalShares: SHARES_100
        });
        assertTrue(wrapper.checkUtilizationBound(pool));
    }

    function test_checkUtilizationBound_holdsForEmptyPool() public view {
        InvariantFuzzTestingWithFoundry.PoolState memory pool = wrapper.emptyPool();
        assertTrue(wrapper.checkUtilizationBound(pool));
    }

    function test_enforceUtilizationBound_revertsWhenExceeded() public {
        // Collateral > totalAssets means utilization > 100%
        InvariantFuzzTestingWithFoundry.PoolState memory pool = InvariantFuzzTestingWithFoundry.PoolState({
            totalAssets: COLLATERAL_300, lockedCollateral: ASSETS_1000, totalShares: SHARES_100
        });
        vm.expectRevert();
        wrapper.enforceUtilizationBound(pool);
    }

    // =========================================================================
    // Full Lifecycle Test
    // =========================================================================

    function test_fullLifecycle_solvencyPreservedThroughActions() public view {
        // 1. Start with empty pool
        InvariantFuzzTestingWithFoundry.PoolState memory pool = wrapper.emptyPool();
        assertTrue(wrapper.checkSolvency(pool));

        // 2. Deposit 1000
        pool = wrapper.applyDeposit(pool, ASSETS_1000);
        assertTrue(wrapper.checkSolvency(pool));
        assertEq(SD59x18.unwrap(pool.totalAssets), 1000e18);

        // 3. Mint options locking 300 collateral with 10 premium
        pool = wrapper.applyMint(pool, COLLATERAL_300, PREMIUM_10);
        assertTrue(wrapper.checkSolvency(pool));
        assertEq(SD59x18.unwrap(pool.lockedCollateral), 300e18);

        // 4. Exercise with 100 payout, releasing 300 collateral
        pool = wrapper.applyExercise(pool, sd(100e18), COLLATERAL_300);
        assertTrue(wrapper.checkSolvency(pool));
        assertEq(SD59x18.unwrap(pool.lockedCollateral), 0);

        // 5. Withdraw 500
        pool = wrapper.applyWithdrawal(pool, ASSETS_500);
        assertTrue(wrapper.checkSolvency(pool));
    }
}
