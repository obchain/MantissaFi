// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { DeploymentRegistry } from "../../src/libraries/deploymentscriptsscriptDeployssol.sol";

/// @title deploymentscriptsscriptDeployssolFuzzTest
/// @notice Fuzz tests for DeploymentRegistry invariants
contract deploymentscriptsscriptDeployssolFuzzTest is Test {
    DeploymentRegistry public registry;

    address public feeRecipient = address(0xFEE);

    // Valid parameter bounds
    int256 public constant VALID_BASE_FEE = 3000000000000000;
    int256 public constant VALID_SPREAD_FEE = 50000000000000000;
    uint256 public constant VALID_POOL_CAP = 1000000e18;
    int256 public constant VALID_DECAY = 940000000000000000;
    uint256 public constant VALID_MIN_OBS = 10;
    int256 public constant VALID_ANN_FACTOR = 19104973174542800000;

    function setUp() public {
        registry = new DeploymentRegistry();
    }

    // =========================================================================
    // Fee Parameter Validation Fuzz Tests
    // =========================================================================

    /// @notice Invariant: validateFeeParams returns true iff all params are within bounds
    function testFuzz_validateFeeParams_consistency(int256 baseFee, int256 spreadFee, uint256 poolCap) public view {
        bool result = registry.validateFeeParams(baseFee, spreadFee, poolCap);

        bool expected = baseFee >= 0 && baseFee <= int256(registry.MAX_BASE_FEE()) && spreadFee >= 0
            && spreadFee <= int256(registry.MAX_SPREAD_FEE()) && poolCap >= registry.MIN_POOL_CAP();

        assertEq(result, expected, "validateFeeParams result mismatch");
    }

    /// @notice Invariant: valid fee params never revert configureChain
    function testFuzz_configureChain_validParams(uint256 chainId, int256 baseFee, int256 spreadFee, uint256 poolCap)
        public
    {
        // Bound to valid ranges
        baseFee = bound(baseFee, 0, int256(registry.MAX_BASE_FEE()));
        spreadFee = bound(spreadFee, 0, int256(registry.MAX_SPREAD_FEE()));
        poolCap = bound(poolCap, registry.MIN_POOL_CAP(), type(uint128).max);
        // Avoid chain ID 0 collisions
        chainId = bound(chainId, 1, type(uint128).max);

        DeploymentRegistry.ChainConfig memory config = DeploymentRegistry.ChainConfig({
            chainId: chainId,
            chainName: "FuzzChain",
            feeRecipient: feeRecipient,
            defaultBaseFee: baseFee,
            defaultSpreadFee: spreadFee,
            defaultPoolCap: poolCap,
            oracleDecayFactor: VALID_DECAY,
            oracleMinObservations: VALID_MIN_OBS,
            oracleAnnualizationFactor: VALID_ANN_FACTOR,
            isConfigured: false
        });

        registry.configureChain(config);

        DeploymentRegistry.ChainConfig memory stored = registry.getChainConfig(chainId);
        assertEq(stored.defaultBaseFee, baseFee, "Base fee not stored correctly");
        assertEq(stored.defaultSpreadFee, spreadFee, "Spread fee not stored correctly");
        assertEq(stored.defaultPoolCap, poolCap, "Pool cap not stored correctly");
        assertTrue(stored.isConfigured, "Chain should be configured");
    }

    // =========================================================================
    // Oracle Parameter Validation Fuzz Tests
    // =========================================================================

    /// @notice Invariant: validateOracleParams returns true iff all params are within bounds
    function testFuzz_validateOracleParams_consistency(int256 decayFactor, uint256 minObs, int256 annFactor)
        public
        view
    {
        bool result = registry.validateOracleParams(decayFactor, minObs, annFactor);

        bool expected = decayFactor >= int256(registry.MIN_DECAY_FACTOR())
            && decayFactor <= int256(registry.MAX_DECAY_FACTOR()) && minObs > 0 && annFactor > 0;

        assertEq(result, expected, "validateOracleParams result mismatch");
    }

    // =========================================================================
    // Compute Expected Fee Rate Fuzz Tests
    // =========================================================================

    /// @notice Invariant: fee rate is always >= base fee for non-negative spread and utilization
    function testFuzz_computeFeeRate_alwaysGteBaseFee(int256 baseFee, int256 spreadFee, int256 utilization)
        public
        view
    {
        // Only test with non-negative fees (protocol constraint)
        baseFee = bound(baseFee, 0, int256(registry.MAX_BASE_FEE()));
        spreadFee = bound(spreadFee, 0, int256(registry.MAX_SPREAD_FEE()));
        utilization = bound(utilization, 0, 1e18);

        int256 rate = registry.computeExpectedFeeRate(baseFee, spreadFee, utilization);

        assertGe(rate, baseFee, "Fee rate should always be >= base fee");
    }

    /// @notice Invariant: fee rate is monotonically non-decreasing with utilization
    function testFuzz_computeFeeRate_monotonicWithUtilization(
        int256 baseFee,
        int256 spreadFee,
        int256 util1,
        int256 util2
    ) public view {
        baseFee = bound(baseFee, 0, int256(registry.MAX_BASE_FEE()));
        spreadFee = bound(spreadFee, 0, int256(registry.MAX_SPREAD_FEE()));
        util1 = bound(util1, 0, 1e18);
        util2 = bound(util2, util1, 1e18);

        int256 rate1 = registry.computeExpectedFeeRate(baseFee, spreadFee, util1);
        int256 rate2 = registry.computeExpectedFeeRate(baseFee, spreadFee, util2);

        assertGe(rate2, rate1, "Fee rate should be monotonically non-decreasing with utilization");
    }

    /// @notice Invariant: fee rate at 0 utilization equals base fee
    function testFuzz_computeFeeRate_zeroUtilEqualsBase(int256 baseFee, int256 spreadFee) public view {
        baseFee = bound(baseFee, 0, int256(registry.MAX_BASE_FEE()));
        spreadFee = bound(spreadFee, 0, int256(registry.MAX_SPREAD_FEE()));

        int256 rate = registry.computeExpectedFeeRate(baseFee, spreadFee, 0);

        assertEq(rate, baseFee, "Rate at zero utilization must equal base fee");
    }

    /// @notice Invariant: fee rate at 100% utilization equals baseFee + spreadFee
    function testFuzz_computeFeeRate_fullUtilEqualsSum(int256 baseFee, int256 spreadFee) public view {
        baseFee = bound(baseFee, 0, int256(registry.MAX_BASE_FEE()));
        spreadFee = bound(spreadFee, 0, int256(registry.MAX_SPREAD_FEE()));

        int256 rate = registry.computeExpectedFeeRate(baseFee, spreadFee, 1e18);

        assertEq(rate, baseFee + spreadFee, "Rate at full utilization must equal baseFee + spreadFee");
    }

    /// @notice Invariant: negative utilization gets clamped to zero
    function testFuzz_computeFeeRate_negativeUtilClamped(int256 baseFee, int256 spreadFee, int256 negUtil) public view {
        baseFee = bound(baseFee, 0, int256(registry.MAX_BASE_FEE()));
        spreadFee = bound(spreadFee, 0, int256(registry.MAX_SPREAD_FEE()));
        negUtil = bound(negUtil, type(int256).min / 2, -1); // Avoid overflow in sd()

        int256 rate = registry.computeExpectedFeeRate(baseFee, spreadFee, negUtil);
        int256 rateAtZero = registry.computeExpectedFeeRate(baseFee, spreadFee, 0);

        assertEq(rate, rateAtZero, "Negative utilization should produce same rate as zero");
    }

    // =========================================================================
    // Deployment Sequencing Fuzz Tests
    // =========================================================================

    /// @notice Invariant: totalDeployments increments exactly by the number of contracts recorded
    function testFuzz_totalDeployments_incrementsByCount(uint8 libCount) public {
        libCount = uint8(bound(libCount, 1, 10));

        _configureChain(421614);

        address[] memory addrs = new address[](libCount);
        string[] memory names = new string[](libCount);
        for (uint256 i; i < libCount; ++i) {
            addrs[i] = address(uint160(0x10 + i));
            names[i] = string(abi.encodePacked("Lib", vm.toString(i)));
        }

        uint256 before = registry.totalDeployments();
        registry.recordLibraryDeployments(421614, addrs, names);

        assertEq(registry.totalDeployments(), before + libCount, "totalDeployments should increment by libCount");
    }

    /// @notice Invariant: phase can only advance forward, never backward
    function testFuzz_phaseAdvances_onlyForward(uint8 targetPhase) public {
        targetPhase = uint8(bound(targetPhase, 0, 6));

        _configureChain(421614);

        // Advance through phases one by one and verify monotonic increase
        uint256 prevPhase = uint256(registry.getPhase(421614));

        if (targetPhase >= 1) {
            _deployLibraries(421614);
            uint256 curPhase = uint256(registry.getPhase(421614));
            assertGt(curPhase, prevPhase, "Phase should advance");
            prevPhase = curPhase;
        }
        if (targetPhase >= 2) {
            registry.recordCoreDeployments(421614, address(0x100), address(0x101), address(0x102), address(0x103));
            uint256 curPhase = uint256(registry.getPhase(421614));
            assertGt(curPhase, prevPhase, "Phase should advance");
            prevPhase = curPhase;
        }
        if (targetPhase >= 3) {
            registry.recordOracleDeployment(421614, address(0x104));
            uint256 curPhase = uint256(registry.getPhase(421614));
            assertGt(curPhase, prevPhase, "Phase should advance");
            prevPhase = curPhase;
        }
        if (targetPhase >= 4) {
            registry.recordSurfaceDeployment(421614);
            uint256 curPhase = uint256(registry.getPhase(421614));
            assertGt(curPhase, prevPhase, "Phase should advance");
            prevPhase = curPhase;
        }
        if (targetPhase >= 5) {
            registry.recordConfiguration(421614, "config");
            uint256 curPhase = uint256(registry.getPhase(421614));
            assertGt(curPhase, prevPhase, "Phase should advance");
            prevPhase = curPhase;
        }
        if (targetPhase >= 6) {
            registry.markAllVerified(421614);
            uint256 curPhase = uint256(registry.getPhase(421614));
            assertGt(curPhase, prevPhase, "Phase should advance");
        }
    }

    /// @notice Invariant: configuredChains count matches number of configured chains
    function testFuzz_configuredChainsCount_matchesArray(uint8 chainCount) public {
        chainCount = uint8(bound(chainCount, 1, 20));

        for (uint256 i; i < chainCount; ++i) {
            uint256 chainId = 1000 + i;
            _configureChain(chainId);
        }

        assertEq(registry.getConfiguredChainsCount(), chainCount, "Configured chains count should match");

        uint256[] memory chains = registry.getConfiguredChains();
        assertEq(chains.length, chainCount, "Chains array length should match");
    }

    // =========================================================================
    // Ownership Fuzz Tests
    // =========================================================================

    /// @notice Invariant: non-owners cannot call owner-restricted functions
    function testFuzz_onlyOwner_rejectsNonOwners(address caller) public {
        vm.assume(caller != address(this));
        vm.assume(caller != address(0));

        DeploymentRegistry.ChainConfig memory config = DeploymentRegistry.ChainConfig({
            chainId: 421614,
            chainName: "Test",
            feeRecipient: feeRecipient,
            defaultBaseFee: VALID_BASE_FEE,
            defaultSpreadFee: VALID_SPREAD_FEE,
            defaultPoolCap: VALID_POOL_CAP,
            oracleDecayFactor: VALID_DECAY,
            oracleMinObservations: VALID_MIN_OBS,
            oracleAnnualizationFactor: VALID_ANN_FACTOR,
            isConfigured: false
        });

        vm.prank(caller);
        vm.expectRevert(DeploymentRegistry.DeploymentRegistry__Unauthorized.selector);
        registry.configureChain(config);
    }

    /// @notice Invariant: after transferOwnership, old owner loses access and new owner gains it
    function testFuzz_transferOwnership_correctAccess(address newOwner) public {
        vm.assume(newOwner != address(0));
        vm.assume(newOwner != address(this));

        registry.transferOwnership(newOwner);

        assertEq(registry.owner(), newOwner, "Owner should be new owner");

        // Old owner should fail
        vm.expectRevert(DeploymentRegistry.DeploymentRegistry__Unauthorized.selector);
        registry.configureDefaultTestnets(feeRecipient);

        // New owner should succeed
        vm.prank(newOwner);
        registry.configureDefaultTestnets(feeRecipient);
        assertEq(registry.getConfiguredChainsCount(), 3);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _configureChain(uint256 chainId) internal {
        DeploymentRegistry.ChainConfig memory config = DeploymentRegistry.ChainConfig({
            chainId: chainId,
            chainName: "FuzzChain",
            feeRecipient: feeRecipient,
            defaultBaseFee: VALID_BASE_FEE,
            defaultSpreadFee: VALID_SPREAD_FEE,
            defaultPoolCap: VALID_POOL_CAP,
            oracleDecayFactor: VALID_DECAY,
            oracleMinObservations: VALID_MIN_OBS,
            oracleAnnualizationFactor: VALID_ANN_FACTOR,
            isConfigured: false
        });
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
}
