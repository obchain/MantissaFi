// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd } from "@prb/math/SD59x18.sol";

/// @title TimeLib
/// @notice Time conversion utilities for Black-Scholes-Merton calculations
/// @dev Converts between block timestamps and annualized time values in SD59x18 format
library TimeLib {
    /// @notice Number of seconds in a year (365.25 days to account for leap years)
    /// @dev 365.25 * 24 * 60 * 60 = 31,557,600 seconds
    int256 internal constant SECONDS_PER_YEAR = 31_557_600;

    /// @notice One second represented in SD59x18 format
    int256 private constant ONE_SECOND = 1e18;

    /// @notice Seconds per year in SD59x18 format
    int256 private constant SECONDS_PER_YEAR_SD = 31_557_600_000000000000000000;

    /// @notice Error thrown when expiry timestamp is in the past
    /// @param expiry The expiry timestamp that was in the past
    /// @param currentTime The current block timestamp
    error TimeLib__ExpiryInPast(uint64 expiry, uint256 currentTime);

    /// @notice Error thrown when expiry timestamp is zero
    error TimeLib__ZeroExpiry();

    /// @notice Converts time remaining until expiry to annualized years
    /// @dev Calculates (expiry - block.timestamp) / 365.25 days
    /// @param expiry The expiry timestamp in Unix seconds
    /// @return Time to expiry in years as SD59x18 (e.g., 0.5e18 for 6 months)
    function toYears(uint64 expiry) internal view returns (SD59x18) {
        if (expiry == 0) {
            revert TimeLib__ZeroExpiry();
        }

        if (expiry <= block.timestamp) {
            revert TimeLib__ExpiryInPast(expiry, block.timestamp);
        }

        uint256 secondsRemaining = uint256(expiry) - block.timestamp;
        return toYearsFromDuration(secondsRemaining);
    }

    /// @notice Converts a duration in seconds to annualized years
    /// @dev Pure function that calculates seconds / 365.25 days
    /// @param seconds_ Duration in seconds to convert
    /// @return Time duration in years as SD59x18 (e.g., 1e18 for exactly one year)
    function toYearsFromDuration(uint256 seconds_) internal pure returns (SD59x18) {
        if (seconds_ == 0) {
            return sd(0);
        }

        // Convert seconds to SD59x18 and divide by seconds per year
        SD59x18 secondsSD = sd(int256(seconds_) * 1e18);
        SD59x18 yearsPerSecond = sd(SECONDS_PER_YEAR_SD);

        return secondsSD.div(yearsPerSecond);
    }

    /// @notice Checks if an option has expired
    /// @dev Returns true if current block timestamp is >= expiry
    /// @param expiry The expiry timestamp in Unix seconds
    /// @return True if expired, false otherwise
    function isExpired(uint64 expiry) internal view returns (bool) {
        return block.timestamp >= expiry;
    }

    /// @notice Returns the number of seconds remaining until expiry
    /// @dev Returns 0 if already expired
    /// @param expiry The expiry timestamp in Unix seconds
    /// @return Seconds remaining until expiry (0 if expired)
    function timeToExpiry(uint64 expiry) internal view returns (uint256) {
        if (block.timestamp >= expiry) {
            return 0;
        }
        return uint256(expiry) - block.timestamp;
    }
}
