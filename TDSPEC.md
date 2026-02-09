# MantissaFi: A Fully On-Chain European Options Protocol with Black-Scholes Pricing Engine

## TDS Project Specification

**Author:** 0xfandom
**Domain:** DeFi Derivatives · Solidity Smart Contracts · Financial Engineering
**Target Chain:** EVM (Ethereum / Arbitrum / BSC)
**Estimated Duration:** 12–16 weeks

---

## 1. Abstract

MantissaFi is a fully on-chain European options protocol that implements Black-Scholes-Merton (BSM) pricing entirely in Solidity using fixed-point arithmetic. Unlike existing protocols (Lyra/Derive, Dopex/Stryke, Panoptic) that rely on off-chain pricing engines or simplified approximations, MantissaFi computes option premiums, Greeks (Delta, Gamma, Theta, Vega), and the cumulative normal distribution function (Φ) entirely on-chain with provable accuracy bounds.

The protocol introduces three novel contributions:

1. **A gas-optimized BSM engine** using PRBMath SD59x18 with a Rational Chebyshev approximation for Φ(x) achieving <0.0001% error at ~45,000 gas
2. **A Liquidity-Sensitive Implied Volatility Surface (LSIVS)** that adjusts IV dynamically based on pool utilization, skew, and on-chain realized volatility — removing the need for off-chain IV oracles
3. **A formal verification framework** using Certora/Halmos proving key protocol invariants: solvency, monotonicity of pricing, and correct exercise/settlement

This project serves as both a production-grade DeFi protocol and an academic contribution to on-chain financial engineering.

---

## 2. Motivation & Research Gap

### 2.1 The Problem

On-chain options remain a fraction of DeFi derivatives volume (~$342B monthly) because:

- **Pricing complexity**: Black-Scholes requires exp(), ln(), sqrt(), and the cumulative normal distribution — functions not natively available in the EVM
- **IV bootstrapping**: Most protocols depend on off-chain implied volatility feeds (Deribit, centralized exchanges) creating centralization risk
- **Gas costs**: Naïve implementations of BSM on-chain cost 200K+ gas per price computation, making them impractical for AMM use
- **LP risk**: Options AMMs historically expose LPs to adverse selection; Lyra V1's AMM lost money for LPs during high volatility

### 2.2 Why This Matters

The BSM model, despite its known limitations for crypto (fat tails, volatility clustering, 24/7 markets), remains the foundational pricing framework that all existing DeFi options protocols build upon. Siren, Lyra, Dopex, Premia, Pods, Rysk, and Auctus all use BSM either directly or with modifications. Building an efficient, fully verified on-chain BSM engine is foundational infrastructure.

### 2.3 Novel Contributions

| Contribution | Existing Approaches | MantissaFi |
|---|---|---|
| CDF computation | Off-chain or low-precision polynomial | Rational Chebyshev approximation, <0.0001% error, ~45K gas |
| IV source | Off-chain oracle (Deribit) | On-chain LSIVS from realized vol + utilization |
| Greeks | Not computed on-chain | Full on-chain Delta, Gamma, Theta, Vega |
| Formal verification | Unit tests only | Certora/Halmos invariant proofs |
| Gas efficiency | 200K+ per pricing | Target <80K per full BSM computation |

---

## 3. Technical Architecture

### 3.1 System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    MantissaFi Protocol                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │  OptionVault  │  │  BSMEngine   │  │  VolatilitySurface    │ │
│  │              │  │              │  │                       │ │
│  │ • mint()     │──│ • price()    │──│ • getIV()             │ │
│  │ • exercise() │  │ • delta()    │  │ • updateRealizedVol() │ │
│  │ • settle()   │  │ • gamma()    │  │ • skewAdjust()        │ │
│  │ • liquidate()│  │ • theta()    │  │ • utilizationAdjust() │ │
│  └──────┬───────┘  │ • vega()     │  └───────────┬───────────┘ │
│         │          │ • cdf()      │              │             │
│         │          └──────────────┘              │             │
│  ┌──────▼───────┐  ┌──────────────┐  ┌──────────▼────────────┐ │
│  │ LiquidityPool│  │  FixedPoint  │  │  OracleAdapter        │ │
│  │              │  │  MathLib     │  │                       │ │
│  │ • deposit()  │  │              │  │ • Chainlink            │ │
│  │ • withdraw() │  │ • exp()      │  │ • Pyth                │ │
│  │ • allocate() │  │ • ln()       │  │ • TWAP                │ │
│  │ • hedgeDelta│  │ • sqrt()     │  │ • RealizedVol calc    │ │
│  └──────────────┘  │ • cdf()      │  └───────────────────────┘ │
│                    │ • pdf()      │                             │
│                    └──────────────┘                             │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │ OptionToken  │  │  Settlement  │  │  AccessControl        │ │
│  │  (ERC-1155)  │  │   Engine     │  │  & Governance         │ │
│  └──────────────┘  └──────────────┘  └───────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Contract Architecture

```
contracts/
├── core/
│   ├── OptionVault.sol          # Main entry point — mint, exercise, settle
│   ├── LiquidityPool.sol        # LP deposits, withdrawals, delta hedging
│   ├── OptionToken.sol          # ERC-1155 multi-token (calls & puts, multiple strikes/expiries)
│   └── Settlement.sol           # Expiry settlement, ITM/OTM resolution
├── pricing/
│   ├── BSMEngine.sol            # Black-Scholes-Merton pricing engine
│   ├── FixedPointMathLib.sol    # Custom math: exp, ln, sqrt, cdf, pdf
│   ├── CumulativeNormal.sol     # High-precision Φ(x) approximation
│   └── Greeks.sol               # Delta, Gamma, Theta, Vega computation
├── volatility/
│   ├── VolatilitySurface.sol    # LSIVS — implied volatility surface
│   ├── RealizedVolOracle.sol    # EWMA realized volatility from price feeds
│   └── SkewModel.sol            # Strike-dependent IV adjustment
├── oracle/
│   ├── OracleAdapter.sol        # Multi-oracle: Chainlink + Pyth + TWAP
│   └── PriceValidator.sol       # Staleness, deviation checks
├── periphery/
│   ├── OptionRouter.sol         # User-facing multicall helper
│   ├── OptionLens.sol           # View functions for frontends
│   └── FeeController.sol        # Dynamic fee model
└── libraries/
    ├── OptionMath.sol           # Payoff calculations, moneyness
    ├── TimeLib.sol              # Block.timestamp → annualized time
    └── Constants.sol            # Fixed-point constants (√2π, e, etc.)
```

### 3.3 Core Data Structures

```solidity
// Option series definition
struct OptionSeries {
    address underlying;      // e.g., WETH
    address collateral;      // e.g., USDC
    uint64 expiry;          // Unix timestamp
    int256 strikePrice;     // SD59x18 — e.g., 3000e18
    bool isCall;            // true = call, false = put
}

// Market state per series
struct MarketState {
    int256 impliedVolatility;   // SD59x18 — e.g., 0.65e18 = 65%
    int256 totalLong;           // Total long open interest (SD59x18)
    int256 totalShort;          // Total short open interest
    int256 poolDelta;           // Net delta exposure of LP pool
    uint64 lastTradeTimestamp;
}

// LP pool state
struct PoolState {
    uint256 totalAssets;        // Total USDC in pool
    uint256 lockedCollateral;   // Collateral backing sold options
    uint256 availableLiquidity; // totalAssets - lockedCollateral
    int256 netDelta;            // Aggregate delta of all positions
    int256 netGamma;            // Aggregate gamma
}
```

---

## 4. Mathematical Foundation

### 4.1 Black-Scholes-Merton Formula

For a European call option:

```
C = S · Φ(d₁) - K · e^(-rT) · Φ(d₂)

where:
    d₁ = [ln(S/K) + (r + σ²/2) · T] / (σ · √T)
    d₂ = d₁ - σ · √T

    S = spot price of underlying
    K = strike price
    r = risk-free rate (can be set to DeFi lending rate)
    σ = implied volatility
    T = time to expiry (annualized)
    Φ = cumulative normal distribution function
```

For a European put: `P = K · e^(-rT) · Φ(-d₂) - S · Φ(-d₁)`

### 4.2 On-Chain CDF: Rational Chebyshev Approximation

The critical challenge is computing Φ(x) on-chain. We use a **rational function approximation** (Abramowitz & Stegun, formula 26.2.17) modified for fixed-point:

```
Φ(x) = 1 - φ(x) · (a₁t + a₂t² + a₃t³)      for x ≥ 0

where:
    t = 1 / (1 + 0.33267 · x)
    φ(x) = (1/√2π) · e^(-x²/2)

    a₁ = 0.4361836
    a₂ = -0.1201676
    a₃ = 0.9372980

For x < 0: Φ(x) = 1 - Φ(-x)     (symmetry)
```

**Maximum absolute error**: |ε| < 1 × 10⁻⁵ (sufficient for option pricing)

For higher precision, use the **7-term Hart approximation** (error < 7.5 × 10⁻⁸):

```solidity
/// @notice Computes Φ(x) using Hart's rational approximation
/// @param x Input in SD59x18 format
/// @return result Φ(x) in SD59x18 format (0 to 1e18)
function cdf(int256 x) internal pure returns (int256 result) {
    // Constants stored as SD59x18
    int256 SQRT2 = 1_414213562373095048;  // √2
    
    // Use erfc-based computation for numerical stability
    // Φ(x) = 0.5 · erfc(-x/√2)
    // erfc approximated via rational polynomial
    
    int256 absX = x < 0 ? -x : x;
    int256 t = sd(1e18).div(sd(1e18).add(sd(0_2316419e11).mul(sd(absX))));
    
    // Horner's method for polynomial evaluation (gas-optimal)
    int256 poly = t.mul(
        A1.add(t.mul(
            A2.add(t.mul(
                A3.add(t.mul(
                    A4.add(t.mul(A5))
                ))
            ))
        ))
    );
    
    int256 pdf_val = pdf(absX);
    int256 cdf_positive = sd(1e18).sub(pdf_val.mul(poly));
    
    result = x >= 0 ? cdf_positive : sd(1e18).sub(cdf_positive);
}
```

### 4.3 Greeks Computation

All Greeks are computed from the same intermediate values (d₁, d₂, φ(d₁)):

```
Delta (Call)  = Φ(d₁)
Delta (Put)   = Φ(d₁) - 1

Gamma         = φ(d₁) / (S · σ · √T)

Theta (Call)  = -[S · φ(d₁) · σ] / [2√T] - r · K · e^(-rT) · Φ(d₂)
Theta (Put)   = -[S · φ(d₁) · σ] / [2√T] + r · K · e^(-rT) · Φ(-d₂)

Vega          = S · √T · φ(d₁)
```

### 4.4 Liquidity-Sensitive Implied Volatility Surface (LSIVS)

Instead of relying on off-chain IV oracles, we construct IV from three on-chain components:

```
σ_implied(K, T) = σ_realized(T) · [1 + skew(K, S) + utilization_premium(u)]

where:
    σ_realized(T) = EWMA realized volatility over matching window
    skew(K, S)    = α · (K/S - 1)² + β · (K/S - 1)    // quadratic skew
    utilization_premium(u) = γ · u / (1 - u)             // convex in utilization

    u = lockedCollateral / totalAssets                    // pool utilization
    α, β, γ = governance-tunable parameters
```

**EWMA Realized Volatility** (computed per-block from oracle updates):

```
σ²_n = λ · σ²_{n-1} + (1 - λ) · r²_n

where:
    r_n = ln(P_n / P_{n-1})        // log return
    λ = decay factor (0.94 daily, adjusted for block time)
```

---

## 5. Gas Optimization Strategy

### 5.1 Targets

| Operation | Target Gas | Approach |
|---|---|---|
| Φ(x) — CDF | 8,000 | Rational approximation + Horner's method |
| φ(x) — PDF | 5,000 | exp(-x²/2) via PRBMath |
| Full BSM price | 45,000 | Shared d₁/d₂ computation |
| All 4 Greeks | 60,000 | Reuse PDF/CDF from pricing |
| Mint option | 120,000 | Price + collateral lock + ERC-1155 mint |
| Exercise | 80,000 | Payoff calc + settlement + transfer |

### 5.2 Optimization Techniques

1. **Horner's method** for polynomial evaluation (minimizes multiplications)
2. **Shared intermediate values**: d₁, d₂, φ(d₁), Φ(d₁), Φ(d₂) computed once, passed to Greeks
3. **Unchecked blocks** where overflow is mathematically impossible
4. **Calldata over memory** for read-only struct parameters
5. **Immutable constants**: √(2π), e, risk-free rate stored as immutables
6. **Assembly-level exp()**: Custom exp() using 2^x decomposition for inner loops
7. **Batch pricing**: Price multiple series in single call with shared oracle read

### 5.3 Gas Benchmarking Framework

```solidity
contract GasBenchmark {
    BSMEngine engine;
    
    function benchmarkCDF() external view returns (uint256 gasUsed) {
        uint256 start = gasleft();
        engine.cdf(sd(1.5e18));  // Φ(1.5) ≈ 0.9332
        gasUsed = start - gasleft();
    }
    
    function benchmarkFullPrice() external view returns (uint256 gasUsed) {
        uint256 start = gasleft();
        engine.priceCall(
            sd(3000e18),   // S = $3000
            sd(3100e18),   // K = $3100
            sd(0.65e18),   // σ = 65%
            sd(0.05e18),   // r = 5%
            sd(0.0833e18)  // T = 1 month
        );
        gasUsed = start - gasleft();
    }
}
```

---

## 6. Security Analysis & Formal Verification

### 6.1 Threat Model

| Threat | Impact | Mitigation |
|---|---|---|
| Oracle manipulation | Mispriced options → LP drain | Multi-oracle validation, TWAP, staleness checks |
| Flash loan + exercise | Extract value via instant price manipulation | Exercise only at expiry (European), oracle TWAP |
| Precision loss → mispricing | Systematic under/over-pricing | Formal verification of error bounds |
| Rounding direction exploit | Drain pool via many small trades | Always round against the trader |
| IV manipulation | Artificially cheap options | Min/max IV bounds, governance caps |
| Donation attack on empty pool | Inflate share price | Minimum initial deposit, virtual offset |
| Front-running option mints | Sandwich attacks on premium | Commit-reveal or batch auctions |

### 6.2 Formal Verification Plan (Certora / Halmos)

**Invariant 1: Solvency**
```
∀ state: pool.totalAssets ≥ Σ(maxPayoff(option_i))
```
"The pool always holds enough to cover worst-case payoffs."

**Invariant 2: Pricing Monotonicity**
```
∀ S, K, σ, r, T:
    ∂C/∂S > 0    (call price increases with spot)
    ∂P/∂S < 0    (put price increases as spot falls)
    ∂C/∂σ > 0    (vega is always positive)
    ∂C/∂T > 0    (theta is negative — time decay)
```

**Invariant 3: Put-Call Parity**
```
∀ S, K, r, T:
    C - P = S - K · e^(-rT)
    |error| < ε_max    (bounded computational error)
```

**Invariant 4: CDF Bounds**
```
∀ x ∈ [-10, 10]:
    0 ≤ Φ(x) ≤ 1
    Φ(-x) = 1 - Φ(x)      (symmetry)
    |Φ_approx(x) - Φ_exact(x)| < 1e-5
```

**Invariant 5: No Value Extraction**
```
∀ mint → exercise sequence:
    profit(user) ≤ intrinsic_value(option) - premium_paid
```

### 6.3 Differential Testing

Compare on-chain BSM output against Python reference implementation:

```python
# Reference: scipy Black-Scholes
from scipy.stats import norm
import numpy as np

def bs_call(S, K, r, sigma, T):
    d1 = (np.log(S/K) + (r + sigma**2/2)*T) / (sigma*np.sqrt(T))
    d2 = d1 - sigma*np.sqrt(T)
    return S*norm.cdf(d1) - K*np.exp(-r*T)*norm.cdf(d2)
```

Fuzz test: generate 10,000 random (S, K, σ, r, T) tuples, compare Solidity output to Python output. **Acceptance criterion**: max relative error < 0.01% for all test cases.

---

## 7. Implementation Roadmap

### Phase 1: Math Engine (Weeks 1–3)
- [ ] Implement `FixedPointMathLib.sol` using PRBMath SD59x18
- [ ] Implement `CumulativeNormal.sol` with Hart's approximation
- [ ] Implement `BSMEngine.sol` — price(), delta(), gamma(), theta(), vega()
- [ ] Gas benchmark suite
- [ ] Differential fuzz tests vs Python scipy reference
- [ ] Error bound analysis document

**Deliverable**: Standalone pricing library with <0.01% error, <80K gas

### Phase 2: Protocol Core (Weeks 4–7)
- [ ] `OptionToken.sol` — ERC-1155 with strike/expiry encoding
- [ ] `OptionVault.sol` — mint, exercise, settle lifecycle
- [ ] `LiquidityPool.sol` — deposit, withdraw, collateral management
- [ ] `Settlement.sol` — expiry resolution, ITM exercise, OTM expiry
- [ ] `OracleAdapter.sol` — Chainlink + Pyth + TWAP with validation
- [ ] Integration tests with fork testing (Arbitrum mainnet fork)

**Deliverable**: Functional options protocol on testnet

### Phase 3: Volatility Surface (Weeks 8–10)
- [ ] `RealizedVolOracle.sol` — EWMA from price feeds
- [ ] `SkewModel.sol` — quadratic strike-dependent skew
- [ ] `VolatilitySurface.sol` — LSIVS combining components
- [ ] Calibration against historical Deribit IV data
- [ ] Back-testing framework

**Deliverable**: Self-contained IV engine, no external IV dependency

### Phase 4: Security & Verification (Weeks 11–13)
- [ ] Certora/Halmos invariant specifications
- [ ] Solvency proof
- [ ] Put-call parity verification
- [ ] CDF error bound proof
- [ ] Slither + Aderyn static analysis
- [ ] Manual audit checklist (reentrancy, access control, oracle, flash loan)

**Deliverable**: Formal verification report with proven invariants

### Phase 5: Documentation & Presentation (Weeks 14–16)
- [ ] Academic paper (LaTeX, targeting ICBC or FC conference format)
- [ ] Gas optimization analysis with comparisons
- [ ] Security audit report
- [ ] NatSpec documentation (auto-generated via solidity-docgen)
- [ ] Frontend demo (optional React dashboard)
- [ ] TDS presentation deck

**Deliverable**: Complete TDS submission package

---

## 8. Testing Strategy

### 8.1 Test Pyramid

```
         ┌─────────────────┐
         │  Fork Tests      │  ← Arbitrum/BSC mainnet fork
         │  (Integration)   │     Real oracles, real tokens
         ├─────────────────┤
         │  Scenario Tests  │  ← Full option lifecycle
         │  (E2E)           │     mint → trade → exercise/expire
         ├─────────────────┤
         │  Property Tests  │  ← Foundry fuzz + invariant testing
         │  (Fuzzing)       │     10K+ random inputs
         ├─────────────────┤
         │  Unit Tests      │  ← Individual function correctness
         │  (Foundation)    │     Math precision, edge cases
         └─────────────────┘
```

### 8.2 Key Test Cases

**Math Precision Tests**:
- CDF at extreme values: Φ(-10) ≈ 0, Φ(0) = 0.5, Φ(10) ≈ 1
- BSM at boundaries: deep ITM, ATM, deep OTM
- Zero time to expiry: option = max(S-K, 0)
- Very high volatility (σ > 200%)
- Very low volatility (σ < 1%)

**Protocol Tests**:
- Mint call → price moves up → exercise → verify payoff
- Mint put → price moves down → exercise → verify payoff
- Option expires OTM → verify zero payoff, collateral return
- LP deposit → options traded → LP withdraw with P&L
- Liquidation trigger on undercollateralized positions

**Attack Simulations**:
- Flash loan + oracle manipulation attempt
- Sandwich attack on option mint
- Max value extraction via rounding
- Pool drain via coordinated exercise

---

## 9. Technology Stack

| Component | Technology |
|---|---|
| Language | Solidity ^0.8.25 |
| Framework | Foundry (forge, cast, anvil) |
| Math Library | PRBMath v4 (SD59x18) + custom CDF |
| Token Standard | ERC-1155 (OpenZeppelin) |
| Oracle | Chainlink v0.8, Pyth, custom TWAP |
| Testing | Forge test + fuzz + invariant |
| Formal Verification | Certora Prover / Halmos |
| Static Analysis | Slither, Aderyn, Mythril |
| Gas Profiling | forge test --gas-report |
| Documentation | NatSpec + solidity-docgen |
| Frontend (optional) | React + wagmi + viem |
| Deployment | Hardhat-deploy / Foundry scripts |

---

## 10. Comparison with Existing Protocols

| Feature | Lyra/Derive | Dopex/Stryke | Panoptic | **MantissaFi** |
|---|---|---|---|---|
| Pricing model | BSM (off-chain IV) | BSM (off-chain IV) | Oracle-free (Uniswap LP) | **BSM (fully on-chain)** |
| IV source | GWAV + Deribit | External | N/A (LP-derived) | **On-chain LSIVS** |
| Greeks on-chain | No | No | Partial | **Yes — full suite** |
| CDF precision | N/A | N/A | N/A | **<0.0001% error** |
| Formal verification | No | No | No | **Certora invariants** |
| Gas per price | N/A (off-chain) | N/A (off-chain) | ~80K | **Target <80K** |
| Option style | European | American | Perpetual | **European** |
| Chain | Custom L2 | Arbitrum | Ethereum/Arbitrum | **Multi-EVM** |

---

## 11. Academic Contribution

### 11.1 Paper Outline

**Title**: "MantissaFi: Gas-Efficient Black-Scholes-Merton Pricing and Liquidity-Sensitive Implied Volatility Surfaces for On-Chain European Options"

1. **Introduction** — Gap in fully on-chain option pricing
2. **Related Work** — Lyra, Dopex, Panoptic, Primitive RMM, Hegic
3. **Mathematical Framework** — BSM in fixed-point, CDF approximation analysis
4. **Volatility Surface Construction** — EWMA realized vol, skew model, utilization premium
5. **System Design** — Smart contract architecture, gas optimization
6. **Formal Verification** — Invariant specifications and proofs
7. **Evaluation** — Gas benchmarks, precision analysis, back-testing against Deribit
8. **Discussion** — Limitations of BSM for crypto, future directions (Heston, jump-diffusion)
9. **Conclusion**

### 11.2 Target Venues

- **IEEE ICBC** (International Conference on Blockchain and Cryptocurrency)
- **FC** (Financial Cryptography and Data Security)
- **DeFi Security Summit** papers track
- **arXiv** preprint for community review

---

## 12. Evaluation Criteria

| Criterion | Metric | Target |
|---|---|---|
| Pricing accuracy | Max relative error vs scipy BSM | < 0.01% |
| CDF accuracy | Max absolute error vs scipy Φ(x) | < 1 × 10⁻⁵ |
| Gas efficiency (price) | Gas per BSM call | < 80,000 |
| Gas efficiency (CDF) | Gas per Φ(x) call | < 10,000 |
| Test coverage | Line + branch coverage | > 95% |
| Formal invariants | Proven invariants | ≥ 5 |
| Fuzz test inputs | Random test vectors | ≥ 10,000 |
| Put-call parity | Max absolute deviation | < 0.001 USDC per option |
| Slither findings | Critical/High | 0 |

---

## 13. Risk & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| CDF gas exceeds target | Medium | Medium | Fall back to lower-precision 3-term approximation |
| Certora learning curve | High | Low | Start with Halmos (Python-based, lower barrier) |
| BSM unsuitable for crypto | Known | Medium | Acknowledge as limitation; propose Heston extension as future work |
| IV surface diverges from market | Medium | High | Calibrate against 6 months of Deribit data; add governance bounds |
| Complexity exceeds timeline | Medium | High | Phase 5 (paper/frontend) can extend; core protocol is MVP |

---

## 14. Repository Structure

```
mantissa-fi/
├── contracts/              # Solidity source
├── test/                   # Forge tests
│   ├── unit/              # Individual function tests
│   ├── fuzz/              # Fuzz + invariant tests
│   ├── integration/       # Full lifecycle tests
│   └── fork/              # Mainnet fork tests
├── certora/               # Formal verification specs
│   ├── specs/             # .spec files
│   └── conf/              # .conf files
├── scripts/               # Deployment + utilities
├── analysis/              # Python notebooks for calibration & back-testing
│   ├── precision_test.py  # Differential testing vs scipy
│   ├── gas_benchmark.py   # Gas analysis and visualization
│   └── iv_calibration.py  # LSIVS calibration vs Deribit
├── paper/                 # LaTeX academic paper
├── docs/                  # Auto-generated NatSpec docs
├── CLAUDE.md              # Claude Code project context
├── .claude/               # Claude Code skills & commands
├── foundry.toml
└── README.md
```

---

## 15. References

1. Black, F., & Scholes, M. (1973). "The Pricing of Options and Corporate Liabilities." *Journal of Political Economy*.
2. Abramowitz, M., & Stegun, I.A. (1964). "Handbook of Mathematical Functions." §26.2.17.
3. Hart, J.F. (1968). "Computer Approximations." Wiley.
4. Adams, H., et al. (2021). "Replicating Market Makers." Primitive Finance.
5. Guillaume, T., et al. (2023). "Panoptic: A Perpetual, Oracle-Free Options Protocol." Panoptic whitepaper.
6. Clark, M. (2021). "Lyra: An Options AMM." Lyra Finance whitepaper.
7. PRBMath. Solidity library for advanced fixed-point math. github.com/PaulRBerg/prb-math.
8. SolStat. Gaussian.sol — CDF implementation for Solidity. github.com/primitivefinance/solstat.

---

*This document serves as the complete TDS project specification for MantissaFi. The project demonstrates senior-level Solidity engineering, deep financial mathematics, formal verification methodology, and gas optimization at the EVM level.*