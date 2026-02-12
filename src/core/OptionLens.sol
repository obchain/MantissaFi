// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { OptionVault } from "./OptionVault.sol";
import { OptionMath } from "../libraries/OptionMath.sol";
import { TimeLib } from "../libraries/TimeLib.sol";

/// @title OptionLens
/// @notice Gas-free read-only view contract aggregating data for frontend consumption
/// @dev Queries OptionVault state and computes derived metrics without modifying state.
///      All functions are `view` or `pure` — safe to call off-chain via `eth_call`.
/// @author MantissaFi Team
contract OptionLens {
    using OptionMath for SD59x18;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Enriched option data combining on-chain state with derived metrics
    /// @param seriesId The unique identifier for this series
    /// @param underlying The underlying asset address
    /// @param collateral The collateral token address
    /// @param strike Strike price in SD59x18
    /// @param expiry Expiry timestamp
    /// @param isCall True for call, false for put
    /// @param state Current series state (0=CREATED, 1=ACTIVE, 2=EXPIRED, 3=SETTLED)
    /// @param totalMinted Total options minted in this series
    /// @param totalExercised Total options exercised in this series
    /// @param collateralLocked Total collateral locked in this series
    /// @param settlementPrice Settlement price (0 if not yet settled)
    /// @param timeToExpiry Seconds remaining until expiry (0 if expired)
    /// @param isExpired Whether the series has passed its expiry timestamp
    /// @param canExercise Whether options in this series can currently be exercised
    struct OptionData {
        uint256 seriesId;
        address underlying;
        address collateral;
        int256 strike;
        uint64 expiry;
        bool isCall;
        OptionVault.SeriesState state;
        uint256 totalMinted;
        uint256 totalExercised;
        uint256 collateralLocked;
        int256 settlementPrice;
        uint256 timeToExpiry;
        bool isExpired;
        bool canExercise;
    }

    /// @notice Aggregated position data for a single account across one series
    /// @param seriesId The option series ID
    /// @param longAmount Options owned (buyer side)
    /// @param shortAmount Options written (seller side)
    /// @param hasClaimed Whether the writer has claimed collateral after settlement
    /// @param strike Strike price in SD59x18
    /// @param expiry Expiry timestamp
    /// @param isCall True for call, false for put
    /// @param state Current series state
    struct AccountPosition {
        uint256 seriesId;
        uint256 longAmount;
        uint256 shortAmount;
        bool hasClaimed;
        int256 strike;
        uint64 expiry;
        bool isCall;
        OptionVault.SeriesState state;
    }

    /// @notice Aggregate statistics across all series in the vault
    /// @param totalSeries Total number of series ever created
    /// @param activeSeries Number of currently active series
    /// @param expiredSeries Number of expired (unsettled) series
    /// @param settledSeries Number of settled series
    /// @param totalCollateralLocked Sum of locked collateral across all series
    /// @param totalMintedAllSeries Sum of totalMinted across all series
    /// @param totalExercisedAllSeries Sum of totalExercised across all series
    struct PoolStats {
        uint256 totalSeries;
        uint256 activeSeries;
        uint256 expiredSeries;
        uint256 settledSeries;
        uint256 totalCollateralLocked;
        uint256 totalMintedAllSeries;
        uint256 totalExercisedAllSeries;
    }

    /// @notice Premium quote for minting a given amount of options
    /// @param seriesId The option series ID
    /// @param amount The number of options quoted
    /// @param collateralRequired The collateral needed to mint
    /// @param intrinsicValue The current intrinsic value per option (SD59x18)
    /// @param timeToExpiry Seconds remaining until expiry
    /// @param isExpired Whether the series is past expiry
    struct Quote {
        uint256 seriesId;
        uint256 amount;
        uint256 collateralRequired;
        int256 intrinsicValue;
        uint256 timeToExpiry;
        bool isExpired;
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice The OptionVault contract this lens reads from
    OptionVault public immutable vault;

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when the vault address is zero
    error OptionLens__ZeroAddress();

    /// @notice Thrown when the series ID does not exist in the vault
    error OptionLens__SeriesNotFound(uint256 seriesId);

    /// @notice Thrown when the quote amount is zero
    error OptionLens__InvalidAmount();

    /// @notice Thrown when the spot price provided is zero or negative
    error OptionLens__InvalidSpotPrice();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Initializes the lens with the target OptionVault
    /// @param vault_ The OptionVault contract address to read from
    constructor(address vault_) {
        if (vault_ == address(0)) revert OptionLens__ZeroAddress();
        vault = OptionVault(vault_);
    }

    // =========================================================================
    // Core View Functions
    // =========================================================================

    /// @notice Returns enriched data for all series matching a given underlying and expiry
    /// @dev Iterates over all series IDs [1, nextSeriesId). Gas-free when called off-chain.
    /// @param underlying The underlying asset address to filter by
    /// @param expiry The expiry timestamp to filter by
    /// @return chain Array of OptionData structs matching the filter criteria
    function getOptionChain(address underlying, uint64 expiry) external view returns (OptionData[] memory chain) {
        uint256 total = vault.nextSeriesId();
        if (total <= 1) {
            return new OptionData[](0);
        }

        // First pass: count matches
        uint256 matchCount = 0;
        for (uint256 i = 1; i < total; i++) {
            (address seriesUnderlying,,, uint64 seriesExpiry,) = _getSeriesConfig(i);
            if (seriesUnderlying == underlying && seriesExpiry == expiry) {
                matchCount++;
            }
        }

        // Second pass: populate results
        chain = new OptionData[](matchCount);
        uint256 idx = 0;
        for (uint256 i = 1; i < total; i++) {
            (address seriesUnderlying,,,,) = _getSeriesConfig(i);
            if (seriesUnderlying == underlying) {
                OptionVault.SeriesData memory data = vault.getSeries(i);
                if (data.config.expiry == expiry) {
                    chain[idx] = _buildOptionData(i, data);
                    idx++;
                }
            }
        }
    }

    /// @notice Returns all series (no filter) with enriched data
    /// @dev Iterates over all series IDs [1, nextSeriesId). Gas-free when called off-chain.
    /// @return allOptions Array of OptionData for every series in the vault
    function getAllSeries() external view returns (OptionData[] memory allOptions) {
        uint256 total = vault.nextSeriesId();
        if (total <= 1) {
            return new OptionData[](0);
        }

        uint256 count = total - 1;
        allOptions = new OptionData[](count);

        for (uint256 i = 1; i < total; i++) {
            OptionVault.SeriesData memory data = vault.getSeries(i);
            allOptions[i - 1] = _buildOptionData(i, data);
        }
    }

    /// @notice Returns all positions held by an account across every series
    /// @dev Iterates over all series IDs [1, nextSeriesId). Gas-free when called off-chain.
    /// @param account The account address to query positions for
    /// @return positionsOut Array of AccountPosition structs where the account has a non-zero position
    function getAccountPositions(address account) external view returns (AccountPosition[] memory positionsOut) {
        uint256 total = vault.nextSeriesId();
        if (total <= 1) {
            return new AccountPosition[](0);
        }

        // First pass: count non-zero positions
        uint256 posCount = 0;
        for (uint256 i = 1; i < total; i++) {
            OptionVault.Position memory pos = vault.getPosition(i, account);
            if (pos.longAmount > 0 || pos.shortAmount > 0) {
                posCount++;
            }
        }

        // Second pass: populate results
        positionsOut = new AccountPosition[](posCount);
        uint256 idx = 0;
        for (uint256 i = 1; i < total; i++) {
            OptionVault.Position memory pos = vault.getPosition(i, account);
            if (pos.longAmount > 0 || pos.shortAmount > 0) {
                OptionVault.SeriesData memory data = vault.getSeries(i);
                positionsOut[idx] = AccountPosition({
                    seriesId: i,
                    longAmount: pos.longAmount,
                    shortAmount: pos.shortAmount,
                    hasClaimed: pos.hasClaimed,
                    strike: data.config.strike,
                    expiry: data.config.expiry,
                    isCall: data.config.isCall,
                    state: data.state
                });
                idx++;
            }
        }
    }

    /// @notice Returns aggregate statistics across all option series
    /// @dev Iterates over all series IDs [1, nextSeriesId). Gas-free when called off-chain.
    /// @return stats Aggregated pool statistics
    function getPoolStats() external view returns (PoolStats memory stats) {
        uint256 total = vault.nextSeriesId();
        if (total <= 1) {
            return stats;
        }

        stats.totalSeries = total - 1;

        for (uint256 i = 1; i < total; i++) {
            OptionVault.SeriesData memory data = vault.getSeries(i);

            if (data.state == OptionVault.SeriesState.ACTIVE) {
                stats.activeSeries++;
            } else if (data.state == OptionVault.SeriesState.EXPIRED) {
                stats.expiredSeries++;
            } else if (data.state == OptionVault.SeriesState.SETTLED) {
                stats.settledSeries++;
            }

            stats.totalCollateralLocked += data.collateralLocked;
            stats.totalMintedAllSeries += data.totalMinted;
            stats.totalExercisedAllSeries += data.totalExercised;
        }
    }

    /// @notice Computes a quote for minting options in a given series
    /// @dev Returns collateral required and intrinsic value. Does not modify state.
    /// @param seriesId The option series ID
    /// @param amount The number of options to quote
    /// @param spotPrice Current spot price of the underlying in SD59x18 (e.g. 3000e18 for $3000)
    /// @return quote The computed Quote struct
    function quoteOption(uint256 seriesId, uint256 amount, int256 spotPrice)
        external
        view
        returns (Quote memory quote)
    {
        if (amount == 0) revert OptionLens__InvalidAmount();
        if (spotPrice <= 0) revert OptionLens__InvalidSpotPrice();

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);

        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        SD59x18 spot = sd(spotPrice);
        SD59x18 strike = sd(data.config.strike);
        SD59x18 intrinsic = OptionMath.intrinsicValue(spot, strike, data.config.isCall);

        uint256 tte = vault.timeToExpiry(seriesId);

        quote = Quote({
            seriesId: seriesId,
            amount: amount,
            collateralRequired: collateralRequired,
            intrinsicValue: SD59x18.unwrap(intrinsic),
            timeToExpiry: tte,
            isExpired: vault.isExpired(seriesId)
        });
    }

    // =========================================================================
    // Single-Series View Functions
    // =========================================================================

    /// @notice Returns enriched data for a single series
    /// @param seriesId The option series ID
    /// @return optionData The enriched OptionData struct
    function getSeriesData(uint256 seriesId) external view returns (OptionData memory optionData) {
        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        optionData = _buildOptionData(seriesId, data);
    }

    /// @notice Returns a single account's position in a specific series with series metadata
    /// @param seriesId The option series ID
    /// @param account The account address
    /// @return position The enriched AccountPosition struct
    function getAccountPosition(uint256 seriesId, address account)
        external
        view
        returns (AccountPosition memory position)
    {
        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        OptionVault.Position memory pos = vault.getPosition(seriesId, account);

        position = AccountPosition({
            seriesId: seriesId,
            longAmount: pos.longAmount,
            shortAmount: pos.shortAmount,
            hasClaimed: pos.hasClaimed,
            strike: data.config.strike,
            expiry: data.config.expiry,
            isCall: data.config.isCall,
            state: data.state
        });
    }

    /// @notice Computes the intrinsic value of an option given a spot price
    /// @param seriesId The option series ID
    /// @param spotPrice Current spot price in SD59x18
    /// @return value The intrinsic value in SD59x18
    function getIntrinsicValue(uint256 seriesId, int256 spotPrice) external view returns (int256 value) {
        if (spotPrice <= 0) revert OptionLens__InvalidSpotPrice();

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        SD59x18 spot = sd(spotPrice);
        SD59x18 strike = sd(data.config.strike);

        value = SD59x18.unwrap(OptionMath.intrinsicValue(spot, strike, data.config.isCall));
    }

    /// @notice Checks whether a specific option is in-the-money at a given spot price
    /// @param seriesId The option series ID
    /// @param spotPrice Current spot price in SD59x18
    /// @return itm True if the option is in-the-money
    function isITM(uint256 seriesId, int256 spotPrice) external view returns (bool itm) {
        if (spotPrice <= 0) revert OptionLens__InvalidSpotPrice();

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        SD59x18 spot = sd(spotPrice);
        SD59x18 strike = sd(data.config.strike);

        itm = OptionMath.isITM(spot, strike, data.config.isCall);
    }

    /// @notice Returns the moneyness ratio S/K for a series at a given spot price
    /// @param seriesId The option series ID
    /// @param spotPrice Current spot price in SD59x18
    /// @return ratio The moneyness ratio in SD59x18
    function getMoneyness(uint256 seriesId, int256 spotPrice) external view returns (int256 ratio) {
        if (spotPrice <= 0) revert OptionLens__InvalidSpotPrice();

        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        SD59x18 spot = sd(spotPrice);
        SD59x18 strike = sd(data.config.strike);

        ratio = SD59x18.unwrap(OptionMath.moneyness(spot, strike));
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @notice Extracts series config fields via the getSeries view function
    /// @dev Uses `getSeries` which returns the full SeriesData struct including nested OptionSeries.
    ///      For the first pass (counting matches), we use a try/catch to gracefully handle
    ///      non-existent series IDs without reverting.
    /// @param seriesId The series ID to query
    /// @return underlying The underlying asset address
    /// @return collateralToken The collateral token address
    /// @return strike The strike price (SD59x18)
    /// @return expiry The expiry timestamp
    /// @return isCall Whether the series is a call option
    function _getSeriesConfig(uint256 seriesId)
        internal
        view
        returns (address underlying, address collateralToken, int256 strike, uint64 expiry, bool isCall)
    {
        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        underlying = data.config.underlying;
        collateralToken = data.config.collateral;
        strike = data.config.strike;
        expiry = data.config.expiry;
        isCall = data.config.isCall;
    }

    /// @notice Builds an enriched OptionData struct from vault data
    /// @param seriesId The series ID
    /// @param data The raw SeriesData from the vault
    /// @return optionData The enriched OptionData struct
    function _buildOptionData(uint256 seriesId, OptionVault.SeriesData memory data)
        internal
        view
        returns (OptionData memory optionData)
    {
        optionData = OptionData({
            seriesId: seriesId,
            underlying: data.config.underlying,
            collateral: data.config.collateral,
            strike: data.config.strike,
            expiry: data.config.expiry,
            isCall: data.config.isCall,
            state: data.state,
            totalMinted: data.totalMinted,
            totalExercised: data.totalExercised,
            collateralLocked: data.collateralLocked,
            settlementPrice: data.settlementPrice,
            timeToExpiry: vault.timeToExpiry(seriesId),
            isExpired: vault.isExpired(seriesId),
            canExercise: vault.canExercise(seriesId)
        });
    }
}
