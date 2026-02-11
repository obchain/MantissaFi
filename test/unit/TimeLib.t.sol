// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd } from "@prb/math/SD59x18.sol";
import { TimeLib } from "../../src/libraries/TimeLib.sol";

/// @title TimeLibWrapper
/// @notice Wrapper contract to expose internal library functions for testing
contract TimeLibWrapper {
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

/// @title TimeLibTest
/// @notice Comprehensive unit tests for TimeLib time conversion utilities
contract TimeLibTest is Test {
    TimeLibWrapper public wrapper;

    /// @notice Tolerance for floating point comparisons (0.0001%)
    int256 private constant TOLERANCE = 1e12;

    /// @notice Seconds in a year (365.25 days)
    uint256 private constant SECONDS_PER_YEAR = 31_557_600;

    /// @notice Base timestamp for tests (year 2024)
    uint256 private constant BASE_TIMESTAMP = 1704067200;

    function setUp() public {
        wrapper = new TimeLibWrapper();
        // Warp to a reasonable base timestamp to avoid underflow issues
        vm.warp(BASE_TIMESTAMP);
    }

    /// @notice Helper to compare SD59x18 values with tolerance
    function assertApproxEqSD(SD59x18 actual, SD59x18 expected, string memory message) internal pure {
        int256 diff = actual.unwrap() - expected.unwrap();
        if (diff < 0) diff = -diff;
        require(diff <= TOLERANCE, message);
    }

    // ============ toYears tests ============

    function test_toYears_oneYearFromNow() public view {
        uint64 expiry = uint64(block.timestamp + SECONDS_PER_YEAR);
        SD59x18 timeInYears = wrapper.toYears(expiry);

        // Should be approximately 1 year
        assertApproxEqSD(timeInYears, sd(1e18), "Should be 1 year");
    }

    function test_toYears_sixMonthsFromNow() public view {
        uint64 expiry = uint64(block.timestamp + SECONDS_PER_YEAR / 2);
        SD59x18 timeInYears = wrapper.toYears(expiry);

        // Should be approximately 0.5 years
        assertApproxEqSD(timeInYears, sd(0.5e18), "Should be 0.5 years");
    }

    function test_toYears_thirtyDaysFromNow() public view {
        uint256 thirtyDays = 30 * 24 * 60 * 60;
        uint64 expiry = uint64(block.timestamp + thirtyDays);
        SD59x18 timeInYears = wrapper.toYears(expiry);

        // 30 days / 365.25 days ≈ 0.08213552 years
        int256 expected = int256((thirtyDays * 1e18) / SECONDS_PER_YEAR);
        assertApproxEqSD(timeInYears, sd(expected), "Should be ~0.082 years");
    }

    function test_toYears_oneWeekFromNow() public view {
        uint256 oneWeek = 7 * 24 * 60 * 60;
        uint64 expiry = uint64(block.timestamp + oneWeek);
        SD59x18 timeInYears = wrapper.toYears(expiry);

        // 7 days / 365.25 days ≈ 0.01916496 years
        int256 expected = int256((oneWeek * 1e18) / SECONDS_PER_YEAR);
        assertApproxEqSD(timeInYears, sd(expected), "Should be ~0.019 years");
    }

    function test_toYears_twoYearsFromNow() public view {
        uint64 expiry = uint64(block.timestamp + 2 * SECONDS_PER_YEAR);
        SD59x18 timeInYears = wrapper.toYears(expiry);

        // Should be approximately 2 years
        assertApproxEqSD(timeInYears, sd(2e18), "Should be 2 years");
    }

    function test_toYears_oneSecondFromNow() public view {
        uint64 expiry = uint64(block.timestamp + 1);
        SD59x18 timeInYears = wrapper.toYears(expiry);

        // Very small but positive value
        assertTrue(timeInYears.gt(sd(0)), "Should be positive");
        assertTrue(timeInYears.lt(sd(1e15)), "Should be very small");
    }

    function test_toYears_revertsOnExpiredOption() public {
        uint64 expiry = uint64(block.timestamp - 1);

        vm.expectRevert(abi.encodeWithSelector(TimeLib.TimeLib__ExpiryInPast.selector, expiry, block.timestamp));
        wrapper.toYears(expiry);
    }

    function test_toYears_revertsOnCurrentTimestamp() public {
        uint64 expiry = uint64(block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(TimeLib.TimeLib__ExpiryInPast.selector, expiry, block.timestamp));
        wrapper.toYears(expiry);
    }

    function test_toYears_revertsOnZeroExpiry() public {
        vm.expectRevert(TimeLib.TimeLib__ZeroExpiry.selector);
        wrapper.toYears(0);
    }

    function test_toYears_atDifferentBlockTimestamp() public {
        // Warp to a different timestamp
        vm.warp(1700000000);

        uint64 expiry = uint64(block.timestamp + SECONDS_PER_YEAR);
        SD59x18 timeInYears = wrapper.toYears(expiry);

        assertApproxEqSD(timeInYears, sd(1e18), "Should be 1 year at warped time");
    }

    // ============ toYearsFromDuration tests ============

    function test_toYearsFromDuration_oneYear() public view {
        SD59x18 timeInYears = wrapper.toYearsFromDuration(SECONDS_PER_YEAR);
        assertApproxEqSD(timeInYears, sd(1e18), "Should be 1 year");
    }

    function test_toYearsFromDuration_halfYear() public view {
        SD59x18 timeInYears = wrapper.toYearsFromDuration(SECONDS_PER_YEAR / 2);
        assertApproxEqSD(timeInYears, sd(0.5e18), "Should be 0.5 years");
    }

    function test_toYearsFromDuration_zeroSeconds() public view {
        SD59x18 timeInYears = wrapper.toYearsFromDuration(0);
        assertEq(timeInYears.unwrap(), 0, "Should be 0 for 0 seconds");
    }

    function test_toYearsFromDuration_oneSecond() public view {
        SD59x18 timeInYears = wrapper.toYearsFromDuration(1);

        // 1 second / 31,557,600 seconds ≈ 3.169e-8 years
        assertTrue(timeInYears.gt(sd(0)), "Should be positive");
        assertTrue(timeInYears.lt(sd(1e12)), "Should be very small");
    }

    function test_toYearsFromDuration_ninetyDays() public view {
        uint256 ninetyDays = 90 * 24 * 60 * 60;
        SD59x18 timeInYears = wrapper.toYearsFromDuration(ninetyDays);

        // 90 days ≈ 0.2464 years
        int256 expected = int256((ninetyDays * 1e18) / SECONDS_PER_YEAR);
        assertApproxEqSD(timeInYears, sd(expected), "Should be ~0.246 years");
    }

    function test_toYearsFromDuration_tenYears() public view {
        SD59x18 timeInYears = wrapper.toYearsFromDuration(10 * SECONDS_PER_YEAR);
        assertApproxEqSD(timeInYears, sd(10e18), "Should be 10 years");
    }

    function test_toYearsFromDuration_oneHour() public view {
        uint256 oneHour = 60 * 60;
        SD59x18 timeInYears = wrapper.toYearsFromDuration(oneHour);

        // Should be approximately 1/8766 years (hours in a year = 365.25 * 24)
        int256 expected = int256((oneHour * 1e18) / SECONDS_PER_YEAR);
        assertApproxEqSD(timeInYears, sd(expected), "Should be ~0.000114 years");
    }

    // ============ isExpired tests ============

    function test_isExpired_futureExpiry() public view {
        uint64 expiry = uint64(block.timestamp + 1000);
        assertFalse(wrapper.isExpired(expiry), "Future expiry should not be expired");
    }

    function test_isExpired_pastExpiry() public view {
        uint64 expiry = uint64(block.timestamp - 1);
        assertTrue(wrapper.isExpired(expiry), "Past expiry should be expired");
    }

    function test_isExpired_exactlyNow() public view {
        uint64 expiry = uint64(block.timestamp);
        assertTrue(wrapper.isExpired(expiry), "Expiry at current time should be expired");
    }

    function test_isExpired_zeroExpiry() public view {
        assertTrue(wrapper.isExpired(0), "Zero expiry should be expired");
    }

    function test_isExpired_oneSecondAgo() public view {
        uint64 expiry = uint64(block.timestamp - 1);
        assertTrue(wrapper.isExpired(expiry), "One second ago should be expired");
    }

    function test_isExpired_oneSecondFromNow() public view {
        uint64 expiry = uint64(block.timestamp + 1);
        assertFalse(wrapper.isExpired(expiry), "One second from now should not be expired");
    }

    function test_isExpired_afterTimeWarp() public {
        uint64 expiry = uint64(block.timestamp + 1000);

        // Before warp
        assertFalse(wrapper.isExpired(expiry), "Should not be expired before warp");

        // Warp past expiry
        vm.warp(uint256(expiry) + 1000);

        // After warp
        assertTrue(wrapper.isExpired(expiry), "Should be expired after warp");
    }

    // ============ timeToExpiry tests ============

    function test_timeToExpiry_futureExpiry() public view {
        uint256 duration = 1000;
        uint64 expiry = uint64(block.timestamp + duration);

        assertEq(wrapper.timeToExpiry(expiry), duration, "Should return exact duration");
    }

    function test_timeToExpiry_pastExpiry() public view {
        uint64 expiry = uint64(block.timestamp - 100);

        assertEq(wrapper.timeToExpiry(expiry), 0, "Past expiry should return 0");
    }

    function test_timeToExpiry_exactlyNow() public view {
        uint64 expiry = uint64(block.timestamp);

        assertEq(wrapper.timeToExpiry(expiry), 0, "Expiry at now should return 0");
    }

    function test_timeToExpiry_zeroExpiry() public view {
        assertEq(wrapper.timeToExpiry(0), 0, "Zero expiry should return 0");
    }

    function test_timeToExpiry_oneYearFromNow() public view {
        uint64 expiry = uint64(block.timestamp + SECONDS_PER_YEAR);

        assertEq(wrapper.timeToExpiry(expiry), SECONDS_PER_YEAR, "Should return one year in seconds");
    }

    function test_timeToExpiry_decreasesOverTime() public {
        uint64 expiry = uint64(block.timestamp + 1000);

        uint256 initialTime = wrapper.timeToExpiry(expiry);
        assertEq(initialTime, 1000, "Initial time should be 1000");

        vm.warp(block.timestamp + 500);

        uint256 remainingTime = wrapper.timeToExpiry(expiry);
        assertEq(remainingTime, 500, "Remaining time should be 500");

        vm.warp(block.timestamp + 600);

        remainingTime = wrapper.timeToExpiry(expiry);
        assertEq(remainingTime, 0, "Should be 0 after expiry");
    }

    // ============ Integration / Cross-function tests ============

    function test_toYearsAndTimeToExpiry_consistency() public view {
        uint64 expiry = uint64(block.timestamp + SECONDS_PER_YEAR);

        uint256 secondsRemaining = wrapper.timeToExpiry(expiry);
        SD59x18 yearsFromToYears = wrapper.toYears(expiry);
        SD59x18 yearsFromDuration = wrapper.toYearsFromDuration(secondsRemaining);

        assertEq(yearsFromToYears.unwrap(), yearsFromDuration.unwrap(), "toYears and toYearsFromDuration should match");
    }

    function test_isExpiredAndTimeToExpiry_consistency() public view {
        uint64 futureExpiry = uint64(block.timestamp + 1000);
        uint64 pastExpiry = uint64(block.timestamp - 1);

        // Future: not expired, has time remaining
        assertFalse(wrapper.isExpired(futureExpiry), "Future should not be expired");
        assertTrue(wrapper.timeToExpiry(futureExpiry) > 0, "Future should have time remaining");

        // Past: expired, no time remaining
        assertTrue(wrapper.isExpired(pastExpiry), "Past should be expired");
        assertEq(wrapper.timeToExpiry(pastExpiry), 0, "Past should have no time remaining");
    }
}
