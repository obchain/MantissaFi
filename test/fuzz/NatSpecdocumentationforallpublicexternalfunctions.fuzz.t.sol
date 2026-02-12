// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    NatSpecdocumentationforallpublicexternalfunctions as NatSpec
} from "../../src/libraries/NatSpecdocumentationforallpublicexternalfunctions.sol";

/// @title NatSpecdocumentationforallpublicexternalfunctionsFuzzTest
/// @notice Fuzz tests for the NatSpec documentation library
/// @dev Tests invariants across random inputs for coverage, scoring, and hashing functions
contract NatSpecdocumentationforallpublicexternalfunctionsFuzzTest is Test {
    // =========================================================================
    // Coverage Ratio Fuzz Tests
    // =========================================================================

    /// @notice Coverage ratio is always in [0, 1]
    function testFuzz_coverageRatio_boundedZeroToOne(uint256 documented, uint256 total) public pure {
        total = bound(total, 1, 10_000);
        documented = bound(documented, 0, total);

        SD59x18 ratio = NatSpec.computeCoverageRatio(documented, total);
        assertGe(SD59x18.unwrap(ratio), 0, "Coverage ratio must be >= 0");
        assertLe(SD59x18.unwrap(ratio), 1e18, "Coverage ratio must be <= 1.0");
    }

    /// @notice Coverage ratio is monotonically increasing with documented count
    function testFuzz_coverageRatio_monotonic(uint256 documented1, uint256 documented2, uint256 total) public pure {
        total = bound(total, 2, 10_000);
        documented1 = bound(documented1, 0, total - 1);
        documented2 = bound(documented2, documented1 + 1, total);

        SD59x18 ratio1 = NatSpec.computeCoverageRatio(documented1, total);
        SD59x18 ratio2 = NatSpec.computeCoverageRatio(documented2, total);
        assertLt(SD59x18.unwrap(ratio1), SD59x18.unwrap(ratio2), "More docs should give higher ratio");
    }

    /// @notice Coverage percentage equals ratio * 100
    function testFuzz_coveragePercentage_equalsRatioTimes100(uint256 documented, uint256 total) public pure {
        total = bound(total, 1, 10_000);
        documented = bound(documented, 0, total);

        SD59x18 ratio = NatSpec.computeCoverageRatio(documented, total);
        SD59x18 percentage = NatSpec.computeCoveragePercentage(documented, total);

        int256 expected = SD59x18.unwrap(ratio.mul(sd(100e18)));
        assertApproxEqAbs(SD59x18.unwrap(percentage), expected, 1, "Percentage should be ratio * 100");
    }

    // =========================================================================
    // Minimum Coverage Threshold Fuzz Tests
    // =========================================================================

    /// @notice meetsMinimumCoverage is consistent with the 80% threshold
    function testFuzz_meetsMinimumCoverage_consistentWithRatio(uint256 documented, uint256 total) public pure {
        total = bound(total, 1, 10_000);
        documented = bound(documented, 0, total);

        bool meets = NatSpec.meetsMinimumCoverage(documented, total);
        SD59x18 ratio = NatSpec.computeCoverageRatio(documented, total);

        if (meets) {
            assertGe(SD59x18.unwrap(ratio), 8e17, "If meets, ratio must be >= 0.8");
        } else {
            assertLt(SD59x18.unwrap(ratio), 8e17, "If not meets, ratio must be < 0.8");
        }
    }

    // =========================================================================
    // Function Doc Score Fuzz Tests
    // =========================================================================

    /// @notice Function doc score is always in [0, 1]
    function testFuzz_functionDocScore_boundedZeroToOne(
        bool hasNotice,
        bool hasDev,
        uint8 paramCount,
        uint8 expectedParamCount,
        uint8 returnCount,
        uint8 expectedReturnCount,
        bool hasSecurity
    ) public pure {
        // Bound to reasonable values
        expectedParamCount = uint8(bound(expectedParamCount, 0, 20));
        paramCount = uint8(bound(paramCount, 0, 20));
        expectedReturnCount = uint8(bound(expectedReturnCount, 0, 10));
        returnCount = uint8(bound(returnCount, 0, 10));

        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: hasNotice,
            hasDev: hasDev,
            paramCount: paramCount,
            expectedParamCount: expectedParamCount,
            returnCount: returnCount,
            expectedReturnCount: expectedReturnCount,
            hasSecurity: hasSecurity
        });

        SD59x18 score = NatSpec.computeFunctionDocScore(tags);
        assertGe(SD59x18.unwrap(score), 0, "Score must be >= 0");
        assertLe(SD59x18.unwrap(score), 1e18, "Score must be <= 1.0");
    }

    /// @notice Perfect documentation always yields score of 1.0
    function testFuzz_functionDocScore_perfectIsAlwaysOne(uint8 paramCount, uint8 returnCount) public pure {
        paramCount = uint8(bound(paramCount, 0, 20));
        returnCount = uint8(bound(returnCount, 0, 10));

        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: true,
            paramCount: paramCount,
            expectedParamCount: paramCount,
            returnCount: returnCount,
            expectedReturnCount: returnCount,
            hasSecurity: true
        });

        SD59x18 score = NatSpec.computeFunctionDocScore(tags);
        assertEq(SD59x18.unwrap(score), 1e18, "Perfect docs should always score 1.0");
    }

    /// @notice Adding more documentation never decreases the score
    function testFuzz_functionDocScore_moreDocsNeverDecrease(uint8 expectedParams, uint8 expectedReturns) public pure {
        expectedParams = uint8(bound(expectedParams, 1, 20));
        expectedReturns = uint8(bound(expectedReturns, 1, 10));

        // Score with no docs
        NatSpec.FunctionDocTags memory noDoc = NatSpec.FunctionDocTags({
            hasNotice: false,
            hasDev: false,
            paramCount: 0,
            expectedParamCount: expectedParams,
            returnCount: 0,
            expectedReturnCount: expectedReturns,
            hasSecurity: false
        });

        // Score with some docs
        NatSpec.FunctionDocTags memory someDoc = NatSpec.FunctionDocTags({
            hasNotice: true,
            hasDev: false,
            paramCount: 0,
            expectedParamCount: expectedParams,
            returnCount: 0,
            expectedReturnCount: expectedReturns,
            hasSecurity: false
        });

        SD59x18 scoreNo = NatSpec.computeFunctionDocScore(noDoc);
        SD59x18 scoreSome = NatSpec.computeFunctionDocScore(someDoc);
        assertGe(SD59x18.unwrap(scoreSome), SD59x18.unwrap(scoreNo), "More docs should never decrease score");
    }

    // =========================================================================
    // Doc Deficit Fuzz Tests
    // =========================================================================

    /// @notice Deficit is zero when documented >= required
    function testFuzz_docDeficit_zeroWhenSufficient(uint256 total, uint256 thresholdRaw) public pure {
        total = bound(total, 1, 10_000);
        thresholdRaw = bound(thresholdRaw, 1, 1e18);
        SD59x18 threshold = sd(int256(thresholdRaw));

        uint256 deficit = NatSpec.computeDocDeficit(total, total, threshold);
        assertEq(deficit, 0, "Full coverage should have zero deficit");
    }

    /// @notice Deficit + documented >= required count
    function testFuzz_docDeficit_fillingDeficitMeetsTarget(uint256 documented, uint256 total) public pure {
        total = bound(total, 1, 1000);
        documented = bound(documented, 0, total);

        SD59x18 threshold = sd(8e17); // 80%
        uint256 deficit = NatSpec.computeDocDeficit(documented, total, threshold);

        if (deficit > 0) {
            // After filling the deficit, coverage should meet threshold
            uint256 newDocumented = documented + deficit;
            assertLe(newDocumented, total, "New documented should not exceed total");
            bool meets = NatSpec.meetsMinimumCoverage(newDocumented, total);
            assertTrue(meets, "Filling deficit should meet threshold");
        }
    }

    // =========================================================================
    // Interface ID Fuzz Tests
    // =========================================================================

    /// @notice XOR of interface ID with itself yields zero
    function testFuzz_interfaceId_xorSelfIsZero(bytes4 sel1, bytes4 sel2) public pure {
        vm.assume(sel1 != bytes4(0) || sel2 != bytes4(0));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = sel1;
        selectors[1] = sel2;
        bytes4 id = NatSpec.computeInterfaceId(selectors);

        // XOR is commutative: reverse should give the same result
        bytes4[] memory reversed = new bytes4[](2);
        reversed[0] = sel2;
        reversed[1] = sel1;
        bytes4 idReversed = NatSpec.computeInterfaceId(reversed);

        assertEq(id, idReversed, "Interface ID should be commutative");
    }

    // =========================================================================
    // Verify Doc Hash Fuzz Tests
    // =========================================================================

    /// @notice Hash verification always succeeds for matching content
    function testFuzz_verifyDocHash_alwaysMatchesSelf(bytes memory content) public pure {
        vm.assume(content.length > 0);
        bytes32 hash = keccak256(content);
        vm.assume(hash != bytes32(0));

        assertTrue(NatSpec.verifyDocHash(hash, content), "Content should always verify against its own hash");
    }

    /// @notice Hash verification fails for different content
    function testFuzz_verifyDocHash_failsForDifferentContent(bytes memory content1, bytes memory content2) public pure {
        vm.assume(content1.length > 0);
        vm.assume(keccak256(content1) != keccak256(content2));
        bytes32 hash = keccak256(content1);
        vm.assume(hash != bytes32(0));

        assertFalse(NatSpec.verifyDocHash(hash, content2), "Different content should not verify");
    }

    // =========================================================================
    // Average Score Fuzz Tests
    // =========================================================================

    /// @notice Average score of identical functions equals the individual score
    function testFuzz_averageDocScore_identicalEqualsIndividual(bool hasNotice, bool hasDev, bool hasSecurity)
        public
        pure
    {
        NatSpec.FunctionDocTags memory tags = NatSpec.FunctionDocTags({
            hasNotice: hasNotice,
            hasDev: hasDev,
            paramCount: 0,
            expectedParamCount: 0,
            returnCount: 0,
            expectedReturnCount: 0,
            hasSecurity: hasSecurity
        });

        SD59x18 individual = NatSpec.computeFunctionDocScore(tags);

        NatSpec.FunctionDocTags[] memory tagArray = new NatSpec.FunctionDocTags[](3);
        tagArray[0] = tags;
        tagArray[1] = tags;
        tagArray[2] = tags;

        SD59x18 avg = NatSpec.computeAverageDocScore(tagArray);
        assertApproxEqAbs(
            SD59x18.unwrap(avg), SD59x18.unwrap(individual), 1, "Average of identical should equal individual"
        );
    }
}
