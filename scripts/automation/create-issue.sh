#!/bin/bash

# =============================================================================
# Issue Creator - Creates GitHub issues from ISSUES.md
# =============================================================================

source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/issue-parser.sh"

create_next_issue() {
    log "Starting issue creation..."

    # Get next issue to create (JSON string)
    local issue_json=$(get_next_issue_to_create)

    if [[ -z "$issue_json" ]] || [[ "$issue_json" == "null" ]]; then
        log "No new issues to create"
        return 0
    fi

    # Extract fields using Python for reliable JSON parsing
    local title=$(echo "$issue_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title', ''))")
    local labels=$(echo "$issue_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('labels', ''))")
    local body=$(echo "$issue_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('body', ''))")
    local number=$(echo "$issue_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('number', 0))")

    if [[ -z "$title" ]]; then
        log "Could not extract issue title"
        return 1
    fi

    log "Creating issue #$number: $title"

    # Create labels if they don't exist (only the actual labels, not the body)
    if [[ "$CREATE_LABELS" == "true" ]]; then
        # Split labels by spaces and filter valid ones
        for label in $labels; do
            label=$(echo "$label" | tr -d '`",' | xargs)
            [[ -z "$label" ]] && continue
            [[ "$label" == "priority:" ]] && continue

            # Check and create label
            if ! gh label list --repo "$REPO_OWNER/$REPO_NAME" 2>/dev/null | grep -q "^$label"; then
                local color="0E8A16"
                case "$label" in
                    *critical*) color="D93F0B" ;;
                    *high*) color="FF6B6B" ;;
                    *security*) color="D93F0B" ;;
                    *documentation*) color="0075CA" ;;
                    *setup*) color="C2E0C6" ;;
                    *math*) color="5319E7" ;;
                    *core*) color="FEF2C0" ;;
                    *devops*) color="006B75" ;;
                esac
                gh label create "$label" --color "$color" --repo "$REPO_OWNER/$REPO_NAME" 2>/dev/null || true
                log "Created label: $label"
            fi
        done
    fi

    # Build label arguments for gh CLI
    local label_args=""
    for label in $labels; do
        label=$(echo "$label" | tr -d '`",' | xargs)
        [[ -z "$label" ]] && continue
        [[ "$label" == "priority:" ]] && continue
        label_args="$label_args --label $label"
    done

    # Create full issue body
    local full_body="## Description

$body

---
*Part of the $REPO_NAME development roadmap.*"

    # Create the issue
    local result
    result=$(gh issue create \
        --repo "$REPO_OWNER/$REPO_NAME" \
        --title "$title" \
        $label_args \
        --body "$full_body" 2>&1)

    if [[ $? -eq 0 ]]; then
        log "Successfully created issue: $result"
        set_state "last_issue_created" "$number"
        set_state "last_action" "create_issue"
        return 0
    else
        log_error "Failed to create issue: $result"
        return 1
    fi
}

# Main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_environment
    init_state
    create_next_issue
fi
