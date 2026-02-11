// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";

/// @title SkewModel
/// @notice Models the volatility skew (smile) that adjusts IV based on option moneyness
/// @dev Implements a quadratic skew model: skew(K, S) = α · (K/S - 1)² + β · (K/S - 1)
///      where α controls curvature (smile) and β controls slope (skew direction)
library SkewModel {
    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice 1.0 in SD59x18 format
    int256 private constant ONE = 1e18;

    /// @notice Maximum allowed skew adjustment (100% = 1.0)
    /// @dev Prevents extreme IV modifications that could destabilize pricing
    int256 private constant MAX_SKEW = 1e18;

    /// @notice Minimum allowed skew adjustment (-50% = -0.5)
    /// @dev Prevents negative IV which is economically meaningless
    int256 private constant MIN_SKEW = -5e17;

    /// @notice Maximum allowed alpha parameter (curvature)
    /// @dev Bounds: 0 ≤ α ≤ 10.0 to prevent excessive smile curvature
    int256 private constant MAX_ALPHA = 10e18;

    /// @notice Maximum allowed beta parameter (slope magnitude)
    /// @dev Bounds: -5.0 ≤ β ≤ 5.0 to prevent extreme skew direction
    int256 private constant MAX_BETA = 5e18;

    /// @notice Minimum allowed beta parameter
    int256 private constant MIN_BETA = -5e18;

    /// @notice Minimum allowed spot price (prevents division by zero)
    int256 private constant MIN_SPOT = 1;

    /// @notice Minimum allowed strike price
    int256 private constant MIN_STRIKE = 1;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when spot price is zero or negative
    error SkewModel__InvalidSpotPrice();

    /// @notice Thrown when strike price is zero or negative
    error SkewModel__InvalidStrikePrice();

    /// @notice Thrown when alpha parameter exceeds maximum bound
    error SkewModel__AlphaExceedsMaximum();

    /// @notice Thrown when alpha parameter is negative
    error SkewModel__AlphaNegative();

    /// @notice Thrown when beta parameter exceeds maximum bound
    error SkewModel__BetaExceedsMaximum();

    /// @notice Thrown when beta parameter is below minimum bound
    error SkewModel__BetaBelowMinimum();

    // ═══════════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Configuration parameters for the skew model
    /// @param alpha Curvature parameter (smile intensity), must be ≥ 0
    /// @param beta Slope parameter (skew direction), negative = put skew, positive = call skew
    struct SkewParams {
        SD59x18 alpha;
        SD59x18 beta;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Calculates the volatility skew adjustment for a given strike and spot price
    /// @dev Implements: skew(K, S) = α · (K/S - 1)² + β · (K/S - 1)
    /// @param strike The option strike price in SD59x18 format
    /// @param spot The current spot price in SD59x18 format
    /// @param params The skew model parameters (alpha, beta)
    /// @return skewAdjustment The skew adjustment to apply to base IV (bounded between MIN_SKEW and MAX_SKEW)
    function calculateSkew(SD59x18 strike, SD59x18 spot, SkewParams memory params)
        internal
        pure
        returns (SD59x18 skewAdjustment)
    {
        // Validate inputs
        if (spot.lte(ZERO)) revert SkewModel__InvalidSpotPrice();
        if (strike.lte(ZERO)) revert SkewModel__InvalidStrikePrice();

        // Calculate moneyness: m = K/S - 1
        SD59x18 moneyness = strike.div(spot).sub(sd(ONE));

        // Calculate quadratic term: α · m²
        SD59x18 moneynessSquared = moneyness.mul(moneyness);
        SD59x18 quadraticTerm = params.alpha.mul(moneynessSquared);

        // Calculate linear term: β · m
        SD59x18 linearTerm = params.beta.mul(moneyness);

        // Total skew: α · m² + β · m
        skewAdjustment = quadraticTerm.add(linearTerm);

        // Bound the result to prevent extreme IV adjustments
        skewAdjustment = _boundSkew(skewAdjustment);
    }

    /// @notice Calculates the adjusted implied volatility by applying skew to base IV
    /// @dev adjustedIV = baseIV * (1 + skew)
    /// @param baseIV The base implied volatility in SD59x18 format
    /// @param strike The option strike price in SD59x18 format
    /// @param spot The current spot price in SD59x18 format
    /// @param params The skew model parameters
    /// @return adjustedIV The adjusted implied volatility after applying skew
    function applySkew(SD59x18 baseIV, SD59x18 strike, SD59x18 spot, SkewParams memory params)
        internal
        pure
        returns (SD59x18 adjustedIV)
    {
        SD59x18 skew = calculateSkew(strike, spot, params);

        // adjustedIV = baseIV * (1 + skew)
        SD59x18 multiplier = sd(ONE).add(skew);
        adjustedIV = baseIV.mul(multiplier);

        // Ensure IV doesn't go negative
        if (adjustedIV.lt(ZERO)) {
            adjustedIV = ZERO;
        }
    }

    /// @notice Calculates the moneyness ratio K/S
    /// @dev Used for external analysis and visualization of the skew curve
    /// @param strike The option strike price in SD59x18 format
    /// @param spot The current spot price in SD59x18 format
    /// @return moneyness The moneyness ratio K/S
    function calculateMoneyness(SD59x18 strike, SD59x18 spot) internal pure returns (SD59x18 moneyness) {
        if (spot.lte(ZERO)) revert SkewModel__InvalidSpotPrice();
        if (strike.lte(ZERO)) revert SkewModel__InvalidStrikePrice();

        moneyness = strike.div(spot);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PARAMETER VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Validates skew model parameters
    /// @dev Ensures alpha and beta are within acceptable bounds
    /// @param params The skew model parameters to validate
    function validateParams(SkewParams memory params) internal pure {
        // Alpha must be non-negative (curvature can't be negative)
        if (params.alpha.lt(ZERO)) revert SkewModel__AlphaNegative();

        // Alpha must not exceed maximum
        if (params.alpha.gt(sd(MAX_ALPHA))) revert SkewModel__AlphaExceedsMaximum();

        // Beta must be within bounds
        if (params.beta.gt(sd(MAX_BETA))) revert SkewModel__BetaExceedsMaximum();
        if (params.beta.lt(sd(MIN_BETA))) revert SkewModel__BetaBelowMinimum();
    }

    /// @notice Creates and validates skew parameters from raw int256 values
    /// @dev Convenience function for governance/configuration
    /// @param alpha The alpha parameter as int256 (18 decimals)
    /// @param beta The beta parameter as int256 (18 decimals)
    /// @return params The validated SkewParams struct
    function createParams(int256 alpha, int256 beta) internal pure returns (SkewParams memory params) {
        params = SkewParams({ alpha: sd(alpha), beta: sd(beta) });
        validateParams(params);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Bounds the skew adjustment to prevent extreme values
    /// @param skew The unbounded skew value
    /// @return bounded The bounded skew value between MIN_SKEW and MAX_SKEW
    function _boundSkew(SD59x18 skew) private pure returns (SD59x18 bounded) {
        if (skew.gt(sd(MAX_SKEW))) {
            return sd(MAX_SKEW);
        }
        if (skew.lt(sd(MIN_SKEW))) {
            return sd(MIN_SKEW);
        }
        return skew;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS FOR CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Returns the maximum allowed skew adjustment
    /// @return The maximum skew value in SD59x18 format
    function maxSkew() internal pure returns (SD59x18) {
        return sd(MAX_SKEW);
    }

    /// @notice Returns the minimum allowed skew adjustment
    /// @return The minimum skew value in SD59x18 format
    function minSkew() internal pure returns (SD59x18) {
        return sd(MIN_SKEW);
    }

    /// @notice Returns the maximum allowed alpha parameter
    /// @return The maximum alpha value in SD59x18 format
    function maxAlpha() internal pure returns (SD59x18) {
        return sd(MAX_ALPHA);
    }

    /// @notice Returns the maximum allowed beta parameter
    /// @return The maximum beta value in SD59x18 format
    function maxBeta() internal pure returns (SD59x18) {
        return sd(MAX_BETA);
    }

    /// @notice Returns the minimum allowed beta parameter
    /// @return The minimum beta value in SD59x18 format
    function minBeta() internal pure returns (SD59x18) {
        return sd(MIN_BETA);
    }
}
