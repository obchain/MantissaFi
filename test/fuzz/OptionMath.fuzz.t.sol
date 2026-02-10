// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { OptionMath } from "../../src/libraries/OptionMath.sol";

/// @title OptionMathFuzzTest
/// @notice Fuzz tests for OptionMath library
/// @dev Tests mathematical invariants across random inputs
contract OptionMathFuzzTest is Test {
    // Bounds for realistic option prices (in whole units, not fixed-point)
    uint256 internal constant MIN_PRICE = 1; // $1
    uint256 internal constant MAX_PRICE = 1_000_000; // $1M

    // =========================================================================
    // Payoff Fuzz Tests
    // =========================================================================

    /// @notice Call payoff is always >= 0
    function testFuzz_callPayoff_neverNegative(uint256 spotRaw, uint256 strikeRaw) public pure {
        // Bound to reasonable price range
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 payoff = OptionMath.callPayoff(spot, strike);
        assertGe(SD59x18.unwrap(payoff), 0, "Call payoff must be >= 0");
    }

    /// @notice Put payoff is always >= 0
    function testFuzz_putPayoff_neverNegative(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 payoff = OptionMath.putPayoff(spot, strike);
        assertGe(SD59x18.unwrap(payoff), 0, "Put payoff must be >= 0");
    }

    /// @notice Call payoff + Put payoff = |S - K| (put-call parity at expiry)
    function testFuzz_payoff_putCallParity(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 callPay = OptionMath.callPayoff(spot, strike);
        SD59x18 putPay = OptionMath.putPayoff(spot, strike);

        // Either call or put has positive payoff (not both)
        // callPayoff + putPayoff = |S - K|
        int256 spotStrikeDiff = int256(spotRaw * 1e18) - int256(strikeRaw * 1e18);
        int256 absDiff = spotStrikeDiff >= 0 ? spotStrikeDiff : -spotStrikeDiff;

        int256 totalPayoff = SD59x18.unwrap(callPay) + SD59x18.unwrap(putPay);
        assertEq(totalPayoff, absDiff, "Payoff sum should equal |S - K|");
    }

    /// @notice At most one of call/put has positive payoff
    function testFuzz_payoff_mutuallyExclusive(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 callPay = OptionMath.callPayoff(spot, strike);
        SD59x18 putPay = OptionMath.putPayoff(spot, strike);

        // At most one can be positive
        bool callPositive = SD59x18.unwrap(callPay) > 0;
        bool putPositive = SD59x18.unwrap(putPay) > 0;
        assertFalse(callPositive && putPositive, "Both payoffs cannot be positive");
    }

    // =========================================================================
    // Moneyness Fuzz Tests
    // =========================================================================

    /// @notice Moneyness is always positive for positive spot and strike
    function testFuzz_moneyness_alwaysPositive(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 m = OptionMath.moneyness(spot, strike);
        assertGt(SD59x18.unwrap(m), 0, "Moneyness must be positive");
    }

    /// @notice Moneyness * inverse moneyness = 1
    function testFuzz_moneyness_inverseProperty(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 m1 = OptionMath.moneyness(spot, strike);
        SD59x18 m2 = OptionMath.moneyness(strike, spot);

        // m1 * m2 should equal 1
        SD59x18 product = m1.mul(m2);
        assertApproxEqRel(SD59x18.unwrap(product), 1e18, 1e14, "Moneyness * inverse should equal 1");
    }

    // =========================================================================
    // Log Moneyness Fuzz Tests
    // =========================================================================

    /// @notice Log moneyness has opposite sign to inverse
    function testFuzz_logMoneyness_antisymmetric(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 lm1 = OptionMath.logMoneyness(spot, strike);
        SD59x18 lm2 = OptionMath.logMoneyness(strike, spot);

        // ln(S/K) = -ln(K/S)
        int256 sum = SD59x18.unwrap(lm1) + SD59x18.unwrap(lm2);
        assertApproxEqAbs(sum, 0, 10, "Log moneyness should be antisymmetric");
    }

    /// @notice Log moneyness sign matches spot-strike comparison
    function testFuzz_logMoneyness_signCorrect(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 lm = OptionMath.logMoneyness(spot, strike);

        if (spotRaw > strikeRaw) {
            assertGt(SD59x18.unwrap(lm), 0, "ln(S/K) > 0 when S > K");
        } else if (spotRaw < strikeRaw) {
            assertLt(SD59x18.unwrap(lm), 0, "ln(S/K) < 0 when S < K");
        } else {
            assertEq(SD59x18.unwrap(lm), 0, "ln(S/K) = 0 when S = K");
        }
    }

    // =========================================================================
    // isITM Fuzz Tests
    // =========================================================================

    /// @notice isITM is consistent with payoff
    function testFuzz_isITM_consistentWithPayoff(uint256 spotRaw, uint256 strikeRaw, bool isCall) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        bool itm = OptionMath.isITM(spot, strike, isCall);
        SD59x18 payoff = isCall ? OptionMath.callPayoff(spot, strike) : OptionMath.putPayoff(spot, strike);

        if (itm) {
            assertGt(SD59x18.unwrap(payoff), 0, "ITM option should have positive payoff");
        } else {
            assertEq(SD59x18.unwrap(payoff), 0, "OTM/ATM option should have zero payoff");
        }
    }

    /// @notice Call and put ITM are mutually exclusive (except ATM)
    function testFuzz_isITM_mutuallyExclusive(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        bool callITM = OptionMath.isITM(spot, strike, true);
        bool putITM = OptionMath.isITM(spot, strike, false);

        // Both can't be ITM at the same time
        assertFalse(callITM && putITM, "Call and put cannot both be ITM");
    }

    // =========================================================================
    // Intrinsic Value Fuzz Tests
    // =========================================================================

    /// @notice Intrinsic value equals payoff
    function testFuzz_intrinsicValue_equalsPayoff(uint256 spotRaw, uint256 strikeRaw, bool isCall) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));

        SD59x18 iv = OptionMath.intrinsicValue(spot, strike, isCall);
        SD59x18 payoff = isCall ? OptionMath.callPayoff(spot, strike) : OptionMath.putPayoff(spot, strike);

        assertEq(SD59x18.unwrap(iv), SD59x18.unwrap(payoff), "Intrinsic value should equal payoff");
    }

    // =========================================================================
    // Time Value Fuzz Tests
    // =========================================================================

    /// @notice Time value is always >= 0
    function testFuzz_timeValue_neverNegative(uint256 premiumRaw, uint256 intrinsicRaw) public pure {
        premiumRaw = bound(premiumRaw, 0, MAX_PRICE);
        intrinsicRaw = bound(intrinsicRaw, 0, MAX_PRICE);

        SD59x18 premium = sd(int256(premiumRaw * 1e18));
        SD59x18 intrinsic = sd(int256(intrinsicRaw * 1e18));

        SD59x18 tv = OptionMath.timeValue(premium, intrinsic);
        assertGe(SD59x18.unwrap(tv), 0, "Time value must be >= 0");
    }

    /// @notice Time value + intrinsic >= premium (due to floor)
    function testFuzz_timeValue_decomposition(uint256 premiumRaw, uint256 intrinsicRaw) public pure {
        premiumRaw = bound(premiumRaw, 0, MAX_PRICE);
        intrinsicRaw = bound(intrinsicRaw, 0, premiumRaw); // Intrinsic <= Premium normally

        SD59x18 premium = sd(int256(premiumRaw * 1e18));
        SD59x18 intrinsic = sd(int256(intrinsicRaw * 1e18));

        SD59x18 tv = OptionMath.timeValue(premium, intrinsic);

        // tv + intrinsic = premium (when intrinsic <= premium)
        int256 reconstructed = SD59x18.unwrap(tv) + SD59x18.unwrap(intrinsic);
        assertEq(reconstructed, SD59x18.unwrap(premium), "Time value + intrinsic should equal premium");
    }
}
