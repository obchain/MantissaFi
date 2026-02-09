# Contributing to MantissaFi

Thank you for your interest in contributing to MantissaFi! This document provides guidelines and standards for contributing to the project.

---

## Table of Contents

- [Getting Started](#getting-started)
- [Branch Naming Convention](#branch-naming-convention)
- [Commit Message Format](#commit-message-format)
- [Pull Request Process](#pull-request-process)
- [Code Style Guidelines](#code-style-guidelines)
- [Testing Requirements](#testing-requirements)
- [Security Considerations](#security-considerations)

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Solidity 0.8.24+
- Git

### Setup

```bash
# Clone the repository
git clone git@github.com:obchain/MantissaFi.git
cd MantissaFi

# Install dependencies
forge install

# Build the project
forge build

# Run tests
forge test
```

---

## Branch Naming Convention

Use the following prefixes for branch names:

| Prefix | Purpose | Example |
|--------|---------|---------|
| `feat/` | New features | `feat/add-option-pricing` |
| `fix/` | Bug fixes | `fix/precision-loss-in-sqrt` |
| `test/` | Adding or updating tests | `test/fuzz-cumulative-normal` |
| `docs/` | Documentation changes | `docs/update-readme` |
| `refactor/` | Code refactoring | `refactor/extract-math-lib` |
| `perf/` | Performance improvements | `perf/optimize-exp-function` |
| `chore/` | Maintenance tasks | `chore/update-dependencies` |

### Branch Name Format

```
<type>/<short-description>
```

**Examples:**
- `feat/black-scholes-pricing`
- `fix/oracle-stale-price-check`
- `test/invariant-liquidity-pool`
- `docs/add-natspec-comments`

---

## Commit Message Format

We follow [Conventional Commits](https://www.conventionalcommits.org/) specification.

### Format

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### Types

| Type | Description |
|------|-------------|
| `feat` | A new feature |
| `fix` | A bug fix |
| `docs` | Documentation only changes |
| `style` | Formatting, missing semicolons, etc. (no code change) |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | Performance improvement |
| `test` | Adding or correcting tests |
| `chore` | Maintenance tasks, dependency updates |

### Scopes

Use the module name as the scope:

- `core` - Core protocol contracts
- `pricing` - Option pricing (BSM)
- `volatility` - IV calculations
- `oracle` - Price feed integrations
- `periphery` - Router, helper contracts
- `libraries` - Shared math libraries

### Examples

```bash
# Feature
feat(pricing): implement Black-Scholes call option pricing

# Bug fix
fix(oracle): add staleness check for Chainlink price feeds

# Documentation
docs(core): add NatSpec comments to MantissaCore

# Tests
test(pricing): add fuzz tests for cumulative normal distribution

# Refactoring
refactor(libraries): extract exp function to separate library

# Performance
perf(pricing): optimize d1/d2 calculation with caching
```

### Commit Message Guidelines

1. **Subject line**: Maximum 72 characters
2. **Body**: Wrap at 80 characters, explain *what* and *why* (not *how*)
3. **Footer**: Reference issues with `Closes #123` or `Refs #456`

---

## Pull Request Process

### Before Submitting

1. **Create a feature branch** from `main`
2. **Write tests** for new functionality
3. **Run the full test suite**: `forge test`
4. **Run gas benchmarks**: `forge test --gas-report`
5. **Format code**: `forge fmt`
6. **Update documentation** if needed

### PR Checklist

Every PR should include:

- [ ] Tests for new functionality
- [ ] All tests passing (`forge test`)
- [ ] Code formatted (`forge fmt --check`)
- [ ] NatSpec documentation for public/external functions
- [ ] Gas report for gas-sensitive changes
- [ ] No compiler warnings
- [ ] Updated README/docs if applicable

### PR Title Format

Follow the same format as commit messages:

```
<type>(<scope>): <description>
```

### PR Description Template

```markdown
## Summary
Brief description of changes.

## Changes
- Change 1
- Change 2

## Test Plan
- [ ] Unit tests added/updated
- [ ] Fuzz tests added/updated
- [ ] Integration tests (if applicable)

## Gas Impact
[Include gas report diff if applicable]

## Related Issues
Closes #<issue_number>
```

---

## Code Style Guidelines

### Solidity Style Guide

We follow the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html) with additional requirements:

#### File Structure

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// 1. Imports (sorted alphabetically)
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SD59x18} from "@prb/math/SD59x18.sol";

// 2. Interfaces

// 3. Libraries

// 4. Contracts
```

#### Contract Structure

```solidity
contract Example {
    // 1. Type declarations (enums, structs)
    // 2. State variables
    // 3. Events
    // 4. Errors
    // 5. Modifiers
    // 6. Constructor
    // 7. External functions
    // 8. Public functions
    // 9. Internal functions
    // 10. Private functions
}
```

#### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Contracts | PascalCase | `OptionPricer` |
| Interfaces | PascalCase with `I` prefix | `IOracle` |
| Libraries | PascalCase | `MathLib` |
| Functions | camelCase | `calculatePrice` |
| Variables | camelCase | `strikePrice` |
| Constants | SCREAMING_SNAKE_CASE | `MAX_FEE_BPS` |
| Private variables | camelCase with `_` prefix | `_owner` |
| Function parameters | camelCase with `_` prefix | `_amount` |
| Events | PascalCase | `OptionMinted` |
| Errors | PascalCase | `InsufficientBalance` |

#### NatSpec Documentation

**Required** for all public and external functions:

```solidity
/// @notice Calculates the price of a European call option using Black-Scholes
/// @dev Uses fixed-point arithmetic with SD59x18 for precision
/// @param _spot Current spot price of the underlying asset
/// @param _strike Strike price of the option
/// @param _timeToExpiry Time to expiration in seconds
/// @param _volatility Implied volatility (annualized)
/// @param _riskFreeRate Risk-free interest rate (annualized)
/// @return price The calculated option price in the same decimals as spot
function calculateCallPrice(
    SD59x18 _spot,
    SD59x18 _strike,
    SD59x18 _timeToExpiry,
    SD59x18 _volatility,
    SD59x18 _riskFreeRate
) external pure returns (SD59x18 price) {
    // Implementation
}
```

#### Error Handling

Use custom errors instead of require strings:

```solidity
// Good
error InvalidStrikePrice(uint256 strike);
error ExpiredOption(uint256 expiry, uint256 currentTime);

if (strike == 0) revert InvalidStrikePrice(strike);

// Avoid
require(strike > 0, "Invalid strike price");
```

---

## Testing Requirements

### Test Categories

All new code must include appropriate tests:

| Test Type | Location | Purpose |
|-----------|----------|---------|
| Unit | `test/unit/` | Test individual functions |
| Fuzz | `test/fuzz/` | Property-based testing |
| Invariant | `test/invariant/` | Protocol invariants |
| Integration | `test/integration/` | Multi-contract interactions |
| Fork | `test/fork/` | Mainnet fork testing |
| Differential | `test/differential/` | Compare with reference implementations |
| Gas | `test/gas/` | Gas benchmarking |

### Minimum Requirements

1. **Unit Tests**: Cover all public/external functions
2. **Fuzz Tests**: For mathematical functions and edge cases
3. **Coverage**: Aim for >90% line coverage on new code

### Test File Naming

```
test/<category>/<ContractName>.<Category>.t.sol
```

**Examples:**
- `test/unit/OptionPricer.Unit.t.sol`
- `test/fuzz/CumulativeNormal.Fuzz.t.sol`
- `test/invariant/LiquidityPool.Invariant.t.sol`

### Running Tests

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/unit/OptionPricer.Unit.t.sol

# Run with verbosity
forge test -vvv

# Run with gas report
forge test --gas-report

# Run fuzz tests with more runs
forge test --fuzz-runs 10000

# Run fork tests
forge test --fork-url $RPC_URL
```

---

## Security Considerations

### Before Submitting Code

1. **No hardcoded secrets** - Use environment variables
2. **Check for reentrancy** - Use checks-effects-interactions pattern
3. **Validate inputs** - Check for zero addresses, overflow, etc.
4. **Consider flash loan attacks** - For any price-dependent logic
5. **Review oracle usage** - Check for staleness, manipulation

### Reporting Vulnerabilities

See [SECURITY.md](./SECURITY.md) for responsible disclosure guidelines.

---

## Questions?

If you have questions about contributing, please:

1. Check existing issues and documentation
2. Open a new issue with the `question` label
3. Join our community discussions

Thank you for contributing to MantissaFi!
