// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";

/// @title VolatilitySurface
/// @notice Liquidity-Sensitive Implied Volatility Surface combining realized volatility, skew, and utilization premium
/// @dev Implements the formula: σ_implied(K, T) = σ_realized(T) · [1 + skew(K, S) + utilization_premium(u)]
/// @author MantissaFi Team
library VolatilitySurface {
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                                   CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice 1.0 in SD59x18 fixed-point representation
    int256 private constant ONE = 1e18;

    /// @notice Minimum allowed implied volatility (5% = 0.05)
    int256 private constant DEFAULT_IV_FLOOR = 50000000000000000;

    /// @notice Maximum allowed implied volatility (500% = 5.0)
    int256 private constant DEFAULT_IV_CEILING = 5_000000000000000000;

    /// @notice Default gamma coefficient for utilization premium (0.5)
    int256 private constant DEFAULT_GAMMA = 500000000000000000;

    /// @notice Maximum utilization ratio before circuit breaker (99% = 0.99)
    int256 private constant MAX_UTILIZATION = 990000000000000000;

    /// @notice Default base skew coefficient (0.15)
    int256 private constant DEFAULT_SKEW_COEFFICIENT = 150000000000000000;

    /// @notice Moneyness where ATM is considered (1.0)
    int256 private constant ATM_MONEYNESS = 1e18;

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                                    ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Error thrown when spot price is zero or negative
    error VolatilitySurface__InvalidSpotPrice();

    /// @notice Error thrown when strike price is zero or negative
    error VolatilitySurface__InvalidStrikePrice();

    /// @notice Error thrown when realized volatility is zero or negative
    error VolatilitySurface__InvalidRealizedVolatility();

    /// @notice Error thrown when time to expiry is zero or negative
    error VolatilitySurface__InvalidTimeToExpiry();

    /// @notice Error thrown when utilization ratio is negative
    error VolatilitySurface__InvalidUtilization();

    /// @notice Error thrown when utilization exceeds maximum (circuit breaker)
    error VolatilitySurface__UtilizationTooHigh(int256 utilization);

    /// @notice Error thrown when IV floor is greater than or equal to ceiling
    error VolatilitySurface__InvalidIVBounds(int256 floor, int256 ceiling);

    /// @notice Error thrown when total assets is zero
    error VolatilitySurface__ZeroTotalAssets();

    /// @notice Error thrown when locked collateral exceeds total assets
    error VolatilitySurface__LockedExceedsTotal(uint256 locked, uint256 total);

    /// @notice Error thrown when gamma coefficient is negative
    error VolatilitySurface__InvalidGamma();

    /// @notice Error thrown when skew coefficient is negative
    error VolatilitySurface__InvalidSkewCoefficient();

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                                    STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Configuration parameters for the IV surface
    /// @param ivFloor Minimum allowed IV (SD59x18)
    /// @param ivCeiling Maximum allowed IV (SD59x18)
    /// @param gamma Utilization premium coefficient (SD59x18)
    /// @param skewCoefficient Volatility skew sensitivity (SD59x18)
    struct SurfaceConfig {
        SD59x18 ivFloor;
        SD59x18 ivCeiling;
        SD59x18 gamma;
        SD59x18 skewCoefficient;
    }

    /// @notice Pool liquidity state for utilization calculation
    /// @param totalAssets Total assets in the pool
    /// @param lockedCollateral Collateral locked for sold options
    struct PoolState {
        uint256 totalAssets;
        uint256 lockedCollateral;
    }

    /// @notice Input parameters for IV calculation
    /// @param spot Current spot price (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param realizedVol Realized volatility from oracle (SD59x18)
    /// @param timeToExpiry Time to expiration in years (SD59x18)
    struct IVParams {
        SD59x18 spot;
        SD59x18 strike;
        SD59x18 realizedVol;
        SD59x18 timeToExpiry;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                              CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Computes the implied volatility for a given strike and expiry
    /// @dev σ_implied(K, T) = σ_realized(T) · [1 + skew(K, S) + utilization_premium(u)]
    /// @param params IV calculation parameters (spot, strike, realizedVol, timeToExpiry)
    /// @param poolState Pool liquidity state for utilization
    /// @param config Surface configuration parameters
    /// @return iv The calculated implied volatility in SD59x18 format
    function getImpliedVolatility(
        IVParams memory params,
        PoolState memory poolState,
        SurfaceConfig memory config
    ) internal pure returns (SD59x18 iv) {
        // Validate inputs
        _validateIVParams(params);
        _validateConfig(config);

        // Calculate utilization ratio
        SD59x18 utilization = calculateUtilization(poolState);

        // Calculate skew adjustment based on moneyness
        SD59x18 skewAdjustment = calculateSkew(params.spot, params.strike, config.skewCoefficient);

        // Calculate utilization premium
        SD59x18 utilizationPremium = calculateUtilizationPremium(utilization, config.gamma);

        // Combine: σ_implied = σ_realized · [1 + skew + utilization_premium]
        SD59x18 multiplier = sd(ONE).add(skewAdjustment).add(utilizationPremium);
        iv = params.realizedVol.mul(multiplier);

        // Apply IV bounds
        iv = clampIV(iv, config.ivFloor, config.ivCeiling);
    }

    /// @notice Simplified IV calculation using default configuration
    /// @param spot Current spot price (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param realizedVol Realized volatility (SD59x18)
    /// @param utilization Pool utilization ratio (SD59x18)
    /// @return iv The calculated implied volatility in SD59x18 format
    function getImpliedVolatilitySimple(
        SD59x18 spot,
        SD59x18 strike,
        SD59x18 realizedVol,
        SD59x18 utilization
    ) internal pure returns (SD59x18 iv) {
        // Validate basic inputs
        if (spot.lte(ZERO)) revert VolatilitySurface__InvalidSpotPrice();
        if (strike.lte(ZERO)) revert VolatilitySurface__InvalidStrikePrice();
        if (realizedVol.lte(ZERO)) revert VolatilitySurface__InvalidRealizedVolatility();
        if (utilization.lt(ZERO)) revert VolatilitySurface__InvalidUtilization();
        if (utilization.gte(sd(ONE))) revert VolatilitySurface__UtilizationTooHigh(SD59x18.unwrap(utilization));

        // Use default parameters
        SD59x18 skewCoeff = sd(DEFAULT_SKEW_COEFFICIENT);
        SD59x18 gamma = sd(DEFAULT_GAMMA);

        // Calculate components
        SD59x18 skewAdjustment = calculateSkew(spot, strike, skewCoeff);
        SD59x18 utilizationPremium = calculateUtilizationPremium(utilization, gamma);

        // Combine
        SD59x18 multiplier = sd(ONE).add(skewAdjustment).add(utilizationPremium);
        iv = realizedVol.mul(multiplier);

        // Apply default bounds
        iv = clampIV(iv, sd(DEFAULT_IV_FLOOR), sd(DEFAULT_IV_CEILING));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                           COMPONENT FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Calculates the utilization ratio from pool state
    /// @dev u = lockedCollateral / totalAssets
    /// @param poolState Pool liquidity state
    /// @return utilization The utilization ratio in SD59x18 format [0, 1)
    function calculateUtilization(PoolState memory poolState) internal pure returns (SD59x18 utilization) {
        if (poolState.totalAssets == 0) {
            revert VolatilitySurface__ZeroTotalAssets();
        }
        if (poolState.lockedCollateral > poolState.totalAssets) {
            revert VolatilitySurface__LockedExceedsTotal(poolState.lockedCollateral, poolState.totalAssets);
        }

        // Compute ratio: u = lockedCollateral / totalAssets
        // Scale to SD59x18: multiply by 1e18 for precision
        utilization = sd(int256(poolState.lockedCollateral)).mul(sd(ONE)).div(sd(int256(poolState.totalAssets)));
    }

    /// @notice Calculates the utilization premium
    /// @dev utilization_premium(u) = γ · u / (1 - u)
    /// @param utilization Current utilization ratio (SD59x18)
    /// @param gamma Utilization sensitivity coefficient (SD59x18)
    /// @return premium The utilization premium in SD59x18 format
    function calculateUtilizationPremium(SD59x18 utilization, SD59x18 gamma) internal pure returns (SD59x18 premium) {
        if (gamma.lt(ZERO)) revert VolatilitySurface__InvalidGamma();
        if (utilization.lt(ZERO)) revert VolatilitySurface__InvalidUtilization();
        if (utilization.gte(sd(MAX_UTILIZATION))) {
            revert VolatilitySurface__UtilizationTooHigh(SD59x18.unwrap(utilization));
        }

        // Handle zero utilization case
        if (utilization.eq(ZERO)) {
            return ZERO;
        }

        // premium = γ · u / (1 - u)
        SD59x18 denominator = sd(ONE).sub(utilization);
        premium = gamma.mul(utilization).div(denominator);
    }

    /// @notice Calculates the volatility skew adjustment based on moneyness
    /// @dev skew(K, S) = skewCoeff · (1 - K/S) for OTM puts (K < S)
    ///      skew(K, S) = skewCoeff · (K/S - 1) for OTM calls (K > S)
    ///      This creates a smile shape with higher IV for OTM options
    /// @param spot Current spot price (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param skewCoefficient Skew sensitivity (SD59x18)
    /// @return skew The skew adjustment in SD59x18 format
    function calculateSkew(
        SD59x18 spot,
        SD59x18 strike,
        SD59x18 skewCoefficient
    ) internal pure returns (SD59x18 skew) {
        if (spot.lte(ZERO)) revert VolatilitySurface__InvalidSpotPrice();
        if (strike.lte(ZERO)) revert VolatilitySurface__InvalidStrikePrice();
        if (skewCoefficient.lt(ZERO)) revert VolatilitySurface__InvalidSkewCoefficient();

        // Calculate moneyness: K/S
        SD59x18 moneyness = strike.div(spot);

        // Calculate log-moneyness for smooth skew: ln(K/S)
        SD59x18 logMoneyness = moneyness.ln();

        // Skew = coefficient * |ln(K/S)|^2
        // This creates a parabolic smile centered at ATM
        SD59x18 logMoneynessSquared = logMoneyness.mul(logMoneyness);
        skew = skewCoefficient.mul(logMoneynessSquared);
    }

    /// @notice Calculates linear skew (simpler model)
    /// @dev skew = coefficient * |K/S - 1|
    /// @param spot Current spot price (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @param skewCoefficient Skew sensitivity (SD59x18)
    /// @return skew The linear skew adjustment in SD59x18 format
    function calculateLinearSkew(
        SD59x18 spot,
        SD59x18 strike,
        SD59x18 skewCoefficient
    ) internal pure returns (SD59x18 skew) {
        if (spot.lte(ZERO)) revert VolatilitySurface__InvalidSpotPrice();
        if (strike.lte(ZERO)) revert VolatilitySurface__InvalidStrikePrice();
        if (skewCoefficient.lt(ZERO)) revert VolatilitySurface__InvalidSkewCoefficient();

        // Calculate moneyness deviation from ATM
        SD59x18 moneyness = strike.div(spot);
        SD59x18 deviation = moneyness.sub(sd(ONE));

        // Take absolute value for symmetric smile
        if (deviation.lt(ZERO)) {
            deviation = deviation.abs();
        }

        skew = skewCoefficient.mul(deviation);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                          INTERPOLATION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Linear interpolation between two IV points
    /// @dev iv = iv1 + (iv2 - iv1) * (strike - strike1) / (strike2 - strike1)
    /// @param strike Target strike price (SD59x18)
    /// @param strike1 Lower strike bound (SD59x18)
    /// @param strike2 Upper strike bound (SD59x18)
    /// @param iv1 IV at lower strike (SD59x18)
    /// @param iv2 IV at upper strike (SD59x18)
    /// @return iv Interpolated IV at target strike (SD59x18)
    function interpolateLinear(
        SD59x18 strike,
        SD59x18 strike1,
        SD59x18 strike2,
        SD59x18 iv1,
        SD59x18 iv2
    ) internal pure returns (SD59x18 iv) {
        if (strike1.gte(strike2)) revert VolatilitySurface__InvalidStrikePrice();
        if (strike.lt(strike1) || strike.gt(strike2)) revert VolatilitySurface__InvalidStrikePrice();

        // t = (strike - strike1) / (strike2 - strike1)
        SD59x18 t = strike.sub(strike1).div(strike2.sub(strike1));

        // iv = iv1 + t * (iv2 - iv1)
        iv = iv1.add(t.mul(iv2.sub(iv1)));
    }

    /// @notice Cubic interpolation for smoother IV surface (Hermite spline)
    /// @dev Uses cubic Hermite interpolation for C1 continuity
    /// @param strike Target strike price (SD59x18)
    /// @param strike1 Lower strike bound (SD59x18)
    /// @param strike2 Upper strike bound (SD59x18)
    /// @param iv1 IV at lower strike (SD59x18)
    /// @param iv2 IV at upper strike (SD59x18)
    /// @param slope1 Derivative at lower strike (SD59x18)
    /// @param slope2 Derivative at upper strike (SD59x18)
    /// @return iv Interpolated IV at target strike (SD59x18)
    function interpolateCubic(
        SD59x18 strike,
        SD59x18 strike1,
        SD59x18 strike2,
        SD59x18 iv1,
        SD59x18 iv2,
        SD59x18 slope1,
        SD59x18 slope2
    ) internal pure returns (SD59x18 iv) {
        if (strike1.gte(strike2)) revert VolatilitySurface__InvalidStrikePrice();
        if (strike.lt(strike1) || strike.gt(strike2)) revert VolatilitySurface__InvalidStrikePrice();

        // Normalize t to [0, 1]
        SD59x18 h = strike2.sub(strike1);
        SD59x18 t = strike.sub(strike1).div(h);

        // Hermite basis functions
        // h00(t) = 2t³ - 3t² + 1
        // h10(t) = t³ - 2t² + t
        // h01(t) = -2t³ + 3t²
        // h11(t) = t³ - t²

        SD59x18 t2 = t.mul(t);
        SD59x18 t3 = t2.mul(t);

        SD59x18 two = sd(2e18);
        SD59x18 three = sd(3e18);

        SD59x18 h00 = two.mul(t3).sub(three.mul(t2)).add(sd(ONE));
        SD59x18 h10 = t3.sub(two.mul(t2)).add(t);
        SD59x18 h01 = three.mul(t2).sub(two.mul(t3));
        SD59x18 h11 = t3.sub(t2);

        // Cubic Hermite spline: p(t) = h00*p0 + h10*h*m0 + h01*p1 + h11*h*m1
        iv = h00.mul(iv1).add(h10.mul(h).mul(slope1)).add(h01.mul(iv2)).add(h11.mul(h).mul(slope2));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                            UTILITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Clamps the IV to within floor and ceiling bounds
    /// @param iv The input IV (SD59x18)
    /// @param floor Minimum allowed IV (SD59x18)
    /// @param ceiling Maximum allowed IV (SD59x18)
    /// @return clamped The clamped IV (SD59x18)
    function clampIV(SD59x18 iv, SD59x18 floor, SD59x18 ceiling) internal pure returns (SD59x18 clamped) {
        if (floor.gte(ceiling)) revert VolatilitySurface__InvalidIVBounds(SD59x18.unwrap(floor), SD59x18.unwrap(ceiling));

        if (iv.lt(floor)) {
            return floor;
        }
        if (iv.gt(ceiling)) {
            return ceiling;
        }
        return iv;
    }

    /// @notice Returns the default surface configuration
    /// @return config Default SurfaceConfig struct
    function getDefaultConfig() internal pure returns (SurfaceConfig memory config) {
        config = SurfaceConfig({
            ivFloor: sd(DEFAULT_IV_FLOOR),
            ivCeiling: sd(DEFAULT_IV_CEILING),
            gamma: sd(DEFAULT_GAMMA),
            skewCoefficient: sd(DEFAULT_SKEW_COEFFICIENT)
        });
    }

    /// @notice Validates a custom surface configuration
    /// @param config Configuration to validate
    /// @return valid True if configuration is valid
    function validateConfig(SurfaceConfig memory config) internal pure returns (bool valid) {
        if (config.ivFloor.gte(config.ivCeiling)) return false;
        if (config.ivFloor.lte(ZERO)) return false;
        if (config.gamma.lt(ZERO)) return false;
        if (config.skewCoefficient.lt(ZERO)) return false;
        return true;
    }

    /// @notice Computes the moneyness ratio K/S
    /// @param spot Current spot price (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @return moneyness The moneyness ratio (SD59x18)
    function getMoneyness(SD59x18 spot, SD59x18 strike) internal pure returns (SD59x18 moneyness) {
        if (spot.lte(ZERO)) revert VolatilitySurface__InvalidSpotPrice();
        if (strike.lte(ZERO)) revert VolatilitySurface__InvalidStrikePrice();
        moneyness = strike.div(spot);
    }

    /// @notice Computes the log-moneyness ln(K/S)
    /// @param spot Current spot price (SD59x18)
    /// @param strike Option strike price (SD59x18)
    /// @return logMoneyness The log-moneyness (SD59x18)
    function getLogMoneyness(SD59x18 spot, SD59x18 strike) internal pure returns (SD59x18 logMoneyness) {
        SD59x18 moneyness = getMoneyness(spot, strike);
        logMoneyness = moneyness.ln();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                          INTERNAL VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Validates IV calculation parameters
    /// @param params Parameters to validate
    function _validateIVParams(IVParams memory params) private pure {
        if (params.spot.lte(ZERO)) revert VolatilitySurface__InvalidSpotPrice();
        if (params.strike.lte(ZERO)) revert VolatilitySurface__InvalidStrikePrice();
        if (params.realizedVol.lte(ZERO)) revert VolatilitySurface__InvalidRealizedVolatility();
        if (params.timeToExpiry.lte(ZERO)) revert VolatilitySurface__InvalidTimeToExpiry();
    }

    /// @notice Validates surface configuration
    /// @param config Configuration to validate
    function _validateConfig(SurfaceConfig memory config) private pure {
        if (config.ivFloor.gte(config.ivCeiling)) {
            revert VolatilitySurface__InvalidIVBounds(SD59x18.unwrap(config.ivFloor), SD59x18.unwrap(config.ivCeiling));
        }
        if (config.ivFloor.lte(ZERO)) {
            revert VolatilitySurface__InvalidIVBounds(SD59x18.unwrap(config.ivFloor), SD59x18.unwrap(config.ivCeiling));
        }
        if (config.gamma.lt(ZERO)) revert VolatilitySurface__InvalidGamma();
        if (config.skewCoefficient.lt(ZERO)) revert VolatilitySurface__InvalidSkewCoefficient();
    }
}
