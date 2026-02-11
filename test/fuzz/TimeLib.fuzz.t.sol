// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd } from "@prb/math/SD59x18.sol";
import { TimeLib } from "../../src/libraries/TimeLib.sol";

/// @title TimeLibFuzzWrapper
/// @notice Wrapper contract to expose internal library functions for fuzz testing
contract TimeLibFuzzWrapper {
    function toYears(uint64 expiry) external view returns (SD59x18) {
        return TimeLib.toYears(expiry);
    }

    function toYearsFromDuration(uint256 seconds_) external pure returns (SD59x18) {
        return TimeLib.toYearsFromDuration(seconds_);
    }

    function isExpired(uint64 expiry) external view returns (bool) {
        return TimeLib.isExpired(expiry);
    }

    function timeToExpiry(uint64 expiry) external view returns (uint256) {
        return TimeLib.timeToExpiry(expiry);
    }
}

/// @title TimeLibFuzzTest
/// @notice Fuzz tests verifying mathematical invariants for TimeLib
contract TimeLibFuzzTest is Test {
    TimeLibFuzzWrapper public wrapper;

    /// @notice Seconds in a year (365.25 days)
    uint256 private constant SECONDS_PER_YEAR = 31_557_600;

    /// @notice Base timestamp for tests (year 2024)
    uint256 private constant BASE_TIMESTAMP = 1704067200;

    /// @notice Maximum reasonable expiry (100 years from now)
    uint256 private constant MAX_EXPIRY_OFFSET = 100 * SECONDS_PER_YEAR;

    /// @notice Tolerance for floating point comparisons (1e-8)
    int256 private constant TOLERANCE = 1e10;

    function setUp() public {
        wrapper = new TimeLibFuzzWrapper();
        vm.warp(BASE_TIMESTAMP);
    }

    // ============ toYearsFromDuration fuzz tests ============

    /// @notice toYearsFromDuration should always return a non-negative value
    function testFuzz_toYearsFromDuration_nonNegative(uint256 seconds_) public view {
        // Bound to prevent overflow in internal calculations
        seconds_ = bound(seconds_, 0, MAX_EXPIRY_OFFSET);

        SD59x18 result = wrapper.toYearsFromDuration(seconds_);
        assertTrue(result.gte(sd(0)), "Result should always be non-negative");
    }

    /// @notice toYearsFromDuration should be monotonically increasing
    function testFuzz_toYearsFromDuration_monotonic(uint256 a, uint256 b) public view {
        a = bound(a, 0, MAX_EXPIRY_OFFSET / 2);
        b = bound(b, a, MAX_EXPIRY_OFFSET);

        SD59x18 resultA = wrapper.toYearsFromDuration(a);
        SD59x18 resultB = wrapper.toYearsFromDuration(b);

        assertTrue(resultB.gte(resultA), "Longer duration should yield >= years");
    }

    /// @notice toYearsFromDuration(0) should always return 0
    function testFuzz_toYearsFromDuration_zeroIdentity() public view {
        SD59x18 result = wrapper.toYearsFromDuration(0);
        assertEq(result.unwrap(), 0, "Zero seconds should always yield zero years");
    }

    /// @notice toYearsFromDuration should be approximately linear
    function testFuzz_toYearsFromDuration_linearity(uint256 base, uint256 multiplier) public view {
        base = bound(base, 1, SECONDS_PER_YEAR);
        multiplier = bound(multiplier, 1, 10);

        SD59x18 baseResult = wrapper.toYearsFromDuration(base);
        SD59x18 scaledResult = wrapper.toYearsFromDuration(base * multiplier);

        // scaledResult should be approximately multiplier * baseResult
        SD59x18 expected = baseResult.mul(sd(int256(multiplier) * 1e18));
        int256 diff = scaledResult.unwrap() - expected.unwrap();
        if (diff < 0) diff = -diff;

        assertTrue(diff <= TOLERANCE, "Should be approximately linear");
    }

    /// @notice One year in seconds should convert to approximately 1.0
    function testFuzz_toYearsFromDuration_oneYear(uint256 deviation) public view {
        // Test with slight deviations around one year
        deviation = bound(deviation, 0, 86400); // +/- 1 day

        SD59x18 result = wrapper.toYearsFromDuration(SECONDS_PER_YEAR + deviation);

        // Should be approximately 1.0 (within a few days tolerance)
        assertTrue(result.gt(sd(0.99e18)), "Should be > 0.99 years");
        assertTrue(result.lt(sd(1.01e18)), "Should be < 1.01 years");
    }

    // ============ toYears fuzz tests ============

    /// @notice toYears should always return positive for future expiries
    function testFuzz_toYears_positiveForFuture(uint256 offset) public view {
        offset = bound(offset, 1, MAX_EXPIRY_OFFSET);
        uint64 expiry = uint64(block.timestamp + offset);

        SD59x18 result = wrapper.toYears(expiry);
        assertTrue(result.gt(sd(0)), "Future expiry should yield positive years");
    }

    /// @notice toYears result should match toYearsFromDuration(timeToExpiry)
    function testFuzz_toYears_consistentWithDuration(uint256 offset) public view {
        offset = bound(offset, 1, MAX_EXPIRY_OFFSET);
        uint64 expiry = uint64(block.timestamp + offset);

        uint256 secondsRemaining = wrapper.timeToExpiry(expiry);
        SD59x18 fromToYears = wrapper.toYears(expiry);
        SD59x18 fromDuration = wrapper.toYearsFromDuration(secondsRemaining);

        assertEq(fromToYears.unwrap(), fromDuration.unwrap(), "Should be consistent");
    }

    // ============ isExpired fuzz tests ============

    /// @notice isExpired should return false for future timestamps
    function testFuzz_isExpired_falseForFuture(uint256 offset) public view {
        offset = bound(offset, 1, MAX_EXPIRY_OFFSET);
        uint64 expiry = uint64(block.timestamp + offset);

        assertFalse(wrapper.isExpired(expiry), "Future expiry should not be expired");
    }

    /// @notice isExpired should return true for past timestamps
    function testFuzz_isExpired_trueForPast(uint256 secondsAgo) public view {
        secondsAgo = bound(secondsAgo, 1, block.timestamp - 1);
        uint64 expiry = uint64(block.timestamp - secondsAgo);

        assertTrue(wrapper.isExpired(expiry), "Past expiry should be expired");
    }

    /// @notice isExpired state should flip after time passes expiry
    function testFuzz_isExpired_stateTransition(uint256 offset) public {
        offset = bound(offset, 1, MAX_EXPIRY_OFFSET);
        uint64 expiry = uint64(block.timestamp + offset);

        // Before expiry
        assertFalse(wrapper.isExpired(expiry), "Should not be expired before");

        // Warp to exactly expiry
        vm.warp(expiry);
        assertTrue(wrapper.isExpired(expiry), "Should be expired at expiry");

        // Warp past expiry
        vm.warp(uint256(expiry) + 1);
        assertTrue(wrapper.isExpired(expiry), "Should be expired after");
    }

    // ============ timeToExpiry fuzz tests ============

    /// @notice timeToExpiry should return 0 for expired options
    function testFuzz_timeToExpiry_zeroForExpired(uint256 secondsAgo) public view {
        secondsAgo = bound(secondsAgo, 0, block.timestamp);
        uint64 expiry = uint64(block.timestamp - secondsAgo);

        assertEq(wrapper.timeToExpiry(expiry), 0, "Expired options should return 0");
    }

    /// @notice timeToExpiry should return exact offset for future expiries
    function testFuzz_timeToExpiry_exactOffset(uint256 offset) public view {
        offset = bound(offset, 1, MAX_EXPIRY_OFFSET);
        uint64 expiry = uint64(block.timestamp + offset);

        assertEq(wrapper.timeToExpiry(expiry), offset, "Should return exact offset");
    }

    /// @notice timeToExpiry should decrease as time passes
    function testFuzz_timeToExpiry_decreasing(uint256 offset, uint256 elapsedTime) public {
        offset = bound(offset, 1000, MAX_EXPIRY_OFFSET);
        elapsedTime = bound(elapsedTime, 1, offset - 1);

        uint64 expiry = uint64(block.timestamp + offset);

        uint256 initialTime = wrapper.timeToExpiry(expiry);
        vm.warp(block.timestamp + elapsedTime);
        uint256 laterTime = wrapper.timeToExpiry(expiry);

        assertEq(initialTime - laterTime, elapsedTime, "Should decrease by elapsed time");
    }

    // ============ Cross-function invariant tests ============

    /// @notice isExpired and timeToExpiry should be consistent
    function testFuzz_isExpiredAndTimeToExpiry_consistency(uint64 expiry) public view {
        bool expired = wrapper.isExpired(expiry);
        uint256 remaining = wrapper.timeToExpiry(expiry);

        if (expired) {
            assertEq(remaining, 0, "Expired options should have 0 time remaining");
        } else {
            assertTrue(remaining > 0, "Non-expired options should have positive time");
        }
    }

    /// @notice Converting back and forth should preserve approximate value
    function testFuzz_conversionRoundtrip(uint256 originalSeconds) public view {
        originalSeconds = bound(originalSeconds, SECONDS_PER_YEAR, MAX_EXPIRY_OFFSET);

        SD59x18 yearsValue = wrapper.toYearsFromDuration(originalSeconds);

        // Convert years back to seconds: years * SECONDS_PER_YEAR
        int256 reconstructedSeconds = yearsValue.unwrap() * int256(SECONDS_PER_YEAR) / 1e18;

        // Allow for small rounding errors (within 1 second)
        int256 diff = int256(originalSeconds) - reconstructedSeconds;
        if (diff < 0) diff = -diff;

        assertTrue(diff <= 1, "Roundtrip should preserve value within 1 second");
    }
}
