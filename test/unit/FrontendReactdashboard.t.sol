// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { FrontendReactdashboard } from "../../src/libraries/FrontendReactdashboard.sol";

/// @notice Wrapper contract to expose library functions for revert testing
contract FrontendReactdashboardWrapper {
    function computeGreeks(FrontendReactdashboard.GreeksInput memory input)
        external
        pure
        returns (FrontendReactdashboard.Greeks memory)
    {
        return FrontendReactdashboard.computeGreeks(input);
    }

    function computeDelta(FrontendReactdashboard.GreeksInput memory input) external pure returns (SD59x18) {
        return FrontendReactdashboard.computeDelta(input);
    }

    function computePrice(FrontendReactdashboard.GreeksInput memory input) external pure returns (SD59x18) {
        return FrontendReactdashboard.computePrice(input);
    }

    function buildOptionChain(
        SD59x18 spot,
        SD59x18[] memory strikes,
        SD59x18[] memory expiries,
        SD59x18 sigma,
        SD59x18 rate
    ) external pure returns (FrontendReactdashboard.ChainCell[] memory) {
        return FrontendReactdashboard.buildOptionChain(spot, strikes, expiries, sigma, rate);
    }

    function generateStrikes(SD59x18 spot, SD59x18 spread, uint256 count) external pure returns (SD59x18[] memory) {
        return FrontendReactdashboard.generateStrikes(spot, spread, count);
    }

    function computeLPDashboard(
        SD59x18 totalAssets,
        SD59x18 lockedCollateral,
        SD59x18 totalSupply,
        SD59x18 userShares,
        SD59x18 userDepositValue
    ) external pure returns (FrontendReactdashboard.LPDashboard memory) {
        return FrontendReactdashboard.computeLPDashboard(
            totalAssets, lockedCollateral, totalSupply, userShares, userDepositValue
        );
    }

    function computeDepositShares(SD59x18 depositAmount, SD59x18 totalAssets, SD59x18 totalSupply)
        external
        pure
        returns (SD59x18)
    {
        return FrontendReactdashboard.computeDepositShares(depositAmount, totalAssets, totalSupply);
    }

    function computeWithdrawAmount(SD59x18 sharesToBurn, SD59x18 totalAssets, SD59x18 totalSupply)
        external
        pure
        returns (SD59x18)
    {
        return FrontendReactdashboard.computeWithdrawAmount(sharesToBurn, totalAssets, totalSupply);
    }

    function buildIVSurface(SD59x18[] memory strikes, SD59x18[] memory expiries, SD59x18[] memory ivs)
        external
        pure
        returns (FrontendReactdashboard.IVSurfacePoint[] memory)
    {
        return FrontendReactdashboard.buildIVSurface(strikes, expiries, ivs);
    }

    function impliedVolatilityBisection(
        SD59x18 spot,
        SD59x18 strike,
        SD59x18 tau,
        SD59x18 rate,
        SD59x18 marketPrice,
        bool isCall
    ) external pure returns (SD59x18) {
        return FrontendReactdashboard.impliedVolatilityBisection(spot, strike, tau, rate, marketPrice, isCall);
    }

    function enrichPosition(
        SD59x18 strike,
        bool isCall,
        SD59x18 size,
        SD59x18 entryPrice,
        SD59x18 spot,
        SD59x18 sigma,
        SD59x18 tau,
        SD59x18 rate
    ) external pure returns (FrontendReactdashboard.PositionSummary memory) {
        return FrontendReactdashboard.enrichPosition(strike, isCall, size, entryPrice, spot, sigma, tau, rate);
    }

    function batchEnrichPositions(
        SD59x18[] memory strikes,
        bool[] memory isCalls,
        SD59x18[] memory sizes,
        SD59x18[] memory entryPrices,
        SD59x18 spot,
        SD59x18 sigma,
        SD59x18 tau,
        SD59x18 rate
    ) external pure returns (FrontendReactdashboard.PositionSummary[] memory) {
        return FrontendReactdashboard.batchEnrichPositions(strikes, isCalls, sizes, entryPrices, spot, sigma, tau, rate);
    }

    function aggregatePortfolioGreeks(
        SD59x18[] memory strikes,
        bool[] memory isCalls,
        SD59x18[] memory sizes,
        SD59x18 spot,
        SD59x18 sigma,
        SD59x18 tau,
        SD59x18 rate
    ) external pure returns (SD59x18, SD59x18, SD59x18, SD59x18) {
        return FrontendReactdashboard.aggregatePortfolioGreeks(strikes, isCalls, sizes, spot, sigma, tau, rate);
    }
}

/// @title FrontendReactdashboardTest
/// @notice Unit tests for FrontendReactdashboard library
contract FrontendReactdashboardTest is Test {
    FrontendReactdashboardWrapper internal wrapper;

    // Standard test parameters: ETH at $3000, ATM, 80% IV, 1 year, 5% rate
    SD59x18 internal constant SPOT = SD59x18.wrap(3000e18);
    SD59x18 internal constant STRIKE_ATM = SD59x18.wrap(3000e18);
    SD59x18 internal constant STRIKE_ITM_CALL = SD59x18.wrap(2800e18);
    SD59x18 internal constant STRIKE_OTM_CALL = SD59x18.wrap(3200e18);
    SD59x18 internal constant SIGMA = SD59x18.wrap(800000000000000000); // 0.8 = 80%
    SD59x18 internal constant TAU = SD59x18.wrap(1e18); // 1 year
    SD59x18 internal constant RATE = SD59x18.wrap(50000000000000000); // 0.05 = 5%

    function setUp() public {
        wrapper = new FrontendReactdashboardWrapper();
    }

    // =========================================================================
    // Greeks: Delta Tests
    // =========================================================================

    function test_computeGreeks_callDelta_ATM() public pure {
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });
        FrontendReactdashboard.Greeks memory g = FrontendReactdashboard.computeGreeks(input);
        // ATM call delta should be roughly 0.5-0.7 (with drift)
        assertGt(SD59x18.unwrap(g.delta), 4e17, "ATM call delta > 0.4");
        assertLt(SD59x18.unwrap(g.delta), 8e17, "ATM call delta < 0.8");
    }

    function test_computeGreeks_putDelta_ATM() public pure {
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: false
        });
        FrontendReactdashboard.Greeks memory g = FrontendReactdashboard.computeGreeks(input);
        // ATM put delta should be negative, roughly -0.5 to -0.3
        assertLt(SD59x18.unwrap(g.delta), 0, "Put delta is negative");
        assertGt(SD59x18.unwrap(g.delta), -8e17, "Put delta > -0.8");
    }

    function test_computeDelta_callPutRelation() public pure {
        FrontendReactdashboard.GreeksInput memory callInput = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });
        FrontendReactdashboard.GreeksInput memory putInput = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: false
        });

        SD59x18 callDelta = FrontendReactdashboard.computeDelta(callInput);
        SD59x18 putDelta = FrontendReactdashboard.computeDelta(putInput);

        // Call delta - Put delta = 1 (put-call parity for delta)
        int256 diff = SD59x18.unwrap(callDelta) - SD59x18.unwrap(putDelta);
        assertApproxEqRel(diff, 1e18, 1e15, "Call delta - Put delta = 1");
    }

    // =========================================================================
    // Greeks: Gamma Tests
    // =========================================================================

    function test_computeGreeks_gamma_positive() public pure {
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });
        FrontendReactdashboard.Greeks memory g = FrontendReactdashboard.computeGreeks(input);
        assertGt(SD59x18.unwrap(g.gamma), 0, "Gamma must be positive");
    }

    function test_computeGreeks_gamma_sameForCallPut() public pure {
        FrontendReactdashboard.GreeksInput memory callInput = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });
        FrontendReactdashboard.GreeksInput memory putInput = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: false
        });

        FrontendReactdashboard.Greeks memory cg = FrontendReactdashboard.computeGreeks(callInput);
        FrontendReactdashboard.Greeks memory pg = FrontendReactdashboard.computeGreeks(putInput);

        assertEq(SD59x18.unwrap(cg.gamma), SD59x18.unwrap(pg.gamma), "Gamma is same for call and put");
    }

    // =========================================================================
    // Greeks: Vega Tests
    // =========================================================================

    function test_computeGreeks_vega_positive() public pure {
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });
        FrontendReactdashboard.Greeks memory g = FrontendReactdashboard.computeGreeks(input);
        assertGt(SD59x18.unwrap(g.vega), 0, "Vega must be positive");
    }

    function test_computeGreeks_vega_sameForCallPut() public pure {
        FrontendReactdashboard.GreeksInput memory callInput = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });
        FrontendReactdashboard.GreeksInput memory putInput = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: false
        });

        FrontendReactdashboard.Greeks memory cg = FrontendReactdashboard.computeGreeks(callInput);
        FrontendReactdashboard.Greeks memory pg = FrontendReactdashboard.computeGreeks(putInput);

        assertEq(SD59x18.unwrap(cg.vega), SD59x18.unwrap(pg.vega), "Vega is same for call and put");
    }

    // =========================================================================
    // Greeks: Price Tests
    // =========================================================================

    function test_computeGreeks_callPrice_positive() public pure {
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });
        FrontendReactdashboard.Greeks memory g = FrontendReactdashboard.computeGreeks(input);
        assertGt(SD59x18.unwrap(g.price), 0, "Call price must be positive");
    }

    function test_computeGreeks_putCallParity() public pure {
        FrontendReactdashboard.GreeksInput memory callInput = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });
        FrontendReactdashboard.GreeksInput memory putInput = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: false
        });

        SD59x18 callPrice = FrontendReactdashboard.computePrice(callInput);
        SD59x18 putPrice = FrontendReactdashboard.computePrice(putInput);

        // Put-call parity: C - P = S - K × e^(-rτ)
        SD59x18 discount = RATE.mul(TAU).mul(sd(-1e18)).exp();
        int256 lhs = SD59x18.unwrap(callPrice) - SD59x18.unwrap(putPrice);
        int256 rhs = SD59x18.unwrap(SPOT) - SD59x18.unwrap(STRIKE_ATM.mul(discount));

        assertApproxEqRel(lhs, rhs, 1e15, "Put-call parity: C - P = S - Ke^(-rT)");
    }

    // =========================================================================
    // Greeks: Revert Tests
    // =========================================================================

    function test_computeGreeks_revertsOnZeroSpot() public {
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: ZERO, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });
        vm.expectRevert(FrontendReactdashboard.FrontendReactdashboard__InvalidSpotPrice.selector);
        wrapper.computeGreeks(input);
    }

    function test_computeGreeks_revertsOnZeroStrike() public {
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: ZERO, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });
        vm.expectRevert(FrontendReactdashboard.FrontendReactdashboard__InvalidStrikePrice.selector);
        wrapper.computeGreeks(input);
    }

    function test_computeGreeks_revertsOnInvalidVolatility() public {
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: SPOT,
            strike: STRIKE_ATM,
            sigma: sd(5000000000000000), // 0.005 = 0.5%, below MIN_IV
            tau: TAU,
            rate: RATE,
            isCall: true
        });
        vm.expectRevert(FrontendReactdashboard.FrontendReactdashboard__InvalidVolatility.selector);
        wrapper.computeGreeks(input);
    }

    function test_computeGreeks_revertsOnZeroTau() public {
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: ZERO, rate: RATE, isCall: true
        });
        vm.expectRevert(FrontendReactdashboard.FrontendReactdashboard__InvalidTimeToExpiry.selector);
        wrapper.computeGreeks(input);
    }

    // =========================================================================
    // Option Chain Tests
    // =========================================================================

    function test_buildOptionChain_singleCell() public pure {
        SD59x18[] memory strikes = new SD59x18[](1);
        strikes[0] = STRIKE_ATM;
        SD59x18[] memory expiries = new SD59x18[](1);
        expiries[0] = TAU;

        FrontendReactdashboard.ChainCell[] memory chain =
            FrontendReactdashboard.buildOptionChain(SPOT, strikes, expiries, SIGMA, RATE);

        assertEq(chain.length, 1, "Chain should have 1 cell");
        assertEq(SD59x18.unwrap(chain[0].strike), SD59x18.unwrap(STRIKE_ATM), "Strike matches");
        assertEq(SD59x18.unwrap(chain[0].expiry), SD59x18.unwrap(TAU), "Expiry matches");
        assertGt(SD59x18.unwrap(chain[0].callGreeks.price), 0, "Call price positive");
        assertGt(SD59x18.unwrap(chain[0].putGreeks.price), 0, "Put price positive");
    }

    function test_buildOptionChain_grid() public pure {
        SD59x18[] memory strikes = new SD59x18[](3);
        strikes[0] = STRIKE_ITM_CALL;
        strikes[1] = STRIKE_ATM;
        strikes[2] = STRIKE_OTM_CALL;

        SD59x18[] memory expiries = new SD59x18[](2);
        expiries[0] = sd(25e16); // 0.25 years
        expiries[1] = TAU; // 1 year

        FrontendReactdashboard.ChainCell[] memory chain =
            FrontendReactdashboard.buildOptionChain(SPOT, strikes, expiries, SIGMA, RATE);

        assertEq(chain.length, 6, "3 strikes x 2 expiries = 6 cells");

        // First 3 cells belong to expiry[0], last 3 to expiry[1]
        assertEq(SD59x18.unwrap(chain[0].expiry), 25e16, "First row is short expiry");
        assertEq(SD59x18.unwrap(chain[3].expiry), 1e18, "Second row is long expiry");
    }

    function test_buildOptionChain_revertsOnEmptyStrikes() public {
        SD59x18[] memory strikes = new SD59x18[](0);
        SD59x18[] memory expiries = new SD59x18[](1);
        expiries[0] = TAU;

        vm.expectRevert(FrontendReactdashboard.FrontendReactdashboard__EmptyStrikes.selector);
        wrapper.buildOptionChain(SPOT, strikes, expiries, SIGMA, RATE);
    }

    // =========================================================================
    // Generate Strikes Tests
    // =========================================================================

    function test_generateStrikes_basic() public pure {
        SD59x18[] memory strikes = FrontendReactdashboard.generateStrikes(SPOT, sd(2e17), 5); // ±20%, 5 strikes

        assertEq(strikes.length, 5, "Should generate 5 strikes");

        // First strike = 3000 * 0.8 = 2400
        assertApproxEqRel(SD59x18.unwrap(strikes[0]), 2400e18, 1e15, "Lower bound ~2400");

        // Last strike = 3000 * 1.2 = 3600
        assertApproxEqRel(SD59x18.unwrap(strikes[4]), 3600e18, 1e15, "Upper bound ~3600");

        // Strikes should be ascending
        for (uint256 i = 1; i < strikes.length; i++) {
            assertGt(SD59x18.unwrap(strikes[i]), SD59x18.unwrap(strikes[i - 1]), "Strikes ascending");
        }
    }

    function test_generateStrikes_revertsOnCountOne() public {
        vm.expectRevert(FrontendReactdashboard.FrontendReactdashboard__EmptyStrikes.selector);
        wrapper.generateStrikes(SPOT, sd(2e17), 1);
    }

    // =========================================================================
    // LP Dashboard Tests
    // =========================================================================

    function test_computeLPDashboard_basic() public pure {
        SD59x18 totalAssets = sd(1_000_000e18);
        SD59x18 locked = sd(300_000e18);
        SD59x18 totalSupply = sd(500_000e18);
        SD59x18 userShares = sd(50_000e18);
        SD59x18 userDeposit = sd(90_000e18);

        FrontendReactdashboard.LPDashboard memory dash =
            FrontendReactdashboard.computeLPDashboard(totalAssets, locked, totalSupply, userShares, userDeposit);

        // Utilization = 300k / 1M = 0.3
        assertApproxEqRel(SD59x18.unwrap(dash.utilization), 3e17, 1e14, "Utilization = 30%");

        // Share price = 1M / 500k = 2.0
        assertApproxEqRel(SD59x18.unwrap(dash.sharePrice), 2e18, 1e14, "Share price = 2.0");

        // User equity = 50k × 2.0 = 100k
        assertApproxEqRel(SD59x18.unwrap(dash.userEquity), 100_000e18, 1e14, "Equity = 100k");

        // P&L = 100k - 90k = 10k (profit)
        assertApproxEqRel(SD59x18.unwrap(dash.pnl), 10_000e18, 1e14, "PnL = +10k");

        // PnL % = 10k / 90k ≈ 11.11%
        assertApproxEqRel(SD59x18.unwrap(dash.pnlPercent), 111111111111111111, 1e14, "PnL % ~11.1%");
    }

    function test_computeLPDashboard_loss() public pure {
        SD59x18 totalAssets = sd(800_000e18); // Pool lost value
        SD59x18 locked = sd(200_000e18);
        SD59x18 totalSupply = sd(500_000e18);
        SD59x18 userShares = sd(50_000e18);
        SD59x18 userDeposit = sd(100_000e18);

        FrontendReactdashboard.LPDashboard memory dash =
            FrontendReactdashboard.computeLPDashboard(totalAssets, locked, totalSupply, userShares, userDeposit);

        // User equity = 50k × (800k / 500k) = 50k × 1.6 = 80k
        assertApproxEqRel(SD59x18.unwrap(dash.userEquity), 80_000e18, 1e14, "Equity = 80k");

        // P&L = 80k - 100k = -20k (loss)
        assertLt(SD59x18.unwrap(dash.pnl), 0, "PnL is negative (loss)");
    }

    function test_computeLPDashboard_revertsOnZeroAssets() public {
        vm.expectRevert(FrontendReactdashboard.FrontendReactdashboard__ZeroTotalAssets.selector);
        wrapper.computeLPDashboard(ZERO, ZERO, sd(1e18), sd(1e18), sd(1e18));
    }

    function test_computeLPDashboard_revertsOnZeroSupply() public {
        vm.expectRevert(FrontendReactdashboard.FrontendReactdashboard__ZeroTotalSupply.selector);
        wrapper.computeLPDashboard(sd(1e18), ZERO, ZERO, sd(1e18), sd(1e18));
    }

    // =========================================================================
    // Deposit/Withdraw Share Tests
    // =========================================================================

    function test_computeDepositShares_basic() public pure {
        // Pool: 1M assets, 500k shares. Deposit 100k -> 50k shares
        SD59x18 shares = FrontendReactdashboard.computeDepositShares(sd(100_000e18), sd(1_000_000e18), sd(500_000e18));
        assertApproxEqRel(SD59x18.unwrap(shares), 50_000e18, 1e14, "Deposit 100k gets 50k shares");
    }

    function test_computeWithdrawAmount_basic() public pure {
        // Pool: 1M assets, 500k shares. Burn 50k shares -> 100k assets
        SD59x18 amount = FrontendReactdashboard.computeWithdrawAmount(sd(50_000e18), sd(1_000_000e18), sd(500_000e18));
        assertApproxEqRel(SD59x18.unwrap(amount), 100_000e18, 1e14, "Burn 50k shares gets 100k assets");
    }

    function test_computeDepositShares_revertsOnZeroDeposit() public {
        vm.expectRevert(FrontendReactdashboard.FrontendReactdashboard__ZeroDepositAmount.selector);
        wrapper.computeDepositShares(ZERO, sd(1e18), sd(1e18));
    }

    // =========================================================================
    // IV Surface Tests
    // =========================================================================

    function test_buildIVSurface_basic() public pure {
        SD59x18[] memory strikes = new SD59x18[](2);
        strikes[0] = sd(2800e18);
        strikes[1] = sd(3200e18);

        SD59x18[] memory expiries = new SD59x18[](2);
        expiries[0] = sd(25e16);
        expiries[1] = sd(1e18);

        SD59x18[] memory ivs = new SD59x18[](4);
        ivs[0] = sd(85e16); // 85%
        ivs[1] = sd(80e16); // 80%
        ivs[2] = sd(75e16); // 75%
        ivs[3] = sd(70e16); // 70%

        FrontendReactdashboard.IVSurfacePoint[] memory surface =
            FrontendReactdashboard.buildIVSurface(strikes, expiries, ivs);

        assertEq(surface.length, 4, "2x2 surface = 4 points");
        assertEq(SD59x18.unwrap(surface[0].iv), 85e16, "First point IV correct");
        assertEq(SD59x18.unwrap(surface[3].iv), 70e16, "Last point IV correct");
    }

    function test_buildIVSurface_revertsOnLengthMismatch() public {
        SD59x18[] memory strikes = new SD59x18[](2);
        strikes[0] = sd(2800e18);
        strikes[1] = sd(3200e18);

        SD59x18[] memory expiries = new SD59x18[](2);
        expiries[0] = sd(25e16);
        expiries[1] = sd(1e18);

        SD59x18[] memory ivs = new SD59x18[](3); // Should be 4

        vm.expectRevert(
            abi.encodeWithSelector(FrontendReactdashboard.FrontendReactdashboard__ArrayLengthMismatch.selector, 4, 3)
        );
        wrapper.buildIVSurface(strikes, expiries, ivs);
    }

    // =========================================================================
    // Implied Volatility Bisection Tests
    // =========================================================================

    function test_impliedVolatilityBisection_roundTrip() public pure {
        // Price an option at known sigma, then recover sigma
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: SPOT, strike: STRIKE_ATM, sigma: SIGMA, tau: TAU, rate: RATE, isCall: true
        });

        SD59x18 marketPrice = FrontendReactdashboard.computePrice(input);

        SD59x18 recoveredIV =
            FrontendReactdashboard.impliedVolatilityBisection(SPOT, STRIKE_ATM, TAU, RATE, marketPrice, true);

        // Should recover the original sigma within 1%
        assertApproxEqRel(SD59x18.unwrap(recoveredIV), SD59x18.unwrap(SIGMA), 1e16, "Recovered IV matches original");
    }

    // =========================================================================
    // Position Enrichment Tests
    // =========================================================================

    function test_enrichPosition_longCall() public pure {
        SD59x18 entryPrice = sd(100e18);
        SD59x18 size = sd(10e18);

        FrontendReactdashboard.PositionSummary memory summary =
            FrontendReactdashboard.enrichPosition(STRIKE_ATM, true, size, entryPrice, SPOT, SIGMA, TAU, RATE);

        assertEq(SD59x18.unwrap(summary.strike), SD59x18.unwrap(STRIKE_ATM), "Strike matches");
        assertTrue(summary.isCall, "Is call");
        assertGt(SD59x18.unwrap(summary.currentPrice), 0, "Current price > 0");
        assertGt(SD59x18.unwrap(summary.delta), 0, "Long call has positive delta");
    }

    function test_batchEnrichPositions_basic() public pure {
        SD59x18[] memory strikes = new SD59x18[](2);
        strikes[0] = STRIKE_ATM;
        strikes[1] = STRIKE_ATM;

        bool[] memory isCalls = new bool[](2);
        isCalls[0] = true;
        isCalls[1] = false;

        SD59x18[] memory sizes = new SD59x18[](2);
        sizes[0] = sd(5e18);
        sizes[1] = sd(5e18);

        SD59x18[] memory entryPrices = new SD59x18[](2);
        entryPrices[0] = sd(100e18);
        entryPrices[1] = sd(80e18);

        FrontendReactdashboard.PositionSummary[] memory summaries =
            FrontendReactdashboard.batchEnrichPositions(strikes, isCalls, sizes, entryPrices, SPOT, SIGMA, TAU, RATE);

        assertEq(summaries.length, 2, "Two positions returned");
        assertTrue(summaries[0].isCall, "First is call");
        assertFalse(summaries[1].isCall, "Second is put");
    }

    function test_batchEnrichPositions_revertsOnMismatch() public {
        SD59x18[] memory strikes = new SD59x18[](2);
        strikes[0] = STRIKE_ATM;
        strikes[1] = STRIKE_ATM;

        bool[] memory isCalls = new bool[](1); // Wrong length

        SD59x18[] memory sizes = new SD59x18[](2);
        SD59x18[] memory entryPrices = new SD59x18[](2);

        vm.expectRevert(
            abi.encodeWithSelector(FrontendReactdashboard.FrontendReactdashboard__ArrayLengthMismatch.selector, 2, 1)
        );
        wrapper.batchEnrichPositions(strikes, isCalls, sizes, entryPrices, SPOT, SIGMA, TAU, RATE);
    }

    // =========================================================================
    // Aggregate Portfolio Greeks Tests
    // =========================================================================

    function test_aggregatePortfolioGreeks_deltaHedge() public pure {
        // Long 1 call + short delta shares should have ~0 portfolio delta
        SD59x18[] memory strikes = new SD59x18[](1);
        strikes[0] = STRIKE_ATM;

        bool[] memory isCalls = new bool[](1);
        isCalls[0] = true;

        SD59x18[] memory sizes = new SD59x18[](1);
        sizes[0] = sd(1e18);

        (SD59x18 totalDelta,,,) =
            FrontendReactdashboard.aggregatePortfolioGreeks(strikes, isCalls, sizes, SPOT, SIGMA, TAU, RATE);

        // Single call delta should be between 0.4 and 0.8
        assertGt(SD59x18.unwrap(totalDelta), 4e17, "Portfolio delta > 0.4");
        assertLt(SD59x18.unwrap(totalDelta), 8e17, "Portfolio delta < 0.8");
    }
}
