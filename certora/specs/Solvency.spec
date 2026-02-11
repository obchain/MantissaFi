/**
 * @title Solvency Invariant Specification
 * @notice Certora spec proving the OptionVault always holds sufficient collateral
 * @dev Verifies that collateralLocked >= maxPossiblePayout for all active options
 */

using OptionVault as vault;

methods {
    // View functions
    function nextSeriesId() external returns (uint256) envfree;
    function getSeries(uint256) external returns (
        address underlying,
        address collateral,
        int256 strike,
        uint64 expiry,
        bool isCall,
        uint8 state,
        uint256 totalMinted,
        uint256 totalExercised,
        uint256 collateralLocked,
        int256 settlementPrice,
        uint64 createdAt
    ) envfree;
    function getPosition(uint256, address) external returns (
        uint256 longAmount,
        uint256 shortAmount,
        bool hasClaimed
    ) envfree;
    function isExpired(uint256) external returns (bool) envfree;
    function canExercise(uint256) external returns (bool) envfree;
    function timeToExpiry(uint256) external returns (uint256) envfree;
    function calculateCollateral(uint256, uint256) external returns (uint256) envfree;

    // State-changing functions
    function createSeries(OptionVault.OptionSeries) external returns (uint256);
    function mint(uint256, uint256) external returns (uint256);
    function exercise(uint256, uint256) external returns (uint256);
    function settle(uint256) external;
    function claimCollateral(uint256) external returns (uint256);
    function pause() external;
    function unpause() external;
    function emergencyWithdraw(address, uint256) external;
}

/*
 * ============================================================================
 * DEFINITIONS
 * ============================================================================
 */

/**
 * @notice Get the collateral locked for a series
 */
function getSeriesCollateralLocked(uint256 seriesId) returns uint256 {
    address underlying;
    address collateral;
    int256 strike;
    uint64 expiry;
    bool isCall;
    uint8 state;
    uint256 totalMinted;
    uint256 totalExercised;
    uint256 collateralLocked;
    int256 settlementPrice;
    uint64 createdAt;

    underlying, collateral, strike, expiry, isCall, state, totalMinted, totalExercised, collateralLocked, settlementPrice, createdAt = vault.getSeries(seriesId);

    return collateralLocked;
}

/**
 * @notice Get total minted options for a series
 */
function getSeriesTotalMinted(uint256 seriesId) returns uint256 {
    address underlying;
    address collateral;
    int256 strike;
    uint64 expiry;
    bool isCall;
    uint8 state;
    uint256 totalMinted;
    uint256 totalExercised;
    uint256 collateralLocked;
    int256 settlementPrice;
    uint64 createdAt;

    underlying, collateral, strike, expiry, isCall, state, totalMinted, totalExercised, collateralLocked, settlementPrice, createdAt = vault.getSeries(seriesId);

    return totalMinted;
}

/**
 * @notice Get total exercised options for a series
 */
function getSeriesTotalExercised(uint256 seriesId) returns uint256 {
    address underlying;
    address collateral;
    int256 strike;
    uint64 expiry;
    bool isCall;
    uint8 state;
    uint256 totalMinted;
    uint256 totalExercised;
    uint256 collateralLocked;
    int256 settlementPrice;
    uint64 createdAt;

    underlying, collateral, strike, expiry, isCall, state, totalMinted, totalExercised, collateralLocked, settlementPrice, createdAt = vault.getSeries(seriesId);

    return totalExercised;
}

/**
 * @notice Calculate max possible payout for remaining options
 * @dev For 100% collateralization, max payout = collateral required for remaining options
 */
function maxPossiblePayout(uint256 seriesId) returns uint256 {
    uint256 totalMinted = getSeriesTotalMinted(seriesId);
    uint256 totalExercised = getSeriesTotalExercised(seriesId);
    uint256 remaining = totalMinted - totalExercised;

    // Max payout is the collateral required for remaining options
    // (since options are 100% collateralized)
    return vault.calculateCollateral(seriesId, remaining);
}

/*
 * ============================================================================
 * INVARIANTS
 * ============================================================================
 */

/**
 * @title Solvency Invariant
 * @notice The vault always holds enough collateral to cover maximum possible payoffs
 * @dev collateralLocked >= maxPossiblePayout for any series
 */
invariant solvencyInvariant(uint256 seriesId)
    getSeriesCollateralLocked(seriesId) >= maxPossiblePayout(seriesId)
    {
        preserved mint(uint256 sid, uint256 amount) with (env e) {
            require sid == seriesId;
        }
        preserved exercise(uint256 sid, uint256 amount) with (env e) {
            require sid == seriesId;
        }
        preserved claimCollateral(uint256 sid) with (env e) {
            require sid == seriesId;
        }
    }

/**
 * @title Non-negative Collateral
 * @notice Collateral locked can never be negative (implicit in uint256 but important for logic)
 */
invariant nonNegativeCollateral(uint256 seriesId)
    getSeriesCollateralLocked(seriesId) >= 0

/**
 * @title Total Exercised Bounded
 * @notice Total exercised cannot exceed total minted
 */
invariant exercisedBoundedByMinted(uint256 seriesId)
    getSeriesTotalExercised(seriesId) <= getSeriesTotalMinted(seriesId)

/*
 * ============================================================================
 * RULES
 * ============================================================================
 */

/**
 * @title Minting Increases Collateral
 * @notice Minting options always increases collateral locked proportionally
 */
rule mintingIncreasesCollateral(uint256 seriesId, uint256 amount) {
    env e;

    uint256 collateralBefore = getSeriesCollateralLocked(seriesId);
    uint256 mintedBefore = getSeriesTotalMinted(seriesId);

    vault.mint(e, seriesId, amount);

    uint256 collateralAfter = getSeriesCollateralLocked(seriesId);
    uint256 mintedAfter = getSeriesTotalMinted(seriesId);

    assert collateralAfter > collateralBefore, "Collateral should increase after minting";
    assert mintedAfter == mintedBefore + amount, "Total minted should increase by amount";
}

/**
 * @title Exercise Decreases Collateral Safely
 * @notice Exercising options decreases collateral but maintains solvency
 */
rule exerciseMaintainsSolvency(uint256 seriesId, uint256 amount) {
    env e;

    // Pre-condition: solvency holds before
    require getSeriesCollateralLocked(seriesId) >= maxPossiblePayout(seriesId);

    vault.exercise(e, seriesId, amount);

    // Post-condition: solvency still holds
    assert getSeriesCollateralLocked(seriesId) >= maxPossiblePayout(seriesId),
        "Solvency must be maintained after exercise";
}

/**
 * @title Claim Collateral Maintains Solvency
 * @notice Claiming collateral after settlement maintains solvency
 */
rule claimMaintainsSolvency(uint256 seriesId) {
    env e;

    // Pre-condition: solvency holds before
    require getSeriesCollateralLocked(seriesId) >= maxPossiblePayout(seriesId);

    vault.claimCollateral(e, seriesId);

    // Post-condition: solvency still holds
    assert getSeriesCollateralLocked(seriesId) >= maxPossiblePayout(seriesId),
        "Solvency must be maintained after claim";
}

/**
 * @title No Collateral Leakage
 * @notice Collateral can only decrease through exercise or claim, never arbitrarily
 */
rule noCollateralLeakage(uint256 seriesId, method f) {
    env e;
    calldataarg args;

    uint256 collateralBefore = getSeriesCollateralLocked(seriesId);

    f(e, args);

    uint256 collateralAfter = getSeriesCollateralLocked(seriesId);

    // Collateral should only decrease via exercise or claimCollateral
    assert (collateralAfter < collateralBefore) =>
        (f.selector == sig:exercise(uint256,uint256).selector ||
         f.selector == sig:claimCollateral(uint256).selector ||
         f.selector == sig:emergencyWithdraw(address,uint256).selector),
        "Collateral should only decrease through legitimate operations";
}

/**
 * @title Settlement Does Not Change Collateral
 * @notice Settling a series does not affect collateral locked
 */
rule settlementPreservesCollateral(uint256 seriesId) {
    env e;

    uint256 collateralBefore = getSeriesCollateralLocked(seriesId);

    vault.settle(e, seriesId);

    uint256 collateralAfter = getSeriesCollateralLocked(seriesId);

    assert collateralAfter == collateralBefore,
        "Settlement should not change collateral locked";
}
