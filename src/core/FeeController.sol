// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";

/// @title FeeController
/// @notice Dynamic fee model that increases with pool utilization to protect LPs
/// @dev Fee = baseFee + (spreadFee × utilization²)
///      All fee parameters are stored as SD59x18 fixed-point values (18 decimals)
///      Utilization is computed as totalMinted / poolCap for each series
/// @author MantissaFi Team
contract FeeController is Ownable {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Fee configuration for an option series
    /// @param baseFee The minimum fee applied to all trades (e.g., 0.003e18 = 30 bps)
    /// @param spreadFee The utilization-sensitive spread component (e.g., 0.05e18 = 500 bps at max util)
    /// @param poolCap The maximum notional capacity for the series (denominated in collateral token units)
    /// @param isConfigured Whether this series has been configured
    struct FeeConfig {
        SD59x18 baseFee;
        SD59x18 spreadFee;
        uint256 poolCap;
        bool isConfigured;
    }

    /// @notice Snapshot of cumulative fees collected for a series
    /// @param totalCollected Cumulative fees collected for this series
    /// @param totalTrades Number of fee-paying trades
    struct FeeAccumulator {
        uint256 totalCollected;
        uint256 totalTrades;
    }

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum allowed base fee (10% = 0.10)
    int256 public constant MAX_BASE_FEE = 100000000000000000; // 0.1e18

    /// @notice Maximum allowed spread fee (50% = 0.50)
    int256 public constant MAX_SPREAD_FEE = 500000000000000000; // 0.5e18

    /// @notice Minimum pool cap to prevent division-by-zero edge cases
    uint256 public constant MIN_POOL_CAP = 1e18;

    /// @notice Contract version
    string public constant VERSION = "1.0.0";

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Series ID => Fee configuration
    mapping(uint256 => FeeConfig) public feeConfigs;

    /// @notice Series ID => Cumulative fee data
    mapping(uint256 => FeeAccumulator) public feeAccumulators;

    /// @notice Default base fee applied when a series has no custom config
    SD59x18 public defaultBaseFee;

    /// @notice Default spread fee applied when a series has no custom config
    SD59x18 public defaultSpreadFee;

    /// @notice Default pool cap applied when a series has no custom config
    uint256 public defaultPoolCap;

    /// @notice Address that receives collected protocol fees
    address public feeRecipient;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a series fee config is set or updated
    /// @param seriesId The series ID
    /// @param baseFee The base fee in SD59x18 format
    /// @param spreadFee The spread fee in SD59x18 format
    /// @param poolCap The pool cap in collateral units
    event FeeConfigSet(uint256 indexed seriesId, int256 baseFee, int256 spreadFee, uint256 poolCap);

    /// @notice Emitted when global defaults are updated
    /// @param baseFee The new default base fee
    /// @param spreadFee The new default spread fee
    /// @param poolCap The new default pool cap
    event DefaultsUpdated(int256 baseFee, int256 spreadFee, uint256 poolCap);

    /// @notice Emitted when the fee recipient is updated
    /// @param oldRecipient The previous fee recipient
    /// @param newRecipient The new fee recipient
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted when a fee is charged
    /// @param seriesId The series ID
    /// @param payer The address paying the fee
    /// @param amount The notional amount
    /// @param fee The fee amount charged
    event FeeCharged(uint256 indexed seriesId, address indexed payer, uint256 amount, uint256 fee);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when base fee exceeds the maximum allowed
    error FeeController__BaseFeeExceedsMaximum(int256 baseFee);

    /// @notice Thrown when spread fee exceeds the maximum allowed
    error FeeController__SpreadFeeExceedsMaximum(int256 spreadFee);

    /// @notice Thrown when a fee parameter is negative
    error FeeController__NegativeFee(int256 fee);

    /// @notice Thrown when pool cap is below the minimum
    error FeeController__PoolCapTooLow(uint256 poolCap);

    /// @notice Thrown when a zero address is provided
    error FeeController__ZeroAddress();

    /// @notice Thrown when a series is not configured and no defaults exist
    error FeeController__SeriesNotConfigured(uint256 seriesId);

    /// @notice Thrown when the amount is zero
    error FeeController__ZeroAmount();

    /// @notice Thrown when utilization data is invalid (totalMinted > poolCap)
    error FeeController__InvalidUtilization(uint256 totalMinted, uint256 poolCap);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Initializes the FeeController with default parameters
    /// @param _feeRecipient Address that receives protocol fees
    /// @param _defaultBaseFee Default base fee in SD59x18 format (e.g., 3e15 = 30 bps)
    /// @param _defaultSpreadFee Default spread fee in SD59x18 format (e.g., 5e16 = 500 bps)
    /// @param _defaultPoolCap Default pool cap in collateral units
    constructor(address _feeRecipient, int256 _defaultBaseFee, int256 _defaultSpreadFee, uint256 _defaultPoolCap)
        Ownable(msg.sender)
    {
        if (_feeRecipient == address(0)) revert FeeController__ZeroAddress();

        _validateFeeParams(_defaultBaseFee, _defaultSpreadFee, _defaultPoolCap);

        feeRecipient = _feeRecipient;
        defaultBaseFee = sd(_defaultBaseFee);
        defaultSpreadFee = sd(_defaultSpreadFee);
        defaultPoolCap = _defaultPoolCap;
    }

    // =========================================================================
    // Core Fee Calculation
    // =========================================================================

    /// @notice Calculates the fee for a given series and notional amount
    /// @dev Fee = amount × (baseFee + spreadFee × utilization²)
    ///      Utilization is capped at 1.0 (100%) to prevent overflow
    /// @param seriesId The option series ID
    /// @param amount The notional trade amount
    /// @param totalMinted Total options currently minted for the series
    /// @return fee The fee amount in the same units as `amount`
    function calculateFee(uint256 seriesId, uint256 amount, uint256 totalMinted) external view returns (uint256 fee) {
        if (amount == 0) revert FeeController__ZeroAmount();

        (SD59x18 baseFee, SD59x18 spreadFee, uint256 poolCap) = _getEffectiveConfig(seriesId);

        SD59x18 feeRate = _computeFeeRate(baseFee, spreadFee, totalMinted, poolCap);
        fee = _applyFeeRate(feeRate, amount);
    }

    /// @notice Calculates the fee using a raw utilization ratio (for off-chain queries)
    /// @dev Useful for frontends that already know the utilization
    /// @param seriesId The option series ID
    /// @param amount The notional trade amount
    /// @param utilization The utilization ratio as SD59x18 (0 to 1e18)
    /// @return fee The fee amount
    function calculateFeeWithUtilization(uint256 seriesId, uint256 amount, int256 utilization)
        external
        view
        returns (uint256 fee)
    {
        if (amount == 0) revert FeeController__ZeroAmount();

        (SD59x18 baseFee, SD59x18 spreadFee,) = _getEffectiveConfig(seriesId);

        // Clamp utilization to [0, 1]
        SD59x18 util = sd(utilization);
        if (util.lt(ZERO)) util = ZERO;
        if (util.gt(UNIT)) util = UNIT;

        SD59x18 utilSquared = util.mul(util);
        SD59x18 feeRate = baseFee.add(spreadFee.mul(utilSquared));

        fee = _applyFeeRate(feeRate, amount);
    }

    /// @notice Returns the current fee rate for a series at a given utilization level
    /// @param seriesId The option series ID
    /// @param totalMinted Total options currently minted for the series
    /// @return feeRate The current fee rate as SD59x18 (e.g., 0.005e18 = 50 bps)
    function getFeeRate(uint256 seriesId, uint256 totalMinted) external view returns (int256 feeRate) {
        (SD59x18 baseFee, SD59x18 spreadFee, uint256 poolCap) = _getEffectiveConfig(seriesId);
        return _computeFeeRate(baseFee, spreadFee, totalMinted, poolCap).unwrap();
    }

    /// @notice Returns the utilization ratio for a series
    /// @param totalMinted Total options currently minted
    /// @param poolCap The pool capacity
    /// @return utilization The utilization ratio (0 to 1e18) in SD59x18
    function getUtilization(uint256 totalMinted, uint256 poolCap) external pure returns (int256 utilization) {
        if (poolCap < MIN_POOL_CAP) revert FeeController__PoolCapTooLow(poolCap);
        return _calculateUtilization(totalMinted, poolCap).unwrap();
    }

    // =========================================================================
    // Fee Recording
    // =========================================================================

    /// @notice Records a fee charge for accounting purposes
    /// @dev Should be called by the vault after collecting a fee
    /// @param seriesId The option series ID
    /// @param payer The address that paid the fee
    /// @param amount The notional amount of the trade
    /// @param fee The fee amount collected
    function recordFee(uint256 seriesId, address payer, uint256 amount, uint256 fee) external onlyOwner {
        FeeAccumulator storage acc = feeAccumulators[seriesId];
        acc.totalCollected += fee;
        acc.totalTrades += 1;

        emit FeeCharged(seriesId, payer, amount, fee);
    }

    // =========================================================================
    // Admin: Series Configuration
    // =========================================================================

    /// @notice Sets the fee configuration for a specific series
    /// @param seriesId The option series ID
    /// @param baseFee The base fee in SD59x18 format
    /// @param spreadFee The spread fee in SD59x18 format
    /// @param poolCap The pool capacity in collateral units
    function setFeeConfig(uint256 seriesId, int256 baseFee, int256 spreadFee, uint256 poolCap) external onlyOwner {
        _validateFeeParams(baseFee, spreadFee, poolCap);

        feeConfigs[seriesId] =
            FeeConfig({ baseFee: sd(baseFee), spreadFee: sd(spreadFee), poolCap: poolCap, isConfigured: true });

        emit FeeConfigSet(seriesId, baseFee, spreadFee, poolCap);
    }

    /// @notice Removes the custom fee configuration for a series (falls back to defaults)
    /// @param seriesId The option series ID
    function removeFeeConfig(uint256 seriesId) external onlyOwner {
        delete feeConfigs[seriesId];

        emit FeeConfigSet(seriesId, defaultBaseFee.unwrap(), defaultSpreadFee.unwrap(), defaultPoolCap);
    }

    // =========================================================================
    // Admin: Global Defaults
    // =========================================================================

    /// @notice Updates the global default fee parameters
    /// @param baseFee The new default base fee
    /// @param spreadFee The new default spread fee
    /// @param poolCap The new default pool cap
    function setDefaults(int256 baseFee, int256 spreadFee, uint256 poolCap) external onlyOwner {
        _validateFeeParams(baseFee, spreadFee, poolCap);

        defaultBaseFee = sd(baseFee);
        defaultSpreadFee = sd(spreadFee);
        defaultPoolCap = poolCap;

        emit DefaultsUpdated(baseFee, spreadFee, poolCap);
    }

    /// @notice Updates the fee recipient address
    /// @param newRecipient The new fee recipient
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert FeeController__ZeroAddress();

        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;

        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @notice Returns the effective fee configuration for a series
    /// @dev Returns the series-specific config if set, otherwise the global defaults
    /// @param seriesId The option series ID
    /// @return baseFee The effective base fee
    /// @return spreadFee The effective spread fee
    /// @return poolCap The effective pool cap
    function getEffectiveConfig(uint256 seriesId)
        external
        view
        returns (int256 baseFee, int256 spreadFee, uint256 poolCap)
    {
        (SD59x18 base, SD59x18 spread, uint256 cap) = _getEffectiveConfig(seriesId);
        return (base.unwrap(), spread.unwrap(), cap);
    }

    /// @notice Returns the cumulative fee data for a series
    /// @param seriesId The option series ID
    /// @return totalCollected Total fees collected
    /// @return totalTrades Number of fee-paying trades
    function getAccumulatedFees(uint256 seriesId) external view returns (uint256 totalCollected, uint256 totalTrades) {
        FeeAccumulator storage acc = feeAccumulators[seriesId];
        return (acc.totalCollected, acc.totalTrades);
    }

    /// @notice Checks whether a series has a custom fee configuration
    /// @param seriesId The option series ID
    /// @return True if the series has a custom config
    function hasCustomConfig(uint256 seriesId) external view returns (bool) {
        return feeConfigs[seriesId].isConfigured;
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /// @notice Resolves the effective fee configuration for a series
    /// @param seriesId The option series ID
    /// @return baseFee The base fee
    /// @return spreadFee The spread fee
    /// @return poolCap The pool cap
    function _getEffectiveConfig(uint256 seriesId)
        internal
        view
        returns (SD59x18 baseFee, SD59x18 spreadFee, uint256 poolCap)
    {
        FeeConfig storage config = feeConfigs[seriesId];
        if (config.isConfigured) {
            return (config.baseFee, config.spreadFee, config.poolCap);
        }
        return (defaultBaseFee, defaultSpreadFee, defaultPoolCap);
    }

    /// @notice Computes the fee rate from parameters and utilization
    /// @dev feeRate = baseFee + spreadFee × utilization²
    /// @param baseFee The base fee component
    /// @param spreadFee The spread fee component
    /// @param totalMinted Total options minted for the series
    /// @param poolCap The pool capacity
    /// @return feeRate The computed fee rate
    function _computeFeeRate(SD59x18 baseFee, SD59x18 spreadFee, uint256 totalMinted, uint256 poolCap)
        internal
        pure
        returns (SD59x18 feeRate)
    {
        SD59x18 utilization = _calculateUtilization(totalMinted, poolCap);
        SD59x18 utilSquared = utilization.mul(utilization);
        feeRate = baseFee.add(spreadFee.mul(utilSquared));
    }

    /// @notice Calculates utilization ratio, clamped to [0, 1]
    /// @param totalMinted Total options minted
    /// @param poolCap The pool capacity
    /// @return utilization The utilization ratio as SD59x18
    function _calculateUtilization(uint256 totalMinted, uint256 poolCap) internal pure returns (SD59x18 utilization) {
        if (totalMinted == 0) return ZERO;

        // Convert to SD59x18 for division
        SD59x18 minted = sd(int256(totalMinted));
        SD59x18 cap = sd(int256(poolCap));

        utilization = minted.div(cap);

        // Clamp to 1.0 maximum (pool can be over-utilized in edge cases)
        if (utilization.gt(UNIT)) {
            utilization = UNIT;
        }
    }

    /// @notice Applies a fee rate to a notional amount
    /// @param feeRate The fee rate as SD59x18
    /// @param amount The notional amount
    /// @return fee The fee in the same units as amount
    function _applyFeeRate(SD59x18 feeRate, uint256 amount) internal pure returns (uint256 fee) {
        SD59x18 amountSD = sd(int256(amount));
        SD59x18 feeSD = amountSD.mul(feeRate);

        // Fee is always non-negative; floor at zero
        int256 feeRaw = feeSD.unwrap();
        fee = feeRaw > 0 ? uint256(feeRaw) / 1e18 : 0;
    }

    /// @notice Validates fee parameters against bounds
    /// @param baseFee The base fee to validate
    /// @param spreadFee The spread fee to validate
    /// @param poolCap The pool cap to validate
    function _validateFeeParams(int256 baseFee, int256 spreadFee, uint256 poolCap) internal pure {
        if (baseFee < 0) revert FeeController__NegativeFee(baseFee);
        if (spreadFee < 0) revert FeeController__NegativeFee(spreadFee);
        if (baseFee > MAX_BASE_FEE) revert FeeController__BaseFeeExceedsMaximum(baseFee);
        if (spreadFee > MAX_SPREAD_FEE) revert FeeController__SpreadFeeExceedsMaximum(spreadFee);
        if (poolCap < MIN_POOL_CAP) revert FeeController__PoolCapTooLow(poolCap);
    }
}
