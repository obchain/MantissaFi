// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    AddAmericanstyleoptionsupport,
    AmericanOptionParams,
    AmericanOptionResult,
    LatticeConfig
} from "../../src/libraries/AddAmericanstyleoptionsupport.sol";

/// @title AddAmericanstyleoptionsupportFuzzTest
/// @notice Fuzz tests for American option pricing invariants
/// @dev Tests mathematical properties that must hold across all valid inputs
contract AddAmericanstyleoptionsupportFuzzTest is Test {
    // Realistic bounds for option parameters
    // NOTE: Bounds are chosen to satisfy the CRR stability condition σ√(Δt) > r·Δt,
    // which ensures the risk-neutral probability p stays in (0, 1).
    uint256 internal constant MIN_PRICE = 1; // $1
    uint256 internal constant MAX_PRICE = 100_000; // $100k
    uint256 internal constant MIN_VOL_BPS = 10; // 10% volatility
    uint256 internal constant MAX_VOL_BPS = 200; // 200% volatility
    uint256 internal constant MIN_RATE_BPS = 0; // 0% rate
    uint256 internal constant MAX_RATE_BPS = 10; // 10% rate
    uint256 internal constant MIN_TIME_DAYS = 1; // 1 day
    uint256 internal constant MAX_TIME_DAYS = 365; // 1 year

    uint256 internal constant STEPS = 8; // Keep low for gas efficiency in fuzz runs

    function _boundParams(uint256 spotRaw, uint256 strikeRaw, uint256 volBps, uint256 rateBps, uint256 timeDays)
        internal
        pure
        returns (AmericanOptionParams memory p)
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        volBps = bound(volBps, MIN_VOL_BPS, MAX_VOL_BPS);
        rateBps = bound(rateBps, MIN_RATE_BPS, MAX_RATE_BPS);
        timeDays = bound(timeDays, MIN_TIME_DAYS, MAX_TIME_DAYS);

        p = AmericanOptionParams({
            spot: sd(int256(spotRaw) * 1e18),
            strike: sd(int256(strikeRaw) * 1e18),
            volatility: sd(int256(volBps) * 1e16), // volBps / 100 in 18 decimals
            riskFreeRate: sd(int256(rateBps) * 1e16), // rateBps / 100 in 18 decimals
            timeToExpiry: sd(int256(timeDays) * 1e18 / 365) // convert days to years
        });
    }

    // =========================================================================
    // Invariant: American option price >= 0
    // =========================================================================

    /// @notice American call price is always non-negative
    function testFuzz_priceCall_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.priceCallWithSteps(p, STEPS);
        assertGe(SD59x18.unwrap(result.price), 0, "American call price must be >= 0");
    }

    /// @notice American put price is always non-negative
    function testFuzz_pricePut_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.pricePutWithSteps(p, STEPS);
        assertGe(SD59x18.unwrap(result.price), 0, "American put price must be >= 0");
    }

    // =========================================================================
    // Invariant: American price >= European price
    // =========================================================================

    /// @notice American call is always worth at least as much as European call
    function testFuzz_priceCall_americanGeEuropean(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.priceCallWithSteps(p, STEPS);
        SD59x18 europeanPrice = AddAmericanstyleoptionsupport.priceEuropean(p, true, STEPS);

        assertGe(SD59x18.unwrap(result.price), SD59x18.unwrap(europeanPrice), "American call >= European call");
    }

    /// @notice American put is always worth at least as much as European put
    function testFuzz_pricePut_americanGeEuropean(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.pricePutWithSteps(p, STEPS);
        SD59x18 europeanPrice = AddAmericanstyleoptionsupport.priceEuropean(p, false, STEPS);

        assertGe(SD59x18.unwrap(result.price), SD59x18.unwrap(europeanPrice), "American put >= European put");
    }

    // =========================================================================
    // Invariant: American price >= intrinsic value
    // =========================================================================

    /// @notice American call price is always at least the intrinsic value
    function testFuzz_priceCall_geIntrinsic(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.priceCallWithSteps(p, STEPS);
        SD59x18 intrinsic = AddAmericanstyleoptionsupport.exerciseValue(p.spot, p.strike, true);

        assertGe(SD59x18.unwrap(result.price), SD59x18.unwrap(intrinsic), "American call >= intrinsic value");
    }

    /// @notice American put price is always at least the intrinsic value
    function testFuzz_pricePut_geIntrinsic(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.pricePutWithSteps(p, STEPS);
        SD59x18 intrinsic = AddAmericanstyleoptionsupport.exerciseValue(p.spot, p.strike, false);

        assertGe(SD59x18.unwrap(result.price), SD59x18.unwrap(intrinsic), "American put >= intrinsic value");
    }

    // =========================================================================
    // Invariant: Early exercise premium >= 0
    // =========================================================================

    /// @notice Early exercise premium is always non-negative
    function testFuzz_earlyExercisePremium_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);

        AmericanOptionResult memory callResult = AddAmericanstyleoptionsupport.priceCallWithSteps(p, STEPS);
        AmericanOptionResult memory putResult = AddAmericanstyleoptionsupport.pricePutWithSteps(p, STEPS);

        assertGe(SD59x18.unwrap(callResult.earlyExercisePremium), 0, "Call early exercise premium >= 0");
        assertGe(SD59x18.unwrap(putResult.earlyExercisePremium), 0, "Put early exercise premium >= 0");
    }

    // =========================================================================
    // Invariant: CRR lattice u * d = 1
    // =========================================================================

    /// @notice Up factor times down factor equals 1 (CRR recombining property)
    function testFuzz_lattice_udProduct(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);
        LatticeConfig memory cfg = AddAmericanstyleoptionsupport.buildLattice(p, STEPS);

        SD59x18 product = cfg.u.mul(cfg.d);
        assertApproxEqRel(SD59x18.unwrap(product), 1e18, 1e14, "u * d must equal 1");
    }

    // =========================================================================
    // Invariant: Call delta in [0, 1], Put delta in [-1, 0]
    // =========================================================================

    /// @notice Call delta should be in [0, 1]
    function testFuzz_callDelta_bounds(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.priceCallWithSteps(p, STEPS);

        // Delta is computed from finite differences and can have numerical edge cases,
        // so use a small tolerance band
        assertGe(SD59x18.unwrap(result.delta), -1e16, "Call delta should be >= ~0");
        assertLe(SD59x18.unwrap(result.delta), 1e18 + 1e16, "Call delta should be <= ~1");
    }

    /// @notice Put delta should be in [-1, 0]
    function testFuzz_putDelta_bounds(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);
        AmericanOptionResult memory result = AddAmericanstyleoptionsupport.pricePutWithSteps(p, STEPS);

        assertGe(SD59x18.unwrap(result.delta), -1e18 - 1e16, "Put delta should be >= ~-1");
        assertLe(SD59x18.unwrap(result.delta), 1e16, "Put delta should be <= ~0");
    }

    // =========================================================================
    // Invariant: Monotonicity — call price increases with spot
    // =========================================================================

    /// @notice Call price increases when spot increases (positive delta)
    function testFuzz_priceCall_monotoneInSpot(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE - 1);
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);

        AmericanOptionResult memory r1 = AddAmericanstyleoptionsupport.priceCallWithSteps(p, STEPS);

        // Bump spot up by $1
        p.spot = p.spot.add(sd(1e18));
        AmericanOptionResult memory r2 = AddAmericanstyleoptionsupport.priceCallWithSteps(p, STEPS);

        assertGe(SD59x18.unwrap(r2.price), SD59x18.unwrap(r1.price), "Call price should increase with spot");
    }

    // =========================================================================
    // Invariant: Monotonicity — put price decreases with spot
    // =========================================================================

    /// @notice Put price decreases when spot increases (negative delta)
    function testFuzz_pricePut_monotoneInSpot(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volBps,
        uint256 rateBps,
        uint256 timeDays
    ) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE - 1);
        AmericanOptionParams memory p = _boundParams(spotRaw, strikeRaw, volBps, rateBps, timeDays);

        AmericanOptionResult memory r1 = AddAmericanstyleoptionsupport.pricePutWithSteps(p, STEPS);

        // Bump spot up by $1
        p.spot = p.spot.add(sd(1e18));
        AmericanOptionResult memory r2 = AddAmericanstyleoptionsupport.pricePutWithSteps(p, STEPS);

        assertLe(SD59x18.unwrap(r2.price), SD59x18.unwrap(r1.price), "Put price should decrease with spot");
    }

    // =========================================================================
    // Invariant: Exercise value consistency
    // =========================================================================

    /// @notice Exercise value for call + exercise value for put = |S - K|
    function testFuzz_exerciseValue_callPutSum(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);

        SD59x18 spot = sd(int256(spotRaw) * 1e18);
        SD59x18 strike = sd(int256(strikeRaw) * 1e18);

        SD59x18 callVal = AddAmericanstyleoptionsupport.exerciseValue(spot, strike, true);
        SD59x18 putVal = AddAmericanstyleoptionsupport.exerciseValue(spot, strike, false);

        int256 spotStrikeDiff = int256(spotRaw) * 1e18 - int256(strikeRaw) * 1e18;
        int256 absDiff = spotStrikeDiff >= 0 ? spotStrikeDiff : -spotStrikeDiff;

        int256 sum = SD59x18.unwrap(callVal) + SD59x18.unwrap(putVal);
        assertEq(sum, absDiff, "Call exercise + put exercise = |S - K|");
    }
}
