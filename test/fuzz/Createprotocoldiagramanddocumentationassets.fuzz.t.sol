// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    ProtocolDiagramData,
    DiagramParams,
    GasBreakdown,
    IVSurfacePoint,
    ProtocolGasComparison,
    OptionState
} from "../../src/libraries/Createprotocoldiagramanddocumentationassets.sol";

/// @title CreateprotocoldiagramanddocumentationassetsFuzzTest
/// @notice Fuzz tests for ProtocolDiagramData library
/// @dev Tests mathematical invariants across randomized inputs
contract CreateprotocoldiagramanddocumentationassetsFuzzTest is Test {
    // Bounds for realistic parameters
    uint256 internal constant MIN_PRICE = 1; // $1
    uint256 internal constant MAX_PRICE = 100_000; // $100k
    uint256 internal constant MIN_VOL_BPS = 50; // 0.5% vol
    uint256 internal constant MAX_VOL_BPS = 3000; // 300% vol
    uint256 internal constant MIN_TIME_DAYS = 1; // 1 day
    uint256 internal constant MAX_TIME_DAYS = 730; // 2 years
    uint256 internal constant MAX_RATE_BPS = 200; // 20% rate

    /// @dev Creates bounded DiagramParams from raw fuzz inputs
    function _makeParams(uint256 spotRaw, uint256 strikeRaw, uint256 volRaw, uint256 timeRaw, uint256 rateRaw)
        internal
        pure
        returns (DiagramParams memory p)
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        volRaw = bound(volRaw, MIN_VOL_BPS, MAX_VOL_BPS);
        timeRaw = bound(timeRaw, MIN_TIME_DAYS, MAX_TIME_DAYS);
        rateRaw = bound(rateRaw, 0, MAX_RATE_BPS);

        p = DiagramParams({
            spot: sd(int256(spotRaw * 1e18)),
            strike: sd(int256(strikeRaw * 1e18)),
            volatility: sd(int256(volRaw) * 1e14), // bps * 1e14 = fractional * 1e18
            riskFreeRate: sd(int256(rateRaw) * 1e14),
            timeToExpiry: sd(int256(timeRaw) * 2_739_726_027_397_260) // days * (1/365.25) in SD59x18
        });
    }

    // =========================================================================
    // Invariant: Gas breakdown components always sum to total
    // =========================================================================

    /// @notice BSM gas breakdown total is always the sum of its components
    function testFuzz_bsmGasBreakdown_sumInvariant(uint256) public pure {
        GasBreakdown memory bd = ProtocolDiagramData.bsmGasBreakdown();
        uint256 expected = bd.cdfGas + bd.expGas + bd.lnGas + bd.sqrtGas + bd.arithmeticGas;
        assertEq(bd.totalGas, expected, "Gas breakdown sum invariant");
    }

    // =========================================================================
    // Invariant: Full pipeline gas > pricing gas alone
    // =========================================================================

    /// @notice Full pipeline gas always exceeds pricing-only gas
    function testFuzz_fullPipeline_exceedsPricing(uint256) public pure {
        (uint256 pricingGas, uint256 greeksGas, uint256 totalGas) = ProtocolDiagramData.fullPipelineGasBreakdown();
        assertEq(totalGas, pricingGas + greeksGas, "Total = pricing + greeks");
        assertGt(totalGas, pricingGas, "Full pipeline > pricing alone");
        assertGt(greeksGas, 0, "Greeks gas > 0");
    }

    // =========================================================================
    // Invariant: State transition validity is consistent
    // =========================================================================

    /// @notice Only exactly 4 transitions are valid in the 5×5 state matrix
    function testFuzz_transitionMatrix_exactly4Valid(uint256) public pure {
        bool[25] memory matrix = ProtocolDiagramData.transitionMatrix();
        uint256 count = 0;
        for (uint256 i = 0; i < 25; i++) {
            if (matrix[i]) count++;
        }
        assertEq(count, 4, "Exactly 4 valid transitions");
    }

    /// @notice isValidTransition is deterministic for all state pairs
    function testFuzz_isValidTransition_deterministic(uint8 fromRaw, uint8 toRaw) public pure {
        fromRaw = uint8(bound(fromRaw, 0, 4));
        toRaw = uint8(bound(toRaw, 0, 4));

        bool result1 = ProtocolDiagramData.isValidTransition(OptionState(fromRaw), OptionState(toRaw));
        bool result2 = ProtocolDiagramData.isValidTransition(OptionState(fromRaw), OptionState(toRaw));
        assertEq(result1, result2, "Transition validity must be deterministic");
    }

    // =========================================================================
    // Invariant: Self-transitions are never valid
    // =========================================================================

    /// @notice No state can transition to itself
    function testFuzz_noSelfTransitions(uint8 stateRaw) public pure {
        stateRaw = uint8(bound(stateRaw, 0, 4));
        assertFalse(
            ProtocolDiagramData.isValidTransition(OptionState(stateRaw), OptionState(stateRaw)),
            "Self-transitions must be invalid"
        );
    }

    // =========================================================================
    // Invariant: Lifecycle gas cost is always positive
    // =========================================================================

    /// @notice Both lifecycle paths have positive gas cost
    function testFuzz_lifecycleGas_positive(bool exercised) public pure {
        uint256 gas = ProtocolDiagramData.lifecycleGasCost(exercised);
        assertGt(gas, 0, "Lifecycle gas must be positive");
    }

    /// @notice Exercise path is always more expensive than expiry path
    function testFuzz_exercisePath_moreExpensive(uint256) public pure {
        uint256 exerciseGas = ProtocolDiagramData.lifecycleGasCost(true);
        uint256 expiryGas = ProtocolDiagramData.lifecycleGasCost(false);
        assertGt(exerciseGas, expiryGas, "Exercise path must cost more than expiry path");
    }

    // =========================================================================
    // Invariant: Protocol gas comparison ordering
    // =========================================================================

    /// @notice MantissaFi gas < Lyra gas < Primitive gas, and oracle is cheapest
    function testFuzz_protocolGas_ordering(uint256) public pure {
        ProtocolGasComparison memory cmp = ProtocolDiagramData.protocolGasComparison();
        assertLt(cmp.deribitGas, cmp.mantissaGas, "Oracle < MantissaFi");
        assertLt(cmp.mantissaGas, cmp.lyraGas, "MantissaFi < Lyra");
        assertLt(cmp.lyraGas, cmp.primitiveGas, "Lyra < Primitive");
    }

    // =========================================================================
    // Invariant: Pricing error is non-negative
    // =========================================================================

    /// @notice Absolute and relative pricing errors are always >= 0
    function testFuzz_pricingError_nonNegative(
        uint256 spotRaw,
        uint256 strikeRaw,
        uint256 volRaw,
        uint256 timeRaw,
        uint256 rateRaw
    ) public pure {
        DiagramParams memory p = _makeParams(spotRaw, strikeRaw, volRaw, timeRaw, rateRaw);

        // Use a reasonable reference price
        SD59x18 referencePrice = sd(100e18);
        (SD59x18 absErr, SD59x18 relErr) = ProtocolDiagramData.pricingErrorAtPoint(p, referencePrice);
        assertGe(SD59x18.unwrap(absErr), 0, "Absolute error must be >= 0");
        assertGe(SD59x18.unwrap(relErr), 0, "Relative error must be >= 0");
    }

    // =========================================================================
    // Invariant: CDF accuracy (symmetry error) is always small
    // =========================================================================

    /// @notice CDF symmetry error |Φ(x) + Φ(-x) - 1| is bounded for reasonable x
    function testFuzz_cdfAccuracy_bounded(int128 xRaw) public pure {
        int256 x = bound(int256(xRaw), -5e18, 5e18);
        SD59x18 err = ProtocolDiagramData.cdfAccuracyAtPoint(sd(x));
        // Symmetry error should be tiny (< 1e-6)
        assertLt(SD59x18.unwrap(err), 1e12, "CDF symmetry error must be < 1e-6");
    }

    // =========================================================================
    // Invariant: CDF accuracy is symmetric in x
    // =========================================================================

    /// @notice cdfAccuracyAtPoint(x) == cdfAccuracyAtPoint(-x)
    function testFuzz_cdfAccuracy_symmetric(int128 xRaw) public pure {
        int256 x = bound(int256(xRaw), -5e18, 5e18);
        SD59x18 errPos = ProtocolDiagramData.cdfAccuracyAtPoint(sd(x));
        SD59x18 errNeg = ProtocolDiagramData.cdfAccuracyAtPoint(sd(-x));
        assertEq(SD59x18.unwrap(errPos), SD59x18.unwrap(errNeg), "CDF accuracy must be symmetric");
    }

    // =========================================================================
    // Invariant: Histogram bin classification is bounded
    // =========================================================================

    /// @notice classifyIntoBin always returns a valid bin index < numBins
    function testFuzz_classifyIntoBin_bounded(uint256 errorRaw, uint256 binWidthRaw, uint256 numBinsRaw) public pure {
        errorRaw = bound(errorRaw, 0, 1e24);
        binWidthRaw = bound(binWidthRaw, 1, 1e24);
        numBinsRaw = bound(numBinsRaw, 1, 1000);

        uint256 binIndex =
            ProtocolDiagramData.classifyIntoBin(sd(int256(errorRaw)), sd(int256(binWidthRaw)), numBinsRaw);
        assertLt(binIndex, numBinsRaw, "Bin index must be < numBins");
    }

    // =========================================================================
    // Invariant: IV surface point has IV >= 1% (floor)
    // =========================================================================

    /// @notice IV surface always returns IV >= 1% (the floor)
    function testFuzz_ivSurfacePoint_ivFloor(uint256 spotRaw, uint256 strikeRaw, uint256 timeRaw, uint256 baseVolRaw)
        public
        pure
    {
        spotRaw = bound(spotRaw, 1, 100_000);
        strikeRaw = bound(strikeRaw, 1, 100_000);
        timeRaw = bound(timeRaw, 1, 730);
        baseVolRaw = bound(baseVolRaw, 10, 3000); // 0.1% to 300%

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));
        SD59x18 t = sd(int256(timeRaw) * 2_739_726_027_397_260);
        SD59x18 baseVol = sd(int256(baseVolRaw) * 1e14);

        IVSurfacePoint memory pt =
            ProtocolDiagramData.ivSurfacePoint(spot, strike, t, baseVol, sd(0), sd(0), ZERO, ZERO);

        // IV should always be >= 1% (0.01 = 1e16)
        assertGe(SD59x18.unwrap(pt.impliedVol), 10_000_000_000_000_000, "IV must be >= 1% floor");
    }

    // =========================================================================
    // Invariant: IV surface moneyness is K/S
    // =========================================================================

    /// @notice IV surface point moneyness equals strike / spot
    function testFuzz_ivSurfacePoint_moneynessIsKOverS(uint256 spotRaw, uint256 strikeRaw) public pure {
        spotRaw = bound(spotRaw, 1, 100_000);
        strikeRaw = bound(strikeRaw, 1, 100_000);

        SD59x18 spot = sd(int256(spotRaw * 1e18));
        SD59x18 strike = sd(int256(strikeRaw * 1e18));
        SD59x18 t = sd(250_000_000_000_000_000); // ~3 months
        SD59x18 baseVol = sd(800_000_000_000_000_000); // 80%

        IVSurfacePoint memory pt =
            ProtocolDiagramData.ivSurfacePoint(spot, strike, t, baseVol, sd(0), sd(0), ZERO, ZERO);

        SD59x18 expected = strike.div(spot);
        // Allow tiny rounding difference (1 ULP)
        assertApproxEqAbs(SD59x18.unwrap(pt.moneyness), SD59x18.unwrap(expected), 1, "Moneyness must equal K/S");
    }

    // =========================================================================
    // Invariant: Volatility smile has correct array length
    // =========================================================================

    /// @notice volatilitySmile returns an array of exactly numPoints elements
    function testFuzz_volatilitySmile_correctLength(uint256 numPointsRaw) public pure {
        numPointsRaw = bound(numPointsRaw, 1, 20);

        SD59x18[] memory smile = ProtocolDiagramData.volatilitySmile(
            sd(3000e18),
            sd(250_000_000_000_000_000),
            sd(800_000_000_000_000_000),
            sd(0),
            sd(0),
            sd(800_000_000_000_000_000),
            sd(1_200_000_000_000_000_000),
            numPointsRaw
        );
        assertEq(smile.length, numPointsRaw, "Smile array length must match numPoints");
    }

    // =========================================================================
    // Invariant: Term structure has correct array length
    // =========================================================================

    /// @notice termStructure returns an array of exactly numPoints elements
    function testFuzz_termStructure_correctLength(uint256 numPointsRaw) public pure {
        numPointsRaw = bound(numPointsRaw, 1, 20);

        SD59x18[] memory ts = ProtocolDiagramData.termStructure(
            sd(3000e18),
            sd(1e18),
            sd(800_000_000_000_000_000),
            sd(0),
            sd(0),
            sd(19_178_082_191_780_821), // ~7 days
            sd(1e18), // ~1 year
            numPointsRaw
        );
        assertEq(ts.length, numPointsRaw, "Term structure array length must match numPoints");
    }
}
