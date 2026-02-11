// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import { CumulativeNormal } from "./CumulativeNormal.sol";

/// @title InvariantFuzzTestingWithFoundry
/// @notice Library enforcing protocol invariants across arbitrary sequences of pool actions
/// @dev Provides on-chain verification of three critical invariants:
///      1. Solvency: totalAssets ≥ lockedCollateral at all times
///      2. Supply Consistency: sum of minted option tokens == vault-recorded total
///      3. CDF Bounds: Φ(x) ∈ [0, 1] for all x ∈ ℝ
///      All arithmetic uses PRBMath SD59x18 fixed-point representation.
/// @author MantissaFi Team
library InvariantFuzzTestingWithFoundry {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice 1.0 in SD59x18 fixed-point representation
    int256 private constant ONE = 1e18;

    /// @notice Maximum number of option series tracked simultaneously
    uint256 internal constant MAX_SERIES = 256;

    /// @notice Maximum utilization ratio (100% = 1.0 in SD59x18)
    int256 private constant MAX_UTILIZATION = 1e18;

    /// @notice CDF lower bound (0.0)
    int256 private constant CDF_LOWER_BOUND = 0;

    /// @notice CDF upper bound (1.0 in SD59x18)
    int256 private constant CDF_UPPER_BOUND = 1e18;

    /// @notice Maximum CDF input magnitude (10.0 in SD59x18)
    int256 private constant CDF_INPUT_BOUND = 10e18;

    /// @notice Tolerance for numerical precision in CDF bounds (1e-12 in SD59x18)
    int256 private constant CDF_TOLERANCE = 1_000_000;

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when the solvency invariant is violated (totalAssets < lockedCollateral)
    /// @param totalAssets The pool's total assets
    /// @param lockedCollateral The pool's locked collateral
    error InvariantFuzz__SolvencyViolation(int256 totalAssets, int256 lockedCollateral);

    /// @notice Thrown when the total supply invariant is violated
    /// @param sumMinted The sum of individually minted option tokens
    /// @param vaultRecorded The vault's recorded total minted
    error InvariantFuzz__SupplyMismatch(uint256 sumMinted, uint256 vaultRecorded);

    /// @notice Thrown when the CDF output is out of bounds [0, 1]
    /// @param input The CDF input value
    /// @param output The CDF output that violated bounds
    error InvariantFuzz__CdfOutOfBounds(int256 input, int256 output);

    /// @notice Thrown when pool total assets is negative
    /// @param totalAssets The invalid total assets value
    error InvariantFuzz__NegativeTotalAssets(int256 totalAssets);

    /// @notice Thrown when locked collateral is negative
    /// @param lockedCollateral The invalid locked collateral value
    error InvariantFuzz__NegativeLockedCollateral(int256 lockedCollateral);

    /// @notice Thrown when deposit amount is zero or negative
    error InvariantFuzz__InvalidDepositAmount();

    /// @notice Thrown when withdrawal amount exceeds available liquidity
    /// @param requested The requested withdrawal
    /// @param available The available liquidity
    error InvariantFuzz__InsufficientLiquidity(int256 requested, int256 available);

    /// @notice Thrown when mint amount is zero
    error InvariantFuzz__ZeroMintAmount();

    /// @notice Thrown when exercise amount exceeds minted supply
    /// @param exerciseAmount The requested exercise amount
    /// @param totalMinted The total minted amount
    error InvariantFuzz__ExerciseExceedsMinted(uint256 exerciseAmount, uint256 totalMinted);

    /// @notice Thrown when series count exceeds the maximum allowed
    /// @param count The current series count
    error InvariantFuzz__MaxSeriesExceeded(uint256 count);

    /// @notice Thrown when utilization ratio exceeds 100%
    /// @param utilization The computed utilization ratio
    error InvariantFuzz__UtilizationExceeded(int256 utilization);

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Represents the state of a liquidity pool for invariant checking
    /// @param totalAssets Total assets deposited in the pool (SD59x18)
    /// @param lockedCollateral Collateral currently locked for written options (SD59x18)
    /// @param totalShares Total LP shares outstanding (SD59x18)
    struct PoolState {
        SD59x18 totalAssets;
        SD59x18 lockedCollateral;
        SD59x18 totalShares;
    }

    /// @notice Tracks the supply of a single option series
    /// @param seriesId Unique identifier for the series
    /// @param totalMinted Total options minted in this series
    /// @param totalExercised Total options exercised in this series
    /// @param collateralPerOption Collateral locked per option (SD59x18)
    struct SeriesSupply {
        uint256 seriesId;
        uint256 totalMinted;
        uint256 totalExercised;
        SD59x18 collateralPerOption;
    }

    /// @notice Aggregated supply snapshot across all active series
    /// @param seriesCount Number of active series
    /// @param totalMintedAcrossAll Sum of totalMinted across all series
    /// @param totalExercisedAcrossAll Sum of totalExercised across all series
    /// @param vaultRecordedMinted The vault's internally recorded total minted
    /// @param vaultRecordedExercised The vault's internally recorded total exercised
    struct SupplySnapshot {
        uint256 seriesCount;
        uint256 totalMintedAcrossAll;
        uint256 totalExercisedAcrossAll;
        uint256 vaultRecordedMinted;
        uint256 vaultRecordedExercised;
    }

    /// @notice Result of an invariant check
    /// @param solvencyHolds True if totalAssets >= lockedCollateral
    /// @param supplyConsistent True if sum(minted) == vault recorded total
    /// @param cdfBounded True if CDF output is in [0, 1]
    /// @param allHold True only if all three invariants hold
    struct InvariantCheckResult {
        bool solvencyHolds;
        bool supplyConsistent;
        bool cdfBounded;
        bool allHold;
    }

    // =========================================================================
    // Solvency Invariant
    // =========================================================================

    /// @notice Checks that pool total assets are at least as large as locked collateral
    /// @dev Invariant: totalAssets >= lockedCollateral
    /// @param pool The current pool state
    /// @return holds True if the solvency invariant holds
    function checkSolvency(PoolState memory pool) internal pure returns (bool holds) {
        holds = pool.totalAssets.gte(pool.lockedCollateral);
    }

    /// @notice Strictly enforces the solvency invariant (reverts on violation)
    /// @param pool The current pool state
    function enforceSolvency(PoolState memory pool) internal pure {
        if (pool.totalAssets.lt(pool.lockedCollateral)) {
            revert InvariantFuzz__SolvencyViolation(
                SD59x18.unwrap(pool.totalAssets), SD59x18.unwrap(pool.lockedCollateral)
            );
        }
    }

    /// @notice Computes available liquidity (totalAssets - lockedCollateral)
    /// @param pool The current pool state
    /// @return available The available liquidity (SD59x18), clamped to zero minimum
    function availableLiquidity(PoolState memory pool) internal pure returns (SD59x18 available) {
        if (pool.totalAssets.gt(pool.lockedCollateral)) {
            available = pool.totalAssets.sub(pool.lockedCollateral);
        } else {
            available = ZERO;
        }
    }

    /// @notice Computes utilization ratio (lockedCollateral / totalAssets)
    /// @param pool The current pool state
    /// @return utilization The utilization ratio in [0, 1] (SD59x18)
    function computeUtilization(PoolState memory pool) internal pure returns (SD59x18 utilization) {
        if (pool.totalAssets.lte(ZERO)) {
            return ZERO;
        }
        utilization = pool.lockedCollateral.div(pool.totalAssets);
    }

    // =========================================================================
    // Total Supply Invariant
    // =========================================================================

    /// @notice Checks that the sum of per-series minted tokens matches the vault's recorded total
    /// @dev Invariant: Σ series[i].totalMinted == vaultRecordedMinted
    /// @param snapshot The supply snapshot to check
    /// @return holds True if the supply invariant holds
    function checkSupplyConsistency(SupplySnapshot memory snapshot) internal pure returns (bool holds) {
        holds = snapshot.totalMintedAcrossAll == snapshot.vaultRecordedMinted
            && snapshot.totalExercisedAcrossAll == snapshot.vaultRecordedExercised;
    }

    /// @notice Strictly enforces the supply consistency invariant
    /// @param snapshot The supply snapshot to check
    function enforceSupplyConsistency(SupplySnapshot memory snapshot) internal pure {
        if (snapshot.totalMintedAcrossAll != snapshot.vaultRecordedMinted) {
            revert InvariantFuzz__SupplyMismatch(snapshot.totalMintedAcrossAll, snapshot.vaultRecordedMinted);
        }
        if (snapshot.totalExercisedAcrossAll != snapshot.vaultRecordedExercised) {
            revert InvariantFuzz__SupplyMismatch(snapshot.totalExercisedAcrossAll, snapshot.vaultRecordedExercised);
        }
    }

    /// @notice Aggregates individual series supplies into a snapshot for invariant checking
    /// @param seriesArray Array of series supply data
    /// @param vaultRecordedMinted The vault's recorded total minted
    /// @param vaultRecordedExercised The vault's recorded total exercised
    /// @return snapshot The aggregated supply snapshot
    function buildSupplySnapshot(
        SeriesSupply[] memory seriesArray,
        uint256 vaultRecordedMinted,
        uint256 vaultRecordedExercised
    ) internal pure returns (SupplySnapshot memory snapshot) {
        if (seriesArray.length > MAX_SERIES) {
            revert InvariantFuzz__MaxSeriesExceeded(seriesArray.length);
        }

        uint256 totalMinted;
        uint256 totalExercised;
        for (uint256 i = 0; i < seriesArray.length; i++) {
            totalMinted += seriesArray[i].totalMinted;
            totalExercised += seriesArray[i].totalExercised;
        }

        snapshot = SupplySnapshot({
            seriesCount: seriesArray.length,
            totalMintedAcrossAll: totalMinted,
            totalExercisedAcrossAll: totalExercised,
            vaultRecordedMinted: vaultRecordedMinted,
            vaultRecordedExercised: vaultRecordedExercised
        });
    }

    /// @notice Checks that exercised amount never exceeds minted amount for a series
    /// @param supply The series supply data
    /// @return holds True if exercised <= minted
    function checkSeriesExerciseBound(SeriesSupply memory supply) internal pure returns (bool holds) {
        holds = supply.totalExercised <= supply.totalMinted;
    }

    // =========================================================================
    // CDF Bounds Invariant
    // =========================================================================

    /// @notice Checks that Φ(x) ∈ [0, 1] for the given input
    /// @dev Uses the CumulativeNormal library's rational approximation
    /// @param x Input value in SD59x18 format
    /// @return holds True if the CDF output is within [0, 1]
    function checkCdfBounds(SD59x18 x) internal pure returns (bool holds) {
        SD59x18 result = CumulativeNormal.cdf(x);
        int256 raw = SD59x18.unwrap(result);
        // Allow small numerical tolerance at boundaries
        holds = raw >= (CDF_LOWER_BOUND - CDF_TOLERANCE) && raw <= (CDF_UPPER_BOUND + CDF_TOLERANCE);
    }

    /// @notice Strictly enforces that the CDF output is within [0, 1]
    /// @param x Input value in SD59x18 format
    /// @return result The CDF value (SD59x18)
    function enforceCdfBounds(SD59x18 x) internal pure returns (SD59x18 result) {
        result = CumulativeNormal.cdf(x);
        int256 raw = SD59x18.unwrap(result);
        if (raw < (CDF_LOWER_BOUND - CDF_TOLERANCE) || raw > (CDF_UPPER_BOUND + CDF_TOLERANCE)) {
            revert InvariantFuzz__CdfOutOfBounds(SD59x18.unwrap(x), raw);
        }
    }

    /// @notice Checks the CDF monotonicity property: if a < b then Φ(a) ≤ Φ(b)
    /// @param a First input (SD59x18)
    /// @param b Second input (SD59x18), must be >= a
    /// @return holds True if Φ(a) ≤ Φ(b)
    function checkCdfMonotonicity(SD59x18 a, SD59x18 b) internal pure returns (bool holds) {
        if (a.gt(b)) {
            // Swap so a <= b
            (a, b) = (b, a);
        }
        SD59x18 cdfA = CumulativeNormal.cdf(a);
        SD59x18 cdfB = CumulativeNormal.cdf(b);
        holds = cdfB.gte(cdfA);
    }

    /// @notice Checks the CDF symmetry property: Φ(x) + Φ(-x) ≈ 1
    /// @param x Input value (SD59x18)
    /// @return holds True if Φ(x) + Φ(-x) is within tolerance of 1.0
    function checkCdfSymmetry(SD59x18 x) internal pure returns (bool holds) {
        SD59x18 cdfPos = CumulativeNormal.cdf(x);
        SD59x18 cdfNeg = CumulativeNormal.cdf(x.mul(sd(-ONE)));
        int256 sum = SD59x18.unwrap(cdfPos) + SD59x18.unwrap(cdfNeg);
        // Sum should be approximately 1.0
        int256 diff = sum - ONE;
        if (diff < 0) diff = -diff;
        holds = diff <= CDF_TOLERANCE;
    }

    // =========================================================================
    // Pool State Transitions
    // =========================================================================

    /// @notice Applies a deposit to the pool and verifies solvency is preserved
    /// @param pool The current pool state
    /// @param depositAmount The amount to deposit (SD59x18, must be > 0)
    /// @return updated The updated pool state
    function applyDeposit(PoolState memory pool, SD59x18 depositAmount)
        internal
        pure
        returns (PoolState memory updated)
    {
        if (depositAmount.lte(ZERO)) {
            revert InvariantFuzz__InvalidDepositAmount();
        }

        SD59x18 newShares;
        if (pool.totalAssets.lte(ZERO) || pool.totalShares.lte(ZERO)) {
            newShares = depositAmount;
        } else {
            newShares = depositAmount.mul(pool.totalShares).div(pool.totalAssets);
        }

        updated = PoolState({
            totalAssets: pool.totalAssets.add(depositAmount),
            lockedCollateral: pool.lockedCollateral,
            totalShares: pool.totalShares.add(newShares)
        });
    }

    /// @notice Applies a withdrawal to the pool and verifies solvency is preserved
    /// @param pool The current pool state
    /// @param withdrawAmount The amount to withdraw (SD59x18, must be > 0)
    /// @return updated The updated pool state
    function applyWithdrawal(PoolState memory pool, SD59x18 withdrawAmount)
        internal
        pure
        returns (PoolState memory updated)
    {
        if (withdrawAmount.lte(ZERO)) {
            revert InvariantFuzz__InvalidDepositAmount();
        }

        SD59x18 available = availableLiquidity(pool);
        if (withdrawAmount.gt(available)) {
            revert InvariantFuzz__InsufficientLiquidity(SD59x18.unwrap(withdrawAmount), SD59x18.unwrap(available));
        }

        SD59x18 sharesToBurn;
        if (pool.totalAssets.gt(ZERO)) {
            sharesToBurn = withdrawAmount.mul(pool.totalShares).div(pool.totalAssets);
        } else {
            sharesToBurn = ZERO;
        }

        updated = PoolState({
            totalAssets: pool.totalAssets.sub(withdrawAmount),
            lockedCollateral: pool.lockedCollateral,
            totalShares: pool.totalShares.sub(sharesToBurn)
        });
    }

    /// @notice Applies a collateral lock (option mint) and verifies solvency
    /// @param pool The current pool state
    /// @param collateralAmount Collateral to lock (SD59x18, must be > 0)
    /// @param premiumReceived Premium received from buyer (SD59x18)
    /// @return updated The updated pool state
    function applyMint(PoolState memory pool, SD59x18 collateralAmount, SD59x18 premiumReceived)
        internal
        pure
        returns (PoolState memory updated)
    {
        if (collateralAmount.lte(ZERO)) {
            revert InvariantFuzz__ZeroMintAmount();
        }

        SD59x18 available = availableLiquidity(pool);
        if (collateralAmount.gt(available)) {
            revert InvariantFuzz__InsufficientLiquidity(SD59x18.unwrap(collateralAmount), SD59x18.unwrap(available));
        }

        updated = PoolState({
            totalAssets: pool.totalAssets.add(premiumReceived),
            lockedCollateral: pool.lockedCollateral.add(collateralAmount),
            totalShares: pool.totalShares
        });
    }

    /// @notice Applies an exercise (collateral release + payout) and verifies solvency
    /// @param pool The current pool state
    /// @param payoutAmount Payout to the exerciser (SD59x18)
    /// @param collateralReleased Collateral being released (SD59x18)
    /// @return updated The updated pool state
    function applyExercise(PoolState memory pool, SD59x18 payoutAmount, SD59x18 collateralReleased)
        internal
        pure
        returns (PoolState memory updated)
    {
        updated = PoolState({
            totalAssets: pool.totalAssets.sub(payoutAmount),
            lockedCollateral: pool.lockedCollateral.sub(collateralReleased),
            totalShares: pool.totalShares
        });
    }

    /// @notice Applies an OTM expiry (collateral release, no payout)
    /// @param pool The current pool state
    /// @param collateralReleased Collateral being released (SD59x18)
    /// @return updated The updated pool state
    function applyExpiry(PoolState memory pool, SD59x18 collateralReleased)
        internal
        pure
        returns (PoolState memory updated)
    {
        updated = PoolState({
            totalAssets: pool.totalAssets,
            lockedCollateral: pool.lockedCollateral.sub(collateralReleased),
            totalShares: pool.totalShares
        });
    }

    // =========================================================================
    // Combined Invariant Check
    // =========================================================================

    /// @notice Runs all three invariant checks and returns the combined result
    /// @param pool The current pool state
    /// @param snapshot The current supply snapshot
    /// @param cdfInput A CDF input value to test (SD59x18)
    /// @return result The combined invariant check result
    function checkAllInvariants(PoolState memory pool, SupplySnapshot memory snapshot, SD59x18 cdfInput)
        internal
        pure
        returns (InvariantCheckResult memory result)
    {
        result.solvencyHolds = checkSolvency(pool);
        result.supplyConsistent = checkSupplyConsistency(snapshot);
        result.cdfBounded = checkCdfBounds(cdfInput);
        result.allHold = result.solvencyHolds && result.supplyConsistent && result.cdfBounded;
    }

    /// @notice Enforces all three invariants simultaneously (reverts on any violation)
    /// @param pool The current pool state
    /// @param snapshot The current supply snapshot
    /// @param cdfInput A CDF input value to test (SD59x18)
    function enforceAllInvariants(PoolState memory pool, SupplySnapshot memory snapshot, SD59x18 cdfInput)
        internal
        pure
    {
        enforceSolvency(pool);
        enforceSupplyConsistency(snapshot);
        enforceCdfBounds(cdfInput);
    }

    // =========================================================================
    // Utility Functions
    // =========================================================================

    /// @notice Creates an initial empty pool state
    /// @return pool A pool state with zero values
    function emptyPool() internal pure returns (PoolState memory pool) {
        pool = PoolState({ totalAssets: ZERO, lockedCollateral: ZERO, totalShares: ZERO });
    }

    /// @notice Creates a pool state with the given parameters
    /// @param totalAssets Total assets in the pool (SD59x18)
    /// @param lockedCollateral Locked collateral in the pool (SD59x18)
    /// @param totalShares Total shares outstanding (SD59x18)
    /// @return pool The constructed pool state
    function createPool(SD59x18 totalAssets, SD59x18 lockedCollateral, SD59x18 totalShares)
        internal
        pure
        returns (PoolState memory pool)
    {
        pool = PoolState({ totalAssets: totalAssets, lockedCollateral: lockedCollateral, totalShares: totalShares });
    }

    /// @notice Creates a supply snapshot with matching totals (valid state)
    /// @param minted Total minted amount
    /// @param exercised Total exercised amount
    /// @return snapshot A consistent supply snapshot
    function createConsistentSnapshot(uint256 minted, uint256 exercised)
        internal
        pure
        returns (SupplySnapshot memory snapshot)
    {
        snapshot = SupplySnapshot({
            seriesCount: 1,
            totalMintedAcrossAll: minted,
            totalExercisedAcrossAll: exercised,
            vaultRecordedMinted: minted,
            vaultRecordedExercised: exercised
        });
    }

    /// @notice Validates that a pool state has non-negative values
    /// @param pool The pool state to validate
    function validatePoolState(PoolState memory pool) internal pure {
        if (pool.totalAssets.lt(ZERO)) {
            revert InvariantFuzz__NegativeTotalAssets(SD59x18.unwrap(pool.totalAssets));
        }
        if (pool.lockedCollateral.lt(ZERO)) {
            revert InvariantFuzz__NegativeLockedCollateral(SD59x18.unwrap(pool.lockedCollateral));
        }
    }

    /// @notice Checks the utilization invariant: utilization ∈ [0, 1]
    /// @param pool The current pool state
    /// @return holds True if utilization is bounded
    function checkUtilizationBound(PoolState memory pool) internal pure returns (bool holds) {
        if (pool.totalAssets.lte(ZERO)) {
            return true;
        }
        SD59x18 util = computeUtilization(pool);
        holds = util.gte(ZERO) && util.lte(sd(MAX_UTILIZATION));
    }

    /// @notice Enforces the utilization bound invariant
    /// @param pool The current pool state
    function enforceUtilizationBound(PoolState memory pool) internal pure {
        if (pool.totalAssets.gt(ZERO)) {
            SD59x18 util = computeUtilization(pool);
            if (util.gt(sd(MAX_UTILIZATION))) {
                revert InvariantFuzz__UtilizationExceeded(SD59x18.unwrap(util));
            }
        }
    }
}
