// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, UNIT, ZERO } from "@prb/math/SD59x18.sol";
import { RealizedVolOracle } from "../../src/core/RealizedVolOracle.sol";

contract RealizedVolOracleFuzzTest is Test {
    RealizedVolOracle public oracle;

    address public asset;

    // Bounds for valid configuration
    int256 public constant MIN_DECAY = 800000000000000000; // 0.8
    int256 public constant MAX_DECAY = 990000000000000000; // 0.99
    int256 public constant DEFAULT_ANNUALIZATION = 19104973174542805400; // sqrt(365)

    // Price bounds to avoid overflow in ln() calculations
    int256 public constant MIN_PRICE = 1e6; // Very small but safe minimum
    int256 public constant MAX_PRICE = 1e30; // Very large but safe maximum

    function setUp() public {
        oracle = new RealizedVolOracle();
        asset = makeAddr("asset");
    }

    /*//////////////////////////////////////////////////////////////
                    CONFIGURATION FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test that valid decay factors are always accepted
    function testFuzz_configureAsset_validDecayFactors(int256 decayFactor) public {
        // Bound to valid range
        decayFactor = bound(decayFactor, MIN_DECAY, MAX_DECAY);

        address fuzzAsset = address(uint160(uint256(keccak256(abi.encode(decayFactor)))));

        oracle.configureAsset(fuzzAsset, decayFactor, 5, DEFAULT_ANNUALIZATION);

        (int256 storedDecay,,, bool configured) = oracle.getAssetConfig(fuzzAsset);
        assertEq(storedDecay, decayFactor);
        assertTrue(configured);
    }

    /// @notice Fuzz test that invalid decay factors always revert
    function testFuzz_configureAsset_invalidDecayFactors_tooLow(int256 decayFactor) public {
        // Bound below valid range
        decayFactor = bound(decayFactor, type(int256).min, MIN_DECAY - 1);

        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidDecayFactor.selector, decayFactor));
        oracle.configureAsset(asset, decayFactor, 5, DEFAULT_ANNUALIZATION);
    }

    /// @notice Fuzz test that decay factors above max always revert
    function testFuzz_configureAsset_invalidDecayFactors_tooHigh(int256 decayFactor) public {
        // Bound above valid range
        decayFactor = bound(decayFactor, MAX_DECAY + 1, type(int256).max);

        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidDecayFactor.selector, decayFactor));
        oracle.configureAsset(asset, decayFactor, 5, DEFAULT_ANNUALIZATION);
    }

    /// @notice Fuzz test that any positive minObservations is valid
    function testFuzz_configureAsset_validMinObservations(uint256 minObs) public {
        // Must be positive
        minObs = bound(minObs, 1, type(uint256).max);

        address fuzzAsset = address(uint160(uint256(keccak256(abi.encode(minObs)))));

        oracle.configureAsset(fuzzAsset, 940000000000000000, minObs, DEFAULT_ANNUALIZATION);

        (, uint256 storedMinObs,,) = oracle.getAssetConfig(fuzzAsset);
        assertEq(storedMinObs, minObs);
    }

    /// @notice Fuzz test that positive annualization factors are valid
    function testFuzz_configureAsset_validAnnualizationFactors(int256 annFactor) public {
        // Must be positive
        annFactor = bound(annFactor, 1, type(int256).max);

        address fuzzAsset = address(uint160(uint256(keccak256(abi.encode(annFactor)))));

        oracle.configureAsset(fuzzAsset, 940000000000000000, 5, annFactor);

        (,, int256 storedAnnFactor,) = oracle.getAssetConfig(fuzzAsset);
        assertEq(storedAnnFactor, annFactor);
    }

    /*//////////////////////////////////////////////////////////////
                    VOLATILITY UPDATE FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test that positive prices are always accepted
    function testFuzz_updateVolatility_positivePrices(int256 price) public {
        // Bound to positive and safe range
        price = bound(price, MIN_PRICE, MAX_PRICE);

        oracle.configureAsset(asset, 940000000000000000, 2, DEFAULT_ANNUALIZATION);
        oracle.updateVolatility(asset, price);

        (int256 storedPrice,) = oracle.getLatestObservation(asset);
        assertEq(storedPrice, price);
    }

    /// @notice Fuzz test that non-positive prices always revert
    function testFuzz_updateVolatility_nonPositivePrices(int256 price) public {
        // Bound to non-positive
        price = bound(price, type(int256).min, 0);

        oracle.configureAsset(asset, 940000000000000000, 2, DEFAULT_ANNUALIZATION);

        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidPrice.selector, price));
        oracle.updateVolatility(asset, price);
    }

    /// @notice Fuzz test EWMA invariant: variance is always non-negative
    function testFuzz_ewma_varianceNonNegative(int256 price1, int256 price2, int256 price3) public {
        // Bound prices to safe range with limited ratio to avoid ln(0)
        // Keep prices within 1000x of each other to avoid precision issues
        int256 minP = 1e15;
        int256 maxP = 1e24;
        price1 = bound(price1, minP, maxP);
        price2 = bound(price2, price1 / 100, price1 * 100);
        price2 = bound(price2, minP, maxP);
        price3 = bound(price3, price2 / 100, price2 * 100);
        price3 = bound(price3, minP, maxP);

        oracle.configureAsset(asset, 940000000000000000, 1, DEFAULT_ANNUALIZATION);

        oracle.updateVolatility(asset, price1);
        oracle.updateVolatility(asset, price2);
        oracle.updateVolatility(asset, price3);

        int256 variance = oracle.getVariance(asset);
        assertTrue(variance >= 0, "Variance must be non-negative");
    }

    /// @notice Fuzz test that observation count always increments
    function testFuzz_observationCount_alwaysIncrements(uint8 numUpdates, int256 basePrice) public {
        // Limit updates to avoid gas issues
        numUpdates = uint8(bound(numUpdates, 1, 50));
        basePrice = bound(basePrice, MIN_PRICE, MAX_PRICE / 2);

        oracle.configureAsset(asset, 940000000000000000, 1, DEFAULT_ANNUALIZATION);

        for (uint256 i = 0; i < numUpdates; i++) {
            // Vary price slightly
            int256 price = basePrice + int256(i) * 1e15;
            oracle.updateVolatility(asset, price);
            assertEq(oracle.getObservationCount(asset), i + 1);
        }
    }

    /// @notice Fuzz test EWMA with random price sequences
    function testFuzz_ewma_randomPriceSequence(
        int256 seed,
        uint8 numPrices
    ) public {
        numPrices = uint8(bound(numPrices, 2, 30));

        oracle.configureAsset(asset, 940000000000000000, 1, DEFAULT_ANNUALIZATION);

        int256 prevVariance = 0;

        for (uint256 i = 0; i < numPrices; i++) {
            // Generate pseudo-random price from seed
            int256 price = int256(uint256(keccak256(abi.encode(seed, i))) % uint256(MAX_PRICE - MIN_PRICE)) + MIN_PRICE;

            oracle.updateVolatility(asset, price);

            int256 variance = oracle.getVariance(asset);

            // Variance should always be non-negative
            assertTrue(variance >= 0, "Variance must be non-negative");

            // After first return, variance should be set (may be zero if price unchanged)
            if (i > 0) {
                // Variance can increase or decrease, but should be bounded
                assertTrue(variance <= type(int128).max, "Variance should not overflow");
            }

            prevVariance = variance;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    REALIZED VOL FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test that realized vol is always non-negative
    function testFuzz_getRealizedVol_nonNegative(
        int256 price1,
        int256 price2,
        int256 price3,
        int256 price4
    ) public {
        // Bound prices with limited ratio to avoid ln(0) issues
        int256 minP = 1e15;
        int256 maxP = 1e24;
        price1 = bound(price1, minP, maxP);
        price2 = bound(price2, price1 / 100, price1 * 100);
        price2 = bound(price2, minP, maxP);
        price3 = bound(price3, price2 / 100, price2 * 100);
        price3 = bound(price3, minP, maxP);
        price4 = bound(price4, price3 / 100, price3 * 100);
        price4 = bound(price4, minP, maxP);

        oracle.configureAsset(asset, 940000000000000000, 2, DEFAULT_ANNUALIZATION);

        oracle.updateVolatility(asset, price1);
        oracle.updateVolatility(asset, price2);
        oracle.updateVolatility(asset, price3);
        oracle.updateVolatility(asset, price4);

        int256 vol = oracle.getRealizedVol(asset);
        assertTrue(vol >= 0, "Realized volatility must be non-negative");
    }

    /// @notice Fuzz test getRealizedVol with window
    function testFuzz_getRealizedVolWithWindow_nonNegative(
        uint256 window,
        int256 basePrice
    ) public {
        // Window must be between 2 and MAX_OBSERVATIONS
        window = bound(window, 2, 20);
        basePrice = bound(basePrice, MIN_PRICE, MAX_PRICE / 2);

        oracle.configureAsset(asset, 940000000000000000, 1, DEFAULT_ANNUALIZATION);

        // Add enough observations
        for (uint256 i = 0; i < window + 5; i++) {
            int256 price = basePrice + int256(i % 10) * 1e17;
            oracle.updateVolatility(asset, price);
        }

        int256 vol = oracle.getRealizedVol(asset, window);
        assertTrue(vol >= 0, "Windowed volatility must be non-negative");
    }

    /// @notice Fuzz test that invalid windows always revert
    function testFuzz_getRealizedVolWithWindow_invalidWindow(uint256 window) public {
        oracle.configureAsset(asset, 940000000000000000, 1, DEFAULT_ANNUALIZATION);

        // Add some observations
        oracle.updateVolatility(asset, 100e18);
        oracle.updateVolatility(asset, 101e18);

        // Window too small (< 2) or too large (> MAX_OBSERVATIONS)
        if (window < 2 || window > oracle.MAX_OBSERVATIONS()) {
            vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidWindow.selector, window));
            oracle.getRealizedVol(asset, window);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    ANNUALIZATION FACTOR FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test annualization factor calculation
    function testFuzz_calculateAnnualizationFactor_valid(uint256 secondsBetween) public view {
        // Bound to positive and reasonable values
        secondsBetween = bound(secondsBetween, 1, 31536000); // 1 second to 1 year

        int256 factor = oracle.calculateAnnualizationFactor(secondsBetween);

        // Factor should always be positive
        assertTrue(factor > 0, "Annualization factor must be positive");

        // Factor should be higher for shorter intervals (more observations per year)
        // Just verify it doesn't overflow
        assertTrue(factor < type(int256).max, "Factor should not overflow");
    }

    /// @notice Fuzz test that zero seconds always reverts
    function testFuzz_calculateAnnualizationFactor_zeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RealizedVolOracle.InvalidWindow.selector, uint256(0)));
        oracle.calculateAnnualizationFactor(0);
    }

    /*//////////////////////////////////////////////////////////////
                    CIRCULAR BUFFER FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test circular buffer behavior with many observations
    function testFuzz_circularBuffer_wraparound(uint16 numObservations, int256 basePrice) public {
        // Limit to reasonable number
        numObservations = uint16(bound(numObservations, 1, 300));
        basePrice = bound(basePrice, MIN_PRICE, MAX_PRICE / 2);

        oracle.configureAsset(asset, 940000000000000000, 1, DEFAULT_ANNUALIZATION);

        int256 lastPrice;
        for (uint256 i = 0; i < numObservations; i++) {
            lastPrice = basePrice + int256(i % 100) * 1e16;
            oracle.updateVolatility(asset, lastPrice);
        }

        // Observation count should match
        assertEq(oracle.getObservationCount(asset), numObservations);

        // Latest observation should be correct
        (int256 storedPrice,) = oracle.getLatestObservation(asset);
        assertEq(storedPrice, lastPrice);
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-ASSET FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test that multiple assets remain independent
    function testFuzz_multiAsset_independence(
        int256 price1,
        int256 price2,
        int256 decayFactor1,
        int256 decayFactor2
    ) public {
        // Bound inputs
        price1 = bound(price1, MIN_PRICE, MAX_PRICE);
        price2 = bound(price2, MIN_PRICE, MAX_PRICE);
        decayFactor1 = bound(decayFactor1, MIN_DECAY, MAX_DECAY);
        decayFactor2 = bound(decayFactor2, MIN_DECAY, MAX_DECAY);

        address asset1 = makeAddr("asset1");
        address asset2 = makeAddr("asset2");

        oracle.configureAsset(asset1, decayFactor1, 1, DEFAULT_ANNUALIZATION);
        oracle.configureAsset(asset2, decayFactor2, 1, DEFAULT_ANNUALIZATION);

        oracle.updateVolatility(asset1, price1);
        oracle.updateVolatility(asset2, price2);

        // Verify independence
        (int256 config1Decay,,,) = oracle.getAssetConfig(asset1);
        (int256 config2Decay,,,) = oracle.getAssetConfig(asset2);

        assertEq(config1Decay, decayFactor1);
        assertEq(config2Decay, decayFactor2);

        (int256 obs1Price,) = oracle.getLatestObservation(asset1);
        (int256 obs2Price,) = oracle.getLatestObservation(asset2);

        assertEq(obs1Price, price1);
        assertEq(obs2Price, price2);

        assertEq(oracle.getObservationCount(asset1), 1);
        assertEq(oracle.getObservationCount(asset2), 1);
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT: EWMA BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test that volatility remains bounded for bounded price changes
    function testFuzz_volatility_boundedForBoundedReturns(
        int256 basePrice,
        int8[] calldata priceDeltas
    ) public {
        if (priceDeltas.length < 3) return;

        basePrice = bound(basePrice, 1e18, 1e24);

        oracle.configureAsset(asset, 940000000000000000, 2, DEFAULT_ANNUALIZATION);

        int256 currentPrice = basePrice;

        for (uint256 i = 0; i < priceDeltas.length && i < 20; i++) {
            // Apply delta as percentage (max 10% change per step)
            int256 delta = (currentPrice * int256(priceDeltas[i])) / 1000; // -12.8% to +12.7%
            currentPrice = currentPrice + delta;

            // Ensure price stays positive
            if (currentPrice <= 0) {
                currentPrice = basePrice;
            }

            oracle.updateVolatility(asset, currentPrice);

            // Variance should remain bounded
            int256 variance = oracle.getVariance(asset);
            assertTrue(variance >= 0, "Variance should be non-negative");
            // With bounded returns, variance should be bounded
            assertTrue(variance < 1e36, "Variance should be bounded for bounded returns");
        }

        // Get realized vol if we have enough observations
        if (oracle.getObservationCount(asset) > 2) {
            int256 vol = oracle.getRealizedVol(asset);
            assertTrue(vol >= 0, "Vol should be non-negative");
        }
    }
}
