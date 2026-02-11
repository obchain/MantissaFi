// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";

/// @title OptionVault
/// @notice Main entry point for option lifecycle management
/// @dev Manages option series creation, minting, exercise, and settlement
/// @author MantissaFi Team
contract OptionVault is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Option series state machine
    /// @dev CREATED -> ACTIVE -> EXPIRED -> SETTLED
    enum SeriesState {
        CREATED, // Series created but not yet active
        ACTIVE, // Series is open for minting
        EXPIRED, // Past expiry, awaiting settlement
        SETTLED // Settlement complete, payouts available
    }

    /// @notice Configuration for an option series
    struct OptionSeries {
        address underlying; // Underlying asset address
        address collateral; // Collateral token (e.g., USDC)
        int256 strike; // Strike price in SD59x18
        uint64 expiry; // Expiry timestamp
        bool isCall; // True for call, false for put
    }

    /// @notice Full state of an option series
    struct SeriesData {
        OptionSeries config; // Series configuration
        SeriesState state; // Current state
        uint256 totalMinted; // Total options minted
        uint256 totalExercised; // Total options exercised
        uint256 collateralLocked; // Total collateral locked
        int256 settlementPrice; // Price at settlement (SD59x18)
        uint64 createdAt; // Creation timestamp
    }

    /// @notice User position in a series
    struct Position {
        uint256 longAmount; // Options owned (buyer)
        uint256 shortAmount; // Options written (seller)
        bool hasClaimed; // Whether payout has been claimed
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Counter for series IDs
    uint256 public nextSeriesId;

    /// @notice Series ID => Series data
    mapping(uint256 => SeriesData) public series;

    /// @notice Series ID => User => Position
    mapping(uint256 => mapping(address => Position)) public positions;

    /// @notice Minimum time before expiry for minting (1 hour)
    uint256 public constant MIN_TIME_TO_EXPIRY = 1 hours;

    /// @notice Grace period after expiry for exercise (24 hours)
    uint256 public constant EXERCISE_GRACE_PERIOD = 24 hours;

    /// @notice Maximum settlement delay after expiry (7 days)
    uint256 public constant MAX_SETTLEMENT_DELAY = 7 days;

    // =========================================================================
    // Events
    // =========================================================================

    event SeriesCreated(
        uint256 indexed seriesId, address indexed underlying, int256 strike, uint64 expiry, bool isCall
    );

    event SeriesActivated(uint256 indexed seriesId);

    event OptionMinted(
        uint256 indexed seriesId, address indexed minter, uint256 amount, uint256 premium, uint256 collateral
    );

    event OptionExercised(uint256 indexed seriesId, address indexed exerciser, uint256 amount, uint256 payout);

    event SeriesSettled(uint256 indexed seriesId, int256 settlementPrice);

    event PayoutClaimed(uint256 indexed seriesId, address indexed claimer, uint256 payout);

    // =========================================================================
    // Errors
    // =========================================================================

    error OptionVault__SeriesNotFound();
    error OptionVault__InvalidStrike();
    error OptionVault__InvalidExpiry();
    error OptionVault__InvalidAmount();
    error OptionVault__InvalidState(SeriesState current, SeriesState required);
    error OptionVault__ExpiryTooSoon();
    error OptionVault__AlreadyExpired();
    error OptionVault__NotYetExpired();
    error OptionVault__ExercisePeriodEnded();
    error OptionVault__SettlementTooEarly();
    error OptionVault__SettlementTooLate();
    error OptionVault__InsufficientPosition();
    error OptionVault__AlreadyClaimed();
    error OptionVault__ZeroAddress();
    error OptionVault__TransferFailed();

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor() Ownable(msg.sender) {
        nextSeriesId = 1;
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @notice Get full series data
    /// @param seriesId The series ID
    /// @return data The series data
    function getSeries(uint256 seriesId) external view returns (SeriesData memory data) {
        data = series[seriesId];
        if (data.config.underlying == address(0)) {
            revert OptionVault__SeriesNotFound();
        }
    }

    /// @notice Get user position in a series
    /// @param seriesId The series ID
    /// @param user The user address
    /// @return position The user's position
    function getPosition(uint256 seriesId, address user) external view returns (Position memory) {
        return positions[seriesId][user];
    }

    /// @notice Check if a series is expired
    /// @param seriesId The series ID
    /// @return True if expired
    function isExpired(uint256 seriesId) public view returns (bool) {
        return block.timestamp >= series[seriesId].config.expiry;
    }

    /// @notice Check if exercise window is open
    /// @param seriesId The series ID
    /// @return True if exercise is allowed
    function canExercise(uint256 seriesId) public view returns (bool) {
        SeriesData storage s = series[seriesId];
        if (s.state != SeriesState.ACTIVE && s.state != SeriesState.EXPIRED) {
            return false;
        }
        uint64 expiry = s.config.expiry;
        return block.timestamp >= expiry && block.timestamp <= expiry + EXERCISE_GRACE_PERIOD;
    }

    /// @notice Calculate time to expiry in seconds
    /// @param seriesId The series ID
    /// @return seconds Time remaining (0 if expired)
    function timeToExpiry(uint256 seriesId) external view returns (uint256) {
        uint64 expiry = series[seriesId].config.expiry;
        if (block.timestamp >= expiry) return 0;
        return expiry - block.timestamp;
    }

    // =========================================================================
    // Series Management
    // =========================================================================

    /// @notice Create a new option series
    /// @param config The option series configuration
    /// @return seriesId The ID of the created series
    function createSeries(OptionSeries calldata config) external whenNotPaused returns (uint256 seriesId) {
        // Validate inputs
        if (config.underlying == address(0)) revert OptionVault__ZeroAddress();
        if (config.collateral == address(0)) revert OptionVault__ZeroAddress();
        if (config.strike <= 0) revert OptionVault__InvalidStrike();
        if (config.expiry <= block.timestamp) revert OptionVault__InvalidExpiry();
        if (config.expiry < block.timestamp + MIN_TIME_TO_EXPIRY) revert OptionVault__ExpiryTooSoon();

        // Create series
        seriesId = nextSeriesId++;

        series[seriesId] = SeriesData({
            config: config,
            state: SeriesState.ACTIVE,
            totalMinted: 0,
            totalExercised: 0,
            collateralLocked: 0,
            settlementPrice: 0,
            createdAt: uint64(block.timestamp)
        });

        emit SeriesCreated(seriesId, config.underlying, config.strike, config.expiry, config.isCall);
        emit SeriesActivated(seriesId);
    }

    // =========================================================================
    // Minting
    // =========================================================================

    /// @notice Mint new options by providing collateral
    /// @dev For calls: collateral = underlying. For puts: collateral = strike * amount in stablecoin
    /// @param seriesId The series ID
    /// @param amount The number of options to mint
    /// @return premium The premium paid for the options (placeholder - returns 0)
    function mint(uint256 seriesId, uint256 amount) external nonReentrant whenNotPaused returns (uint256 premium) {
        if (amount == 0) revert OptionVault__InvalidAmount();

        SeriesData storage s = series[seriesId];
        if (s.config.underlying == address(0)) revert OptionVault__SeriesNotFound();
        if (s.state != SeriesState.ACTIVE) revert OptionVault__InvalidState(s.state, SeriesState.ACTIVE);
        if (block.timestamp >= s.config.expiry) revert OptionVault__AlreadyExpired();
        if (s.config.expiry - block.timestamp < MIN_TIME_TO_EXPIRY) revert OptionVault__ExpiryTooSoon();

        // Calculate collateral required (100% collateralization)
        uint256 collateralRequired = _calculateCollateral(s.config, amount);

        // Transfer collateral from minter
        IERC20(s.config.collateral).safeTransferFrom(msg.sender, address(this), collateralRequired);

        // Update state
        s.totalMinted += amount;
        s.collateralLocked += collateralRequired;

        // Update positions
        Position storage pos = positions[seriesId][msg.sender];
        pos.shortAmount += amount;
        pos.longAmount += amount; // Minter gets both long and short positions

        // Premium calculation would go here (from BSMEngine)
        // For now, premium is 0 - users pay only collateral
        premium = 0;

        emit OptionMinted(seriesId, msg.sender, amount, premium, collateralRequired);
    }

    /// @notice Calculate collateral required for minting
    /// @dev 100% collateralization: calls require underlying, puts require strike value
    /// @param config The option series config
    /// @param amount Number of options
    /// @return collateral Required collateral amount
    function _calculateCollateral(OptionSeries memory config, uint256 amount)
        internal
        pure
        returns (uint256 collateral)
    {
        if (config.isCall) {
            // Call option: need 1 unit of underlying per option
            // Assuming 18 decimals for underlying
            collateral = amount;
        } else {
            // Put option: need strike price worth of collateral per option
            // Convert strike (SD59x18) to uint256
            // strike is in 18 decimals, amount is in token units
            int256 strikeInt = config.strike;
            require(strikeInt > 0, "Invalid strike");
            collateral = (uint256(strikeInt) * amount) / 1e18;
        }
    }

    /// @notice Calculate required collateral for a series
    /// @param seriesId The series ID
    /// @param amount The number of options
    /// @return collateral The required collateral
    function calculateCollateral(uint256 seriesId, uint256 amount) external view returns (uint256) {
        SeriesData storage s = series[seriesId];
        if (s.config.underlying == address(0)) revert OptionVault__SeriesNotFound();
        return _calculateCollateral(s.config, amount);
    }

    // =========================================================================
    // Exercise
    // =========================================================================

    /// @notice Exercise options at or after expiry (European style)
    /// @param seriesId The series ID
    /// @param amount The number of options to exercise
    /// @return payout The payout received
    function exercise(uint256 seriesId, uint256 amount) external nonReentrant whenNotPaused returns (uint256 payout) {
        if (amount == 0) revert OptionVault__InvalidAmount();

        SeriesData storage s = series[seriesId];
        if (s.config.underlying == address(0)) revert OptionVault__SeriesNotFound();

        // Check exercise window
        if (!canExercise(seriesId)) {
            if (block.timestamp < s.config.expiry) {
                revert OptionVault__NotYetExpired();
            } else {
                revert OptionVault__ExercisePeriodEnded();
            }
        }

        // Check position
        Position storage pos = positions[seriesId][msg.sender];
        if (pos.longAmount < amount) revert OptionVault__InsufficientPosition();

        // Update state to EXPIRED if still ACTIVE
        if (s.state == SeriesState.ACTIVE) {
            s.state = SeriesState.EXPIRED;
        }

        // Calculate payout based on settlement price
        // For now, use a mock settlement price (should come from oracle)
        int256 spotPrice = s.settlementPrice;
        if (spotPrice == 0) {
            // Mock: use strike * 1.1 for calls ITM, strike * 0.9 for puts ITM
            spotPrice = s.config.isCall ? (s.config.strike * 110) / 100 : (s.config.strike * 90) / 100;
            s.settlementPrice = spotPrice;
        }

        payout = _calculatePayout(s.config, spotPrice, amount);

        // Update positions
        pos.longAmount -= amount;
        s.totalExercised += amount;

        // Transfer payout
        if (payout > 0) {
            IERC20(s.config.collateral).safeTransfer(msg.sender, payout);
            s.collateralLocked -= payout;
        }

        emit OptionExercised(seriesId, msg.sender, amount, payout);
    }

    /// @notice Calculate payout for exercising options
    /// @param config The option series config
    /// @param spotPrice The spot price at exercise (SD59x18)
    /// @param amount Number of options
    /// @return payout The payout amount
    function _calculatePayout(OptionSeries memory config, int256 spotPrice, uint256 amount)
        internal
        pure
        returns (uint256 payout)
    {
        int256 strike = config.strike;

        if (config.isCall) {
            // Call payout: max(spot - strike, 0)
            if (spotPrice > strike) {
                int256 payoffPerOption = spotPrice - strike;
                payout = (uint256(payoffPerOption) * amount) / 1e18;
            }
        } else {
            // Put payout: max(strike - spot, 0)
            if (strike > spotPrice) {
                int256 payoffPerOption = strike - spotPrice;
                payout = (uint256(payoffPerOption) * amount) / 1e18;
            }
        }
    }

    // =========================================================================
    // Settlement
    // =========================================================================

    /// @notice Settle a series after expiry
    /// @dev Marks series as settled, allowing remaining collateral claims
    /// @param seriesId The series ID
    function settle(uint256 seriesId) external nonReentrant whenNotPaused {
        SeriesData storage s = series[seriesId];
        if (s.config.underlying == address(0)) revert OptionVault__SeriesNotFound();

        // Check state
        if (s.state == SeriesState.SETTLED) return; // Already settled
        if (s.state == SeriesState.CREATED) revert OptionVault__InvalidState(s.state, SeriesState.EXPIRED);

        // Check timing
        uint64 expiry = s.config.expiry;
        if (block.timestamp < expiry + EXERCISE_GRACE_PERIOD) {
            revert OptionVault__SettlementTooEarly();
        }
        if (block.timestamp > expiry + MAX_SETTLEMENT_DELAY) {
            revert OptionVault__SettlementTooLate();
        }

        // Set settlement price if not already set
        if (s.settlementPrice == 0) {
            // Mock settlement price (should come from oracle)
            s.settlementPrice = s.config.strike;
        }

        // Mark as settled
        s.state = SeriesState.SETTLED;

        emit SeriesSettled(seriesId, s.settlementPrice);
    }

    /// @notice Claim remaining collateral after settlement (for writers)
    /// @param seriesId The series ID
    /// @return payout The collateral returned
    function claimCollateral(uint256 seriesId) external nonReentrant returns (uint256 payout) {
        SeriesData storage s = series[seriesId];
        if (s.config.underlying == address(0)) revert OptionVault__SeriesNotFound();
        if (s.state != SeriesState.SETTLED) revert OptionVault__InvalidState(s.state, SeriesState.SETTLED);

        Position storage pos = positions[seriesId][msg.sender];
        if (pos.hasClaimed) revert OptionVault__AlreadyClaimed();
        if (pos.shortAmount == 0) revert OptionVault__InsufficientPosition();

        // Calculate remaining collateral for short position
        // Short position collateral minus exercised payouts
        uint256 collateralPerOption = _calculateCollateral(s.config, 1);
        uint256 totalCollateral = collateralPerOption * pos.shortAmount;

        // Calculate how much was paid out from this position's collateral
        uint256 payoutFromPosition = 0;
        if (s.totalExercised > 0 && s.totalMinted > 0) {
            // Pro-rata share of total payouts
            uint256 totalPayout = _calculatePayout(s.config, s.settlementPrice, s.totalExercised);
            payoutFromPosition = (totalPayout * pos.shortAmount) / s.totalMinted;
        }

        payout = totalCollateral > payoutFromPosition ? totalCollateral - payoutFromPosition : 0;

        pos.hasClaimed = true;

        if (payout > 0) {
            IERC20(s.config.collateral).safeTransfer(msg.sender, payout);
            s.collateralLocked -= payout;
        }

        emit PayoutClaimed(seriesId, msg.sender, payout);
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Emergency withdraw stuck tokens (admin only)
    /// @param token The token to withdraw
    /// @param amount The amount to withdraw
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
