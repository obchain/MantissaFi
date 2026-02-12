// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { DeploymentRegistry } from "../../src/libraries/deploymentscriptsscriptDeployssol.sol";

/// @title deploymentscriptsscriptDeployssolTest
/// @notice Unit tests for DeploymentRegistry contract
contract deploymentscriptsscriptDeployssolTest is Test {
    DeploymentRegistry public registry;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public feeRecipient = address(0xFEE);

    // Mock deployed addresses
    address public mockVault = address(0x100);
    address public mockFeeController = address(0x101);
    address public mockLens = address(0x102);
    address public mockRouter = address(0x103);
    address public mockOracle = address(0x104);

    // Valid fee parameters
    int256 public constant VALID_BASE_FEE = 3000000000000000; // 0.003e18 = 30 bps
    int256 public constant VALID_SPREAD_FEE = 50000000000000000; // 0.05e18 = 500 bps
    uint256 public constant VALID_POOL_CAP = 1000000e18;

    // Valid oracle parameters
    int256 public constant VALID_DECAY = 940000000000000000; // 0.94e18
    uint256 public constant VALID_MIN_OBS = 10;
    int256 public constant VALID_ANN_FACTOR = 19104973174542800000; // sqrt(365) ≈ 19.1e18

    function setUp() public {
        registry = new DeploymentRegistry();
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_setsOwner() public view {
        assertEq(registry.owner(), owner, "Owner should be deployer");
    }

    function test_constructor_versionIsSet() public view {
        assertEq(registry.VERSION(), "1.0.0", "Version mismatch");
    }

    function test_constructor_totalDeploymentsIsZero() public view {
        assertEq(registry.totalDeployments(), 0, "Should start with zero deployments");
    }

    function test_constructor_noChainsConfigured() public view {
        assertEq(registry.getConfiguredChainsCount(), 0, "Should start with no chains");
    }

    // =========================================================================
    // Chain Configuration Tests
    // =========================================================================

    function test_configureChain_success() public {
        DeploymentRegistry.ChainConfig memory config = _createValidChainConfig(421614, "Arbitrum Sepolia");

        registry.configureChain(config);

        DeploymentRegistry.ChainConfig memory stored = registry.getChainConfig(421614);
        assertEq(stored.chainId, 421614, "Chain ID mismatch");
        assertEq(stored.feeRecipient, feeRecipient, "Fee recipient mismatch");
        assertEq(stored.defaultBaseFee, VALID_BASE_FEE, "Base fee mismatch");
        assertTrue(stored.isConfigured, "Should be configured");
    }

    function test_configureChain_incrementsChainsCount() public {
        _configureChain(421614, "Arbitrum Sepolia");

        assertEq(registry.getConfiguredChainsCount(), 1, "Should have 1 chain");

        _configureChain(97, "BSC Testnet");

        assertEq(registry.getConfiguredChainsCount(), 2, "Should have 2 chains");
    }

    function test_configureChain_revertDuplicate() public {
        _configureChain(421614, "Arbitrum Sepolia");

        DeploymentRegistry.ChainConfig memory config = _createValidChainConfig(421614, "Duplicate");

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentRegistry.DeploymentRegistry__ChainAlreadyConfigured.selector, 421614)
        );
        registry.configureChain(config);
    }

    function test_configureChain_revertZeroFeeRecipient() public {
        DeploymentRegistry.ChainConfig memory config = _createValidChainConfig(421614, "Test");
        config.feeRecipient = address(0);

        vm.expectRevert(DeploymentRegistry.DeploymentRegistry__ZeroAddress.selector);
        registry.configureChain(config);
    }

    function test_configureChain_revertNegativeBaseFee() public {
        DeploymentRegistry.ChainConfig memory config = _createValidChainConfig(421614, "Test");
        config.defaultBaseFee = -1;

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentRegistry.DeploymentRegistry__InvalidFeeParams.selector, "Base fee negative"
            )
        );
        registry.configureChain(config);
    }

    function test_configureChain_revertBaseFeeExceedsMax() public {
        DeploymentRegistry.ChainConfig memory config = _createValidChainConfig(421614, "Test");
        config.defaultBaseFee = 100000000000000001; // MAX_BASE_FEE + 1

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentRegistry.DeploymentRegistry__InvalidFeeParams.selector, "Base fee exceeds maximum"
            )
        );
        registry.configureChain(config);
    }

    function test_configureChain_revertPoolCapTooLow() public {
        DeploymentRegistry.ChainConfig memory config = _createValidChainConfig(421614, "Test");
        config.defaultPoolCap = 0;

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentRegistry.DeploymentRegistry__InvalidFeeParams.selector, "Pool cap too low")
        );
        registry.configureChain(config);
    }

    function test_configureChain_revertDecayFactorTooLow() public {
        DeploymentRegistry.ChainConfig memory config = _createValidChainConfig(421614, "Test");
        config.oracleDecayFactor = 799999999999999999; // Below MIN_DECAY_FACTOR

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentRegistry.DeploymentRegistry__InvalidOracleParams.selector, "Decay factor too low"
            )
        );
        registry.configureChain(config);
    }

    function test_configureChain_revertUnauthorized() public {
        DeploymentRegistry.ChainConfig memory config = _createValidChainConfig(421614, "Test");

        vm.prank(alice);
        vm.expectRevert(DeploymentRegistry.DeploymentRegistry__Unauthorized.selector);
        registry.configureChain(config);
    }

    // =========================================================================
    // Default Testnets Tests
    // =========================================================================

    function test_configureDefaultTestnets_success() public {
        registry.configureDefaultTestnets(feeRecipient);

        assertEq(registry.getConfiguredChainsCount(), 3, "Should have 3 chains");

        uint256[] memory chains = registry.getConfiguredChains();
        assertEq(chains[0], 421614, "First chain should be Arbitrum Sepolia");
        assertEq(chains[1], 97, "Second chain should be BSC Testnet");
        assertEq(chains[2], 11155111, "Third chain should be Ethereum Sepolia");
    }

    function test_configureDefaultTestnets_revertZeroRecipient() public {
        vm.expectRevert(DeploymentRegistry.DeploymentRegistry__ZeroAddress.selector);
        registry.configureDefaultTestnets(address(0));
    }

    function test_configureDefaultTestnets_storesCorrectParams() public {
        registry.configureDefaultTestnets(feeRecipient);

        DeploymentRegistry.ChainConfig memory arbConfig = registry.getChainConfig(421614);
        assertEq(arbConfig.defaultBaseFee, 3000000000000000, "Arbitrum base fee mismatch");
        assertEq(arbConfig.defaultSpreadFee, 50000000000000000, "Arbitrum spread fee mismatch");
        assertEq(arbConfig.defaultPoolCap, 1000000e18, "Arbitrum pool cap mismatch");
        assertEq(arbConfig.oracleDecayFactor, 940000000000000000, "Arbitrum decay factor mismatch");
    }

    // =========================================================================
    // Deployment Phase Sequencing Tests
    // =========================================================================

    function test_fullDeploymentSequence() public {
        _configureChain(421614, "Arbitrum Sepolia");

        // Phase 0: PENDING
        assertEq(uint256(registry.getPhase(421614)), uint256(DeploymentRegistry.DeployPhase.PENDING));

        // Phase 1: Libraries
        address[] memory libAddrs = new address[](2);
        libAddrs[0] = address(0x10);
        libAddrs[1] = address(0x11);
        string[] memory libNames = new string[](2);
        libNames[0] = "CumulativeNormal";
        libNames[1] = "OptionMath";
        registry.recordLibraryDeployments(421614, libAddrs, libNames);
        assertEq(uint256(registry.getPhase(421614)), uint256(DeploymentRegistry.DeployPhase.LIBRARIES_DEPLOYED));

        // Phase 2: Core
        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter);
        assertEq(uint256(registry.getPhase(421614)), uint256(DeploymentRegistry.DeployPhase.CORE_DEPLOYED));

        // Phase 3: Oracle
        registry.recordOracleDeployment(421614, mockOracle);
        assertEq(uint256(registry.getPhase(421614)), uint256(DeploymentRegistry.DeployPhase.ORACLE_DEPLOYED));

        // Phase 4: Surface
        registry.recordSurfaceDeployment(421614);
        assertEq(uint256(registry.getPhase(421614)), uint256(DeploymentRegistry.DeployPhase.SURFACE_DEPLOYED));

        // Phase 5: Configuration
        registry.recordConfiguration(421614, "Set vault owner and fee config");
        assertEq(uint256(registry.getPhase(421614)), uint256(DeploymentRegistry.DeployPhase.CONFIGURED));

        // Phase 6: Verification
        registry.markAllVerified(421614);
        assertEq(uint256(registry.getPhase(421614)), uint256(DeploymentRegistry.DeployPhase.VERIFIED));
        assertTrue(registry.isFullyVerified(421614));
    }

    function test_recordLibraries_revertWrongPhase() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614);

        // Now at LIBRARIES_DEPLOYED — recording libs again should revert
        address[] memory addrs = new address[](1);
        addrs[0] = address(0x10);
        string[] memory names = new string[](1);
        names[0] = "Lib";

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentRegistry.DeploymentRegistry__InvalidPhase.selector,
                DeploymentRegistry.DeployPhase.LIBRARIES_DEPLOYED,
                DeploymentRegistry.DeployPhase.PENDING
            )
        );
        registry.recordLibraryDeployments(421614, addrs, names);
    }

    function test_recordCoreDeployments_revertZeroVault() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614);

        vm.expectRevert(DeploymentRegistry.DeploymentRegistry__ZeroAddress.selector);
        registry.recordCoreDeployments(421614, address(0), mockFeeController, mockLens, mockRouter);
    }

    function test_recordCoreDeployments_storesManifest() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614);
        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter);

        DeploymentRegistry.DeploymentManifest memory manifest = registry.getManifest(421614);
        assertEq(manifest.vault, mockVault, "Vault address mismatch");
        assertEq(manifest.feeController, mockFeeController, "FeeController address mismatch");
        assertEq(manifest.lens, mockLens, "Lens address mismatch");
        assertEq(manifest.router, mockRouter, "Router address mismatch");
    }

    function test_recordOracleDeployment_revertZeroAddress() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614);
        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter);

        vm.expectRevert(DeploymentRegistry.DeploymentRegistry__ZeroAddress.selector);
        registry.recordOracleDeployment(421614, address(0));
    }

    function test_recordOracleDeployment_storesInManifest() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614);
        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter);
        registry.recordOracleDeployment(421614, mockOracle);

        DeploymentRegistry.DeploymentManifest memory manifest = registry.getManifest(421614);
        assertEq(manifest.oracle, mockOracle, "Oracle address mismatch");
    }

    function test_recordConfiguration_setsDeployedAt() public {
        _configureChain(421614, "Test");
        _advanceToSurfaceDeployed(421614);

        uint256 ts = block.timestamp;
        registry.recordConfiguration(421614, "All permissions set");

        DeploymentRegistry.DeploymentManifest memory manifest = registry.getManifest(421614);
        assertEq(manifest.deployedAt, ts, "deployedAt should match block.timestamp");
    }

    // =========================================================================
    // Verification Tests
    // =========================================================================

    function test_markVerified_success() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614);
        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter);

        registry.markVerified(421614, "OptionVault");

        DeploymentRegistry.DeployRecord memory record = registry.getDeployRecord(421614, "OptionVault");
        assertTrue(record.isVerified, "Should be verified");
    }

    function test_markVerified_revertNotDeployed() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614);
        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter);

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentRegistry.DeploymentRegistry__NotDeployed.selector, 421614, "NonExistent")
        );
        registry.markVerified(421614, "NonExistent");
    }

    function test_markVerified_revertAlreadyVerified() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614);
        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter);

        registry.markVerified(421614, "OptionVault");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentRegistry.DeploymentRegistry__AlreadyVerified.selector, 421614, "OptionVault"
            )
        );
        registry.markVerified(421614, "OptionVault");
    }

    // =========================================================================
    // View Function Tests
    // =========================================================================

    function test_isDeployed_returnsFalseForUnconfiguredChain() public view {
        assertFalse(registry.isDeployed(999, "OptionVault"), "Should be false for unconfigured chain");
    }

    function test_isDeployed_returnsTrueAfterRecording() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614);
        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter);

        assertTrue(registry.isDeployed(421614, "OptionVault"), "Should be deployed");
        assertTrue(registry.isDeployed(421614, "FeeController"), "Should be deployed");
    }

    function test_isDeployed_returnsFalseForNonDeployedContract() public {
        _configureChain(421614, "Test");

        assertFalse(registry.isDeployed(421614, "OptionVault"), "Should not be deployed yet");
    }

    function test_getDeployRecord_returnsCorrectData() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614);
        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter);

        DeploymentRegistry.DeployRecord memory record = registry.getDeployRecord(421614, "OptionVault");
        assertEq(record.contractAddress, mockVault, "Address mismatch");
        assertEq(record.deployBlock, block.number, "Block number mismatch");
        assertEq(record.deployTimestamp, block.timestamp, "Timestamp mismatch");
        assertFalse(record.isVerified, "Should not be verified yet");
    }

    function test_totalDeployments_incrementsCorrectly() public {
        _configureChain(421614, "Test");
        _deployLibraries(421614); // 2 libs
        assertEq(registry.totalDeployments(), 2, "Should have 2 after libs");

        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter); // 4 more
        assertEq(registry.totalDeployments(), 6, "Should have 6 after core");
    }

    // =========================================================================
    // Validation View Functions Tests
    // =========================================================================

    function test_validateFeeParams_validReturnsTrue() public view {
        assertTrue(registry.validateFeeParams(VALID_BASE_FEE, VALID_SPREAD_FEE, VALID_POOL_CAP));
    }

    function test_validateFeeParams_negativeBaseFeeReturnsFalse() public view {
        assertFalse(registry.validateFeeParams(-1, VALID_SPREAD_FEE, VALID_POOL_CAP));
    }

    function test_validateFeeParams_excessiveBaseFeeReturnsFalse() public view {
        assertFalse(registry.validateFeeParams(100000000000000001, VALID_SPREAD_FEE, VALID_POOL_CAP));
    }

    function test_validateFeeParams_lowPoolCapReturnsFalse() public view {
        assertFalse(registry.validateFeeParams(VALID_BASE_FEE, VALID_SPREAD_FEE, 0));
    }

    function test_validateOracleParams_validReturnsTrue() public view {
        assertTrue(registry.validateOracleParams(VALID_DECAY, VALID_MIN_OBS, VALID_ANN_FACTOR));
    }

    function test_validateOracleParams_decayTooLowReturnsFalse() public view {
        assertFalse(registry.validateOracleParams(799999999999999999, VALID_MIN_OBS, VALID_ANN_FACTOR));
    }

    function test_validateOracleParams_zeroMinObsReturnsFalse() public view {
        assertFalse(registry.validateOracleParams(VALID_DECAY, 0, VALID_ANN_FACTOR));
    }

    function test_validateOracleParams_nonPositiveAnnFactorReturnsFalse() public view {
        assertFalse(registry.validateOracleParams(VALID_DECAY, VALID_MIN_OBS, 0));
        assertFalse(registry.validateOracleParams(VALID_DECAY, VALID_MIN_OBS, -1));
    }

    // =========================================================================
    // Compute Expected Fee Rate Tests
    // =========================================================================

    function test_computeExpectedFeeRate_zeroUtilization() public view {
        int256 rate = registry.computeExpectedFeeRate(VALID_BASE_FEE, VALID_SPREAD_FEE, 0);
        assertEq(rate, VALID_BASE_FEE, "At zero utilization, fee rate should equal base fee");
    }

    function test_computeExpectedFeeRate_fullUtilization() public view {
        // At 100% utilization: feeRate = baseFee + spreadFee * 1^2 = baseFee + spreadFee
        int256 rate = registry.computeExpectedFeeRate(VALID_BASE_FEE, VALID_SPREAD_FEE, 1e18);
        assertEq(rate, VALID_BASE_FEE + VALID_SPREAD_FEE, "At full util, rate = base + spread");
    }

    function test_computeExpectedFeeRate_halfUtilization() public view {
        // At 50% utilization: feeRate = baseFee + spreadFee * 0.25
        int256 rate = registry.computeExpectedFeeRate(VALID_BASE_FEE, VALID_SPREAD_FEE, 5e17);
        int256 expected = VALID_BASE_FEE + (VALID_SPREAD_FEE * 25 / 100);
        assertEq(rate, expected, "At 50% util, rate = base + spread * 0.25");
    }

    function test_computeExpectedFeeRate_clampsNegativeUtilToZero() public view {
        int256 rate = registry.computeExpectedFeeRate(VALID_BASE_FEE, VALID_SPREAD_FEE, -1e18);
        assertEq(rate, VALID_BASE_FEE, "Negative util should clamp to 0, returning base fee only");
    }

    function test_computeExpectedFeeRate_clampsExcessiveUtilToOne() public view {
        int256 rate = registry.computeExpectedFeeRate(VALID_BASE_FEE, VALID_SPREAD_FEE, 2e18);
        int256 rateAtOne = registry.computeExpectedFeeRate(VALID_BASE_FEE, VALID_SPREAD_FEE, 1e18);
        assertEq(rate, rateAtOne, "Excessive util should clamp to 1.0");
    }

    // =========================================================================
    // Ownership Tests
    // =========================================================================

    function test_transferOwnership_success() public {
        registry.transferOwnership(alice);
        assertEq(registry.owner(), alice, "Owner should be alice");
    }

    function test_transferOwnership_revertZeroAddress() public {
        vm.expectRevert(DeploymentRegistry.DeploymentRegistry__ZeroAddress.selector);
        registry.transferOwnership(address(0));
    }

    function test_transferOwnership_revertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(DeploymentRegistry.DeploymentRegistry__Unauthorized.selector);
        registry.transferOwnership(bob);
    }

    function test_transferOwnership_newOwnerCanAct() public {
        registry.transferOwnership(alice);

        vm.prank(alice);
        DeploymentRegistry.ChainConfig memory config = _createValidChainConfig(421614, "Test");
        registry.configureChain(config);

        assertEq(registry.getConfiguredChainsCount(), 1, "Alice should be able to configure chains");
    }

    // =========================================================================
    // Constants Tests
    // =========================================================================

    function test_constants_chainIds() public view {
        assertEq(registry.ARBITRUM_SEPOLIA(), 421614);
        assertEq(registry.BSC_TESTNET(), 97);
        assertEq(registry.ETHEREUM_SEPOLIA(), 11155111);
    }

    function test_constants_feeBounds() public view {
        assertEq(registry.MAX_BASE_FEE(), 100000000000000000);
        assertEq(registry.MAX_SPREAD_FEE(), 500000000000000000);
        assertEq(registry.MIN_POOL_CAP(), 1e18);
    }

    function test_constants_oracleBounds() public view {
        assertEq(registry.MIN_DECAY_FACTOR(), 800000000000000000);
        assertEq(registry.MAX_DECAY_FACTOR(), 990000000000000000);
    }

    // =========================================================================
    // Edge Case Tests
    // =========================================================================

    function test_recordLibraries_arrayLengthMismatch() public {
        _configureChain(421614, "Test");

        address[] memory addrs = new address[](2);
        addrs[0] = address(0x10);
        addrs[1] = address(0x11);
        string[] memory names = new string[](1);
        names[0] = "Lib1";

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentRegistry.DeploymentRegistry__InvalidFeeParams.selector, "Array length mismatch"
            )
        );
        registry.recordLibraryDeployments(421614, addrs, names);
    }

    function test_getPhase_revertUnconfiguredChain() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.DeploymentRegistry__ChainNotConfigured.selector, 999));
        registry.getPhase(999);
    }

    function test_getManifest_revertUnconfiguredChain() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentRegistry.DeploymentRegistry__ChainNotConfigured.selector, 999));
        registry.getManifest(999);
    }

    function test_recordCoreDeployments_skippingPhaseReverts() public {
        _configureChain(421614, "Test");

        // Try to record core without recording libraries first (phase is PENDING, needs LIBRARIES_DEPLOYED)
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentRegistry.DeploymentRegistry__InvalidPhase.selector,
                DeploymentRegistry.DeployPhase.PENDING,
                DeploymentRegistry.DeployPhase.LIBRARIES_DEPLOYED
            )
        );
        registry.recordCoreDeployments(421614, mockVault, mockFeeController, mockLens, mockRouter);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createValidChainConfig(uint256 chainId, string memory name)
        internal
        view
        returns (DeploymentRegistry.ChainConfig memory)
    {
        return DeploymentRegistry.ChainConfig({
            chainId: chainId,
            chainName: name,
            feeRecipient: feeRecipient,
            defaultBaseFee: VALID_BASE_FEE,
            defaultSpreadFee: VALID_SPREAD_FEE,
            defaultPoolCap: VALID_POOL_CAP,
            oracleDecayFactor: VALID_DECAY,
            oracleMinObservations: VALID_MIN_OBS,
            oracleAnnualizationFactor: VALID_ANN_FACTOR,
            isConfigured: false
        });
    }

    function _configureChain(uint256 chainId, string memory name) internal {
        DeploymentRegistry.ChainConfig memory config = _createValidChainConfig(chainId, name);
        registry.configureChain(config);
    }

    function _deployLibraries(uint256 chainId) internal {
        address[] memory addrs = new address[](2);
        addrs[0] = address(0x10);
        addrs[1] = address(0x11);
        string[] memory names = new string[](2);
        names[0] = "CumulativeNormal";
        names[1] = "OptionMath";
        registry.recordLibraryDeployments(chainId, addrs, names);
    }

    function _advanceToSurfaceDeployed(uint256 chainId) internal {
        _deployLibraries(chainId);
        registry.recordCoreDeployments(chainId, mockVault, mockFeeController, mockLens, mockRouter);
        registry.recordOracleDeployment(chainId, mockOracle);
        registry.recordSurfaceDeployment(chainId);
    }
}
