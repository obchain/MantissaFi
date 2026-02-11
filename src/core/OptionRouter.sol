// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { OptionVault } from "./OptionVault.sol";

/// @title OptionRouter
/// @notice User-facing multicall helper that batches common option operations
/// @dev Provides gasless approval via ERC-2612 permits and atomic multi-step workflows
/// @author MantissaFi Team
contract OptionRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice ERC-2612 permit signature data for gasless token approvals
    /// @param value The amount to approve
    /// @param deadline Timestamp after which the permit is no longer valid
    /// @param v ECDSA signature recovery identifier
    /// @param r ECDSA signature output (first 32 bytes)
    /// @param s ECDSA signature output (second 32 bytes)
    struct Permit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice The OptionVault contract this router interacts with
    OptionVault public immutable vault;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when options are minted using a permit signature
    /// @param seriesId The option series ID
    /// @param minter The address that minted options
    /// @param amount The number of options minted
    /// @param collateral The collateral transferred
    event MintedWithPermit(uint256 indexed seriesId, address indexed minter, uint256 amount, uint256 collateral);

    /// @notice Emitted when options are minted and collateral is deposited atomically
    /// @param seriesId The option series ID
    /// @param minter The address that minted and deposited
    /// @param amount The number of options minted
    /// @param collateral The collateral transferred
    event MintedAndDeposited(uint256 indexed seriesId, address indexed minter, uint256 amount, uint256 collateral);

    /// @notice Emitted when options are exercised and payout is withdrawn atomically
    /// @param seriesId The option series ID
    /// @param exerciser The address that exercised and withdrew
    /// @param amount The number of options exercised
    /// @param payout The payout received
    event ExercisedAndWithdrawn(uint256 indexed seriesId, address indexed exerciser, uint256 amount, uint256 payout);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when the vault address is zero
    error OptionRouter__ZeroAddress();

    /// @notice Thrown when the mint amount is zero
    error OptionRouter__InvalidAmount();

    /// @notice Thrown when the series ID does not exist
    error OptionRouter__SeriesNotFound();

    /// @notice Thrown when the permit value is insufficient for the required collateral
    /// @param required The collateral amount required
    /// @param permitted The amount approved via permit
    error OptionRouter__InsufficientPermit(uint256 required, uint256 permitted);

    /// @notice Thrown when exercising yields zero payout
    error OptionRouter__ZeroPayout();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Initializes the router with the target OptionVault
    /// @param vault_ The OptionVault contract address
    constructor(address vault_) {
        if (vault_ == address(0)) revert OptionRouter__ZeroAddress();
        vault = OptionVault(vault_);
    }

    // =========================================================================
    // External Functions
    // =========================================================================

    /// @notice Mint options using an ERC-2612 permit for gasless collateral approval
    /// @dev Executes permit (tolerant to frontrunning), transfers collateral, then mints via vault.
    ///      The permit should approve this router to spend the collateral token.
    /// @param seriesId The option series ID to mint
    /// @param amount The number of options to mint
    /// @param permit The ERC-2612 permit signature data
    /// @return premium The premium paid (currently 0 in OptionVault)
    function mintWithPermit(uint256 seriesId, uint256 amount, Permit calldata permit)
        external
        nonReentrant
        returns (uint256 premium)
    {
        if (amount == 0) revert OptionRouter__InvalidAmount();

        // Fetch series config to determine collateral token and required amount
        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        address collateralToken = data.config.collateral;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        // Validate permit covers the collateral requirement
        if (permit.value < collateralRequired) {
            revert OptionRouter__InsufficientPermit(collateralRequired, permit.value);
        }

        // Execute permit — use try/catch to tolerate frontrunning or prior approval
        try IERC20Permit(collateralToken)
            .permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) { }
            catch { } // solhint-disable-line no-empty-blocks

        // Transfer collateral from user to this router
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralRequired);

        // Approve vault to spend collateral
        IERC20(collateralToken).forceApprove(address(vault), collateralRequired);

        // Mint options through the vault (vault pulls collateral from this contract)
        premium = vault.mint(seriesId, amount);

        // Transfer the long+short position ownership to the user
        // Note: OptionVault assigns positions to msg.sender (this router).
        // In a production system, the vault would support transferring positions.
        // For now, the router holds positions on behalf of the user.

        emit MintedWithPermit(seriesId, msg.sender, amount, collateralRequired);
    }

    /// @notice Mint options with pre-approved collateral in a single transaction
    /// @dev User must have approved this router for the collateral token before calling.
    ///      Transfers collateral from user, approves vault, and mints.
    /// @param seriesId The option series ID to mint
    /// @param amount The number of options to mint
    function mintAndDeposit(uint256 seriesId, uint256 amount) external nonReentrant {
        if (amount == 0) revert OptionRouter__InvalidAmount();

        // Fetch series config
        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        address collateralToken = data.config.collateral;
        uint256 collateralRequired = vault.calculateCollateral(seriesId, amount);

        // Transfer collateral from user to this router
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralRequired);

        // Approve vault to spend collateral
        IERC20(collateralToken).forceApprove(address(vault), collateralRequired);

        // Mint options through the vault
        vault.mint(seriesId, amount);

        emit MintedAndDeposited(seriesId, msg.sender, amount, collateralRequired);
    }

    /// @notice Exercise options and withdraw the payout in a single transaction
    /// @dev Exercises options held by this router on behalf of the caller, then transfers payout.
    ///      The caller must have previously minted through this router so the router holds the position.
    /// @param seriesId The option series ID to exercise
    /// @param amount The number of options to exercise
    function exerciseAndWithdraw(uint256 seriesId, uint256 amount) external nonReentrant {
        if (amount == 0) revert OptionRouter__InvalidAmount();

        // Fetch series config to determine collateral token
        OptionVault.SeriesData memory data = vault.getSeries(seriesId);
        address collateralToken = data.config.collateral;

        // Exercise options — payout goes to this contract since the vault tracks the router's position
        uint256 payout = vault.exercise(seriesId, amount);

        if (payout == 0) revert OptionRouter__ZeroPayout();

        // Transfer payout to the user
        IERC20(collateralToken).safeTransfer(msg.sender, payout);

        emit ExercisedAndWithdrawn(seriesId, msg.sender, amount, payout);
    }
}
