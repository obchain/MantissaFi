#!/bin/bash

# =============================================================================
# Setup Automation - Portable setup for cron (Linux) or launchd (macOS)
# Runs every 30 minutes
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_SCRIPT="$SCRIPT_DIR/run.sh"

# Auto-detect repo name from git
REPO_NAME=$(basename "$PROJECT_ROOT")

# Make scripts executable
chmod +x "$SCRIPT_DIR"/*.sh

echo "Setting up automation for: $REPO_NAME"
echo "Project root: $PROJECT_ROOT"
echo ""

# Detect platform
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - use launchd
    PLIST_NAME="com.${REPO_NAME,,}.automation"
    PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

    echo "Platform: macOS (using launchd)"
    echo ""

    # Unload existing if present
    launchctl unload "$PLIST_PATH" 2>/dev/null

    # Generate plist
    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$RUN_SCRIPT</string>
    </array>
    <key>StartInterval</key>
    <integer>1800</integer>
    <key>WorkingDirectory</key>
    <string>$PROJECT_ROOT</string>
    <key>StandardOutPath</key>
    <string>$SCRIPT_DIR/automation.log</string>
    <key>StandardErrorPath</key>
    <string>$SCRIPT_DIR/automation.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF

    # Load the agent
    launchctl load "$PLIST_PATH"

    echo "Launchd agent installed!"
    echo ""
    echo "Status:"
    launchctl list | grep "$REPO_NAME" || echo "  (will start on next interval)"
    echo ""
    echo "Commands:"
    echo "  Stop:   launchctl unload $PLIST_PATH"
    echo "  Start:  launchctl load $PLIST_PATH"
    echo "  Logs:   tail -f $SCRIPT_DIR/automation.log"
    echo "  Manual: $RUN_SCRIPT"

else
    # Linux - use cron
    echo "Platform: Linux (using cron)"
    echo ""

    CRON_ENTRY="*/30 * * * * cd $SCRIPT_DIR && ./run.sh >> automation.log 2>&1"
    CRON_MARKER="# $REPO_NAME Automation"

    # Remove existing entry if present
    if crontab -l 2>/dev/null | grep -q "$REPO_NAME"; then
        echo "Updating existing cron job..."
        crontab -l | grep -v "$REPO_NAME" | crontab -
    fi

    # Add new cron entry
    (crontab -l 2>/dev/null; echo "$CRON_MARKER - runs every 30 minutes"; echo "$CRON_ENTRY") | crontab -

    echo "Cron job installed!"
    echo ""
    echo "Current crontab:"
    crontab -l | grep -A1 "$REPO_NAME"
    echo ""
    echo "Commands:"
    echo "  Remove: crontab -e (delete the $REPO_NAME lines)"
    echo "  Logs:   tail -f $SCRIPT_DIR/automation.log"
    echo "  Manual: $RUN_SCRIPT"
fi

echo ""
echo "Setup complete!"
