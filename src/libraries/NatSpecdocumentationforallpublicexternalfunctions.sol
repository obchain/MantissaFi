// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";

/// @title NatSpecdocumentationforallpublicexternalfunctions
/// @notice On-chain documentation registry for tracking and validating NatSpec coverage of protocol contracts
/// @dev Provides utilities for hashing function signatures, computing documentation coverage metrics,
///      and maintaining an on-chain registry of documented interfaces. Uses SD59x18 for coverage ratios.
/// @author MantissaFi Team
library NatSpecdocumentationforallpublicexternalfunctions {
    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice 1.0 in SD59x18 fixed-point representation
    int256 private constant ONE = 1e18;

    /// @notice 100.0 in SD59x18 fixed-point representation (for percentage calculations)
    int256 private constant HUNDRED = 100e18;

    /// @notice Minimum acceptable documentation coverage ratio (80% = 0.8)
    /// @dev Below this threshold, a contract is considered insufficiently documented
    int256 private constant MIN_COVERAGE_THRESHOLD = 800000000000000000;

    /// @notice Maximum number of function selectors allowed in a single registry entry
    /// @dev Prevents unbounded gas consumption during batch operations
    uint256 private constant MAX_SELECTORS_PER_CONTRACT = 256;

    /// @notice Maximum byte length for a documentation hash
    uint256 private constant HASH_LENGTH = 32;

    /// @notice Weight for @notice tag in coverage scoring (30% = 0.3)
    int256 private constant NOTICE_WEIGHT = 300000000000000000;

    /// @notice Weight for @dev tag in coverage scoring (20% = 0.2)
    int256 private constant DEV_WEIGHT = 200000000000000000;

    /// @notice Weight for @param tags in coverage scoring (25% = 0.25)
    int256 private constant PARAM_WEIGHT = 250000000000000000;

    /// @notice Weight for @return tags in coverage scoring (15% = 0.15)
    int256 private constant RETURN_WEIGHT = 150000000000000000;

    /// @notice Weight for @custom:security tag in coverage scoring (10% = 0.1)
    int256 private constant SECURITY_WEIGHT = 100000000000000000;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when no function selectors are provided
    error NatSpec__EmptySelectors();

    /// @notice Thrown when the number of selectors exceeds the maximum allowed
    /// @param provided The number of selectors provided
    /// @param maximum The maximum number allowed
    error NatSpec__TooManySelectors(uint256 provided, uint256 maximum);

    /// @notice Thrown when documented count exceeds total function count
    /// @param documented Number of documented functions
    /// @param total Total number of functions
    error NatSpec__DocumentedExceedsTotal(uint256 documented, uint256 total);

    /// @notice Thrown when total function count is zero
    error NatSpec__ZeroTotalFunctions();

    /// @notice Thrown when an empty function signature is provided
    error NatSpec__EmptySignature();

    /// @notice Thrown when coverage is below the minimum threshold
    /// @param coverage The actual coverage ratio
    /// @param threshold The minimum required coverage ratio
    error NatSpec__InsufficientCoverage(int256 coverage, int256 threshold);

    /// @notice Thrown when tag weights do not sum to 1.0
    /// @param weightSum The actual sum of weights
    error NatSpec__InvalidWeightSum(int256 weightSum);

    /// @notice Thrown when a tag count exceeds the expected count
    /// @param tagCount The actual tag count
    /// @param expected The expected count
    error NatSpec__TagCountExceedsExpected(uint256 tagCount, uint256 expected);

    /// @notice Thrown when an invalid documentation hash is provided (zero hash)
    error NatSpec__InvalidDocHash();

    // ═══════════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Represents the NatSpec tag counts for a single function
    /// @param hasNotice Whether the function has a @notice tag
    /// @param hasDev Whether the function has a @dev tag
    /// @param paramCount Number of @param tags present
    /// @param expectedParamCount Total number of parameters the function expects
    /// @param returnCount Number of @return tags present
    /// @param expectedReturnCount Total number of return values the function expects
    /// @param hasSecurity Whether the function has a @custom:security tag
    struct FunctionDocTags {
        bool hasNotice;
        bool hasDev;
        uint8 paramCount;
        uint8 expectedParamCount;
        uint8 returnCount;
        uint8 expectedReturnCount;
        bool hasSecurity;
    }

    /// @notice Represents a contract's documentation metadata
    /// @param contractHash Keccak256 hash of the contract name
    /// @param selectorCount Number of public/external function selectors
    /// @param documentedCount Number of functions with complete NatSpec
    /// @param docHash Keccak256 hash of the full NatSpec documentation content
    struct ContractDoc {
        bytes32 contractHash;
        uint256 selectorCount;
        uint256 documentedCount;
        bytes32 docHash;
    }

    /// @notice Tag weight configuration for customized coverage scoring
    /// @param noticeWeight Weight for @notice tag (SD59x18)
    /// @param devWeight Weight for @dev tag (SD59x18)
    /// @param paramWeight Weight for @param tags (SD59x18)
    /// @param returnWeight Weight for @return tags (SD59x18)
    /// @param securityWeight Weight for @custom:security tag (SD59x18)
    struct TagWeights {
        SD59x18 noticeWeight;
        SD59x18 devWeight;
        SD59x18 paramWeight;
        SD59x18 returnWeight;
        SD59x18 securityWeight;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Computes the documentation coverage ratio for a contract
    /// @dev Coverage = documentedCount / totalFunctions, returned as SD59x18 in [0, 1]
    /// @param documentedCount Number of fully documented functions
    /// @param totalFunctions Total number of public/external functions
    /// @return coverage The coverage ratio as SD59x18 (e.g., 0.85e18 for 85%)
    function computeCoverageRatio(uint256 documentedCount, uint256 totalFunctions)
        internal
        pure
        returns (SD59x18 coverage)
    {
        if (totalFunctions == 0) revert NatSpec__ZeroTotalFunctions();
        if (documentedCount > totalFunctions) {
            revert NatSpec__DocumentedExceedsTotal(documentedCount, totalFunctions);
        }

        SD59x18 documented = sd(int256(documentedCount) * 1e18);
        SD59x18 total = sd(int256(totalFunctions) * 1e18);
        coverage = documented.div(total);
    }

    /// @notice Computes the coverage ratio as a percentage (0-100)
    /// @dev Multiplies the coverage ratio by 100 for display purposes
    /// @param documentedCount Number of fully documented functions
    /// @param totalFunctions Total number of public/external functions
    /// @return percentage The coverage percentage as SD59x18 (e.g., 85e18 for 85%)
    function computeCoveragePercentage(uint256 documentedCount, uint256 totalFunctions)
        internal
        pure
        returns (SD59x18 percentage)
    {
        SD59x18 ratio = computeCoverageRatio(documentedCount, totalFunctions);
        percentage = ratio.mul(sd(HUNDRED));
    }

    /// @notice Checks whether a contract meets the minimum coverage threshold
    /// @dev Compares the coverage ratio against MIN_COVERAGE_THRESHOLD (80%)
    /// @param documentedCount Number of fully documented functions
    /// @param totalFunctions Total number of public/external functions
    /// @return meetsThreshold True if coverage >= 80%
    function meetsMinimumCoverage(uint256 documentedCount, uint256 totalFunctions)
        internal
        pure
        returns (bool meetsThreshold)
    {
        SD59x18 coverage = computeCoverageRatio(documentedCount, totalFunctions);
        meetsThreshold = coverage.gte(sd(MIN_COVERAGE_THRESHOLD));
    }

    /// @notice Enforces the minimum coverage threshold, reverting if not met
    /// @dev Reverts with NatSpec__InsufficientCoverage if coverage < 80%
    /// @param documentedCount Number of fully documented functions
    /// @param totalFunctions Total number of public/external functions
    /// @custom:security Critical for deployment gates — ensures protocol documentation standards
    function enforceCoverage(uint256 documentedCount, uint256 totalFunctions) internal pure {
        SD59x18 coverage = computeCoverageRatio(documentedCount, totalFunctions);
        if (coverage.lt(sd(MIN_COVERAGE_THRESHOLD))) {
            revert NatSpec__InsufficientCoverage(SD59x18.unwrap(coverage), MIN_COVERAGE_THRESHOLD);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FUNCTION DOCUMENTATION SCORING
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Computes a weighted documentation quality score for a single function
    /// @dev Score is a weighted sum of tag completeness: notice (30%) + dev (20%) + param (25%) + return (15%) + security (10%)
    /// @param tags The NatSpec tag presence/count data for the function
    /// @return score The documentation quality score as SD59x18 in [0, 1]
    function computeFunctionDocScore(FunctionDocTags memory tags) internal pure returns (SD59x18 score) {
        SD59x18 total = ZERO;

        // @notice contribution (30%)
        if (tags.hasNotice) {
            total = total.add(sd(NOTICE_WEIGHT));
        }

        // @dev contribution (20%)
        if (tags.hasDev) {
            total = total.add(sd(DEV_WEIGHT));
        }

        // @param contribution (25%) — proportional to documented params
        if (tags.expectedParamCount > 0) {
            uint8 effective = tags.paramCount > tags.expectedParamCount ? tags.expectedParamCount : tags.paramCount;
            SD59x18 paramRatio =
                sd(int256(uint256(effective)) * 1e18).div(sd(int256(uint256(tags.expectedParamCount)) * 1e18));
            total = total.add(sd(PARAM_WEIGHT).mul(paramRatio));
        } else {
            // No params expected — full score for param tag
            total = total.add(sd(PARAM_WEIGHT));
        }

        // @return contribution (15%) — proportional to documented returns
        if (tags.expectedReturnCount > 0) {
            uint8 effective = tags.returnCount > tags.expectedReturnCount ? tags.expectedReturnCount : tags.returnCount;
            SD59x18 returnRatio =
                sd(int256(uint256(effective)) * 1e18).div(sd(int256(uint256(tags.expectedReturnCount)) * 1e18));
            total = total.add(sd(RETURN_WEIGHT).mul(returnRatio));
        } else {
            // No returns expected — full score for return tag
            total = total.add(sd(RETURN_WEIGHT));
        }

        // @custom:security contribution (10%)
        if (tags.hasSecurity) {
            total = total.add(sd(SECURITY_WEIGHT));
        }

        score = total;
    }

    /// @notice Computes a weighted documentation score using custom tag weights
    /// @dev Custom weights must sum to exactly 1.0 (1e18)
    /// @param tags The NatSpec tag presence/count data for the function
    /// @param weights Custom weights for each NatSpec tag category
    /// @return score The documentation quality score as SD59x18 in [0, 1]
    function computeFunctionDocScoreWeighted(FunctionDocTags memory tags, TagWeights memory weights)
        internal
        pure
        returns (SD59x18 score)
    {
        // Validate weights sum to 1.0
        SD59x18 weightSum = weights.noticeWeight.add(weights.devWeight).add(weights.paramWeight)
            .add(weights.returnWeight).add(weights.securityWeight);

        // Allow tiny rounding tolerance (1 wei)
        int256 diff = SD59x18.unwrap(weightSum) - ONE;
        if (diff > 1 || diff < -1) {
            revert NatSpec__InvalidWeightSum(SD59x18.unwrap(weightSum));
        }

        SD59x18 total = ZERO;

        if (tags.hasNotice) {
            total = total.add(weights.noticeWeight);
        }

        if (tags.hasDev) {
            total = total.add(weights.devWeight);
        }

        if (tags.expectedParamCount > 0) {
            uint8 effective = tags.paramCount > tags.expectedParamCount ? tags.expectedParamCount : tags.paramCount;
            SD59x18 paramRatio =
                sd(int256(uint256(effective)) * 1e18).div(sd(int256(uint256(tags.expectedParamCount)) * 1e18));
            total = total.add(weights.paramWeight.mul(paramRatio));
        } else {
            total = total.add(weights.paramWeight);
        }

        if (tags.expectedReturnCount > 0) {
            uint8 effective = tags.returnCount > tags.expectedReturnCount ? tags.expectedReturnCount : tags.returnCount;
            SD59x18 returnRatio =
                sd(int256(uint256(effective)) * 1e18).div(sd(int256(uint256(tags.expectedReturnCount)) * 1e18));
            total = total.add(weights.returnWeight.mul(returnRatio));
        } else {
            total = total.add(weights.returnWeight);
        }

        if (tags.hasSecurity) {
            total = total.add(weights.securityWeight);
        }

        score = total;
    }

    /// @notice Checks whether a function's documentation score meets a given threshold
    /// @dev Computes the score and compares it against the provided threshold
    /// @param tags The NatSpec tag data for the function
    /// @param threshold The minimum acceptable score as SD59x18
    /// @return passing True if the function's doc score >= threshold
    function functionMeetsThreshold(FunctionDocTags memory tags, SD59x18 threshold)
        internal
        pure
        returns (bool passing)
    {
        SD59x18 score = computeFunctionDocScore(tags);
        passing = score.gte(threshold);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // HASHING AND REGISTRY UTILITIES
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Computes the 4-byte function selector from a function signature string
    /// @dev Equivalent to bytes4(keccak256(bytes(signature)))
    /// @param signature The function signature (e.g., "transfer(address,uint256)")
    /// @return selector The 4-byte function selector
    function computeSelector(string memory signature) internal pure returns (bytes4 selector) {
        if (bytes(signature).length == 0) revert NatSpec__EmptySignature();
        selector = bytes4(keccak256(bytes(signature)));
    }

    /// @notice Computes the interface hash for a set of function selectors (EIP-165 style)
    /// @dev XORs all selectors together to produce a single interface identifier
    /// @param selectors Array of 4-byte function selectors
    /// @return interfaceId The XOR of all selectors
    function computeInterfaceId(bytes4[] memory selectors) internal pure returns (bytes4 interfaceId) {
        if (selectors.length == 0) revert NatSpec__EmptySelectors();
        if (selectors.length > MAX_SELECTORS_PER_CONTRACT) {
            revert NatSpec__TooManySelectors(selectors.length, MAX_SELECTORS_PER_CONTRACT);
        }

        interfaceId = selectors[0];
        for (uint256 i = 1; i < selectors.length; i++) {
            interfaceId ^= selectors[i];
        }
    }

    /// @notice Builds a documentation metadata struct from raw inputs
    /// @dev Creates a ContractDoc with computed hashes for registry storage
    /// @param contractName The name of the contract
    /// @param selectors Array of public/external function selectors
    /// @param documentedCount Number of fully documented functions
    /// @param docContent The full NatSpec documentation content to hash
    /// @return doc The assembled ContractDoc metadata
    function buildContractDoc(
        string memory contractName,
        bytes4[] memory selectors,
        uint256 documentedCount,
        bytes memory docContent
    ) internal pure returns (ContractDoc memory doc) {
        if (selectors.length == 0) revert NatSpec__EmptySelectors();
        if (selectors.length > MAX_SELECTORS_PER_CONTRACT) {
            revert NatSpec__TooManySelectors(selectors.length, MAX_SELECTORS_PER_CONTRACT);
        }
        if (documentedCount > selectors.length) {
            revert NatSpec__DocumentedExceedsTotal(documentedCount, selectors.length);
        }
        if (bytes(contractName).length == 0) revert NatSpec__EmptySignature();

        doc = ContractDoc({
            contractHash: keccak256(bytes(contractName)),
            selectorCount: selectors.length,
            documentedCount: documentedCount,
            docHash: keccak256(docContent)
        });
    }

    /// @notice Verifies that a documentation hash matches expected content
    /// @dev Compares the keccak256 of provided content against the stored hash
    /// @param docHash The expected documentation hash
    /// @param content The content to verify
    /// @return valid True if the hash of content matches docHash
    function verifyDocHash(bytes32 docHash, bytes memory content) internal pure returns (bool valid) {
        if (docHash == bytes32(0)) revert NatSpec__InvalidDocHash();
        valid = keccak256(content) == docHash;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // AGGREGATE ANALYSIS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Computes the average documentation score across multiple functions
    /// @dev Sums individual function doc scores and divides by count
    /// @param tagArray Array of FunctionDocTags for each function in a contract
    /// @return averageScore The mean documentation score as SD59x18 in [0, 1]
    function computeAverageDocScore(FunctionDocTags[] memory tagArray) internal pure returns (SD59x18 averageScore) {
        uint256 count = tagArray.length;
        if (count == 0) revert NatSpec__ZeroTotalFunctions();

        SD59x18 totalScore = ZERO;
        for (uint256 i = 0; i < count; i++) {
            totalScore = totalScore.add(computeFunctionDocScore(tagArray[i]));
        }

        averageScore = totalScore.div(sd(int256(count) * 1e18));
    }

    /// @notice Counts the number of fully documented functions from a tag array
    /// @dev A function is considered fully documented if its score is 1.0
    /// @param tagArray Array of FunctionDocTags for each function
    /// @return count The number of functions with perfect documentation score
    function countFullyDocumented(FunctionDocTags[] memory tagArray) internal pure returns (uint256 count) {
        SD59x18 perfectScore = sd(ONE);
        for (uint256 i = 0; i < tagArray.length; i++) {
            SD59x18 score = computeFunctionDocScore(tagArray[i]);
            if (score.gte(perfectScore)) {
                count++;
            }
        }
    }

    /// @notice Computes the documentation deficit — how many more functions need documentation
    /// @dev deficit = ceil(threshold * total) - documented, floored at 0
    /// @param documentedCount Number of currently documented functions
    /// @param totalFunctions Total number of public/external functions
    /// @param threshold The target coverage ratio as SD59x18 (e.g., 0.8e18 for 80%)
    /// @return deficit The number of additional functions that need documentation
    function computeDocDeficit(uint256 documentedCount, uint256 totalFunctions, SD59x18 threshold)
        internal
        pure
        returns (uint256 deficit)
    {
        if (totalFunctions == 0) revert NatSpec__ZeroTotalFunctions();
        if (documentedCount > totalFunctions) {
            revert NatSpec__DocumentedExceedsTotal(documentedCount, totalFunctions);
        }

        // Required = ceil(threshold * total)
        SD59x18 required = threshold.mul(sd(int256(totalFunctions) * 1e18));
        int256 requiredRaw = SD59x18.unwrap(required);

        // Ceiling division: (requiredRaw + 1e18 - 1) / 1e18
        uint256 requiredCount;
        if (requiredRaw <= 0) {
            requiredCount = 0;
        } else {
            requiredCount = uint256(requiredRaw + 999999999999999999) / 1e18;
        }

        if (requiredCount > documentedCount) {
            deficit = requiredCount - documentedCount;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANT ACCESSORS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Returns the minimum coverage threshold (80%)
    /// @return The minimum coverage threshold as SD59x18
    function getMinCoverageThreshold() internal pure returns (SD59x18) {
        return sd(MIN_COVERAGE_THRESHOLD);
    }

    /// @notice Returns the maximum number of selectors allowed per contract
    /// @return The maximum selector count
    function getMaxSelectorsPerContract() internal pure returns (uint256) {
        return MAX_SELECTORS_PER_CONTRACT;
    }

    /// @notice Returns the default tag weights used for documentation scoring
    /// @return weights The default TagWeights struct
    function getDefaultTagWeights() internal pure returns (TagWeights memory weights) {
        weights = TagWeights({
            noticeWeight: sd(NOTICE_WEIGHT),
            devWeight: sd(DEV_WEIGHT),
            paramWeight: sd(PARAM_WEIGHT),
            returnWeight: sd(RETURN_WEIGHT),
            securityWeight: sd(SECURITY_WEIGHT)
        });
    }
}
