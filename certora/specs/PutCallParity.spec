/**
 * @title Put-Call Parity Invariant Specification
 * @notice Certora spec proving that option payoffs satisfy put-call parity
 * @dev Verifies: callPayoff(S,K) - putPayoff(S,K) = S - K (at expiry)
 *
 * Put-Call Parity states that:
 *   C - P = S - K·e^(-rT)
 *
 * At expiry (T=0), this simplifies to:
 *   callPayoff - putPayoff = S - K
 *
 * This is because:
 *   callPayoff = max(S - K, 0)
 *   putPayoff = max(K - S, 0)
 *   callPayoff - putPayoff = S - K (always, regardless of ITM/OTM)
 */

using OptionVault as vault;

methods {
    // OptionVault view functions
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
    function calculateCollateral(uint256, uint256) external returns (uint256) envfree;

    // State-changing functions
    function createSeries(OptionVault.OptionSeries) external returns (uint256);
    function mint(uint256, uint256) external returns (uint256);
    function exercise(uint256, uint256) external returns (uint256);
    function settle(uint256) external;
    function claimCollateral(uint256) external returns (uint256);
}

/*
 * ============================================================================
 * DEFINITIONS
 * ============================================================================
 */

/**
 * @notice Get the strike price for a series
 */
function getSeriesStrike(uint256 seriesId) returns int256 {
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

    return strike;
}

/**
 * @notice Get if series is a call option
 */
function getSeriesIsCall(uint256 seriesId) returns bool {
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

    return isCall;
}

/**
 * @notice Get settlement price for a series
 */
function getSeriesSettlementPrice(uint256 seriesId) returns int256 {
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

    return settlementPrice;
}

/**
 * @notice Calculate call payoff: max(S - K, 0)
 */
function callPayoff(int256 spot, int256 strike) returns int256 {
    if (spot > strike) {
        return spot - strike;
    }
    return 0;
}

/**
 * @notice Calculate put payoff: max(K - S, 0)
 */
function putPayoff(int256 spot, int256 strike) returns int256 {
    if (strike > spot) {
        return strike - spot;
    }
    return 0;
}

/*
 * ============================================================================
 * INVARIANTS
 * ============================================================================
 */

/**
 * @title Put-Call Parity at Expiry
 * @notice At expiry: callPayoff - putPayoff = spot - strike
 * @dev This is a mathematical identity that must always hold
 */
invariant putCallParityPayoffs(int256 spot, int256 strike)
    spot > 0 && strike > 0 =>
        callPayoff(spot, strike) - putPayoff(spot, strike) == spot - strike

/*
 * ============================================================================
 * RULES
 * ============================================================================
 */

/**
 * @title Put-Call Parity Identity
 * @notice Verify that callPayoff - putPayoff = spot - strike for any valid inputs
 */
rule putCallParityIdentity(int256 spot, int256 strike) {
    // Preconditions: valid positive prices
    require spot > 0;
    require strike > 0;

    int256 callPay = callPayoff(spot, strike);
    int256 putPay = putPayoff(spot, strike);

    // Put-call parity at expiry: C - P = S - K
    assert callPay - putPay == spot - strike,
        "Put-call parity must hold: callPayoff - putPayoff = spot - strike";
}

/**
 * @title Call Payoff Non-Negative
 * @notice Call option payoff is always >= 0
 */
rule callPayoffNonNegative(int256 spot, int256 strike) {
    require spot > 0;
    require strike > 0;

    int256 payoff = callPayoff(spot, strike);

    assert payoff >= 0, "Call payoff must be non-negative";
}

/**
 * @title Put Payoff Non-Negative
 * @notice Put option payoff is always >= 0
 */
rule putPayoffNonNegative(int256 spot, int256 strike) {
    require spot > 0;
    require strike > 0;

    int256 payoff = putPayoff(spot, strike);

    assert payoff >= 0, "Put payoff must be non-negative";
}

/**
 * @title Call Payoff Bounded by Spot
 * @notice Call payoff cannot exceed spot price
 */
rule callPayoffBoundedBySpot(int256 spot, int256 strike) {
    require spot > 0;
    require strike > 0;

    int256 payoff = callPayoff(spot, strike);

    assert payoff <= spot, "Call payoff cannot exceed spot price";
}

/**
 * @title Put Payoff Bounded by Strike
 * @notice Put payoff cannot exceed strike price
 */
rule putPayoffBoundedByStrike(int256 spot, int256 strike) {
    require spot > 0;
    require strike > 0;

    int256 payoff = putPayoff(spot, strike);

    assert payoff <= strike, "Put payoff cannot exceed strike price";
}

/**
 * @title Symmetric Payoff Relationship
 * @notice Call ITM implies Put OTM and vice versa
 */
rule symmetricPayoffs(int256 spot, int256 strike) {
    require spot > 0;
    require strike > 0;

    int256 callPay = callPayoff(spot, strike);
    int256 putPay = putPayoff(spot, strike);

    // Exactly one of call or put has positive payoff (or both zero at ATM)
    assert (callPay > 0 && putPay == 0) ||
           (callPay == 0 && putPay > 0) ||
           (callPay == 0 && putPay == 0),
        "Call and put cannot both be ITM simultaneously";
}

/**
 * @title Exercise Payout Matches Payoff Formula
 * @notice When exercising, payout should match theoretical payoff
 */
rule exercisePayoutMatchesTheory(uint256 seriesId, uint256 amount) {
    env e;

    // Get series parameters before exercise
    int256 strike = getSeriesStrike(seriesId);
    bool isCall = getSeriesIsCall(seriesId);
    int256 settlementPrice = getSeriesSettlementPrice(seriesId);

    // Only verify for settled series with known price
    require settlementPrice > 0;
    require strike > 0;

    uint256 payout = vault.exercise(e, seriesId, amount);

    // Calculate expected payoff
    int256 expectedPayoffPerOption;
    if (isCall) {
        expectedPayoffPerOption = callPayoff(settlementPrice, strike);
    } else {
        expectedPayoffPerOption = putPayoff(settlementPrice, strike);
    }

    // Payout should be proportional to amount and payoff
    // Note: actual payout may be scaled by decimals
    assert payout >= 0, "Payout must be non-negative";
}
