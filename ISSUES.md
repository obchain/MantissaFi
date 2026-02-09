# MantissaFi — GitHub Issues Tracker

> Copy-paste each issue below into GitHub Issues. Issues are ordered by priority (must-do first → nice-to-have last). Labels and milestones are provided for each.

---

## Milestone: `M0 — Project Setup`

---

### Issue #1: Initialize Foundry project with directory structure and dependencies
**Labels:** `setup`, `priority: critical`
**Milestone:** M0 — Project Setup

**Description:**
Set up the Foundry project scaffold with the complete directory structure, install dependencies, and configure `foundry.toml`.

**Tasks:**
- [ ] Initialize with `forge init`
- [ ] Configure `foundry.toml` with optimizer (200 runs), Solidity 0.8.25, via-IR pipeline
- [ ] Install dependencies:
  - `forge install PaulRBerg/prb-math@v4`
  - `forge install OpenZeppelin/openzeppelin-contracts`
  - `forge install smartcontractkit/chainlink`
- [ ] Create directory structure:
  ```
  src/{core,pricing,volatility,oracle,periphery,libraries}/
  test/{unit,fuzz,invariant,integration,fork,differential,gas}/
  script/
  certora/{specs,conf}/
  analysis/
  ```
- [ ] Add `.gitignore`, `LICENSE` (MIT), `SECURITY.md` placeholder
- [ ] Add `remappings.txt` for dependency resolution
- [ ] Verify `forge build` compiles cleanly

**Acceptance Criteria:**
- `forge build` succeeds with zero errors
- All directories exist
- Dependencies resolve correctly

---

### Issue #2: Create CONTRIBUTING.md with development guidelines
**Labels:** `documentation`, `good first issue`
**Milestone:** M0 — Project Setup

**Description:**
Document contribution guidelines including branch naming, commit message conventions (Conventional Commits), PR template, and code style requirements.

**Tasks:**
- [ ] Branch naming: `feat/`, `fix/`, `test/`, `docs/`, `refactor/`
- [ ] Commit format: `type(scope): description` (feat, fix, test, docs, refactor, perf)
- [ ] PR template with checklist (tests, docs, gas report)
- [ ] Code style: Solidity Style Guide, NatSpec required on all public/external functions
- [ ] Testing requirements: unit + fuzz for all new code

---

### Issue #3: Create SECURITY.md with threat model
**Labels:** `security`, `documentation`, `priority: high`
**Milestone:** M0 — Project Setup

**Description:**
Document the complete threat model for the protocol.

**Threat Categories to Cover:**
- Oracle manipulation (stale prices, flash loan + price manipulation)
- Flash loan + exercise attack vectors
- Precision loss leading to systematic mispricing
- Rounding direction exploits (many small trades draining pool)
- IV manipulation (artificially cheap options)
- Donation attack on empty liquidity pool
- Front-running option mints (sandwich attacks)
- Reentrancy on settlement/exercise
- Access control bypass on admin functions

**Include:**
- Severity ratings for each threat
- Mitigation strategies implemented
- Responsible disclosure policy

---

### Issue #4: Configure CI/CD with GitHub Actions
**Labels:** `devops`, `setup`
**Milestone:** M0 — Project Setup

**Description:**
Set up GitHub Actions workflow for automated testing, linting, and gas reporting.

**Workflows:**
- [ ] `ci.yml`: `forge build` + `forge test` on every PR
- [ ] `gas-report.yml`: Generate and comment gas diff on PRs
- [ ] `slither.yml`: Run Slither static analysis on PRs
- [ ] `fmt.yml`: Check `forge fmt` formatting

---

## Milestone: `M1 — Math Engine`

---

### Issue #5: Implement `Constants.sol` with fixed-point mathematical constants
**Labels:** `math`, `core`, `priority: critical`
**Milestone:** M1 — Math Engine

**Description:**
Define all mathematical constants used across the pricing engine as SD59x18 fixed-point values.

**Constants Required:**
```solidity
int256 constant SQRT_2PI = 2_506628274631000502;     // √(2π)
int256 constant INV_SQRT_2PI = 398942280401432678;    // 1/√(2π)  
int256 constant LN2 = 693147180559945309;             // ln(2)
int256 constant E = 2_718281828459045235;              // Euler's number
int256 constant HALF = 500000000000000000;             // 0.5
int256 constant ONE = 1_000000000000000000;            // 1.0
int256 constant NEG_ONE = -1_000000000000000000;       // -1.0
int256 constant YEAR_IN_SECONDS = 31536000;            // 365 days
```

**Acceptance Criteria:**
- All constants verified against Wolfram Alpha to 18 decimal places
- Unit tests comparing each constant to known values
- NatSpec documentation explaining precision and source

---

### Issue #6: Implement `CumulativeNormal.sol` — on-chain Φ(x) computation
**Labels:** `math`, `core`, `priority: critical`
**Milestone:** M1 — Math Engine

**Description:**
Implement the cumulative normal distribution function Φ(x) using Hart's rational approximation. This is the most critical mathematical component — all BSM pricing depends on it.

**Algorithm:**
Use a 5-term polynomial approximation (Abramowitz & Stegun 26.2.17) with Horner's method:
```
Φ(x) = 1 - φ(x) · P(t)    for x ≥ 0
t = 1 / (1 + p·x)
P(t) = a₁t + a₂t² + a₃t³ + a₄t⁴ + a₅t⁵
```

For x < 0: `Φ(x) = 1 - Φ(-x)` (symmetry property)

**Functions:**
```solidity
function cdf(int256 x) internal pure returns (int256);
function pdf(int256 x) internal pure returns (int256);
```

**Requirements:**
- Maximum absolute error < 1 × 10⁻⁵ vs scipy.stats.norm.cdf
- Gas target: < 10,000 for cdf(), < 6,000 for pdf()
- Correctly handles extreme values: x ∈ [-10, 10]
- Boundary conditions: Φ(0) = 0.5 exactly, Φ(-∞) → 0, Φ(+∞) → 1
- Symmetry: Φ(-x) + Φ(x) = 1

**Testing:**
- Unit tests at known values: Φ(0)=0.5, Φ(1)≈0.8413, Φ(-1)≈0.1587, Φ(1.96)≈0.975
- Fuzz test with 10,000 random inputs, compare to Python reference
- Gas benchmark test
- Symmetry property test

---

### Issue #7: Implement `FixedPointMathLib.sol` — BSM-specific math operations
**Labels:** `math`, `core`, `priority: critical`
**Milestone:** M1 — Math Engine

**Description:**
Extend PRBMath with additional mathematical functions needed specifically for Black-Scholes computation.

**Functions:**
```solidity
/// @notice Compute e^(-x) efficiently for discounting
function expNeg(int256 x) internal pure returns (int256);

/// @notice Compute x² / 2 for CDF computation  
function halfSquare(int256 x) internal pure returns (int256);

/// @notice Natural log ratio ln(a/b) without intermediate overflow
function lnRatio(int256 a, int256 b) internal pure returns (int256);

/// @notice Annualize a duration in seconds to years (SD59x18)
function annualize(uint256 seconds_) internal pure returns (int256);
```

**Requirements:**
- All functions operate on SD59x18 fixed-point numbers
- Use `unchecked` blocks where overflow is mathematically impossible
- Inline assembly for hot paths if gas savings > 500

---

### Issue #8: Implement `BSMEngine.sol` — Black-Scholes-Merton pricing
**Labels:** `math`, `core`, `priority: critical`
**Milestone:** M1 — Math Engine

**Description:**
Implement the full BSM pricing engine for European call and put options.

**Functions:**
```solidity
/// @notice Price a European call option
/// @param spot Current price of underlying (SD59x18)
/// @param strike Strike price (SD59x18)
/// @param vol Implied volatility as decimal, e.g., 0.65e18 = 65% (SD59x18)
/// @param rate Risk-free rate as decimal (SD59x18)
/// @param timeToExpiry Time to expiry in years (SD59x18)
/// @return premium Option premium (SD59x18)
function priceCall(int256 spot, int256 strike, int256 vol, int256 rate, int256 timeToExpiry) 
    external pure returns (int256 premium);

function pricePut(int256 spot, int256 strike, int256 vol, int256 rate, int256 timeToExpiry) 
    external pure returns (int256 premium);

/// @notice Compute d1 and d2 intermediate values
function _d1d2(int256 spot, int256 strike, int256 vol, int256 rate, int256 timeToExpiry) 
    internal pure returns (int256 d1, int256 d2);
```

**Requirements:**
- Gas target: < 80,000 for full pricing
- Share d1/d2 computation between call and put
- Handle edge cases: ATM (S=K), deep ITM, deep OTM
- At expiry (T=0): return intrinsic value max(S-K, 0) for calls
- Validate: vol > 0, timeToExpiry ≥ 0, spot > 0, strike > 0

**Testing:**
- Differential fuzz: 10,000 random inputs vs Python scipy BSM
- Max relative error < 0.01%
- Put-call parity: C - P = S - K·e^(-rT) within tolerance
- Known value tests from textbook examples

---

### Issue #9: Implement `Greeks.sol` — on-chain Delta, Gamma, Theta, Vega
**Labels:** `math`, `core`, `priority: high`
**Milestone:** M1 — Math Engine

**Description:**
Compute all four primary Greeks on-chain, sharing intermediate values from BSM pricing for gas efficiency.

**Functions:**
```solidity
function delta(int256 spot, int256 strike, int256 vol, int256 rate, int256 tte, bool isCall) 
    external pure returns (int256);

function gamma(int256 spot, int256 strike, int256 vol, int256 rate, int256 tte) 
    external pure returns (int256);

function theta(int256 spot, int256 strike, int256 vol, int256 rate, int256 tte, bool isCall) 
    external pure returns (int256);

function vega(int256 spot, int256 strike, int256 vol, int256 rate, int256 tte) 
    external pure returns (int256);

/// @notice Compute all Greeks in a single call (gas-optimized)
function allGreeks(int256 spot, int256 strike, int256 vol, int256 rate, int256 tte, bool isCall)
    external pure returns (int256 _delta, int256 _gamma, int256 _theta, int256 _vega);
```

**Formulas:**
```
Delta(Call) = Φ(d₁)           Delta(Put) = Φ(d₁) - 1
Gamma      = φ(d₁) / (S·σ·√T)
Theta(Call) = -[S·φ(d₁)·σ] / [2√T] - r·K·e^(-rT)·Φ(d₂)
Vega       = S·√T·φ(d₁)
```

**Requirements:**
- `allGreeks()` must reuse d1, d2, φ(d1), Φ(d1), Φ(d2) — compute once
- Gas target for allGreeks(): < 100,000
- Delta ∈ [0,1] for calls, [-1,0] for puts
- Gamma ≥ 0 always
- Vega ≥ 0 always

---

### Issue #10: Create differential testing framework (Python reference)
**Labels:** `testing`, `math`, `priority: high`
**Milestone:** M1 — Math Engine

**Description:**
Build a Python reference implementation and test vector generator to validate Solidity math against known-correct implementations.

**Files:**
```
analysis/
├── reference_bsm.py       # scipy-based BSM reference
├── precision_test.py       # Generate test vectors + compare
├── gas_benchmark.py        # Parse forge gas reports + visualize
├── requirements.txt        # scipy, numpy, web3, matplotlib
└── test_vectors/
    ├── cdf_vectors.json    # 10,000 CDF test cases
    ├── bsm_vectors.json    # 10,000 BSM pricing test cases
    └── greeks_vectors.json # 10,000 Greeks test cases
```

**Test Vector Format:**
```json
{
  "inputs": { "spot": "3000e18", "strike": "3100e18", "vol": "0.65e18", "rate": "0.05e18", "tte": "0.0833e18" },
  "expected": { "callPrice": "...", "putPrice": "...", "delta": "...", "gamma": "...", "theta": "...", "vega": "..." }
}
```

---

### Issue #11: Gas benchmarking suite for math library
**Labels:** `testing`, `performance`, `priority: high`
**Milestone:** M1 — Math Engine

**Description:**
Create a comprehensive gas benchmarking contract and reporting framework.

**Benchmark Functions:**
- `cdf()` at various x values (edge, typical, extreme)
- `pdf()` at various x values
- `priceCall()` at ATM, ITM, OTM
- `pricePut()` at ATM, ITM, OTM
- `allGreeks()` at various moneyness levels
- Compare PRBMath vs ABDKMath for core operations

**Output:**
- Markdown table in CI comment
- Gas comparison chart (optional: matplotlib in analysis/)

---

## Milestone: `M2 — Protocol Core`

---

### Issue #12: Implement `OptionToken.sol` — ERC-1155 option position tokens
**Labels:** `core`, `priority: critical`
**Milestone:** M2 — Protocol Core

**Description:**
Implement an ERC-1155 token contract representing option positions. Each token ID encodes the option series (underlying, strike, expiry, isCall).

**Design:**
```solidity
/// @notice Encode option series into a unique token ID
/// Token ID = keccak256(underlying, strike, expiry, isCall) >> 32
function getTokenId(address underlying, int256 strike, uint64 expiry, bool isCall) 
    public pure returns (uint256);

/// @notice Decode token ID back to option series
function getOptionSeries(uint256 tokenId) 
    public view returns (OptionSeries memory);
```

**Requirements:**
- Extend OpenZeppelin ERC1155
- Only OptionVault can mint/burn (access controlled)
- Token IDs deterministically derived from option parameters
- URI metadata for option description
- Supports batch operations (mintBatch, burnBatch)

---

### Issue #13: Implement `OptionVault.sol` — main entry point for option lifecycle
**Labels:** `core`, `priority: critical`
**Milestone:** M2 — Protocol Core

**Description:**
The central contract managing the complete option lifecycle: create series, mint, exercise, and settle.

**Functions:**
```solidity
function createSeries(OptionSeries calldata series) external returns (uint256 seriesId);
function mint(uint256 seriesId, uint256 amount) external returns (uint256 premium);
function exercise(uint256 seriesId, uint256 amount) external returns (uint256 payout);
function settle(uint256 seriesId) external;  // After expiry — batch settlement
```

**State Machine:**
```
CREATED → ACTIVE → EXPIRED → SETTLED
                 ↘ EXERCISED (if ITM at expiry)
```

**Requirements:**
- Collateral locked on mint (100% collateralization)
- Premium calculated via BSMEngine at mint time
- Exercise only at expiry (European style)
- Settlement resolves all positions after expiry
- Emergency pause functionality
- ReentrancyGuard on all state-changing functions

---

### Issue #14: Implement `LiquidityPool.sol` — LP deposits and collateral management
**Labels:** `core`, `priority: critical`
**Milestone:** M2 — Protocol Core

**Description:**
ERC-4626-style vault for liquidity providers who earn premiums by underwriting options.

**Functions:**
```solidity
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
function withdraw(uint256 shares, address receiver, address owner) external returns (uint256 assets);
function availableLiquidity() external view returns (uint256);
function utilizationRate() external view returns (int256);  // SD59x18
function netDelta() external view returns (int256);          // Pool's aggregate delta
function netGamma() external view returns (int256);          // Pool's aggregate gamma
```

**Requirements:**
- ERC-4626 compliant vault
- Withdrawal restrictions when utilization > 90% (cooldown period)
- Track aggregate Greeks (delta, gamma) of all outstanding options
- Virtual share offset to prevent donation attacks on empty pool
- Minimum initial deposit requirement
- Fee on early withdrawal during lock period

---

### Issue #15: Implement `Settlement.sol` — expiry resolution engine
**Labels:** `core`, `priority: high`
**Milestone:** M2 — Protocol Core

**Description:**
Handle option expiry, determine ITM/OTM status, calculate payoffs, and distribute funds.

**Functions:**
```solidity
function settleExpiredSeries(uint256 seriesId) external;
function claimPayout(uint256 seriesId) external returns (uint256 payout);
function getPayoff(uint256 seriesId) external view returns (int256);
```

**Logic:**
- Call payoff: max(S_expiry - K, 0)
- Put payoff: max(K - S_expiry, 0)
- Oracle price at expiry determines settlement
- Batch settlement for gas efficiency
- Grace period after expiry for claiming (e.g., 7 days)
- Unclaimed funds return to LP pool

---

### Issue #16: Implement `OracleAdapter.sol` — multi-oracle price aggregation
**Labels:** `oracle`, `core`, `priority: high`
**Milestone:** M2 — Protocol Core

**Description:**
Aggregate price feeds from multiple oracles with validation, staleness checks, and deviation detection.

**Design:**
```solidity
function getSpotPrice(address asset) external view returns (int256 price, uint64 updatedAt);
function getSettlementPrice(address asset, uint64 timestamp) external view returns (int256);
```

**Oracle Sources:**
1. **Primary**: Chainlink (latestRoundData)
2. **Secondary**: Pyth Network
3. **Fallback**: TWAP from DEX (Uniswap V3 / PancakeSwap)

**Validation:**
- Staleness check: revert if price older than maxStalePeriod
- Deviation check: if primary vs secondary > threshold, use TWAP as tiebreaker
- Zero/negative price handling
- L2 sequencer uptime check (Arbitrum/Optimism)

---

### Issue #17: Implement `OptionMath.sol` — payoff and moneyness helpers
**Labels:** `math`, `libraries`, `priority: medium`
**Milestone:** M2 — Protocol Core

**Description:**
Utility library for option-specific calculations.

**Functions:**
```solidity
function callPayoff(int256 spot, int256 strike) pure returns (int256);     // max(S-K, 0)
function putPayoff(int256 spot, int256 strike) pure returns (int256);      // max(K-S, 0)
function moneyness(int256 spot, int256 strike) pure returns (int256);      // S/K
function logMoneyness(int256 spot, int256 strike) pure returns (int256);   // ln(S/K)
function isITM(int256 spot, int256 strike, bool isCall) pure returns (bool);
function intrinsicValue(int256 spot, int256 strike, bool isCall) pure returns (int256);
function timeValue(int256 premium, int256 intrinsic) pure returns (int256);
```

---

### Issue #18: Implement `TimeLib.sol` — time conversion utilities
**Labels:** `libraries`, `priority: medium`
**Milestone:** M2 — Protocol Core

**Description:**
Convert between block timestamps and annualized time values used in BSM.

```solidity
function toYears(uint64 expiry) view returns (int256);           // (expiry - now) / 365.25 days
function toYearsFromDuration(uint256 seconds_) pure returns (int256);
function isExpired(uint64 expiry) view returns (bool);
function timeToExpiry(uint64 expiry) view returns (uint256);     // seconds remaining
```

---

### Issue #19: Integration test — full option lifecycle (mint → trade → exercise)
**Labels:** `testing`, `integration`, `priority: high`
**Milestone:** M2 — Protocol Core

**Description:**
End-to-end test covering the complete happy path:
1. LP deposits USDC into LiquidityPool
2. User mints a call option (pays premium)
3. Price moves up (mock oracle update)
4. Option expires ITM
5. User exercises and receives payoff
6. LP withdraws remaining funds

**Also test:**
- OTM expiry (zero payoff, collateral returned)
- Multiple simultaneous option series
- Batch mint and batch exercise

---

## Milestone: `M3 — Volatility Surface`

---

### Issue #20: Implement `RealizedVolOracle.sol` — EWMA realized volatility
**Labels:** `volatility`, `oracle`, `priority: high`
**Milestone:** M3 — Volatility Surface

**Description:**
Compute on-chain realized volatility using Exponentially Weighted Moving Average (EWMA) of log returns from oracle price updates.

**Formula:**
```
σ²_n = λ · σ²_{n-1} + (1 - λ) · r²_n
r_n = ln(P_n / P_{n-1})    // log return
λ = 0.94 (daily decay, adjusted for block time)
```

**Functions:**
```solidity
function updateVolatility(address asset) external;
function getRealizedVol(address asset) external view returns (int256 vol);
function getRealizedVol(address asset, uint256 window) external view returns (int256 vol);
```

**Requirements:**
- Stores rolling price observations
- Configurable decay factor (λ) per asset
- Minimum observations required before returning valid vol
- Annualization adjustment for different block times

---

### Issue #21: Implement `SkewModel.sol` — strike-dependent IV adjustment
**Labels:** `volatility`, `math`, `priority: high`
**Milestone:** M3 — Volatility Surface

**Description:**
Model the volatility skew (smile) that adjusts IV based on the option's moneyness.

**Formula:**
```
skew(K, S) = α · (K/S - 1)² + β · (K/S - 1)
```
Where α controls curvature (smile) and β controls slope (skew direction).

**Requirements:**
- Quadratic model fitting crypto's typical put skew
- Governance-adjustable parameters (α, β)
- Bounded output to prevent extreme IV values
- Per-asset configurable parameters

---

### Issue #22: Implement `VolatilitySurface.sol` — Liquidity-Sensitive IV Surface
**Labels:** `volatility`, `core`, `priority: high`
**Milestone:** M3 — Volatility Surface

**Description:**
Combine realized volatility, skew, and utilization premium into a complete IV surface.

**Formula:**
```
σ_implied(K, T) = σ_realized(T) · [1 + skew(K, S) + utilization_premium(u)]
utilization_premium(u) = γ · u / (1 - u)
u = lockedCollateral / totalAssets
```

**Functions:**
```solidity
function getImpliedVolatility(address asset, int256 strike, uint64 expiry) 
    external view returns (int256 iv);
```

**Requirements:**
- IV floor and ceiling bounds (governance-set)
- Smooth interpolation between strikes
- Utilization premium makes options more expensive as pool fills up
- Integration tests comparing output to historical Deribit IV

---

### Issue #23: Back-test LSIVS against historical Deribit IV data
**Labels:** `research`, `testing`, `priority: medium`
**Milestone:** M3 — Volatility Surface

**Description:**
Validate the LSIVS model by comparing its output to 6 months of historical Deribit implied volatility data for ETH and BTC options.

**Tasks:**
- [ ] Fetch historical Deribit IV data (API or dataset)
- [ ] Run LSIVS model with same inputs (spot, strike, time, realized vol)
- [ ] Compute RMSE, MAE, and max deviation
- [ ] Generate comparison plots
- [ ] Document calibration parameters that minimize error

**Deliverable:** Python notebook in `analysis/iv_calibration.py`

---

## Milestone: `M4 — Security & Verification`

---

### Issue #24: Slither static analysis — fix all High/Medium findings
**Labels:** `security`, `priority: critical`
**Milestone:** M4 — Security

**Description:**
Run Slither on the complete codebase and resolve all High and Medium severity findings.

```bash
slither src/ --config-file slither.config.json
```

**Acceptance Criteria:**
- Zero Critical/High findings
- All Medium findings addressed or documented as accepted risk
- Slither config added to CI pipeline

---

### Issue #25: Certora spec — CDF bounds and symmetry invariant
**Labels:** `security`, `formal-verification`, `priority: high`
**Milestone:** M4 — Security

**Description:**
Write a Certora specification proving CDF properties:

```
invariant cdf_bounds:
    ∀ x: 0 ≤ cdf(x) ≤ 1e18

invariant cdf_symmetry:
    ∀ x: |cdf(x) + cdf(-x) - 1e18| < ε

invariant cdf_monotonic:
    ∀ x, y: x > y → cdf(x) ≥ cdf(y)
```

---

### Issue #26: Certora spec — solvency invariant
**Labels:** `security`, `formal-verification`, `priority: high`
**Milestone:** M4 — Security

**Description:**
Prove that the liquidity pool always holds enough assets to cover maximum possible payoffs.

```
invariant solvency:
    pool.totalAssets() >= sum(maxPayoff(option_i)) for all active options
```

---

### Issue #27: Certora spec — put-call parity invariant
**Labels:** `security`, `formal-verification`, `priority: high`
**Milestone:** M4 — Security

**Description:**
Prove that BSM pricing satisfies put-call parity within a bounded error.

```
invariant put_call_parity:
    ∀ S, K, σ, r, T:
        |priceCall(S,K,σ,r,T) - pricePut(S,K,σ,r,T) - S + K·exp(-r·T)| < ε_max
```

---

### Issue #28: Certora spec — pricing monotonicity invariant
**Labels:** `security`, `formal-verification`, `priority: medium`
**Milestone:** M4 — Security

**Description:**
Prove that option prices move correctly with inputs:
```
∂C/∂S > 0    (call price increases with spot)
∂P/∂S < 0    (put price decreases with spot)
∂C/∂σ > 0    (vega is positive)
```

---

### Issue #29: Certora spec — no value extraction invariant
**Labels:** `security`, `formal-verification`, `priority: medium`
**Milestone:** M4 — Security

**Description:**
Prove that users cannot extract more value than they're entitled to:
```
∀ mint → exercise sequence:
    payout(user) ≤ intrinsicValue(option) 
    AND: premiumPaid(user) > 0
```

---

### Issue #30: Invariant fuzz testing with Foundry
**Labels:** `testing`, `security`, `priority: high`
**Milestone:** M4 — Security

**Description:**
Create Foundry invariant tests that hold across arbitrary sequences of protocol actions.

**Invariants:**
```solidity
function invariant_solvency() public {
    assert(pool.totalAssets() >= pool.lockedCollateral());
}

function invariant_totalSupply() public {
    // Total option tokens minted == total recorded in vault
}

function invariant_cdf_bounds() public {
    int256 x = bound(randomInt(), -10e18, 10e18);
    int256 result = cumulativeNormal.cdf(x);
    assert(result >= 0 && result <= 1e18);
}
```

---

### Issue #31: Manual security review checklist
**Labels:** `security`, `priority: medium`
**Milestone:** M4 — Security

**Description:**
Perform a manual code review using a structured checklist.

**Checklist:**
- [ ] All external calls follow CEI pattern
- [ ] ReentrancyGuard on all state-changing external functions
- [ ] No unbounded loops
- [ ] All division operations check for division by zero
- [ ] Rounding always favors the protocol
- [ ] Access control on all admin functions
- [ ] No storage collisions in upgradeable contracts (if applicable)
- [ ] Events emitted for all state changes
- [ ] Input validation on all public functions
- [ ] Safe ERC-20 transfers (SafeERC20)

---

## Milestone: `M5 — Periphery & UX`

---

### Issue #32: Implement `OptionRouter.sol` — user-facing multicall helper
**Labels:** `periphery`, `priority: medium`
**Milestone:** M5 — Periphery

**Description:**
Helper contract that batches common user operations.

**Functions:**
```solidity
function mintWithPermit(uint256 seriesId, uint256 amount, Permit calldata permit) external;
function mintAndDeposit(uint256 seriesId, uint256 amount) external;
function exerciseAndWithdraw(uint256 seriesId, uint256 amount) external;
```

---

### Issue #33: Implement `OptionLens.sol` — read-only view functions for frontends
**Labels:** `periphery`, `priority: medium`
**Milestone:** M5 — Periphery

**Description:**
Gas-free view contract aggregating data for frontend consumption.

**Functions:**
```solidity
function getOptionChain(address underlying, uint64 expiry) 
    external view returns (OptionData[] memory);
function getAccountPositions(address account) 
    external view returns (Position[] memory);
function getPoolStats() external view returns (PoolStats memory);
function quoteOption(uint256 seriesId, uint256 amount) 
    external view returns (Quote memory);
```

---

### Issue #34: Implement `FeeController.sol` — dynamic fee model
**Labels:** `periphery`, `priority: medium`
**Milestone:** M5 — Periphery

**Description:**
Dynamic fee that increases with pool utilization to protect LPs.

```solidity
function calculateFee(uint256 seriesId, uint256 amount) view returns (uint256 fee);
// Fee = baseFee + (spreadFee * utilization²)
```

---

### Issue #35: Implement deployment scripts (`script/Deploy.s.sol`)
**Labels:** `devops`, `priority: medium`
**Milestone:** M5 — Periphery

**Description:**
Foundry deployment script with proper sequencing, verification, and multi-chain support.

**Tasks:**
- [ ] Deploy math libraries
- [ ] Deploy core contracts (OptionToken → OptionVault → LiquidityPool)
- [ ] Deploy oracle adapters
- [ ] Deploy volatility surface
- [ ] Configure permissions and parameters
- [ ] Verify all contracts on block explorer
- [ ] Support Arbitrum Sepolia, BSC Testnet, Ethereum Sepolia

---

## Milestone: `M6 — Documentation & Paper`

---

### Issue #36: NatSpec documentation for all public/external functions
**Labels:** `documentation`, `priority: high`
**Milestone:** M6 — Documentation

**Description:**
Ensure every public and external function has complete NatSpec:
- `@notice` — what the function does
- `@dev` — implementation details
- `@param` — every parameter
- `@return` — every return value
- `@custom:security` — security considerations (where relevant)

Generate documentation: `forge doc`

---

### Issue #37: Write error bounds analysis document
**Labels:** `documentation`, `research`, `priority: medium`
**Milestone:** M6 — Documentation

**Description:**
Formal analysis of computational error introduced by fixed-point arithmetic.

**Content:**
- CDF approximation error analysis (theoretical bounds)
- Error propagation through BSM formula
- Worst-case error combinations (which inputs maximize error)
- Comparison table: MantissaFi error vs Lyra/Primitive
- Gas vs accuracy tradeoff curves

---

### Issue #38: Write academic paper (LaTeX)
**Labels:** `documentation`, `research`, `priority: medium`
**Milestone:** M6 — Documentation

**Description:**
Academic paper targeting IEEE ICBC or Financial Cryptography conference.

**Sections:**
1. Introduction — Gap in fully on-chain option pricing
2. Related Work — Lyra, Dopex, Panoptic, Primitive RMM
3. Mathematical Framework — BSM in fixed-point, CDF analysis
4. Volatility Surface — EWMA, skew, utilization premium
5. System Design — Contract architecture, gas optimization
6. Formal Verification — Invariants and proofs
7. Evaluation — Gas benchmarks, precision, back-testing
8. Discussion & Future Work — Heston model, jump-diffusion
9. Conclusion

---

### Issue #39: Create protocol diagram and documentation assets
**Labels:** `documentation`, `priority: low`
**Milestone:** M6 — Documentation

**Description:**
Create visual assets for README and paper:
- [ ] Architecture diagram (draw.io / Excalidraw)
- [ ] State machine diagram for option lifecycle
- [ ] Gas comparison chart vs other protocols
- [ ] Precision error distribution plot
- [ ] IV surface 3D visualization

---

## Milestone: `Backlog` (Future Work)

---

### Issue #40: Explore Heston stochastic volatility model extension
**Labels:** `research`, `enhancement`, `priority: low`
**Milestone:** Backlog

**Description:**
Research feasibility of implementing Heston model on-chain as an extension to BSM for more accurate crypto pricing. BSM assumes constant volatility; Heston models volatility as a stochastic process.

---

### Issue #41: Add American-style option support
**Labels:** `enhancement`, `priority: low`
**Milestone:** Backlog

**Description:**
Research binomial tree or Least Squares Monte Carlo approaches for on-chain American option pricing.

---

### Issue #42: Multi-chain deployment with cross-chain settlement
**Labels:** `enhancement`, `priority: low`
**Milestone:** Backlog

**Description:**
Deploy on multiple EVM chains with cross-chain message passing for unified liquidity.

---

### Issue #43: Frontend React dashboard
**Labels:** `frontend`, `enhancement`, `priority: low`
**Milestone:** Backlog

**Description:**
Build a React + wagmi + viem frontend with:
- Option chain view (strikes × expiries)
- Greeks display (live delta, gamma, theta, vega)
- LP dashboard (deposit, withdraw, P&L)
- IV surface visualization (3D chart)
- Transaction history

---

### Issue #44: Structured products (covered calls, protective puts)
**Labels:** `enhancement`, `priority: low`
**Milestone:** Backlog

**Description:**
Implement automated vault strategies:
- Covered call vault: deposit ETH → auto-sell OTM calls weekly
- Protective put vault: deposit ETH → auto-buy OTM puts
- Iron condor vault: sell both OTM call + put spreads