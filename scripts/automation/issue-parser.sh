#!/bin/bash

# =============================================================================
# Issue Parser - Extracts issues from ISSUES.md
# =============================================================================

source "$(dirname "$0")/config.sh"

# Parse ISSUES.md and extract issue data using Python for reliability
parse_issues_file() {
    ISSUES_PATH="$ISSUES_FILE" python3 << 'PYTHON_EOF'
import re
import json
import sys
import os

issues_file = os.environ.get('ISSUES_PATH', 'ISSUES.md')

try:
    with open(issues_file, 'r') as f:
        content = f.read()
except FileNotFoundError:
    print("[]")
    sys.exit(0)

issues = []
# Match issue blocks
pattern = r'### Issue #(\d+): (.+?)\n\*\*Labels:\*\* (.+?)\n\*\*Milestone:\*\* (.+?)\n\n\*\*Description:\*\*\n(.*?)(?=\n---|\n### Issue #|\Z)'

matches = re.findall(pattern, content, re.DOTALL)

for match in matches:
    issue_num, title, labels, milestone, body = match
    # Clean up labels
    labels = labels.replace('`', '').replace(',', ' ').strip()
    # Clean up body
    body = body.strip()

    issues.append({
        "number": int(issue_num),
        "title": title.strip(),
        "labels": labels,
        "milestone": milestone.strip(),
        "body": body
    })

print(json.dumps(issues))
PYTHON_EOF
}

# Get next issue to create (not yet created on GitHub)
get_next_issue_to_create() {
    # Get list of existing issues from GitHub
    local existing_titles=$(gh issue list --repo "$REPO_OWNER/$REPO_NAME" --state all --limit 100 --json title 2>/dev/null | python3 -c "import sys,json; [print(i.get('title','')) for i in json.load(sys.stdin)]" 2>/dev/null)

    # Parse issues from file
    local parsed_issues=$(parse_issues_file)

    # Find first issue not yet created
    echo "$parsed_issues" | python3 -c "
import sys
import json

issues = json.load(sys.stdin)
existing = '''$existing_titles'''.strip().split('\n')

for issue in issues:
    title = issue.get('title', '')
    # Check if this issue title already exists (partial match)
    exists = any(title.lower() in e.lower() or e.lower() in title.lower() for e in existing if e)
    if not exists:
        print(json.dumps(issue))
        break
" 2>/dev/null | head -1
}

# Create labels if they don't exist
ensure_labels_exist() {
    local labels="$1"

    for label in $labels; do
        # Clean label
        label=$(echo "$label" | tr -d '`"' | xargs)

        [[ -z "$label" ]] && continue

        # Check if label exists
        if ! gh label list --repo "$REPO_OWNER/$REPO_NAME" 2>/dev/null | grep -q "^$label"; then
            # Create label with appropriate color
            local color="0E8A16"  # Default green
            case "$label" in
                *critical*) color="D93F0B" ;;
                *high*) color="FF6B6B" ;;
                *security*) color="D93F0B" ;;
                *bug*|*fix*) color="D73A4A" ;;
                *feature*|*feat*) color="0E8A16" ;;
                *docs*|*documentation*) color="0075CA" ;;
                *test*) color="BFD4F2" ;;
                *setup*) color="C2E0C6" ;;
                *math*) color="5319E7" ;;
                *core*) color="FEF2C0" ;;
                *devops*) color="006B75" ;;
            esac

            gh label create "$label" --color "$color" --repo "$REPO_OWNER/$REPO_NAME" 2>/dev/null || true
            log "Created label: $label"
        fi
    done
}

# Main function to test parser
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_environment
    init_state

    echo "Parsing ISSUES.md..."
    parse_issues_file | python3 -m json.tool 2>/dev/null || parse_issues_file

    echo ""
    echo "Next issue to create:"
    get_next_issue_to_create | python3 -m json.tool 2>/dev/null || get_next_issue_to_create
fi
