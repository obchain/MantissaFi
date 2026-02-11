// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO, UNIT } from "@prb/math/SD59x18.sol";
import {
    Integrationtest,
    OptionSeries,
    OptionPosition,
    PoolState,
    OraclePrice,
    ExerciseResult,
    BSMInputs,
    BSMOutputs,
    LPPosition,
    BatchMintRequest,
    BatchExerciseRequest,
    OptionExpired,
    OptionNotExpired,
    OptionNotITM,
    InsufficientLiquidity,
    InsufficientCollateral,
    InsufficientPremium,
    InsufficientBalance,
    InvalidStrike,
    InvalidExpiry,
    InvalidVolatility,
    ZeroTimeToExpiry,
    ZeroAmount,
    InvalidOptionId,
    StalePriceData,
    InvalidOraclePrice,
    ArrayLengthMismatch,
    BatchSizeTooLarge
} from "../../src/libraries/Integrationtest.sol";

/// @title IntegrationtestWrapper
/// @notice Wrapper contract to expose library functions for testing reverts
contract IntegrationtestWrapper {
    function computeD1(BSMInputs memory inputs) external pure returns (SD59x18) {
        return Integrationtest.computeD1(inputs);
    }

    function computeBSM(BSMInputs memory inputs, bool isCall) external pure returns (BSMOutputs memory) {
        return Integrationtest.computeBSM(inputs, isCall);
    }

    function calculateMintPremium(
        OptionSeries memory series,
        SD59x18 amount,
        SD59x18 spotPrice,
        SD59x18 volatility,
        uint256 currentTime
    ) external pure returns (SD59x18) {
        return Integrationtest.calculateMintPremium(series, amount, spotPrice, volatility, currentTime);
    }

    function calculateMoneyness(SD59x18 spotPrice, SD59x18 strikePrice) external pure returns (SD59x18) {
        return Integrationtest.calculateMoneyness(spotPrice, strikePrice);
    }

    function calculateDepositShares(SD59x18 depositAmount, SD59x18 totalAssets, SD59x18 totalShares)
        external
        pure
        returns (SD59x18)
    {
        return Integrationtest.calculateDepositShares(depositAmount, totalAssets, totalShares);
    }

    function updatePoolAfterMint(PoolState memory pool, SD59x18 premium, SD59x18 collateralRequired)
        external
        pure
        returns (PoolState memory)
    {
        return Integrationtest.updatePoolAfterMint(pool, premium, collateralRequired);
    }

    function validateOraclePrice(OraclePrice memory priceData, uint256 currentTime) external pure {
        Integrationtest.validateOraclePrice(priceData, currentTime);
    }

    function validateBatchSize(uint256 size) external pure {
        Integrationtest.validateBatchSize(size);
    }

    function calculateBatchMintPremium(
        BatchMintRequest[] memory requests,
        OptionSeries[] memory seriesArray,
        SD59x18 spotPrice,
        SD59x18 volatility,
        uint256 currentTime
    ) external pure returns (SD59x18) {
        return Integrationtest.calculateBatchMintPremium(requests, seriesArray, spotPrice, volatility, currentTime);
    }

    function calculateTimeToExpiry(uint64 expiry, uint256 currentTime) external pure returns (SD59x18) {
        return Integrationtest.calculateTimeToExpiry(expiry, currentTime);
    }

    function validateOptionSeries(OptionSeries memory series, uint256 currentTime) external pure {
        Integrationtest.validateOptionSeries(series, currentTime);
    }

    function validateVolatility(SD59x18 volatility) external pure {
        Integrationtest.validateVolatility(volatility);
    }
}

/// @title IntegrationtestTest
/// @notice Unit tests for the Integrationtest library
/// @dev Covers all public functions, edge cases, and error conditions
contract IntegrationtestTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    IntegrationtestWrapper internal wrapper;

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Standard spot price for ETH ($3000)
    SD59x18 internal constant SPOT_PRICE = SD59x18.wrap(3000e18);

    /// @notice Standard strike price ($3100)
    SD59x18 internal constant STRIKE_PRICE = SD59x18.wrap(3100e18);

    /// @notice Standard volatility (65%)
    SD59x18 internal constant VOLATILITY = SD59x18.wrap(650000000000000000);

    /// @notice Standard risk-free rate (5%)
    SD59x18 internal constant RISK_FREE_RATE = SD59x18.wrap(50000000000000000);

    /// @notice One month in seconds
    uint256 internal constant ONE_MONTH = 30 days;

    /// @notice One year in seconds
    uint256 internal constant ONE_YEAR = 365 days;

    /// @notice Standard option amount (1 option)
    SD59x18 internal constant ONE_OPTION = SD59x18.wrap(1e18);

    /// @notice Test addresses
    address internal constant WETH = address(0x1);
    address internal constant USDC = address(0x2);

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        wrapper = new IntegrationtestWrapper();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Creates a standard call option series for testing
    function _createCallSeries(uint64 expiry) internal pure returns (OptionSeries memory) {
        return
            OptionSeries({
                underlying: WETH, collateral: USDC, expiry: expiry, strikePrice: STRIKE_PRICE, isCall: true
            });
    }

    /// @notice Creates a standard put option series for testing
    function _createPutSeries(uint64 expiry) internal pure returns (OptionSeries memory) {
        return
            OptionSeries({
                underlying: WETH, collateral: USDC, expiry: expiry, strikePrice: STRIKE_PRICE, isCall: false
            });
    }

    /// @notice Creates standard BSM inputs for testing
    function _createBSMInputs() internal pure returns (BSMInputs memory) {
        return BSMInputs({
            spot: SPOT_PRICE,
            strike: STRIKE_PRICE,
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });
    }

    /// @notice Creates an initialized pool state for testing
    function _createPoolState(SD59x18 assets) internal pure returns (PoolState memory) {
        return PoolState({
            totalAssets: assets,
            lockedCollateral: ZERO,
            availableLiquidity: assets,
            totalPremiumsCollected: ZERO,
            totalPayoutsMade: ZERO,
            netDelta: ZERO
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BSM PRICING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test d1 computation with standard inputs
    function test_ComputeD1_StandardInputs() public pure {
        BSMInputs memory inputs = BSMInputs({
            spot: SPOT_PRICE,
            strike: STRIKE_PRICE,
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });
        SD59x18 d1 = Integrationtest.computeD1(inputs);

        // d1 should be negative for OTM call (spot < strike)
        assertTrue(d1.lt(ZERO), "d1 should be negative for OTM call");
    }

    /// @notice Test d1 computation with ATM option
    function test_ComputeD1_ATMOption() public pure {
        BSMInputs memory inputs = BSMInputs({
            spot: sd(3000e18),
            strike: sd(3000e18),
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });

        SD59x18 d1 = Integrationtest.computeD1(inputs);

        // For ATM option, d1 should be slightly positive due to drift term
        assertTrue(d1.gt(sd(-1e18)), "d1 should be near zero for ATM");
        assertTrue(d1.lt(sd(1e18)), "d1 should be near zero for ATM");
    }

    /// @notice Test d1 reverts with zero time to expiry
    function test_ComputeD1_RevertOnZeroTime() public {
        BSMInputs memory inputs = BSMInputs({
            spot: SPOT_PRICE,
            strike: STRIKE_PRICE,
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: ZERO
        });

        vm.expectRevert(ZeroTimeToExpiry.selector);
        wrapper.computeD1(inputs);
    }

    /// @notice Test d2 computation
    function test_ComputeD2_IsLessThanD1() public pure {
        BSMInputs memory inputs = BSMInputs({
            spot: SPOT_PRICE,
            strike: STRIKE_PRICE,
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });
        SD59x18 d1 = Integrationtest.computeD1(inputs);
        SD59x18 d2 = Integrationtest.computeD2(inputs, d1);

        // d2 = d1 - sigma * sqrt(T), so d2 < d1
        assertTrue(d2.lt(d1), "d2 should be less than d1");
    }

    /// @notice Test call option pricing
    function test_PriceCall_StandardInputs() public pure {
        BSMInputs memory inputs = BSMInputs({
            spot: SPOT_PRICE,
            strike: STRIKE_PRICE,
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });
        SD59x18 price = Integrationtest.priceCall(inputs);

        // Price should be positive
        assertTrue(price.gt(ZERO), "Call price should be positive");

        // Price should be less than spot price
        assertTrue(price.lt(inputs.spot), "Call price should be less than spot");
    }

    /// @notice Test call option is cheap for deep OTM
    function test_PriceCall_DeepOTM() public pure {
        BSMInputs memory inputs = BSMInputs({
            spot: sd(3000e18),
            strike: sd(5000e18), // Deep OTM
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });

        SD59x18 price = Integrationtest.priceCall(inputs);

        // Deep OTM call should be very cheap
        assertTrue(price.lt(sd(50e18)), "Deep OTM call should be cheap");
    }

    /// @notice Test call option is expensive for deep ITM
    function test_PriceCall_DeepITM() public pure {
        BSMInputs memory inputs = BSMInputs({
            spot: sd(5000e18),
            strike: sd(3000e18), // Deep ITM
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });

        SD59x18 price = Integrationtest.priceCall(inputs);

        // Deep ITM call should be close to intrinsic value (S - K)
        SD59x18 intrinsic = inputs.spot.sub(inputs.strike);
        assertTrue(price.gt(intrinsic), "ITM call should be >= intrinsic value");
    }

    /// @notice Test put option pricing
    function test_PricePut_StandardInputs() public pure {
        BSMInputs memory inputs = BSMInputs({
            spot: SPOT_PRICE,
            strike: STRIKE_PRICE,
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });
        SD59x18 price = Integrationtest.pricePut(inputs);

        // Put price should be positive
        assertTrue(price.gt(ZERO), "Put price should be positive");
    }

    /// @notice Test put-call parity
    function test_PutCallParity() public pure {
        BSMInputs memory inputs = BSMInputs({
            spot: sd(3000e18),
            strike: sd(3000e18), // ATM for cleaner parity check
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });

        SD59x18 callPrice = Integrationtest.priceCall(inputs);
        SD59x18 putPrice = Integrationtest.pricePut(inputs);

        // Put-call parity: C - P = S - K * e^(-rT)
        SD59x18 discountFactor = inputs.riskFreeRate.mul(inputs.timeToExpiry).mul(sd(-1e18)).exp();
        SD59x18 expected = inputs.spot.sub(inputs.strike.mul(discountFactor));
        SD59x18 actual = callPrice.sub(putPrice);

        // Allow small error due to fixed-point arithmetic
        SD59x18 diff = expected.sub(actual).abs();
        assertTrue(diff.lt(sd(1e15)), "Put-call parity should hold within tolerance");
    }

    /// @notice Test full BSM computation returns all Greeks
    function test_ComputeBSM_ReturnsAllGreeks() public pure {
        BSMInputs memory inputs = BSMInputs({
            spot: SPOT_PRICE,
            strike: STRIKE_PRICE,
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });
        BSMOutputs memory outputs = Integrationtest.computeBSM(inputs, true);

        // Price should be positive
        assertTrue(outputs.price.gt(ZERO), "Price should be positive");

        // Delta should be between 0 and 1 for call
        assertTrue(outputs.delta.gt(ZERO), "Call delta should be positive");
        assertTrue(outputs.delta.lt(sd(1e18)), "Call delta should be < 1");

        // Gamma should be positive
        assertTrue(outputs.gamma.gt(ZERO), "Gamma should be positive");

        // Vega should be positive
        assertTrue(outputs.vega.gt(ZERO), "Vega should be positive");

        // Theta should be negative for long call
        assertTrue(outputs.theta.lt(ZERO), "Call theta should be negative");
    }

    /// @notice Test BSM for put returns correct delta sign
    function test_ComputeBSM_PutDeltaNegative() public pure {
        BSMInputs memory inputs = BSMInputs({
            spot: SPOT_PRICE,
            strike: STRIKE_PRICE,
            volatility: VOLATILITY,
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });
        BSMOutputs memory outputs = Integrationtest.computeBSM(inputs, false);

        // Put delta should be between -1 and 0
        assertTrue(outputs.delta.lt(ZERO), "Put delta should be negative");
        assertTrue(outputs.delta.gt(sd(-1e18)), "Put delta should be > -1");
    }

    /// @notice Test BSM reverts on invalid volatility
    function test_ComputeBSM_RevertOnInvalidVolatility() public {
        BSMInputs memory inputs = BSMInputs({
            spot: SPOT_PRICE,
            strike: STRIKE_PRICE,
            volatility: sd(1e15), // Too low (0.001%)
            riskFreeRate: RISK_FREE_RATE,
            timeToExpiry: sd(int256(ONE_MONTH * 1e18 / ONE_YEAR))
        });

        vm.expectRevert(abi.encodeWithSelector(InvalidVolatility.selector, inputs.volatility));
        wrapper.computeBSM(inputs, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OPTION LIFECYCLE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test premium calculation for minting
    function test_CalculateMintPremium_ReturnsPositiveValue() public view {
        uint64 expiry = uint64(block.timestamp + ONE_MONTH);
        OptionSeries memory series = _createCallSeries(expiry);

        SD59x18 premium =
            Integrationtest.calculateMintPremium(series, ONE_OPTION, SPOT_PRICE, VOLATILITY, block.timestamp);

        assertTrue(premium.gt(ZERO), "Premium should be positive");
    }

    /// @notice Test premium scales with amount
    function test_CalculateMintPremium_ScalesWithAmount() public view {
        uint64 expiry = uint64(block.timestamp + ONE_MONTH);
        OptionSeries memory series = _createCallSeries(expiry);

        SD59x18 premiumOne =
            Integrationtest.calculateMintPremium(series, ONE_OPTION, SPOT_PRICE, VOLATILITY, block.timestamp);
        SD59x18 premiumTen =
            Integrationtest.calculateMintPremium(series, sd(10e18), SPOT_PRICE, VOLATILITY, block.timestamp);

        // Premium for 10 options should be 10x premium for 1
        SD59x18 expected = premiumOne.mul(sd(10e18));
        SD59x18 diff = expected.sub(premiumTen).abs();
        assertTrue(diff.lt(sd(1e12)), "Premium should scale linearly");
    }

    /// @notice Test premium reverts on zero amount
    function test_CalculateMintPremium_RevertOnZeroAmount() public {
        uint64 expiry = uint64(block.timestamp + ONE_MONTH);
        OptionSeries memory series = _createCallSeries(expiry);

        vm.expectRevert(ZeroAmount.selector);
        wrapper.calculateMintPremium(series, ZERO, SPOT_PRICE, VOLATILITY, block.timestamp);
    }

    /// @notice Test collateral calculation for calls
    function test_CalculateRequiredCollateral_Call() public view {
        OptionSeries memory series = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + ONE_MONTH),
            strikePrice: sd(3000e18),
            isCall: true
        });

        SD59x18 collateral = Integrationtest.calculateRequiredCollateral(series, ONE_OPTION, SPOT_PRICE);

        // Collateral should be at least strike * 1.5
        SD59x18 minCollateral = series.strikePrice.mul(sd(1_500000000000000000));
        assertTrue(collateral.gte(minCollateral), "Collateral should be >= 150% of strike");
    }

    /// @notice Test collateral calculation for puts
    function test_CalculateRequiredCollateral_Put() public view {
        OptionSeries memory series = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + ONE_MONTH),
            strikePrice: sd(3000e18),
            isCall: false
        });

        SD59x18 collateral = Integrationtest.calculateRequiredCollateral(series, ONE_OPTION, SPOT_PRICE);

        // Put collateral should be strike price
        SD59x18 expected = series.strikePrice.mul(ONE_OPTION);
        assertEq(SD59x18.unwrap(collateral), SD59x18.unwrap(expected), "Put collateral should equal strike");
    }

    /// @notice Test exercise payoff for ITM call
    function test_CalculateExercisePayoff_ITMCall() public view {
        OptionSeries memory series = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + ONE_MONTH),
            strikePrice: sd(3000e18),
            isCall: true
        });

        SD59x18 spotAtExercise = sd(3500e18); // ITM

        (SD59x18 payoff, bool isITM) = Integrationtest.calculateExercisePayoff(series, ONE_OPTION, spotAtExercise);

        assertTrue(isITM, "Should be ITM");

        // Payoff = (S - K) * amount = (3500 - 3000) * 1 = 500
        SD59x18 expected = sd(500e18);
        assertEq(SD59x18.unwrap(payoff), SD59x18.unwrap(expected), "Payoff should be 500");
    }

    /// @notice Test exercise payoff for OTM call
    function test_CalculateExercisePayoff_OTMCall() public view {
        OptionSeries memory series = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + ONE_MONTH),
            strikePrice: sd(3000e18),
            isCall: true
        });

        SD59x18 spotAtExercise = sd(2800e18); // OTM

        (SD59x18 payoff, bool isITM) = Integrationtest.calculateExercisePayoff(series, ONE_OPTION, spotAtExercise);

        assertFalse(isITM, "Should be OTM");
        assertEq(SD59x18.unwrap(payoff), 0, "OTM payoff should be zero");
    }

    /// @notice Test exercise payoff for ITM put
    function test_CalculateExercisePayoff_ITMPut() public view {
        OptionSeries memory series = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + ONE_MONTH),
            strikePrice: sd(3000e18),
            isCall: false
        });

        SD59x18 spotAtExercise = sd(2500e18); // ITM for put

        (SD59x18 payoff, bool isITM) = Integrationtest.calculateExercisePayoff(series, ONE_OPTION, spotAtExercise);

        assertTrue(isITM, "Should be ITM");

        // Payoff = (K - S) * amount = (3000 - 2500) * 1 = 500
        SD59x18 expected = sd(500e18);
        assertEq(SD59x18.unwrap(payoff), SD59x18.unwrap(expected), "Put payoff should be 500");
    }

    /// @notice Test isOptionITM
    function test_IsOptionITM_CallAndPut() public view {
        OptionSeries memory callSeries = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + ONE_MONTH),
            strikePrice: sd(3000e18),
            isCall: true
        });

        OptionSeries memory putSeries = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + ONE_MONTH),
            strikePrice: sd(3000e18),
            isCall: false
        });

        // Spot above strike
        assertTrue(Integrationtest.isOptionITM(callSeries, sd(3500e18)), "Call should be ITM when spot > strike");
        assertFalse(Integrationtest.isOptionITM(putSeries, sd(3500e18)), "Put should be OTM when spot > strike");

        // Spot below strike
        assertFalse(Integrationtest.isOptionITM(callSeries, sd(2500e18)), "Call should be OTM when spot < strike");
        assertTrue(Integrationtest.isOptionITM(putSeries, sd(2500e18)), "Put should be ITM when spot < strike");
    }

    /// @notice Test moneyness calculation
    function test_CalculateMoneyness() public pure {
        SD59x18 moneyness = Integrationtest.calculateMoneyness(sd(3300e18), sd(3000e18));

        // Moneyness = S/K = 3300/3000 = 1.1
        SD59x18 expected = sd(1_100000000000000000);
        assertEq(SD59x18.unwrap(moneyness), SD59x18.unwrap(expected), "Moneyness should be 1.1");
    }

    /// @notice Test moneyness reverts on zero strike
    function test_CalculateMoneyness_RevertOnZeroStrike() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidStrike.selector, ZERO));
        wrapper.calculateMoneyness(SPOT_PRICE, ZERO);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POOL MANAGEMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test LP share calculation for first deposit
    function test_CalculateDepositShares_FirstDeposit() public pure {
        SD59x18 depositAmount = sd(1000000e18); // 1M USDC

        SD59x18 shares = Integrationtest.calculateDepositShares(depositAmount, ZERO, ZERO);

        // First deposit: shares = amount
        assertEq(SD59x18.unwrap(shares), SD59x18.unwrap(depositAmount), "First deposit shares should equal amount");
    }

    /// @notice Test LP share calculation for subsequent deposit
    function test_CalculateDepositShares_SubsequentDeposit() public pure {
        SD59x18 totalAssets = sd(1000000e18);
        SD59x18 totalShares = sd(1000000e18);
        SD59x18 depositAmount = sd(500000e18);

        SD59x18 shares = Integrationtest.calculateDepositShares(depositAmount, totalAssets, totalShares);

        // shares = depositAmount * totalShares / totalAssets = 500k
        SD59x18 expected = sd(500000e18);
        assertEq(SD59x18.unwrap(shares), SD59x18.unwrap(expected), "Shares should be proportional");
    }

    /// @notice Test LP share calculation reverts on zero amount
    function test_CalculateDepositShares_RevertOnZeroAmount() public {
        vm.expectRevert(ZeroAmount.selector);
        wrapper.calculateDepositShares(ZERO, sd(1000000e18), sd(1000000e18));
    }

    /// @notice Test withdrawal amount calculation
    function test_CalculateWithdrawAmount() public pure {
        SD59x18 totalAssets = sd(1000000e18);
        SD59x18 totalShares = sd(1000000e18);
        SD59x18 sharesToBurn = sd(250000e18);

        SD59x18 amount = Integrationtest.calculateWithdrawAmount(sharesToBurn, totalAssets, totalShares);

        // amount = sharesToBurn * totalAssets / totalShares = 250k
        SD59x18 expected = sd(250000e18);
        assertEq(SD59x18.unwrap(amount), SD59x18.unwrap(expected), "Withdraw amount should be proportional");
    }

    /// @notice Test pool state update after mint
    function test_UpdatePoolAfterMint() public pure {
        PoolState memory pool = PoolState({
            totalAssets: sd(1000000e18),
            lockedCollateral: ZERO,
            availableLiquidity: sd(1000000e18),
            totalPremiumsCollected: ZERO,
            totalPayoutsMade: ZERO,
            netDelta: ZERO
        });

        SD59x18 premium = sd(5000e18);
        SD59x18 collateral = sd(100000e18);

        PoolState memory updated = Integrationtest.updatePoolAfterMint(pool, premium, collateral);

        // Total assets should increase by premium
        assertEq(SD59x18.unwrap(updated.totalAssets), SD59x18.unwrap(sd(1005000e18)), "Assets should include premium");

        // Locked collateral should increase
        assertEq(SD59x18.unwrap(updated.lockedCollateral), SD59x18.unwrap(collateral), "Collateral should be locked");

        // Available liquidity should decrease
        SD59x18 expectedLiquidity = sd(1005000e18).sub(collateral);
        assertEq(
            SD59x18.unwrap(updated.availableLiquidity), SD59x18.unwrap(expectedLiquidity), "Liquidity should decrease"
        );
    }

    /// @notice Test pool update reverts on insufficient liquidity
    function test_UpdatePoolAfterMint_RevertOnInsufficientLiquidity() public {
        PoolState memory pool = _createPoolState(sd(50000e18)); // Only 50k

        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, 100000e18, 50000e18));
        wrapper.updatePoolAfterMint(pool, sd(5000e18), sd(100000e18)); // Need 100k collateral
    }

    /// @notice Test pool state update after exercise
    function test_UpdatePoolAfterExercise() public pure {
        PoolState memory pool = PoolState({
            totalAssets: sd(1000000e18),
            lockedCollateral: sd(100000e18),
            availableLiquidity: sd(900000e18),
            totalPremiumsCollected: sd(5000e18),
            totalPayoutsMade: ZERO,
            netDelta: ZERO
        });

        SD59x18 payoff = sd(25000e18);
        SD59x18 collateralReleased = sd(100000e18);

        PoolState memory updated = Integrationtest.updatePoolAfterExercise(pool, payoff, collateralReleased);

        // Total assets should decrease by payoff
        assertEq(SD59x18.unwrap(updated.totalAssets), SD59x18.unwrap(sd(975000e18)), "Assets should decrease by payoff");

        // Locked collateral should be zero
        assertEq(SD59x18.unwrap(updated.lockedCollateral), 0, "Collateral should be released");

        // Payouts made should increase
        assertEq(SD59x18.unwrap(updated.totalPayoutsMade), SD59x18.unwrap(payoff), "Payouts should be tracked");
    }

    /// @notice Test pool state update after OTM expiry
    function test_UpdatePoolAfterOTMExpiry() public pure {
        PoolState memory pool = PoolState({
            totalAssets: sd(1000000e18),
            lockedCollateral: sd(100000e18),
            availableLiquidity: sd(900000e18),
            totalPremiumsCollected: sd(5000e18),
            totalPayoutsMade: ZERO,
            netDelta: ZERO
        });

        SD59x18 collateralReleased = sd(100000e18);

        PoolState memory updated = Integrationtest.updatePoolAfterOTMExpiry(pool, collateralReleased);

        // Total assets unchanged
        assertEq(SD59x18.unwrap(updated.totalAssets), SD59x18.unwrap(pool.totalAssets), "Assets should be unchanged");

        // Locked collateral should be zero
        assertEq(SD59x18.unwrap(updated.lockedCollateral), 0, "Collateral should be released");

        // Available liquidity should be full
        assertEq(
            SD59x18.unwrap(updated.availableLiquidity), SD59x18.unwrap(pool.totalAssets), "Liquidity should be full"
        );
    }

    /// @notice Test utilization calculation
    function test_CalculateUtilization() public pure {
        PoolState memory pool = PoolState({
            totalAssets: sd(1000000e18),
            lockedCollateral: sd(400000e18),
            availableLiquidity: sd(600000e18),
            totalPremiumsCollected: ZERO,
            totalPayoutsMade: ZERO,
            netDelta: ZERO
        });

        SD59x18 utilization = Integrationtest.calculateUtilization(pool);

        // Utilization = lockedCollateral / totalAssets = 0.4
        SD59x18 expected = sd(400000000000000000);
        assertEq(SD59x18.unwrap(utilization), SD59x18.unwrap(expected), "Utilization should be 40%");
    }

    /// @notice Test utilization is zero for empty pool
    function test_CalculateUtilization_EmptyPool() public pure {
        PoolState memory pool = PoolState({
            totalAssets: ZERO,
            lockedCollateral: ZERO,
            availableLiquidity: ZERO,
            totalPremiumsCollected: ZERO,
            totalPayoutsMade: ZERO,
            netDelta: ZERO
        });
        SD59x18 utilization = Integrationtest.calculateUtilization(pool);

        assertEq(SD59x18.unwrap(utilization), 0, "Utilization should be zero for empty pool");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test oracle validation passes for fresh data
    function test_ValidateOraclePrice_FreshData() public view {
        OraclePrice memory priceData =
            OraclePrice({ price: SPOT_PRICE, timestamp: uint64(block.timestamp), roundId: 1 });

        // Should not revert
        Integrationtest.validateOraclePrice(priceData, block.timestamp);
    }

    /// @notice Test oracle validation reverts for stale data
    function test_ValidateOraclePrice_RevertOnStaleData() public {
        uint256 currentTime = 10000;
        OraclePrice memory priceData = OraclePrice({
            price: SPOT_PRICE,
            timestamp: uint64(currentTime - 4000), // 4000 seconds old
            roundId: 1
        });

        vm.expectRevert(abi.encodeWithSelector(StalePriceData.selector, priceData.timestamp, currentTime, 3600));
        wrapper.validateOraclePrice(priceData, currentTime);
    }

    /// @notice Test oracle validation reverts for invalid price
    function test_ValidateOraclePrice_RevertOnInvalidPrice() public {
        OraclePrice memory priceData = OraclePrice({ price: ZERO, timestamp: uint64(block.timestamp), roundId: 1 });

        vm.expectRevert(abi.encodeWithSelector(InvalidOraclePrice.selector, int256(0)));
        wrapper.validateOraclePrice(priceData, block.timestamp);
    }

    /// @notice Test price simulation - positive move
    function test_SimulatePriceMove_PositiveMove() public pure {
        SD59x18 currentPrice = sd(3000e18);
        SD59x18 change = sd(100000000000000000); // +10%

        SD59x18 newPrice = Integrationtest.simulatePriceMove(currentPrice, change);

        // New price should be 3300
        SD59x18 expected = sd(3300e18);
        assertEq(SD59x18.unwrap(newPrice), SD59x18.unwrap(expected), "Price should increase by 10%");
    }

    /// @notice Test price simulation - negative move
    function test_SimulatePriceMove_NegativeMove() public pure {
        SD59x18 currentPrice = sd(3000e18);
        SD59x18 change = sd(-200000000000000000); // -20%

        SD59x18 newPrice = Integrationtest.simulatePriceMove(currentPrice, change);

        // New price should be 2400
        SD59x18 expected = sd(2400e18);
        assertEq(SD59x18.unwrap(newPrice), SD59x18.unwrap(expected), "Price should decrease by 20%");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BATCH OPERATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test batch size validation passes for valid size
    function test_ValidateBatchSize_ValidSize() public pure {
        Integrationtest.validateBatchSize(50); // Max allowed
    }

    /// @notice Test batch size validation reverts for oversized batch
    function test_ValidateBatchSize_RevertOnOversizedBatch() public {
        vm.expectRevert(abi.encodeWithSelector(BatchSizeTooLarge.selector, 51, 50));
        wrapper.validateBatchSize(51);
    }

    /// @notice Test batch mint premium calculation
    function test_CalculateBatchMintPremium() public view {
        uint64 expiry = uint64(block.timestamp + ONE_MONTH);

        BatchMintRequest[] memory requests = new BatchMintRequest[](2);
        requests[0] = BatchMintRequest({ seriesId: 0, amount: ONE_OPTION, maxPremium: sd(1000e18) });
        requests[1] = BatchMintRequest({ seriesId: 1, amount: sd(2e18), maxPremium: sd(2000e18) });

        OptionSeries[] memory series = new OptionSeries[](2);
        series[0] = _createCallSeries(expiry);
        series[1] = _createPutSeries(expiry);

        SD59x18 totalPremium =
            Integrationtest.calculateBatchMintPremium(requests, series, SPOT_PRICE, VOLATILITY, block.timestamp);

        // Should be positive
        assertTrue(totalPremium.gt(ZERO), "Total premium should be positive");
    }

    /// @notice Test batch mint reverts on array length mismatch
    function test_CalculateBatchMintPremium_RevertOnLengthMismatch() public {
        BatchMintRequest[] memory requests = new BatchMintRequest[](2);
        OptionSeries[] memory series = new OptionSeries[](1);

        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 2, 1));
        wrapper.calculateBatchMintPremium(requests, series, SPOT_PRICE, VOLATILITY, block.timestamp);
    }

    /// @notice Test batch exercise payoff calculation
    function test_CalculateBatchExercisePayoff() public view {
        OptionPosition[] memory positions = new OptionPosition[](2);
        positions[0] = OptionPosition({
            seriesId: 0,
            holder: address(0x123),
            amount: ONE_OPTION,
            premiumPaid: sd(100e18),
            collateralLocked: sd(3000e18),
            isExercised: false,
            isSettled: false
        });
        positions[1] = OptionPosition({
            seriesId: 1,
            holder: address(0x123),
            amount: ONE_OPTION,
            premiumPaid: sd(100e18),
            collateralLocked: sd(3000e18),
            isExercised: false,
            isSettled: false
        });

        OptionSeries[] memory series = new OptionSeries[](2);
        series[0] = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + ONE_MONTH),
            strikePrice: sd(3000e18),
            isCall: true
        });
        series[1] = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + ONE_MONTH),
            strikePrice: sd(3000e18),
            isCall: true
        });

        SD59x18 spotPrice = sd(3500e18); // Both ITM

        (SD59x18 totalPayoff, uint256 itmCount) =
            Integrationtest.calculateBatchExercisePayoff(positions, series, spotPrice);

        // Both should be ITM with 500 payoff each
        assertEq(itmCount, 2, "Both options should be ITM");
        assertEq(SD59x18.unwrap(totalPayoff), SD59x18.unwrap(sd(1000e18)), "Total payoff should be 1000");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TIME UTILITY TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test time to expiry calculation
    function test_CalculateTimeToExpiry() public view {
        uint64 expiry = uint64(block.timestamp + ONE_YEAR);

        SD59x18 timeToExpiry = Integrationtest.calculateTimeToExpiry(expiry, block.timestamp);

        // Should be approximately 1 year
        assertTrue(timeToExpiry.gt(sd(990000000000000000)), "Should be close to 1 year");
        assertTrue(timeToExpiry.lt(sd(1010000000000000000)), "Should be close to 1 year");
    }

    /// @notice Test time to expiry reverts when expired
    function test_CalculateTimeToExpiry_RevertOnExpired() public {
        uint64 expiry = uint64(block.timestamp - 1); // Already expired

        vm.expectRevert(ZeroTimeToExpiry.selector);
        wrapper.calculateTimeToExpiry(expiry, block.timestamp);
    }

    /// @notice Test isExpired function
    function test_IsExpired() public view {
        uint64 futureExpiry = uint64(block.timestamp + ONE_MONTH);
        uint64 pastExpiry = uint64(block.timestamp - 1);

        assertFalse(Integrationtest.isExpired(futureExpiry, block.timestamp), "Future expiry should not be expired");
        assertTrue(Integrationtest.isExpired(pastExpiry, block.timestamp), "Past expiry should be expired");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VALIDATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test option series validation passes for valid series
    function test_ValidateOptionSeries_ValidSeries() public view {
        uint64 expiry = uint64(block.timestamp + ONE_MONTH);
        OptionSeries memory series = _createCallSeries(expiry);

        // Should not revert
        Integrationtest.validateOptionSeries(series, block.timestamp);
    }

    /// @notice Test option series validation reverts on invalid strike
    function test_ValidateOptionSeries_RevertOnInvalidStrike() public {
        OptionSeries memory series = OptionSeries({
            underlying: WETH,
            collateral: USDC,
            expiry: uint64(block.timestamp + ONE_MONTH),
            strikePrice: ZERO,
            isCall: true
        });

        vm.expectRevert(abi.encodeWithSelector(InvalidStrike.selector, ZERO));
        wrapper.validateOptionSeries(series, block.timestamp);
    }

    /// @notice Test option series validation reverts on short expiry
    function test_ValidateOptionSeries_RevertOnShortExpiry() public {
        uint64 shortExpiry = uint64(block.timestamp + 1800); // Only 30 minutes

        OptionSeries memory series = OptionSeries({
            underlying: WETH, collateral: USDC, expiry: shortExpiry, strikePrice: STRIKE_PRICE, isCall: true
        });

        vm.expectRevert(abi.encodeWithSelector(InvalidExpiry.selector, shortExpiry));
        wrapper.validateOptionSeries(series, block.timestamp);
    }

    /// @notice Test volatility validation passes for valid volatility
    function test_ValidateVolatility_ValidVolatility() public pure {
        Integrationtest.validateVolatility(VOLATILITY); // 65%
        Integrationtest.validateVolatility(sd(10000000000000000)); // 1%
        Integrationtest.validateVolatility(sd(5_000000000000000000)); // 500%
    }

    /// @notice Test volatility validation reverts on too low
    function test_ValidateVolatility_RevertOnTooLow() public {
        SD59x18 lowVol = sd(1000000000000000); // 0.1%

        vm.expectRevert(abi.encodeWithSelector(InvalidVolatility.selector, lowVol));
        wrapper.validateVolatility(lowVol);
    }

    /// @notice Test volatility validation reverts on too high
    function test_ValidateVolatility_RevertOnTooHigh() public {
        SD59x18 highVol = sd(6_000000000000000000); // 600%

        vm.expectRevert(abi.encodeWithSelector(InvalidVolatility.selector, highVol));
        wrapper.validateVolatility(highVol);
    }
}
