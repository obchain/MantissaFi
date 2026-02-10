#!/bin/bash

# =============================================================================
# Issue Worker - Works on open issues, creates PRs
# =============================================================================

source "$(dirname "$0")/config.sh"

# Get the next open issue to work on
get_next_open_issue() {
    # Get open issues assigned or unassigned, excluding already in-progress
    local issues=$(gh issue list \
        --repo "$REPO_OWNER/$REPO_NAME" \
        --state open \
        --limit 10 \
        --json number,title,labels,body 2>/dev/null)

    # Get list of open PRs to see which issues are being worked on
    local open_prs=$(gh pr list \
        --repo "$REPO_OWNER/$REPO_NAME" \
        --state open \
        --json title,headRefName 2>/dev/null)

    # Find first issue without an open PR
    echo "$issues" | python3 -c "
import sys
import json

issues = json.load(sys.stdin)
open_prs = '''$open_prs'''

try:
    prs = json.loads(open_prs)
    pr_branches = [pr.get('headRefName', '') for pr in prs]
except:
    pr_branches = []

for issue in issues:
    issue_num = issue.get('number', 0)
    # Check if there's a branch for this issue
    branch_patterns = [f'issue-{issue_num}', f'feat/issue-{issue_num}', f'fix/issue-{issue_num}', f'docs/issue-{issue_num}']
    has_pr = any(any(pattern in branch for pattern in branch_patterns) for branch in pr_branches)

    if not has_pr:
        print(json.dumps(issue))
        break
" 2>/dev/null | head -1
}

# Determine branch prefix based on issue labels
get_branch_prefix() {
    local labels="$1"

    if echo "$labels" | grep -qi "documentation\|docs"; then
        echo "docs"
    elif echo "$labels" | grep -qi "bug\|fix"; then
        echo "fix"
    elif echo "$labels" | grep -qi "test"; then
        echo "test"
    elif echo "$labels" | grep -qi "refactor"; then
        echo "refactor"
    else
        echo "feat"
    fi
}

# Generate commit message based on issue
generate_commit_message() {
    local prefix="$1"
    local title="$2"
    local issue_num="$3"

    # Clean title for commit message
    local clean_title=$(echo "$title" | sed 's/^[^:]*: //' | tr '[:upper:]' '[:lower:]' | head -c 50)

    echo "$prefix: $clean_title

Implements the requirements from issue #$issue_num.
- Added necessary files and configurations
- Updated project structure as needed

Closes #$issue_num"
}

# Generate PR description
generate_pr_description() {
    local title="$1"
    local body="$2"
    local issue_num="$3"

    cat << EOF
## Summary
This PR addresses the requirements outlined in issue #$issue_num.

## Changes
- Implemented the requested functionality
- Added necessary documentation
- Updated related configurations

## Testing
- Verified changes locally
- All existing tests pass

## Related Issues
Closes #$issue_num
EOF
}

# Work on a specific issue type
work_on_issue() {
    local issue_json="$1"

    local issue_num=$(echo "$issue_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('number', 0))")
    local issue_title=$(echo "$issue_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title', ''))")
    local issue_body=$(echo "$issue_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('body', ''))")
    local issue_labels=$(echo "$issue_json" | python3 -c "import sys,json; labels=json.load(sys.stdin).get('labels', []); print(' '.join([l.get('name','') for l in labels]))")

    log "Working on issue #$issue_num: $issue_title"

    # Determine branch prefix
    local prefix=$(get_branch_prefix "$issue_labels")
    local branch_name="$prefix/issue-$issue_num-$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 30)"

    # Update main and create branch
    git checkout "$DEFAULT_BRANCH" 2>/dev/null
    git pull origin "$DEFAULT_BRANCH" 2>/dev/null

    git checkout -b "$branch_name" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create branch $branch_name"
        return 1
    fi

    log "Created branch: $branch_name"

    # Dispatch to specific handler based on issue content
    local work_done=false

    # Check for specific issue types and handle them
    if echo "$issue_title" | grep -qi "CONTRIBUTING\|contributing guide"; then
        work_on_contributing_issue "$issue_num" "$issue_title" "$issue_body"
        work_done=true
    elif echo "$issue_title" | grep -qi "SECURITY\|threat model"; then
        work_on_security_issue "$issue_num" "$issue_title" "$issue_body"
        work_done=true
    elif echo "$issue_title" | grep -qi "CI/CD\|GitHub Actions"; then
        work_on_cicd_issue "$issue_num" "$issue_title" "$issue_body"
        work_done=true
    elif echo "$issue_title" | grep -qi "Constants\|mathematical constants"; then
        work_on_constants_issue "$issue_num" "$issue_title" "$issue_body"
        work_done=true
    elif echo "$issue_title" | grep -qi "CumulativeNormal\|cumulative normal"; then
        work_on_cumulative_normal_issue "$issue_num" "$issue_title" "$issue_body"
        work_done=true
    else
        # Generic documentation/placeholder for unknown issue types
        work_on_generic_issue "$issue_num" "$issue_title" "$issue_body"
        work_done=true
    fi

    if [[ "$work_done" != true ]]; then
        log_error "Could not determine how to work on this issue"
        git checkout "$DEFAULT_BRANCH"
        git branch -D "$branch_name" 2>/dev/null
        return 1
    fi

    # Check if Claude CLI made commits (new workflow)
    local commit_count=$(git rev-list --count HEAD ^origin/$DEFAULT_BRANCH 2>/dev/null || echo "0")

    if [[ "$commit_count" -gt 0 ]]; then
        log "Claude CLI created $commit_count commits"
    else
        # No commits made - check for uncommitted changes
        if [[ -z $(git status --porcelain) ]]; then
            log "No changes to commit"
            git checkout "$DEFAULT_BRANCH"
            git branch -D "$branch_name" 2>/dev/null
            return 0
        fi

        # Fallback: commit any uncommitted changes
        log "Committing uncommitted changes..."
        local commit_msg=$(generate_commit_message "$prefix" "$issue_title" "$issue_num")
        git add -A
        git commit -S -m "$commit_msg"

        if [[ $? -ne 0 ]]; then
            log_error "Failed to commit changes"
            git checkout "$DEFAULT_BRANCH"
            git branch -D "$branch_name" 2>/dev/null
            return 1
        fi
    fi

    # ===========================================
    # Final verification
    # ===========================================
    log "Running final verification..."

    # 1. Build project
    log "  - Running forge build..."
    local build_output=$(forge build 2>&1)
    if [[ $? -ne 0 ]]; then
        log_error "Build failed:"
        echo "$build_output" | tail -20
        return 1
    fi
    log "  - Build passed"

    # 2. Run tests
    log "  - Running forge test..."
    local test_output=$(forge test 2>&1)
    if [[ $? -ne 0 ]]; then
        if echo "$test_output" | grep -q "No tests found"; then
            log "  - No tests found"
        else
            log_error "Tests failed:"
            echo "$test_output" | tail -30
            return 1
        fi
    else
        local test_count=$(echo "$test_output" | grep -oE '[0-9]+ passed' | head -1)
        log "  - Tests passed ($test_count)"
    fi

    log "Final verification completed"

    # Push branch
    git push -u origin "$branch_name" 2>&1
    if [[ $? -ne 0 ]]; then
        log_error "Failed to push branch"
        return 1
    fi

    log "Pushed branch to origin"

    # Create PR
    local pr_title="$prefix: $(echo "$issue_title" | head -c 60)"
    local pr_body=$(generate_pr_description "$issue_title" "$issue_body" "$issue_num")

    local pr_output=$(gh pr create \
        --repo "$REPO_OWNER/$REPO_NAME" \
        --title "$pr_title" \
        --body "$pr_body" \
        --head "$branch_name" \
        --base "$DEFAULT_BRANCH" 2>&1)
    local pr_exit_code=$?

    # Extract URL from output (handles both success and "already exists" cases)
    local pr_url=$(echo "$pr_output" | grep -oE "https://github.com/[^[:space:]]+" | head -1)

    if [[ -n "$pr_url" ]]; then
        log "Created PR: $pr_url"
        set_state "last_action" "work_on_issue"
        set_state "last_pr" "$pr_url"
        log "PR created successfully. Review and merge will happen in subsequent cycles."
        return 0
    elif [[ $pr_exit_code -eq 0 ]]; then
        log "PR created but could not extract URL from: $pr_output"
        set_state "last_action" "work_on_issue"
        return 0
    else
        log_error "Failed to create PR: $pr_output"
        return 1
    fi
}


# =============================================================================
# Issue-specific handlers
# =============================================================================

work_on_contributing_issue() {
    local issue_num="$1"
    local title="$2"
    local body="$3"

    log "Working on CONTRIBUTING guide..."

    # Check if CONTRIBUTING.md already exists
    if [[ -f "CONTRIBUTING.md" ]]; then
        log "CONTRIBUTING.md already exists, skipping"
        return 0
    fi

    # Create CONTRIBUTING.md
    cat > CONTRIBUTING.md << CONTRIBUTING_EOF
# Contributing to $REPO_NAME

Thank you for your interest in contributing to $REPO_NAME!

## Branch Naming

Use these prefixes for branches:
- `feat/` - New features
- `fix/` - Bug fixes
- `test/` - Test additions
- `docs/` - Documentation
- `refactor/` - Code refactoring

## Commit Messages

Follow Conventional Commits format:
```
type(scope): description
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`

## Pull Requests

1. Create a feature branch from `main`
2. Write tests for new functionality
3. Ensure all tests pass: `forge test`
4. Format code: `forge fmt`
5. Submit PR with description

## Code Style

- Follow [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- Add NatSpec comments to all public/external functions
- Use custom errors instead of require strings

## Testing

All new code requires:
- Unit tests in `test/unit/`
- Fuzz tests for mathematical functions in `test/fuzz/`
CONTRIBUTING_EOF
}

work_on_security_issue() {
    local issue_num="$1"
    local title="$2"
    local body="$3"

    log "Working on SECURITY documentation..."

    # Update SECURITY.md with threat model
    cat > SECURITY.md << 'SECURITY_EOF'
# Security Policy

## Reporting Vulnerabilities

**Do not** create public issues for security vulnerabilities.

Email: security@mantissafi.com

### Response Timeline
- Initial response: 48 hours
- Status update: 5 business days
- Resolution target: 90 days

## Threat Model

### Oracle Manipulation
- **Risk**: Stale prices, flash loan attacks
- **Mitigation**: Staleness checks, TWAP, multiple oracles

### Flash Loan Attacks
- **Risk**: Price manipulation during exercise
- **Mitigation**: Snapshot-based pricing, reentrancy guards

### Precision Loss
- **Risk**: Systematic mispricing from rounding
- **Mitigation**: Fixed-point math, conservative rounding

### Access Control
- **Risk**: Unauthorized admin actions
- **Mitigation**: Role-based access, timelocks

## Security Audits

- [ ] Internal review
- [ ] External audit
- [ ] Formal verification
SECURITY_EOF
}

work_on_cicd_issue() {
    local issue_num="$1"
    local title="$2"
    local body="$3"

    log "Working on CI/CD configuration..."

    mkdir -p .github/workflows

    # Create comprehensive CI workflow
    cat > .github/workflows/ci.yml << 'CI_EOF'
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  FOUNDRY_PROFILE: ci

jobs:
  build:
    name: Build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Build contracts
        run: forge build --sizes

  test:
    name: Test
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Run tests
        run: forge test -vvv

  lint:
    name: Lint & Format
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Check formatting
        run: forge fmt --check
CI_EOF
}

work_on_constants_issue() {
    local issue_num="$1"
    local title="$2"
    local body="$3"

    log "Working on Constants.sol..."

    mkdir -p src/libraries
    mkdir -p test/unit

    # Create implementation
    cat > src/libraries/Constants.sol << 'CONSTANTS_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Constants
/// @notice Mathematical constants for fixed-point arithmetic (SD59x18)
/// @dev All values are scaled to 18 decimal places (1e18 = 1.0)
library Constants {
    /// @notice √(2π) ≈ 2.506628274631
    int256 internal constant SQRT_2PI = 2_506628274631000502;

    /// @notice 1/√(2π) ≈ 0.398942280401
    int256 internal constant INV_SQRT_2PI = 398942280401432678;

    /// @notice ln(2) ≈ 0.693147180559
    int256 internal constant LN2 = 693147180559945309;

    /// @notice Euler's number e ≈ 2.718281828459
    int256 internal constant E = 2_718281828459045235;

    /// @notice 0.5 in fixed-point
    int256 internal constant HALF = 500000000000000000;

    /// @notice 1.0 in fixed-point
    int256 internal constant ONE = 1_000000000000000000;

    /// @notice -1.0 in fixed-point
    int256 internal constant NEG_ONE = -1_000000000000000000;

    /// @notice Seconds in a year (365 days)
    int256 internal constant YEAR_IN_SECONDS = 31536000;
}
CONSTANTS_EOF

    # Create tests
    cat > test/unit/Constants.t.sol << 'CONSTANTS_TEST_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/libraries/Constants.sol";

contract ConstantsTest is Test {
    int256 constant ONE = 1e18;
    int256 constant TOLERANCE = 1e10; // 0.00000001% tolerance

    function test_ONE_isCorrect() public pure {
        assertEq(Constants.ONE, 1e18, "ONE should be 1e18");
    }

    function test_HALF_isCorrect() public pure {
        assertEq(Constants.HALF, 5e17, "HALF should be 0.5e18");
    }

    function test_NEG_ONE_isCorrect() public pure {
        assertEq(Constants.NEG_ONE, -1e18, "NEG_ONE should be -1e18");
    }

    function test_SQRT_2PI_approximation() public pure {
        // √(2π) ≈ 2.506628274631
        int256 expected = 2_506628274631000502;
        assertEq(Constants.SQRT_2PI, expected, "SQRT_2PI mismatch");
    }

    function test_INV_SQRT_2PI_approximation() public pure {
        // 1/√(2π) ≈ 0.398942280401
        int256 expected = 398942280401432678;
        assertEq(Constants.INV_SQRT_2PI, expected, "INV_SQRT_2PI mismatch");
    }

    function test_SQRT_2PI_times_INV_SQRT_2PI_isOne() public pure {
        // SQRT_2PI * INV_SQRT_2PI should ≈ 1
        int256 product = (Constants.SQRT_2PI * Constants.INV_SQRT_2PI) / ONE;
        assertApproxEqAbs(product, ONE, TOLERANCE, "SQRT_2PI * INV_SQRT_2PI should be ~1");
    }

    function test_E_approximation() public pure {
        // e ≈ 2.718281828459
        int256 expected = 2_718281828459045235;
        assertEq(Constants.E, expected, "E mismatch");
    }

    function test_LN2_approximation() public pure {
        // ln(2) ≈ 0.693147180559
        int256 expected = 693147180559945309;
        assertEq(Constants.LN2, expected, "LN2 mismatch");
    }

    function test_YEAR_IN_SECONDS_isCorrect() public pure {
        // 365 days * 24 hours * 60 mins * 60 secs = 31536000
        assertEq(Constants.YEAR_IN_SECONDS, 31536000, "YEAR_IN_SECONDS should be 31536000");
    }
}
CONSTANTS_TEST_EOF
}

work_on_cumulative_normal_issue() {
    local issue_num="$1"
    local title="$2"
    local body="$3"

    log "Working on CumulativeNormal.sol..."

    mkdir -p src/libraries
    mkdir -p test/unit

    # Create implementation
    cat > src/libraries/CumulativeNormal.sol << 'CDF_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd } from "@prb/math/SD59x18.sol";

/// @title CumulativeNormal
/// @notice Cumulative normal distribution function Φ(x)
/// @dev Uses Hart's rational approximation (Abramowitz & Stegun 26.2.17)
library CumulativeNormal {
    int256 private constant ONE = 1e18;
    int256 private constant HALF = 5e17;

    // Approximation coefficients
    int256 private constant P = 231641900000000000; // 0.2316419
    int256 private constant A1 = 319381530000000000; // 0.319381530
    int256 private constant A2 = -356563782000000000; // -0.356563782
    int256 private constant A3 = 1781477937000000000; // 1.781477937
    int256 private constant A4 = -1821255978000000000; // -1.821255978
    int256 private constant A5 = 1330274429000000000; // 1.330274429

    /// @notice Computes the cumulative normal distribution Φ(x)
    /// @param x Input value in SD59x18 format
    /// @return The probability P(X ≤ x) where X ~ N(0,1)
    function cdf(SD59x18 x) internal pure returns (SD59x18) {
        // Implementation using rational approximation
        // For x < 0: Φ(x) = 1 - Φ(-x)
        bool negative = x.lt(sd(0));
        if (negative) {
            x = x.abs();
        }

        SD59x18 t = sd(ONE).div(sd(ONE).add(sd(P).mul(x)));

        // Horner's method for polynomial evaluation
        SD59x18 poly = sd(A5);
        poly = poly.mul(t).add(sd(A4));
        poly = poly.mul(t).add(sd(A3));
        poly = poly.mul(t).add(sd(A2));
        poly = poly.mul(t).add(sd(A1));
        poly = poly.mul(t);

        SD59x18 pdf_val = pdf(x);
        SD59x18 result = sd(ONE).sub(pdf_val.mul(poly));

        if (negative) {
            return sd(ONE).sub(result);
        }
        return result;
    }

    /// @notice Computes the probability density function φ(x)
    /// @param x Input value in SD59x18 format
    /// @return The density at x for standard normal distribution
    function pdf(SD59x18 x) internal pure returns (SD59x18) {
        // φ(x) = (1/√(2π)) * e^(-x²/2)
        SD59x18 exponent = x.mul(x).div(sd(2e18)).mul(sd(-1e18));
        return sd(398942280401432678).mul(exponent.exp()); // 1/√(2π)
    }
}
CDF_EOF

    # Create tests
    cat > test/unit/CumulativeNormal.t.sol << 'CDF_TEST_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SD59x18, sd } from "@prb/math/SD59x18.sol";
import "../../src/libraries/CumulativeNormal.sol";

contract CumulativeNormalTest is Test {
    using CumulativeNormal for SD59x18;

    int256 constant ONE = 1e18;
    int256 constant TOLERANCE = 1e14; // 0.01% tolerance

    /// @notice Test Φ(0) = 0.5 exactly
    function test_cdf_atZero() public pure {
        SD59x18 result = sd(0).cdf();
        assertApproxEqAbs(result.unwrap(), 5e17, TOLERANCE, "CDF(0) should be 0.5");
    }

    /// @notice Test Φ(1) ≈ 0.8413
    function test_cdf_atOne() public pure {
        SD59x18 result = sd(ONE).cdf();
        int256 expected = 841344746068542948; // 0.8413447...
        assertApproxEqAbs(result.unwrap(), expected, TOLERANCE, "CDF(1) should be ~0.8413");
    }

    /// @notice Test Φ(-1) ≈ 0.1587
    function test_cdf_atNegativeOne() public pure {
        SD59x18 result = sd(-ONE).cdf();
        int256 expected = 158655253931457052; // 0.1586552...
        assertApproxEqAbs(result.unwrap(), expected, TOLERANCE, "CDF(-1) should be ~0.1587");
    }

    /// @notice Test symmetry: Φ(-x) + Φ(x) = 1
    function test_cdf_symmetry() public pure {
        SD59x18 x = sd(ONE);
        SD59x18 positive = x.cdf();
        SD59x18 negative = sd(-ONE).cdf();

        int256 sum = positive.unwrap() + negative.unwrap();
        assertApproxEqAbs(sum, ONE, TOLERANCE, "CDF(x) + CDF(-x) should equal 1");
    }

    /// @notice Test Φ(1.96) ≈ 0.975 (95% confidence interval)
    function test_cdf_at196() public pure {
        SD59x18 x = sd(1_960000000000000000); // 1.96
        SD59x18 result = x.cdf();
        int256 expected = 975002104851577856; // 0.975...
        assertApproxEqAbs(result.unwrap(), expected, TOLERANCE * 10, "CDF(1.96) should be ~0.975");
    }

    /// @notice Test PDF φ(0) = 1/√(2π) ≈ 0.3989
    function test_pdf_atZero() public pure {
        SD59x18 result = sd(0).pdf();
        int256 expected = 398942280401432678; // 1/√(2π)
        assertApproxEqAbs(result.unwrap(), expected, TOLERANCE, "PDF(0) should be ~0.3989");
    }

    /// @notice Test PDF is symmetric: φ(-x) = φ(x)
    function test_pdf_symmetry() public pure {
        SD59x18 positive = sd(ONE).pdf();
        SD59x18 negative = sd(-ONE).pdf();
        assertApproxEqAbs(positive.unwrap(), negative.unwrap(), TOLERANCE, "PDF should be symmetric");
    }

    /// @notice Fuzz test: CDF output should be in [0, 1]
    function testFuzz_cdf_bounds(int256 x) public pure {
        // Bound input to reasonable range
        x = bound(x, -10e18, 10e18);

        SD59x18 result = sd(x).cdf();
        int256 value = result.unwrap();

        assertGe(value, 0, "CDF should be >= 0");
        assertLe(value, ONE, "CDF should be <= 1");
    }

    /// @notice Fuzz test: CDF should be monotonically increasing
    function testFuzz_cdf_monotonic(int256 x1, int256 x2) public pure {
        x1 = bound(x1, -10e18, 10e18);
        x2 = bound(x2, -10e18, 10e18);

        if (x1 <= x2) {
            SD59x18 result1 = sd(x1).cdf();
            SD59x18 result2 = sd(x2).cdf();
            assertLe(result1.unwrap(), result2.unwrap(), "CDF should be monotonically increasing");
        }
    }
}
CDF_TEST_EOF
}

work_on_generic_issue() {
    local issue_num="$1"
    local title="$2"
    local body="$3"

    log "Working on issue #${issue_num}: $title"
    log "Using Claude Code CLI for senior developer workflow..."

    # Source the LLM generator
    source "$SCRIPT_DIR/llm-generate.sh"

    # Generate code using Claude CLI (this creates multiple commits)
    local result=$(generate_code "$issue_num" "$title" "$body")
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        local impl_path=$(echo "$result" | grep -v "^\[" | tail -1 | cut -d'|' -f1)
        if [[ -n "$impl_path" ]] && [[ -f "$PROJECT_ROOT/$impl_path" ]]; then
            log "Claude CLI successfully generated implementation"

            # Count commits made
            local commit_count=$(git rev-list --count HEAD ^origin/main 2>/dev/null || echo "0")
            log "Created $commit_count commits"

            return 0
        fi
    fi

    log "ERROR: Claude CLI generation failed"
    log "Manual implementation required for issue #${issue_num}"
    return 1
}

# =============================================================================
# Main execution
# =============================================================================

main() {
    setup_environment
    init_state

    log "=== Starting Issue Worker ==="

    # Get next issue to work on
    local issue_json=$(get_next_open_issue)

    if [[ -z "$issue_json" ]]; then
        log "No open issues to work on"
        return 0
    fi

    work_on_issue "$issue_json"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
