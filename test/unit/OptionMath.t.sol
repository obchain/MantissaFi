// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd } from "@prb/math/SD59x18.sol";
import { OptionMath } from "../../src/libraries/OptionMath.sol";

/// @title OptionMathTest
/// @notice Unit tests for OptionMath library
contract OptionMathTest is Test {
    // Test values in SD59x18 format
    SD59x18 internal constant ETH_3000 = SD59x18.wrap(3000e18);
    SD59x18 internal constant ETH_3100 = SD59x18.wrap(3100e18);
    SD59x18 internal constant ETH_2900 = SD59x18.wrap(2900e18);
    SD59x18 internal constant ZERO = SD59x18.wrap(0);
    SD59x18 internal constant ONE = SD59x18.wrap(1e18);

    // =========================================================================
    // Call Payoff Tests
    // =========================================================================

    function test_callPayoff_ITM() public pure {
        // Spot = 3100, Strike = 3000 -> Payoff = 100
        SD59x18 payoff = OptionMath.callPayoff(ETH_3100, ETH_3000);
        assertEq(SD59x18.unwrap(payoff), 100e18, "Call payoff should be 100");
    }

    function test_callPayoff_ATM() public pure {
        // Spot = Strike -> Payoff = 0
        SD59x18 payoff = OptionMath.callPayoff(ETH_3000, ETH_3000);
        assertEq(SD59x18.unwrap(payoff), 0, "ATM call payoff should be 0");
    }

    function test_callPayoff_OTM() public pure {
        // Spot = 2900, Strike = 3000 -> Payoff = 0
        SD59x18 payoff = OptionMath.callPayoff(ETH_2900, ETH_3000);
        assertEq(SD59x18.unwrap(payoff), 0, "OTM call payoff should be 0");
    }

    function test_callPayoff_deepITM() public pure {
        // Spot = 5000, Strike = 3000 -> Payoff = 2000
        SD59x18 spot = sd(5000e18);
        SD59x18 payoff = OptionMath.callPayoff(spot, ETH_3000);
        assertEq(SD59x18.unwrap(payoff), 2000e18, "Deep ITM call payoff should be 2000");
    }

    // =========================================================================
    // Put Payoff Tests
    // =========================================================================

    function test_putPayoff_ITM() public pure {
        // Spot = 2900, Strike = 3000 -> Payoff = 100
        SD59x18 payoff = OptionMath.putPayoff(ETH_2900, ETH_3000);
        assertEq(SD59x18.unwrap(payoff), 100e18, "Put payoff should be 100");
    }

    function test_putPayoff_ATM() public pure {
        // Spot = Strike -> Payoff = 0
        SD59x18 payoff = OptionMath.putPayoff(ETH_3000, ETH_3000);
        assertEq(SD59x18.unwrap(payoff), 0, "ATM put payoff should be 0");
    }

    function test_putPayoff_OTM() public pure {
        // Spot = 3100, Strike = 3000 -> Payoff = 0
        SD59x18 payoff = OptionMath.putPayoff(ETH_3100, ETH_3000);
        assertEq(SD59x18.unwrap(payoff), 0, "OTM put payoff should be 0");
    }

    function test_putPayoff_deepITM() public pure {
        // Spot = 1000, Strike = 3000 -> Payoff = 2000
        SD59x18 spot = sd(1000e18);
        SD59x18 payoff = OptionMath.putPayoff(spot, ETH_3000);
        assertEq(SD59x18.unwrap(payoff), 2000e18, "Deep ITM put payoff should be 2000");
    }

    // =========================================================================
    // Moneyness Tests
    // =========================================================================

    function test_moneyness_ATM() public pure {
        // S = K -> moneyness = 1.0
        SD59x18 m = OptionMath.moneyness(ETH_3000, ETH_3000);
        assertEq(SD59x18.unwrap(m), 1e18, "ATM moneyness should be 1.0");
    }

    function test_moneyness_ITM_call() public pure {
        // S = 3100, K = 3000 -> moneyness > 1
        SD59x18 m = OptionMath.moneyness(ETH_3100, ETH_3000);
        assertGt(SD59x18.unwrap(m), 1e18, "ITM call moneyness should be > 1");
        // 3100/3000 = 1.0333...
        assertApproxEqRel(SD59x18.unwrap(m), 1033333333333333333, 1e14, "Moneyness should be ~1.033");
    }

    function test_moneyness_OTM_call() public pure {
        // S = 2900, K = 3000 -> moneyness < 1
        SD59x18 m = OptionMath.moneyness(ETH_2900, ETH_3000);
        assertLt(SD59x18.unwrap(m), 1e18, "OTM call moneyness should be < 1");
    }

    function test_moneyness_revertsOnZeroStrike() public {
        vm.expectRevert(OptionMath.OptionMath__InvalidStrikePrice.selector);
        OptionMath.moneyness(ETH_3000, ZERO);
    }

    function test_moneyness_revertsOnNegativeStrike() public {
        vm.expectRevert(OptionMath.OptionMath__InvalidStrikePrice.selector);
        OptionMath.moneyness(ETH_3000, sd(-1e18));
    }

    // =========================================================================
    // Log Moneyness Tests
    // =========================================================================

    function test_logMoneyness_ATM() public pure {
        // S = K -> ln(S/K) = 0
        SD59x18 lm = OptionMath.logMoneyness(ETH_3000, ETH_3000);
        assertEq(SD59x18.unwrap(lm), 0, "ATM log moneyness should be 0");
    }

    function test_logMoneyness_ITM_call() public pure {
        // S > K -> ln(S/K) > 0
        SD59x18 lm = OptionMath.logMoneyness(ETH_3100, ETH_3000);
        assertGt(SD59x18.unwrap(lm), 0, "ITM call log moneyness should be > 0");
    }

    function test_logMoneyness_OTM_call() public pure {
        // S < K -> ln(S/K) < 0
        SD59x18 lm = OptionMath.logMoneyness(ETH_2900, ETH_3000);
        assertLt(SD59x18.unwrap(lm), 0, "OTM call log moneyness should be < 0");
    }

    function test_logMoneyness_symmetry() public pure {
        // ln(S/K) = -ln(K/S)
        SD59x18 lm1 = OptionMath.logMoneyness(ETH_3100, ETH_3000);
        SD59x18 lm2 = OptionMath.logMoneyness(ETH_3000, ETH_3100);
        assertApproxEqAbs(SD59x18.unwrap(lm1), -SD59x18.unwrap(lm2), 1, "Log moneyness should be symmetric");
    }

    function test_logMoneyness_revertsOnZeroSpot() public {
        vm.expectRevert(OptionMath.OptionMath__InvalidSpotPrice.selector);
        OptionMath.logMoneyness(ZERO, ETH_3000);
    }

    function test_logMoneyness_revertsOnZeroStrike() public {
        vm.expectRevert(OptionMath.OptionMath__InvalidStrikePrice.selector);
        OptionMath.logMoneyness(ETH_3000, ZERO);
    }

    // =========================================================================
    // isITM Tests
    // =========================================================================

    function test_isITM_call_true() public pure {
        // S > K -> call is ITM
        assertTrue(OptionMath.isITM(ETH_3100, ETH_3000, true), "Call should be ITM when S > K");
    }

    function test_isITM_call_false() public pure {
        // S < K -> call is OTM
        assertFalse(OptionMath.isITM(ETH_2900, ETH_3000, true), "Call should be OTM when S < K");
    }

    function test_isITM_call_ATM() public pure {
        // S = K -> call is not ITM (ATM)
        assertFalse(OptionMath.isITM(ETH_3000, ETH_3000, true), "Call should not be ITM when S = K");
    }

    function test_isITM_put_true() public pure {
        // K > S -> put is ITM
        assertTrue(OptionMath.isITM(ETH_2900, ETH_3000, false), "Put should be ITM when K > S");
    }

    function test_isITM_put_false() public pure {
        // K < S -> put is OTM
        assertFalse(OptionMath.isITM(ETH_3100, ETH_3000, false), "Put should be OTM when K < S");
    }

    function test_isITM_put_ATM() public pure {
        // S = K -> put is not ITM (ATM)
        assertFalse(OptionMath.isITM(ETH_3000, ETH_3000, false), "Put should not be ITM when S = K");
    }

    // =========================================================================
    // Intrinsic Value Tests
    // =========================================================================

    function test_intrinsicValue_call_ITM() public pure {
        SD59x18 iv = OptionMath.intrinsicValue(ETH_3100, ETH_3000, true);
        assertEq(SD59x18.unwrap(iv), 100e18, "Call intrinsic value should be 100");
    }

    function test_intrinsicValue_call_OTM() public pure {
        SD59x18 iv = OptionMath.intrinsicValue(ETH_2900, ETH_3000, true);
        assertEq(SD59x18.unwrap(iv), 0, "OTM call has no intrinsic value");
    }

    function test_intrinsicValue_put_ITM() public pure {
        SD59x18 iv = OptionMath.intrinsicValue(ETH_2900, ETH_3000, false);
        assertEq(SD59x18.unwrap(iv), 100e18, "Put intrinsic value should be 100");
    }

    function test_intrinsicValue_put_OTM() public pure {
        SD59x18 iv = OptionMath.intrinsicValue(ETH_3100, ETH_3000, false);
        assertEq(SD59x18.unwrap(iv), 0, "OTM put has no intrinsic value");
    }

    // =========================================================================
    // Time Value Tests
    // =========================================================================

    function test_timeValue_positive() public pure {
        // Premium = 150, Intrinsic = 100 -> Time Value = 50
        SD59x18 premium = sd(150e18);
        SD59x18 intrinsic = sd(100e18);
        SD59x18 tv = OptionMath.timeValue(premium, intrinsic);
        assertEq(SD59x18.unwrap(tv), 50e18, "Time value should be 50");
    }

    function test_timeValue_OTM_option() public pure {
        // OTM option: Premium = 50, Intrinsic = 0 -> Time Value = 50
        SD59x18 premium = sd(50e18);
        SD59x18 tv = OptionMath.timeValue(premium, ZERO);
        assertEq(SD59x18.unwrap(tv), 50e18, "OTM time value equals premium");
    }

    function test_timeValue_atExpiry() public pure {
        // At expiry: Premium = Intrinsic -> Time Value = 0
        SD59x18 value = sd(100e18);
        SD59x18 tv = OptionMath.timeValue(value, value);
        assertEq(SD59x18.unwrap(tv), 0, "At expiry time value should be 0");
    }

    function test_timeValue_floorAtZero() public pure {
        // Edge case: Premium < Intrinsic (shouldn't happen, but handle gracefully)
        SD59x18 premium = sd(50e18);
        SD59x18 intrinsic = sd(100e18);
        SD59x18 tv = OptionMath.timeValue(premium, intrinsic);
        assertEq(SD59x18.unwrap(tv), 0, "Time value floors at 0");
    }
}
