// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";

/// @title DeploymentRegistry
/// @notice On-chain registry tracking deployed MantissaFi protocol contracts with sequencing and verification
/// @dev Stores deployment records, enforces correct deployment ordering, and supports multi-chain configuration.
///      Uses SD59x18 fixed-point for all fee/vol parameters. Each deployment is immutably recorded.
/// @author MantissaFi Team
contract DeploymentRegistry {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Deployment lifecycle states enforcing correct sequencing
    /// @dev PENDING → LIBRARIES_DEPLOYED → CORE_DEPLOYED → ORACLE_DEPLOYED → SURFACE_DEPLOYED → CONFIGURED → VERIFIED
    enum DeployPhase {
        PENDING,
        LIBRARIES_DEPLOYED,
        CORE_DEPLOYED,
        ORACLE_DEPLOYED,
        SURFACE_DEPLOYED,
        CONFIGURED,
        VERIFIED
    }

    /// @notice Individual contract deployment record
    /// @param contractAddress The deployed contract address
    /// @param deployBlock Block number of deployment
    /// @param deployTimestamp Timestamp of deployment
    /// @param contractName Human-readable contract identifier
    /// @param isVerified Whether the contract has been verified on a block explorer
    struct DeployRecord {
        address contractAddress;
        uint256 deployBlock;
        uint256 deployTimestamp;
        string contractName;
        bool isVerified;
    }

    /// @notice Chain-specific configuration for multi-chain deployments
    /// @param chainId The EVM chain ID
    /// @param chainName Human-readable chain name
    /// @param feeRecipient Address to receive protocol fees on this chain
    /// @param defaultBaseFee Default base fee for FeeController (SD59x18)
    /// @param defaultSpreadFee Default spread fee for FeeController (SD59x18)
    /// @param defaultPoolCap Default pool cap for FeeController
    /// @param oracleDecayFactor EWMA decay factor for RealizedVolOracle (SD59x18)
    /// @param oracleMinObservations Minimum observations before valid volatility
    /// @param oracleAnnualizationFactor Annualization factor for volatility (SD59x18)
    /// @param isConfigured Whether this chain configuration has been set
    struct ChainConfig {
        uint256 chainId;
        string chainName;
        address feeRecipient;
        int256 defaultBaseFee;
        int256 defaultSpreadFee;
        uint256 defaultPoolCap;
        int256 oracleDecayFactor;
        uint256 oracleMinObservations;
        int256 oracleAnnualizationFactor;
        bool isConfigured;
    }

    /// @notice Full deployment manifest for a single chain
    /// @param vault OptionVault address
    /// @param feeController FeeController address
    /// @param oracle RealizedVolOracle address
    /// @param lens OptionLens address
    /// @param router OptionRouter address
    /// @param deployedAt Timestamp of deployment completion
    /// @param phase Current deployment phase
    struct DeploymentManifest {
        address vault;
        address feeController;
        address oracle;
        address lens;
        address router;
        uint256 deployedAt;
        DeployPhase phase;
    }

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Contract version
    string public constant VERSION = "1.0.0";

    /// @notice Maximum allowed base fee (10%)
    int256 public constant MAX_BASE_FEE = 100000000000000000; // 0.1e18

    /// @notice Maximum allowed spread fee (50%)
    int256 public constant MAX_SPREAD_FEE = 500000000000000000; // 0.5e18

    /// @notice Minimum pool cap to prevent division-by-zero
    uint256 public constant MIN_POOL_CAP = 1e18;

    /// @notice Minimum allowed oracle decay factor (0.8)
    int256 public constant MIN_DECAY_FACTOR = 800000000000000000; // 0.8e18

    /// @notice Maximum allowed oracle decay factor (0.99)
    int256 public constant MAX_DECAY_FACTOR = 990000000000000000; // 0.99e18

    /// @notice Arbitrum Sepolia chain ID
    uint256 public constant ARBITRUM_SEPOLIA = 421614;

    /// @notice BSC Testnet chain ID
    uint256 public constant BSC_TESTNET = 97;

    /// @notice Ethereum Sepolia chain ID
    uint256 public constant ETHEREUM_SEPOLIA = 11155111;

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Deployer/owner address
    address public owner;

    /// @notice Chain ID => Deployment manifest
    mapping(uint256 => DeploymentManifest) public manifests;

    /// @notice Chain ID => Chain configuration
    mapping(uint256 => ChainConfig) public chainConfigs;

    /// @notice Chain ID => Contract name hash => DeployRecord
    mapping(uint256 => mapping(bytes32 => DeployRecord)) public deployRecords;

    /// @notice All chain IDs that have been configured
    uint256[] public configuredChains;

    /// @notice Total number of recorded deployments across all chains
    uint256 public totalDeployments;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a chain configuration is set
    /// @param chainId The chain ID
    /// @param chainName Human-readable chain name
    /// @param feeRecipient Protocol fee recipient for this chain
    event ChainConfigured(uint256 indexed chainId, string chainName, address feeRecipient);

    /// @notice Emitted when a contract deployment is recorded
    /// @param chainId The chain ID
    /// @param contractName The contract identifier
    /// @param contractAddress The deployed address
    /// @param phase The new deployment phase after this record
    event ContractDeployed(
        uint256 indexed chainId, string contractName, address indexed contractAddress, DeployPhase phase
    );

    /// @notice Emitted when deployment phase advances
    /// @param chainId The chain ID
    /// @param previousPhase The previous phase
    /// @param newPhase The new phase
    event PhaseAdvanced(uint256 indexed chainId, DeployPhase previousPhase, DeployPhase newPhase);

    /// @notice Emitted when a contract is marked as verified on block explorer
    /// @param chainId The chain ID
    /// @param contractName The contract identifier
    /// @param contractAddress The verified contract address
    event ContractVerified(uint256 indexed chainId, string contractName, address indexed contractAddress);

    /// @notice Emitted when permissions are configured post-deployment
    /// @param chainId The chain ID
    /// @param description Description of the permissions configured
    event PermissionsConfigured(uint256 indexed chainId, string description);

    /// @notice Emitted when ownership is transferred
    /// @param previousOwner The previous owner
    /// @param newOwner The new owner
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when caller is not the owner
    error DeploymentRegistry__Unauthorized();

    /// @notice Thrown when a zero address is provided where non-zero is required
    error DeploymentRegistry__ZeroAddress();

    /// @notice Thrown when the chain is not configured
    error DeploymentRegistry__ChainNotConfigured(uint256 chainId);

    /// @notice Thrown when the chain is already configured
    error DeploymentRegistry__ChainAlreadyConfigured(uint256 chainId);

    /// @notice Thrown when the deployment phase is invalid for the requested operation
    error DeploymentRegistry__InvalidPhase(DeployPhase current, DeployPhase required);

    /// @notice Thrown when a contract is already deployed at this name on this chain
    error DeploymentRegistry__AlreadyDeployed(uint256 chainId, string contractName);

    /// @notice Thrown when fee parameters are invalid
    error DeploymentRegistry__InvalidFeeParams(string reason);

    /// @notice Thrown when oracle parameters are invalid
    error DeploymentRegistry__InvalidOracleParams(string reason);

    /// @notice Thrown when the contract name is empty
    error DeploymentRegistry__EmptyContractName();

    /// @notice Thrown when attempting to verify an undeployed contract
    error DeploymentRegistry__NotDeployed(uint256 chainId, string contractName);

    /// @notice Thrown when a contract is already verified
    error DeploymentRegistry__AlreadyVerified(uint256 chainId, string contractName);

    /// @notice Thrown when the chain ID array is empty
    error DeploymentRegistry__EmptyChainList();

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @notice Restricts function access to the owner
    modifier onlyOwner() {
        if (msg.sender != owner) revert DeploymentRegistry__Unauthorized();
        _;
    }

    /// @notice Ensures the chain is configured
    modifier chainExists(uint256 chainId) {
        if (!chainConfigs[chainId].isConfigured) {
            revert DeploymentRegistry__ChainNotConfigured(chainId);
        }
        _;
    }

    /// @notice Ensures the deployment is at the required phase
    modifier atPhase(uint256 chainId, DeployPhase required) {
        DeployPhase current = manifests[chainId].phase;
        if (current != required) {
            revert DeploymentRegistry__InvalidPhase(current, required);
        }
        _;
    }

    /// @notice Ensures the deployment is at least at the required phase
    modifier atLeastPhase(uint256 chainId, DeployPhase required) {
        DeployPhase current = manifests[chainId].phase;
        if (uint8(current) < uint8(required)) {
            revert DeploymentRegistry__InvalidPhase(current, required);
        }
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Initializes the registry with the deployer as owner
    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // =========================================================================
    // Chain Configuration
    // =========================================================================

    /// @notice Configures a target chain for deployment
    /// @dev Validates all fee and oracle parameters before storing
    /// @param config The chain configuration to store
    function configureChain(ChainConfig memory config) external onlyOwner {
        if (chainConfigs[config.chainId].isConfigured) {
            revert DeploymentRegistry__ChainAlreadyConfigured(config.chainId);
        }
        if (config.feeRecipient == address(0)) revert DeploymentRegistry__ZeroAddress();

        _validateFeeParams(config.defaultBaseFee, config.defaultSpreadFee, config.defaultPoolCap);
        _validateOracleParams(config.oracleDecayFactor, config.oracleMinObservations, config.oracleAnnualizationFactor);

        config.isConfigured = true;
        chainConfigs[config.chainId] = config;
        configuredChains.push(config.chainId);

        emit ChainConfigured(config.chainId, config.chainName, config.feeRecipient);
    }

    /// @notice Configures the three supported testnets with default parameters
    /// @param feeRecipient The address to receive fees on all chains
    function configureDefaultTestnets(address feeRecipient) external onlyOwner {
        if (feeRecipient == address(0)) revert DeploymentRegistry__ZeroAddress();

        int256 baseFee = 3000000000000000; // 0.003e18 = 30 bps
        int256 spreadFee = 50000000000000000; // 0.05e18 = 500 bps
        uint256 poolCap = 1000000e18; // 1M tokens
        int256 decayFactor = 940000000000000000; // 0.94
        uint256 minObs = 10;
        int256 annFactor = 19104973174542800000; // sqrt(365) ≈ 19.1e18

        _configureChainInternal(
            ARBITRUM_SEPOLIA,
            "Arbitrum Sepolia",
            feeRecipient,
            baseFee,
            spreadFee,
            poolCap,
            decayFactor,
            minObs,
            annFactor
        );
        _configureChainInternal(
            BSC_TESTNET, "BSC Testnet", feeRecipient, baseFee, spreadFee, poolCap, decayFactor, minObs, annFactor
        );
        _configureChainInternal(
            ETHEREUM_SEPOLIA,
            "Ethereum Sepolia",
            feeRecipient,
            baseFee,
            spreadFee,
            poolCap,
            decayFactor,
            minObs,
            annFactor
        );
    }

    // =========================================================================
    // Deployment Recording — Phase Transitions
    // =========================================================================

    /// @notice Records deployment of math libraries (phase PENDING → LIBRARIES_DEPLOYED)
    /// @dev Libraries are typically deployed automatically by the Solidity compiler. This records
    ///      them for tracking purposes.
    /// @param chainId The target chain ID
    /// @param libraryAddresses Array of library contract addresses
    /// @param libraryNames Array of library names (must match addresses length)
    function recordLibraryDeployments(
        uint256 chainId,
        address[] calldata libraryAddresses,
        string[] calldata libraryNames
    ) external onlyOwner chainExists(chainId) atPhase(chainId, DeployPhase.PENDING) {
        uint256 len = libraryAddresses.length;
        if (len != libraryNames.length) {
            revert DeploymentRegistry__InvalidFeeParams("Array length mismatch");
        }

        for (uint256 i; i < len; ++i) {
            _recordDeployment(chainId, libraryNames[i], libraryAddresses[i]);
        }

        _advancePhase(chainId, DeployPhase.LIBRARIES_DEPLOYED);
    }

    /// @notice Records deployment of core contracts (phase LIBRARIES_DEPLOYED → CORE_DEPLOYED)
    /// @dev Must deploy in order: OptionVault → FeeController → OptionLens → OptionRouter
    /// @param chainId The target chain ID
    /// @param vault OptionVault address
    /// @param feeController FeeController address
    /// @param lens OptionLens address
    /// @param router OptionRouter address
    function recordCoreDeployments(uint256 chainId, address vault, address feeController, address lens, address router)
        external
        onlyOwner
        chainExists(chainId)
        atPhase(chainId, DeployPhase.LIBRARIES_DEPLOYED)
    {
        if (vault == address(0)) revert DeploymentRegistry__ZeroAddress();
        if (feeController == address(0)) revert DeploymentRegistry__ZeroAddress();
        if (lens == address(0)) revert DeploymentRegistry__ZeroAddress();
        if (router == address(0)) revert DeploymentRegistry__ZeroAddress();

        _recordDeployment(chainId, "OptionVault", vault);
        _recordDeployment(chainId, "FeeController", feeController);
        _recordDeployment(chainId, "OptionLens", lens);
        _recordDeployment(chainId, "OptionRouter", router);

        DeploymentManifest storage manifest = manifests[chainId];
        manifest.vault = vault;
        manifest.feeController = feeController;
        manifest.lens = lens;
        manifest.router = router;

        _advancePhase(chainId, DeployPhase.CORE_DEPLOYED);
    }

    /// @notice Records deployment of oracle adapter (phase CORE_DEPLOYED → ORACLE_DEPLOYED)
    /// @param chainId The target chain ID
    /// @param oracle RealizedVolOracle address
    function recordOracleDeployment(uint256 chainId, address oracle)
        external
        onlyOwner
        chainExists(chainId)
        atPhase(chainId, DeployPhase.CORE_DEPLOYED)
    {
        if (oracle == address(0)) revert DeploymentRegistry__ZeroAddress();

        _recordDeployment(chainId, "RealizedVolOracle", oracle);

        manifests[chainId].oracle = oracle;

        _advancePhase(chainId, DeployPhase.ORACLE_DEPLOYED);
    }

    /// @notice Records that the volatility surface library is available (phase ORACLE_DEPLOYED → SURFACE_DEPLOYED)
    /// @dev VolatilitySurface is a library and doesn't have a separate deployed address.
    ///      This step confirms it was linked at compile time.
    /// @param chainId The target chain ID
    function recordSurfaceDeployment(uint256 chainId)
        external
        onlyOwner
        chainExists(chainId)
        atPhase(chainId, DeployPhase.ORACLE_DEPLOYED)
    {
        // VolatilitySurface is an internal library — record a sentinel for tracking
        _recordDeployment(chainId, "VolatilitySurface", address(1));

        _advancePhase(chainId, DeployPhase.SURFACE_DEPLOYED);
    }

    /// @notice Records that permissions and parameters have been configured (phase SURFACE_DEPLOYED → CONFIGURED)
    /// @param chainId The target chain ID
    /// @param description Description of what was configured
    function recordConfiguration(uint256 chainId, string calldata description)
        external
        onlyOwner
        chainExists(chainId)
        atPhase(chainId, DeployPhase.SURFACE_DEPLOYED)
    {
        manifests[chainId].deployedAt = block.timestamp;

        _advancePhase(chainId, DeployPhase.CONFIGURED);

        emit PermissionsConfigured(chainId, description);
    }

    // =========================================================================
    // Verification
    // =========================================================================

    /// @notice Marks a deployed contract as verified on a block explorer
    /// @param chainId The target chain ID
    /// @param contractName The contract identifier
    function markVerified(uint256 chainId, string calldata contractName)
        external
        onlyOwner
        chainExists(chainId)
        atLeastPhase(chainId, DeployPhase.CORE_DEPLOYED)
    {
        bytes32 nameHash = keccak256(abi.encodePacked(contractName));
        DeployRecord storage record = deployRecords[chainId][nameHash];

        if (record.contractAddress == address(0)) {
            revert DeploymentRegistry__NotDeployed(chainId, contractName);
        }
        if (record.isVerified) {
            revert DeploymentRegistry__AlreadyVerified(chainId, contractName);
        }

        record.isVerified = true;

        emit ContractVerified(chainId, contractName, record.contractAddress);
    }

    /// @notice Marks all core contracts as verified and advances to VERIFIED phase
    /// @param chainId The target chain ID
    function markAllVerified(uint256 chainId)
        external
        onlyOwner
        chainExists(chainId)
        atPhase(chainId, DeployPhase.CONFIGURED)
    {
        _markRecordVerified(chainId, "OptionVault");
        _markRecordVerified(chainId, "FeeController");
        _markRecordVerified(chainId, "OptionLens");
        _markRecordVerified(chainId, "OptionRouter");
        _markRecordVerified(chainId, "RealizedVolOracle");

        _advancePhase(chainId, DeployPhase.VERIFIED);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @notice Returns the full deployment manifest for a chain
    /// @param chainId The target chain ID
    /// @return manifest The deployment manifest
    function getManifest(uint256 chainId) external view chainExists(chainId) returns (DeploymentManifest memory) {
        return manifests[chainId];
    }

    /// @notice Returns the chain configuration
    /// @param chainId The target chain ID
    /// @return config The chain configuration
    function getChainConfig(uint256 chainId) external view chainExists(chainId) returns (ChainConfig memory) {
        return chainConfigs[chainId];
    }

    /// @notice Returns the deployment record for a specific contract on a chain
    /// @param chainId The target chain ID
    /// @param contractName The contract identifier
    /// @return record The deployment record
    function getDeployRecord(uint256 chainId, string calldata contractName)
        external
        view
        chainExists(chainId)
        returns (DeployRecord memory)
    {
        bytes32 nameHash = keccak256(abi.encodePacked(contractName));
        return deployRecords[chainId][nameHash];
    }

    /// @notice Returns all configured chain IDs
    /// @return chains Array of configured chain IDs
    function getConfiguredChains() external view returns (uint256[] memory) {
        return configuredChains;
    }

    /// @notice Returns the number of configured chains
    /// @return count The number of chains
    function getConfiguredChainsCount() external view returns (uint256) {
        return configuredChains.length;
    }

    /// @notice Returns the current deployment phase for a chain
    /// @param chainId The target chain ID
    /// @return phase The current deployment phase
    function getPhase(uint256 chainId) external view chainExists(chainId) returns (DeployPhase) {
        return manifests[chainId].phase;
    }

    /// @notice Checks whether a specific contract has been deployed on a chain
    /// @param chainId The target chain ID
    /// @param contractName The contract identifier
    /// @return deployed True if the contract has a non-zero address recorded
    function isDeployed(uint256 chainId, string calldata contractName) external view returns (bool) {
        if (!chainConfigs[chainId].isConfigured) return false;
        bytes32 nameHash = keccak256(abi.encodePacked(contractName));
        return deployRecords[chainId][nameHash].contractAddress != address(0);
    }

    /// @notice Checks whether all core contracts are verified on a chain
    /// @param chainId The target chain ID
    /// @return verified True if all core contracts are verified
    function isFullyVerified(uint256 chainId) external view chainExists(chainId) returns (bool) {
        return manifests[chainId].phase == DeployPhase.VERIFIED;
    }

    /// @notice Validates fee parameters against protocol bounds using SD59x18 arithmetic
    /// @param baseFee The base fee to validate (SD59x18)
    /// @param spreadFee The spread fee to validate (SD59x18)
    /// @param poolCap The pool cap to validate
    /// @return valid True if parameters are within bounds
    function validateFeeParams(int256 baseFee, int256 spreadFee, uint256 poolCap) external pure returns (bool valid) {
        if (baseFee < 0 || baseFee > MAX_BASE_FEE) return false;
        if (spreadFee < 0 || spreadFee > MAX_SPREAD_FEE) return false;
        if (poolCap < MIN_POOL_CAP) return false;
        return true;
    }

    /// @notice Validates oracle parameters against protocol bounds
    /// @param decayFactor The EWMA decay factor (SD59x18)
    /// @param minObservations The minimum number of observations
    /// @param annualizationFactor The annualization factor (SD59x18)
    /// @return valid True if parameters are within bounds
    function validateOracleParams(int256 decayFactor, uint256 minObservations, int256 annualizationFactor)
        external
        pure
        returns (bool valid)
    {
        if (decayFactor < MIN_DECAY_FACTOR || decayFactor > MAX_DECAY_FACTOR) return false;
        if (minObservations == 0) return false;
        if (annualizationFactor <= 0) return false;
        return true;
    }

    /// @notice Computes the expected fee rate at a given utilization level
    /// @dev feeRate = baseFee + spreadFee × utilization²
    /// @param baseFee The base fee (SD59x18)
    /// @param spreadFee The spread fee (SD59x18)
    /// @param utilization The utilization ratio (SD59x18, 0 to 1e18)
    /// @return feeRate The computed fee rate (SD59x18)
    function computeExpectedFeeRate(int256 baseFee, int256 spreadFee, int256 utilization)
        external
        pure
        returns (int256 feeRate)
    {
        SD59x18 base = sd(baseFee);
        SD59x18 spread = sd(spreadFee);
        SD59x18 util = sd(utilization);

        // Clamp utilization to [0, 1]
        if (util.lt(ZERO)) util = ZERO;
        if (util.gt(UNIT)) util = UNIT;

        SD59x18 utilSquared = util.mul(util);
        SD59x18 rate = base.add(spread.mul(utilSquared));

        return rate.unwrap();
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Transfers ownership of the registry
    /// @param newOwner The new owner address
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert DeploymentRegistry__ZeroAddress();

        address previousOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(previousOwner, newOwner);
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /// @notice Records a single contract deployment
    /// @param chainId The chain ID
    /// @param contractName The contract identifier
    /// @param contractAddress The deployed address
    function _recordDeployment(uint256 chainId, string memory contractName, address contractAddress) internal {
        if (bytes(contractName).length == 0) revert DeploymentRegistry__EmptyContractName();

        bytes32 nameHash = keccak256(abi.encodePacked(contractName));

        if (deployRecords[chainId][nameHash].contractAddress != address(0)) {
            revert DeploymentRegistry__AlreadyDeployed(chainId, contractName);
        }

        deployRecords[chainId][nameHash] = DeployRecord({
            contractAddress: contractAddress,
            deployBlock: block.number,
            deployTimestamp: block.timestamp,
            contractName: contractName,
            isVerified: false
        });

        totalDeployments++;

        emit ContractDeployed(chainId, contractName, contractAddress, manifests[chainId].phase);
    }

    /// @notice Advances the deployment phase for a chain
    /// @param chainId The chain ID
    /// @param newPhase The new phase to transition to
    function _advancePhase(uint256 chainId, DeployPhase newPhase) internal {
        DeployPhase previousPhase = manifests[chainId].phase;
        manifests[chainId].phase = newPhase;

        emit PhaseAdvanced(chainId, previousPhase, newPhase);
    }

    /// @notice Internal chain configuration helper
    function _configureChainInternal(
        uint256 chainId,
        string memory chainName,
        address feeRecipient,
        int256 baseFee,
        int256 spreadFee,
        uint256 poolCap,
        int256 decayFactor,
        uint256 minObs,
        int256 annFactor
    ) internal {
        if (chainConfigs[chainId].isConfigured) {
            revert DeploymentRegistry__ChainAlreadyConfigured(chainId);
        }

        chainConfigs[chainId] = ChainConfig({
            chainId: chainId,
            chainName: chainName,
            feeRecipient: feeRecipient,
            defaultBaseFee: baseFee,
            defaultSpreadFee: spreadFee,
            defaultPoolCap: poolCap,
            oracleDecayFactor: decayFactor,
            oracleMinObservations: minObs,
            oracleAnnualizationFactor: annFactor,
            isConfigured: true
        });

        configuredChains.push(chainId);

        emit ChainConfigured(chainId, chainName, feeRecipient);
    }

    /// @notice Validates fee parameters against bounds
    function _validateFeeParams(int256 baseFee, int256 spreadFee, uint256 poolCap) internal pure {
        if (baseFee < 0) revert DeploymentRegistry__InvalidFeeParams("Base fee negative");
        if (baseFee > MAX_BASE_FEE) revert DeploymentRegistry__InvalidFeeParams("Base fee exceeds maximum");
        if (spreadFee < 0) revert DeploymentRegistry__InvalidFeeParams("Spread fee negative");
        if (spreadFee > MAX_SPREAD_FEE) revert DeploymentRegistry__InvalidFeeParams("Spread fee exceeds maximum");
        if (poolCap < MIN_POOL_CAP) revert DeploymentRegistry__InvalidFeeParams("Pool cap too low");
    }

    /// @notice Validates oracle parameters against bounds
    function _validateOracleParams(int256 decayFactor, uint256 minObservations, int256 annualizationFactor)
        internal
        pure
    {
        if (decayFactor < MIN_DECAY_FACTOR) {
            revert DeploymentRegistry__InvalidOracleParams("Decay factor too low");
        }
        if (decayFactor > MAX_DECAY_FACTOR) revert DeploymentRegistry__InvalidOracleParams("Decay factor too high");
        if (minObservations == 0) revert DeploymentRegistry__InvalidOracleParams("Min observations is zero");
        if (annualizationFactor <= 0) {
            revert DeploymentRegistry__InvalidOracleParams("Annualization factor not positive");
        }
    }

    /// @notice Marks a deploy record as verified (internal helper)
    function _markRecordVerified(uint256 chainId, string memory contractName) internal {
        bytes32 nameHash = keccak256(abi.encodePacked(contractName));
        DeployRecord storage record = deployRecords[chainId][nameHash];

        if (record.contractAddress == address(0)) {
            revert DeploymentRegistry__NotDeployed(chainId, contractName);
        }

        record.isVerified = true;
        emit ContractVerified(chainId, contractName, record.contractAddress);
    }
}
