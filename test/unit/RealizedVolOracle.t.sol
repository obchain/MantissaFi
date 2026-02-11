// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd } from "@prb/math/SD59x18.sol";
import { RealizedVolOracle } from "../../src/core/RealizedVolOracle.sol";

contract RealizedVolOracleTest is Test {
    RealizedVolOracle public oracle;

    address public owner;
    address public user;
    address public asset1;
    address public asset2;

    // Standard test configuration
    int256 public constant DECAY_FACTOR = 940000000000000000; // 0.94
    uint256 public constant MIN_OBSERVATIONS = 5;
    int256 public constant ANNUALIZATION_FACTOR = 19104973174542805400; // sqrt(365) ≈ 19.1

    // Boundary values
    int256 public constant MIN_DECAY = 800000000000000000; // 0.8
    int256 public constant MAX_DECAY = 990000000000000000; // 0.99

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");
        asset1 = makeAddr("asset1");
        asset2 = makeAddr("asset2");

        oracle = new RealizedVolOracle();
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsOwner() public view {
        assertEq(oracle.owner(), owner);
    }

    function test_constructor_setsVersion() public view {
        assertEq(oracle.VERSION(), "1.0.0");
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_transferOwnership_success() public {
        oracle.transferOwnership(user);
        assertEq(oracle.owner(), user);
    }

    function test_transferOwnership_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit RealizedVolOracle.OwnershipTransferred(owner, user);
        oracle.transferOwnership(user);
    }

    function test_transferOwnership_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(RealizedVolOracle.Unauthorized.selector);
        oracle.transferOwnership(user);
    }

    function test_transferOwnership_revertsOnZeroAddress() public {
        vm.expectRevert(RealizedVolOracle.ZeroAddress.selector);
        oracle.transferOwnership(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURE ASSET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_configureAsset_success() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        (int256 decay, uint256 minObs, int256 annFactor, bool configured) = oracle.getAssetConfig(asset1);

        assertEq(decay, DECAY_FACTOR);
        assertEq(minObs, MIN_OBSERVATIONS);
        assertEq(annFactor, ANNUALIZATION_FACTOR);
        assertTrue(configured);
    }

    function test_configureAsset_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit RealizedVolOracle.AssetConfigured(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
    }

    function test_configureAsset_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(RealizedVolOracle.Unauthorized.selector);
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
    }

    function test_configureAsset_revertsIfAlreadyConfigured() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.AssetAlreadyConfigured.selector, asset1));
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
    }

    function test_configureAsset_revertsIfDecayTooLow() public {
        int256 tooLow = MIN_DECAY - 1;
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidDecayFactor.selector, tooLow));
        oracle.configureAsset(asset1, tooLow, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
    }

    function test_configureAsset_revertsIfDecayTooHigh() public {
        int256 tooHigh = MAX_DECAY + 1;
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidDecayFactor.selector, tooHigh));
        oracle.configureAsset(asset1, tooHigh, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
    }

    function test_configureAsset_acceptsMinDecayBoundary() public {
        oracle.configureAsset(asset1, MIN_DECAY, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
        (int256 decay,,,) = oracle.getAssetConfig(asset1);
        assertEq(decay, MIN_DECAY);
    }

    function test_configureAsset_acceptsMaxDecayBoundary() public {
        oracle.configureAsset(asset1, MAX_DECAY, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
        (int256 decay,,,) = oracle.getAssetConfig(asset1);
        assertEq(decay, MAX_DECAY);
    }

    function test_configureAsset_revertsIfZeroMinObservations() public {
        vm.expectRevert(RealizedVolOracle.InvalidMinObservations.selector);
        oracle.configureAsset(asset1, DECAY_FACTOR, 0, ANNUALIZATION_FACTOR);
    }

    function test_configureAsset_revertsIfZeroAnnualizationFactor() public {
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidAnnualizationFactor.selector, int256(0)));
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, 0);
    }

    function test_configureAsset_revertsIfNegativeAnnualizationFactor() public {
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidAnnualizationFactor.selector, int256(-1e18)));
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, -1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        UPDATE ASSET CONFIG TESTS
    //////////////////////////////////////////////////////////////*/

    function test_updateAssetConfig_success() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        int256 newDecay = 950000000000000000; // 0.95
        uint256 newMinObs = 10;
        int256 newAnnFactor = 15811388300841896660; // sqrt(250) for trading days

        oracle.updateAssetConfig(asset1, newDecay, newMinObs, newAnnFactor);

        (int256 decay, uint256 minObs, int256 annFactor,) = oracle.getAssetConfig(asset1);
        assertEq(decay, newDecay);
        assertEq(minObs, newMinObs);
        assertEq(annFactor, newAnnFactor);
    }

    function test_updateAssetConfig_emitsEvent() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        int256 newDecay = 950000000000000000;
        vm.expectEmit(true, false, false, true);
        emit RealizedVolOracle.AssetConfigUpdated(asset1, newDecay, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
        oracle.updateAssetConfig(asset1, newDecay, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
    }

    function test_updateAssetConfig_revertsIfNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.AssetNotConfigured.selector, asset1));
        oracle.updateAssetConfig(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
    }

    /*//////////////////////////////////////////////////////////////
                        UPDATE VOLATILITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_updateVolatility_firstObservation() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        int256 price = 100e18;
        oracle.updateVolatility(asset1, price);

        assertEq(oracle.getObservationCount(asset1), 1);
        (int256 latestPrice,) = oracle.getLatestObservation(asset1);
        assertEq(latestPrice, price);
    }

    function test_updateVolatility_emitsEvent() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        int256 price = 100e18;
        vm.expectEmit(true, false, false, true);
        emit RealizedVolOracle.VolatilityUpdated(asset1, price, 0, 1);
        oracle.updateVolatility(asset1, price);
    }

    function test_updateVolatility_secondObservationUpdatesVariance() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 101e18); // 1% increase

        int256 variance = oracle.getVariance(asset1);
        assertTrue(variance > 0, "Variance should be positive after price change");
    }

    function test_updateVolatility_revertsIfNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.AssetNotConfigured.selector, asset1));
        oracle.updateVolatility(asset1, 100e18);
    }

    function test_updateVolatility_revertsOnZeroPrice() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidPrice.selector, int256(0)));
        oracle.updateVolatility(asset1, 0);
    }

    function test_updateVolatility_revertsOnNegativePrice() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidPrice.selector, int256(-1e18)));
        oracle.updateVolatility(asset1, -1e18);
    }

    function test_updateVolatility_circularBufferWraparound() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);

        // Fill buffer and exceed MAX_OBSERVATIONS
        uint256 maxObs = oracle.MAX_OBSERVATIONS();
        int256 basePrice = 100e18;

        for (uint256 i = 0; i < maxObs + 10; i++) {
            // Small price variations
            int256 price = basePrice + int256(i % 10) * 1e17;
            oracle.updateVolatility(asset1, price);
        }

        assertEq(oracle.getObservationCount(asset1), maxObs + 10);
    }

    /*//////////////////////////////////////////////////////////////
                        GET REALIZED VOL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getRealizedVol_success() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 2, ANNUALIZATION_FACTOR);

        // Add enough observations
        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 102e18);
        oracle.updateVolatility(asset1, 101e18);
        oracle.updateVolatility(asset1, 103e18);

        int256 vol = oracle.getRealizedVol(asset1);
        assertTrue(vol > 0, "Volatility should be positive");
    }

    function test_getRealizedVol_revertsWithInsufficientObservations() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 5, ANNUALIZATION_FACTOR);

        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 101e18);
        oracle.updateVolatility(asset1, 102e18);

        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InsufficientObservations.selector, asset1, 3, 6));
        oracle.getRealizedVol(asset1);
    }

    function test_getRealizedVol_revertsIfNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.AssetNotConfigured.selector, asset1));
        oracle.getRealizedVol(asset1);
    }

    /*//////////////////////////////////////////////////////////////
                    GET REALIZED VOL WITH WINDOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getRealizedVolWithWindow_success() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);

        // Add observations
        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 102e18);
        oracle.updateVolatility(asset1, 101e18);
        oracle.updateVolatility(asset1, 103e18);
        oracle.updateVolatility(asset1, 102e18);

        int256 vol = oracle.getRealizedVol(asset1, 3);
        assertTrue(vol > 0, "Volatility should be positive");
    }

    function test_getRealizedVolWithWindow_revertsOnWindowTooSmall() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);
        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 101e18);

        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidWindow.selector, uint256(1)));
        oracle.getRealizedVol(asset1, 1);
    }

    function test_getRealizedVolWithWindow_revertsOnWindowTooLarge() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);
        oracle.updateVolatility(asset1, 100e18);

        uint256 tooLarge = oracle.MAX_OBSERVATIONS() + 1;
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidWindow.selector, tooLarge));
        oracle.getRealizedVol(asset1, tooLarge);
    }

    function test_getRealizedVolWithWindow_revertsWithInsufficientObservations() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);
        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 101e18);

        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InsufficientObservations.selector, asset1, 2, 5));
        oracle.getRealizedVol(asset1, 5);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getVariance_returnsZeroInitially() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);
        assertEq(oracle.getVariance(asset1), 0);
    }

    function test_getObservationCount_returnsCorrectCount() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        assertEq(oracle.getObservationCount(asset1), 0);

        oracle.updateVolatility(asset1, 100e18);
        assertEq(oracle.getObservationCount(asset1), 1);

        oracle.updateVolatility(asset1, 101e18);
        assertEq(oracle.getObservationCount(asset1), 2);
    }

    function test_getLatestObservation_returnsZeroWhenEmpty() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        (int256 price, uint256 timestamp) = oracle.getLatestObservation(asset1);
        assertEq(price, 0);
        assertEq(timestamp, 0);
    }

    function test_getLatestObservation_returnsCorrectValues() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        int256 testPrice = 12345e18;
        oracle.updateVolatility(asset1, testPrice);

        (int256 price, uint256 timestamp) = oracle.getLatestObservation(asset1);
        assertEq(price, testPrice);
        assertEq(timestamp, block.timestamp);
    }

    function test_getObservationAt_success() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 200e18);

        (int256 price0,) = oracle.getObservationAt(asset1, 0);
        (int256 price1,) = oracle.getObservationAt(asset1, 1);

        assertEq(price0, 100e18);
        assertEq(price1, 200e18);
    }

    function test_getObservationAt_revertsOnInvalidIndex() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, MIN_OBSERVATIONS, ANNUALIZATION_FACTOR);

        uint256 invalidIndex = oracle.MAX_OBSERVATIONS();
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidWindow.selector, invalidIndex));
        oracle.getObservationAt(asset1, invalidIndex);
    }

    function test_hasValidVolatility_returnsFalseWhenNotConfigured() public view {
        assertFalse(oracle.hasValidVolatility(asset1));
    }

    function test_hasValidVolatility_returnsFalseWithInsufficientObservations() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 5, ANNUALIZATION_FACTOR);
        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 101e18);

        assertFalse(oracle.hasValidVolatility(asset1));
    }

    function test_hasValidVolatility_returnsTrueWithEnoughObservations() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 2, ANNUALIZATION_FACTOR);
        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 101e18);
        oracle.updateVolatility(asset1, 102e18);

        assertTrue(oracle.hasValidVolatility(asset1));
    }

    /*//////////////////////////////////////////////////////////////
                    ANNUALIZATION FACTOR CALCULATION
    //////////////////////////////////////////////////////////////*/

    function test_calculateAnnualizationFactor_daily() public view {
        // For daily observations: sqrt(365)
        uint256 secondsPerDay = 86400;
        int256 factor = oracle.calculateAnnualizationFactor(secondsPerDay);

        // sqrt(365) ≈ 19.1049731745
        int256 expected = 19104973174542800000; // approximately 19.1e18
        assertApproxEqRel(factor, expected, 1e15); // 0.1% tolerance
    }

    function test_calculateAnnualizationFactor_hourly() public view {
        // For hourly observations: sqrt(8760)
        uint256 secondsPerHour = 3600;
        int256 factor = oracle.calculateAnnualizationFactor(secondsPerHour);

        // sqrt(8760) ≈ 93.59
        assertTrue(factor > 93e18 && factor < 94e18);
    }

    function test_calculateAnnualizationFactor_revertsOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidWindow.selector, uint256(0)));
        oracle.calculateAnnualizationFactor(0);
    }

    /*//////////////////////////////////////////////////////////////
                            EWMA MATH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ewma_varianceIncreasesWithPriceMovement() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);

        // Stable prices - low variance
        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 100e18);
        int256 stableVariance = oracle.getVariance(asset1);

        // Configure new asset for volatile prices
        oracle.configureAsset(asset2, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);
        oracle.updateVolatility(asset2, 100e18);
        oracle.updateVolatility(asset2, 110e18); // 10% move
        oracle.updateVolatility(asset2, 100e18); // 10% move back
        int256 volatileVariance = oracle.getVariance(asset2);

        assertTrue(volatileVariance > stableVariance, "Volatile asset should have higher variance");
    }

    function test_ewma_decayBehaviorDiffers() public {
        // Asset with high lambda (0.99) - slow decay, retains more history
        oracle.configureAsset(asset1, 990000000000000000, 1, ANNUALIZATION_FACTOR);

        // Asset with low lambda (0.8) - fast decay, more weight on recent returns
        oracle.configureAsset(asset2, 800000000000000000, 1, ANNUALIZATION_FACTOR);

        // Same price movements for both
        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset2, 100e18);

        // Big shock
        oracle.updateVolatility(asset1, 150e18);
        oracle.updateVolatility(asset2, 150e18);

        int256 highLambdaVariance = oracle.getVariance(asset1);
        int256 lowLambdaVariance = oracle.getVariance(asset2);

        // Different lambdas should produce different variances
        // Low lambda puts more weight on new returns (1-λ), so variance is larger after a shock
        assertTrue(highLambdaVariance != lowLambdaVariance, "Different lambdas should produce different variances");
        // Low lambda (0.8) means (1-λ)=0.2 weight on new return vs high lambda (0.99) with (1-λ)=0.01
        assertTrue(lowLambdaVariance > highLambdaVariance, "Low lambda weights new returns more heavily");
    }

    function test_ewma_symmetricReturns() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);
        oracle.configureAsset(asset2, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);

        // Asset 1: price goes up
        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 110e18);

        // Asset 2: price goes down (same log magnitude)
        oracle.updateVolatility(asset2, 110e18);
        oracle.updateVolatility(asset2, 100e18);

        int256 variance1 = oracle.getVariance(asset1);
        int256 variance2 = oracle.getVariance(asset2);

        // Variances should be approximately equal (squared returns)
        assertApproxEqRel(variance1, variance2, 1e15);
    }

    /*//////////////////////////////////////////////////////////////
                        MULTIPLE ASSETS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_multipleAssets_independentConfiguration() public {
        int256 decay1 = 940000000000000000;
        int256 decay2 = 950000000000000000;

        oracle.configureAsset(asset1, decay1, 5, ANNUALIZATION_FACTOR);
        oracle.configureAsset(asset2, decay2, 10, ANNUALIZATION_FACTOR);

        (int256 config1Decay, uint256 config1MinObs,,) = oracle.getAssetConfig(asset1);
        (int256 config2Decay, uint256 config2MinObs,,) = oracle.getAssetConfig(asset2);

        assertEq(config1Decay, decay1);
        assertEq(config1MinObs, 5);
        assertEq(config2Decay, decay2);
        assertEq(config2MinObs, 10);
    }

    function test_multipleAssets_independentObservations() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);
        oracle.configureAsset(asset2, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);

        oracle.updateVolatility(asset1, 100e18);
        oracle.updateVolatility(asset1, 110e18);

        oracle.updateVolatility(asset2, 50e18);

        assertEq(oracle.getObservationCount(asset1), 2);
        assertEq(oracle.getObservationCount(asset2), 1);

        (int256 price1,) = oracle.getLatestObservation(asset1);
        (int256 price2,) = oracle.getLatestObservation(asset2);

        assertEq(price1, 110e18);
        assertEq(price2, 50e18);
    }

    /*//////////////////////////////////////////////////////////////
                            EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_verySmallPrice() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);

        int256 smallPrice = 1; // Minimum positive value (1e-18 in real terms)
        oracle.updateVolatility(asset1, smallPrice);

        assertEq(oracle.getObservationCount(asset1), 1);
    }

    function test_veryLargePrice() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);

        int256 largePrice = 1e36; // Very large price
        oracle.updateVolatility(asset1, largePrice);

        assertEq(oracle.getObservationCount(asset1), 1);
    }

    function test_smallPriceChange() public {
        oracle.configureAsset(asset1, DECAY_FACTOR, 1, ANNUALIZATION_FACTOR);

        // Use a slightly larger change that produces measurable variance
        // Note: SD59x18 ln() may lose precision for extremely small ratios
        oracle.updateVolatility(asset1, 1e18);
        oracle.updateVolatility(asset1, 1001e15); // 0.1% change

        int256 variance = oracle.getVariance(asset1);
        assertTrue(variance > 0, "Small changes should produce some variance");
    }
}
