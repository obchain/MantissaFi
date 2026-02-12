// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";

/// @title Multichaindeploymentwithcrosschainsettlement
/// @notice Cross-chain settlement hub that coordinates option positions and liquidity across EVM chains
/// @dev Implements a message-passing architecture where each chain has a deployment instance that
///      communicates via verified cross-chain messages. The hub chain aggregates positions and
///      computes net settlement amounts, while spoke chains lock/release collateral locally.
///      All fixed-point arithmetic uses PRB Math SD59x18 (18 decimals).
/// @author MantissaFi Team
contract Multichaindeploymentwithcrosschainsettlement is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice State of a cross-chain message
    /// @dev PENDING -> CONFIRMED or FAILED
    enum MessageStatus {
        PENDING, // Awaiting relay confirmation
        CONFIRMED, // Successfully relayed and executed
        FAILED // Relay failed or timed out
    }

    /// @notice Type of cross-chain operation
    enum OperationType {
        LOCK_COLLATERAL, // Lock collateral on spoke chain
        RELEASE_COLLATERAL, // Release collateral after settlement
        SYNC_POSITION, // Synchronize position data to hub
        SETTLE, // Initiate cross-chain settlement
        LIQUIDITY_REBALANCE // Rebalance liquidity between chains
    }

    /// @notice Configuration for a registered chain deployment
    /// @param chainId The EVM chain ID
    /// @param deploymentAddress The contract address on the remote chain
    /// @param isActive Whether this chain is active for settlement
    /// @param totalLockedCollateral Total collateral locked on this chain
    /// @param totalPositionValue Net position value on this chain (SD59x18)
    /// @param lastSyncTimestamp Timestamp of last successful sync
    struct ChainDeployment {
        uint64 chainId;
        address deploymentAddress;
        bool isActive;
        uint256 totalLockedCollateral;
        int256 totalPositionValue;
        uint64 lastSyncTimestamp;
    }

    /// @notice A cross-chain message for settlement coordination
    /// @param messageId Unique message identifier (hash-based)
    /// @param sourceChainId Origin chain ID
    /// @param destinationChainId Target chain ID
    /// @param operationType The type of operation
    /// @param seriesId The option series this message relates to
    /// @param amount The amount involved (collateral or position size)
    /// @param sender The originating address
    /// @param status Current message status
    /// @param timestamp When the message was created
    /// @param executedAt When the message was executed (0 if pending)
    struct CrossChainMessage {
        bytes32 messageId;
        uint64 sourceChainId;
        uint64 destinationChainId;
        OperationType operationType;
        uint256 seriesId;
        uint256 amount;
        address sender;
        MessageStatus status;
        uint64 timestamp;
        uint64 executedAt;
    }

    /// @notice Aggregated position across all chains for a single series
    /// @param seriesId The option series ID
    /// @param totalLongAcrossChains Aggregate long positions across all chains
    /// @param totalShortAcrossChains Aggregate short positions across all chains
    /// @param totalCollateralAcrossChains Aggregate locked collateral across all chains
    /// @param netSettlementAmount Net settlement due after exercise (SD59x18, positive = payout to longs)
    /// @param isSettled Whether cross-chain settlement is complete
    struct AggregatedPosition {
        uint256 seriesId;
        uint256 totalLongAcrossChains;
        uint256 totalShortAcrossChains;
        uint256 totalCollateralAcrossChains;
        int256 netSettlementAmount;
        bool isSettled;
    }

    /// @notice Per-chain position snapshot used for settlement
    /// @param chainId The chain ID
    /// @param longAmount Long position size on this chain
    /// @param shortAmount Short position size on this chain
    /// @param lockedCollateral Collateral locked on this chain
    /// @param settlementDelta Amount to transfer in (+) or out (-) during settlement (SD59x18)
    struct ChainPositionSnapshot {
        uint64 chainId;
        uint256 longAmount;
        uint256 shortAmount;
        uint256 lockedCollateral;
        int256 settlementDelta;
    }

    /// @notice Liquidity rebalance request between two chains
    /// @param fromChainId Source chain for liquidity
    /// @param toChainId Destination chain for liquidity
    /// @param token The collateral token address
    /// @param amount The amount to rebalance
    /// @param executed Whether the rebalance has been executed
    struct RebalanceRequest {
        uint64 fromChainId;
        uint64 toChainId;
        address token;
        uint256 amount;
        bool executed;
    }

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum number of registered chains
    uint256 public constant MAX_CHAINS = 32;

    /// @notice Message expiry duration (messages older than this are considered stale)
    uint256 public constant MESSAGE_EXPIRY = 24 hours;

    /// @notice Minimum sync interval between position syncs
    uint256 public constant MIN_SYNC_INTERVAL = 5 minutes;

    /// @notice Maximum settlement imbalance tolerance (1% in SD59x18)
    int256 public constant MAX_SETTLEMENT_IMBALANCE = 10000000000000000; // 0.01e18

    /// @notice Contract version
    string public constant VERSION = "1.0.0";

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice This chain's ID (set at deployment)
    uint64 public immutable localChainId;

    /// @notice Whether this instance is the hub (settlement coordinator)
    bool public immutable isHub;

    /// @notice Registered chain IDs
    uint64[] public registeredChains;

    /// @notice Chain ID => Chain deployment configuration
    mapping(uint64 => ChainDeployment) public chainDeployments;

    /// @notice Message ID => Cross-chain message
    mapping(bytes32 => CrossChainMessage) public messages;

    /// @notice Series ID => Aggregated cross-chain position
    mapping(uint256 => AggregatedPosition) public aggregatedPositions;

    /// @notice Series ID => Chain ID => Position snapshot
    mapping(uint256 => mapping(uint64 => ChainPositionSnapshot)) public chainSnapshots;

    /// @notice Authorized relayer addresses that can confirm cross-chain messages
    mapping(address => bool) public authorizedRelayers;

    /// @notice Nonce for message ID generation
    uint256 public messageNonce;

    /// @notice Rebalance request ID counter
    uint256 public nextRebalanceId;

    /// @notice Rebalance ID => Request
    mapping(uint256 => RebalanceRequest) public rebalanceRequests;

    /// @notice Collateral token used for settlements
    address public collateralToken;

    /// @notice Total collateral locked locally for cross-chain positions
    uint256 public totalLocalCollateral;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new chain deployment is registered
    /// @param chainId The registered chain's ID
    /// @param deploymentAddress The contract address on the remote chain
    event ChainRegistered(uint64 indexed chainId, address indexed deploymentAddress);

    /// @notice Emitted when a chain deployment is deactivated
    /// @param chainId The deactivated chain's ID
    event ChainDeactivated(uint64 indexed chainId);

    /// @notice Emitted when a chain deployment is reactivated
    /// @param chainId The reactivated chain's ID
    event ChainActivated(uint64 indexed chainId);

    /// @notice Emitted when a cross-chain message is sent
    /// @param messageId The unique message identifier
    /// @param sourceChainId The source chain
    /// @param destinationChainId The destination chain
    /// @param operationType The operation type
    /// @param seriesId The related option series
    /// @param amount The amount involved
    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed sourceChainId,
        uint64 indexed destinationChainId,
        OperationType operationType,
        uint256 seriesId,
        uint256 amount
    );

    /// @notice Emitted when a cross-chain message is confirmed
    /// @param messageId The confirmed message ID
    /// @param relayer The relayer that confirmed the message
    event MessageConfirmed(bytes32 indexed messageId, address indexed relayer);

    /// @notice Emitted when a message is marked as failed
    /// @param messageId The failed message ID
    event MessageFailed(bytes32 indexed messageId);

    /// @notice Emitted when collateral is locked for cross-chain settlement
    /// @param seriesId The option series
    /// @param chainId The chain where collateral is locked
    /// @param amount The locked amount
    /// @param depositor The address that deposited collateral
    event CollateralLocked(uint256 indexed seriesId, uint64 indexed chainId, uint256 amount, address indexed depositor);

    /// @notice Emitted when collateral is released after settlement
    /// @param seriesId The option series
    /// @param chainId The chain where collateral is released
    /// @param amount The released amount
    /// @param recipient The address receiving collateral
    event CollateralReleased(
        uint256 indexed seriesId, uint64 indexed chainId, uint256 amount, address indexed recipient
    );

    /// @notice Emitted when positions are synced from a spoke chain to hub
    /// @param seriesId The option series
    /// @param chainId The spoke chain
    /// @param longAmount Synced long position size
    /// @param shortAmount Synced short position size
    event PositionSynced(uint256 indexed seriesId, uint64 indexed chainId, uint256 longAmount, uint256 shortAmount);

    /// @notice Emitted when cross-chain settlement is initiated
    /// @param seriesId The settled option series
    /// @param settlementPrice The price used for settlement (SD59x18)
    /// @param chainsInvolved Number of chains involved
    event SettlementInitiated(uint256 indexed seriesId, int256 settlementPrice, uint256 chainsInvolved);

    /// @notice Emitted when settlement is finalized for a series
    /// @param seriesId The settled option series
    /// @param netAmount The net settlement amount
    event SettlementFinalized(uint256 indexed seriesId, int256 netAmount);

    /// @notice Emitted when a liquidity rebalance is requested
    /// @param rebalanceId The rebalance request ID
    /// @param fromChainId Source chain
    /// @param toChainId Destination chain
    /// @param amount The rebalance amount
    event RebalanceRequested(
        uint256 indexed rebalanceId, uint64 indexed fromChainId, uint64 indexed toChainId, uint256 amount
    );

    /// @notice Emitted when a liquidity rebalance is executed
    /// @param rebalanceId The executed rebalance ID
    event RebalanceExecuted(uint256 indexed rebalanceId);

    /// @notice Emitted when a relayer is authorized or deauthorized
    /// @param relayer The relayer address
    /// @param authorized Whether the relayer is authorized
    event RelayerUpdated(address indexed relayer, bool authorized);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when a zero address is provided
    error CrossChainSettlement__ZeroAddress();

    /// @notice Thrown when the chain is already registered
    error CrossChainSettlement__ChainAlreadyRegistered(uint64 chainId);

    /// @notice Thrown when the chain is not registered
    error CrossChainSettlement__ChainNotRegistered(uint64 chainId);

    /// @notice Thrown when the chain is not active
    error CrossChainSettlement__ChainNotActive(uint64 chainId);

    /// @notice Thrown when the maximum number of chains is reached
    error CrossChainSettlement__MaxChainsReached();

    /// @notice Thrown when a message is not found
    error CrossChainSettlement__MessageNotFound(bytes32 messageId);

    /// @notice Thrown when a message has already been processed
    error CrossChainSettlement__MessageAlreadyProcessed(bytes32 messageId);

    /// @notice Thrown when a message has expired
    error CrossChainSettlement__MessageExpired(bytes32 messageId);

    /// @notice Thrown when the caller is not an authorized relayer
    error CrossChainSettlement__UnauthorizedRelayer(address caller);

    /// @notice Thrown when zero amount is provided
    error CrossChainSettlement__ZeroAmount();

    /// @notice Thrown when the series has already been settled
    error CrossChainSettlement__AlreadySettled(uint256 seriesId);

    /// @notice Thrown when the series has not been settled
    error CrossChainSettlement__NotSettled(uint256 seriesId);

    /// @notice Thrown when settlement price is invalid
    error CrossChainSettlement__InvalidSettlementPrice(int256 price);

    /// @notice Thrown when sync interval has not elapsed
    error CrossChainSettlement__SyncTooFrequent(uint64 chainId, uint256 lastSync, uint256 minInterval);

    /// @notice Thrown when the caller is not the hub
    error CrossChainSettlement__NotHub();

    /// @notice Thrown when the caller is the hub but spoke-only action is attempted
    error CrossChainSettlement__NotSpoke();

    /// @notice Thrown when the chain targets itself
    error CrossChainSettlement__SelfTarget(uint64 chainId);

    /// @notice Thrown when a rebalance request is not found
    error CrossChainSettlement__RebalanceNotFound(uint256 rebalanceId);

    /// @notice Thrown when a rebalance has already been executed
    error CrossChainSettlement__RebalanceAlreadyExecuted(uint256 rebalanceId);

    /// @notice Thrown when insufficient collateral is available
    error CrossChainSettlement__InsufficientCollateral(uint256 available, uint256 required);

    /// @notice Thrown when settlement imbalance exceeds tolerance
    error CrossChainSettlement__SettlementImbalance(int256 imbalance);

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @notice Restricts function to authorized relayers
    modifier onlyRelayer() {
        if (!authorizedRelayers[msg.sender]) {
            revert CrossChainSettlement__UnauthorizedRelayer(msg.sender);
        }
        _;
    }

    /// @notice Restricts function to hub instance only
    modifier onlyHub() {
        if (!isHub) revert CrossChainSettlement__NotHub();
        _;
    }

    /// @notice Restricts function to spoke instance only
    modifier onlySpoke() {
        if (isHub) revert CrossChainSettlement__NotSpoke();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Initializes the cross-chain settlement contract
    /// @param _localChainId The chain ID where this contract is deployed
    /// @param _isHub Whether this instance is the hub (settlement coordinator)
    /// @param _collateralToken The collateral token address used for settlements
    constructor(uint64 _localChainId, bool _isHub, address _collateralToken) Ownable(msg.sender) {
        if (_collateralToken == address(0)) revert CrossChainSettlement__ZeroAddress();

        localChainId = _localChainId;
        isHub = _isHub;
        collateralToken = _collateralToken;
        messageNonce = 0;
        nextRebalanceId = 1;

        // Register self
        chainDeployments[_localChainId] = ChainDeployment({
            chainId: _localChainId,
            deploymentAddress: address(this),
            isActive: true,
            totalLockedCollateral: 0,
            totalPositionValue: 0,
            lastSyncTimestamp: uint64(block.timestamp)
        });
        registeredChains.push(_localChainId);
    }

    // =========================================================================
    // Chain Registration
    // =========================================================================

    /// @notice Registers a new chain deployment for cross-chain settlement
    /// @param chainId The chain ID to register
    /// @param deploymentAddress The contract address on the remote chain
    function registerChain(uint64 chainId, address deploymentAddress) external onlyOwner {
        if (deploymentAddress == address(0)) revert CrossChainSettlement__ZeroAddress();
        if (chainDeployments[chainId].deploymentAddress != address(0)) {
            revert CrossChainSettlement__ChainAlreadyRegistered(chainId);
        }
        if (registeredChains.length >= MAX_CHAINS) revert CrossChainSettlement__MaxChainsReached();

        chainDeployments[chainId] = ChainDeployment({
            chainId: chainId,
            deploymentAddress: deploymentAddress,
            isActive: true,
            totalLockedCollateral: 0,
            totalPositionValue: 0,
            lastSyncTimestamp: 0
        });
        registeredChains.push(chainId);

        emit ChainRegistered(chainId, deploymentAddress);
    }

    /// @notice Deactivates a chain deployment (prevents new operations but allows settlement)
    /// @param chainId The chain ID to deactivate
    function deactivateChain(uint64 chainId) external onlyOwner {
        ChainDeployment storage deployment = chainDeployments[chainId];
        if (deployment.deploymentAddress == address(0)) {
            revert CrossChainSettlement__ChainNotRegistered(chainId);
        }

        deployment.isActive = false;
        emit ChainDeactivated(chainId);
    }

    /// @notice Reactivates a previously deactivated chain
    /// @param chainId The chain ID to reactivate
    function activateChain(uint64 chainId) external onlyOwner {
        ChainDeployment storage deployment = chainDeployments[chainId];
        if (deployment.deploymentAddress == address(0)) {
            revert CrossChainSettlement__ChainNotRegistered(chainId);
        }

        deployment.isActive = true;
        emit ChainActivated(chainId);
    }

    // =========================================================================
    // Relayer Management
    // =========================================================================

    /// @notice Authorizes or deauthorizes a relayer for message confirmation
    /// @param relayer The relayer address
    /// @param authorized Whether the relayer should be authorized
    function setRelayer(address relayer, bool authorized) external onlyOwner {
        if (relayer == address(0)) revert CrossChainSettlement__ZeroAddress();

        authorizedRelayers[relayer] = authorized;
        emit RelayerUpdated(relayer, authorized);
    }

    // =========================================================================
    // Collateral Operations
    // =========================================================================

    /// @notice Locks collateral on the local chain for a cross-chain option position
    /// @param seriesId The option series ID
    /// @param amount The collateral amount to lock
    function lockCollateral(uint256 seriesId, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert CrossChainSettlement__ZeroAmount();

        AggregatedPosition storage aggPos = aggregatedPositions[seriesId];
        if (aggPos.isSettled) revert CrossChainSettlement__AlreadySettled(seriesId);

        // Transfer collateral from sender
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);

        // Update local tracking
        totalLocalCollateral += amount;
        chainDeployments[localChainId].totalLockedCollateral += amount;

        // Update aggregated position
        aggPos.seriesId = seriesId;
        aggPos.totalCollateralAcrossChains += amount;

        // Update chain snapshot
        ChainPositionSnapshot storage snapshot = chainSnapshots[seriesId][localChainId];
        snapshot.chainId = localChainId;
        snapshot.lockedCollateral += amount;

        // Send cross-chain message to hub (if we are spoke)
        if (!isHub) {
            _sendMessage(localChainId, _getHubChainId(), OperationType.LOCK_COLLATERAL, seriesId, amount);
        }

        emit CollateralLocked(seriesId, localChainId, amount, msg.sender);
    }

    /// @notice Releases collateral after settlement on the local chain
    /// @param seriesId The option series ID
    /// @param amount The collateral amount to release
    /// @param recipient The address to receive the collateral
    function releaseCollateral(uint256 seriesId, uint256 amount, address recipient)
        external
        nonReentrant
        whenNotPaused
        onlyRelayer
    {
        if (amount == 0) revert CrossChainSettlement__ZeroAmount();
        if (recipient == address(0)) revert CrossChainSettlement__ZeroAddress();

        AggregatedPosition storage aggPos = aggregatedPositions[seriesId];
        if (!aggPos.isSettled) revert CrossChainSettlement__NotSettled(seriesId);

        if (totalLocalCollateral < amount) {
            revert CrossChainSettlement__InsufficientCollateral(totalLocalCollateral, amount);
        }

        // Update tracking
        totalLocalCollateral -= amount;
        chainDeployments[localChainId].totalLockedCollateral -= amount;

        if (aggPos.totalCollateralAcrossChains >= amount) {
            aggPos.totalCollateralAcrossChains -= amount;
        }

        // Transfer collateral to recipient
        IERC20(collateralToken).safeTransfer(recipient, amount);

        emit CollateralReleased(seriesId, localChainId, amount, recipient);
    }

    // =========================================================================
    // Position Synchronization
    // =========================================================================

    /// @notice Syncs local position data to the hub chain for aggregation
    /// @dev Called by spoke chains to report their position state
    /// @param seriesId The option series ID
    /// @param longAmount Total long positions on this chain
    /// @param shortAmount Total short positions on this chain
    function syncPosition(uint256 seriesId, uint256 longAmount, uint256 shortAmount)
        external
        whenNotPaused
        onlyRelayer
    {
        ChainDeployment storage deployment = chainDeployments[localChainId];
        if (!deployment.isActive) revert CrossChainSettlement__ChainNotActive(localChainId);

        // Enforce minimum sync interval
        uint256 elapsed = block.timestamp - deployment.lastSyncTimestamp;
        if (elapsed < MIN_SYNC_INTERVAL) {
            revert CrossChainSettlement__SyncTooFrequent(localChainId, deployment.lastSyncTimestamp, MIN_SYNC_INTERVAL);
        }

        // Update chain snapshot
        ChainPositionSnapshot storage snapshot = chainSnapshots[seriesId][localChainId];
        snapshot.chainId = localChainId;
        snapshot.longAmount = longAmount;
        snapshot.shortAmount = shortAmount;

        // Update aggregation timestamp
        deployment.lastSyncTimestamp = uint64(block.timestamp);

        // If we are spoke, send sync message to hub
        if (!isHub) {
            _sendMessage(localChainId, _getHubChainId(), OperationType.SYNC_POSITION, seriesId, longAmount);
        }

        emit PositionSynced(seriesId, localChainId, longAmount, shortAmount);
    }

    /// @notice Receives and aggregates position sync data from a spoke chain (hub only)
    /// @param sourceChainId The spoke chain reporting the position
    /// @param seriesId The option series ID
    /// @param longAmount Reported long positions
    /// @param shortAmount Reported short positions
    /// @param lockedCollateral Reported locked collateral
    function receivePositionSync(
        uint64 sourceChainId,
        uint256 seriesId,
        uint256 longAmount,
        uint256 shortAmount,
        uint256 lockedCollateral
    ) external onlyHub onlyRelayer whenNotPaused {
        if (chainDeployments[sourceChainId].deploymentAddress == address(0)) {
            revert CrossChainSettlement__ChainNotRegistered(sourceChainId);
        }

        // Update the chain snapshot for the reporting chain
        ChainPositionSnapshot storage snapshot = chainSnapshots[seriesId][sourceChainId];
        snapshot.chainId = sourceChainId;
        snapshot.longAmount = longAmount;
        snapshot.shortAmount = shortAmount;
        snapshot.lockedCollateral = lockedCollateral;

        // Recompute aggregated position across all chains
        _recomputeAggregatedPosition(seriesId);

        // Update sync timestamp for source chain
        chainDeployments[sourceChainId].lastSyncTimestamp = uint64(block.timestamp);

        emit PositionSynced(seriesId, sourceChainId, longAmount, shortAmount);
    }

    // =========================================================================
    // Cross-Chain Settlement
    // =========================================================================

    /// @notice Initiates cross-chain settlement for an option series (hub only)
    /// @dev Computes net settlement deltas per chain and emits settlement messages
    /// @param seriesId The option series ID to settle
    /// @param settlementPrice The settlement price in SD59x18 format
    /// @param strikePrice The strike price in SD59x18 format
    /// @param isCall Whether the series is a call option
    function initiateSettlement(uint256 seriesId, int256 settlementPrice, int256 strikePrice, bool isCall)
        external
        onlyHub
        onlyOwner
        whenNotPaused
    {
        if (settlementPrice <= 0) revert CrossChainSettlement__InvalidSettlementPrice(settlementPrice);

        AggregatedPosition storage aggPos = aggregatedPositions[seriesId];
        if (aggPos.isSettled) revert CrossChainSettlement__AlreadySettled(seriesId);

        // Calculate intrinsic value per option
        SD59x18 spot = sd(settlementPrice);
        SD59x18 strike = sd(strikePrice);
        SD59x18 payoffPerOption;

        if (isCall) {
            // Call payoff: max(spot - strike, 0)
            if (spot.gt(strike)) {
                payoffPerOption = spot.sub(strike);
            } else {
                payoffPerOption = ZERO;
            }
        } else {
            // Put payoff: max(strike - spot, 0)
            if (strike.gt(spot)) {
                payoffPerOption = strike.sub(spot);
            } else {
                payoffPerOption = ZERO;
            }
        }

        // Compute settlement deltas per chain
        uint256 chainsInvolved = 0;
        int256 totalNetSettlement = 0;

        for (uint256 i = 0; i < registeredChains.length; i++) {
            uint64 chainId = registeredChains[i];
            ChainPositionSnapshot storage snapshot = chainSnapshots[seriesId][chainId];

            if (snapshot.longAmount == 0 && snapshot.shortAmount == 0) continue;

            chainsInvolved++;

            // Net payout for this chain = (longAmount * payoff) - (shortAmount * payoff share)
            SD59x18 longPayout = sd(int256(snapshot.longAmount)).mul(payoffPerOption);
            SD59x18 shortObligation = sd(int256(snapshot.shortAmount)).mul(payoffPerOption);

            // settlementDelta: positive means chain receives net, negative means chain pays net
            int256 delta = longPayout.sub(shortObligation).unwrap();
            snapshot.settlementDelta = delta;
            totalNetSettlement += delta;

            // Send settlement message to each spoke chain
            if (chainId != localChainId) {
                _sendMessage(localChainId, chainId, OperationType.SETTLE, seriesId, snapshot.longAmount);
            }
        }

        // Verify settlement balances (net across all chains should be ~0)
        SD59x18 imbalance = sd(totalNetSettlement).abs();
        SD59x18 totalPositionSize =
            sd(int256(aggPos.totalLongAcrossChains + aggPos.totalShortAcrossChains)).mul(payoffPerOption);

        // Only check imbalance if there is meaningful position size
        if (totalPositionSize.gt(ZERO)) {
            SD59x18 relativeImbalance = imbalance.div(totalPositionSize.abs().add(UNIT));
            if (relativeImbalance.gt(sd(MAX_SETTLEMENT_IMBALANCE))) {
                revert CrossChainSettlement__SettlementImbalance(totalNetSettlement);
            }
        }

        // Finalize settlement
        aggPos.netSettlementAmount = totalNetSettlement;
        aggPos.isSettled = true;

        emit SettlementInitiated(seriesId, settlementPrice, chainsInvolved);
        emit SettlementFinalized(seriesId, totalNetSettlement);
    }

    /// @notice Executes the local portion of a cross-chain settlement (spoke chain)
    /// @param seriesId The option series ID
    /// @param settlementPrice The settlement price used by the hub
    /// @param delta The settlement delta for this chain (from hub computation)
    function executeSettlement(uint256 seriesId, int256 settlementPrice, int256 delta)
        external
        onlyRelayer
        nonReentrant
        whenNotPaused
    {
        if (settlementPrice <= 0) revert CrossChainSettlement__InvalidSettlementPrice(settlementPrice);

        AggregatedPosition storage aggPos = aggregatedPositions[seriesId];
        if (aggPos.isSettled) revert CrossChainSettlement__AlreadySettled(seriesId);

        // Apply settlement delta to chain snapshot
        ChainPositionSnapshot storage snapshot = chainSnapshots[seriesId][localChainId];
        snapshot.settlementDelta = delta;

        // Mark as settled
        aggPos.netSettlementAmount = delta;
        aggPos.isSettled = true;

        emit SettlementFinalized(seriesId, delta);
    }

    // =========================================================================
    // Liquidity Rebalancing
    // =========================================================================

    /// @notice Requests a liquidity rebalance between two chains
    /// @param fromChainId The source chain
    /// @param toChainId The destination chain
    /// @param amount The amount to rebalance
    /// @return rebalanceId The ID of the rebalance request
    function requestRebalance(uint64 fromChainId, uint64 toChainId, uint256 amount)
        external
        onlyOwner
        whenNotPaused
        returns (uint256 rebalanceId)
    {
        if (amount == 0) revert CrossChainSettlement__ZeroAmount();
        if (fromChainId == toChainId) revert CrossChainSettlement__SelfTarget(fromChainId);

        if (chainDeployments[fromChainId].deploymentAddress == address(0)) {
            revert CrossChainSettlement__ChainNotRegistered(fromChainId);
        }
        if (chainDeployments[toChainId].deploymentAddress == address(0)) {
            revert CrossChainSettlement__ChainNotRegistered(toChainId);
        }
        if (!chainDeployments[fromChainId].isActive) revert CrossChainSettlement__ChainNotActive(fromChainId);
        if (!chainDeployments[toChainId].isActive) revert CrossChainSettlement__ChainNotActive(toChainId);

        rebalanceId = nextRebalanceId++;
        rebalanceRequests[rebalanceId] = RebalanceRequest({
            fromChainId: fromChainId, toChainId: toChainId, token: collateralToken, amount: amount, executed: false
        });

        // Send cross-chain rebalance message
        _sendMessage(fromChainId, toChainId, OperationType.LIQUIDITY_REBALANCE, 0, amount);

        emit RebalanceRequested(rebalanceId, fromChainId, toChainId, amount);
    }

    /// @notice Executes a liquidity rebalance on the local chain
    /// @dev Called by a relayer after bridging is complete
    /// @param rebalanceId The rebalance request ID
    function executeRebalance(uint256 rebalanceId) external onlyRelayer nonReentrant whenNotPaused {
        RebalanceRequest storage request = rebalanceRequests[rebalanceId];
        if (request.amount == 0) revert CrossChainSettlement__RebalanceNotFound(rebalanceId);
        if (request.executed) revert CrossChainSettlement__RebalanceAlreadyExecuted(rebalanceId);

        request.executed = true;

        // Update chain deployment collateral tracking
        if (request.fromChainId == localChainId) {
            // We are the source: reduce our tracked collateral
            ChainDeployment storage fromDeployment = chainDeployments[request.fromChainId];
            if (fromDeployment.totalLockedCollateral >= request.amount) {
                fromDeployment.totalLockedCollateral -= request.amount;
            }
        }

        if (request.toChainId == localChainId) {
            // We are the destination: increase our tracked collateral
            chainDeployments[request.toChainId].totalLockedCollateral += request.amount;
        }

        emit RebalanceExecuted(rebalanceId);
    }

    // =========================================================================
    // Message Management
    // =========================================================================

    /// @notice Confirms a pending cross-chain message
    /// @dev Called by an authorized relayer after verifying the message on the destination chain
    /// @param messageId The message to confirm
    function confirmMessage(bytes32 messageId) external onlyRelayer {
        CrossChainMessage storage message = messages[messageId];
        if (message.messageId == bytes32(0)) revert CrossChainSettlement__MessageNotFound(messageId);
        if (message.status != MessageStatus.PENDING) {
            revert CrossChainSettlement__MessageAlreadyProcessed(messageId);
        }
        if (block.timestamp > message.timestamp + MESSAGE_EXPIRY) {
            revert CrossChainSettlement__MessageExpired(messageId);
        }

        message.status = MessageStatus.CONFIRMED;
        message.executedAt = uint64(block.timestamp);

        emit MessageConfirmed(messageId, msg.sender);
    }

    /// @notice Marks a pending message as failed
    /// @param messageId The message to mark as failed
    function failMessage(bytes32 messageId) external onlyRelayer {
        CrossChainMessage storage message = messages[messageId];
        if (message.messageId == bytes32(0)) revert CrossChainSettlement__MessageNotFound(messageId);
        if (message.status != MessageStatus.PENDING) {
            revert CrossChainSettlement__MessageAlreadyProcessed(messageId);
        }

        message.status = MessageStatus.FAILED;

        emit MessageFailed(messageId);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @notice Returns the number of registered chains
    /// @return count The chain count
    function getRegisteredChainCount() external view returns (uint256 count) {
        return registeredChains.length;
    }

    /// @notice Returns all registered chain IDs
    /// @return chains Array of registered chain IDs
    function getRegisteredChains() external view returns (uint64[] memory chains) {
        return registeredChains;
    }

    /// @notice Returns the chain deployment configuration
    /// @param chainId The chain ID
    /// @return deployment The chain deployment data
    function getChainDeployment(uint64 chainId) external view returns (ChainDeployment memory deployment) {
        deployment = chainDeployments[chainId];
        if (deployment.deploymentAddress == address(0)) {
            revert CrossChainSettlement__ChainNotRegistered(chainId);
        }
    }

    /// @notice Returns the aggregated position for a series across all chains
    /// @param seriesId The option series ID
    /// @return position The aggregated position
    function getAggregatedPosition(uint256 seriesId) external view returns (AggregatedPosition memory position) {
        return aggregatedPositions[seriesId];
    }

    /// @notice Returns the position snapshot for a series on a specific chain
    /// @param seriesId The option series ID
    /// @param chainId The chain ID
    /// @return snapshot The chain position snapshot
    function getChainSnapshot(uint256 seriesId, uint64 chainId)
        external
        view
        returns (ChainPositionSnapshot memory snapshot)
    {
        return chainSnapshots[seriesId][chainId];
    }

    /// @notice Returns cross-chain message details
    /// @param messageId The message ID
    /// @return message The message data
    function getMessage(bytes32 messageId) external view returns (CrossChainMessage memory message) {
        message = messages[messageId];
        if (message.messageId == bytes32(0)) revert CrossChainSettlement__MessageNotFound(messageId);
    }

    /// @notice Returns the rebalance request details
    /// @param rebalanceId The rebalance ID
    /// @return request The rebalance request
    function getRebalanceRequest(uint256 rebalanceId) external view returns (RebalanceRequest memory request) {
        request = rebalanceRequests[rebalanceId];
        if (request.amount == 0) revert CrossChainSettlement__RebalanceNotFound(rebalanceId);
    }

    /// @notice Computes the total locked collateral across all registered chains
    /// @return total The total collateral locked across all chains
    function getTotalCollateralAcrossChains() external view returns (uint256 total) {
        for (uint256 i = 0; i < registeredChains.length; i++) {
            total += chainDeployments[registeredChains[i]].totalLockedCollateral;
        }
    }

    /// @notice Checks whether a chain is registered and active
    /// @param chainId The chain ID to check
    /// @return registered Whether the chain is registered
    /// @return active Whether the chain is active
    function isChainActive(uint64 chainId) external view returns (bool registered, bool active) {
        ChainDeployment storage deployment = chainDeployments[chainId];
        registered = deployment.deploymentAddress != address(0);
        active = deployment.isActive;
    }

    /// @notice Returns the settlement delta for a specific chain and series
    /// @param seriesId The option series ID
    /// @param chainId The chain ID
    /// @return delta The settlement delta (positive = receives, negative = pays)
    function getSettlementDelta(uint256 seriesId, uint64 chainId) external view returns (int256 delta) {
        return chainSnapshots[seriesId][chainId].settlementDelta;
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Pauses the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Updates the collateral token address
    /// @param newToken The new collateral token address
    function setCollateralToken(address newToken) external onlyOwner {
        if (newToken == address(0)) revert CrossChainSettlement__ZeroAddress();
        collateralToken = newToken;
    }

    /// @notice Emergency withdrawal of stuck tokens
    /// @param token The token to withdraw
    /// @param amount The amount to withdraw
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /// @notice Creates and stores a cross-chain message
    /// @param sourceChainId The source chain
    /// @param destinationChainId The destination chain
    /// @param operationType The operation type
    /// @param seriesId The related option series
    /// @param amount The amount involved
    /// @return messageId The generated message ID
    function _sendMessage(
        uint64 sourceChainId,
        uint64 destinationChainId,
        OperationType operationType,
        uint256 seriesId,
        uint256 amount
    ) internal returns (bytes32 messageId) {
        messageId = keccak256(abi.encodePacked(sourceChainId, destinationChainId, messageNonce, block.timestamp));
        messageNonce++;

        messages[messageId] = CrossChainMessage({
            messageId: messageId,
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            operationType: operationType,
            seriesId: seriesId,
            amount: amount,
            sender: msg.sender,
            status: MessageStatus.PENDING,
            timestamp: uint64(block.timestamp),
            executedAt: 0
        });

        emit MessageSent(messageId, sourceChainId, destinationChainId, operationType, seriesId, amount);
    }

    /// @notice Recomputes the aggregated position for a series across all chains
    /// @param seriesId The option series ID
    function _recomputeAggregatedPosition(uint256 seriesId) internal {
        AggregatedPosition storage aggPos = aggregatedPositions[seriesId];
        aggPos.seriesId = seriesId;

        uint256 totalLong = 0;
        uint256 totalShort = 0;
        uint256 totalCollateral = 0;

        for (uint256 i = 0; i < registeredChains.length; i++) {
            ChainPositionSnapshot storage snapshot = chainSnapshots[seriesId][registeredChains[i]];
            totalLong += snapshot.longAmount;
            totalShort += snapshot.shortAmount;
            totalCollateral += snapshot.lockedCollateral;
        }

        aggPos.totalLongAcrossChains = totalLong;
        aggPos.totalShortAcrossChains = totalShort;
        aggPos.totalCollateralAcrossChains = totalCollateral;
    }

    /// @notice Gets the hub chain ID (first registered chain by convention)
    /// @return hubChainId The hub chain ID
    function _getHubChainId() internal view returns (uint64 hubChainId) {
        return registeredChains[0];
    }
}
