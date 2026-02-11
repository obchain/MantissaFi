// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";

/// @title RealizedVolOracle
/// @notice Computes on-chain realized volatility using EWMA (Exponentially Weighted Moving Average)
/// @dev Uses PRB Math SD59x18 for fixed-point arithmetic
/// @dev Formula: σ²_n = λ · σ²_{n-1} + (1 - λ) · r²_n where r_n = ln(P_n / P_{n-1})
contract RealizedVolOracle {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Configuration for an asset's volatility calculation
    /// @param decayFactor Lambda (λ) decay factor for EWMA (typically 0.94)
    /// @param minObservations Minimum observations required before returning valid volatility
    /// @param annualizationFactor Factor to annualize volatility based on observation frequency
    /// @param isConfigured Whether the asset has been configured
    struct AssetConfig {
        SD59x18 decayFactor;
        uint256 minObservations;
        SD59x18 annualizationFactor;
        bool isConfigured;
    }

    /// @notice Price observation data for an asset
    /// @param price The observed price in SD59x18 format
    /// @param timestamp Block timestamp of the observation
    struct Observation {
        SD59x18 price;
        uint256 timestamp;
    }

    /// @notice Volatility state for an asset
    /// @param variance Current EWMA variance (σ²)
    /// @param observationCount Total number of observations recorded
    /// @param latestObservationIndex Index of the most recent observation in circular buffer
    struct VolatilityState {
        SD59x18 variance;
        uint256 observationCount;
        uint256 latestObservationIndex;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum number of observations to store per asset (circular buffer)
    uint256 public constant MAX_OBSERVATIONS = 256;

    /// @notice Default decay factor (λ = 0.94) commonly used for daily EWMA
    int256 public constant DEFAULT_DECAY_FACTOR = 940000000000000000; // 0.94e18

    /// @notice Minimum allowed decay factor (0.8)
    int256 public constant MIN_DECAY_FACTOR = 800000000000000000; // 0.8e18

    /// @notice Maximum allowed decay factor (0.99)
    int256 public constant MAX_DECAY_FACTOR = 990000000000000000; // 0.99e18

    /// @notice Seconds in a year for annualization (365 days)
    int256 public constant SECONDS_PER_YEAR = 31536000;

    /// @notice Minimum price to prevent division issues
    int256 public constant MIN_PRICE = 1; // 1e-18 in SD59x18

    /// @notice Version of this contract
    string public constant VERSION = "1.0.0";

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner address that can configure assets
    address public owner;

    /// @notice Configuration for each asset
    mapping(address => AssetConfig) public assetConfigs;

    /// @notice Volatility state for each asset
    mapping(address => VolatilityState) public volatilityStates;

    /// @notice Circular buffer of price observations for each asset
    /// @dev asset => index => Observation
    mapping(address => mapping(uint256 => Observation)) public observations;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not the owner
    error Unauthorized();

    /// @notice Thrown when asset is not configured
    error AssetNotConfigured(address asset);

    /// @notice Thrown when asset is already configured
    error AssetAlreadyConfigured(address asset);

    /// @notice Thrown when decay factor is out of valid range
    error InvalidDecayFactor(int256 decayFactor);

    /// @notice Thrown when minimum observations is zero
    error InvalidMinObservations();

    /// @notice Thrown when price is not positive
    error InvalidPrice(int256 price);

    /// @notice Thrown when not enough observations for volatility calculation
    error InsufficientObservations(address asset, uint256 current, uint256 required);

    /// @notice Thrown when window size is invalid
    error InvalidWindow(uint256 window);

    /// @notice Thrown when annualization factor is not positive
    error InvalidAnnualizationFactor(int256 factor);

    /// @notice Thrown when the new owner address is zero
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an asset is configured
    /// @param asset The asset address
    /// @param decayFactor The decay factor (λ)
    /// @param minObservations Minimum observations required
    /// @param annualizationFactor Factor for annualizing volatility
    event AssetConfigured(
        address indexed asset, int256 decayFactor, uint256 minObservations, int256 annualizationFactor
    );

    /// @notice Emitted when volatility is updated for an asset
    /// @param asset The asset address
    /// @param price The new price observation
    /// @param variance The updated EWMA variance
    /// @param observationCount Total observations recorded
    event VolatilityUpdated(address indexed asset, int256 price, int256 variance, uint256 observationCount);

    /// @notice Emitted when ownership is transferred
    /// @param previousOwner The previous owner address
    /// @param newOwner The new owner address
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when asset configuration is updated
    /// @param asset The asset address
    /// @param decayFactor The new decay factor
    /// @param minObservations The new minimum observations
    /// @param annualizationFactor The new annualization factor
    event AssetConfigUpdated(
        address indexed asset, int256 decayFactor, uint256 minObservations, int256 annualizationFactor
    );

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts function access to owner
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Ensures asset is configured
    modifier assetConfigured(address asset) {
        if (!assetConfigs[asset].isConfigured) revert AssetNotConfigured(asset);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the oracle with the deployer as owner
    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfers ownership to a new address
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @notice Configures volatility parameters for an asset
    /// @param asset The asset address to configure
    /// @param decayFactor The decay factor λ (0.8 to 0.99)
    /// @param minObservations Minimum observations before valid volatility
    /// @param annualizationFactor Factor to annualize volatility (e.g., sqrt(365) for daily)
    function configureAsset(address asset, int256 decayFactor, uint256 minObservations, int256 annualizationFactor)
        external
        onlyOwner
    {
        if (assetConfigs[asset].isConfigured) revert AssetAlreadyConfigured(asset);
        if (decayFactor < MIN_DECAY_FACTOR || decayFactor > MAX_DECAY_FACTOR) {
            revert InvalidDecayFactor(decayFactor);
        }
        if (minObservations == 0) revert InvalidMinObservations();
        if (annualizationFactor <= 0) revert InvalidAnnualizationFactor(annualizationFactor);

        assetConfigs[asset] = AssetConfig({
            decayFactor: sd(decayFactor),
            minObservations: minObservations,
            annualizationFactor: sd(annualizationFactor),
            isConfigured: true
        });

        emit AssetConfigured(asset, decayFactor, minObservations, annualizationFactor);
    }

    /// @notice Updates configuration for an already configured asset
    /// @param asset The asset address to update
    /// @param decayFactor The new decay factor λ
    /// @param minObservations New minimum observations
    /// @param annualizationFactor New annualization factor
    function updateAssetConfig(address asset, int256 decayFactor, uint256 minObservations, int256 annualizationFactor)
        external
        onlyOwner
        assetConfigured(asset)
    {
        if (decayFactor < MIN_DECAY_FACTOR || decayFactor > MAX_DECAY_FACTOR) {
            revert InvalidDecayFactor(decayFactor);
        }
        if (minObservations == 0) revert InvalidMinObservations();
        if (annualizationFactor <= 0) revert InvalidAnnualizationFactor(annualizationFactor);

        assetConfigs[asset].decayFactor = sd(decayFactor);
        assetConfigs[asset].minObservations = minObservations;
        assetConfigs[asset].annualizationFactor = sd(annualizationFactor);

        emit AssetConfigUpdated(asset, decayFactor, minObservations, annualizationFactor);
    }

    /*//////////////////////////////////////////////////////////////
                          VOLATILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates volatility with a new price observation
    /// @dev Computes EWMA variance: σ²_n = λ · σ²_{n-1} + (1 - λ) · r²_n
    /// @param asset The asset to update volatility for
    /// @param price The new price observation (must be positive, in SD59x18 format)
    function updateVolatility(address asset, int256 price) external assetConfigured(asset) {
        if (price <= 0) revert InvalidPrice(price);

        SD59x18 priceSD = sd(price);
        VolatilityState storage state = volatilityStates[asset];
        AssetConfig storage config = assetConfigs[asset];

        uint256 newIndex;
        if (state.observationCount == 0) {
            // First observation - just store it, no return calculation possible
            newIndex = 0;
        } else {
            // Calculate new index in circular buffer
            newIndex = (state.latestObservationIndex + 1) % MAX_OBSERVATIONS;

            // Get previous price
            Observation storage prevObs = observations[asset][state.latestObservationIndex];
            SD59x18 prevPrice = prevObs.price;

            // Calculate log return: r = ln(P_n / P_{n-1})
            SD59x18 priceRatio = priceSD.div(prevPrice);
            SD59x18 logReturn = priceRatio.ln();

            // Calculate squared return
            SD59x18 returnSquared = logReturn.mul(logReturn);

            // Update EWMA variance: σ²_n = λ · σ²_{n-1} + (1 - λ) · r²_n
            SD59x18 lambda = config.decayFactor;
            SD59x18 oneMinusLambda = UNIT.sub(lambda);

            SD59x18 newVariance = lambda.mul(state.variance).add(oneMinusLambda.mul(returnSquared));
            state.variance = newVariance;
        }

        // Store new observation
        observations[asset][newIndex] = Observation({ price: priceSD, timestamp: block.timestamp });

        state.latestObservationIndex = newIndex;
        state.observationCount++;

        emit VolatilityUpdated(asset, price, state.variance.unwrap(), state.observationCount);
    }

    /// @notice Gets the current realized volatility for an asset
    /// @dev Returns annualized volatility: σ_annualized = σ · annualizationFactor
    /// @param asset The asset to get volatility for
    /// @return vol The annualized realized volatility in SD59x18 format
    function getRealizedVol(address asset) external view assetConfigured(asset) returns (int256 vol) {
        AssetConfig storage config = assetConfigs[asset];
        VolatilityState storage state = volatilityStates[asset];

        // Need at least minObservations to return valid volatility
        // Note: we need minObservations + 1 prices to get minObservations returns
        if (state.observationCount <= config.minObservations) {
            revert InsufficientObservations(asset, state.observationCount, config.minObservations + 1);
        }

        // Calculate standard deviation from variance and annualize
        SD59x18 stdDev = state.variance.sqrt();
        SD59x18 annualizedVol = stdDev.mul(config.annualizationFactor);

        return annualizedVol.unwrap();
    }

    /// @notice Gets realized volatility calculated from a specific window of observations
    /// @dev Recalculates volatility from the last `window` observations
    /// @param asset The asset to get volatility for
    /// @param window Number of recent observations to use (2 to MAX_OBSERVATIONS)
    /// @return vol The annualized realized volatility in SD59x18 format
    function getRealizedVol(address asset, uint256 window) external view assetConfigured(asset) returns (int256 vol) {
        if (window < 2 || window > MAX_OBSERVATIONS) revert InvalidWindow(window);

        AssetConfig storage config = assetConfigs[asset];
        VolatilityState storage state = volatilityStates[asset];

        // Need enough observations
        if (state.observationCount < window) {
            revert InsufficientObservations(asset, state.observationCount, window);
        }

        // Calculate variance over the window using EWMA
        SD59x18 variance = ZERO;
        SD59x18 lambda = config.decayFactor;
        SD59x18 oneMinusLambda = UNIT.sub(lambda);

        // Start from the oldest observation in our window and move forward
        uint256 startIndex;
        if (state.observationCount >= MAX_OBSERVATIONS) {
            // Buffer is full, calculate starting point
            startIndex = (state.latestObservationIndex + MAX_OBSERVATIONS - window + 1) % MAX_OBSERVATIONS;
        } else {
            // Buffer not full yet
            startIndex = state.observationCount - window;
        }

        // Get the first price in window
        SD59x18 prevPrice = observations[asset][startIndex].price;

        // Process window - 1 returns (we have window prices, so window - 1 returns)
        for (uint256 i = 1; i < window; i++) {
            uint256 currentIndex;
            if (state.observationCount >= MAX_OBSERVATIONS) {
                currentIndex = (startIndex + i) % MAX_OBSERVATIONS;
            } else {
                currentIndex = startIndex + i;
            }

            SD59x18 currentPrice = observations[asset][currentIndex].price;

            // Calculate log return
            SD59x18 priceRatio = currentPrice.div(prevPrice);
            SD59x18 logReturn = priceRatio.ln();
            SD59x18 returnSquared = logReturn.mul(logReturn);

            // Apply EWMA: σ²_n = λ · σ²_{n-1} + (1 - λ) · r²_n
            variance = lambda.mul(variance).add(oneMinusLambda.mul(returnSquared));

            prevPrice = currentPrice;
        }

        // Calculate standard deviation and annualize
        SD59x18 stdDev = variance.sqrt();
        SD59x18 annualizedVol = stdDev.mul(config.annualizationFactor);

        return annualizedVol.unwrap();
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gets the raw variance for an asset
    /// @param asset The asset address
    /// @return The current EWMA variance in SD59x18 format
    function getVariance(address asset) external view assetConfigured(asset) returns (int256) {
        return volatilityStates[asset].variance.unwrap();
    }

    /// @notice Gets the number of observations recorded for an asset
    /// @param asset The asset address
    /// @return The total observation count
    function getObservationCount(address asset) external view assetConfigured(asset) returns (uint256) {
        return volatilityStates[asset].observationCount;
    }

    /// @notice Gets the latest observation for an asset
    /// @param asset The asset address
    /// @return price The latest price in SD59x18 format
    /// @return timestamp The timestamp of the observation
    function getLatestObservation(address asset)
        external
        view
        assetConfigured(asset)
        returns (int256 price, uint256 timestamp)
    {
        VolatilityState storage state = volatilityStates[asset];
        if (state.observationCount == 0) {
            return (0, 0);
        }

        Observation storage obs = observations[asset][state.latestObservationIndex];
        return (obs.price.unwrap(), obs.timestamp);
    }

    /// @notice Gets an observation at a specific index in the circular buffer
    /// @param asset The asset address
    /// @param index The index in the circular buffer (0 to MAX_OBSERVATIONS - 1)
    /// @return price The price at that index in SD59x18 format
    /// @return timestamp The timestamp of the observation
    function getObservationAt(address asset, uint256 index)
        external
        view
        assetConfigured(asset)
        returns (int256 price, uint256 timestamp)
    {
        if (index >= MAX_OBSERVATIONS) revert InvalidWindow(index);

        Observation storage obs = observations[asset][index];
        return (obs.price.unwrap(), obs.timestamp);
    }

    /// @notice Checks if an asset has enough observations for volatility calculation
    /// @param asset The asset address
    /// @return True if volatility can be calculated
    function hasValidVolatility(address asset) external view returns (bool) {
        if (!assetConfigs[asset].isConfigured) return false;

        AssetConfig storage config = assetConfigs[asset];
        VolatilityState storage state = volatilityStates[asset];

        return state.observationCount > config.minObservations;
    }

    /// @notice Gets the full configuration for an asset
    /// @param asset The asset address
    /// @return decayFactor The decay factor λ in SD59x18 format
    /// @return minObservations Minimum observations required
    /// @return annualizationFactor The annualization factor in SD59x18 format
    /// @return isConfigured Whether the asset is configured
    function getAssetConfig(address asset)
        external
        view
        returns (int256 decayFactor, uint256 minObservations, int256 annualizationFactor, bool isConfigured)
    {
        AssetConfig storage config = assetConfigs[asset];
        return (
            config.decayFactor.unwrap(),
            config.minObservations,
            config.annualizationFactor.unwrap(),
            config.isConfigured
        );
    }

    /// @notice Calculates the annualization factor for a given observation frequency
    /// @dev Returns sqrt(observationsPerYear) which annualizes volatility
    /// @param secondsBetweenObservations Expected seconds between observations
    /// @return The annualization factor in SD59x18 format
    function calculateAnnualizationFactor(uint256 secondsBetweenObservations) external pure returns (int256) {
        if (secondsBetweenObservations == 0) revert InvalidWindow(0);

        // observationsPerYear = SECONDS_PER_YEAR / secondsBetweenObservations
        SD59x18 observationsPerYear = sd(SECONDS_PER_YEAR * 1e18).div(sd(int256(secondsBetweenObservations) * 1e18));

        // annualizationFactor = sqrt(observationsPerYear)
        return observationsPerYear.sqrt().unwrap();
    }
}
