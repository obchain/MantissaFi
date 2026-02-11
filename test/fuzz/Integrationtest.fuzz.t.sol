// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import {
    Integrationtest,
    OptionSeries,
    OptionPosition,
    PoolState,
    OraclePrice,
    BSMInputs,
    BSMOutputs,
    BatchMintRequest
} from "../../src/libraries/Integrationtest.sol";

/// @title IntegrationtestFuzzTest
/// @notice Fuzz tests for the Integrationtest library invariants
/// @dev Tests property-based invariants that must hold for all valid inputs
contract IntegrationtestFuzzTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Minimum valid volatility (1%)
    int256 internal constant MIN_VOL = 10000000000000000;

    /// @notice Maximum valid volatility (500%)
    int256 internal constant MAX_VOL = 5_000000000000000000;

    /// @notice Minimum valid spot/strike price ($1)
    int256 internal constant MIN_PRICE = 1e18;

    /// @notice Maximum valid spot/strike price ($1,000,000)
    int256 internal constant MAX_PRICE = 1_000_000e18;

    /// @notice Minimum time to expiry (1 hour)
    int256 internal constant MIN_TIME = 3600e18;

    /// @notice Maximum time to expiry (2 years)
    int256 internal constant MAX_TIME = 63072000e18;

    /// @notice Seconds per year for conversion
    int256 internal constant SECONDS_PER_YEAR = 31536000e18;

    /// @notice Test addresses
    address internal constant WETH = address(0x1);
    address internal constant USDC = address(0x2);

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Bounds a value to valid BSM price range
    function _boundPrice(int256 price) internal pure returns (SD59x18) {
        return sd(bound(price, MIN_PRICE, MAX_PRICE));
    }

    /// @notice Bounds a value to valid volatility range
    function _boundVolatility(int256 vol) internal pure returns (SD59x18) {
        return sd(bound(vol, MIN_VOL, MAX_VOL));
    }

    /// @notice Bounds a value to valid time range and converts to years
    function _boundTimeToExpiry(int256 timeSeconds) internal pure returns (SD59x18) {
        int256 bounded = bound(timeSeconds, MIN_TIME, MAX_TIME);
        return sd(bounded).div(sd(SECONDS_PER_YEAR));
    }

    /// @notice Bounds risk-free rate to reasonable range (0% to 20%)
    function _boundRiskFreeRate(int256 rate) internal pure returns (SD59x18) {
        return sd(bound(rate, 0, 200000000000000000));
    }

    /// @notice Creates bounded BSM inputs
    function _createBoundedBSMInputs(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) internal pure returns (BSMInputs memory) {
        return BSMInputs({
            spot: _boundPrice(spot),
            strike: _boundPrice(strike),
            volatility: _boundVolatility(vol),
            riskFreeRate: _boundRiskFreeRate(rate),
            timeToExpiry: _boundTimeToExpiry(time)
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BSM PRICING INVARIANT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Call price is always non-negative
    /// @dev C >= 0 for all valid inputs
    function testFuzz_CallPriceNonNegative(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) public pure {
        BSMInputs memory inputs = _createBoundedBSMInputs(spot, strike, vol, rate, time);
        SD59x18 price = Integrationtest.priceCall(inputs);

        assertTrue(price.gte(ZERO), "Call price must be non-negative");
    }

    /// @notice Invariant: Put price is always non-negative
    /// @dev P >= 0 for all valid inputs
    function testFuzz_PutPriceNonNegative(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) public pure {
        BSMInputs memory inputs = _createBoundedBSMInputs(spot, strike, vol, rate, time);
        SD59x18 price = Integrationtest.pricePut(inputs);

        assertTrue(price.gte(ZERO), "Put price must be non-negative");
    }

    /// @notice Invariant: Call price <= Spot price (no arbitrage)
    /// @dev C <= S for all valid inputs
    function testFuzz_CallPriceBoundedBySpot(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) public pure {
        BSMInputs memory inputs = _createBoundedBSMInputs(spot, strike, vol, rate, time);
        SD59x18 price = Integrationtest.priceCall(inputs);

        assertTrue(price.lte(inputs.spot), "Call price must be <= spot price");
    }

    /// @notice Invariant: Put price <= Strike * e^(-rT) (discounted strike)
    /// @dev P <= K * e^(-rT) for all valid inputs
    function testFuzz_PutPriceBoundedByDiscountedStrike(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) public pure {
        BSMInputs memory inputs = _createBoundedBSMInputs(spot, strike, vol, rate, time);
        SD59x18 price = Integrationtest.pricePut(inputs);

        SD59x18 discountFactor = inputs.riskFreeRate.mul(inputs.timeToExpiry).mul(sd(-1e18)).exp();
        SD59x18 maxPutPrice = inputs.strike.mul(discountFactor);

        assertTrue(price.lte(maxPutPrice), "Put price must be <= discounted strike");
    }

    /// @notice Invariant: Put-call parity holds within tolerance
    /// @dev |C - P - S + K*e^(-rT)| < epsilon for all valid inputs
    function testFuzz_PutCallParity(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) public pure {
        BSMInputs memory inputs = _createBoundedBSMInputs(spot, strike, vol, rate, time);

        SD59x18 callPrice = Integrationtest.priceCall(inputs);
        SD59x18 putPrice = Integrationtest.pricePut(inputs);

        // C - P = S - K*e^(-rT)
        SD59x18 discountFactor = inputs.riskFreeRate.mul(inputs.timeToExpiry).mul(sd(-1e18)).exp();
        SD59x18 lhs = callPrice.sub(putPrice);
        SD59x18 rhs = inputs.spot.sub(inputs.strike.mul(discountFactor));

        // Allow 0.1% relative error or 1e15 absolute error
        SD59x18 diff = lhs.sub(rhs).abs();
        SD59x18 relativeTolerance = rhs.abs().mul(sd(1e15)).div(sd(1e18)); // 0.1%
        SD59x18 tolerance = relativeTolerance.gt(sd(1e15)) ? relativeTolerance : sd(1e15);

        assertTrue(diff.lte(tolerance), "Put-call parity must hold within tolerance");
    }

    /// @notice Invariant: d2 < d1 always
    /// @dev d2 = d1 - sigma * sqrt(T), so d2 < d1 when sigma, T > 0
    function testFuzz_D2LessThanD1(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) public pure {
        BSMInputs memory inputs = _createBoundedBSMInputs(spot, strike, vol, rate, time);

        SD59x18 d1 = Integrationtest.computeD1(inputs);
        SD59x18 d2 = Integrationtest.computeD2(inputs, d1);

        assertTrue(d2.lt(d1), "d2 must be less than d1");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GREEKS INVARIANT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Call delta is in [0, 1]
    /// @dev 0 <= Delta_call <= 1
    function testFuzz_CallDeltaInRange(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) public pure {
        BSMInputs memory inputs = _createBoundedBSMInputs(spot, strike, vol, rate, time);
        BSMOutputs memory outputs = Integrationtest.computeBSM(inputs, true);

        assertTrue(outputs.delta.gte(ZERO), "Call delta must be >= 0");
        assertTrue(outputs.delta.lte(sd(1e18)), "Call delta must be <= 1");
    }

    /// @notice Invariant: Put delta is in [-1, 0]
    /// @dev -1 <= Delta_put <= 0
    function testFuzz_PutDeltaInRange(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) public pure {
        BSMInputs memory inputs = _createBoundedBSMInputs(spot, strike, vol, rate, time);
        BSMOutputs memory outputs = Integrationtest.computeBSM(inputs, false);

        assertTrue(outputs.delta.gte(sd(-1e18)), "Put delta must be >= -1");
        assertTrue(outputs.delta.lte(ZERO), "Put delta must be <= 0");
    }

    /// @notice Invariant: Gamma is always non-negative
    /// @dev Gamma >= 0 for all options (can be numerically zero for extreme inputs)
    function testFuzz_GammaNonNegative(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) public pure {
        BSMInputs memory inputs = _createBoundedBSMInputs(spot, strike, vol, rate, time);
        BSMOutputs memory outputs = Integrationtest.computeBSM(inputs, true);

        // Gamma should be non-negative (numerically can be zero for extreme cases)
        assertTrue(outputs.gamma.gte(ZERO), "Gamma must be non-negative");
    }

    /// @notice Invariant: Vega is always non-negative
    /// @dev Vega >= 0 for all options (can be numerically zero for extreme inputs)
    function testFuzz_VegaNonNegative(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 rate,
        int256 time
    ) public pure {
        BSMInputs memory inputs = _createBoundedBSMInputs(spot, strike, vol, rate, time);
        BSMOutputs memory outputs = Integrationtest.computeBSM(inputs, true);

        // Vega should be non-negative (numerically can be zero for extreme cases)
        assertTrue(outputs.vega.gte(ZERO), "Vega must be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OPTION PAYOFF INVARIANT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Call payoff = max(S - K, 0)
    function testFuzz_CallPayoff(int256 spotRaw, int256 strikeRaw, int256 amountRaw) public view {
        SD59x18 spot = _boundPrice(spotRaw);
        SD59x18 strike = _boundPrice(strikeRaw);
        SD59x18 amount = sd(bound(amountRaw, 1e18, 1000e18)); // 1 to 1000 options

        OptionSeries memory series = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + 30 days),
            strikePrice: strike,
            isCall: true
        });

        (SD59x18 payoff, bool isITM) = Integrationtest.calculateExercisePayoff(series, amount, spot);

        if (spot.gt(strike)) {
            // ITM: payoff = (S - K) * amount
            assertTrue(isITM, "Should be ITM when spot > strike");
            SD59x18 expected = spot.sub(strike).mul(amount);
            assertEq(SD59x18.unwrap(payoff), SD59x18.unwrap(expected), "Payoff should equal (S-K)*amount");
        } else {
            // OTM: payoff = 0
            assertFalse(isITM, "Should be OTM when spot <= strike");
            assertEq(SD59x18.unwrap(payoff), 0, "OTM payoff should be zero");
        }
    }

    /// @notice Invariant: Put payoff = max(K - S, 0)
    function testFuzz_PutPayoff(int256 spotRaw, int256 strikeRaw, int256 amountRaw) public view {
        SD59x18 spot = _boundPrice(spotRaw);
        SD59x18 strike = _boundPrice(strikeRaw);
        SD59x18 amount = sd(bound(amountRaw, 1e18, 1000e18));

        OptionSeries memory series = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + 30 days),
            strikePrice: strike,
            isCall: false
        });

        (SD59x18 payoff, bool isITM) = Integrationtest.calculateExercisePayoff(series, amount, spot);

        if (strike.gt(spot)) {
            // ITM: payoff = (K - S) * amount
            assertTrue(isITM, "Should be ITM when strike > spot");
            SD59x18 expected = strike.sub(spot).mul(amount);
            assertEq(SD59x18.unwrap(payoff), SD59x18.unwrap(expected), "Payoff should equal (K-S)*amount");
        } else {
            // OTM: payoff = 0
            assertFalse(isITM, "Should be OTM when strike <= spot");
            assertEq(SD59x18.unwrap(payoff), 0, "OTM payoff should be zero");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POOL MANAGEMENT INVARIANT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Shares are proportional to deposit for non-empty pools
    function testFuzz_SharesProportional(
        int256 totalAssetsRaw,
        int256 totalSharesRaw,
        int256 depositRaw
    ) public pure {
        // Bound to reasonable values
        SD59x18 totalAssets = sd(bound(totalAssetsRaw, 1e18, 1_000_000_000e18));
        SD59x18 totalShares = sd(bound(totalSharesRaw, 1e18, 1_000_000_000e18));
        SD59x18 deposit = sd(bound(depositRaw, 1e18, 1_000_000e18));

        SD59x18 shares = Integrationtest.calculateDepositShares(deposit, totalAssets, totalShares);

        // shares / totalShares = deposit / totalAssets (proportional)
        // Cross multiply: shares * totalAssets = deposit * totalShares
        SD59x18 lhs = shares.mul(totalAssets);
        SD59x18 rhs = deposit.mul(totalShares);

        // Allow small rounding error
        SD59x18 diff = lhs.sub(rhs).abs();
        assertTrue(diff.lt(sd(1e15)), "Shares must be proportional to deposit");
    }

    /// @notice Invariant: First deposit shares equal deposit amount
    function testFuzz_FirstDepositShares(int256 depositRaw) public pure {
        SD59x18 deposit = sd(bound(depositRaw, 1e18, 1_000_000_000e18));

        SD59x18 shares = Integrationtest.calculateDepositShares(deposit, ZERO, ZERO);

        assertEq(SD59x18.unwrap(shares), SD59x18.unwrap(deposit), "First deposit shares = amount");
    }

    /// @notice Invariant: Pool invariants maintained after mint
    function testFuzz_PoolStateAfterMint(
        int256 totalAssetsRaw,
        int256 premiumRaw,
        int256 collateralRaw
    ) public pure {
        // Ensure pool has enough liquidity
        SD59x18 totalAssets = sd(bound(totalAssetsRaw, 1_000_000e18, 1_000_000_000e18));
        SD59x18 premium = sd(bound(premiumRaw, 1e18, 100_000e18));
        SD59x18 collateral = sd(bound(collateralRaw, 1e18, 500_000e18));

        // Skip if collateral > available liquidity
        if (collateral.gt(totalAssets)) {
            return;
        }

        PoolState memory pool = PoolState({
            totalAssets: totalAssets,
            lockedCollateral: ZERO,
            availableLiquidity: totalAssets,
            totalPremiumsCollected: ZERO,
            totalPayoutsMade: ZERO,
            netDelta: ZERO
        });

        PoolState memory updated = Integrationtest.updatePoolAfterMint(pool, premium, collateral);

        // Invariant 1: totalAssets = oldAssets + premium
        assertEq(
            SD59x18.unwrap(updated.totalAssets),
            SD59x18.unwrap(totalAssets.add(premium)),
            "Assets must increase by premium"
        );

        // Invariant 2: lockedCollateral = oldLocked + collateral
        assertEq(
            SD59x18.unwrap(updated.lockedCollateral), SD59x18.unwrap(collateral), "Collateral must be locked"
        );

        // Invariant 3: availableLiquidity = totalAssets - lockedCollateral
        assertEq(
            SD59x18.unwrap(updated.availableLiquidity),
            SD59x18.unwrap(updated.totalAssets.sub(updated.lockedCollateral)),
            "Liquidity = assets - locked"
        );
    }

    /// @notice Invariant: Utilization is in [0, 1]
    function testFuzz_UtilizationInRange(int256 totalAssetsRaw, int256 lockedRaw) public pure {
        SD59x18 totalAssets = sd(bound(totalAssetsRaw, 1e18, 1_000_000_000e18));
        SD59x18 locked = sd(bound(lockedRaw, 0, SD59x18.unwrap(totalAssets)));

        PoolState memory pool = PoolState({
            totalAssets: totalAssets,
            lockedCollateral: locked,
            availableLiquidity: totalAssets.sub(locked),
            totalPremiumsCollected: ZERO,
            totalPayoutsMade: ZERO,
            netDelta: ZERO
        });

        SD59x18 utilization = Integrationtest.calculateUtilization(pool);

        assertTrue(utilization.gte(ZERO), "Utilization must be >= 0");
        assertTrue(utilization.lte(sd(1e18)), "Utilization must be <= 1");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRICE SIMULATION INVARIANT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Simulated price is always positive
    function testFuzz_SimulatedPricePositive(int256 priceRaw, int256 changeRaw) public pure {
        SD59x18 price = _boundPrice(priceRaw);
        // Bound change to reasonable range (-99% to +1000%)
        SD59x18 change = sd(bound(changeRaw, -990000000000000000, 10_000000000000000000));

        SD59x18 newPrice = Integrationtest.simulatePriceMove(price, change);

        assertTrue(newPrice.gt(ZERO), "Simulated price must be positive");
    }

    /// @notice Invariant: Price change math is correct
    function testFuzz_PriceChangeCalculation(int256 priceRaw, int256 changeRaw) public pure {
        SD59x18 price = _boundPrice(priceRaw);
        // Bound to positive changes to avoid near-zero price issues
        SD59x18 change = sd(bound(changeRaw, 0, 1_000000000000000000)); // 0% to 100%

        SD59x18 newPrice = Integrationtest.simulatePriceMove(price, change);

        // newPrice = price * (1 + change)
        SD59x18 expected = price.mul(sd(1e18).add(change));

        // Allow small rounding error
        SD59x18 diff = newPrice.sub(expected).abs();
        assertTrue(diff.lt(sd(1e12)), "Price change calculation must be correct");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TIME UTILITY INVARIANT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Invariant: Time to expiry is correctly annualized
    function testFuzz_TimeToExpiryAnnualized(uint64 expiryOffset) public view {
        // Bound offset to 1 hour to 2 years
        expiryOffset = uint64(bound(expiryOffset, 3600, 63072000));
        uint64 expiry = uint64(block.timestamp + expiryOffset);

        SD59x18 timeToExpiry = Integrationtest.calculateTimeToExpiry(expiry, block.timestamp);

        // timeToExpiry should be expiryOffset / 31536000 (seconds per year)
        SD59x18 expected = sd(int256(uint256(expiryOffset) * 1e18)).div(sd(31536000e18));

        // Allow small rounding error
        SD59x18 diff = timeToExpiry.sub(expected).abs();
        assertTrue(diff.lt(sd(1e15)), "Time annualization must be correct");
    }

    /// @notice Invariant: isExpired correctly identifies expired options
    function testFuzz_IsExpiredCorrect(uint64 offset, bool shouldBeExpired) public view {
        offset = uint64(bound(offset, 1, 365 days));

        uint64 expiry;
        if (shouldBeExpired) {
            // Safe subtraction - we know block.timestamp > offset because offset is bounded
            expiry = block.timestamp > offset ? uint64(block.timestamp - offset) : 0;
        } else {
            expiry = uint64(block.timestamp + offset);
        }

        bool isExpired = Integrationtest.isExpired(expiry, block.timestamp);

        if (shouldBeExpired && expiry > 0) {
            assertTrue(isExpired, "Past expiry should be expired");
        } else if (!shouldBeExpired) {
            assertFalse(isExpired, "Future expiry should not be expired");
        }
    }
}
