// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Constants
/// @notice Mathematical constants for fixed-point arithmetic (SD59x18)
library Constants {
    /// @notice √(2π) ≈ 2.506628274631
    int256 internal constant SQRT_2PI = 2_506628274631000502;

    /// @notice 1/√(2π) ≈ 0.398942280401
    int256 internal constant INV_SQRT_2PI = 398942280401432678;

    /// @notice ln(2) ≈ 0.693147180559
    int256 internal constant LN2 = 693147180559945309;

    /// @notice Euler's number e ≈ 2.718281828459
    int256 internal constant E = 2_718281828459045235;

    /// @notice 0.5 in fixed-point
    int256 internal constant HALF = 500000000000000000;

    /// @notice 1.0 in fixed-point
    int256 internal constant ONE = 1_000000000000000000;

    /// @notice -1.0 in fixed-point
    int256 internal constant NEG_ONE = -1_000000000000000000;

    /// @notice Seconds in a year (365 days)
    int256 internal constant YEAR_IN_SECONDS = 31536000;
}
