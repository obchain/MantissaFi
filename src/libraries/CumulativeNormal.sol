// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd } from "@prb/math/SD59x18.sol";

/// @title CumulativeNormal
/// @notice Cumulative normal distribution function Φ(x)
/// @dev Uses Hart's rational approximation (Abramowitz & Stegun 26.2.17)
library CumulativeNormal {
    int256 private constant ONE = 1e18;
    int256 private constant HALF = 5e17;

    // Approximation coefficients
    int256 private constant P = 231641900000000000; // 0.2316419
    int256 private constant A1 = 319381530000000000; // 0.319381530
    int256 private constant A2 = -356563782000000000; // -0.356563782
    int256 private constant A3 = 1781477937000000000; // 1.781477937
    int256 private constant A4 = -1821255978000000000; // -1.821255978
    int256 private constant A5 = 1330274429000000000; // 1.330274429

    /// @notice Computes the cumulative normal distribution Φ(x)
    /// @param x Input value in SD59x18 format
    /// @return The probability P(X ≤ x) where X ~ N(0,1)
    function cdf(SD59x18 x) internal pure returns (SD59x18) {
        // Implementation using rational approximation
        // For x < 0: Φ(x) = 1 - Φ(-x)
        bool negative = x.lt(sd(0));
        if (negative) {
            x = x.abs();
        }

        SD59x18 t = sd(ONE).div(sd(ONE).add(sd(P).mul(x)));

        // Horner's method for polynomial evaluation
        SD59x18 poly = sd(A5);
        poly = poly.mul(t).add(sd(A4));
        poly = poly.mul(t).add(sd(A3));
        poly = poly.mul(t).add(sd(A2));
        poly = poly.mul(t).add(sd(A1));
        poly = poly.mul(t);

        SD59x18 pdf_val = pdf(x);
        SD59x18 result = sd(ONE).sub(pdf_val.mul(poly));

        if (negative) {
            return sd(ONE).sub(result);
        }
        return result;
    }

    /// @notice Computes the probability density function φ(x)
    /// @param x Input value in SD59x18 format
    /// @return The density at x for standard normal distribution
    function pdf(SD59x18 x) internal pure returns (SD59x18) {
        // φ(x) = (1/√(2π)) * e^(-x²/2)
        SD59x18 exponent = x.mul(x).div(sd(2e18)).mul(sd(-1e18));
        return sd(398942280401432678).mul(exponent.exp()); // 1/√(2π)
    }
}
