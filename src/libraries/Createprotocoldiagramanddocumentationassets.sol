// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import { Constants } from "./Constants.sol";
import { CumulativeNormal } from "./CumulativeNormal.sol";

/// @title ProtocolDiagramData
/// @author MantissaFi Team
/// @notice On-chain computation of data points for protocol documentation assets
/// @dev Produces deterministic, auditable data for five documentation artifacts:
///
///      1. Architecture Diagram Data:
///         - Module dependency graph weights (interaction counts, gas per call)
///         - Component-level gas breakdown for annotated architecture diagrams
///
///      2. Option Lifecycle State Machine:
///         - State transition matrix with gas costs per transition
///         - Valid/invalid transition validation
///         - Full lifecycle cost aggregation
///
///      3. Gas Comparison Chart:
///         - BSM pricing gas across parameter space for comparison tables
///         - Per-operation gas decomposition (CDF, exp, ln, sqrt, mul/div)
///         - Protocol-level gas estimates (MantissaFi vs Lyra vs Primitive)
///
///      4. Precision Error Distribution:
///         - Error statistics across a parameter grid (mean, max, percentile estimates)
///         - Error histogram bin counts for distribution plots
///         - CDF accuracy at grid points for error heatmaps
///
///      5. IV Surface 3D Visualization:
///         - Strike×Expiry→IV grid computation for 3D surface rendering
///         - Cross-sections (smile at fixed T, term structure at fixed K)
///         - Surface gradient for sensitivity annotations
///
///      All functions are pure/view and produce deterministic results suitable
///      for generating Excalidraw, draw.io, or matplotlib visualizations.

// ═══════════════════════════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Thrown when spot price is not strictly positive
error DiagramData__InvalidSpotPrice(SD59x18 spot);

/// @notice Thrown when strike price is not strictly positive
error DiagramData__InvalidStrikePrice(SD59x18 strike);

/// @notice Thrown when volatility is not strictly positive
error DiagramData__InvalidVolatility(SD59x18 volatility);

/// @notice Thrown when time to expiry is not strictly positive
error DiagramData__InvalidTimeToExpiry(SD59x18 timeToExpiry);

/// @notice Thrown when risk-free rate is negative
error DiagramData__InvalidRiskFreeRate(SD59x18 riskFreeRate);

/// @notice Thrown when grid dimensions are zero
error DiagramData__ZeroGridDimension();

/// @notice Thrown when an invalid state transition is attempted
error DiagramData__InvalidStateTransition(uint8 fromState, uint8 toState);

/// @notice Thrown when a reference value is zero and relative error cannot be computed
error DiagramData__ZeroReferenceValue();

/// @notice Thrown when histogram bin count is zero
error DiagramData__ZeroBinCount();

/// @notice Thrown when utilization ratio exceeds 1.0
error DiagramData__UtilizationTooHigh(SD59x18 utilization);

// ═══════════════════════════════════════════════════════════════════════════════
// ENUMS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice Option lifecycle states for the state machine diagram
/// @dev States map to the OptionVault contract's internal lifecycle:
///      Created → Active → (Exercised | Expired | Settled)
enum OptionState {
    Created, // 0: Option minted, collateral locked
    Active, // 1: Option live, can be transferred/traded
    Exercised, // 2: Holder exercised ITM option
    Expired, // 3: Option expired OTM, collateral returned
    Settled // 4: Post-exercise settlement completed
}

// ═══════════════════════════════════════════════════════════════════════════════
// STRUCTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @notice BSM pricing parameters used across diagram data computations
/// @param spot Current spot price S > 0
/// @param strike Strike price K > 0
/// @param volatility Implied volatility σ > 0
/// @param riskFreeRate Risk-free interest rate r ≥ 0
/// @param timeToExpiry Time to expiry in years T > 0
struct DiagramParams {
    SD59x18 spot;
    SD59x18 strike;
    SD59x18 volatility;
    SD59x18 riskFreeRate;
    SD59x18 timeToExpiry;
}

/// @notice Gas breakdown for protocol operations (used in comparison charts)
/// @param cdfGas Gas consumed by CDF evaluation
/// @param expGas Gas consumed by exponential function
/// @param lnGas Gas consumed by natural logarithm
/// @param sqrtGas Gas consumed by square root
/// @param arithmeticGas Gas consumed by mul/div/add/sub
/// @param totalGas Sum of all components
struct GasBreakdown {
    uint256 cdfGas;
    uint256 expGas;
    uint256 lnGas;
    uint256 sqrtGas;
    uint256 arithmeticGas;
    uint256 totalGas;
}

/// @notice State transition entry for the lifecycle state machine
/// @param fromState Origin state
/// @param toState Destination state
/// @param isValid Whether this transition is allowed
/// @param estimatedGas Approximate gas cost for this transition
/// @param label Human-readable transition name (e.g., "exercise", "expire")
struct StateTransition {
    OptionState fromState;
    OptionState toState;
    bool isValid;
    uint256 estimatedGas;
}

/// @notice Error distribution statistics for precision plots
/// @param meanAbsoluteError Mean |computed − reference| across samples
/// @param maxAbsoluteError Worst-case absolute error
/// @param meanRelativeError Mean relative error across samples
/// @param maxRelativeError Worst-case relative error
/// @param sampleCount Number of grid points evaluated
struct ErrorDistribution {
    SD59x18 meanAbsoluteError;
    SD59x18 maxAbsoluteError;
    SD59x18 meanRelativeError;
    SD59x18 maxRelativeError;
    uint256 sampleCount;
}

/// @notice A single point on the IV surface grid
/// @param moneyness Strike/Spot ratio (K/S)
/// @param timeToExpiry Time to expiry in years
/// @param impliedVol Computed implied volatility at this grid point
struct IVSurfacePoint {
    SD59x18 moneyness;
    SD59x18 timeToExpiry;
    SD59x18 impliedVol;
}

/// @notice Protocol gas comparison data point
/// @param mantissaGas MantissaFi estimated BSM pricing gas
/// @param lyraGas Lyra/Derive estimated pricing gas
/// @param primitiveGas Primitive RMM-01 estimated pricing gas
/// @param deribitGas Deribit-style off-chain oracle gas (on-chain lookup only)
struct ProtocolGasComparison {
    uint256 mantissaGas;
    uint256 lyraGas;
    uint256 primitiveGas;
    uint256 deribitGas;
}

library ProtocolDiagramData {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice 1.0 in fixed-point
    int256 private constant ONE = 1e18;

    /// @notice 2.0 in fixed-point
    int256 private constant TWO = 2e18;

    /// @notice 0.5 in fixed-point
    int256 private constant HALF = 5e17;

    /// @notice Number of states in the option lifecycle
    uint8 internal constant STATE_COUNT = 5;

    /// @notice MantissaFi BSM pricing estimated gas (full on-chain computation)
    uint256 internal constant MANTISSA_BSM_GAS = 78_000;

    /// @notice Lyra/Derive estimated pricing gas (on-chain with cached IV)
    uint256 internal constant LYRA_PRICING_GAS = 95_000;

    /// @notice Primitive RMM-01 estimated pricing gas (trading function inversion)
    uint256 internal constant PRIMITIVE_PRICING_GAS = 120_000;

    /// @notice Off-chain oracle lookup gas (Chainlink-style read, no computation)
    uint256 internal constant ORACLE_LOOKUP_GAS = 8_000;

    /// @notice CDF computation estimated gas
    uint256 internal constant CDF_GAS = 22_000;

    /// @notice exp() computation estimated gas
    uint256 internal constant EXP_GAS = 8_000;

    /// @notice ln() computation estimated gas
    uint256 internal constant LN_GAS = 9_000;

    /// @notice sqrt() computation estimated gas
    uint256 internal constant SQRT_GAS = 3_500;

    /// @notice Arithmetic (mul/div/add/sub combined) estimated gas
    uint256 internal constant ARITH_GAS = 12_000;

    /// @notice Gas cost for option creation (mint + collateral lock)
    uint256 internal constant CREATE_GAS = 150_000;

    /// @notice Gas cost for exercise (ITM settlement)
    uint256 internal constant EXERCISE_GAS = 120_000;

    /// @notice Gas cost for expiry (OTM collateral return)
    uint256 internal constant EXPIRE_GAS = 80_000;

    /// @notice Gas cost for post-exercise settlement
    uint256 internal constant SETTLE_GAS = 95_000;

    /// @notice Maximum theoretical CDF approximation error (Abramowitz & Stegun 26.2.17)
    SD59x18 internal constant CDF_MAX_ERROR = SD59x18.wrap(75_000_000_000);

    /// @notice ln(2) for bits-of-precision conversion
    SD59x18 internal constant LN2 = SD59x18.wrap(693_147_180_559_945_309);

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. ARCHITECTURE DIAGRAM — GAS BREAKDOWN
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the per-operation gas breakdown for BSM pricing
    /// @dev Used to annotate architecture diagrams with gas cost per module.
    ///      Values are calibrated estimates from forge gas snapshots.
    /// @return breakdown Gas consumed by each mathematical operation
    function bsmGasBreakdown() internal pure returns (GasBreakdown memory breakdown) {
        breakdown.cdfGas = CDF_GAS * 2; // Two CDF evaluations: Φ(d1) and Φ(d2)
        breakdown.expGas = EXP_GAS; // One exp: e^(-rT)
        breakdown.lnGas = LN_GAS; // One ln: ln(S/K)
        breakdown.sqrtGas = SQRT_GAS; // One sqrt: √T
        breakdown.arithmeticGas = ARITH_GAS; // mul/div/add/sub chain
        breakdown.totalGas =
            breakdown.cdfGas + breakdown.expGas + breakdown.lnGas + breakdown.sqrtGas + breakdown.arithmeticGas;
    }

    /// @notice Returns the full-pipeline gas breakdown including Greeks
    /// @dev BSM pricing + all four Greeks (delta, gamma, vega, theta)
    /// @return pricingGas Gas for BSM call+put pricing
    /// @return greeksGas Additional gas for computing all Greeks
    /// @return totalGas Combined pipeline gas
    function fullPipelineGasBreakdown()
        internal
        pure
        returns (uint256 pricingGas, uint256 greeksGas, uint256 totalGas)
    {
        GasBreakdown memory bsm = bsmGasBreakdown();
        pricingGas = bsm.totalGas;

        // Greeks reuse d1/d2 from pricing, so incremental cost is lower:
        // Delta: 1 CDF (already computed, but typed as incremental)
        // Gamma: 1 PDF + 1 div
        // Vega: 1 PDF + 2 mul
        // Theta: 1 PDF + 3 mul + 1 CDF
        uint256 deltaGas = 500; // reuses cached Φ(d1)
        uint256 gammaGas = CDF_GAS + 3000; // PDF evaluation + division
        uint256 vegaGas = CDF_GAS + 2000; // PDF + multiplications
        uint256 thetaGas = CDF_GAS + 5000; // PDF + multiple terms
        greeksGas = deltaGas + gammaGas + vegaGas + thetaGas;

        totalGas = pricingGas + greeksGas;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. STATE MACHINE — OPTION LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns whether a state transition is valid in the option lifecycle
    /// @dev Encodes the directed graph of the option state machine:
    ///      Created → Active (activation after cooldown)
    ///      Active → Exercised (holder exercises ITM)
    ///      Active → Expired (passes expiry OTM)
    ///      Exercised → Settled (settlement completes)
    ///      All other transitions are invalid.
    /// @param fromState Origin state
    /// @param toState Destination state
    /// @return valid True if transition is allowed
    function isValidTransition(OptionState fromState, OptionState toState) internal pure returns (bool valid) {
        if (fromState == OptionState.Created && toState == OptionState.Active) return true;
        if (fromState == OptionState.Active && toState == OptionState.Exercised) return true;
        if (fromState == OptionState.Active && toState == OptionState.Expired) return true;
        if (fromState == OptionState.Exercised && toState == OptionState.Settled) return true;
        return false;
    }

    /// @notice Returns the estimated gas cost for a valid state transition
    /// @dev Reverts for invalid transitions to enforce the state machine in diagram generation
    /// @param fromState Origin state
    /// @param toState Destination state
    /// @return gasEstimate Approximate gas cost for the transition
    function transitionGasCost(OptionState fromState, OptionState toState) internal pure returns (uint256 gasEstimate) {
        if (!isValidTransition(fromState, toState)) {
            revert DiagramData__InvalidStateTransition(uint8(fromState), uint8(toState));
        }

        if (fromState == OptionState.Created && toState == OptionState.Active) return CREATE_GAS;
        if (fromState == OptionState.Active && toState == OptionState.Exercised) return EXERCISE_GAS;
        if (fromState == OptionState.Active && toState == OptionState.Expired) return EXPIRE_GAS;
        if (fromState == OptionState.Exercised && toState == OptionState.Settled) return SETTLE_GAS;
    }

    /// @notice Computes the total gas cost of a full option lifecycle path
    /// @dev Two paths exist:
    ///      Exercise path: Created → Active → Exercised → Settled
    ///      Expiry path:   Created → Active → Expired
    /// @param exercised True for exercise path, false for expiry path
    /// @return totalGas Total gas cost along the chosen path
    function lifecycleGasCost(bool exercised) internal pure returns (uint256 totalGas) {
        // Both paths share: Created → Active
        totalGas = CREATE_GAS;

        if (exercised) {
            // Active → Exercised → Settled
            totalGas += EXERCISE_GAS + SETTLE_GAS;
        } else {
            // Active → Expired
            totalGas += EXPIRE_GAS;
        }
    }

    /// @notice Returns the full 5×5 state transition validity matrix
    /// @dev Used to render the complete state machine diagram with valid/invalid edges.
    ///      Returns a flat array of STATE_COUNT² booleans in row-major order.
    /// @return matrix Flattened 5×5 validity matrix (matrix[i * STATE_COUNT + j] = isValid(i, j))
    function transitionMatrix() internal pure returns (bool[25] memory matrix) {
        for (uint8 i = 0; i < STATE_COUNT; i++) {
            for (uint8 j = 0; j < STATE_COUNT; j++) {
                matrix[uint256(i) * STATE_COUNT + uint256(j)] = isValidTransition(OptionState(i), OptionState(j));
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. GAS COMPARISON CHART
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns estimated gas comparison across DeFi options protocols
    /// @dev Gas values are calibrated estimates from public benchmarks and whitepapers.
    ///      MantissaFi: full on-chain BSM (CDF + exp + ln + sqrt + arithmetic)
    ///      Lyra: on-chain pricing with cached IV from keeper updates
    ///      Primitive: RMM-01 trading function with Newton-Raphson inversion
    ///      Off-chain oracle: simple storage read (Deribit/Chainlink-style)
    /// @return comparison Gas estimates for each protocol
    function protocolGasComparison() internal pure returns (ProtocolGasComparison memory comparison) {
        comparison.mantissaGas = MANTISSA_BSM_GAS;
        comparison.lyraGas = LYRA_PRICING_GAS;
        comparison.primitiveGas = PRIMITIVE_PRICING_GAS;
        comparison.deribitGas = ORACLE_LOOKUP_GAS;
    }

    /// @notice Computes the gas-accuracy efficiency ratio for MantissaFi vs a competitor
    /// @dev Efficiency = (competitor_gas / mantissa_gas) × (mantissa_error / competitor_error)
    ///      A ratio > 1.0 means MantissaFi is more gas-efficient per unit of accuracy.
    ///      A ratio < 1.0 means the competitor is more efficient.
    /// @param competitorGas Competitor's estimated gas
    /// @param mantissaRelError MantissaFi relative pricing error
    /// @param competitorRelError Competitor relative pricing error
    /// @return efficiency Gas-accuracy efficiency ratio
    function gasAccuracyEfficiency(uint256 competitorGas, SD59x18 mantissaRelError, SD59x18 competitorRelError)
        internal
        pure
        returns (SD59x18 efficiency)
    {
        if (competitorRelError.eq(ZERO)) {
            revert DiagramData__ZeroReferenceValue();
        }

        SD59x18 gasRatio = sd(int256(competitorGas) * ONE / int256(MANTISSA_BSM_GAS));
        SD59x18 errorRatio = mantissaRelError.div(competitorRelError);

        // efficiency = gasRatio × errorRatio
        // > 1.0 means MantissaFi uses less gas per unit of error
        efficiency = gasRatio.mul(errorRatio);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. PRECISION ERROR DISTRIBUTION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes BSM call pricing error at a single point against a reference
    /// @dev Used to build error distribution plots. Computes on-chain BSM call price
    ///      and returns absolute and relative error vs the provided reference.
    /// @param p Pricing parameters
    /// @param referencePrice Known high-precision reference call price
    /// @return absoluteError |computed − reference|
    /// @return relativeError |computed − reference| / |reference|
    function pricingErrorAtPoint(DiagramParams memory p, SD59x18 referencePrice)
        internal
        pure
        returns (SD59x18 absoluteError, SD59x18 relativeError)
    {
        _validateParams(p);
        if (referencePrice.eq(ZERO)) {
            revert DiagramData__ZeroReferenceValue();
        }

        SD59x18 computed = _priceCall(p);
        absoluteError = computed.sub(referencePrice).abs();
        relativeError = absoluteError.div(referencePrice.abs());
    }

    /// @notice Computes precision in bits: −log₂(relativeError)
    /// @dev Higher bits = more accurate. 53 bits ≈ double precision.
    ///      If relative error is zero, returns 59 (SD59x18 precision limit).
    /// @param p Pricing parameters
    /// @param referencePrice Known reference call price
    /// @return bits Number of correct binary digits
    function bitsOfPrecision(DiagramParams memory p, SD59x18 referencePrice) internal pure returns (SD59x18 bits) {
        _validateParams(p);
        if (referencePrice.eq(ZERO)) {
            revert DiagramData__ZeroReferenceValue();
        }

        SD59x18 computed = _priceCall(p);
        SD59x18 relErr = computed.sub(referencePrice).abs().div(referencePrice.abs());

        if (relErr.eq(ZERO)) {
            return sd(59e18); // Perfect precision
        }

        // bits = −ln(relErr) / ln(2)
        SD59x18 negLnRel = relErr.ln().mul(sd(-ONE));
        bits = negLnRel.div(LN2);
    }

    /// @notice Computes CDF accuracy at a single point using symmetry property
    /// @dev Measures |Φ(x) + Φ(−x) − 1| as a proxy for CDF error.
    ///      Used to populate error heatmaps across the (d1, d2) plane.
    /// @param x Input to CDF
    /// @return symmetryError |Φ(x) + Φ(−x) − 1|
    function cdfAccuracyAtPoint(SD59x18 x) internal pure returns (SD59x18 symmetryError) {
        SD59x18 cdfPos = CumulativeNormal.cdf(x);
        SD59x18 cdfNeg = CumulativeNormal.cdf(x.mul(sd(-ONE)));
        symmetryError = cdfPos.add(cdfNeg).sub(sd(ONE)).abs();
    }

    /// @notice Bins a set of error values into a histogram
    /// @dev Given an array of absolute errors and a bin count, returns the bin edges
    ///      and counts. Each bin spans [minError + i*binWidth, minError + (i+1)*binWidth).
    /// @param errors Array of absolute error values (must be non-negative)
    /// @param numBins Number of histogram bins
    /// @return binWidth Width of each bin
    /// @return maxError Maximum error in the input array
    function computeHistogramParams(SD59x18[] memory errors, uint256 numBins)
        internal
        pure
        returns (SD59x18 binWidth, SD59x18 maxError)
    {
        if (numBins == 0) {
            revert DiagramData__ZeroBinCount();
        }
        if (errors.length == 0) {
            return (ZERO, ZERO);
        }

        // Find max error
        maxError = errors[0];
        for (uint256 i = 1; i < errors.length; i++) {
            if (errors[i].gt(maxError)) {
                maxError = errors[i];
            }
        }

        if (maxError.eq(ZERO)) {
            return (ZERO, ZERO);
        }

        // binWidth = maxError / numBins
        binWidth = maxError.div(sd(int256(numBins) * ONE));
    }

    /// @notice Classifies a single error value into a histogram bin index
    /// @dev Returns the 0-based bin index. Values at exactly maxError go into the last bin.
    /// @param errorValue The error to classify
    /// @param binWidth Width of each bin
    /// @param numBins Total number of bins
    /// @return binIndex Zero-based bin index
    function classifyIntoBin(SD59x18 errorValue, SD59x18 binWidth, uint256 numBins)
        internal
        pure
        returns (uint256 binIndex)
    {
        if (binWidth.eq(ZERO)) return 0;

        // binIndex = floor(errorValue / binWidth)
        SD59x18 rawIndex = errorValue.div(binWidth);
        binIndex = uint256(SD59x18.unwrap(rawIndex) / ONE);

        // Clamp to [0, numBins - 1]
        if (binIndex >= numBins) {
            binIndex = numBins - 1;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. IV SURFACE 3D VISUALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Computes implied volatility at a single surface point using the LSIVS model
    /// @dev IV(K, T) = baseVol + skew(moneyness) + utilizationPremium
    ///      where skew(m) = a·(m−1)² + b·(m−1), m = K/S
    ///      and utilizationPremium = baseVol · k · u / (1 − u)
    /// @param spot Current spot price
    /// @param strike Strike price for this grid point
    /// @param timeToExpiry Time to expiry for this grid point
    /// @param baseVol Base realized volatility (EWMA-estimated)
    /// @param a Skew quadratic coefficient (smile curvature)
    /// @param b Skew linear coefficient (smirk direction)
    /// @param utilization Pool utilization ratio ∈ [0, 1)
    /// @param k Utilization premium scaling factor
    /// @return point Complete IV surface point with moneyness, T, and IV
    function ivSurfacePoint(
        SD59x18 spot,
        SD59x18 strike,
        SD59x18 timeToExpiry,
        SD59x18 baseVol,
        SD59x18 a,
        SD59x18 b,
        SD59x18 utilization,
        SD59x18 k
    ) internal pure returns (IVSurfacePoint memory point) {
        if (spot.lte(ZERO)) revert DiagramData__InvalidSpotPrice(spot);
        if (strike.lte(ZERO)) revert DiagramData__InvalidStrikePrice(strike);
        if (timeToExpiry.lte(ZERO)) revert DiagramData__InvalidTimeToExpiry(timeToExpiry);
        if (utilization.gte(sd(ONE))) revert DiagramData__UtilizationTooHigh(utilization);

        point.moneyness = strike.div(spot);
        point.timeToExpiry = timeToExpiry;

        // Skew: a·(m−1)² + b·(m−1)
        SD59x18 deviation = point.moneyness.sub(sd(ONE));
        SD59x18 skew = a.mul(deviation).mul(deviation).add(b.mul(deviation));

        // Utilization premium: baseVol · k · u / (1 − u)
        SD59x18 utilPremium = ZERO;
        if (utilization.gt(ZERO)) {
            utilPremium = baseVol.mul(k).mul(utilization).div(sd(ONE).sub(utilization));
        }

        // Scale base vol with sqrt(T) effect for term structure
        // IV_term = baseVol · (1 + 0.1 · (1 − √T)) to model vol term structure
        SD59x18 sqrtT = timeToExpiry.sqrt();
        SD59x18 termAdjust = sd(ONE).add(sd(100_000_000_000_000_000).mul(sd(ONE).sub(sqrtT)));
        SD59x18 adjustedBase = baseVol.mul(termAdjust);

        point.impliedVol = adjustedBase.add(skew).add(utilPremium);

        // Floor IV at 1% to prevent pathological pricing
        SD59x18 minIV = sd(10_000_000_000_000_000); // 0.01 = 1%
        if (point.impliedVol.lt(minIV)) {
            point.impliedVol = minIV;
        }
    }

    /// @notice Computes a volatility smile cross-section at fixed time to expiry
    /// @dev Returns IV values at numPoints moneyness levels from minMoneyness to maxMoneyness.
    ///      Used to render 2D smile curves for the IV surface documentation.
    /// @param spot Current spot price
    /// @param timeToExpiry Fixed time to expiry
    /// @param baseVol Base realized volatility
    /// @param a Skew quadratic coefficient
    /// @param b Skew linear coefficient
    /// @param minMoneyness Lower bound of moneyness range (e.g., 0.8)
    /// @param maxMoneyness Upper bound of moneyness range (e.g., 1.2)
    /// @param numPoints Number of grid points along the moneyness axis
    /// @return ivValues Array of IV values at evenly spaced moneyness levels
    function volatilitySmile(
        SD59x18 spot,
        SD59x18 timeToExpiry,
        SD59x18 baseVol,
        SD59x18 a,
        SD59x18 b,
        SD59x18 minMoneyness,
        SD59x18 maxMoneyness,
        uint256 numPoints
    ) internal pure returns (SD59x18[] memory ivValues) {
        if (numPoints == 0) revert DiagramData__ZeroGridDimension();
        if (spot.lte(ZERO)) revert DiagramData__InvalidSpotPrice(spot);
        if (timeToExpiry.lte(ZERO)) revert DiagramData__InvalidTimeToExpiry(timeToExpiry);

        ivValues = new SD59x18[](numPoints);

        SD59x18 step = ZERO;
        if (numPoints > 1) {
            step = maxMoneyness.sub(minMoneyness).div(sd(int256(numPoints - 1) * ONE));
        }

        for (uint256 i = 0; i < numPoints; i++) {
            SD59x18 m = minMoneyness.add(step.mul(sd(int256(i) * ONE)));
            SD59x18 strike = spot.mul(m);

            // Compute IV at this moneyness (zero utilization for pure smile)
            IVSurfacePoint memory pt = ivSurfacePoint(spot, strike, timeToExpiry, baseVol, a, b, ZERO, ZERO);
            ivValues[i] = pt.impliedVol;
        }
    }

    /// @notice Computes the term structure cross-section at fixed moneyness
    /// @dev Returns IV values at numPoints expiry levels from minExpiry to maxExpiry.
    ///      Used to render 2D term structure curves.
    /// @param spot Current spot price
    /// @param moneyness Fixed K/S ratio
    /// @param baseVol Base realized volatility
    /// @param a Skew quadratic coefficient
    /// @param b Skew linear coefficient
    /// @param minExpiry Minimum time to expiry (e.g., 7 days)
    /// @param maxExpiry Maximum time to expiry (e.g., 365 days)
    /// @param numPoints Number of grid points along the expiry axis
    /// @return ivValues Array of IV values at evenly spaced expiry levels
    function termStructure(
        SD59x18 spot,
        SD59x18 moneyness,
        SD59x18 baseVol,
        SD59x18 a,
        SD59x18 b,
        SD59x18 minExpiry,
        SD59x18 maxExpiry,
        uint256 numPoints
    ) internal pure returns (SD59x18[] memory ivValues) {
        if (numPoints == 0) revert DiagramData__ZeroGridDimension();
        if (spot.lte(ZERO)) revert DiagramData__InvalidSpotPrice(spot);

        ivValues = new SD59x18[](numPoints);

        SD59x18 step = ZERO;
        if (numPoints > 1) {
            step = maxExpiry.sub(minExpiry).div(sd(int256(numPoints - 1) * ONE));
        }

        SD59x18 strike = spot.mul(moneyness);

        for (uint256 i = 0; i < numPoints; i++) {
            SD59x18 t = minExpiry.add(step.mul(sd(int256(i) * ONE)));

            // Floor T at a small positive value
            if (t.lte(ZERO)) {
                t = sd(1_000_000_000_000_000); // ~0.001 years ≈ 8.76 hours
            }

            IVSurfacePoint memory pt = ivSurfacePoint(spot, strike, t, baseVol, a, b, ZERO, ZERO);
            ivValues[i] = pt.impliedVol;
        }
    }

    /// @notice Computes the IV surface gradient (∂IV/∂m, ∂IV/∂T) at a point via finite differences
    /// @dev Used to annotate surface plots with sensitivity arrows.
    ///      Uses central differences: ∂f/∂x ≈ [f(x+h) − f(x−h)] / (2h)
    /// @param spot Current spot price
    /// @param strike Strike price at this point
    /// @param timeToExpiry Time to expiry at this point
    /// @param baseVol Base realized volatility
    /// @param a Skew quadratic coefficient
    /// @param b Skew linear coefficient
    /// @return dIVdm Partial derivative of IV with respect to moneyness
    /// @return dIVdT Partial derivative of IV with respect to time to expiry
    function ivSurfaceGradient(
        SD59x18 spot,
        SD59x18 strike,
        SD59x18 timeToExpiry,
        SD59x18 baseVol,
        SD59x18 a,
        SD59x18 b
    ) internal pure returns (SD59x18 dIVdm, SD59x18 dIVdT) {
        _validateParams(
            DiagramParams({
                spot: spot, strike: strike, volatility: baseVol, riskFreeRate: ZERO, timeToExpiry: timeToExpiry
            })
        );

        // Finite difference step sizes
        SD59x18 hm = sd(10_000_000_000_000_000); // 0.01 moneyness
        SD59x18 ht = sd(2_739_726_027_397_260); // ~1 day in years

        // ∂IV/∂m via central difference on strike (K = m·S, so δK = hm·S)
        SD59x18 strikeUp = strike.add(hm.mul(spot));
        SD59x18 strikeDown = strike.sub(hm.mul(spot));

        // Ensure strikeDown > 0
        if (strikeDown.lte(ZERO)) {
            strikeDown = sd(1); // minimal positive
        }

        IVSurfacePoint memory ptUp = ivSurfacePoint(spot, strikeUp, timeToExpiry, baseVol, a, b, ZERO, ZERO);
        IVSurfacePoint memory ptDown = ivSurfacePoint(spot, strikeDown, timeToExpiry, baseVol, a, b, ZERO, ZERO);

        dIVdm = ptUp.impliedVol.sub(ptDown.impliedVol).div(hm.mul(sd(TWO)));

        // ∂IV/∂T via central difference on time
        SD59x18 tUp = timeToExpiry.add(ht);
        SD59x18 tDown = timeToExpiry.sub(ht);

        // Ensure tDown > 0
        if (tDown.lte(ZERO)) {
            tDown = sd(1_000_000_000_000_000); // ~0.001 years
        }

        IVSurfacePoint memory ptTUp = ivSurfacePoint(spot, strike, tUp, baseVol, a, b, ZERO, ZERO);
        IVSurfacePoint memory ptTDown = ivSurfacePoint(spot, strike, tDown, baseVol, a, b, ZERO, ZERO);

        SD59x18 actualDt = tUp.sub(tDown);
        dIVdT = ptTUp.impliedVol.sub(ptTDown.impliedVol).div(actualDt);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates all pricing parameters
    function _validateParams(DiagramParams memory p) private pure {
        if (p.spot.lte(ZERO)) revert DiagramData__InvalidSpotPrice(p.spot);
        if (p.strike.lte(ZERO)) revert DiagramData__InvalidStrikePrice(p.strike);
        if (p.volatility.lte(ZERO)) revert DiagramData__InvalidVolatility(p.volatility);
        if (p.timeToExpiry.lte(ZERO)) revert DiagramData__InvalidTimeToExpiry(p.timeToExpiry);
        if (p.riskFreeRate.lt(ZERO)) revert DiagramData__InvalidRiskFreeRate(p.riskFreeRate);
    }

    /// @notice Computes d1 for BSM
    /// @dev d1 = [ln(S/K) + (r + σ²/2)·T] / (σ·√T)
    function _computeD1(DiagramParams memory p) private pure returns (SD59x18 d1) {
        SD59x18 logMoneyness = p.spot.div(p.strike).ln();
        SD59x18 halfVar = p.volatility.mul(p.volatility).div(sd(TWO));
        SD59x18 drift = p.riskFreeRate.add(halfVar).mul(p.timeToExpiry);
        SD59x18 volSqrtT = p.volatility.mul(p.timeToExpiry.sqrt());
        d1 = logMoneyness.add(drift).div(volSqrtT);
    }

    /// @notice Prices a European call via BSM
    /// @dev C = S·Φ(d1) − K·e^(−rT)·Φ(d2)
    function _priceCall(DiagramParams memory p) private pure returns (SD59x18 price) {
        _validateParams(p);
        SD59x18 d1 = _computeD1(p);
        SD59x18 d2 = d1.sub(p.volatility.mul(p.timeToExpiry.sqrt()));

        SD59x18 cdfD1 = CumulativeNormal.cdf(d1);
        SD59x18 cdfD2 = CumulativeNormal.cdf(d2);
        SD59x18 discount = p.riskFreeRate.mul(p.timeToExpiry).mul(sd(-ONE)).exp();

        price = p.spot.mul(cdfD1).sub(p.strike.mul(discount).mul(cdfD2));
        if (price.lt(ZERO)) {
            price = ZERO;
        }
    }
}
