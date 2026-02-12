// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import {
    HestonModel,
    HestonParams,
    HestonResult,
    HestonModel__InvalidSpotPrice,
    HestonModel__InvalidStrikePrice,
    HestonModel__InvalidTimeToExpiry,
    HestonModel__InvalidRiskFreeRate,
    HestonModel__InvalidInitialVariance,
    HestonModel__InvalidLongRunVariance,
    HestonModel__InvalidMeanReversionSpeed,
    HestonModel__InvalidVolOfVol,
    HestonModel__InvalidCorrelation
} from "../../src/libraries/ExploreHestonstochasticvolatilitymodelextension.sol";

/// @notice Wrapper contract to expose library functions for revert testing
contract HestonModelWrapper {
    function priceCall(HestonParams memory p) external pure returns (SD59x18) {
        return HestonModel.priceCall(p);
    }

    function pricePut(HestonParams memory p) external pure returns (SD59x18) {
        return HestonModel.pricePut(p);
    }

    function priceHeston(HestonParams memory p) external pure returns (HestonResult memory) {
        return HestonModel.priceHeston(p);
    }

    function fellerRatio(HestonParams memory p) external pure returns (SD59x18) {
        return HestonModel.fellerRatio(p);
    }

    function checkFellerCondition(HestonParams memory p) external pure returns (bool) {
        return HestonModel.checkFellerCondition(p);
    }

    function expectedVariance(HestonParams memory p) external pure returns (SD59x18) {
        return HestonModel.expectedVariance(p);
    }

    function averageExpectedVariance(HestonParams memory p) external pure returns (SD59x18) {
        return HestonModel.averageExpectedVariance(p);
    }

    function hestonImpliedVol(HestonParams memory p) external pure returns (SD59x18) {
        return HestonModel.hestonImpliedVol(p);
    }

    function callDelta(HestonParams memory p) external pure returns (SD59x18) {
        return HestonModel.callDelta(p);
    }

    function callVega(HestonParams memory p) external pure returns (SD59x18) {
        return HestonModel.callVega(p);
    }
}

/// @title ExploreHestonstochasticvolatilitymodelextensionTest
/// @notice Unit tests for HestonModel library
contract ExploreHestonstochasticvolatilitymodelextensionTest is Test {
    HestonModelWrapper internal wrapper;

    // Standard Heston test parameters (typical crypto options)
    // S=3000, K=3000, r=5%, T=0.25 (3 months), v0=0.04 (vol=20%), theta=0.04, kappa=2, xi=0.3, rho=-0.7
    SD59x18 internal constant SPOT = SD59x18.wrap(3000e18);
    SD59x18 internal constant STRIKE = SD59x18.wrap(3000e18);
    SD59x18 internal constant RATE = SD59x18.wrap(50000000000000000); // 0.05
    SD59x18 internal constant TIME = SD59x18.wrap(250000000000000000); // 0.25
    SD59x18 internal constant V0 = SD59x18.wrap(40000000000000000); // 0.04
    SD59x18 internal constant THETA = SD59x18.wrap(40000000000000000); // 0.04
    SD59x18 internal constant KAPPA = SD59x18.wrap(2000000000000000000); // 2.0
    SD59x18 internal constant XI = SD59x18.wrap(300000000000000000); // 0.3
    SD59x18 internal constant RHO = SD59x18.wrap(-700000000000000000); // -0.7

    function setUp() public {
        wrapper = new HestonModelWrapper();
    }

    function _defaultParams() internal pure returns (HestonParams memory p) {
        p.spot = SPOT;
        p.strike = STRIKE;
        p.riskFreeRate = RATE;
        p.timeToExpiry = TIME;
        p.v0 = V0;
        p.theta = THETA;
        p.kappa = KAPPA;
        p.xi = XI;
        p.rho = RHO;
    }

    // =========================================================================
    // Feller Condition Tests
    // =========================================================================

    function test_fellerRatio_standardParams() public pure {
        HestonParams memory p = _defaultParams();
        // 2 * 2.0 * 0.04 / 0.3^2 = 0.16 / 0.09 ≈ 1.777
        SD59x18 ratio = HestonModel.fellerRatio(p);
        assertGt(SD59x18.unwrap(ratio), 1e18, "Feller ratio should be > 1 for standard params");
    }

    function test_checkFellerCondition_satisfied() public pure {
        HestonParams memory p = _defaultParams();
        assertTrue(HestonModel.checkFellerCondition(p), "Feller condition should be satisfied");
    }

    function test_checkFellerCondition_violated() public pure {
        HestonParams memory p = _defaultParams();
        // Set xi very high to violate Feller: 2*2*0.04 = 0.16 vs xi^2 = 4.0
        p.xi = sd(2e18);
        assertFalse(HestonModel.checkFellerCondition(p), "Feller condition should be violated");
    }

    // =========================================================================
    // Expected Variance Tests
    // =========================================================================

    function test_expectedVariance_atExpiry() public pure {
        HestonParams memory p = _defaultParams();
        SD59x18 ev = HestonModel.expectedVariance(p);
        // When v0 == theta, expected variance should equal theta at any time
        assertApproxEqRel(
            SD59x18.unwrap(ev), SD59x18.unwrap(THETA), 1e14, "Expected variance should equal theta when v0=theta"
        );
    }

    function test_expectedVariance_v0HigherThanTheta() public pure {
        HestonParams memory p = _defaultParams();
        p.v0 = sd(100000000000000000); // 0.10 (higher than theta=0.04)
        SD59x18 ev = HestonModel.expectedVariance(p);
        // E[v(T)] should be between theta and v0
        assertGt(SD59x18.unwrap(ev), SD59x18.unwrap(THETA), "Expected var > theta when v0 > theta");
        assertLt(SD59x18.unwrap(ev), 100000000000000000, "Expected var < v0 when v0 > theta");
    }

    function test_expectedVariance_v0LowerThanTheta() public pure {
        HestonParams memory p = _defaultParams();
        p.v0 = sd(10000000000000000); // 0.01 (lower than theta=0.04)
        SD59x18 ev = HestonModel.expectedVariance(p);
        // E[v(T)] should be between v0 and theta
        assertGt(SD59x18.unwrap(ev), 10000000000000000, "Expected var > v0 when v0 < theta");
        assertLt(SD59x18.unwrap(ev), SD59x18.unwrap(THETA), "Expected var < theta when v0 < theta");
    }

    // =========================================================================
    // Average Expected Variance Tests
    // =========================================================================

    function test_averageExpectedVariance_v0EqualsTheta() public pure {
        HestonParams memory p = _defaultParams();
        // When v0 == theta, average expected variance = theta
        SD59x18 avgVar = HestonModel.averageExpectedVariance(p);
        assertApproxEqRel(
            SD59x18.unwrap(avgVar), SD59x18.unwrap(THETA), 1e14, "Avg expected var should equal theta when v0=theta"
        );
    }

    function test_averageExpectedVariance_positive() public pure {
        HestonParams memory p = _defaultParams();
        p.v0 = sd(100000000000000000); // 0.10
        SD59x18 avgVar = HestonModel.averageExpectedVariance(p);
        assertGt(SD59x18.unwrap(avgVar), 0, "Average expected variance must be positive");
    }

    // =========================================================================
    // Call Pricing Tests
    // =========================================================================

    function test_priceCall_ATM_positive() public pure {
        HestonParams memory p = _defaultParams();
        SD59x18 price = HestonModel.priceCall(p);
        assertGt(SD59x18.unwrap(price), 0, "ATM call price must be positive");
    }

    function test_priceCall_ATM_reasonableRange() public pure {
        // For ATM options with ~20% vol, 3 months, price should be ~3-8% of spot
        HestonParams memory p = _defaultParams();
        SD59x18 price = HestonModel.priceCall(p);
        int256 priceRaw = SD59x18.unwrap(price);
        // Price should be between $30 and $300 for a $3000 underlying
        assertGt(priceRaw, 30e18, "ATM call price too low");
        assertLt(priceRaw, 300e18, "ATM call price too high");
    }

    function test_priceCall_deepITM() public pure {
        HestonParams memory p = _defaultParams();
        p.strike = sd(2000e18); // deep ITM
        SD59x18 price = HestonModel.priceCall(p);
        // Deep ITM call should be close to intrinsic value S - K*e^(-rT) ≈ 1000
        assertGt(SD59x18.unwrap(price), 900e18, "Deep ITM call should be > $900");
    }

    function test_priceCall_deepOTM() public pure {
        HestonParams memory p = _defaultParams();
        p.strike = sd(5000e18); // deep OTM
        SD59x18 price = HestonModel.priceCall(p);
        // Deep OTM call should be close to zero
        assertLt(SD59x18.unwrap(price), 50e18, "Deep OTM call should be near zero");
    }

    function test_priceCall_neverNegative() public pure {
        HestonParams memory p = _defaultParams();
        p.strike = sd(10000e18); // very deep OTM
        SD59x18 price = HestonModel.priceCall(p);
        assertGe(SD59x18.unwrap(price), 0, "Call price must be >= 0");
    }

    // =========================================================================
    // Put Pricing Tests
    // =========================================================================

    function test_pricePut_ATM_positive() public pure {
        HestonParams memory p = _defaultParams();
        SD59x18 price = HestonModel.pricePut(p);
        assertGt(SD59x18.unwrap(price), 0, "ATM put price must be positive");
    }

    function test_pricePut_deepITM() public pure {
        HestonParams memory p = _defaultParams();
        p.strike = sd(5000e18); // deep ITM put
        SD59x18 price = HestonModel.pricePut(p);
        // Deep ITM put should be close to K*e^(-rT) - S ≈ 2000
        assertGt(SD59x18.unwrap(price), 1800e18, "Deep ITM put should be > $1800");
    }

    function test_pricePut_neverNegative() public pure {
        HestonParams memory p = _defaultParams();
        p.strike = sd(100e18); // very deep OTM put
        SD59x18 price = HestonModel.pricePut(p);
        assertGe(SD59x18.unwrap(price), 0, "Put price must be >= 0");
    }

    // =========================================================================
    // Put-Call Parity Tests
    // =========================================================================

    function test_putCallParity() public pure {
        HestonParams memory p = _defaultParams();
        SD59x18 callPrice = HestonModel.priceCall(p);
        SD59x18 putPrice = HestonModel.pricePut(p);

        // Put-call parity: C - P = S - K*e^(-rT)
        int256 lhs = SD59x18.unwrap(callPrice) - SD59x18.unwrap(putPrice);

        // K*e^(-rT)
        SD59x18 discount = sd(-50000000000000000).mul(sd(250000000000000000)).exp(); // e^(-0.05*0.25)
        int256 rhs = SD59x18.unwrap(SPOT) - SD59x18.unwrap(STRIKE.mul(discount));

        // Allow 1% relative tolerance for numerical integration approximation
        assertApproxEqRel(
            uint256(lhs > 0 ? lhs : -lhs), uint256(rhs > 0 ? rhs : -rhs), 1e16, "Put-call parity violated"
        );
    }

    // =========================================================================
    // Full Pricing Result Tests
    // =========================================================================

    function test_priceHeston_complete() public pure {
        HestonParams memory p = _defaultParams();
        HestonResult memory result = HestonModel.priceHeston(p);

        assertGt(SD59x18.unwrap(result.callPrice), 0, "Call price must be positive");
        assertGt(SD59x18.unwrap(result.putPrice), 0, "Put price must be positive");
        assertGt(SD59x18.unwrap(result.fellerRatio), 1e18, "Feller ratio should be > 1");
    }

    // =========================================================================
    // Greeks Tests
    // =========================================================================

    function test_callDelta_ATM() public pure {
        HestonParams memory p = _defaultParams();
        SD59x18 delta = HestonModel.callDelta(p);
        int256 deltaRaw = SD59x18.unwrap(delta);
        // ATM call delta should be around 0.5 (slightly above due to drift)
        assertGt(deltaRaw, 400000000000000000, "ATM delta should be > 0.4");
        assertLt(deltaRaw, 700000000000000000, "ATM delta should be < 0.7");
    }

    function test_callDelta_deepITM() public pure {
        HestonParams memory p = _defaultParams();
        p.strike = sd(1000e18); // deep ITM
        SD59x18 delta = HestonModel.callDelta(p);
        // Deep ITM delta should be close to 1
        assertGt(SD59x18.unwrap(delta), 900000000000000000, "Deep ITM delta should be > 0.9");
    }

    function test_callDelta_deepOTM() public pure {
        HestonParams memory p = _defaultParams();
        p.strike = sd(10000e18); // deep OTM
        SD59x18 delta = HestonModel.callDelta(p);
        // Deep OTM delta should be close to 0
        assertLt(SD59x18.unwrap(delta), 100000000000000000, "Deep OTM delta should be < 0.1");
    }

    function test_callVega_positive() public pure {
        HestonParams memory p = _defaultParams();
        SD59x18 vegaVal = HestonModel.callVega(p);
        // Vega should be positive (higher variance → higher option price)
        assertGt(SD59x18.unwrap(vegaVal), 0, "Vega should be positive");
    }

    // =========================================================================
    // Implied Volatility Tests
    // =========================================================================

    function test_hestonImpliedVol_positive() public pure {
        HestonParams memory p = _defaultParams();
        SD59x18 iv = HestonModel.hestonImpliedVol(p);
        assertGt(SD59x18.unwrap(iv), 0, "Implied vol must be positive");
    }

    function test_hestonImpliedVol_reasonableRange() public pure {
        HestonParams memory p = _defaultParams();
        SD59x18 iv = HestonModel.hestonImpliedVol(p);
        int256 ivRaw = SD59x18.unwrap(iv);
        // For v0=0.04 (vol=20%), implied vol should be in range 10%-50%
        assertGt(ivRaw, 100000000000000000, "Implied vol should be > 10%");
        assertLt(ivRaw, 500000000000000000, "Implied vol should be < 50%");
    }

    // =========================================================================
    // Parameter Validation / Revert Tests
    // =========================================================================

    function test_priceCall_revertsOnZeroSpot() public {
        HestonParams memory p = _defaultParams();
        p.spot = ZERO;
        vm.expectRevert();
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnZeroStrike() public {
        HestonParams memory p = _defaultParams();
        p.strike = ZERO;
        vm.expectRevert();
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnZeroTimeToExpiry() public {
        HestonParams memory p = _defaultParams();
        p.timeToExpiry = ZERO;
        vm.expectRevert();
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnNegativeRate() public {
        HestonParams memory p = _defaultParams();
        p.riskFreeRate = sd(-1e17);
        vm.expectRevert();
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnZeroV0() public {
        HestonParams memory p = _defaultParams();
        p.v0 = ZERO;
        vm.expectRevert();
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnZeroTheta() public {
        HestonParams memory p = _defaultParams();
        p.theta = ZERO;
        vm.expectRevert();
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnZeroKappa() public {
        HestonParams memory p = _defaultParams();
        p.kappa = ZERO;
        vm.expectRevert();
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnZeroXi() public {
        HestonParams memory p = _defaultParams();
        p.xi = ZERO;
        vm.expectRevert();
        wrapper.priceCall(p);
    }

    function test_priceCall_revertsOnInvalidCorrelation() public {
        HestonParams memory p = _defaultParams();
        p.rho = sd(15e17); // 1.5, outside [-1,1]
        vm.expectRevert();
        wrapper.priceCall(p);
    }

    // =========================================================================
    // Monotonicity Tests
    // =========================================================================

    function test_callPrice_increasesWithSpot() public pure {
        HestonParams memory p1 = _defaultParams();
        HestonParams memory p2 = _defaultParams();
        p2.spot = sd(3200e18);

        SD59x18 price1 = HestonModel.priceCall(p1);
        SD59x18 price2 = HestonModel.priceCall(p2);

        assertGt(SD59x18.unwrap(price2), SD59x18.unwrap(price1), "Call price should increase with spot");
    }

    function test_callPrice_decreasesWithStrike() public pure {
        HestonParams memory p1 = _defaultParams();
        HestonParams memory p2 = _defaultParams();
        p2.strike = sd(3200e18);

        SD59x18 price1 = HestonModel.priceCall(p1);
        SD59x18 price2 = HestonModel.priceCall(p2);

        assertLt(SD59x18.unwrap(price2), SD59x18.unwrap(price1), "Call price should decrease with strike");
    }
}
