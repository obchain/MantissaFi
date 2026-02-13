// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, ZERO } from "@prb/math/SD59x18.sol";
import { CumulativeNormal } from "./CumulativeNormal.sol";
import { Constants } from "./Constants.sol";

/// @title FrontendReactdashboard
/// @notice On-chain computation library powering the React + wagmi + viem frontend dashboard
/// @dev Provides pure functions for option chain views, Black-Scholes Greeks (delta, gamma, theta, vega),
///      LP dashboard metrics (P&L, utilization, share pricing), IV surface grid generation,
///      and position enrichment for transaction history. All math uses SD59x18 fixed-point arithmetic.
/// @author MantissaFi Team
library FrontendReactdashboard {
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                                   CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice 1.0 in SD59x18 fixed-point
    int256 private constant ONE = 1e18;

    /// @notice 0.5 in SD59x18 fixed-point
    int256 private constant HALF = 5e17;

    /// @notice 2.0 in SD59x18 fixed-point
    int256 private constant TWO = 2e18;

    /// @notice Seconds per year (365.25 days) in SD59x18 fixed-point
    int256 private constant SECONDS_PER_YEAR_SD = 31_557_600e18;

    /// @notice Minimum allowed implied volatility (1% = 0.01)
    int256 private constant MIN_IV = 10000000000000000;

    /// @notice Maximum allowed implied volatility (1000% = 10.0)
    int256 private constant MAX_IV = 10_000000000000000000;

    /// @notice Minimum time to expiry for Greeks (1 second in years ≈ 3.17e-8)
    int256 private constant MIN_TIME_TO_EXPIRY = 31709791983;

    /// @notice Maximum number of strikes in a chain view (gas safety bound)
    uint256 private constant MAX_CHAIN_STRIKES = 50;

    /// @notice Maximum grid dimension for IV surface (gas safety bound)
    uint256 private constant MAX_SURFACE_DIM = 20;

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                                    ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when spot price is zero or negative
    error FrontendReactdashboard__InvalidSpotPrice();

    /// @notice Thrown when strike price is zero or negative
    error FrontendReactdashboard__InvalidStrikePrice();

    /// @notice Thrown when implied volatility is out of valid range
    error FrontendReactdashboard__InvalidVolatility();

    /// @notice Thrown when time to expiry is zero or negative
    error FrontendReactdashboard__InvalidTimeToExpiry();

    /// @notice Thrown when the risk-free rate is excessively negative
    error FrontendReactdashboard__InvalidRate();

    /// @notice Thrown when array lengths do not match
    error FrontendReactdashboard__ArrayLengthMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when the strike array is empty
    error FrontendReactdashboard__EmptyStrikes();

    /// @notice Thrown when the expiry array is empty
    error FrontendReactdashboard__EmptyExpiries();

    /// @notice Thrown when an array exceeds the maximum allowed length
    error FrontendReactdashboard__ArrayTooLarge(uint256 length, uint256 max);

    /// @notice Thrown when total assets is zero in LP calculations
    error FrontendReactdashboard__ZeroTotalAssets();

    /// @notice Thrown when total supply is zero in share pricing
    error FrontendReactdashboard__ZeroTotalSupply();

    /// @notice Thrown when deposit amount is zero
    error FrontendReactdashboard__ZeroDepositAmount();

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                                    STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Parameters for Black-Scholes Greeks computation
    /// @param spot Current spot price of the underlying (SD59x18, must be > 0)
    /// @param strike Option strike price (SD59x18, must be > 0)
    /// @param sigma Implied volatility (SD59x18, annualized, e.g. 0.8e18 = 80%)
    /// @param tau Time to expiry in years (SD59x18, must be > 0)
    /// @param rate Risk-free rate (SD59x18, annualized, e.g. 0.05e18 = 5%)
    /// @param isCall True for call, false for put
    struct GreeksInput {
        SD59x18 spot;
        SD59x18 strike;
        SD59x18 sigma;
        SD59x18 tau;
        SD59x18 rate;
        bool isCall;
    }

    /// @notice Complete set of Black-Scholes Greeks for a single option
    /// @param delta ∂V/∂S — sensitivity to underlying price
    /// @param gamma ∂²V/∂S² — rate of change of delta
    /// @param theta ∂V/∂τ — time decay (per year, divide by 365.25 for daily)
    /// @param vega ∂V/∂σ — sensitivity to volatility
    /// @param price Black-Scholes theoretical price
    struct Greeks {
        SD59x18 delta;
        SD59x18 gamma;
        SD59x18 theta;
        SD59x18 vega;
        SD59x18 price;
    }

    /// @notice A single cell in the option chain grid (one strike × one expiry)
    /// @param strike Strike price (SD59x18)
    /// @param expiry Time to expiry in years (SD59x18)
    /// @param callGreeks Greeks for the call at this (strike, expiry)
    /// @param putGreeks Greeks for the put at this (strike, expiry)
    struct ChainCell {
        SD59x18 strike;
        SD59x18 expiry;
        Greeks callGreeks;
        Greeks putGreeks;
    }

    /// @notice LP dashboard snapshot for a liquidity provider
    /// @param totalAssets Total pool assets (SD59x18)
    /// @param lockedCollateral Collateral locked in active positions (SD59x18)
    /// @param utilization Pool utilization ratio = locked / total (SD59x18)
    /// @param sharePrice Price per LP share = totalAssets / totalSupply (SD59x18)
    /// @param userShares Number of LP shares held by the user (SD59x18)
    /// @param userEquity User's equity = shares × sharePrice (SD59x18)
    /// @param pnl User's unrealized P&L = equity - depositValue (SD59x18)
    /// @param pnlPercent P&L as percentage of initial deposit (SD59x18)
    struct LPDashboard {
        SD59x18 totalAssets;
        SD59x18 lockedCollateral;
        SD59x18 utilization;
        SD59x18 sharePrice;
        SD59x18 userShares;
        SD59x18 userEquity;
        SD59x18 pnl;
        SD59x18 pnlPercent;
    }

    /// @notice A single point on the IV surface grid
    /// @param strike Strike price (SD59x18)
    /// @param expiry Time to expiry in years (SD59x18)
    /// @param iv Implied volatility at this (strike, expiry) (SD59x18)
    struct IVSurfacePoint {
        SD59x18 strike;
        SD59x18 expiry;
        SD59x18 iv;
    }

    /// @notice Position summary for transaction history display
    /// @param strike Strike price (SD59x18)
    /// @param isCall True for call, false for put
    /// @param size Position size (SD59x18, positive = long, negative = short)
    /// @param entryPrice Average entry price paid (SD59x18)
    /// @param currentPrice Current mark price (SD59x18)
    /// @param unrealizedPnl Current P&L = (currentPrice - entryPrice) × size (SD59x18)
    /// @param delta Current delta of the position (SD59x18)
    struct PositionSummary {
        SD59x18 strike;
        bool isCall;
        SD59x18 size;
        SD59x18 entryPrice;
        SD59x18 currentPrice;
        SD59x18 unrealizedPnl;
        SD59x18 delta;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                         BLACK-SCHOLES d1 / d2
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Computes Black-Scholes d1 parameter
    /// @dev d1 = [ln(S/K) + (r + σ²/2) × τ] / (σ × √τ)
    /// @param spot Spot price (SD59x18, > 0)
    /// @param strike Strike price (SD59x18, > 0)
    /// @param sigma Implied volatility (SD59x18, > 0)
    /// @param tau Time to expiry in years (SD59x18, > 0)
    /// @param rate Risk-free rate (SD59x18)
    /// @return d1 The d1 parameter (SD59x18)
    function computeD1(SD59x18 spot, SD59x18 strike, SD59x18 sigma, SD59x18 tau, SD59x18 rate)
        internal
        pure
        returns (SD59x18 d1)
    {
        // ln(S/K) = ln(S) - ln(K) avoids intermediate overflow
        SD59x18 logMoneyness = spot.ln().sub(strike.ln());

        // σ² / 2
        SD59x18 halfSigmaSq = sigma.mul(sigma).div(sd(TWO));

        // (r + σ²/2) × τ
        SD59x18 drift = rate.add(halfSigmaSq).mul(tau);

        // σ × √τ
        SD59x18 volSqrtTau = sigma.mul(tau.sqrt());

        // d1 = (logMoneyness + drift) / volSqrtTau
        d1 = logMoneyness.add(drift).div(volSqrtTau);
    }

    /// @notice Computes Black-Scholes d2 parameter
    /// @dev d2 = d1 - σ × √τ
    /// @param d1 The d1 parameter (SD59x18)
    /// @param sigma Implied volatility (SD59x18)
    /// @param tau Time to expiry in years (SD59x18)
    /// @return d2 The d2 parameter (SD59x18)
    function computeD2(SD59x18 d1, SD59x18 sigma, SD59x18 tau) internal pure returns (SD59x18 d2) {
        d2 = d1.sub(sigma.mul(tau.sqrt()));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                              GREEKS CALCULATION
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Computes the full set of Black-Scholes Greeks for a single option
    /// @dev Calculates delta, gamma, theta, vega, and theoretical price in one pass.
    ///      Uses the generalized Black-Scholes model with continuous risk-free rate.
    /// @param input GreeksInput struct with all required parameters
    /// @return greeks Complete Greeks struct
    function computeGreeks(GreeksInput memory input) internal pure returns (Greeks memory greeks) {
        _validateGreeksInput(input);

        SD59x18 d1 = computeD1(input.spot, input.strike, input.sigma, input.tau, input.rate);
        SD59x18 d2 = computeD2(d1, input.sigma, input.tau);

        // Discount factor: e^(-r × τ)
        SD59x18 discount = input.rate.mul(input.tau).mul(sd(-1e18)).exp();

        // PDF at d1 for gamma/theta/vega
        SD59x18 pdfD1 = CumulativeNormal.pdf(d1);

        // √τ for reuse
        SD59x18 sqrtTau = input.tau.sqrt();

        // σ × √τ for reuse
        SD59x18 volSqrtTau = input.sigma.mul(sqrtTau);

        if (input.isCall) {
            SD59x18 nd1 = CumulativeNormal.cdf(d1);
            SD59x18 nd2 = CumulativeNormal.cdf(d2);

            // Call delta = Φ(d1)
            greeks.delta = nd1;

            // Call price = S × Φ(d1) - K × e^(-rτ) × Φ(d2)
            greeks.price = input.spot.mul(nd1).sub(input.strike.mul(discount).mul(nd2));

            // Call theta = -(S × φ(d1) × σ) / (2√τ) - r × K × e^(-rτ) × Φ(d2)
            SD59x18 thetaTerm1 = input.spot.mul(pdfD1).mul(input.sigma).div(sd(TWO).mul(sqrtTau)).mul(sd(-1e18));
            SD59x18 thetaTerm2 = input.rate.mul(input.strike).mul(discount).mul(nd2).mul(sd(-1e18));
            greeks.theta = thetaTerm1.add(thetaTerm2);
        } else {
            SD59x18 nNegD1 = CumulativeNormal.cdf(d1.mul(sd(-1e18)));
            SD59x18 nNegD2 = CumulativeNormal.cdf(d2.mul(sd(-1e18)));

            // Put delta = Φ(d1) - 1 = -Φ(-d1)
            greeks.delta = nNegD1.mul(sd(-1e18));

            // Put price = K × e^(-rτ) × Φ(-d2) - S × Φ(-d1)
            greeks.price = input.strike.mul(discount).mul(nNegD2).sub(input.spot.mul(nNegD1));

            // Put theta = -(S × φ(d1) × σ) / (2√τ) + r × K × e^(-rτ) × Φ(-d2)
            SD59x18 thetaTerm1 = input.spot.mul(pdfD1).mul(input.sigma).div(sd(TWO).mul(sqrtTau)).mul(sd(-1e18));
            SD59x18 thetaTerm2 = input.rate.mul(input.strike).mul(discount).mul(nNegD2);
            greeks.theta = thetaTerm1.add(thetaTerm2);
        }

        // Gamma = φ(d1) / (S × σ × √τ)  — same for calls and puts
        greeks.gamma = pdfD1.div(input.spot.mul(volSqrtTau));

        // Vega = S × φ(d1) × √τ  — same for calls and puts
        greeks.vega = input.spot.mul(pdfD1).mul(sqrtTau);
    }

    /// @notice Computes only the delta for a single option (gas-efficient)
    /// @param input GreeksInput struct with all required parameters
    /// @return delta The option delta (SD59x18)
    function computeDelta(GreeksInput memory input) internal pure returns (SD59x18 delta) {
        _validateGreeksInput(input);
        SD59x18 d1 = computeD1(input.spot, input.strike, input.sigma, input.tau, input.rate);
        if (input.isCall) {
            delta = CumulativeNormal.cdf(d1);
        } else {
            delta = CumulativeNormal.cdf(d1).sub(sd(ONE));
        }
    }

    /// @notice Computes the Black-Scholes theoretical option price
    /// @param input GreeksInput struct with all required parameters
    /// @return price The theoretical option price (SD59x18)
    function computePrice(GreeksInput memory input) internal pure returns (SD59x18 price) {
        Greeks memory g = computeGreeks(input);
        price = g.price;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                        OPTION CHAIN VIEW (strikes × expiries)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Builds a full option chain grid for the frontend (strikes × expiries)
    /// @dev Returns a flat array of ChainCells. Row-major order: for each expiry, all strikes.
    ///      Total cells = len(strikes) × len(expiries). Gas-bounded by MAX_CHAIN_STRIKES × MAX_SURFACE_DIM.
    /// @param spot Current spot price (SD59x18, > 0)
    /// @param strikes Array of strike prices (SD59x18[], each > 0)
    /// @param expiries Array of time-to-expiry in years (SD59x18[], each > 0)
    /// @param sigma Implied volatility (SD59x18)
    /// @param rate Risk-free rate (SD59x18)
    /// @return chain Flat array of ChainCell structs (row-major: expiry-outer, strike-inner)
    function buildOptionChain(
        SD59x18 spot,
        SD59x18[] memory strikes,
        SD59x18[] memory expiries,
        SD59x18 sigma,
        SD59x18 rate
    ) internal pure returns (ChainCell[] memory chain) {
        if (spot.lte(ZERO)) revert FrontendReactdashboard__InvalidSpotPrice();
        if (strikes.length == 0) revert FrontendReactdashboard__EmptyStrikes();
        if (expiries.length == 0) revert FrontendReactdashboard__EmptyExpiries();
        if (strikes.length > MAX_CHAIN_STRIKES) {
            revert FrontendReactdashboard__ArrayTooLarge(strikes.length, MAX_CHAIN_STRIKES);
        }
        if (expiries.length > MAX_SURFACE_DIM) {
            revert FrontendReactdashboard__ArrayTooLarge(expiries.length, MAX_SURFACE_DIM);
        }

        uint256 totalCells = strikes.length * expiries.length;
        chain = new ChainCell[](totalCells);

        uint256 idx = 0;
        for (uint256 e = 0; e < expiries.length; e++) {
            for (uint256 s = 0; s < strikes.length; s++) {
                GreeksInput memory callInput = GreeksInput({
                    spot: spot, strike: strikes[s], sigma: sigma, tau: expiries[e], rate: rate, isCall: true
                });
                GreeksInput memory putInput = GreeksInput({
                    spot: spot, strike: strikes[s], sigma: sigma, tau: expiries[e], rate: rate, isCall: false
                });

                chain[idx] = ChainCell({
                    strike: strikes[s],
                    expiry: expiries[e],
                    callGreeks: computeGreeks(callInput),
                    putGreeks: computeGreeks(putInput)
                });

                idx++;
            }
        }
    }

    /// @notice Generates an evenly-spaced array of strikes around the spot price
    /// @dev Creates strikes from spot × (1 - spread) to spot × (1 + spread) with `count` steps.
    ///      Useful for the frontend to auto-generate strike arrays for the chain view.
    /// @param spot Current spot price (SD59x18, > 0)
    /// @param spread Half-width of the strike range as a fraction (e.g. 0.2e18 = ±20%)
    /// @param count Number of strikes to generate (must be >= 2)
    /// @return strikes Array of evenly-spaced strike prices
    function generateStrikes(SD59x18 spot, SD59x18 spread, uint256 count)
        internal
        pure
        returns (SD59x18[] memory strikes)
    {
        if (spot.lte(ZERO)) revert FrontendReactdashboard__InvalidSpotPrice();
        if (count < 2) revert FrontendReactdashboard__EmptyStrikes();
        if (count > MAX_CHAIN_STRIKES) {
            revert FrontendReactdashboard__ArrayTooLarge(count, MAX_CHAIN_STRIKES);
        }

        strikes = new SD59x18[](count);

        SD59x18 lower = spot.mul(sd(ONE).sub(spread));
        SD59x18 upper = spot.mul(sd(ONE).add(spread));

        // Ensure lower bound is at least a small positive number
        if (lower.lte(ZERO)) {
            lower = sd(1); // Smallest positive SD59x18
        }

        SD59x18 step = upper.sub(lower).div(sd(int256((count - 1) * 1e18)));

        for (uint256 i = 0; i < count; i++) {
            strikes[i] = lower.add(step.mul(sd(int256(i * 1e18))));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                          LP DASHBOARD COMPUTATIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Computes a complete LP dashboard snapshot
    /// @dev All inputs and outputs are in SD59x18 fixed-point. The frontend passes pool state
    ///      and user-specific data; this function returns a fully computed dashboard.
    /// @param totalAssets Total value of pool assets (SD59x18, > 0)
    /// @param lockedCollateral Collateral locked in active options (SD59x18, >= 0)
    /// @param totalSupply Total LP shares outstanding (SD59x18, > 0)
    /// @param userShares User's LP share balance (SD59x18, >= 0)
    /// @param userDepositValue User's total deposited value (cost basis, SD59x18, >= 0)
    /// @return dashboard Complete LPDashboard struct
    function computeLPDashboard(
        SD59x18 totalAssets,
        SD59x18 lockedCollateral,
        SD59x18 totalSupply,
        SD59x18 userShares,
        SD59x18 userDepositValue
    ) internal pure returns (LPDashboard memory dashboard) {
        if (totalAssets.lte(ZERO)) revert FrontendReactdashboard__ZeroTotalAssets();
        if (totalSupply.lte(ZERO)) revert FrontendReactdashboard__ZeroTotalSupply();

        dashboard.totalAssets = totalAssets;
        dashboard.lockedCollateral = lockedCollateral;

        // Utilization = locked / total
        dashboard.utilization = lockedCollateral.div(totalAssets);

        // Share price = totalAssets / totalSupply
        dashboard.sharePrice = totalAssets.div(totalSupply);

        dashboard.userShares = userShares;

        // User equity = shares × sharePrice
        dashboard.userEquity = userShares.mul(dashboard.sharePrice);

        // P&L = equity - cost basis
        dashboard.pnl = dashboard.userEquity.sub(userDepositValue);

        // P&L percent = pnl / depositValue  (handle zero deposit)
        if (userDepositValue.gt(ZERO)) {
            dashboard.pnlPercent = dashboard.pnl.div(userDepositValue);
        } else {
            dashboard.pnlPercent = ZERO;
        }
    }

    /// @notice Computes the number of LP shares to mint for a deposit
    /// @dev shares = depositAmount × totalSupply / totalAssets
    /// @param depositAmount Amount being deposited (SD59x18, > 0)
    /// @param totalAssets Current total pool assets (SD59x18, > 0)
    /// @param totalSupply Current total LP shares (SD59x18, > 0)
    /// @return shares LP shares to mint (SD59x18)
    function computeDepositShares(SD59x18 depositAmount, SD59x18 totalAssets, SD59x18 totalSupply)
        internal
        pure
        returns (SD59x18 shares)
    {
        if (depositAmount.lte(ZERO)) revert FrontendReactdashboard__ZeroDepositAmount();
        if (totalAssets.lte(ZERO)) revert FrontendReactdashboard__ZeroTotalAssets();
        if (totalSupply.lte(ZERO)) revert FrontendReactdashboard__ZeroTotalSupply();

        shares = depositAmount.mul(totalSupply).div(totalAssets);
    }

    /// @notice Computes the asset amount returned for a withdrawal of LP shares
    /// @dev withdrawAmount = sharesToBurn × totalAssets / totalSupply
    /// @param sharesToBurn Number of LP shares to burn (SD59x18, > 0)
    /// @param totalAssets Current total pool assets (SD59x18, > 0)
    /// @param totalSupply Current total LP shares (SD59x18, > 0)
    /// @return withdrawAmount Assets returned to the user (SD59x18)
    function computeWithdrawAmount(SD59x18 sharesToBurn, SD59x18 totalAssets, SD59x18 totalSupply)
        internal
        pure
        returns (SD59x18 withdrawAmount)
    {
        if (sharesToBurn.lte(ZERO)) revert FrontendReactdashboard__ZeroDepositAmount();
        if (totalAssets.lte(ZERO)) revert FrontendReactdashboard__ZeroTotalAssets();
        if (totalSupply.lte(ZERO)) revert FrontendReactdashboard__ZeroTotalSupply();

        withdrawAmount = sharesToBurn.mul(totalAssets).div(totalSupply);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                      IV SURFACE VISUALIZATION (3D)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Builds a 3D IV surface grid for visualization
    /// @dev Returns a flat array of IVSurfacePoints. The frontend renders this as a 3D mesh.
    ///      IV values are supplied externally (e.g. from the VolatilitySurface library or oracle).
    ///      Total points = len(strikes) × len(expiries) = len(ivs).
    /// @param strikes Array of strike prices (SD59x18[])
    /// @param expiries Array of time-to-expiry in years (SD59x18[])
    /// @param ivs Flat array of IV values in row-major order: [strike0_expiry0, strike1_expiry0, ...] (SD59x18[])
    /// @return surface Array of IVSurfacePoint structs for 3D rendering
    function buildIVSurface(SD59x18[] memory strikes, SD59x18[] memory expiries, SD59x18[] memory ivs)
        internal
        pure
        returns (IVSurfacePoint[] memory surface)
    {
        if (strikes.length == 0) revert FrontendReactdashboard__EmptyStrikes();
        if (expiries.length == 0) revert FrontendReactdashboard__EmptyExpiries();

        uint256 totalPoints = strikes.length * expiries.length;
        if (ivs.length != totalPoints) {
            revert FrontendReactdashboard__ArrayLengthMismatch(totalPoints, ivs.length);
        }
        if (strikes.length > MAX_SURFACE_DIM) {
            revert FrontendReactdashboard__ArrayTooLarge(strikes.length, MAX_SURFACE_DIM);
        }
        if (expiries.length > MAX_SURFACE_DIM) {
            revert FrontendReactdashboard__ArrayTooLarge(expiries.length, MAX_SURFACE_DIM);
        }

        surface = new IVSurfacePoint[](totalPoints);

        uint256 idx = 0;
        for (uint256 e = 0; e < expiries.length; e++) {
            for (uint256 s = 0; s < strikes.length; s++) {
                surface[idx] = IVSurfacePoint({ strike: strikes[s], expiry: expiries[e], iv: ivs[idx] });
                idx++;
            }
        }
    }

    /// @notice Computes IV from Black-Scholes price using bisection method (Newton-Raphson lite)
    /// @dev Iterative approach: starts with a bracket [low, high] and narrows until convergence.
    ///      Uses vega to guide the midpoint correction for faster convergence.
    ///      Max 64 iterations ensures termination within gas limits.
    /// @param spot Spot price (SD59x18, > 0)
    /// @param strike Strike price (SD59x18, > 0)
    /// @param tau Time to expiry in years (SD59x18, > 0)
    /// @param rate Risk-free rate (SD59x18)
    /// @param marketPrice Observed market price of the option (SD59x18, > 0)
    /// @param isCall True for call, false for put
    /// @return iv The implied volatility that matches the market price (SD59x18)
    function impliedVolatilityBisection(
        SD59x18 spot,
        SD59x18 strike,
        SD59x18 tau,
        SD59x18 rate,
        SD59x18 marketPrice,
        bool isCall
    ) internal pure returns (SD59x18 iv) {
        if (spot.lte(ZERO)) revert FrontendReactdashboard__InvalidSpotPrice();
        if (strike.lte(ZERO)) revert FrontendReactdashboard__InvalidStrikePrice();
        if (tau.lte(ZERO)) revert FrontendReactdashboard__InvalidTimeToExpiry();

        SD59x18 low = sd(MIN_IV);
        SD59x18 high = sd(MAX_IV);

        for (uint256 i = 0; i < 64; i++) {
            SD59x18 mid = low.add(high).div(sd(TWO));

            GreeksInput memory input =
                GreeksInput({ spot: spot, strike: strike, sigma: mid, tau: tau, rate: rate, isCall: isCall });

            SD59x18 price = computePrice(input);
            SD59x18 diff = price.sub(marketPrice);

            // Convergence check: |diff| < 1e-10 (in SD59x18 = 1e8)
            if (diff.abs().lt(sd(100000000))) {
                return mid;
            }

            if (diff.gt(ZERO)) {
                high = mid;
            } else {
                low = mid;
            }
        }

        // Return best estimate after max iterations
        iv = low.add(high).div(sd(TWO));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                         TRANSACTION HISTORY / POSITION ENRICHMENT
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Enriches a position with current mark price and P&L for the transaction history view
    /// @dev Computes the current theoretical price using Black-Scholes and derives unrealized P&L.
    /// @param strike Strike price (SD59x18, > 0)
    /// @param isCall True for call, false for put
    /// @param size Position size (SD59x18, positive = long, negative = short)
    /// @param entryPrice Average entry price paid per option (SD59x18)
    /// @param spot Current spot price (SD59x18, > 0)
    /// @param sigma Current implied volatility (SD59x18)
    /// @param tau Time to expiry in years (SD59x18, > 0)
    /// @param rate Risk-free rate (SD59x18)
    /// @return summary Fully computed PositionSummary struct
    function enrichPosition(
        SD59x18 strike,
        bool isCall,
        SD59x18 size,
        SD59x18 entryPrice,
        SD59x18 spot,
        SD59x18 sigma,
        SD59x18 tau,
        SD59x18 rate
    ) internal pure returns (PositionSummary memory summary) {
        GreeksInput memory input = GreeksInput({
            spot: spot, strike: strike, sigma: sigma, tau: tau, rate: rate, isCall: isCall
        });

        Greeks memory greeks = computeGreeks(input);

        summary.strike = strike;
        summary.isCall = isCall;
        summary.size = size;
        summary.entryPrice = entryPrice;
        summary.currentPrice = greeks.price;

        // Unrealized P&L = (currentPrice - entryPrice) × size
        summary.unrealizedPnl = greeks.price.sub(entryPrice).mul(size);

        // Position delta = option delta × size
        summary.delta = greeks.delta.mul(size);
    }

    /// @notice Batch-enriches multiple positions for the transaction history table
    /// @dev Processes an array of positions in one call for gas efficiency.
    ///      All positions share the same spot price, sigma, tau, and rate.
    /// @param strikes Strike prices (SD59x18[])
    /// @param isCalls Call/put flags (bool[])
    /// @param sizes Position sizes (SD59x18[])
    /// @param entryPrices Entry prices (SD59x18[])
    /// @param spot Current spot price (SD59x18)
    /// @param sigma Current implied volatility (SD59x18)
    /// @param tau Time to expiry in years (SD59x18)
    /// @param rate Risk-free rate (SD59x18)
    /// @return summaries Array of PositionSummary structs
    function batchEnrichPositions(
        SD59x18[] memory strikes,
        bool[] memory isCalls,
        SD59x18[] memory sizes,
        SD59x18[] memory entryPrices,
        SD59x18 spot,
        SD59x18 sigma,
        SD59x18 tau,
        SD59x18 rate
    ) internal pure returns (PositionSummary[] memory summaries) {
        uint256 len = strikes.length;
        if (isCalls.length != len) revert FrontendReactdashboard__ArrayLengthMismatch(len, isCalls.length);
        if (sizes.length != len) revert FrontendReactdashboard__ArrayLengthMismatch(len, sizes.length);
        if (entryPrices.length != len) revert FrontendReactdashboard__ArrayLengthMismatch(len, entryPrices.length);

        summaries = new PositionSummary[](len);
        for (uint256 i = 0; i < len; i++) {
            summaries[i] = enrichPosition(strikes[i], isCalls[i], sizes[i], entryPrices[i], spot, sigma, tau, rate);
        }
    }

    /// @notice Aggregates portfolio-level Greeks across multiple positions
    /// @dev Sums delta, gamma, theta, and vega across all positions. Useful for risk dashboard.
    /// @param strikes Strike prices (SD59x18[])
    /// @param isCalls Call/put flags (bool[])
    /// @param sizes Position sizes (SD59x18[])
    /// @param spot Current spot price (SD59x18)
    /// @param sigma Current implied volatility (SD59x18)
    /// @param tau Time to expiry in years (SD59x18)
    /// @param rate Risk-free rate (SD59x18)
    /// @return totalDelta Aggregate delta (SD59x18)
    /// @return totalGamma Aggregate gamma (SD59x18)
    /// @return totalTheta Aggregate theta (SD59x18)
    /// @return totalVega Aggregate vega (SD59x18)
    function aggregatePortfolioGreeks(
        SD59x18[] memory strikes,
        bool[] memory isCalls,
        SD59x18[] memory sizes,
        SD59x18 spot,
        SD59x18 sigma,
        SD59x18 tau,
        SD59x18 rate
    ) internal pure returns (SD59x18 totalDelta, SD59x18 totalGamma, SD59x18 totalTheta, SD59x18 totalVega) {
        uint256 len = strikes.length;
        if (isCalls.length != len) revert FrontendReactdashboard__ArrayLengthMismatch(len, isCalls.length);
        if (sizes.length != len) revert FrontendReactdashboard__ArrayLengthMismatch(len, sizes.length);

        totalDelta = ZERO;
        totalGamma = ZERO;
        totalTheta = ZERO;
        totalVega = ZERO;

        for (uint256 i = 0; i < len; i++) {
            GreeksInput memory input =
                GreeksInput({ spot: spot, strike: strikes[i], sigma: sigma, tau: tau, rate: rate, isCall: isCalls[i] });

            Greeks memory greeks = computeGreeks(input);

            totalDelta = totalDelta.add(greeks.delta.mul(sizes[i]));
            totalGamma = totalGamma.add(greeks.gamma.mul(sizes[i]));
            totalTheta = totalTheta.add(greeks.theta.mul(sizes[i]));
            totalVega = totalVega.add(greeks.vega.mul(sizes[i]));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════
    //                                            INTERNAL VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Validates all inputs to the Greeks computation
    /// @param input GreeksInput struct to validate
    function _validateGreeksInput(GreeksInput memory input) private pure {
        if (input.spot.lte(ZERO)) revert FrontendReactdashboard__InvalidSpotPrice();
        if (input.strike.lte(ZERO)) revert FrontendReactdashboard__InvalidStrikePrice();
        if (input.sigma.lte(sd(MIN_IV)) || input.sigma.gt(sd(MAX_IV))) {
            revert FrontendReactdashboard__InvalidVolatility();
        }
        if (input.tau.lt(sd(MIN_TIME_TO_EXPIRY))) {
            revert FrontendReactdashboard__InvalidTimeToExpiry();
        }
        // Rate can be negative (e.g. negative interest rates) but bound it
        if (input.rate.lt(sd(-1e18))) revert FrontendReactdashboard__InvalidRate();
    }
}
