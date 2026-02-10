#!/bin/bash

# =============================================================================
# LLM Code Generator - Uses Claude Code CLI for production-quality code
# =============================================================================
# This script runs Claude CLI to implement issues like a senior developer:
# - Multiple incremental commits
# - Real production code (no placeholders)
# - Comprehensive tests (unit + fuzz)
# - Proper NatSpec documentation
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Generate code using Claude Code CLI with senior developer workflow
generate_code() {
    local issue_num="$1"
    local issue_title="$2"
    local issue_body="$3"

    # Extract contract name from issue title
    # Pattern: "Implement `ContractName.sol` — description"
    local contract_name=$(echo "$issue_title" | sed -nE 's/.*`([A-Za-z0-9]+)\.sol`.*/\1/p')
    if [[ -z "$contract_name" ]]; then
        contract_name=$(echo "$issue_title" | sed 's/Implement //' | sed 's/ —.*$//' | sed 's/\.sol$//' | tr -cd 'A-Za-z0-9')
    fi

    local filename=$(echo "$contract_name" | tr '[:upper:]' '[:lower:]')
    local impl_file="src/libraries/${contract_name}.sol"
    local test_file="test/unit/${contract_name}.t.sol"
    local fuzz_file="test/fuzz/${contract_name}.fuzz.t.sol"

    # Check if it's a core contract vs library
    if echo "$issue_title" | grep -qiE "Vault|Pool|Token|Settlement|Router|Lens|Controller|Oracle"; then
        impl_file="src/core/${contract_name}.sol"
    fi

    # Find claude CLI
    local claude_cmd=""
    if command -v claude &> /dev/null; then
        claude_cmd="claude"
    elif [[ -x "/opt/homebrew/bin/claude" ]]; then
        claude_cmd="/opt/homebrew/bin/claude"
    elif [[ -x "/usr/local/bin/claude" ]]; then
        claude_cmd="/usr/local/bin/claude"
    else
        echo "ERROR: Claude Code CLI not found" >&2
        return 1
    fi

    # Create the prompt for senior developer workflow
    local prompt="You are a senior Solidity developer implementing a feature for MantissaFi (DeFi options protocol).

## Issue #${issue_num}: ${issue_title}

${issue_body}

## Your Task

Implement this feature following these steps with MULTIPLE COMMITS like a senior developer:

### Step 1: Create Core Implementation
- Create ${impl_file} with the main contract/library
- Use Solidity ^0.8.24 and PRB Math SD59x18 for fixed-point
- Add complete NatSpec documentation (@notice, @dev, @param, @return)
- Use custom errors (not require strings)
- NO TODOs or placeholders - implement everything fully

After creating the implementation file, run:
\`\`\`bash
forge build
git add ${impl_file}
git commit -S -m \"feat(${contract_name}): add core implementation

Implement main functionality for ${contract_name}.
Part of #${issue_num}\"
\`\`\`

### Step 2: Create Unit Tests
- Create ${test_file} with comprehensive unit tests
- Test all functions with various scenarios (normal, edge cases, error conditions)
- Use descriptive test names (test_functionName_scenario)
- Aim for 15-30 unit tests covering all code paths

After creating unit tests, run:
\`\`\`bash
forge test --match-contract ${contract_name}Test
git add ${test_file}
git commit -S -m \"test(${contract_name}): add unit tests

Add comprehensive unit tests covering:
- Normal operation scenarios
- Edge cases and boundary conditions
- Error handling and reverts

Part of #${issue_num}\"
\`\`\`

### Step 3: Create Fuzz Tests
- Create ${fuzz_file} with fuzz tests for invariants
- Test mathematical properties that should always hold
- Use bound() to constrain inputs to valid ranges
- Aim for 5-15 fuzz tests

After creating fuzz tests, run:
\`\`\`bash
forge test --match-contract ${contract_name}FuzzTest
git add ${fuzz_file}
git commit -S -m \"test(${contract_name}): add fuzz tests

Add fuzz tests verifying mathematical invariants.
Part of #${issue_num}\"
\`\`\`

### Step 4: Final Verification
Run all tests to verify everything works:
\`\`\`bash
forge test --match-path \"test/**/${contract_name}*\"
\`\`\`

## Important Guidelines

1. Study existing code style in src/libraries/Constants.sol and src/libraries/CumulativeNormal.sol
2. Use SD59x18 from @prb/math for all fixed-point math
3. Follow the same import patterns: \`import { SD59x18, sd, ZERO } from \"@prb/math/SD59x18.sol\";\`
4. Make each commit independently buildable
5. Write REAL production code - no placeholders, no TODOs
6. All tests must pass before each commit

Start implementing now. Create the files and make the commits."

    echo "Running Claude CLI for ${contract_name} implementation..." >&2
    echo "This will create multiple commits as a senior developer would..." >&2

    # Run Claude CLI with the prompt
    # Use --dangerously-skip-permissions to allow file writes and git commits
    echo "$prompt" | $claude_cmd \
        --print \
        --dangerously-skip-permissions \
        2>&1 | tee -a "$LOG_FILE" >&2

    local claude_exit=$?

    # Check if files were created
    if [[ -f "$PROJECT_ROOT/$impl_file" ]]; then
        echo "SUCCESS: Implementation created at $impl_file" >&2

        # Return the paths
        echo "$impl_file|$test_file|$fuzz_file"
        return 0
    else
        echo "ERROR: Implementation file not created at $impl_file" >&2
        return 1
    fi
}

# Main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 3 ]]; then
        echo "Usage: $0 <issue_num> <issue_title> <issue_body>"
        exit 1
    fi
    setup_environment
    generate_code "$1" "$2" "$3"
fi
