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
        CREATED,    // Series created but not yet active
        ACTIVE,     // Series is open for minting
        EXPIRED,    // Past expiry, awaiting settlement
        SETTLED     // Settlement complete, payouts available
    }

    /// @notice Configuration for an option series
    struct OptionSeries {
        address underlying;      // Underlying asset address
        address collateral;      // Collateral token (e.g., USDC)
        int256 strike;           // Strike price in SD59x18
        uint64 expiry;           // Expiry timestamp
        bool isCall;             // True for call, false for put
    }

    /// @notice Full state of an option series
    struct SeriesData {
        OptionSeries config;          // Series configuration
        SeriesState state;            // Current state
        uint256 totalMinted;          // Total options minted
        uint256 totalExercised;       // Total options exercised
        uint256 collateralLocked;     // Total collateral locked
        int256 settlementPrice;       // Price at settlement (SD59x18)
        uint64 createdAt;             // Creation timestamp
    }

    /// @notice User position in a series
    struct Position {
        uint256 longAmount;      // Options owned (buyer)
        uint256 shortAmount;     // Options written (seller)
        bool hasClaimed;         // Whether payout has been claimed
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
        uint256 indexed seriesId,
        address indexed underlying,
        int256 strike,
        uint64 expiry,
        bool isCall
    );

    event SeriesActivated(uint256 indexed seriesId);

    event OptionMinted(
        uint256 indexed seriesId,
        address indexed minter,
        uint256 amount,
        uint256 premium,
        uint256 collateral
    );

    event OptionExercised(
        uint256 indexed seriesId,
        address indexed exerciser,
        uint256 amount,
        uint256 payout
    );

    event SeriesSettled(
        uint256 indexed seriesId,
        int256 settlementPrice
    );

    event PayoutClaimed(
        uint256 indexed seriesId,
        address indexed claimer,
        uint256 payout
    );

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
}
