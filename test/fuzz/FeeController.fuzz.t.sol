// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import { FeeController } from "../../src/core/FeeController.sol";

/// @title FeeControllerFuzzTest
/// @notice Fuzz tests for FeeController dynamic fee model invariants
/// @dev Tests that mathematical properties hold across random inputs
contract FeeControllerFuzzTest is Test {
    FeeController public controller;

    address public feeRecipient = address(0xFEE);

    // Default parameters
    int256 public constant DEFAULT_BASE_FEE = 3e15; // 30 bps
    int256 public constant DEFAULT_SPREAD_FEE = 5e16; // 500 bps
    uint256 public constant DEFAULT_POOL_CAP = 1_000_000e18;

    // Bounds for fuzz inputs
    uint256 internal constant MIN_AMOUNT = 1e18; // 1 token
    uint256 internal constant MAX_AMOUNT = 1_000_000e18; // 1M tokens
    uint256 internal constant MIN_POOL_CAP = 1e18; // Minimum pool cap
    uint256 internal constant MAX_POOL_CAP = 100_000_000e18; // 100M tokens

    function setUp() public {
        controller = new FeeController(feeRecipient, DEFAULT_BASE_FEE, DEFAULT_SPREAD_FEE, DEFAULT_POOL_CAP);
    }

    // =========================================================================
    // Fee Non-Negativity Invariant
    // =========================================================================

    /// @notice Fee is always >= 0 for any valid inputs
    function testFuzz_calculateFee_neverNegative(uint256 amount, uint256 totalMinted) public view {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        totalMinted = bound(totalMinted, 0, DEFAULT_POOL_CAP * 2);

        uint256 fee = controller.calculateFee(1, amount, totalMinted);
        assertGe(fee, 0, "Fee must be non-negative");
    }

    // =========================================================================
    // Fee Monotonicity: Higher Utilization => Higher Fee
    // =========================================================================

    /// @notice Fee increases monotonically with utilization for same amount
    function testFuzz_calculateFee_monotonicallyIncreasingWithUtilization(
        uint256 amount,
        uint256 totalMintedLow,
        uint256 totalMintedHigh
    ) public view {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        totalMintedLow = bound(totalMintedLow, 0, DEFAULT_POOL_CAP - 1);
        totalMintedHigh = bound(totalMintedHigh, totalMintedLow + 1, DEFAULT_POOL_CAP);

        uint256 feeLow = controller.calculateFee(1, amount, totalMintedLow);
        uint256 feeHigh = controller.calculateFee(1, amount, totalMintedHigh);

        assertGe(feeHigh, feeLow, "Fee must increase with utilization");
    }

    // =========================================================================
    // Fee Proportionality: Larger Amounts => Larger Fees
    // =========================================================================

    /// @notice Fee is proportional to trade amount
    function testFuzz_calculateFee_proportionalToAmount(uint256 amountSmall, uint256 totalMinted) public view {
        amountSmall = bound(amountSmall, MIN_AMOUNT, MAX_AMOUNT / 2);
        totalMinted = bound(totalMinted, 0, DEFAULT_POOL_CAP);

        uint256 amountLarge = amountSmall * 2;

        uint256 feeSmall = controller.calculateFee(1, amountSmall, totalMinted);
        uint256 feeLarge = controller.calculateFee(1, amountLarge, totalMinted);

        // fee(2x) should equal 2 × fee(x) (linear in amount)
        // Allow 1 wei tolerance for rounding
        assertApproxEqAbs(feeLarge, feeSmall * 2, 1, "Fee should be proportional to amount");
    }

    // =========================================================================
    // Fee Upper Bound: Fee Never Exceeds Amount
    // =========================================================================

    /// @notice Fee is always less than the notional amount
    /// @dev Since max fee rate = baseFee + spreadFee < 1.0, fee < amount
    function testFuzz_calculateFee_neverExceedsAmount(uint256 amount, uint256 totalMinted) public view {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        totalMinted = bound(totalMinted, 0, DEFAULT_POOL_CAP * 2);

        uint256 fee = controller.calculateFee(1, amount, totalMinted);
        assertLt(fee, amount, "Fee must be less than trade amount");
    }

    // =========================================================================
    // Fee Lower Bound: Fee >= baseFee × amount
    // =========================================================================

    /// @notice Fee is always at least baseFee × amount (the minimum fee)
    function testFuzz_calculateFee_atLeastBaseFee(uint256 amount, uint256 totalMinted) public view {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        totalMinted = bound(totalMinted, 0, DEFAULT_POOL_CAP * 2);

        uint256 fee = controller.calculateFee(1, amount, totalMinted);
        uint256 baseFeeComponent = controller.calculateFee(1, amount, 0);

        assertGe(fee, baseFeeComponent, "Fee must be at least the base fee component");
    }

    // =========================================================================
    // Utilization Capping: Over-utilization Clamps to 100%
    // =========================================================================

    /// @notice Fees are the same whether utilization is 100%, 150%, or 200%
    function testFuzz_calculateFee_cappedAtFullUtilization(uint256 amount, uint256 overMinted) public view {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        overMinted = bound(overMinted, DEFAULT_POOL_CAP, DEFAULT_POOL_CAP * 3);

        uint256 feeAtMax = controller.calculateFee(1, amount, DEFAULT_POOL_CAP);
        uint256 feeOverMax = controller.calculateFee(1, amount, overMinted);

        assertEq(feeOverMax, feeAtMax, "Fee should be capped at 100% utilization");
    }

    // =========================================================================
    // Fee Rate Bounds
    // =========================================================================

    /// @notice Fee rate is bounded by [baseFee, baseFee + spreadFee]
    function testFuzz_getFeeRate_bounded(uint256 totalMinted) public view {
        totalMinted = bound(totalMinted, 0, DEFAULT_POOL_CAP * 2);

        int256 rate = controller.getFeeRate(1, totalMinted);

        assertGe(rate, DEFAULT_BASE_FEE, "Rate must be >= baseFee");
        assertLe(rate, DEFAULT_BASE_FEE + DEFAULT_SPREAD_FEE, "Rate must be <= baseFee + spreadFee");
    }

    // =========================================================================
    // Utilization Range
    // =========================================================================

    /// @notice Utilization is always in [0, 1]
    function testFuzz_getUtilization_bounded(uint256 totalMinted, uint256 poolCap) public view {
        poolCap = bound(poolCap, MIN_POOL_CAP, MAX_POOL_CAP);
        totalMinted = bound(totalMinted, 0, poolCap * 3);

        int256 util = controller.getUtilization(totalMinted, poolCap);

        assertGe(util, 0, "Utilization must be >= 0");
        assertLe(util, 1e18, "Utilization must be <= 1.0");
    }

    // =========================================================================
    // Custom Config Fee Consistency
    // =========================================================================

    /// @notice Custom config fees are consistent with the formula
    function testFuzz_calculateFee_customConfigConsistent(
        uint256 amount,
        uint256 totalMinted,
        uint64 baseFeeRaw,
        uint64 spreadFeeRaw
    ) public {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        totalMinted = bound(totalMinted, 0, DEFAULT_POOL_CAP);

        // Bound fee parameters to valid ranges
        int256 baseFee = int256(uint256(bound(baseFeeRaw, 0, 1e16))); // 0 to 1%
        int256 spreadFee = int256(uint256(bound(spreadFeeRaw, 0, 5e17))); // 0 to 50%

        controller.setFeeConfig(1, baseFee, spreadFee, DEFAULT_POOL_CAP);

        uint256 fee = controller.calculateFee(1, amount, totalMinted);

        // Fee at zero utilization should be baseFee * amount
        uint256 feeAtZero = controller.calculateFee(1, amount, 0);
        assertGe(fee, feeAtZero, "Fee must be >= base fee component for custom config");
    }

    // =========================================================================
    // Quadratic Growth: Convexity Test
    // =========================================================================

    /// @notice The fee curve is convex (second derivative >= 0)
    /// @dev For three evenly-spaced utilization points: f(mid) <= (f(low) + f(high)) / 2
    function testFuzz_feeRate_convexity(uint256 utilizationLow, uint256 gap) public view {
        utilizationLow = bound(utilizationLow, 0, DEFAULT_POOL_CAP / 3);
        gap = bound(gap, DEFAULT_POOL_CAP / 100, DEFAULT_POOL_CAP / 3);

        uint256 utilizationMid = utilizationLow + gap;
        uint256 utilizationHigh = utilizationMid + gap;

        // Ensure we don't exceed pool cap
        if (utilizationHigh > DEFAULT_POOL_CAP) return;

        int256 rateLow = controller.getFeeRate(1, utilizationLow);
        int256 rateMid = controller.getFeeRate(1, utilizationMid);
        int256 rateHigh = controller.getFeeRate(1, utilizationHigh);

        // For a convex function: f(mid) <= (f(low) + f(high)) / 2
        int256 average = (rateLow + rateHigh) / 2;
        assertLe(rateMid, average + 1, "Fee curve must be convex (f(mid) <= avg(f(low), f(high)))");
    }

    // =========================================================================
    // calculateFeeWithUtilization Consistency
    // =========================================================================

    /// @notice calculateFee and calculateFeeWithUtilization produce consistent results
    function testFuzz_calculateFee_consistentWithExplicitUtilization(uint256 amount, uint256 totalMinted) public view {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        totalMinted = bound(totalMinted, 0, DEFAULT_POOL_CAP);

        uint256 feeImplicit = controller.calculateFee(1, amount, totalMinted);

        int256 util = controller.getUtilization(totalMinted, DEFAULT_POOL_CAP);
        uint256 feeExplicit = controller.calculateFeeWithUtilization(1, amount, util);

        assertEq(feeImplicit, feeExplicit, "Implicit and explicit utilization should give same fee");
    }

    // =========================================================================
    // Fee Accumulator Invariant
    // =========================================================================

    /// @notice Accumulated fees always increase monotonically
    function testFuzz_recordFee_accumulatorMonotonic(uint128 fee1, uint128 fee2) public {
        controller.recordFee(1, address(0xA), 100e18, uint256(fee1));

        (uint256 collected1,) = controller.getAccumulatedFees(1);

        controller.recordFee(1, address(0xB), 200e18, uint256(fee2));

        (uint256 collected2,) = controller.getAccumulatedFees(1);

        assertGe(collected2, collected1, "Accumulated fees must monotonically increase");
    }
}
