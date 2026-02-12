// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import { CumulativeNormal } from "./CumulativeNormal.sol";
import { Constants } from "./Constants.sol";

/// @title AddAmericanstyleoptionsupport
/// @author MantissaFi Team
/// @notice On-chain American option pricing via the Cox-Ross-Rubinstein (CRR) binomial tree
/// @dev Implements a configurable-depth binomial lattice for American calls and puts.
///
///      **Algorithm overview (CRR binomial model):**
///      1. Discretise the option lifetime T into N equal steps of length Δt = T / N.
///      2. At each step the underlying moves up by factor u = e^(σ√Δt) or down by d = 1/u.
///      3. The risk-neutral probability of an up-move is p = (e^(rΔt) − d) / (u − d).
///      4. Build terminal payoffs at step N, then backward-induct to t = 0.
///         At every interior node the holder may exercise early, so
///         V(i,j) = max( exercise_value, e^(−rΔt) · [p·V(i+1,j+1) + (1−p)·V(i+1,j)] ).
///
///      The library is gas-bounded: a maximum of 64 time steps is enforced, keeping the
///      node count ≤ 65 per backward-induction layer (O(N) memory, O(N²) compute).
///
///      All arithmetic uses PRBMath SD59x18 18-decimal fixed-point numbers.

// ═══════════════════════════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Thrown when spot price is not strictly positive
error AmericanOption__InvalidSpotPrice(SD59x18 spot);

/// @notice Thrown when strike price is not strictly positive
error AmericanOption__InvalidStrikePrice(SD59x18 strike);

/// @notice Thrown when volatility is not strictly positive
error AmericanOption__InvalidVolatility(SD59x18 volatility);

/// @notice Thrown when time to expiry is not strictly positive
error AmericanOption__InvalidTimeToExpiry(SD59x18 timeToExpiry);

/// @notice Thrown when risk-free rate is negative
error AmericanOption__InvalidRiskFreeRate(SD59x18 riskFreeRate);

/// @notice Thrown when the number of tree steps is zero or exceeds MAX_STEPS
error AmericanOption__InvalidSteps(uint256 steps);

/// @notice Thrown when computed risk-neutral probability is outside (0, 1)
error AmericanOption__InvalidProbability(SD59x18 probability);

// ═══════════════════════════════════════════════════════════════════════════════
// STRUCTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Input parameters for American option pricing
/// @param spot Current spot price S > 0
/// @param strike Strike price K > 0
/// @param volatility Implied volatility σ > 0
/// @param riskFreeRate Risk-free interest rate r ≥ 0
/// @param timeToExpiry Time to expiry in years T > 0
struct AmericanOptionParams {
    SD59x18 spot;
    SD59x18 strike;
    SD59x18 volatility;
    SD59x18 riskFreeRate;
    SD59x18 timeToExpiry;
}

/// @notice Intermediate lattice quantities computed once and reused
/// @param dt Time per step Δt = T / N
/// @param u Up factor e^(σ√Δt)
/// @param d Down factor 1/u
/// @param p Risk-neutral up probability
/// @param discountPerStep e^(−rΔt)
struct LatticeConfig {
    SD59x18 dt;
    SD59x18 u;
    SD59x18 d;
    SD59x18 p;
    SD59x18 discountPerStep;
}

/// @notice Full result returned by the pricing functions
/// @param price The fair value of the American option
/// @param earlyExercisePremium Difference between American and European value
/// @param delta Finite-difference delta at the root node
struct AmericanOptionResult {
    SD59x18 price;
    SD59x18 earlyExercisePremium;
    SD59x18 delta;
}

library AddAmericanstyleoptionsupport {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Maximum number of binomial tree steps (keeps gas bounded)
    uint256 internal constant MAX_STEPS = 64;

    /// @notice Default number of steps when the caller does not specify
    uint256 internal constant DEFAULT_STEPS = 32;

    /// @notice 1.0 in SD59x18
    SD59x18 internal constant ONE = SD59x18.wrap(1_000000000000000000);

    /// @notice 2.0 in SD59x18
    SD59x18 internal constant TWO = SD59x18.wrap(2_000000000000000000);

    /// @notice 0.5 in SD59x18
    SD59x18 internal constant HALF = SD59x18.wrap(500000000000000000);

    // ═══════════════════════════════════════════════════════════════════════════
    // PRIMARY PRICING FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Prices an American call option using the CRR binomial tree
    /// @dev Uses the default step count (DEFAULT_STEPS = 32)
    /// @param p Option parameters
    /// @return result The pricing result including price, early exercise premium, and delta
    function priceCall(AmericanOptionParams memory p) internal pure returns (AmericanOptionResult memory result) {
        result = priceCallWithSteps(p, DEFAULT_STEPS);
    }

    /// @notice Prices an American put option using the CRR binomial tree
    /// @dev Uses the default step count (DEFAULT_STEPS = 32)
    /// @param p Option parameters
    /// @return result The pricing result including price, early exercise premium, and delta
    function pricePut(AmericanOptionParams memory p) internal pure returns (AmericanOptionResult memory result) {
        result = pricePutWithSteps(p, DEFAULT_STEPS);
    }

    /// @notice Prices an American call with a caller-specified number of tree steps
    /// @param p Option parameters
    /// @param steps Number of binomial tree steps (1 ≤ steps ≤ MAX_STEPS)
    /// @return result The pricing result
    function priceCallWithSteps(AmericanOptionParams memory p, uint256 steps)
        internal
        pure
        returns (AmericanOptionResult memory result)
    {
        _validateParams(p);
        _validateSteps(steps);
        LatticeConfig memory cfg = _buildLattice(p, steps);
        result = _priceTree(p, cfg, steps, true);
    }

    /// @notice Prices an American put with a caller-specified number of tree steps
    /// @param p Option parameters
    /// @param steps Number of binomial tree steps (1 ≤ steps ≤ MAX_STEPS)
    /// @return result The pricing result
    function pricePutWithSteps(AmericanOptionParams memory p, uint256 steps)
        internal
        pure
        returns (AmericanOptionResult memory result)
    {
        _validateParams(p);
        _validateSteps(steps);
        LatticeConfig memory cfg = _buildLattice(p, steps);
        result = _priceTree(p, cfg, steps, false);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EUROPEAN PRICING (for early-exercise premium computation)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Prices a European option using the same binomial tree (no early exercise)
    /// @param p Option parameters
    /// @param isCall True for call, false for put
    /// @param steps Number of binomial tree steps
    /// @return price The European option price
    function priceEuropean(AmericanOptionParams memory p, bool isCall, uint256 steps)
        internal
        pure
        returns (SD59x18 price)
    {
        _validateParams(p);
        _validateSteps(steps);
        LatticeConfig memory cfg = _buildLattice(p, steps);
        price = _priceTreeEuropean(p, cfg, steps, isCall);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LATTICE PARAMETER HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes the CRR lattice configuration from option parameters
    /// @dev Exposed for testing and external inspection
    /// @param p Option parameters
    /// @param steps Number of tree steps
    /// @return cfg The lattice configuration
    function buildLattice(AmericanOptionParams memory p, uint256 steps)
        internal
        pure
        returns (LatticeConfig memory cfg)
    {
        _validateParams(p);
        _validateSteps(steps);
        cfg = _buildLattice(p, steps);
    }

    /// @notice Computes the exercise value at a given node
    /// @param spot Current spot price at the node
    /// @param strike Strike price
    /// @param isCall True for call, false for put
    /// @return value The exercise payoff max(S−K, 0) for calls or max(K−S, 0) for puts
    function exerciseValue(SD59x18 spot, SD59x18 strike, bool isCall) internal pure returns (SD59x18 value) {
        if (isCall) {
            value = spot.gt(strike) ? spot.sub(strike) : ZERO;
        } else {
            value = strike.gt(spot) ? strike.sub(spot) : ZERO;
        }
    }

    /// @notice Computes the spot price at a specific node in the binomial tree
    /// @dev S(i,j) = S₀ · u^j · d^(i−j)  where i = time step, j = number of up moves
    /// @param spot Initial spot price S₀
    /// @param u Up factor
    /// @param d Down factor
    /// @param upMoves Number of up moves j
    /// @param downMoves Number of down moves (i − j)
    /// @return nodeSpot The spot price at the node
    function nodePrice(SD59x18 spot, SD59x18 u, SD59x18 d, uint256 upMoves, uint256 downMoves)
        internal
        pure
        returns (SD59x18 nodeSpot)
    {
        nodeSpot = spot;
        for (uint256 k; k < upMoves; ++k) {
            nodeSpot = nodeSpot.mul(u);
        }
        for (uint256 k; k < downMoves; ++k) {
            nodeSpot = nodeSpot.mul(d);
        }
    }

    /// @notice Checks whether early exercise is optimal at a given node
    /// @param exercise The exercise (intrinsic) value at the node
    /// @param continuation The discounted continuation value
    /// @return optimal True if early exercise value exceeds continuation value
    function isEarlyExerciseOptimal(SD59x18 exercise, SD59x18 continuation) internal pure returns (bool optimal) {
        optimal = exercise.gt(continuation);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EARLY EXERCISE BOUNDARY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes the early exercise boundary prices for each time step
    /// @dev Returns the critical spot price at each step below/above which early exercise is optimal.
    ///      For puts the boundary is the highest spot where exercise beats continuation;
    ///      for calls the boundary is the lowest spot where exercise beats continuation.
    ///      A value of ZERO means no early exercise is optimal at that step.
    /// @param p Option parameters
    /// @param isCall True for call, false for put
    /// @param steps Number of tree steps
    /// @return boundary Array of critical spot prices (length = steps), indexed by time step
    function earlyExerciseBoundary(AmericanOptionParams memory p, bool isCall, uint256 steps)
        internal
        pure
        returns (SD59x18[] memory boundary)
    {
        _validateParams(p);
        _validateSteps(steps);
        LatticeConfig memory cfg = _buildLattice(p, steps);

        // Build terminal payoffs
        SD59x18[] memory values = new SD59x18[](steps + 1);
        for (uint256 j; j <= steps; ++j) {
            SD59x18 spotAtNode = nodePrice(p.spot, cfg.u, cfg.d, j, steps - j);
            values[j] = exerciseValue(spotAtNode, p.strike, isCall);
        }

        boundary = new SD59x18[](steps);

        // Backward induction: track boundary at each step
        for (uint256 i = steps; i >= 1; --i) {
            SD59x18 criticalSpot = ZERO;
            SD59x18[] memory newValues = new SD59x18[](i);

            for (uint256 j; j < i; ++j) {
                SD59x18 continuation =
                    cfg.discountPerStep.mul(cfg.p.mul(values[j + 1]).add(ONE.sub(cfg.p).mul(values[j])));
                SD59x18 spotAtNode = nodePrice(p.spot, cfg.u, cfg.d, j, i - 1 - j);
                SD59x18 exercise = exerciseValue(spotAtNode, p.strike, isCall);

                if (exercise.gt(continuation)) {
                    newValues[j] = exercise;
                    // Track boundary: for puts we want the highest exercised spot,
                    // for calls we want the lowest exercised spot
                    if (isCall) {
                        if (criticalSpot.eq(ZERO) || spotAtNode.lt(criticalSpot)) {
                            criticalSpot = spotAtNode;
                        }
                    } else {
                        if (spotAtNode.gt(criticalSpot)) {
                            criticalSpot = spotAtNode;
                        }
                    }
                } else {
                    newValues[j] = continuation;
                }
            }

            boundary[i - 1] = criticalSpot;
            values = newValues;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: LATTICE CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Builds the CRR lattice parameters
    /// @dev u = e^(σ√Δt), d = 1/u, p = (e^(rΔt) − d) / (u − d)
    function _buildLattice(AmericanOptionParams memory p, uint256 steps)
        private
        pure
        returns (LatticeConfig memory cfg)
    {
        // Δt = T / N
        cfg.dt = p.timeToExpiry.div(sd(int256(steps) * 1e18));

        // u = exp(σ · √Δt)
        SD59x18 sqrtDt = cfg.dt.sqrt();
        cfg.u = p.volatility.mul(sqrtDt).exp();

        // d = 1 / u
        cfg.d = ONE.div(cfg.u);

        // Discount factor per step: e^(-r · Δt)
        cfg.discountPerStep = p.riskFreeRate.mul(cfg.dt).mul(sd(-1e18)).exp();

        // Growth factor per step: e^(r · Δt)
        SD59x18 growthFactor = p.riskFreeRate.mul(cfg.dt).exp();

        // Risk-neutral probability: p = (e^(rΔt) − d) / (u − d)
        cfg.p = growthFactor.sub(cfg.d).div(cfg.u.sub(cfg.d));

        // Validate probability is in (0, 1)
        if (cfg.p.lte(ZERO) || cfg.p.gte(ONE)) {
            revert AmericanOption__InvalidProbability(cfg.p);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: TREE PRICING (AMERICAN — with early exercise)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Backward-inducts through the binomial tree with early exercise
    /// @dev O(N) memory — only one layer of values is kept at a time.
    ///      Also computes a first-order central-difference delta from the first time step.
    function _priceTree(AmericanOptionParams memory p, LatticeConfig memory cfg, uint256 steps, bool isCall)
        private
        pure
        returns (AmericanOptionResult memory result)
    {
        // --- Terminal payoffs (step N) ---
        SD59x18[] memory values = new SD59x18[](steps + 1);
        for (uint256 j; j <= steps; ++j) {
            SD59x18 spotAtNode = nodePrice(p.spot, cfg.u, cfg.d, j, steps - j);
            values[j] = exerciseValue(spotAtNode, p.strike, isCall);
        }

        // --- Backward induction with early exercise ---
        for (uint256 i = steps; i >= 1; --i) {
            SD59x18[] memory newValues = new SD59x18[](i);
            for (uint256 j; j < i; ++j) {
                // Continuation value
                SD59x18 continuation =
                    cfg.discountPerStep.mul(cfg.p.mul(values[j + 1]).add(ONE.sub(cfg.p).mul(values[j])));
                // Exercise value at this node
                SD59x18 spotAtNode = nodePrice(p.spot, cfg.u, cfg.d, j, i - 1 - j);
                SD59x18 exercise = exerciseValue(spotAtNode, p.strike, isCall);
                // American: take the max
                newValues[j] = exercise.gt(continuation) ? exercise : continuation;
            }
            // Capture delta from step 1 (two nodes: up and down from root)
            if (i == 1) {
                SD59x18 spotUp = p.spot.mul(cfg.u);
                SD59x18 spotDown = p.spot.mul(cfg.d);
                // Δ = (V_up − V_down) / (S_up − S_down)
                // newValues has been set for i=1 but values still has the i=2 layer
                // Actually at i=1: newValues[0] is the root value
                // We need values from one step before the root, i.e. the i=1 layer
                // which is the current values array (still 2 elements: values[0], values[1])
                // Wait — at this point we are computing the i=1 layer.
                // values[] currently holds the i=1 results (2 elements after previous iteration set them)
                // Actually let me re-think: values currently still holds the layer for step i (before overwrite).
                // When i=1, values holds the 2-element layer from step 1 (set in the i=2 iteration).
                // newValues will be the root (1 element).
                // Delta uses the step-1 layer: values[0] (down) and values[1] (up).
                // But we need the American values at step 1, which were computed in the i=2 iteration.
                // Actually values[j] = american value at step (i) node j. When i=1, the current
                // values array was set in the previous loop iteration (when i=2), containing 2 elements.
                // But those are the values AFTER backward induction from step 2, which already include
                // early exercise. We haven't overwritten values yet (newValues is separate).
                // However, for the American tree the step-1 values already incorporate early exercise
                // from deeper nodes but not at step 1 itself. We should use the final American values.
                // The newValues array for i=1 will contain only 1 element (the root).
                // The values array at i=1 entry contains the 2 American values from step 1.
                // We want delta from those step-1 American values.
                result.delta = values[1].sub(values[0]).div(spotUp.sub(spotDown));
            }
            values = newValues;
        }

        result.price = values[0];

        // Compute early exercise premium = American price − European price
        SD59x18 europeanPrice = _priceTreeEuropean(p, cfg, steps, isCall);
        result.earlyExercisePremium = result.price.gt(europeanPrice) ? result.price.sub(europeanPrice) : ZERO;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: TREE PRICING (EUROPEAN — no early exercise)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Backward-inducts through the binomial tree WITHOUT early exercise
    function _priceTreeEuropean(AmericanOptionParams memory p, LatticeConfig memory cfg, uint256 steps, bool isCall)
        private
        pure
        returns (SD59x18 price)
    {
        SD59x18[] memory values = new SD59x18[](steps + 1);
        for (uint256 j; j <= steps; ++j) {
            SD59x18 spotAtNode = nodePrice(p.spot, cfg.u, cfg.d, j, steps - j);
            values[j] = exerciseValue(spotAtNode, p.strike, isCall);
        }

        SD59x18 q = ONE.sub(cfg.p);
        for (uint256 i = steps; i >= 1; --i) {
            SD59x18[] memory newValues = new SD59x18[](i);
            for (uint256 j; j < i; ++j) {
                newValues[j] = cfg.discountPerStep.mul(cfg.p.mul(values[j + 1]).add(q.mul(values[j])));
            }
            values = newValues;
        }

        price = values[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates all option parameters
    function _validateParams(AmericanOptionParams memory p) private pure {
        if (p.spot.lte(ZERO)) {
            revert AmericanOption__InvalidSpotPrice(p.spot);
        }
        if (p.strike.lte(ZERO)) {
            revert AmericanOption__InvalidStrikePrice(p.strike);
        }
        if (p.volatility.lte(ZERO)) {
            revert AmericanOption__InvalidVolatility(p.volatility);
        }
        if (p.timeToExpiry.lte(ZERO)) {
            revert AmericanOption__InvalidTimeToExpiry(p.timeToExpiry);
        }
        if (p.riskFreeRate.lt(ZERO)) {
            revert AmericanOption__InvalidRiskFreeRate(p.riskFreeRate);
        }
    }

    /// @notice Validates the step count
    function _validateSteps(uint256 steps) private pure {
        if (steps == 0 || steps > MAX_STEPS) {
            revert AmericanOption__InvalidSteps(steps);
        }
    }
}
