// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    HestonModel,
    HestonParams,
    HestonResult
} from "../../src/libraries/ExploreHestonstochasticvolatilitymodelextension.sol";

/// @title ExploreHestonstochasticvolatilitymodelextensionFuzzTest
/// @notice Fuzz tests for HestonModel library invariants
/// @dev Tests mathematical properties that must hold across all valid parameter ranges
contract ExploreHestonstochasticvolatilitymodelextensionFuzzTest is Test {
    // =========================================================================
    // Helpers
    // =========================================================================

    /// @notice Constructs bounded Heston parameters from fuzz inputs
    /// @dev Bounds are chosen to avoid numerical overflow in fixed-point arithmetic
    function _boundParams(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 timeRaw,
        uint256 v0Raw,
        uint256 thetaRaw,
        uint256 kappaRaw,
        uint256 xiRaw,
        uint256 rhoRaw
    ) internal pure returns (HestonParams memory p) {
        // Spot and strike: $10 to $100,000
        spotRaw = bound(spotRaw, 10, 100_000);
        strikeRaw = bound(strikeRaw, 10, 100_000);

        // Time to expiry: 1 day to 2 years (in SD59x18 year fractions)
        // 1/365 ≈ 0.00274 to 2.0
        timeRaw = bound(timeRaw, 2_739_726_027_397_260, 2e18);

        // Variance v0: 0.01 (10% vol) to 1.0 (100% vol)
        v0Raw = bound(v0Raw, 1e16, 1e18);

        // Long-run variance theta: 0.01 to 1.0
        thetaRaw = bound(thetaRaw, 1e16, 1e18);

        // Mean-reversion speed kappa: 0.1 to 10.0
        kappaRaw = bound(kappaRaw, 1e17, 10e18);

        // Vol-of-vol xi: 0.1 to 2.0
        xiRaw = bound(xiRaw, 1e17, 2e18);

        // Correlation rho: -0.99 to 0.99 (avoid exact -1, 1 for numerical stability)
        rhoRaw = bound(rhoRaw, 0, 198);
        int256 rhoInt = int256(rhoRaw) - 99; // maps to [-99, 99]

        p.spot = sd(int256(spotRaw * 1e18));
        p.strike = sd(int256(strikeRaw * 1e18));
        p.riskFreeRate = sd(50000000000000000); // fixed at 5% for stability
        p.timeToExpiry = SD59x18.wrap(int256(timeRaw));
        p.v0 = SD59x18.wrap(int256(v0Raw));
        p.theta = SD59x18.wrap(int256(thetaRaw));
        p.kappa = SD59x18.wrap(int256(kappaRaw));
        p.xi = SD59x18.wrap(int256(xiRaw));
        p.rho = sd(rhoInt * 1e16); // maps to [-0.99, 0.99]
    }

    // =========================================================================
    // Invariant: Call price is non-negative
    // =========================================================================

    /// @notice Call price must always be >= 0 for any valid parameters
    function testFuzz_callPrice_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 timeRaw,
        uint256 v0Raw,
        uint256 thetaRaw,
        uint256 kappaRaw,
        uint256 xiRaw,
        uint256 rhoRaw
    ) public pure {
        HestonParams memory p = _boundParams(spotRaw, strikeRaw, timeRaw, v0Raw, thetaRaw, kappaRaw, xiRaw, rhoRaw);
        SD59x18 price = HestonModel.priceCall(p);
        assertGe(SD59x18.unwrap(price), 0, "Call price must be >= 0");
    }

    // =========================================================================
    // Invariant: Put price is non-negative
    // =========================================================================

    /// @notice Put price must always be >= 0 for any valid parameters
    function testFuzz_putPrice_neverNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 timeRaw,
        uint256 v0Raw,
        uint256 thetaRaw,
        uint256 kappaRaw,
        uint256 xiRaw,
        uint256 rhoRaw
    ) public pure {
        HestonParams memory p = _boundParams(spotRaw, strikeRaw, timeRaw, v0Raw, thetaRaw, kappaRaw, xiRaw, rhoRaw);
        SD59x18 price = HestonModel.pricePut(p);
        assertGe(SD59x18.unwrap(price), 0, "Put price must be >= 0");
    }

    // =========================================================================
    // Invariant: Call price ≤ Spot (upper bound)
    // =========================================================================

    /// @notice Call price can never exceed the spot price
    function testFuzz_callPrice_boundedBySpot(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 timeRaw,
        uint256 v0Raw,
        uint256 thetaRaw,
        uint256 kappaRaw,
        uint256 xiRaw,
        uint256 rhoRaw
    ) public pure {
        HestonParams memory p = _boundParams(spotRaw, strikeRaw, timeRaw, v0Raw, thetaRaw, kappaRaw, xiRaw, rhoRaw);
        SD59x18 price = HestonModel.priceCall(p);
        assertLe(SD59x18.unwrap(price), SD59x18.unwrap(p.spot), "Call price must be <= spot");
    }

    // =========================================================================
    // Invariant: Put price ≤ K·e^(-rT) (discounted strike)
    // =========================================================================

    /// @notice Put price can never exceed the discounted strike price
    function testFuzz_putPrice_boundedByDiscountedStrike(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 timeRaw,
        uint256 v0Raw,
        uint256 thetaRaw,
        uint256 kappaRaw,
        uint256 xiRaw,
        uint256 rhoRaw
    ) public pure {
        HestonParams memory p = _boundParams(spotRaw, strikeRaw, timeRaw, v0Raw, thetaRaw, kappaRaw, xiRaw, rhoRaw);
        SD59x18 price = HestonModel.pricePut(p);
        SD59x18 discountedStrike = p.strike.mul(p.riskFreeRate.mul(p.timeToExpiry).mul(sd(-1e18)).exp());
        // Allow tiny numerical tolerance (1 wei per dollar)
        assertLe(
            SD59x18.unwrap(price), SD59x18.unwrap(discountedStrike) + 1e18, "Put price must be <= discounted strike"
        );
    }

    // =========================================================================
    // Invariant: Feller ratio is always positive
    // =========================================================================

    /// @notice Feller ratio 2κθ/ξ² is always positive for positive parameters
    function testFuzz_fellerRatio_alwaysPositive(uint256 kappaRaw, uint256 thetaRaw, uint256 xiRaw) public pure {
        kappaRaw = bound(kappaRaw, 1e17, 10e18);
        thetaRaw = bound(thetaRaw, 1e16, 1e18);
        xiRaw = bound(xiRaw, 1e17, 2e18);

        HestonParams memory p;
        p.spot = sd(3000e18);
        p.strike = sd(3000e18);
        p.riskFreeRate = sd(50000000000000000);
        p.timeToExpiry = sd(250000000000000000);
        p.v0 = sd(40000000000000000);
        p.theta = SD59x18.wrap(int256(thetaRaw));
        p.kappa = SD59x18.wrap(int256(kappaRaw));
        p.xi = SD59x18.wrap(int256(xiRaw));
        p.rho = sd(-500000000000000000);

        SD59x18 ratio = HestonModel.fellerRatio(p);
        assertGt(SD59x18.unwrap(ratio), 0, "Feller ratio must be positive");
    }

    // =========================================================================
    // Invariant: Expected variance is between v0 and theta
    // =========================================================================

    /// @notice Expected variance at expiry is always between v₀ and θ (or equal to both)
    function testFuzz_expectedVariance_bounded(uint256 v0Raw, uint256 thetaRaw, uint256 kappaRaw, uint256 timeRaw)
        public
        pure
    {
        v0Raw = bound(v0Raw, 1e16, 1e18);
        thetaRaw = bound(thetaRaw, 1e16, 1e18);
        kappaRaw = bound(kappaRaw, 1e17, 10e18);
        timeRaw = bound(timeRaw, 2_739_726_027_397_260, 2e18);

        HestonParams memory p;
        p.spot = sd(3000e18);
        p.strike = sd(3000e18);
        p.riskFreeRate = sd(50000000000000000);
        p.timeToExpiry = SD59x18.wrap(int256(timeRaw));
        p.v0 = SD59x18.wrap(int256(v0Raw));
        p.theta = SD59x18.wrap(int256(thetaRaw));
        p.kappa = SD59x18.wrap(int256(kappaRaw));
        p.xi = sd(300000000000000000);
        p.rho = sd(-500000000000000000);

        SD59x18 ev = HestonModel.expectedVariance(p);
        int256 evRaw = SD59x18.unwrap(ev);

        // Expected variance should be between min(v0, theta) and max(v0, theta)
        int256 lower = int256(v0Raw) < int256(thetaRaw) ? int256(v0Raw) : int256(thetaRaw);
        int256 upper = int256(v0Raw) > int256(thetaRaw) ? int256(v0Raw) : int256(thetaRaw);

        assertGe(evRaw, lower - 1e10, "Expected variance < min(v0, theta)");
        assertLe(evRaw, upper + 1e10, "Expected variance > max(v0, theta)");
    }

    // =========================================================================
    // Invariant: Average expected variance is between v0 and theta
    // =========================================================================

    /// @notice Average expected variance lies between v₀ and θ
    function testFuzz_avgExpectedVariance_bounded(uint256 v0Raw, uint256 thetaRaw, uint256 kappaRaw, uint256 timeRaw)
        public
        pure
    {
        v0Raw = bound(v0Raw, 1e16, 1e18);
        thetaRaw = bound(thetaRaw, 1e16, 1e18);
        kappaRaw = bound(kappaRaw, 1e17, 10e18);
        timeRaw = bound(timeRaw, 2_739_726_027_397_260, 2e18);

        HestonParams memory p;
        p.spot = sd(3000e18);
        p.strike = sd(3000e18);
        p.riskFreeRate = sd(50000000000000000);
        p.timeToExpiry = SD59x18.wrap(int256(timeRaw));
        p.v0 = SD59x18.wrap(int256(v0Raw));
        p.theta = SD59x18.wrap(int256(thetaRaw));
        p.kappa = SD59x18.wrap(int256(kappaRaw));
        p.xi = sd(300000000000000000);
        p.rho = sd(-500000000000000000);

        SD59x18 avgVar = HestonModel.averageExpectedVariance(p);
        int256 avgVarRaw = SD59x18.unwrap(avgVar);

        int256 lower = int256(v0Raw) < int256(thetaRaw) ? int256(v0Raw) : int256(thetaRaw);
        int256 upper = int256(v0Raw) > int256(thetaRaw) ? int256(v0Raw) : int256(thetaRaw);

        assertGe(avgVarRaw, lower - 1e10, "Avg expected variance < min(v0, theta)");
        assertLe(avgVarRaw, upper + 1e10, "Avg expected variance > max(v0, theta)");
    }

    // =========================================================================
    // Invariant: Call delta ∈ [0, 1]
    // =========================================================================

    /// @notice Call delta must be in [0, 1] for all valid parameters
    function testFuzz_callDelta_inUnitInterval(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 timeRaw,
        uint256 v0Raw,
        uint256 thetaRaw,
        uint256 kappaRaw,
        uint256 xiRaw,
        uint256 rhoRaw
    ) public pure {
        HestonParams memory p = _boundParams(spotRaw, strikeRaw, timeRaw, v0Raw, thetaRaw, kappaRaw, xiRaw, rhoRaw);
        SD59x18 delta = HestonModel.callDelta(p);
        int256 deltaRaw = SD59x18.unwrap(delta);
        assertGe(deltaRaw, 0, "Call delta must be >= 0");
        assertLe(deltaRaw, 1e18, "Call delta must be <= 1");
    }

    // =========================================================================
    // Invariant: Call price increases with spot (weak monotonicity)
    // =========================================================================

    /// @notice Call price is weakly monotonically increasing in spot price
    /// @dev Tests near-ATM options where the quadrature is most accurate.
    ///      The spot prices are kept within ±25% of the strike to ensure
    ///      the integrand is well-behaved for 8-point Gauss-Legendre.
    function testFuzz_callPrice_monotoneInSpot(uint256 spotBps1, uint256 spotBps2) public pure {
        // Spot as percentage of a fixed strike=$3000: 75%-125%
        spotBps1 = bound(spotBps1, 7500, 12500);
        spotBps2 = bound(spotBps2, 7500, 12500);

        SD59x18 strike = sd(3000e18);

        HestonParams memory p1;
        p1.spot = sd(int256(spotBps1 * 3e17)); // spotBps * 3000 / 10000 in 1e18
        p1.strike = strike;
        p1.riskFreeRate = sd(50000000000000000);
        p1.timeToExpiry = sd(250000000000000000);
        p1.v0 = sd(40000000000000000);
        p1.theta = sd(40000000000000000);
        p1.kappa = sd(2000000000000000000);
        p1.xi = sd(300000000000000000);
        p1.rho = sd(-500000000000000000);

        HestonParams memory p2;
        p2.spot = sd(int256(spotBps2 * 3e17));
        p2.strike = strike;
        p2.riskFreeRate = p1.riskFreeRate;
        p2.timeToExpiry = p1.timeToExpiry;
        p2.v0 = p1.v0;
        p2.theta = p1.theta;
        p2.kappa = p1.kappa;
        p2.xi = p1.xi;
        p2.rho = p1.rho;

        // Ensure p2.spot >= p1.spot
        if (SD59x18.unwrap(p1.spot) > SD59x18.unwrap(p2.spot)) {
            (p1.spot, p2.spot) = (p2.spot, p1.spot);
        }

        SD59x18 price1 = HestonModel.priceCall(p1);
        SD59x18 price2 = HestonModel.priceCall(p2);

        // Tolerance: 1% of strike to account for quadrature noise
        int256 tolerance = 30e18; // $30 tolerance for $3000 underlying
        assertGe(SD59x18.unwrap(price2) + tolerance, SD59x18.unwrap(price1), "Call price should be monotone in spot");
    }

    // =========================================================================
    // Invariant: Put-call parity (approximate)
    // =========================================================================

    /// @notice Put-call parity: C − P ≈ S − K·e^(−rT) within tolerance
    /// @dev Put-call parity is exact for the Heston model in theory, but
    ///      numerical quadrature introduces approximation error. We restrict
    ///      to near-money options where quadrature is most accurate.
    function testFuzz_putCallParity(uint256 spotRaw, uint256 strikeRaw) public pure {
        // Near-money options: strike within ±30% of spot for best quadrature accuracy
        spotRaw = bound(spotRaw, 2500, 4000);
        strikeRaw = bound(strikeRaw, 2500, 4000);

        HestonParams memory p;
        p.spot = sd(int256(spotRaw * 1e18));
        p.strike = sd(int256(strikeRaw * 1e18));
        p.riskFreeRate = sd(50000000000000000); // 5%
        p.timeToExpiry = sd(250000000000000000); // 0.25 years
        p.v0 = sd(40000000000000000); // 0.04
        p.theta = sd(40000000000000000);
        p.kappa = sd(2000000000000000000);
        p.xi = sd(300000000000000000);
        p.rho = sd(-500000000000000000);

        SD59x18 callPrice = HestonModel.priceCall(p);
        SD59x18 putPrice = HestonModel.pricePut(p);

        // C - P should approximately equal S - K*e^(-rT)
        int256 lhs = SD59x18.unwrap(callPrice) - SD59x18.unwrap(putPrice);
        SD59x18 discount = p.riskFreeRate.mul(p.timeToExpiry).mul(sd(-1e18)).exp();
        int256 rhs = SD59x18.unwrap(p.spot) - SD59x18.unwrap(p.strike.mul(discount));

        int256 diff = lhs - rhs;
        int256 absDiff = diff >= 0 ? diff : -diff;

        // 20% of the max(spot, strike) as tolerance for 8-point quadrature error
        int256 maxPrice =
            SD59x18.unwrap(p.spot) > SD59x18.unwrap(p.strike) ? SD59x18.unwrap(p.spot) : SD59x18.unwrap(p.strike);
        int256 tolerance = maxPrice / 5;
        assertLe(absDiff, tolerance, "Put-call parity violated beyond tolerance");
    }

    // =========================================================================
    // Invariant: Implied vol is always positive
    // =========================================================================

    /// @notice Implied volatility extracted from Heston is always positive
    function testFuzz_impliedVol_positive(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, 1000, 10_000);
        strikeRaw = bound(strikeRaw, 1000, 10_000);

        HestonParams memory p;
        p.spot = sd(int256(spotRaw * 1e18));
        p.strike = sd(int256(strikeRaw * 1e18));
        p.riskFreeRate = sd(50000000000000000);
        p.timeToExpiry = sd(250000000000000000);
        p.v0 = sd(40000000000000000);
        p.theta = sd(40000000000000000);
        p.kappa = sd(2000000000000000000);
        p.xi = sd(300000000000000000);
        p.rho = sd(-500000000000000000);

        SD59x18 iv = HestonModel.hestonImpliedVol(p);
        assertGt(SD59x18.unwrap(iv), 0, "Implied vol must be positive");
    }

    // =========================================================================
    // Invariant: Feller condition implies fellerRatio > 1
    // =========================================================================

    /// @notice checkFellerCondition is consistent with fellerRatio > 1
    function testFuzz_fellerCondition_consistent(uint256 kappaRaw, uint256 thetaRaw, uint256 xiRaw) public pure {
        kappaRaw = bound(kappaRaw, 1e17, 10e18);
        thetaRaw = bound(thetaRaw, 1e16, 1e18);
        xiRaw = bound(xiRaw, 1e17, 2e18);

        HestonParams memory p;
        p.spot = sd(3000e18);
        p.strike = sd(3000e18);
        p.riskFreeRate = sd(50000000000000000);
        p.timeToExpiry = sd(250000000000000000);
        p.v0 = sd(40000000000000000);
        p.theta = SD59x18.wrap(int256(thetaRaw));
        p.kappa = SD59x18.wrap(int256(kappaRaw));
        p.xi = SD59x18.wrap(int256(xiRaw));
        p.rho = sd(-500000000000000000);

        bool satisfied = HestonModel.checkFellerCondition(p);
        SD59x18 ratio = HestonModel.fellerRatio(p);

        if (satisfied) {
            assertGt(SD59x18.unwrap(ratio), 1e18, "Feller satisfied but ratio <= 1");
        } else {
            assertLe(SD59x18.unwrap(ratio), 1e18, "Feller not satisfied but ratio > 1");
        }
    }
}
