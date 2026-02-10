# Portable GitHub Automation Agent

A fully automated system that creates GitHub issues from a markdown file and works on them — creating branches, implementing changes, opening PRs, and auto-merging. Runs every 30 minutes with human-like activity (no AI attribution).

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Configuration](#configuration)
4. [ISSUES.md Format](#issuesmd-format)
5. [How It Works](#how-it-works)
6. [Commands Reference](#commands-reference)
7. [Customizing Issue Handlers](#customizing-issue-handlers)
8. [Troubleshooting](#troubleshooting)
9. [Uninstall](#uninstall)

---

## Prerequisites

### Required Tools

```bash
# 1. GitHub CLI (gh)
brew install gh          # macOS
sudo apt install gh      # Ubuntu/Debian

# 2. Authenticate GitHub CLI
gh auth login

# 3. Python 3
python3 --version        # Should be 3.x

# 4. Git configured with your identity
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

### Optional (Recommended)

```bash
# direnv - for per-project GitHub tokens
brew install direnv      # macOS
sudo apt install direnv  # Ubuntu/Debian

# Add to ~/.zshrc or ~/.bashrc:
eval "$(direnv hook zsh)"   # or bash
```

---

## Installation

### Step 1: Copy Automation Scripts

Copy the `scripts/automation/` folder to your project:

```bash
# From this repo
cp -r scripts/automation/ /path/to/your/project/scripts/automation/
```

Or clone and copy:

```bash
git clone <this-repo>
cp -r <this-repo>/scripts/automation/ /path/to/your/project/scripts/automation/
```

### Step 2: Make Scripts Executable

```bash
cd /path/to/your/project
chmod +x scripts/automation/*.sh
```

### Step 3: Create ISSUES.md

Create an `ISSUES.md` file in your project root (see [format below](#issuesmd-format)).

### Step 4: Set Up GitHub Token (Optional but Recommended)

For per-project GitHub authentication:

```bash
# Create token file in project root
echo "ghp_your_github_token_here" > .github_token
chmod 600 .github_token

# Create .envrc for direnv
cat > .envrc << 'EOF'
if [[ -f .github_token ]]; then
    export GH_TOKEN=$(cat .github_token)
    export GITHUB_TOKEN=$GH_TOKEN
fi
EOF

# Allow direnv
direnv allow
```

### Step 5: Install the Automation Agent

```bash
./scripts/automation/setup-cron.sh
```

This will:
- **macOS**: Create a launchd agent (`~/Library/LaunchAgents/com.<reponame>.automation.plist`)
- **Linux**: Create a cron job

### Step 6: Verify Installation

```bash
# macOS
launchctl list | grep automation

# Linux
crontab -l | grep automation
```

---

## Configuration

Edit `scripts/automation/config.sh` to customize:

```bash
# Automation behavior
AUTO_MERGE="true"          # Auto-merge PRs after creation
CREATE_LABELS="true"       # Create missing GitHub labels
MAX_ISSUES_PER_RUN="1"     # Issues to create per run
MAX_PRS_TO_MERGE="1"       # PRs to merge per run

# Commit options
DATE_OFFSET_DAYS="0"       # Backdate commits (0 = today)

# These are auto-detected (no need to change):
# PROJECT_ROOT    - detected from script location
# REPO_OWNER      - detected from git remote
# REPO_NAME       - detected from git remote
```

---

## ISSUES.md Format

Create `ISSUES.md` in your project root with this format:

```markdown
# Project Issues Tracker

---

## Milestone: `M1 — First Milestone`

---

### Issue #1: Your first issue title
**Labels:** `enhancement`, `priority: high`
**Milestone:** M1 — First Milestone

**Description:**
Detailed description of what needs to be done.

**Tasks:**
- [ ] Task 1
- [ ] Task 2
- [ ] Task 3

**Acceptance Criteria:**
- Criterion 1
- Criterion 2

---

### Issue #2: Second issue title
**Labels:** `documentation`, `good first issue`
**Milestone:** M1 — First Milestone

**Description:**
Another description here.

---

### Issue #3: Third issue
**Labels:** `bug`, `priority: critical`
**Milestone:** M2 — Second Milestone

**Description:**
Bug fix description.

---
```

### Label Colors (Auto-Created)

| Label Pattern | Color |
|---------------|-------|
| `*critical*` | Red (#D93F0B) |
| `*high*` | Light Red (#FF6B6B) |
| `*security*` | Red (#D93F0B) |
| `*documentation*` | Blue (#0075CA) |
| `*setup*` | Light Green (#C2E0C6) |
| `*math*` | Purple (#5319E7) |
| `*core*` | Yellow (#FEF2C0) |
| `*devops*` | Teal (#006B75) |
| Default | Green (#0E8A16) |

---

## How It Works

### Automation Cycle

The agent alternates every 30 minutes:

```
┌─────────────────┐     ┌─────────────────┐
│  Create Issue   │ ──► │  Work on Issue  │
│  from ISSUES.md │     │  Branch→PR→Merge│
└─────────────────┘     └─────────────────┘
         ▲                       │
         └───────────────────────┘
              (next 30 min)
```

### Detailed Flow

**Create Issue Phase:**
1. Parse `ISSUES.md` for all issues
2. Check GitHub for existing issues (by title)
3. Create the next missing issue
4. Create any missing labels

**Work on Issue Phase:**
1. Find oldest open issue
2. Create feature branch: `feat/issue-{num}-{slug}` or `docs/issue-{num}-{slug}`
3. Implement changes (based on issue type)
4. Commit with conventional commit message
5. Push branch
6. Create PR with professional description
7. Auto-merge PR
8. Close issue
9. Pull latest main

### File Structure

```
your-project/
├── ISSUES.md                    # Your issues definition
├── .github_token                # GitHub token (optional)
├── .envrc                       # direnv config (optional)
└── scripts/
    └── automation/
        ├── config.sh            # Configuration (auto-detects paths)
        ├── run.sh               # Main orchestrator
        ├── create-issue.sh      # Creates GitHub issues
        ├── work-on-issue.sh     # Implements & creates PRs
        ├── issue-parser.sh      # Parses ISSUES.md
        ├── setup-cron.sh        # Installs cron/launchd
        ├── .state               # Current state (auto-generated)
        ├── automation.log       # Logs (auto-generated)
        └── README.md            # This file
```

---

## Commands Reference

### Manual Execution

```bash
# Run one cycle (will alternate action automatically)
./scripts/automation/run.sh

# Force create issue
echo "last_action=work_on_issue" > scripts/automation/.state
./scripts/automation/run.sh

# Force work on issue
echo "last_action=create_issue" > scripts/automation/.state
./scripts/automation/run.sh

# Run individual scripts
./scripts/automation/create-issue.sh
./scripts/automation/work-on-issue.sh
```

### Monitoring

```bash
# Watch live logs
tail -f scripts/automation/automation.log

# Check current state
cat scripts/automation/.state

# Check agent status (macOS)
launchctl list | grep automation

# Check cron (Linux)
crontab -l | grep automation
```

### Control Agent

```bash
# Stop (macOS)
launchctl unload ~/Library/LaunchAgents/com.*.automation.plist

# Start (macOS)
launchctl load ~/Library/LaunchAgents/com.*.automation.plist

# Restart (macOS)
launchctl unload ~/Library/LaunchAgents/com.*.automation.plist
launchctl load ~/Library/LaunchAgents/com.*.automation.plist
```

---

## Customizing Issue Handlers

The `work-on-issue.sh` script has handlers for different issue types. To add custom handlers:

1. Open `scripts/automation/work-on-issue.sh`
2. Find the `implement_issue()` function
3. Add a case for your issue type:

```bash
implement_issue() {
    local issue_number="$1"
    local issue_title="$2"

    # Add your custom handler
    if [[ "$issue_title" == *"YourKeyword"* ]]; then
        log "Working on YourKeyword..."
        # Create/modify files here
        cat > "src/YourFile.sol" << 'EOF'
// Your implementation
EOF
        return 0
    fi

    # ... existing handlers ...
}
```

---

## Troubleshooting

### Agent Not Running

```bash
# Check if loaded (macOS)
launchctl list | grep automation

# Check logs
tail -50 scripts/automation/automation.log

# Test manually
./scripts/automation/run.sh
```

### GitHub Authentication Issues

```bash
# Check gh auth
gh auth status

# Re-authenticate
gh auth login

# Check token (if using direnv)
echo $GH_TOKEN
```

### "No new issues to create"

- Check `ISSUES.md` format matches expected pattern
- Verify issues aren't already created on GitHub:
  ```bash
  gh issue list --state all
  ```

### Permission Denied

```bash
chmod +x scripts/automation/*.sh
```

### Wrong Git Identity

```bash
# Check current identity
git config user.name
git config user.email

# Set for this repo only
git config user.name "Your Name"
git config user.email "your@email.com"
```

### macOS: "Operation not permitted" for cron

Use launchd instead (the setup script does this automatically on macOS).

---

## Uninstall

### macOS (launchd)

```bash
# Stop and remove agent
launchctl unload ~/Library/LaunchAgents/com.*.automation.plist
rm ~/Library/LaunchAgents/com.*.automation.plist

# Remove scripts (optional)
rm -rf scripts/automation/
```

### Linux (cron)

```bash
# Edit crontab and remove automation lines
crontab -e

# Remove scripts (optional)
rm -rf scripts/automation/
```

---

## Notes

- **Sleep Mode**: Agent pauses when system sleeps (macOS/Linux). Missed runs don't stack.
- **No AI Attribution**: All commits and PRs appear as regular human activity.
- **Safe**: Won't create duplicate issues (checks by title).
- **Idempotent**: Safe to run multiple times manually.
- **Portable**: Auto-detects project root, repo owner, and repo name from git remote.

---

## License

MIT
