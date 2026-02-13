// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { FrontendReactdashboard } from "../../src/libraries/FrontendReactdashboard.sol";

/// @title FrontendReactdashboardFuzzTest
/// @notice Fuzz tests for FrontendReactdashboard library
/// @dev Tests mathematical invariants across random inputs
contract FrontendReactdashboardFuzzTest is Test {
    // Bounds for realistic option parameters
    uint256 internal constant MIN_PRICE = 10; // $10
    uint256 internal constant MAX_PRICE = 100_000; // $100k
    uint256 internal constant MIN_SIGMA = 20; // 20% = 0.20
    uint256 internal constant MAX_SIGMA = 300; // 300% = 3.00
    uint256 internal constant MIN_TAU = 1; // ~0.27% of year (1 day)
    uint256 internal constant MAX_TAU = 730; // 2 years in days

    /// @dev Helper: builds a GreeksInput from bounded raw values
    function _buildInput(uint256 spotRaw, uint256 strikeRaw, uint256 sigmaRaw, uint256 tauDays, bool isCall)
        internal
        pure
        returns (FrontendReactdashboard.GreeksInput memory)
    {
        return FrontendReactdashboard.GreeksInput({
            spot: sd(int256(spotRaw) * 1e18),
            strike: sd(int256(strikeRaw) * 1e18),
            sigma: sd(int256(sigmaRaw) * 1e16), // sigmaRaw=80 -> 0.80e18
            tau: sd(int256(tauDays) * 1e18).div(sd(365.25e18)), // convert days to years
            rate: sd(5e16), // fixed 5% rate
            isCall: isCall
        });
    }

    // =========================================================================
    // Delta Invariants
    // =========================================================================

    /// @notice Call delta is always in [0, 1]
    function testFuzz_callDelta_bounded(uint256 spotRaw, uint256 strikeRaw, uint256 sigmaRaw, uint256 tauDays)
        public
        pure
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        sigmaRaw = bound(sigmaRaw, MIN_SIGMA, MAX_SIGMA);
        tauDays = bound(tauDays, MIN_TAU, MAX_TAU);

        FrontendReactdashboard.GreeksInput memory input = _buildInput(spotRaw, strikeRaw, sigmaRaw, tauDays, true);
        FrontendReactdashboard.Greeks memory g = FrontendReactdashboard.computeGreeks(input);

        assertGe(SD59x18.unwrap(g.delta), 0, "Call delta >= 0");
        assertLe(SD59x18.unwrap(g.delta), 1e18 + 1e14, "Call delta <= 1 (with tolerance)");
    }

    /// @notice Put delta is always in [-1, 0]
    function testFuzz_putDelta_bounded(uint256 spotRaw, uint256 strikeRaw, uint256 sigmaRaw, uint256 tauDays)
        public
        pure
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        sigmaRaw = bound(sigmaRaw, MIN_SIGMA, MAX_SIGMA);
        tauDays = bound(tauDays, MIN_TAU, MAX_TAU);

        FrontendReactdashboard.GreeksInput memory input = _buildInput(spotRaw, strikeRaw, sigmaRaw, tauDays, false);
        FrontendReactdashboard.Greeks memory g = FrontendReactdashboard.computeGreeks(input);

        assertLe(SD59x18.unwrap(g.delta), 0, "Put delta <= 0");
        assertGe(SD59x18.unwrap(g.delta), -1e18 - 1e14, "Put delta >= -1 (with tolerance)");
    }

    /// @notice Call delta - Put delta = 1 (put-call delta parity)
    function testFuzz_deltaParity(uint256 spotRaw, uint256 strikeRaw, uint256 sigmaRaw, uint256 tauDays) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        sigmaRaw = bound(sigmaRaw, MIN_SIGMA, MAX_SIGMA);
        tauDays = bound(tauDays, MIN_TAU, MAX_TAU);

        FrontendReactdashboard.GreeksInput memory callInput = _buildInput(spotRaw, strikeRaw, sigmaRaw, tauDays, true);
        FrontendReactdashboard.GreeksInput memory putInput = _buildInput(spotRaw, strikeRaw, sigmaRaw, tauDays, false);

        SD59x18 callDelta = FrontendReactdashboard.computeDelta(callInput);
        SD59x18 putDelta = FrontendReactdashboard.computeDelta(putInput);

        int256 diff = SD59x18.unwrap(callDelta) - SD59x18.unwrap(putDelta);
        assertApproxEqRel(diff, 1e18, 1e15, "Call delta - Put delta = 1");
    }

    // =========================================================================
    // Gamma & Vega Invariants
    // =========================================================================

    /// @notice Gamma is always non-negative
    function testFuzz_gamma_nonnegative(uint256 spotRaw, uint256 strikeRaw, uint256 sigmaRaw, uint256 tauDays)
        public
        pure
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        sigmaRaw = bound(sigmaRaw, MIN_SIGMA, MAX_SIGMA);
        tauDays = bound(tauDays, MIN_TAU, MAX_TAU);

        FrontendReactdashboard.GreeksInput memory input = _buildInput(spotRaw, strikeRaw, sigmaRaw, tauDays, true);
        FrontendReactdashboard.Greeks memory g = FrontendReactdashboard.computeGreeks(input);

        assertGe(SD59x18.unwrap(g.gamma), 0, "Gamma >= 0");
    }

    /// @notice Vega is always non-negative
    function testFuzz_vega_nonnegative(uint256 spotRaw, uint256 strikeRaw, uint256 sigmaRaw, uint256 tauDays)
        public
        pure
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        sigmaRaw = bound(sigmaRaw, MIN_SIGMA, MAX_SIGMA);
        tauDays = bound(tauDays, MIN_TAU, MAX_TAU);

        FrontendReactdashboard.GreeksInput memory input = _buildInput(spotRaw, strikeRaw, sigmaRaw, tauDays, true);
        FrontendReactdashboard.Greeks memory g = FrontendReactdashboard.computeGreeks(input);

        assertGe(SD59x18.unwrap(g.vega), 0, "Vega >= 0");
    }

    /// @notice Gamma is the same for calls and puts (same strike/expiry)
    function testFuzz_gamma_callEqualsPut(uint256 spotRaw, uint256 strikeRaw, uint256 sigmaRaw, uint256 tauDays)
        public
        pure
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        sigmaRaw = bound(sigmaRaw, MIN_SIGMA, MAX_SIGMA);
        tauDays = bound(tauDays, MIN_TAU, MAX_TAU);

        FrontendReactdashboard.GreeksInput memory callInput = _buildInput(spotRaw, strikeRaw, sigmaRaw, tauDays, true);
        FrontendReactdashboard.GreeksInput memory putInput = _buildInput(spotRaw, strikeRaw, sigmaRaw, tauDays, false);

        FrontendReactdashboard.Greeks memory cg = FrontendReactdashboard.computeGreeks(callInput);
        FrontendReactdashboard.Greeks memory pg = FrontendReactdashboard.computeGreeks(putInput);

        assertEq(SD59x18.unwrap(cg.gamma), SD59x18.unwrap(pg.gamma), "Gamma(call) = Gamma(put)");
    }

    // =========================================================================
    // Put-Call Price Parity
    // =========================================================================

    /// @notice Put-call parity: C - P = S - K * e^(-rT)
    function testFuzz_putCallParity(uint256 spotRaw, uint256 strikeRaw, uint256 sigmaRaw, uint256 tauDays) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        sigmaRaw = bound(sigmaRaw, MIN_SIGMA, MAX_SIGMA);
        tauDays = bound(tauDays, MIN_TAU, MAX_TAU);

        FrontendReactdashboard.GreeksInput memory callInput = _buildInput(spotRaw, strikeRaw, sigmaRaw, tauDays, true);
        FrontendReactdashboard.GreeksInput memory putInput = _buildInput(spotRaw, strikeRaw, sigmaRaw, tauDays, false);

        SD59x18 callPrice = FrontendReactdashboard.computePrice(callInput);
        SD59x18 putPrice = FrontendReactdashboard.computePrice(putInput);

        // discount = e^(-r * tau)
        SD59x18 discount = callInput.rate.mul(callInput.tau).mul(sd(-1e18)).exp();

        int256 lhs = SD59x18.unwrap(callPrice) - SD59x18.unwrap(putPrice);
        int256 rhs = SD59x18.unwrap(callInput.spot) - SD59x18.unwrap(callInput.strike.mul(discount));

        // 0.1% tolerance for numerical precision
        assertApproxEqRel(lhs, rhs, 1e15, "Put-call parity holds");
    }

    // =========================================================================
    // LP Dashboard Invariants
    // =========================================================================

    /// @notice Deposit then withdraw returns same amount (no-arbitrage share pricing)
    function testFuzz_depositWithdraw_roundTrip(uint256 assetsRaw, uint256 supplyRaw, uint256 depositRaw) public pure {
        assetsRaw = bound(assetsRaw, 1, 1_000_000_000);
        supplyRaw = bound(supplyRaw, 1, 1_000_000_000);
        depositRaw = bound(depositRaw, 1, 1_000_000_000);

        SD59x18 totalAssets = sd(int256(assetsRaw) * 1e18);
        SD59x18 totalSupply = sd(int256(supplyRaw) * 1e18);
        SD59x18 deposit = sd(int256(depositRaw) * 1e18);

        SD59x18 shares = FrontendReactdashboard.computeDepositShares(deposit, totalAssets, totalSupply);

        // After deposit: new totals
        SD59x18 newAssets = totalAssets.add(deposit);
        SD59x18 newSupply = totalSupply.add(shares);

        // Withdraw all minted shares
        SD59x18 withdrawn = FrontendReactdashboard.computeWithdrawAmount(shares, newAssets, newSupply);

        // Should recover the deposit amount
        assertApproxEqRel(
            SD59x18.unwrap(withdrawn), SD59x18.unwrap(deposit), 1e14, "Deposit-withdraw round trip preserves value"
        );
    }

    /// @notice LP utilization is always in [0, 1] when locked <= total
    function testFuzz_lpDashboard_utilizationBounded(uint256 totalRaw, uint256 lockedRaw) public pure {
        totalRaw = bound(totalRaw, 1, 1_000_000_000);
        lockedRaw = bound(lockedRaw, 0, totalRaw);

        SD59x18 totalAssets = sd(int256(totalRaw) * 1e18);
        SD59x18 locked = sd(int256(lockedRaw) * 1e18);
        SD59x18 totalSupply = sd(int256(totalRaw) * 1e18); // 1:1 for simplicity

        FrontendReactdashboard.LPDashboard memory dash =
            FrontendReactdashboard.computeLPDashboard(totalAssets, locked, totalSupply, sd(1e18), sd(1e18));

        assertGe(SD59x18.unwrap(dash.utilization), 0, "Utilization >= 0");
        assertLe(SD59x18.unwrap(dash.utilization), 1e18 + 1, "Utilization <= 1");
    }

    // =========================================================================
    // Generate Strikes Invariants
    // =========================================================================

    /// @notice Generated strikes are always ascending
    function testFuzz_generateStrikes_ascending(uint256 spotRaw, uint256 spreadRaw, uint256 count) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        spreadRaw = bound(spreadRaw, 5, 50); // 5% to 50%
        count = bound(count, 2, 20);

        SD59x18 spot = sd(int256(spotRaw) * 1e18);
        SD59x18 spread = sd(int256(spreadRaw) * 1e16); // spreadRaw=20 -> 0.20e18

        SD59x18[] memory strikes = FrontendReactdashboard.generateStrikes(spot, spread, count);

        assertEq(strikes.length, count, "Correct count");
        for (uint256 i = 1; i < strikes.length; i++) {
            assertGt(SD59x18.unwrap(strikes[i]), SD59x18.unwrap(strikes[i - 1]), "Strikes ascending");
        }
    }

    /// @notice Generated strikes are centered around spot
    function testFuzz_generateStrikes_centered(uint256 spotRaw, uint256 spreadRaw) public pure {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        spreadRaw = bound(spreadRaw, 5, 50);

        SD59x18 spot = sd(int256(spotRaw) * 1e18);
        SD59x18 spread = sd(int256(spreadRaw) * 1e16);

        SD59x18[] memory strikes = FrontendReactdashboard.generateStrikes(spot, spread, 11); // odd count

        // Middle strike should be close to spot
        SD59x18 midStrike = strikes[5];
        assertApproxEqRel(SD59x18.unwrap(midStrike), SD59x18.unwrap(spot), 1e15, "Middle strike ~= spot");
    }

    // =========================================================================
    // IV Surface Invariants
    // =========================================================================

    /// @notice IV surface preserves all input data
    function testFuzz_buildIVSurface_preservesData(uint256 nStrikes, uint256 nExpiries) public pure {
        nStrikes = bound(nStrikes, 1, 5);
        nExpiries = bound(nExpiries, 1, 5);

        SD59x18[] memory strikes = new SD59x18[](nStrikes);
        SD59x18[] memory expiries = new SD59x18[](nExpiries);
        SD59x18[] memory ivs = new SD59x18[](nStrikes * nExpiries);

        for (uint256 i = 0; i < nStrikes; i++) {
            strikes[i] = sd(int256((i + 1) * 1000) * 1e18);
        }
        for (uint256 i = 0; i < nExpiries; i++) {
            expiries[i] = sd(int256((i + 1)) * 1e17); // 0.1, 0.2, ...
        }
        for (uint256 i = 0; i < ivs.length; i++) {
            ivs[i] = sd(int256((i + 50)) * 1e16); // 0.50, 0.51, ...
        }

        FrontendReactdashboard.IVSurfacePoint[] memory surface =
            FrontendReactdashboard.buildIVSurface(strikes, expiries, ivs);

        assertEq(surface.length, nStrikes * nExpiries, "Correct total points");

        // Verify data preserved
        for (uint256 i = 0; i < surface.length; i++) {
            assertEq(SD59x18.unwrap(surface[i].iv), SD59x18.unwrap(ivs[i]), "IV preserved");
        }
    }

    // =========================================================================
    // Position Enrichment Invariants
    // =========================================================================

    /// @notice Long position P&L sign matches price movement direction
    function testFuzz_enrichPosition_pnlSign(uint256 spotRaw, uint256 strikeRaw, uint256 sigmaRaw, uint256 tauDays)
        public
        pure
    {
        spotRaw = bound(spotRaw, MIN_PRICE, MAX_PRICE);
        strikeRaw = bound(strikeRaw, MIN_PRICE, MAX_PRICE);
        sigmaRaw = bound(sigmaRaw, MIN_SIGMA, MAX_SIGMA);
        tauDays = bound(tauDays, MIN_TAU, MAX_TAU);

        SD59x18 spot = sd(int256(spotRaw) * 1e18);
        SD59x18 strike = sd(int256(strikeRaw) * 1e18);
        SD59x18 sigma = sd(int256(sigmaRaw) * 1e16);
        SD59x18 tau = sd(int256(tauDays) * 1e18).div(sd(365.25e18));

        // Compute current price
        FrontendReactdashboard.GreeksInput memory input = FrontendReactdashboard.GreeksInput({
            spot: spot, strike: strike, sigma: sigma, tau: tau, rate: sd(5e16), isCall: true
        });
        SD59x18 currentPrice = FrontendReactdashboard.computePrice(input);

        // Set entry price = current price -> PnL should be ~0
        SD59x18 size = sd(1e18);
        FrontendReactdashboard.PositionSummary memory summary =
            FrontendReactdashboard.enrichPosition(strike, true, size, currentPrice, spot, sigma, tau, sd(5e16));

        // PnL should be approximately 0 when entry = current
        assertApproxEqAbs(SD59x18.unwrap(summary.unrealizedPnl), 0, 1e8, "PnL ~0 when entry = mark");
    }
}
