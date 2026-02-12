// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    NatSpecdocumentationforallpublicexternalfunctions as NatSpec
} from "../../src/libraries/NatSpecdocumentationforallpublicexternalfunctions.sol";

/// @notice Wrapper contract to test library revert behavior via external calls
contract NatSpecWrapper {
    function computeCoverageRatio(uint256 documented, uint256 total) external pure returns (SD59x18) {
        return NatSpec.computeCoverageRatio(documented, total);
    }

    function computeCoveragePercentage(uint256 documented, uint256 total) external pure returns (SD59x18) {
        return NatSpec.computeCoveragePercentage(documented, total);
    }

    function meetsMinimumCoverage(uint256 documented, uint256 total) external pure returns (bool) {
        return NatSpec.meetsMinimumCoverage(documented, total);
    }

    function enforceCoverage(uint256 documented, uint256 total) external pure {
        NatSpec.enforceCoverage(documented, total);
    }

    function computeFunctionDocScore(NatSpec.FunctionDocTags memory tags) external pure returns (SD59x18) {
        return NatSpec.computeFunctionDocScore(tags);
    }

    function computeFunctionDocScoreWeighted(NatSpec.FunctionDocTags memory tags, NatSpec.TagWeights memory weights)
        external
        pure
        returns (SD59x18)
    {
        return NatSpec.computeFunctionDocScoreWeighted(tags, weights);
    }

    function functionMeetsThreshold(NatSpec.FunctionDocTags memory tags, SD59x18 threshold)
        external
        pure
        returns (bool)
    {
        return NatSpec.functionMeetsThreshold(tags, threshold);
    }

    function computeSelector(string memory signature) external pure returns (bytes4) {
        return NatSpec.computeSelector(signature);
    }

    function computeInterfaceId(bytes4[] memory selectors) external pure returns (bytes4) {
        return NatSpec.computeInterfaceId(selectors);
    }

    function buildContractDoc(
        string memory contractName,
        bytes4[] memory selectors,
        uint256 documentedCount,
        bytes memory docContent
    ) external pure returns (NatSpec.ContractDoc memory) {
        return NatSpec.buildContractDoc(contractName, selectors, documentedCount, docContent);
    }

    function verifyDocHash(bytes32 docHash, bytes memory content) external pure returns (bool) {
        return NatSpec.verifyDocHash(docHash, content);
    }

    function computeAverageDocScore(NatSpec.FunctionDocTags[] memory tagArray) external pure returns (SD59x18) {
        return NatSpec.computeAverageDocScore(tagArray);
    }

    function countFullyDocumented(NatSpec.FunctionDocTags[] memory tagArray) external pure returns (uint256) {
        return NatSpec.countFullyDocumented(tagArray);
    }

    function computeDocDeficit(uint256 documented, uint256 total, SD59x18 threshold) external pure returns (uint256) {
        return NatSpec.computeDocDeficit(documented, total, threshold);
    }

    function getMinCoverageThreshold() external pure returns (SD59x18) {
        return NatSpec.getMinCoverageThreshold();
    }

    function getMaxSelectorsPerContract() external pure returns (uint256) {
        return NatSpec.getMaxSelectorsPerContract();
    }

    function getDefaultTagWeights() external pure returns (NatSpec.TagWeights memory) {
        return NatSpec.getDefaultTagWeights();
    }
}

/// @title NatSpecdocumentationforallpublicexternalfunctionsTest
/// @notice Unit tests for the NatSpec documentation library
contract NatSpecdocumentationforallpublicexternalfunctionsTest is Test {
    NatSpecWrapper internal wrapper;

    function setUp() public {
        wrapper = new NatSpecWrapper();
    }

    // =========================================================================
    // Coverage Ratio Tests
    // =========================================================================

    function test_computeCoverageRatio_fullCoverage() public pure {
        SD59x18 ratio = NatSpec.computeCoverageRatio(10, 10);
        assertEq(SD59x18.unwrap(ratio), 1e18, "Full coverage should be 1.0");
    }

    function test_computeCoverageRatio_halfCoverage() public pure {
        SD59x18 ratio = NatSpec.computeCoverageRatio(5, 10);
        assertEq(SD59x18.unwrap(ratio), 5e17, "Half coverage should be 0.5");
    }

    function test_computeCoverageRatio_zeroCoverage() public pure {
        SD59x18 ratio = NatSpec.computeCoverageRatio(0, 10);
        assertEq(SD59x18.unwrap(ratio), 0, "Zero coverage should be 0.0");
    }

    function test_computeCoverageRatio_revertsOnZeroTotal() public {
        vm.expectRevert(NatSpec.NatSpec__ZeroTotalFunctions.selector);
        wrapper.computeCoverageRatio(0, 0);
    }

    function test_computeCoverageRatio_revertsWhenDocumentedExceedsTotal() public {
        vm.expectRevert(abi.encodeWithSelector(NatSpec.NatSpec__DocumentedExceedsTotal.selector, 11, 10));
        wrapper.computeCoverageRatio(11, 10);
    }

    // =========================================================================
    // Coverage Percentage Tests
    // =========================================================================

    function test_computeCoveragePercentage_full() public pure {
        SD59x18 pct = NatSpec.computeCoveragePercentage(10, 10);
        assertEq(SD59x18.unwrap(pct), 100e18, "Full coverage should be 100%");
    }

    function test_computeCoveragePercentage_partial() public pure {
        SD59x18 pct = NatSpec.computeCoveragePercentage(8, 10);
        assertEq(SD59x18.unwrap(pct), 80e18, "80% coverage should be 80");
    }

    // =========================================================================
    // Minimum Coverage Tests
    // =========================================================================

    function test_meetsMinimumCoverage_atThreshold() public pure {
        // 80% is exactly the threshold
        bool result = NatSpec.meetsMinimumCoverage(8, 10);
        assertTrue(result, "80% should meet the 80% threshold");
    }

    function test_meetsMinimumCoverage_aboveThreshold() public pure {
        bool result = NatSpec.meetsMinimumCoverage(9, 10);
        assertTrue(result, "90% should meet the 80% threshold");
    }

    function test_meetsMinimumCoverage_belowThreshold() public pure {
        bool result = NatSpec.meetsMinimumCoverage(7, 10);
        assertFalse(result, "70% should not meet the 80% threshold");
    }

    // =========================================================================
    // Enforce Coverage Tests
    // =========================================================================

    function test_enforceCoverage_passes() public pure {
        NatSpec.enforceCoverage(8, 10); // Should not revert
    }

    function test_enforceCoverage_reverts() public {
        vm.expectRevert();
        wrapper.enforceCoverage(7, 10);
    }

    // =========================================================================
    // Function Doc Score Tests
    // =========================================================================

    function test_computeFunctionDocScore_perfect() public pure {
        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: true,
            paramCount: 2,
            expectedParamCount: 2,
            returnCount: 1,
            expectedReturnCount: 1,
            hasSecurity: true
        });
        SD59x18 score = NatSpec.computeFunctionDocScore(tags);
        assertEq(SD59x18.unwrap(score), 1e18, "Perfect tags should give score of 1.0");
    }

    function test_computeFunctionDocScore_onlyNotice() public pure {
        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: false,
            paramCount: 0,
            expectedParamCount: 2,
            returnCount: 0,
            expectedReturnCount: 1,
            hasSecurity: false
        });
        SD59x18 score = NatSpec.computeFunctionDocScore(tags);
        // Only notice (0.3), params 0/2 (0), returns 0/1 (0) = 0.3
        assertEq(SD59x18.unwrap(score), 3e17, "Only notice should give 0.3");
    }

    function test_computeFunctionDocScore_noParams() public pure {
        // Function with no params or returns — notice + dev + security + full param + full return
        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: true,
            paramCount: 0,
            expectedParamCount: 0,
            returnCount: 0,
            expectedReturnCount: 0,
            hasSecurity: true
        });
        SD59x18 score = NatSpec.computeFunctionDocScore(tags);
        assertEq(SD59x18.unwrap(score), 1e18, "No-param function with all tags should score 1.0");
    }

    function test_computeFunctionDocScore_partialParams() public pure {
        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: true,
            paramCount: 1,
            expectedParamCount: 4,
            returnCount: 1,
            expectedReturnCount: 1,
            hasSecurity: true
        });
        SD59x18 score = NatSpec.computeFunctionDocScore(tags);
        // notice(0.3) + dev(0.2) + param(0.25 * 1/4 = 0.0625) + return(0.15) + security(0.1) = 0.8125
        assertApproxEqAbs(SD59x18.unwrap(score), 8125e14, 1, "Partial param score should be ~0.8125");
    }

    function test_computeFunctionDocScore_empty() public pure {
        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: false,
            hasDev: false,
            paramCount: 0,
            expectedParamCount: 3,
            returnCount: 0,
            expectedReturnCount: 2,
            hasSecurity: false
        });
        SD59x18 score = NatSpec.computeFunctionDocScore(tags);
        assertEq(SD59x18.unwrap(score), 0, "Empty tags should give 0 score");
    }

    // =========================================================================
    // Weighted Doc Score Tests
    // =========================================================================

    function test_computeFunctionDocScoreWeighted_equalWeights() public pure {
        NatSpec.TagWeights memory weights = NatSpec.TagWeights({
            noticeWeight: sd(2e17), // 0.2 each
            devWeight: sd(2e17),
            paramWeight: sd(2e17),
            returnWeight: sd(2e17),
            securityWeight: sd(2e17)
        });

        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: true,
            paramCount: 1,
            expectedParamCount: 1,
            returnCount: 1,
            expectedReturnCount: 1,
            hasSecurity: true
        });

        SD59x18 score = NatSpec.computeFunctionDocScoreWeighted(tags, weights);
        assertEq(SD59x18.unwrap(score), 1e18, "Perfect tags with equal weights should be 1.0");
    }

    function test_computeFunctionDocScoreWeighted_revertsOnBadWeights() public {
        NatSpec.TagWeights memory weights = NatSpec.TagWeights({
            noticeWeight: sd(5e17),
            devWeight: sd(5e17),
            paramWeight: sd(5e17),
            returnWeight: sd(5e17),
            securityWeight: sd(5e17)
        });

        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: true,
            paramCount: 0,
            expectedParamCount: 0,
            returnCount: 0,
            expectedReturnCount: 0,
            hasSecurity: true
        });

        vm.expectRevert();
        wrapper.computeFunctionDocScoreWeighted(tags, weights);
    }

    // =========================================================================
    // Function Meets Threshold Tests
    // =========================================================================

    function test_functionMeetsThreshold_passes() public pure {
        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: true,
            paramCount: 1,
            expectedParamCount: 1,
            returnCount: 1,
            expectedReturnCount: 1,
            hasSecurity: true
        });
        bool result = NatSpec.functionMeetsThreshold(tags, sd(8e17));
        assertTrue(result, "Perfect score should meet 0.8 threshold");
    }

    function test_functionMeetsThreshold_fails() public pure {
        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: false,
            paramCount: 0,
            expectedParamCount: 3,
            returnCount: 0,
            expectedReturnCount: 1,
            hasSecurity: false
        });
        bool result = NatSpec.functionMeetsThreshold(tags, sd(8e17));
        assertFalse(result, "Low score should not meet 0.8 threshold");
    }

    // =========================================================================
    // Selector and Hashing Tests
    // =========================================================================

    function test_computeSelector_transfer() public pure {
        bytes4 selector = NatSpec.computeSelector("transfer(address,uint256)");
        assertEq(selector, bytes4(keccak256("transfer(address,uint256)")), "Selector should match ERC20 transfer");
    }

    function test_computeSelector_revertsOnEmpty() public {
        vm.expectRevert(NatSpec.NatSpec__EmptySignature.selector);
        wrapper.computeSelector("");
    }

    function test_computeInterfaceId_single() public pure {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(0x12345678);
        bytes4 id = NatSpec.computeInterfaceId(selectors);
        assertEq(id, bytes4(0x12345678), "Single selector interface ID should be the selector itself");
    }

    function test_computeInterfaceId_multiple() public pure {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(0x12345678);
        selectors[1] = bytes4(0xabcdef00);
        bytes4 id = NatSpec.computeInterfaceId(selectors);
        assertEq(id, bytes4(0x12345678) ^ bytes4(0xabcdef00), "Interface ID should be XOR of selectors");
    }

    function test_computeInterfaceId_revertsOnEmpty() public {
        bytes4[] memory selectors = new bytes4[](0);
        vm.expectRevert(NatSpec.NatSpec__EmptySelectors.selector);
        wrapper.computeInterfaceId(selectors);
    }

    // =========================================================================
    // Build Contract Doc Tests
    // =========================================================================

    function test_buildContractDoc_valid() public pure {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = bytes4(0x11111111);
        selectors[1] = bytes4(0x22222222);
        selectors[2] = bytes4(0x33333333);
        bytes memory docContent = "NatSpec docs here";

        NatSpec.ContractDoc memory doc = NatSpec.buildContractDoc("MyContract", selectors, 2, docContent);
        assertEq(doc.contractHash, keccak256("MyContract"), "Contract hash should match");
        assertEq(doc.selectorCount, 3, "Selector count should be 3");
        assertEq(doc.documentedCount, 2, "Documented count should be 2");
        assertEq(doc.docHash, keccak256(docContent), "Doc hash should match content hash");
    }

    function test_buildContractDoc_revertsOnEmptyName() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(0x11111111);
        vm.expectRevert(NatSpec.NatSpec__EmptySignature.selector);
        wrapper.buildContractDoc("", selectors, 0, "docs");
    }

    // =========================================================================
    // Verify Doc Hash Tests
    // =========================================================================

    function test_verifyDocHash_valid() public pure {
        bytes memory content = "documentation content";
        bytes32 hash = keccak256(content);
        assertTrue(NatSpec.verifyDocHash(hash, content), "Valid content should verify");
    }

    function test_verifyDocHash_invalid() public pure {
        bytes memory content = "documentation content";
        bytes32 wrongHash = keccak256("wrong content");
        assertFalse(NatSpec.verifyDocHash(wrongHash, content), "Wrong content should not verify");
    }

    function test_verifyDocHash_revertsOnZeroHash() public {
        vm.expectRevert(NatSpec.NatSpec__InvalidDocHash.selector);
        wrapper.verifyDocHash(bytes32(0), "content");
    }

    // =========================================================================
    // Average Doc Score Tests
    // =========================================================================

    function test_computeAverageDocScore_allPerfect() public pure {
        NatSpec.FunctionDocTags[] memory tags = new NatSpec.FunctionDocTags[](3);
        for (uint256 i = 0; i < 3; i++) {
            tags[i] = NatSpec.FunctionDocTags({
                hasNotice: true,
                hasDev: true,
                paramCount: 1,
                expectedParamCount: 1,
                returnCount: 1,
                expectedReturnCount: 1,
                hasSecurity: true
            });
        }
        SD59x18 avg = NatSpec.computeAverageDocScore(tags);
        assertEq(SD59x18.unwrap(avg), 1e18, "Average of perfect scores should be 1.0");
    }

    function test_computeAverageDocScore_mixed() public pure {
        NatSpec.FunctionDocTags[] memory tags = new NatSpec.FunctionDocTags[](2);
        // Perfect score = 1.0
        tags[0] = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: true,
            paramCount: 0,
            expectedParamCount: 0,
            returnCount: 0,
            expectedReturnCount: 0,
            hasSecurity: true
        });
        // Zero score = 0.0
        tags[1] = NatSpec.FunctionDocTags({
            hasNotice: false,
            hasDev: false,
            paramCount: 0,
            expectedParamCount: 1,
            returnCount: 0,
            expectedReturnCount: 1,
            hasSecurity: false
        });
        SD59x18 avg = NatSpec.computeAverageDocScore(tags);
        assertEq(SD59x18.unwrap(avg), 5e17, "Average of 1.0 and 0.0 should be 0.5");
    }

    function test_computeAverageDocScore_revertsOnEmpty() public {
        NatSpec.FunctionDocTags[] memory tags = new NatSpec.FunctionDocTags[](0);
        vm.expectRevert(NatSpec.NatSpec__ZeroTotalFunctions.selector);
        wrapper.computeAverageDocScore(tags);
    }

    // =========================================================================
    // Count Fully Documented Tests
    // =========================================================================

    function test_countFullyDocumented_allPerfect() public pure {
        NatSpec.FunctionDocTags[] memory tags = new NatSpec.FunctionDocTags[](3);
        for (uint256 i = 0; i < 3; i++) {
            tags[i] = NatSpec.FunctionDocTags({
                hasNotice: true,
                hasDev: true,
                paramCount: 0,
                expectedParamCount: 0,
                returnCount: 0,
                expectedReturnCount: 0,
                hasSecurity: true
            });
        }
        uint256 count = NatSpec.countFullyDocumented(tags);
        assertEq(count, 3, "All 3 should be fully documented");
    }

    function test_countFullyDocumented_nonePerfect() public pure {
        NatSpec.FunctionDocTags[] memory tags = new NatSpec.FunctionDocTags[](2);
        tags[0] = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: false,
            paramCount: 0,
            expectedParamCount: 0,
            returnCount: 0,
            expectedReturnCount: 0,
            hasSecurity: false
        });
        tags[1] = NatSpec.FunctionDocTags({
            hasNotice: false,
            hasDev: true,
            paramCount: 0,
            expectedParamCount: 0,
            returnCount: 0,
            expectedReturnCount: 0,
            hasSecurity: false
        });
        uint256 count = NatSpec.countFullyDocumented(tags);
        assertEq(count, 0, "None should be fully documented");
    }

    // =========================================================================
    // Doc Deficit Tests
    // =========================================================================

    function test_computeDocDeficit_noDeficit() public pure {
        uint256 deficit = NatSpec.computeDocDeficit(10, 10, sd(8e17));
        assertEq(deficit, 0, "Full coverage has no deficit");
    }

    function test_computeDocDeficit_withDeficit() public pure {
        // Need ceil(0.8 * 10) = 8 documented, have 5 → deficit = 3
        uint256 deficit = NatSpec.computeDocDeficit(5, 10, sd(8e17));
        assertEq(deficit, 3, "Deficit should be 3");
    }

    function test_computeDocDeficit_exactThreshold() public pure {
        uint256 deficit = NatSpec.computeDocDeficit(8, 10, sd(8e17));
        assertEq(deficit, 0, "At threshold should have no deficit");
    }

    // =========================================================================
    // Constant Accessor Tests
    // =========================================================================

    function test_getMinCoverageThreshold() public pure {
        SD59x18 threshold = NatSpec.getMinCoverageThreshold();
        assertEq(SD59x18.unwrap(threshold), 8e17, "Min threshold should be 0.8");
    }

    function test_getMaxSelectorsPerContract() public pure {
        uint256 max = NatSpec.getMaxSelectorsPerContract();
        assertEq(max, 256, "Max selectors should be 256");
    }

    function test_getDefaultTagWeights_sumToOne() public pure {
        NatSpec.TagWeights memory weights = NatSpec.getDefaultTagWeights();
        int256 sum = SD59x18.unwrap(weights.noticeWeight) + SD59x18.unwrap(weights.devWeight)
            + SD59x18.unwrap(weights.paramWeight) + SD59x18.unwrap(weights.returnWeight)
            + SD59x18.unwrap(weights.securityWeight);
        assertEq(sum, 1e18, "Default weights should sum to 1.0");
    }
}
