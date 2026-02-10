#!/bin/bash

# =============================================================================
# Automation Runner
# 4-Step Cycle: Create Issue → Work on Issue → Review PR → Merge PR
# Runs every 30 minutes, one step per run
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

main() {
    setup_environment
    init_state

    log "=========================================="
    log "$REPO_NAME Automation Runner Started"
    log "=========================================="

    # Get current step in the 4-step cycle
    local last_action=$(get_state "last_action")
    log "Last action was: $last_action"

    case "$last_action" in
        "merge_pr"|"none"|"")
            # Step 1: Create a new issue
            log "Step 1/4: Creating issue..."
            bash "$SCRIPT_DIR/create-issue.sh"
            ;;
        "create_issue")
            # Step 2: Work on issue, open PR (no merge)
            log "Step 2/4: Working on issue, opening PR..."
            bash "$SCRIPT_DIR/work-on-issue.sh"
            ;;
        "work_on_issue")
            # Step 3: Review the PR with comments
            log "Step 3/4: Reviewing PR..."
            bash "$SCRIPT_DIR/review-pr.sh"
            ;;
        "review_pr")
            # Step 4: Merge the PR
            log "Step 4/4: Merging PR..."
            bash "$SCRIPT_DIR/merge-pr.sh"
            ;;
        *)
            log "Unknown last action: $last_action, starting fresh"
            bash "$SCRIPT_DIR/create-issue.sh"
            ;;
    esac

    set_state "last_run" "$(date +%s)"

    log "=========================================="
    log "Automation Runner Completed"
    log "=========================================="
}

# Run with lock to prevent concurrent executions
LOCK_FILE="$PROJECT_ROOT/scripts/automation/.lock"

if [[ -f "$LOCK_FILE" ]]; then
    # Check if lock is stale (older than 30 minutes)
    lock_age=$(($(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)))
    if [[ $lock_age -gt 1800 ]]; then
        log "Removing stale lock file"
        rm -f "$LOCK_FILE"
    else
        log "Another instance is running, exiting"
        exit 0
    fi
fi

# Create lock
echo $$ > "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

main
