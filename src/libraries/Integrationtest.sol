// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import { Constants } from "./Constants.sol";
import { CumulativeNormal } from "./CumulativeNormal.sol";

/// @title Integrationtest
/// @author MantissaFi Team
/// @notice Library providing infrastructure for full option lifecycle integration testing
/// @dev Implements mock oracles, option structures, and helper functions for:
///      - LP deposits/withdrawals
///      - Option minting with BSM pricing
///      - Oracle price updates
///      - ITM/OTM exercise and settlement
///      - Batch operations and multi-series support

// ═══════════════════════════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Thrown when attempting to operate on an expired option
/// @param optionId The ID of the expired option
/// @param expiry The expiry timestamp
/// @param currentTime The current block timestamp
error OptionExpired(uint256 optionId, uint64 expiry, uint256 currentTime);

/// @notice Thrown when attempting to exercise an option that hasn't expired
/// @param optionId The ID of the option
/// @param expiry The expiry timestamp
/// @param currentTime The current block timestamp
error OptionNotExpired(uint256 optionId, uint64 expiry, uint256 currentTime);

/// @notice Thrown when attempting to exercise an OTM option
/// @param optionId The ID of the option
/// @param spotPrice The current spot price
/// @param strikePrice The option strike price
error OptionNotITM(uint256 optionId, SD59x18 spotPrice, SD59x18 strikePrice);

/// @notice Thrown when there is insufficient liquidity in the pool
/// @param required The required amount
/// @param available The available amount
error InsufficientLiquidity(uint256 required, uint256 available);

/// @notice Thrown when there is insufficient collateral for an operation
/// @param required The required collateral
/// @param available The available collateral
error InsufficientCollateral(uint256 required, uint256 available);

/// @notice Thrown when premium payment is insufficient
/// @param required The required premium
/// @param provided The provided premium
error InsufficientPremium(SD59x18 required, SD59x18 provided);

/// @notice Thrown when attempting to withdraw more than available balance
/// @param requested The requested withdrawal amount
/// @param available The available balance
error InsufficientBalance(uint256 requested, uint256 available);

/// @notice Thrown when an invalid strike price is provided
/// @param strike The invalid strike price
error InvalidStrike(SD59x18 strike);

/// @notice Thrown when an invalid expiry is provided
/// @param expiry The invalid expiry timestamp
error InvalidExpiry(uint64 expiry);

/// @notice Thrown when an invalid volatility is provided
/// @param volatility The invalid volatility value
error InvalidVolatility(SD59x18 volatility);

/// @notice Thrown when time to expiry is zero or negative
error ZeroTimeToExpiry();

/// @notice Thrown when option amount is zero
error ZeroAmount();

/// @notice Thrown when an invalid option ID is referenced
/// @param optionId The invalid option ID
error InvalidOptionId(uint256 optionId);

/// @notice Thrown when oracle price is stale
/// @param lastUpdate The last update timestamp
/// @param currentTime The current block timestamp
/// @param maxAge The maximum allowed age
error StalePriceData(uint256 lastUpdate, uint256 currentTime, uint256 maxAge);

/// @notice Thrown when oracle returns invalid price
/// @param price The invalid price
error InvalidOraclePrice(int256 price);

/// @notice Thrown when batch operation has mismatched array lengths
/// @param length1 First array length
/// @param length2 Second array length
error ArrayLengthMismatch(uint256 length1, uint256 length2);

/// @notice Thrown when batch size exceeds maximum
/// @param size The provided batch size
/// @param max The maximum allowed batch size
error BatchSizeTooLarge(uint256 size, uint256 max);

// ═══════════════════════════════════════════════════════════════════════════════
// STRUCTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Represents an option series configuration
/// @param underlying Address of the underlying asset (e.g., WETH)
/// @param collateral Address of the collateral asset (e.g., USDC)
/// @param expiry Unix timestamp of option expiry
/// @param strikePrice Strike price in SD59x18 format
/// @param isCall True for call option, false for put option
struct OptionSeries {
    address underlying;
    address collateral;
    uint64 expiry;
    SD59x18 strikePrice;
    bool isCall;
}

/// @notice Represents a minted option position
/// @param seriesId ID of the option series
/// @param holder Address of the option holder
/// @param amount Number of options (SD59x18 format, 1e18 = 1 option)
/// @param premiumPaid Total premium paid for this position
/// @param collateralLocked Collateral locked for this position
/// @param isExercised Whether the option has been exercised
/// @param isSettled Whether the option has been settled post-expiry
struct OptionPosition {
    uint256 seriesId;
    address holder;
    SD59x18 amount;
    SD59x18 premiumPaid;
    SD59x18 collateralLocked;
    bool isExercised;
    bool isSettled;
}

/// @notice Represents the state of the liquidity pool
/// @param totalAssets Total assets deposited in the pool
/// @param lockedCollateral Collateral currently locked for written options
/// @param availableLiquidity Assets available for new option writing
/// @param totalPremiumsCollected Cumulative premiums collected
/// @param totalPayoutsMade Cumulative payouts to option exercisers
/// @param netDelta Net delta exposure of the pool
struct PoolState {
    SD59x18 totalAssets;
    SD59x18 lockedCollateral;
    SD59x18 availableLiquidity;
    SD59x18 totalPremiumsCollected;
    SD59x18 totalPayoutsMade;
    SD59x18 netDelta;
}

/// @notice Represents oracle price data
/// @param price Current spot price in SD59x18 format
/// @param timestamp Timestamp of the price update
/// @param roundId Oracle round ID for tracking
struct OraclePrice {
    SD59x18 price;
    uint64 timestamp;
    uint80 roundId;
}

/// @notice Represents the result of an exercise operation
/// @param payoff The payoff amount received
/// @param collateralReturned Collateral returned to the pool
/// @param wasITM Whether the option was in-the-money
struct ExerciseResult {
    SD59x18 payoff;
    SD59x18 collateralReturned;
    bool wasITM;
}

/// @notice Represents Black-Scholes pricing inputs
/// @param spot Current spot price (S)
/// @param strike Strike price (K)
/// @param volatility Implied volatility (sigma)
/// @param riskFreeRate Risk-free rate (r)
/// @param timeToExpiry Time to expiry in years (T)
struct BSMInputs {
    SD59x18 spot;
    SD59x18 strike;
    SD59x18 volatility;
    SD59x18 riskFreeRate;
    SD59x18 timeToExpiry;
}

/// @notice Represents Black-Scholes pricing outputs including Greeks
/// @param price Option premium
/// @param delta Rate of change of price with respect to spot
/// @param gamma Rate of change of delta with respect to spot
/// @param theta Rate of change of price with respect to time
/// @param vega Rate of change of price with respect to volatility
struct BSMOutputs {
    SD59x18 price;
    SD59x18 delta;
    SD59x18 gamma;
    SD59x18 theta;
    SD59x18 vega;
}

/// @notice Represents LP (Liquidity Provider) position
/// @param depositor Address of the LP
/// @param shares LP shares owned
/// @param depositedAt Timestamp of deposit
/// @param lastWithdrawAt Timestamp of last withdrawal
struct LPPosition {
    address depositor;
    SD59x18 shares;
    uint64 depositedAt;
    uint64 lastWithdrawAt;
}

/// @notice Batch mint request structure
/// @param seriesId ID of the option series to mint
/// @param amount Number of options to mint
/// @param maxPremium Maximum premium willing to pay (slippage protection)
struct BatchMintRequest {
    uint256 seriesId;
    SD59x18 amount;
    SD59x18 maxPremium;
}

/// @notice Batch exercise request structure
/// @param optionId ID of the option position to exercise
struct BatchExerciseRequest {
    uint256 optionId;
}

// ═══════════════════════════════════════════════════════════════════════════════
// LIBRARY
// ═══════════════════════════════════════════════════════════════════════════════

/// @title Integrationtest Library
/// @notice Core library for integration test infrastructure
library Integrationtest {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Maximum staleness for oracle price data (1 hour)
    uint256 internal constant MAX_ORACLE_STALENESS = 3600;

    /// @notice Maximum batch size for batch operations
    uint256 internal constant MAX_BATCH_SIZE = 50;

    /// @notice Minimum time to expiry for new options (1 hour)
    uint256 internal constant MIN_TIME_TO_EXPIRY = 3600;

    /// @notice Collateral ratio for written options (150%)
    SD59x18 internal constant COLLATERAL_RATIO = SD59x18.wrap(1_500000000000000000);

    /// @notice Minimum volatility (1%)
    SD59x18 internal constant MIN_VOLATILITY = SD59x18.wrap(10000000000000000);

    /// @notice Maximum volatility (500%)
    SD59x18 internal constant MAX_VOLATILITY = SD59x18.wrap(5_000000000000000000);

    /// @notice Default risk-free rate (5%)
    SD59x18 internal constant DEFAULT_RISK_FREE_RATE = SD59x18.wrap(50000000000000000);

    /// @notice Seconds per year for time conversion
    SD59x18 internal constant SECONDS_PER_YEAR = SD59x18.wrap(31536000_000000000000000000);

    // ═══════════════════════════════════════════════════════════════════════════
    // BSM PRICING FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes d1 parameter for Black-Scholes formula
    /// @dev d1 = [ln(S/K) + (r + sigma^2/2) * T] / (sigma * sqrt(T))
    /// @param inputs BSM pricing inputs
    /// @return d1 The d1 parameter in SD59x18 format
    function computeD1(BSMInputs memory inputs) internal pure returns (SD59x18 d1) {
        if (inputs.timeToExpiry.lte(ZERO)) {
            revert ZeroTimeToExpiry();
        }

        // ln(S/K)
        SD59x18 moneyness = inputs.spot.div(inputs.strike).ln();

        // sigma^2 / 2
        SD59x18 varianceHalf = inputs.volatility.mul(inputs.volatility).div(sd(2e18));

        // r + sigma^2/2
        SD59x18 drift = inputs.riskFreeRate.add(varianceHalf);

        // (r + sigma^2/2) * T
        SD59x18 driftTerm = drift.mul(inputs.timeToExpiry);

        // sigma * sqrt(T)
        SD59x18 volatilityTerm = inputs.volatility.mul(inputs.timeToExpiry.sqrt());

        // d1 = [ln(S/K) + (r + sigma^2/2) * T] / (sigma * sqrt(T))
        d1 = moneyness.add(driftTerm).div(volatilityTerm);
    }

    /// @notice Computes d2 parameter for Black-Scholes formula
    /// @dev d2 = d1 - sigma * sqrt(T)
    /// @param inputs BSM pricing inputs
    /// @param d1 The pre-computed d1 parameter
    /// @return d2 The d2 parameter in SD59x18 format
    function computeD2(BSMInputs memory inputs, SD59x18 d1) internal pure returns (SD59x18 d2) {
        SD59x18 volatilityTerm = inputs.volatility.mul(inputs.timeToExpiry.sqrt());
        d2 = d1.sub(volatilityTerm);
    }

    /// @notice Prices a European call option using Black-Scholes-Merton
    /// @dev C = S * Phi(d1) - K * e^(-rT) * Phi(d2)
    /// @param inputs BSM pricing inputs
    /// @return price The call option premium in SD59x18 format
    function priceCall(BSMInputs memory inputs) internal pure returns (SD59x18 price) {
        _validateBSMInputs(inputs);

        SD59x18 d1 = computeD1(inputs);
        SD59x18 d2 = computeD2(inputs, d1);

        // Phi(d1) and Phi(d2)
        SD59x18 cdfD1 = CumulativeNormal.cdf(d1);
        SD59x18 cdfD2 = CumulativeNormal.cdf(d2);

        // e^(-rT)
        SD59x18 discountFactor = inputs.riskFreeRate.mul(inputs.timeToExpiry).mul(sd(-1e18)).exp();

        // C = S * Phi(d1) - K * e^(-rT) * Phi(d2)
        SD59x18 spotTerm = inputs.spot.mul(cdfD1);
        SD59x18 strikeTerm = inputs.strike.mul(discountFactor).mul(cdfD2);

        price = spotTerm.sub(strikeTerm);

        // Ensure non-negative price
        if (price.lt(ZERO)) {
            price = ZERO;
        }
    }

    /// @notice Prices a European put option using Black-Scholes-Merton
    /// @dev P = K * e^(-rT) * Phi(-d2) - S * Phi(-d1)
    /// @param inputs BSM pricing inputs
    /// @return price The put option premium in SD59x18 format
    function pricePut(BSMInputs memory inputs) internal pure returns (SD59x18 price) {
        _validateBSMInputs(inputs);

        SD59x18 d1 = computeD1(inputs);
        SD59x18 d2 = computeD2(inputs, d1);

        // Phi(-d1) and Phi(-d2)
        SD59x18 cdfNegD1 = CumulativeNormal.cdf(d1.mul(sd(-1e18)));
        SD59x18 cdfNegD2 = CumulativeNormal.cdf(d2.mul(sd(-1e18)));

        // e^(-rT)
        SD59x18 discountFactor = inputs.riskFreeRate.mul(inputs.timeToExpiry).mul(sd(-1e18)).exp();

        // P = K * e^(-rT) * Phi(-d2) - S * Phi(-d1)
        SD59x18 strikeTerm = inputs.strike.mul(discountFactor).mul(cdfNegD2);
        SD59x18 spotTerm = inputs.spot.mul(cdfNegD1);

        price = strikeTerm.sub(spotTerm);

        // Ensure non-negative price
        if (price.lt(ZERO)) {
            price = ZERO;
        }
    }

    /// @notice Computes full BSM pricing with all Greeks
    /// @param inputs BSM pricing inputs
    /// @param isCall True for call option, false for put option
    /// @return outputs BSM outputs including price and all Greeks
    function computeBSM(BSMInputs memory inputs, bool isCall) internal pure returns (BSMOutputs memory outputs) {
        _validateBSMInputs(inputs);

        SD59x18 d1 = computeD1(inputs);
        SD59x18 d2 = computeD2(inputs, d1);

        // Common values
        SD59x18 cdfD1 = CumulativeNormal.cdf(d1);
        SD59x18 cdfD2 = CumulativeNormal.cdf(d2);
        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);
        SD59x18 sqrtT = inputs.timeToExpiry.sqrt();
        SD59x18 discountFactor = inputs.riskFreeRate.mul(inputs.timeToExpiry).mul(sd(-1e18)).exp();

        if (isCall) {
            // Call price: C = S * Phi(d1) - K * e^(-rT) * Phi(d2)
            outputs.price = inputs.spot.mul(cdfD1).sub(inputs.strike.mul(discountFactor).mul(cdfD2));

            // Call delta: Delta = Phi(d1)
            outputs.delta = cdfD1;
        } else {
            // Put price: P = K * e^(-rT) * Phi(-d2) - S * Phi(-d1)
            SD59x18 cdfNegD1 = sd(1e18).sub(cdfD1);
            SD59x18 cdfNegD2 = sd(1e18).sub(cdfD2);
            outputs.price = inputs.strike.mul(discountFactor).mul(cdfNegD2).sub(inputs.spot.mul(cdfNegD1));

            // Put delta: Delta = Phi(d1) - 1
            outputs.delta = cdfD1.sub(sd(1e18));
        }

        // Gamma: Gamma = phi(d1) / (S * sigma * sqrt(T))
        SD59x18 gammaDenom = inputs.spot.mul(inputs.volatility).mul(sqrtT);
        outputs.gamma = pdfD1.div(gammaDenom);

        // Vega: Vega = S * sqrt(T) * phi(d1)
        outputs.vega = inputs.spot.mul(sqrtT).mul(pdfD1);

        // Theta (annualized)
        // Common term: -S * phi(d1) * sigma / (2 * sqrt(T))
        SD59x18 thetaCommon = inputs.spot.mul(pdfD1).mul(inputs.volatility).div(sd(2e18).mul(sqrtT)).mul(sd(-1e18));

        if (isCall) {
            // Call theta: theta_common - r * K * e^(-rT) * Phi(d2)
            SD59x18 rateTerm = inputs.riskFreeRate.mul(inputs.strike).mul(discountFactor).mul(cdfD2);
            outputs.theta = thetaCommon.sub(rateTerm);
        } else {
            // Put theta: theta_common + r * K * e^(-rT) * Phi(-d2)
            SD59x18 cdfNegD2 = sd(1e18).sub(cdfD2);
            SD59x18 rateTerm = inputs.riskFreeRate.mul(inputs.strike).mul(discountFactor).mul(cdfNegD2);
            outputs.theta = thetaCommon.add(rateTerm);
        }

        // Ensure non-negative price
        if (outputs.price.lt(ZERO)) {
            outputs.price = ZERO;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OPTION LIFECYCLE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Calculates the premium for minting an option
    /// @param series The option series configuration
    /// @param amount Number of options to mint
    /// @param spotPrice Current spot price from oracle
    /// @param volatility Implied volatility
    /// @param currentTime Current block timestamp
    /// @return premium Total premium to pay
    function calculateMintPremium(
        OptionSeries memory series,
        SD59x18 amount,
        SD59x18 spotPrice,
        SD59x18 volatility,
        uint256 currentTime
    ) internal pure returns (SD59x18 premium) {
        if (amount.lte(ZERO)) {
            revert ZeroAmount();
        }

        SD59x18 timeToExpiry = _calculateTimeToExpiry(series.expiry, currentTime);

        BSMInputs memory inputs = BSMInputs({
            spot: spotPrice,
            strike: series.strikePrice,
            volatility: volatility,
            riskFreeRate: DEFAULT_RISK_FREE_RATE,
            timeToExpiry: timeToExpiry
        });

        SD59x18 pricePerOption = series.isCall ? priceCall(inputs) : pricePut(inputs);

        premium = pricePerOption.mul(amount);
    }

    /// @notice Calculates required collateral for minting options
    /// @param series The option series configuration
    /// @param amount Number of options to mint
    /// @param spotPrice Current spot price
    /// @return collateral Required collateral amount
    function calculateRequiredCollateral(
        OptionSeries memory series,
        SD59x18 amount,
        SD59x18 spotPrice
    ) internal pure returns (SD59x18 collateral) {
        if (amount.lte(ZERO)) {
            revert ZeroAmount();
        }

        SD59x18 maxPayoff;
        if (series.isCall) {
            // For calls, use max of strike * 1.5 or current spot price
            // This ensures adequate collateral if price rises significantly
            SD59x18 strikeCollateral = series.strikePrice.mul(COLLATERAL_RATIO);
            maxPayoff = spotPrice.gt(strikeCollateral) ? spotPrice : strikeCollateral;
        } else {
            // For puts, max payoff is strike price (if spot goes to 0)
            maxPayoff = series.strikePrice;
        }

        collateral = maxPayoff.mul(amount);
    }

    /// @notice Calculates the payoff for exercising an option
    /// @param series The option series configuration
    /// @param amount Number of options being exercised
    /// @param spotPrice Current spot price at exercise
    /// @return payoff The payoff amount (can be zero if OTM)
    /// @return isITM Whether the option is in-the-money
    function calculateExercisePayoff(
        OptionSeries memory series,
        SD59x18 amount,
        SD59x18 spotPrice
    ) internal pure returns (SD59x18 payoff, bool isITM) {
        if (amount.lte(ZERO)) {
            revert ZeroAmount();
        }

        SD59x18 intrinsicValue;

        if (series.isCall) {
            // Call payoff: max(S - K, 0)
            if (spotPrice.gt(series.strikePrice)) {
                intrinsicValue = spotPrice.sub(series.strikePrice);
                isITM = true;
            }
        } else {
            // Put payoff: max(K - S, 0)
            if (series.strikePrice.gt(spotPrice)) {
                intrinsicValue = series.strikePrice.sub(spotPrice);
                isITM = true;
            }
        }

        payoff = intrinsicValue.mul(amount);
    }

    /// @notice Determines if an option is in-the-money
    /// @param series The option series configuration
    /// @param spotPrice Current spot price
    /// @return True if ITM, false if OTM or ATM
    function isOptionITM(OptionSeries memory series, SD59x18 spotPrice) internal pure returns (bool) {
        if (series.isCall) {
            return spotPrice.gt(series.strikePrice);
        } else {
            return series.strikePrice.gt(spotPrice);
        }
    }

    /// @notice Calculates moneyness ratio (S/K)
    /// @param spotPrice Current spot price
    /// @param strikePrice Strike price
    /// @return moneyness The moneyness ratio
    function calculateMoneyness(SD59x18 spotPrice, SD59x18 strikePrice) internal pure returns (SD59x18 moneyness) {
        if (strikePrice.lte(ZERO)) {
            revert InvalidStrike(strikePrice);
        }
        moneyness = spotPrice.div(strikePrice);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POOL MANAGEMENT FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Calculates LP shares for a deposit
    /// @param depositAmount Amount being deposited
    /// @param totalAssets Current total assets in pool
    /// @param totalShares Current total shares outstanding
    /// @return shares Number of shares to mint
    function calculateDepositShares(
        SD59x18 depositAmount,
        SD59x18 totalAssets,
        SD59x18 totalShares
    ) internal pure returns (SD59x18 shares) {
        if (depositAmount.lte(ZERO)) {
            revert ZeroAmount();
        }

        // If first deposit, shares = deposit amount
        if (totalAssets.lte(ZERO) || totalShares.lte(ZERO)) {
            shares = depositAmount;
        } else {
            // shares = depositAmount * totalShares / totalAssets
            shares = depositAmount.mul(totalShares).div(totalAssets);
        }
    }

    /// @notice Calculates withdrawal amount for given shares
    /// @param sharesToBurn Number of shares to burn
    /// @param totalAssets Current total assets in pool
    /// @param totalShares Current total shares outstanding
    /// @return withdrawAmount Amount to withdraw
    function calculateWithdrawAmount(
        SD59x18 sharesToBurn,
        SD59x18 totalAssets,
        SD59x18 totalShares
    ) internal pure returns (SD59x18 withdrawAmount) {
        if (sharesToBurn.lte(ZERO)) {
            revert ZeroAmount();
        }

        if (totalShares.lte(ZERO)) {
            revert InsufficientBalance(uint256(SD59x18.unwrap(sharesToBurn)), 0);
        }

        // withdrawAmount = sharesToBurn * totalAssets / totalShares
        withdrawAmount = sharesToBurn.mul(totalAssets).div(totalShares);
    }

    /// @notice Updates pool state after a mint operation
    /// @param pool Current pool state
    /// @param premium Premium collected
    /// @param collateralRequired Collateral to lock
    /// @return Updated pool state
    function updatePoolAfterMint(
        PoolState memory pool,
        SD59x18 premium,
        SD59x18 collateralRequired
    ) internal pure returns (PoolState memory) {
        if (pool.availableLiquidity.lt(collateralRequired)) {
            revert InsufficientLiquidity(
                uint256(SD59x18.unwrap(collateralRequired)),
                uint256(SD59x18.unwrap(pool.availableLiquidity))
            );
        }

        pool.totalAssets = pool.totalAssets.add(premium);
        pool.lockedCollateral = pool.lockedCollateral.add(collateralRequired);
        pool.availableLiquidity = pool.totalAssets.sub(pool.lockedCollateral);
        pool.totalPremiumsCollected = pool.totalPremiumsCollected.add(premium);

        return pool;
    }

    /// @notice Updates pool state after an exercise operation
    /// @param pool Current pool state
    /// @param payoff Payoff amount to the exerciser
    /// @param collateralReleased Collateral being released
    /// @return Updated pool state
    function updatePoolAfterExercise(
        PoolState memory pool,
        SD59x18 payoff,
        SD59x18 collateralReleased
    ) internal pure returns (PoolState memory) {
        pool.totalAssets = pool.totalAssets.sub(payoff);
        pool.lockedCollateral = pool.lockedCollateral.sub(collateralReleased);
        pool.availableLiquidity = pool.totalAssets.sub(pool.lockedCollateral);
        pool.totalPayoutsMade = pool.totalPayoutsMade.add(payoff);

        return pool;
    }

    /// @notice Updates pool state after OTM expiry (collateral returned)
    /// @param pool Current pool state
    /// @param collateralReleased Collateral being released
    /// @return Updated pool state
    function updatePoolAfterOTMExpiry(
        PoolState memory pool,
        SD59x18 collateralReleased
    ) internal pure returns (PoolState memory) {
        pool.lockedCollateral = pool.lockedCollateral.sub(collateralReleased);
        pool.availableLiquidity = pool.totalAssets.sub(pool.lockedCollateral);

        return pool;
    }

    /// @notice Calculates pool utilization ratio
    /// @param pool Current pool state
    /// @return utilization Utilization ratio (0 to 1e18)
    function calculateUtilization(PoolState memory pool) internal pure returns (SD59x18 utilization) {
        if (pool.totalAssets.lte(ZERO)) {
            return ZERO;
        }
        utilization = pool.lockedCollateral.div(pool.totalAssets);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates oracle price data
    /// @param priceData The oracle price data to validate
    /// @param currentTime Current block timestamp
    function validateOraclePrice(OraclePrice memory priceData, uint256 currentTime) internal pure {
        if (priceData.price.lte(ZERO)) {
            revert InvalidOraclePrice(SD59x18.unwrap(priceData.price));
        }

        if (currentTime > priceData.timestamp + MAX_ORACLE_STALENESS) {
            revert StalePriceData(priceData.timestamp, currentTime, MAX_ORACLE_STALENESS);
        }
    }

    /// @notice Simulates a price update (for testing)
    /// @param currentPrice Current price
    /// @param priceChangePercent Percentage change (-100 to +infinite, in 1e18 format)
    /// @return newPrice Updated price
    function simulatePriceMove(
        SD59x18 currentPrice,
        SD59x18 priceChangePercent
    ) internal pure returns (SD59x18 newPrice) {
        // newPrice = currentPrice * (1 + priceChangePercent)
        SD59x18 multiplier = sd(1e18).add(priceChangePercent);
        newPrice = currentPrice.mul(multiplier);

        // Ensure positive price
        if (newPrice.lte(ZERO)) {
            newPrice = sd(1); // Minimum price of 1 wei
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BATCH OPERATION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates batch operation size
    /// @param size The batch size to validate
    function validateBatchSize(uint256 size) internal pure {
        if (size > MAX_BATCH_SIZE) {
            revert BatchSizeTooLarge(size, MAX_BATCH_SIZE);
        }
    }

    /// @notice Calculates total premium for batch mint
    /// @param requests Array of mint requests
    /// @param seriesArray Array of option series
    /// @param spotPrice Current spot price
    /// @param volatility Implied volatility
    /// @param currentTime Current block timestamp
    /// @return totalPremium Total premium for all mints
    function calculateBatchMintPremium(
        BatchMintRequest[] memory requests,
        OptionSeries[] memory seriesArray,
        SD59x18 spotPrice,
        SD59x18 volatility,
        uint256 currentTime
    ) internal pure returns (SD59x18 totalPremium) {
        validateBatchSize(requests.length);

        if (requests.length != seriesArray.length) {
            revert ArrayLengthMismatch(requests.length, seriesArray.length);
        }

        for (uint256 i = 0; i < requests.length; i++) {
            SD59x18 premium =
                calculateMintPremium(seriesArray[i], requests[i].amount, spotPrice, volatility, currentTime);
            totalPremium = totalPremium.add(premium);
        }
    }

    /// @notice Calculates total payoff for batch exercise
    /// @param positions Array of option positions
    /// @param seriesArray Corresponding option series
    /// @param spotPrice Current spot price
    /// @return totalPayoff Total payoff for all exercises
    /// @return itmCount Number of ITM options
    function calculateBatchExercisePayoff(
        OptionPosition[] memory positions,
        OptionSeries[] memory seriesArray,
        SD59x18 spotPrice
    ) internal pure returns (SD59x18 totalPayoff, uint256 itmCount) {
        validateBatchSize(positions.length);

        if (positions.length != seriesArray.length) {
            revert ArrayLengthMismatch(positions.length, seriesArray.length);
        }

        for (uint256 i = 0; i < positions.length; i++) {
            (SD59x18 payoff, bool isITM) = calculateExercisePayoff(seriesArray[i], positions[i].amount, spotPrice);

            if (isITM) {
                totalPayoff = totalPayoff.add(payoff);
                itmCount++;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TIME UTILITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Converts timestamp difference to annualized time
    /// @param expiry Expiry timestamp
    /// @param currentTime Current timestamp
    /// @return timeToExpiry Annualized time to expiry
    function calculateTimeToExpiry(uint64 expiry, uint256 currentTime) internal pure returns (SD59x18 timeToExpiry) {
        return _calculateTimeToExpiry(expiry, currentTime);
    }

    /// @notice Checks if an option has expired
    /// @param expiry Expiry timestamp
    /// @param currentTime Current timestamp
    /// @return True if expired, false otherwise
    function isExpired(uint64 expiry, uint256 currentTime) internal pure returns (bool) {
        return currentTime >= expiry;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VALIDATION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates an option series configuration
    /// @param series The option series to validate
    /// @param currentTime Current block timestamp
    function validateOptionSeries(OptionSeries memory series, uint256 currentTime) internal pure {
        if (series.strikePrice.lte(ZERO)) {
            revert InvalidStrike(series.strikePrice);
        }

        if (series.expiry <= currentTime + MIN_TIME_TO_EXPIRY) {
            revert InvalidExpiry(series.expiry);
        }
    }

    /// @notice Validates volatility input
    /// @param volatility The volatility to validate
    function validateVolatility(SD59x18 volatility) internal pure {
        if (volatility.lt(MIN_VOLATILITY) || volatility.gt(MAX_VOLATILITY)) {
            revert InvalidVolatility(volatility);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Internal function to calculate time to expiry
    function _calculateTimeToExpiry(uint64 expiry, uint256 currentTime) private pure returns (SD59x18 timeToExpiry) {
        if (expiry <= currentTime) {
            revert ZeroTimeToExpiry();
        }

        uint256 secondsToExpiry = expiry - currentTime;
        // Convert to annualized: seconds / 31536000
        timeToExpiry = sd(int256(secondsToExpiry * 1e18)).div(SECONDS_PER_YEAR);
    }

    /// @notice Validates BSM pricing inputs
    function _validateBSMInputs(BSMInputs memory inputs) private pure {
        if (inputs.spot.lte(ZERO)) {
            revert InvalidOraclePrice(SD59x18.unwrap(inputs.spot));
        }

        if (inputs.strike.lte(ZERO)) {
            revert InvalidStrike(inputs.strike);
        }

        if (inputs.volatility.lt(MIN_VOLATILITY) || inputs.volatility.gt(MAX_VOLATILITY)) {
            revert InvalidVolatility(inputs.volatility);
        }

        if (inputs.timeToExpiry.lte(ZERO)) {
            revert ZeroTimeToExpiry();
        }
    }
}
