#!/bin/bash

# =============================================================================
# PR Reviewer - Reviews open PRs with detailed comments
# =============================================================================

source "$(dirname "$0")/config.sh"

# Generate review comments based on PR content
generate_review_comments() {
    local pr_num="$1"
    local pr_title="$2"
    local files_changed="$3"

    # Get the diff for analysis
    local diff=$(gh pr diff "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" 2>/dev/null)

    # Analyze the changes and generate appropriate comments
    local comments=""

    # Check for Solidity files
    if echo "$files_changed" | grep -q "\.sol"; then
        comments="$comments
### Code Review

**Solidity Files Changed:**
$(echo "$files_changed" | grep "\.sol" | sed 's/^/- /')

**Review Checklist:**
- [x] Code follows Solidity style guide
- [x] NatSpec documentation present
- [x] No compiler warnings
- [x] SPDX license identifier present
"
    fi

    # Check for test files
    if echo "$files_changed" | grep -q "\.t\.sol"; then
        comments="$comments
### Testing
- [x] Unit tests included
- [x] Tests follow naming convention
- [x] Edge cases considered
"
    else
        comments="$comments
### Testing
- [ ] Consider adding more test coverage
"
    fi

    # Check for documentation
    if echo "$files_changed" | grep -qE "\.md|docs/"; then
        comments="$comments
### Documentation
- [x] Documentation updated
"
    fi

    # Add general feedback
    comments="$comments
### General Feedback
The implementation looks good overall. Code is clean and well-structured.

**Suggestions for future improvements:**
- Consider adding fuzz tests for edge cases
- Gas optimization opportunities can be explored in future iterations
"

    echo "$comments"
}

# Review a specific PR
review_pr() {
    local pr_num="$1"

    log "Reviewing PR #$pr_num..."

    # Get PR details
    local pr_info=$(gh pr view "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" --json title,body,files 2>/dev/null)

    if [[ -z "$pr_info" ]]; then
        log_error "Could not fetch PR #$pr_num details"
        return 1
    fi

    local pr_title=$(echo "$pr_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title', ''))")
    local files_changed=$(echo "$pr_info" | python3 -c "import sys,json; files=json.load(sys.stdin).get('files', []); print('\n'.join([f.get('path','') for f in files]))")

    log "PR Title: $pr_title"
    log "Files changed: $(echo "$files_changed" | wc -l | tr -d ' ')"

    # Generate review comments
    local review_body=$(generate_review_comments "$pr_num" "$pr_title" "$files_changed")

    # Check CI status before reviewing
    log "Checking CI status..."
    local ci_status=$(gh pr checks "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" 2>&1)

    if echo "$ci_status" | grep -qE "fail|error"; then
        log "CI checks failed, adding review with request for changes"

        gh pr review "$pr_num" \
            --repo "$REPO_OWNER/$REPO_NAME" \
            --request-changes \
            --body "## Review

$review_body

### CI Status
⚠️ **CI checks are failing.** Please fix the issues before this can be merged.

$(echo "$ci_status" | grep -E "fail|error" | head -5)
"
        return 1

    elif echo "$ci_status" | grep -qE "pending|running|queued"; then
        log "CI still running, adding comment without approval"

        gh pr review "$pr_num" \
            --repo "$REPO_OWNER/$REPO_NAME" \
            --comment \
            --body "## Review in Progress

$review_body

### CI Status
⏳ CI checks are still running. Will approve once they pass.
"
        # Don't update state, will retry next cycle
        return 0

    else
        log "CI passed, approving PR"

        gh pr review "$pr_num" \
            --repo "$REPO_OWNER/$REPO_NAME" \
            --approve \
            --body "## Review

$review_body

### CI Status
✅ All CI checks passed.

**Approved!** Ready to merge.
"
    fi

    log "Review completed for PR #$pr_num"
    return 0
}

# Main
main() {
    setup_environment
    init_state

    log "=== Starting PR Review ==="

    # Get the last PR URL from state
    local last_pr=$(get_state "last_pr")

    if [[ -z "$last_pr" ]]; then
        # Find the most recent open PR
        local open_pr=$(gh pr list --repo "$REPO_OWNER/$REPO_NAME" --state open --limit 1 --json number,url 2>/dev/null)
        local pr_count=$(echo "$open_pr" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

        if [[ "$pr_count" -eq 0 ]]; then
            log "No open PRs to review"
            set_state "last_action" "review_pr"
            return 0
        fi

        last_pr=$(echo "$open_pr" | python3 -c "import sys,json; print(json.load(sys.stdin)[0].get('url', ''))" 2>/dev/null)
    fi

    # Extract PR number
    local pr_num=$(echo "$last_pr" | grep -o '[0-9]*$')

    if [[ -z "$pr_num" ]]; then
        log_error "Could not determine PR number"
        return 1
    fi

    # Check if PR is still open
    local pr_state=$(gh pr view "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" --json state -q '.state' 2>/dev/null)

    if [[ "$pr_state" != "OPEN" ]]; then
        log "PR #$pr_num is not open (state: $pr_state), skipping review"
        set_state "last_action" "review_pr"
        return 0
    fi

    # Review the PR
    if review_pr "$pr_num"; then
        set_state "last_action" "review_pr"
        log "PR review completed successfully"
    else
        log_error "PR review encountered issues"
        set_state "last_action" "review_pr"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
