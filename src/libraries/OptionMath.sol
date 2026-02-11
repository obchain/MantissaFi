// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";

/// @title OptionMath
/// @notice Utility library for option-specific calculations
/// @dev All functions operate on SD59x18 fixed-point numbers
/// @author MantissaFi Team
library OptionMath {
    /// @notice Error thrown when spot price is zero or negative
    error OptionMath__InvalidSpotPrice();

    /// @notice Error thrown when strike price is zero or negative
    error OptionMath__InvalidStrikePrice();

    /// @notice Computes the payoff of a call option at expiry
    /// @param spot The spot price of the underlying asset (SD59x18)
    /// @param strike The strike price of the option (SD59x18)
    /// @return payoff max(S - K, 0) in SD59x18 format
    function callPayoff(SD59x18 spot, SD59x18 strike) internal pure returns (SD59x18 payoff) {
        if (spot.gt(strike)) {
            payoff = spot.sub(strike);
        } else {
            payoff = ZERO;
        }
    }

    /// @notice Computes the payoff of a put option at expiry
    /// @param spot The spot price of the underlying asset (SD59x18)
    /// @param strike The strike price of the option (SD59x18)
    /// @return payoff max(K - S, 0) in SD59x18 format
    function putPayoff(SD59x18 spot, SD59x18 strike) internal pure returns (SD59x18 payoff) {
        if (strike.gt(spot)) {
            payoff = strike.sub(spot);
        } else {
            payoff = ZERO;
        }
    }

    /// @notice Computes the moneyness ratio S/K
    /// @dev Moneyness > 1 means ITM for calls, OTM for puts
    /// @param spot The spot price of the underlying asset (SD59x18)
    /// @param strike The strike price of the option (SD59x18)
    /// @return ratio The moneyness ratio S/K in SD59x18 format
    function moneyness(SD59x18 spot, SD59x18 strike) internal pure returns (SD59x18 ratio) {
        if (strike.lte(ZERO)) {
            revert OptionMath__InvalidStrikePrice();
        }
        ratio = spot.div(strike);
    }

    /// @notice Computes the log-moneyness ln(S/K)
    /// @dev Used in Black-Scholes d1/d2 calculations
    /// @param spot The spot price of the underlying asset (SD59x18)
    /// @param strike The strike price of the option (SD59x18)
    /// @return logRatio The natural logarithm of S/K in SD59x18 format
    function logMoneyness(SD59x18 spot, SD59x18 strike) internal pure returns (SD59x18 logRatio) {
        if (spot.lte(ZERO)) {
            revert OptionMath__InvalidSpotPrice();
        }
        if (strike.lte(ZERO)) {
            revert OptionMath__InvalidStrikePrice();
        }
        // ln(S/K) = ln(S) - ln(K) to avoid intermediate overflow
        logRatio = spot.ln().sub(strike.ln());
    }

    /// @notice Checks if an option is in-the-money
    /// @param spot The spot price of the underlying asset (SD59x18)
    /// @param strike The strike price of the option (SD59x18)
    /// @param isCall True for call option, false for put option
    /// @return True if the option is ITM
    function isITM(SD59x18 spot, SD59x18 strike, bool isCall) internal pure returns (bool) {
        if (isCall) {
            // Call is ITM when S > K
            return spot.gt(strike);
        } else {
            // Put is ITM when K > S
            return strike.gt(spot);
        }
    }

    /// @notice Computes the intrinsic value of an option
    /// @dev Intrinsic value is the payoff if exercised immediately
    /// @param spot The spot price of the underlying asset (SD59x18)
    /// @param strike The strike price of the option (SD59x18)
    /// @param isCall True for call option, false for put option
    /// @return value The intrinsic value (always >= 0) in SD59x18 format
    function intrinsicValue(SD59x18 spot, SD59x18 strike, bool isCall) internal pure returns (SD59x18 value) {
        if (isCall) {
            value = callPayoff(spot, strike);
        } else {
            value = putPayoff(spot, strike);
        }
    }

    /// @notice Computes the time value component of an option premium
    /// @dev Time value = Premium - Intrinsic Value
    /// @param premium The total option premium (SD59x18)
    /// @param intrinsic The intrinsic value of the option (SD59x18)
    /// @return value The time value component in SD59x18 format
    function timeValue(SD59x18 premium, SD59x18 intrinsic) internal pure returns (SD59x18 value) {
        // Time value cannot be negative for standard options
        if (premium.gt(intrinsic)) {
            value = premium.sub(intrinsic);
        } else {
            value = ZERO;
        }
    }
}
