// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { Certoraspec } from "../../src/libraries/Certoraspec.sol";
import { PricingParams, MonotonicityResult } from "../../src/libraries/Certoraspec.sol";

/// @title CertoraspecFuzzTest
/// @notice Fuzz tests for Certoraspec pricing monotonicity invariants
contract CertoraspecFuzzTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    int256 private constant ONE = 1e18;

    // Fuzzing bounds — chosen to avoid extreme d1 values that underflow φ(d1) to zero
    int256 private constant MIN_PRICE = 10e18; // $10
    int256 private constant MAX_PRICE = 100_000e18; // $100,000

    int256 private constant MIN_VOL = 50000000000000000; // 5%
    int256 private constant MAX_VOL = 2_000000000000000000; // 200%

    int256 private constant MIN_RATE = 0;
    int256 private constant MAX_RATE = 200000000000000000; // 20%

    int256 private constant MIN_TIME = 19178082191780822; // ~1 week (7/365)
    int256 private constant MAX_TIME = 2_000000000000000000; // 2 years

    int256 private constant MIN_EPSILON = 100000000000000; // 0.0001
    int256 private constant MAX_EPSILON = 100000000000000000; // 0.1

    // Maximum moneyness ratio to keep d1 in a computable range
    int256 private constant MAX_MONEYNESS_RATIO = 3e18; // strike/spot ≤ 3 and spot/strike ≤ 3

    // ═══════════════════════════════════════════════════════════════════════════
    //                        HELPER: Bound and build params
    // ═══════════════════════════════════════════════════════════════════════════

    function _boundParams(int256 spotRaw, int256 strikeRaw, int256 volRaw, int256 rateRaw, int256 timeRaw)
        private
        pure
        returns (PricingParams memory)
    {
        int256 spot = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        int256 vol = bound(volRaw, MIN_VOL, MAX_VOL);
        int256 rate = bound(rateRaw, MIN_RATE, MAX_RATE);
        int256 time = bound(timeRaw, MIN_TIME, MAX_TIME);

        // Constrain strike so moneyness ratio stays within [1/3, 3]
        int256 minStrike = spot / 3;
        if (minStrike < MIN_PRICE) minStrike = MIN_PRICE;
        int256 maxStrike = spot * 3;
        if (maxStrike > MAX_PRICE) maxStrike = MAX_PRICE;
        int256 strike = bound(strikeRaw, minStrike, maxStrike);

        return PricingParams({
            spot: sd(spot), strike: sd(strike), volatility: sd(vol), riskFreeRate: sd(rate), timeToExpiry: sd(time)
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //     INVARIANT 1: ∂C/∂S > 0 — Call price increases with spot
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Call delta is always positive for valid inputs
    function testFuzz_callDelta_AlwaysPositive(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        SD59x18 delta = Certoraspec.callDelta(p);
        assertTrue(delta.gte(ZERO), "Call delta must be >= 0");
    }

    /// @notice Call price is monotonically non-decreasing in spot
    function testFuzz_callPrice_MonotonicInSpot(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw,
        int256 epsilonRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        int256 maxEps = MAX_PRICE - SD59x18.unwrap(p.spot);
        if (maxEps < MIN_EPSILON) return;
        int256 epsUpper = maxEps < MAX_EPSILON ? maxEps : MAX_EPSILON;
        int256 eps = bound(epsilonRaw, MIN_EPSILON, epsUpper);

        MonotonicityResult memory res = Certoraspec.verifyCallMonotonicInSpot(p, sd(eps));
        assertTrue(res.holds, "Call must be monotonic in spot: C(S+eps) >= C(S)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //     INVARIANT 2: ∂P/∂S < 0 — Put price decreases with spot
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Put delta is always negative for valid inputs
    function testFuzz_putDelta_AlwaysNegative(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        SD59x18 delta = Certoraspec.putDelta(p);
        assertTrue(delta.lte(ZERO), "Put delta must be <= 0");
    }

    /// @notice Put price is monotonically non-increasing in spot
    function testFuzz_putPrice_MonotonicInSpot(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw,
        int256 epsilonRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        // Ensure spot + epsilon doesn't exceed MAX_PRICE (overflow safety)
        int256 maxEps = MAX_PRICE - SD59x18.unwrap(p.spot);
        if (maxEps < MIN_EPSILON) return; // skip if spot is at ceiling
        int256 epsUpper = maxEps < MAX_EPSILON ? maxEps : MAX_EPSILON;
        int256 eps = bound(epsilonRaw, MIN_EPSILON, epsUpper);

        MonotonicityResult memory res = Certoraspec.verifyPutMonotonicInSpot(p, sd(eps));
        assertTrue(res.holds, "Put must be anti-monotonic in spot: P(S+eps) <= P(S)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //     INVARIANT 3: ∂/∂σ > 0 — Vega is positive
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Vega is always non-negative for valid inputs
    function testFuzz_vega_AlwaysNonNegative(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        SD59x18 v = Certoraspec.vega(p);
        assertTrue(v.gte(ZERO), "Vega must be >= 0");
    }

    /// @notice Call price is monotonically non-decreasing in volatility
    function testFuzz_callPrice_MonotonicInVol(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw,
        int256 epsilonRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        int256 maxEps = MAX_VOL - SD59x18.unwrap(p.volatility);
        if (maxEps < MIN_EPSILON) return;
        int256 epsUpper = maxEps < MAX_EPSILON ? maxEps : MAX_EPSILON;
        int256 eps = bound(epsilonRaw, MIN_EPSILON, epsUpper);

        MonotonicityResult memory res = Certoraspec.verifyCallMonotonicInVol(p, sd(eps));
        assertTrue(res.holds, "Call must be monotonic in vol: C(sigma+eps) >= C(sigma)");
    }

    /// @notice Put price is monotonically non-decreasing in volatility
    function testFuzz_putPrice_MonotonicInVol(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw,
        int256 epsilonRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        int256 maxEps = MAX_VOL - SD59x18.unwrap(p.volatility);
        if (maxEps < MIN_EPSILON) return;
        int256 epsUpper = maxEps < MAX_EPSILON ? maxEps : MAX_EPSILON;
        int256 eps = bound(epsilonRaw, MIN_EPSILON, epsUpper);

        MonotonicityResult memory res = Certoraspec.verifyPutMonotonicInVol(p, sd(eps));
        assertTrue(res.holds, "Put must be monotonic in vol: P(sigma+eps) >= P(sigma)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //     COMPOSITE: All three invariants hold simultaneously
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice All three pricing monotonicity invariants hold for any valid input
    function testFuzz_allInvariants_Hold(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw,
        int256 epsilonRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        // Epsilon must fit both spot bump and vol bump
        int256 maxSpotEps = MAX_PRICE - SD59x18.unwrap(p.spot);
        int256 maxVolEps = MAX_VOL - SD59x18.unwrap(p.volatility);
        int256 maxEps = maxSpotEps < maxVolEps ? maxSpotEps : maxVolEps;
        if (maxEps < MIN_EPSILON) return;
        int256 epsUpper = maxEps < MAX_EPSILON ? maxEps : MAX_EPSILON;
        int256 eps = bound(epsilonRaw, MIN_EPSILON, epsUpper);

        (bool callOk, bool putOk, bool vegaOk) = Certoraspec.verifyAllInvariants(p, sd(eps));
        assertTrue(callOk, "Call spot monotonicity must hold");
        assertTrue(putOk, "Put spot monotonicity must hold");
        assertTrue(vegaOk, "Vega monotonicity must hold");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //     DELTA BOUNDS: Call delta ∈ (0,1), Put delta ∈ (-1,0)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Call delta is always in [0, 1]
    function testFuzz_callDelta_BoundedZeroOne(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        SD59x18 delta = Certoraspec.callDelta(p);
        assertTrue(delta.gte(ZERO), "Call delta must be >= 0");
        assertTrue(delta.lte(sd(ONE)), "Call delta must be <= 1");
    }

    /// @notice Put delta is always in [-1, 0]
    function testFuzz_putDelta_BoundedNegOneZero(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        SD59x18 delta = Certoraspec.putDelta(p);
        assertTrue(delta.gte(sd(-ONE)), "Put delta must be >= -1");
        assertTrue(delta.lte(ZERO), "Put delta must be <= 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //     GAMMA POSITIVITY: Γ ≥ 0
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gamma is always non-negative
    function testFuzz_gamma_AlwaysNonNegative(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        SD59x18 g = Certoraspec.gamma(p);
        assertTrue(g.gte(ZERO), "Gamma must be >= 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //     PUT-CALL PARITY: C - P = S - K * e^(-rT)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Put-call parity holds within tolerance for all valid inputs
    function testFuzz_putCallParity_Holds(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);

        // Use a relative tolerance: 0.1% of spot price
        int256 toleranceRaw = SD59x18.unwrap(p.spot) / 1000;
        if (toleranceRaw < 1e15) toleranceRaw = 1e15; // floor at 0.001

        (bool holds,) = Certoraspec.verifyPutCallParity(p, sd(toleranceRaw));
        assertTrue(holds, "Put-call parity must hold within 0.1% tolerance");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //     PRICE NON-NEGATIVITY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Call price is always non-negative
    function testFuzz_callPrice_NonNegative(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        SD59x18 price = Certoraspec.priceCall(p);
        assertTrue(price.gte(ZERO), "Call price must be >= 0");
    }

    /// @notice Put price is always non-negative
    function testFuzz_putPrice_NonNegative(
        int256 spotRaw,
        int256 strikeRaw,
        int256 volRaw,
        int256 rateRaw,
        int256 timeRaw
    ) public pure {
        PricingParams memory p = _boundParams(spotRaw, strikeRaw, volRaw, rateRaw, timeRaw);
        SD59x18 price = Certoraspec.pricePut(p);
        assertTrue(price.gte(ZERO), "Put price must be >= 0");
    }
}
