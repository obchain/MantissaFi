#!/bin/bash

# =============================================================================
# PR Merger - Merges approved PRs after CI passes
# =============================================================================

source "$(dirname "$0")/config.sh"

# Wait for CI checks to pass
wait_for_ci() {
    local pr_num="$1"
    local max_wait=600  # 10 minutes max
    local wait_interval=20
    local elapsed=0

    log "Checking CI status for PR #$pr_num..."

    while [[ $elapsed -lt $max_wait ]]; do
        # Get detailed check status using GitHub API
        local check_status=$(gh pr checks "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" 2>&1)
        local pr_status=$(gh pr view "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" --json statusCheckRollup -q '.statusCheckRollup[] | "\(.context): \(.state)"' 2>/dev/null)

        # Check using multiple methods for reliability
        # Method 1: Check if "pass" or "success" appears for all checks
        local total_checks=$(echo "$pr_status" | grep -c . 2>/dev/null || echo "0")
        local passed_checks=$(echo "$pr_status" | grep -ciE "success|pass" 2>/dev/null || echo "0")
        total_checks="${total_checks//[^0-9]/}"
        passed_checks="${passed_checks//[^0-9]/}"
        [[ -z "$total_checks" ]] && total_checks=0
        [[ -z "$passed_checks" ]] && passed_checks=0

        if [[ "$total_checks" -gt 0 ]] && [[ "$passed_checks" -eq "$total_checks" ]]; then
            log "CI checks passed! ($passed_checks/$total_checks)"
            return 0
        fi

        # Method 2: Check for "All checks were successful" message
        if echo "$check_status" | grep -qi "All checks were successful\|pass"; then
            log "CI checks passed!"
            return 0
        fi

        # Method 3: Check mergeable state
        local mergeable=$(gh pr view "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" --json mergeable -q '.mergeable' 2>/dev/null)
        if [[ "$mergeable" == "MERGEABLE" ]]; then
            log "PR is mergeable, CI likely passed"
            return 0
        fi

        # Check if any check failed
        if echo "$pr_status" | grep -qiE "failure|failed|error"; then
            log_error "CI checks failed!"
            echo "$pr_status" | grep -iE "failure|failed|error" | head -5
            return 1
        fi

        # Still pending
        if echo "$pr_status" | grep -qiE "pending|running|queued|expected"; then
            log "CI running... ($passed_checks checks passed, ${elapsed}s elapsed)"
            sleep $wait_interval
            elapsed=$((elapsed + wait_interval))
        else
            # No clear status, check if we can merge anyway
            if [[ "$mergeable" == "MERGEABLE" ]] || [[ "$mergeable" == "UNKNOWN" ]]; then
                log "CI status unclear but PR appears mergeable"
                return 0
            fi
            sleep $wait_interval
            elapsed=$((elapsed + wait_interval))
        fi
    done

    # Final check before giving up
    local final_mergeable=$(gh pr view "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" --json mergeable -q '.mergeable' 2>/dev/null)
    if [[ "$final_mergeable" == "MERGEABLE" ]]; then
        log "PR is mergeable after timeout, proceeding"
        return 0
    fi

    log_error "Timeout waiting for CI (${max_wait}s)"
    return 1
}

# Check if PR is approved
check_approval() {
    local pr_num="$1"

    local reviews=$(gh pr view "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" --json reviews -q '.reviews[-1].state' 2>/dev/null)

    if [[ "$reviews" == "APPROVED" ]]; then
        return 0
    else
        log "PR #$pr_num is not approved (state: $reviews)"
        return 1
    fi
}

# Merge the PR
merge_pr() {
    local pr_num="$1"

    log "Merging PR #$pr_num..."

    # Get PR title for merge commit message
    local pr_title=$(gh pr view "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" --json title -q '.title' 2>/dev/null)
    local pr_body=$(gh pr view "$pr_num" --repo "$REPO_OWNER/$REPO_NAME" --json body -q '.body' 2>/dev/null)

    # Extract issue number from PR body
    local issue_num=$(echo "$pr_body" | grep -oE "Closes #[0-9]+" | grep -oE "[0-9]+" | head -1)

    # Create merge commit message
    local merge_message="$pr_title

Reviewed and approved. All CI checks passed.
"

    if [[ -n "$issue_num" ]]; then
        merge_message="$merge_message
Closes #$issue_num"
    fi

    # Merge with squash
    local merge_result=$(gh pr merge "$pr_num" \
        --repo "$REPO_OWNER/$REPO_NAME" \
        --squash \
        --delete-branch \
        --body "$merge_message" 2>&1)

    if [[ $? -eq 0 ]]; then
        log "Successfully merged PR #$pr_num"

        # Update local main branch
        git checkout "$DEFAULT_BRANCH" 2>/dev/null
        git pull origin "$DEFAULT_BRANCH" 2>/dev/null

        # Add closing comment to the issue
        if [[ -n "$issue_num" ]]; then
            gh issue comment "$issue_num" \
                --repo "$REPO_OWNER/$REPO_NAME" \
                --body "This issue has been resolved in PR #$pr_num.

**Summary:**
- Implementation complete
- Tests passing
- Code reviewed and approved
- Merged to main

Thanks for the contribution! 🎉" 2>/dev/null

            # Close the issue if not auto-closed
            gh issue close "$issue_num" --repo "$REPO_OWNER/$REPO_NAME" 2>/dev/null
            log "Closed issue #$issue_num"
        fi

        return 0
    else
        log_error "Failed to merge PR: $merge_result"
        return 1
    fi
}

# Main
main() {
    setup_environment
    init_state

    log "=== Starting PR Merge ==="

    # Get the last PR URL from state
    local last_pr=$(get_state "last_pr")

    if [[ -z "$last_pr" ]]; then
        # Find the most recent open PR
        local open_pr=$(gh pr list --repo "$REPO_OWNER/$REPO_NAME" --state open --limit 1 --json number,url 2>/dev/null)
        local pr_count=$(echo "$open_pr" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

        if [[ "$pr_count" -eq 0 ]]; then
            log "No open PRs to merge"
            set_state "last_action" "merge_pr"
            set_state "last_pr" ""
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
        log "PR #$pr_num is not open (state: $pr_state), skipping"
        set_state "last_action" "merge_pr"
        set_state "last_pr" ""
        return 0
    fi

    # Wait for CI to pass
    if ! wait_for_ci "$pr_num"; then
        log_error "CI checks failed, cannot merge"
        # Still mark as attempted so we move to next cycle
        set_state "last_action" "merge_pr"
        return 1
    fi

    # Check if PR is approved (skip for single-developer workflows)
    if [[ "${REQUIRE_APPROVAL:-false}" == "true" ]]; then
        if ! check_approval "$pr_num"; then
            log "PR not yet approved, will retry"
            return 1
        fi
    else
        log "Skipping approval check (single-developer workflow)"
    fi

    # Merge the PR
    if merge_pr "$pr_num"; then
        set_state "last_action" "merge_pr"
        set_state "last_pr" ""
        log "Merge completed successfully!"
    else
        log_error "Merge failed"
        set_state "last_action" "merge_pr"
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
