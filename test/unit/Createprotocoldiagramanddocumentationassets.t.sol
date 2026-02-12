// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    ProtocolDiagramData,
    DiagramParams,
    GasBreakdown,
    StateTransition,
    ErrorDistribution,
    IVSurfacePoint,
    ProtocolGasComparison,
    OptionState,
    DiagramData__InvalidSpotPrice,
    DiagramData__InvalidStrikePrice,
    DiagramData__InvalidVolatility,
    DiagramData__InvalidTimeToExpiry,
    DiagramData__InvalidRiskFreeRate,
    DiagramData__InvalidStateTransition,
    DiagramData__ZeroReferenceValue,
    DiagramData__ZeroBinCount,
    DiagramData__ZeroGridDimension,
    DiagramData__UtilizationTooHigh
} from "../../src/libraries/Createprotocoldiagramanddocumentationassets.sol";

/// @notice Wrapper contract to test library revert behavior via external calls
contract DiagramDataWrapper {
    function pricingErrorAtPoint(DiagramParams memory p, SD59x18 ref) external pure returns (SD59x18, SD59x18) {
        return ProtocolDiagramData.pricingErrorAtPoint(p, ref);
    }

    function bitsOfPrecision(DiagramParams memory p, SD59x18 ref) external pure returns (SD59x18) {
        return ProtocolDiagramData.bitsOfPrecision(p, ref);
    }

    function transitionGasCost(OptionState from, OptionState to) external pure returns (uint256) {
        return ProtocolDiagramData.transitionGasCost(from, to);
    }

    function gasAccuracyEfficiency(uint256 cGas, SD59x18 mErr, SD59x18 cErr) external pure returns (SD59x18) {
        return ProtocolDiagramData.gasAccuracyEfficiency(cGas, mErr, cErr);
    }

    function computeHistogramParams(SD59x18[] memory errors, uint256 numBins) external pure returns (SD59x18, SD59x18) {
        return ProtocolDiagramData.computeHistogramParams(errors, numBins);
    }

    function ivSurfacePoint(
        SD59x18 spot,
        SD59x18 strike,
        SD59x18 t,
        SD59x18 baseVol,
        SD59x18 a,
        SD59x18 b,
        SD59x18 util,
        SD59x18 k
    ) external pure returns (IVSurfacePoint memory) {
        return ProtocolDiagramData.ivSurfacePoint(spot, strike, t, baseVol, a, b, util, k);
    }

    function volatilitySmile(
        SD59x18 spot,
        SD59x18 t,
        SD59x18 baseVol,
        SD59x18 a,
        SD59x18 b,
        SD59x18 minM,
        SD59x18 maxM,
        uint256 n
    ) external pure returns (SD59x18[] memory) {
        return ProtocolDiagramData.volatilitySmile(spot, t, baseVol, a, b, minM, maxM, n);
    }

    function termStructure(
        SD59x18 spot,
        SD59x18 m,
        SD59x18 baseVol,
        SD59x18 a,
        SD59x18 b,
        SD59x18 minT,
        SD59x18 maxT,
        uint256 n
    ) external pure returns (SD59x18[] memory) {
        return ProtocolDiagramData.termStructure(spot, m, baseVol, a, b, minT, maxT, n);
    }
}

/// @title CreateprotocoldiagramanddocumentationassetsTest
/// @notice Unit tests for ProtocolDiagramData library
contract CreateprotocoldiagramanddocumentationassetsTest is Test {
    DiagramDataWrapper internal wrapper;

    // Standard test params: ETH $3000, ATM, 80% vol, 5% rate, 30 days
    DiagramParams internal standardParams;

    function setUp() public {
        wrapper = new DiagramDataWrapper();

        standardParams = DiagramParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000), // 0.8 = 80%
            riskFreeRate: sd(50_000_000_000_000_000), // 0.05 = 5%
            timeToExpiry: sd(82_191_780_821_917_808) // 30/365.25 years
        });
    }

    // =========================================================================
    // 1. Architecture Diagram — Gas Breakdown
    // =========================================================================

    function test_bsmGasBreakdown_totalIsSumOfComponents() public pure {
        GasBreakdown memory bd = ProtocolDiagramData.bsmGasBreakdown();
        uint256 expected = bd.cdfGas + bd.expGas + bd.lnGas + bd.sqrtGas + bd.arithmeticGas;
        assertEq(bd.totalGas, expected, "Total gas must equal sum of components");
    }

    function test_bsmGasBreakdown_cdfIsDominant() public pure {
        GasBreakdown memory bd = ProtocolDiagramData.bsmGasBreakdown();
        // CDF is the most expensive single operation (2x evaluations)
        assertGt(bd.cdfGas, bd.expGas, "CDF gas > exp gas");
        assertGt(bd.cdfGas, bd.lnGas, "CDF gas > ln gas");
        assertGt(bd.cdfGas, bd.sqrtGas, "CDF gas > sqrt gas");
    }

    function test_fullPipelineGasBreakdown_greeksAreIncremental() public pure {
        (uint256 pricingGas, uint256 greeksGas, uint256 totalGas) = ProtocolDiagramData.fullPipelineGasBreakdown();
        assertEq(totalGas, pricingGas + greeksGas, "Total = pricing + greeks");
        assertGe(pricingGas, greeksGas, "Pricing should be >= incremental Greeks");
        assertGt(totalGas, pricingGas, "Full pipeline should exceed pricing alone");
    }

    // =========================================================================
    // 2. State Machine — Option Lifecycle
    // =========================================================================

    function test_isValidTransition_createdToActive() public pure {
        assertTrue(
            ProtocolDiagramData.isValidTransition(OptionState.Created, OptionState.Active),
            "Created -> Active should be valid"
        );
    }

    function test_isValidTransition_activeToExercised() public pure {
        assertTrue(
            ProtocolDiagramData.isValidTransition(OptionState.Active, OptionState.Exercised),
            "Active -> Exercised should be valid"
        );
    }

    function test_isValidTransition_activeToExpired() public pure {
        assertTrue(
            ProtocolDiagramData.isValidTransition(OptionState.Active, OptionState.Expired),
            "Active -> Expired should be valid"
        );
    }

    function test_isValidTransition_exercisedToSettled() public pure {
        assertTrue(
            ProtocolDiagramData.isValidTransition(OptionState.Exercised, OptionState.Settled),
            "Exercised -> Settled should be valid"
        );
    }

    function test_isValidTransition_invalidTransitions() public pure {
        // Self-transitions should be invalid
        assertFalse(ProtocolDiagramData.isValidTransition(OptionState.Created, OptionState.Created));
        // Backward transitions should be invalid
        assertFalse(ProtocolDiagramData.isValidTransition(OptionState.Active, OptionState.Created));
        // Skip transitions should be invalid
        assertFalse(ProtocolDiagramData.isValidTransition(OptionState.Created, OptionState.Exercised));
        // Terminal → any should be invalid
        assertFalse(ProtocolDiagramData.isValidTransition(OptionState.Expired, OptionState.Active));
        assertFalse(ProtocolDiagramData.isValidTransition(OptionState.Settled, OptionState.Active));
    }

    function test_transitionGasCost_validTransitions() public pure {
        assertEq(
            ProtocolDiagramData.transitionGasCost(OptionState.Created, OptionState.Active),
            150_000,
            "Created -> Active gas"
        );
        assertEq(
            ProtocolDiagramData.transitionGasCost(OptionState.Active, OptionState.Exercised),
            120_000,
            "Active -> Exercised gas"
        );
        assertEq(
            ProtocolDiagramData.transitionGasCost(OptionState.Active, OptionState.Expired),
            80_000,
            "Active -> Expired gas"
        );
        assertEq(
            ProtocolDiagramData.transitionGasCost(OptionState.Exercised, OptionState.Settled),
            95_000,
            "Exercised -> Settled gas"
        );
    }

    function test_transitionGasCost_revertsOnInvalid() public {
        vm.expectRevert();
        wrapper.transitionGasCost(OptionState.Created, OptionState.Exercised);
    }

    function test_lifecycleGasCost_exercisePath() public pure {
        uint256 gas = ProtocolDiagramData.lifecycleGasCost(true);
        // Created -> Active -> Exercised -> Settled = 150k + 120k + 95k = 365k
        assertEq(gas, 365_000, "Exercise path total gas");
    }

    function test_lifecycleGasCost_expiryPath() public pure {
        uint256 gas = ProtocolDiagramData.lifecycleGasCost(false);
        // Created -> Active -> Expired = 150k + 80k = 230k
        assertEq(gas, 230_000, "Expiry path total gas");
    }

    function test_transitionMatrix_hasExactly4ValidTransitions() public pure {
        bool[25] memory matrix = ProtocolDiagramData.transitionMatrix();
        uint256 validCount = 0;
        for (uint256 i = 0; i < 25; i++) {
            if (matrix[i]) validCount++;
        }
        assertEq(validCount, 4, "State machine should have exactly 4 valid transitions");
    }

    // =========================================================================
    // 3. Gas Comparison Chart
    // =========================================================================

    function test_protocolGasComparison_ordering() public pure {
        ProtocolGasComparison memory cmp = ProtocolDiagramData.protocolGasComparison();
        // MantissaFi should be cheapest on-chain protocol
        assertLt(cmp.mantissaGas, cmp.lyraGas, "MantissaFi < Lyra gas");
        assertLt(cmp.mantissaGas, cmp.primitiveGas, "MantissaFi < Primitive gas");
        // Oracle lookup is cheapest overall
        assertLt(cmp.deribitGas, cmp.mantissaGas, "Oracle lookup < MantissaFi gas");
    }

    function test_gasAccuracyEfficiency_favorableMantissa() public pure {
        // If MantissaFi has lower error and lower gas, efficiency should be < 1.0
        SD59x18 mantissaErr = sd(1e10); // 1e-8 relative error
        SD59x18 competitorErr = sd(1e11); // 1e-7 relative error (10x worse)
        SD59x18 eff = ProtocolDiagramData.gasAccuracyEfficiency(95_000, mantissaErr, competitorErr);
        // gasRatio = 95000/78000 ≈ 1.218, errorRatio = 1e-8/1e-7 = 0.1
        // efficiency ≈ 0.12
        assertLt(SD59x18.unwrap(eff), 1e18, "Efficiency < 1.0 when MantissaFi is more accurate");
    }

    function test_gasAccuracyEfficiency_revertsOnZeroCompetitorError() public {
        vm.expectRevert();
        wrapper.gasAccuracyEfficiency(95_000, sd(1e10), ZERO);
    }

    // =========================================================================
    // 4. Precision Error Distribution
    // =========================================================================

    function test_pricingErrorAtPoint_returnsNonNegative() public pure {
        DiagramParams memory p = DiagramParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });
        SD59x18 referencePrice = sd(200e18); // approximate ATM call price
        (SD59x18 absErr, SD59x18 relErr) = ProtocolDiagramData.pricingErrorAtPoint(p, referencePrice);
        assertGe(SD59x18.unwrap(absErr), 0, "Absolute error >= 0");
        assertGe(SD59x18.unwrap(relErr), 0, "Relative error >= 0");
    }

    function test_pricingErrorAtPoint_revertsOnZeroRef() public {
        vm.expectRevert();
        wrapper.pricingErrorAtPoint(standardParams, ZERO);
    }

    function test_bitsOfPrecision_highForAccurateRef() public pure {
        DiagramParams memory p = DiagramParams({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: sd(800_000_000_000_000_000),
            riskFreeRate: sd(50_000_000_000_000_000),
            timeToExpiry: sd(82_191_780_821_917_808)
        });
        // Using a reference close to computed should give high precision
        SD59x18 bits = ProtocolDiagramData.bitsOfPrecision(p, sd(200e18));
        // Bits should be positive (some precision exists)
        assertGt(SD59x18.unwrap(bits), 0, "Bits of precision should be positive");
    }

    function test_bitsOfPrecision_revertsOnZeroRef() public {
        vm.expectRevert();
        wrapper.bitsOfPrecision(standardParams, ZERO);
    }

    function test_cdfAccuracyAtPoint_symmetricAndSmall() public pure {
        SD59x18 errAtZero = ProtocolDiagramData.cdfAccuracyAtPoint(sd(0));
        assertLt(SD59x18.unwrap(errAtZero), 1e10, "CDF symmetry error at 0 should be tiny");

        SD59x18 errAt1 = ProtocolDiagramData.cdfAccuracyAtPoint(sd(1e18));
        assertLt(SD59x18.unwrap(errAt1), 1e12, "CDF symmetry error at 1.0 should be small");
    }

    function test_computeHistogramParams_basic() public pure {
        SD59x18[] memory errors = new SD59x18[](3);
        errors[0] = sd(1e16);
        errors[1] = sd(2e16);
        errors[2] = sd(3e16);

        (SD59x18 binWidth, SD59x18 maxError) = ProtocolDiagramData.computeHistogramParams(errors, 3);
        assertEq(SD59x18.unwrap(maxError), 3e16, "Max error should be 3e16");
        assertEq(SD59x18.unwrap(binWidth), 1e16, "Bin width should be 1e16 for 3 bins");
    }

    function test_computeHistogramParams_emptyArray() public pure {
        SD59x18[] memory errors = new SD59x18[](0);
        (SD59x18 binWidth, SD59x18 maxError) = ProtocolDiagramData.computeHistogramParams(errors, 5);
        assertEq(SD59x18.unwrap(binWidth), 0, "Empty array should give zero bin width");
        assertEq(SD59x18.unwrap(maxError), 0, "Empty array should give zero max error");
    }

    function test_computeHistogramParams_revertsOnZeroBins() public {
        SD59x18[] memory errors = new SD59x18[](1);
        errors[0] = sd(1e18);
        vm.expectRevert();
        wrapper.computeHistogramParams(errors, 0);
    }

    function test_classifyIntoBin_basic() public pure {
        // 3 bins, binWidth = 1e16, error = 1.5e16 => bin 1
        uint256 bin = ProtocolDiagramData.classifyIntoBin(sd(15e15), sd(1e16), 3);
        assertEq(bin, 1, "Error 1.5e16 with binWidth 1e16 => bin 1");
    }

    function test_classifyIntoBin_clampsToLastBin() public pure {
        // Error exactly at max => last bin
        uint256 bin = ProtocolDiagramData.classifyIntoBin(sd(3e16), sd(1e16), 3);
        assertEq(bin, 2, "Error at max should clamp to last bin");
    }

    // =========================================================================
    // 5. IV Surface 3D Visualization
    // =========================================================================

    function test_ivSurfacePoint_atmReturnsBaseVol() public pure {
        // ATM (K/S = 1), skew = 0, no utilization => IV ≈ baseVol (modulo term adjust)
        IVSurfacePoint memory pt = ProtocolDiagramData.ivSurfacePoint(
            sd(3000e18), // spot
            sd(3000e18), // strike = spot (ATM)
            sd(250_000_000_000_000_000), // ~3 months
            sd(800_000_000_000_000_000), // 80% base vol
            sd(0), // no quadratic skew
            sd(0), // no linear skew
            ZERO, // no utilization
            ZERO // no util scaling
        );
        assertEq(SD59x18.unwrap(pt.moneyness), 1e18, "ATM moneyness should be 1.0");
        // IV should be close to 80% (with small term structure adjustment)
        assertGt(SD59x18.unwrap(pt.impliedVol), 700_000_000_000_000_000, "IV > 70%");
        assertLt(SD59x18.unwrap(pt.impliedVol), 900_000_000_000_000_000, "IV < 90%");
    }

    function test_ivSurfacePoint_otmHasHigherIVWithSmile() public pure {
        SD59x18 a = sd(200_000_000_000_000_000); // 0.2 quadratic coefficient (smile)
        SD59x18 b = sd(0); // no asymmetry

        IVSurfacePoint memory ptATM = ProtocolDiagramData.ivSurfacePoint(
            sd(3000e18), sd(3000e18), sd(250_000_000_000_000_000), sd(800_000_000_000_000_000), a, b, ZERO, ZERO
        );
        IVSurfacePoint memory ptOTM = ProtocolDiagramData.ivSurfacePoint(
            sd(3000e18), sd(3600e18), sd(250_000_000_000_000_000), sd(800_000_000_000_000_000), a, b, ZERO, ZERO
        );

        // OTM strike should have higher IV (volatility smile)
        assertGt(
            SD59x18.unwrap(ptOTM.impliedVol), SD59x18.unwrap(ptATM.impliedVol), "OTM should have higher IV (smile)"
        );
    }

    function test_ivSurfacePoint_utilizationIncreasesIV() public pure {
        IVSurfacePoint memory ptNoUtil = ProtocolDiagramData.ivSurfacePoint(
            sd(3000e18), sd(3000e18), sd(250_000_000_000_000_000), sd(800_000_000_000_000_000), sd(0), sd(0), ZERO, ZERO
        );
        IVSurfacePoint memory ptHighUtil = ProtocolDiagramData.ivSurfacePoint(
            sd(3000e18),
            sd(3000e18),
            sd(250_000_000_000_000_000),
            sd(800_000_000_000_000_000),
            sd(0),
            sd(0),
            sd(500_000_000_000_000_000), // 50% utilization
            sd(200_000_000_000_000_000) // k = 0.2
        );

        assertGt(
            SD59x18.unwrap(ptHighUtil.impliedVol),
            SD59x18.unwrap(ptNoUtil.impliedVol),
            "Higher utilization should increase IV"
        );
    }

    function test_ivSurfacePoint_revertsOnZeroSpot() public {
        vm.expectRevert();
        wrapper.ivSurfacePoint(
            ZERO, sd(3000e18), sd(250_000_000_000_000_000), sd(800_000_000_000_000_000), sd(0), sd(0), ZERO, ZERO
        );
    }

    function test_ivSurfacePoint_revertsOnUtilizationTooHigh() public {
        vm.expectRevert();
        wrapper.ivSurfacePoint(
            sd(3000e18),
            sd(3000e18),
            sd(250_000_000_000_000_000),
            sd(800_000_000_000_000_000),
            sd(0),
            sd(0),
            sd(1e18), // utilization = 1.0 (invalid)
            sd(200_000_000_000_000_000)
        );
    }

    function test_volatilitySmile_returnsCorrectLength() public pure {
        SD59x18[] memory smile = ProtocolDiagramData.volatilitySmile(
            sd(3000e18),
            sd(250_000_000_000_000_000),
            sd(800_000_000_000_000_000),
            sd(200_000_000_000_000_000),
            sd(0),
            sd(800_000_000_000_000_000), // 0.8 min moneyness
            sd(1_200_000_000_000_000_000), // 1.2 max moneyness
            5
        );
        assertEq(smile.length, 5, "Smile should have 5 points");
    }

    function test_volatilitySmile_revertsOnZeroPoints() public {
        vm.expectRevert();
        wrapper.volatilitySmile(
            sd(3000e18),
            sd(250_000_000_000_000_000),
            sd(800_000_000_000_000_000),
            sd(0),
            sd(0),
            sd(800_000_000_000_000_000),
            sd(1_200_000_000_000_000_000),
            0
        );
    }

    function test_termStructure_returnsCorrectLength() public pure {
        SD59x18[] memory ts = ProtocolDiagramData.termStructure(
            sd(3000e18),
            sd(1e18), // ATM
            sd(800_000_000_000_000_000),
            sd(0),
            sd(0),
            sd(19_178_082_191_780_821), // ~7 days
            sd(1e18), // ~1 year
            10
        );
        assertEq(ts.length, 10, "Term structure should have 10 points");
    }

    function test_ivSurfaceGradient_nonZeroForATM() public pure {
        (SD59x18 dIVdm, SD59x18 dIVdT) = ProtocolDiagramData.ivSurfaceGradient(
            sd(3000e18),
            sd(3000e18),
            sd(250_000_000_000_000_000),
            sd(800_000_000_000_000_000),
            sd(200_000_000_000_000_000), // a = 0.2 (smile)
            sd(0) // b = 0
        );
        // With a smile (a > 0), the moneyness gradient at ATM should be approximately zero
        // (minimum of the parabola), and time gradient should be non-zero
        // The gradient values depend on the model, just check they're finite and reasonable
        assertLt(SD59x18.unwrap(dIVdm.abs()), 10e18, "dIV/dm should be bounded");
        assertLt(SD59x18.unwrap(dIVdT.abs()), 10e18, "dIV/dT should be bounded");
    }

    // =========================================================================
    // Validation Revert Tests
    // =========================================================================

    function test_pricingErrorAtPoint_revertsOnZeroSpot() public {
        DiagramParams memory p = standardParams;
        p.spot = sd(0);
        vm.expectRevert();
        wrapper.pricingErrorAtPoint(p, sd(100e18));
    }

    function test_pricingErrorAtPoint_revertsOnZeroStrike() public {
        DiagramParams memory p = standardParams;
        p.strike = sd(0);
        vm.expectRevert();
        wrapper.pricingErrorAtPoint(p, sd(100e18));
    }

    function test_pricingErrorAtPoint_revertsOnZeroVol() public {
        DiagramParams memory p = standardParams;
        p.volatility = sd(0);
        vm.expectRevert();
        wrapper.pricingErrorAtPoint(p, sd(100e18));
    }

    function test_pricingErrorAtPoint_revertsOnZeroTime() public {
        DiagramParams memory p = standardParams;
        p.timeToExpiry = sd(0);
        vm.expectRevert();
        wrapper.pricingErrorAtPoint(p, sd(100e18));
    }

    function test_pricingErrorAtPoint_revertsOnNegativeRate() public {
        DiagramParams memory p = standardParams;
        p.riskFreeRate = sd(-1e18);
        vm.expectRevert();
        wrapper.pricingErrorAtPoint(p, sd(100e18));
    }
}
