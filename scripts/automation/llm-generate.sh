#!/bin/bash

# =============================================================================
# LLM Code Generator - Uses Claude Code CLI for production-quality code
# =============================================================================
# This script runs Claude CLI to implement issues like a senior developer:
# - Multiple incremental commits
# - Real production code (no placeholders)
# - Comprehensive tests (unit + fuzz)
# - Proper NatSpec documentation
#
# KEY: We run Claude CLI WITHOUT --print so it actually executes tools
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

    # Determine file paths based on contract type
    local impl_file="src/libraries/${contract_name}.sol"
    local test_file="test/unit/${contract_name}.t.sol"
    local fuzz_file="test/fuzz/${contract_name}.fuzz.t.sol"

    # Check if it's a core contract vs library
    if echo "$issue_title" | grep -qiE "Vault|Pool|Token|Settlement|Router|Lens|Controller|Oracle|Adapter"; then
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
    local prompt="You are implementing a feature for MantissaFi (DeFi options protocol on Solidity).

## Issue #${issue_num}: ${issue_title}

${issue_body}

## Your Task

Implement this feature with MULTIPLE COMMITS like a senior developer would:

### Commit 1: Core Implementation
Create ${impl_file} with:
- Solidity ^0.8.24
- PRB Math SD59x18 for fixed-point math
- Complete NatSpec documentation
- Custom errors (not require strings)
- NO TODOs or placeholders - implement EVERYTHING

After creating the file, run \`forge build\` to verify, then commit:
\`git add ${impl_file} && git commit -S -m \"feat(${contract_name}): add core implementation\"\`

### Commit 2: Unit Tests
Create ${test_file} with 15-30 unit tests covering:
- All public/external functions
- Edge cases and boundary conditions
- Error conditions (reverts)

Run \`forge test --match-contract ${contract_name}Test\` then commit:
\`git add ${test_file} && git commit -S -m \"test(${contract_name}): add unit tests\"\`

### Commit 3: Fuzz Tests
Create ${fuzz_file} with 5-15 fuzz tests for invariants.

Run \`forge test --match-contract ${contract_name}FuzzTest\` then commit:
\`git add ${fuzz_file} && git commit -S -m \"test(${contract_name}): add fuzz tests\"\`

## Code Style Reference
Study these existing files for style:
- src/libraries/Constants.sol
- src/libraries/CumulativeNormal.sol
- src/libraries/OptionMath.sol

Use: \`import { SD59x18, sd, ZERO } from \"@prb/math/SD59x18.sol\";\`

## IMPORTANT
1. Write REAL, COMPLETE code - no placeholders
2. Each commit must compile and tests must pass
3. Make the commits after each step

Start now."

    echo "========================================" >&2
    echo "Running Claude CLI for ${contract_name}" >&2
    echo "This will create files and make commits" >&2
    echo "========================================" >&2

    # Run Claude CLI WITHOUT --print so it actually executes tools
    # Use --dangerously-skip-permissions to allow writes and bash without prompts
    echo "$prompt" | $claude_cmd \
        --dangerously-skip-permissions \
        2>&1 | tee -a "$LOG_FILE"

    local claude_exit=$?

    # Verify files were created
    if [[ -f "$PROJECT_ROOT/$impl_file" ]]; then
        echo "SUCCESS: Implementation created at $impl_file" >&2

        # Count commits made
        local commit_count=$(git rev-list --count HEAD ^origin/main 2>/dev/null || echo "0")
        echo "Commits created: $commit_count" >&2

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
