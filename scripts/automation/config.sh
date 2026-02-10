#!/bin/bash

# =============================================================================
# Automation Configuration
# =============================================================================

# Auto-detect project root (two levels up from this script)
# Handle both sourced and executed cases
if [[ -n "${BASH_SOURCE[0]}" ]]; then
    _config_path="${BASH_SOURCE[0]}"
else
    _config_path="$0"
fi
# Convert to absolute path if relative
if [[ "$_config_path" != /* ]]; then
    _config_path="$(pwd)/$_config_path"
fi
SCRIPT_DIR="$(cd "$(dirname "$_config_path")" && pwd)"
export PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Auto-detect repo owner and name from git remote
_get_repo_info() {
    local remote_url=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null)
    # Extract owner/repo from various URL formats using sed
    # Handles: git@github.com:owner/repo.git, https://github.com/owner/repo.git, git@github.com-alias:owner/repo.git
    echo "$remote_url" | sed -E 's/.*[:/]([^/]+)\/([^/.]+)(\.git)?$/\1 \2/'
}
read -r REPO_OWNER REPO_NAME <<< "$(_get_repo_info)"
export REPO_OWNER
export REPO_NAME
export DEFAULT_BRANCH="main"

# File paths
export ISSUES_FILE="$PROJECT_ROOT/ISSUES.md"
export STATE_FILE="$PROJECT_ROOT/scripts/automation/.state"
export LOG_FILE="$PROJECT_ROOT/scripts/automation/automation.log"

# Automation settings
export AUTO_MERGE="true"
export CREATE_LABELS="true"
export MAX_ISSUES_PER_RUN="1"
export MAX_PRS_TO_MERGE="1"
export REQUIRE_APPROVAL="false"  # Set to "true" for team workflows

# Commit date offset (days back for realistic commit history)
export DATE_OFFSET_DAYS="0"

# Git identity (loaded from .github_token or direnv)
# Line 4 of .github_token = GIT_USER_NAME
# Line 5 of .github_token = GIT_USER_EMAIL

# Logging
log() {
    rotate_logs_if_needed
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# Log rotation - zip every 12 hours, delete older than 7 days
rotate_logs_if_needed() {
    local log_dir="$(dirname "$LOG_FILE")"
    local rotation_marker="$log_dir/.last_rotation"
    local current_time=$(date +%s)
    local twelve_hours=43200  # 12 * 60 * 60
    local seven_days=604800   # 7 * 24 * 60 * 60

    # Check if rotation is needed (every 12 hours)
    if [[ -f "$rotation_marker" ]]; then
        local last_rotation=$(cat "$rotation_marker" 2>/dev/null || echo "0")
        local time_diff=$((current_time - last_rotation))

        if [[ $time_diff -lt $twelve_hours ]]; then
            return 0  # No rotation needed
        fi
    fi

    # Rotate current log if it exists and has content
    if [[ -f "$LOG_FILE" ]] && [[ -s "$LOG_FILE" ]]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local archive_name="automation_${timestamp}.log"

        # Move current log to archive
        mv "$LOG_FILE" "$log_dir/$archive_name"

        # Compress the archive
        gzip "$log_dir/$archive_name" 2>/dev/null

        # Create new empty log file
        touch "$LOG_FILE"
    fi

    # Delete logs older than 7 days
    find "$log_dir" -name "automation_*.log.gz" -type f -mtime +7 -delete 2>/dev/null
    find "$log_dir" -name "automation_*.log" -type f -mtime +7 -delete 2>/dev/null

    # Update rotation marker
    echo "$current_time" > "$rotation_marker"
}

# State management
get_state() {
    local key="$1"
    grep "^$key=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2
}

set_state() {
    local key="$1"
    local value="$2"

    if grep -q "^$key=" "$STATE_FILE" 2>/dev/null; then
        # Use | as delimiter to handle URLs with slashes
        sed -i '' "s|^$key=.*|$key=$value|" "$STATE_FILE"
    else
        echo "$key=$value" >> "$STATE_FILE"
    fi
}

# Initialize state file
init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "last_action=none" > "$STATE_FILE"
        echo "last_issue_created=0" >> "$STATE_FILE"
        echo "last_run=$(date +%s)" >> "$STATE_FILE"
    fi
}

# Change to project directory and load direnv
setup_environment() {
    cd "$PROJECT_ROOT" || exit 1
    eval "$(direnv export bash 2>/dev/null)"

    # Switch to correct GitHub account for this project
    setup_gh_auth

    # Configure commit signing if SSH key is available
    setup_commit_signing
}

# Setup gh CLI authentication from project's .github_token file
setup_gh_auth() {
    local token=""
    local token_file=""

    # Priority 1: Check project root
    if [[ -f "$PROJECT_ROOT/.github_token" ]]; then
        token_file="$PROJECT_ROOT/.github_token"
    # Priority 2: Check parent directory (shared token for multiple projects)
    elif [[ -f "$PROJECT_ROOT/../.github_token" ]]; then
        token_file="$PROJECT_ROOT/../.github_token"
    fi

    if [[ -n "$token_file" ]]; then
        # Read token from first line
        token=$(head -1 "$token_file" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$token" ]]; then
            export GH_TOKEN="$token"
            log "Using GitHub token from $token_file"
            return 0
        fi
    fi

    log "WARNING: No .github_token file found"
    log "Create .github_token with your GitHub personal access token"
}

# Setup commit signing for verified commits
setup_commit_signing() {
    # Check if signing is already configured
    if git config --get commit.gpgsign >/dev/null 2>&1; then
        return 0
    fi

    # Try to find SSH key for signing
    local ssh_key=""
    local remote_url=$(git remote get-url origin 2>/dev/null)
    local github_token_file="$PROJECT_ROOT/.github_token"

    # Priority 1: Read SSH key path from .github_token file (third line if exists)
    if [[ -f "$github_token_file" ]]; then
        local key_from_file=$(sed -n '3p' "$github_token_file" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$key_from_file" ]] && [[ -f "$key_from_file" ]]; then
            ssh_key="$key_from_file"
        fi
    fi

    # Priority 2: Extract account from remote URL and find matching SSH key
    if [[ -z "$ssh_key" ]]; then
        local account_name=$(echo "$remote_url" | sed -nE 's/.*github\.com-([^:]+):.*/\1/p')
        if [[ -n "$account_name" ]] && [[ -f "$HOME/.ssh/$account_name" ]]; then
            ssh_key="$HOME/.ssh/$account_name"
        fi
    fi

    # Priority 3: Default SSH keys
    if [[ -z "$ssh_key" ]]; then
        if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
            ssh_key="$HOME/.ssh/id_ed25519"
        elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
            ssh_key="$HOME/.ssh/id_rsa"
        fi
    fi

    if [[ -n "$ssh_key" ]] && [[ -f "$ssh_key" ]]; then
        # Configure SSH signing for this repo
        git config --local gpg.format ssh
        git config --local user.signingkey "$ssh_key"
        git config --local commit.gpgsign true
        log "Configured SSH commit signing with key: $ssh_key"
    else
        log "WARNING: No SSH key found for commit signing"
    fi
}
