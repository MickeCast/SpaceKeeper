#!/bin/bash
# Stops SpaceKeeper and removes the app, its login agent and the CLI link.
# Saved layouts and logs stay in ~/Library/Application Support/SpaceKeeper and ~/Library/Logs/SpaceKeeper.
set -uo pipefail

LABEL="com.mickecast.SpaceKeeper"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/spacekeeper"
rm -rf "$HOME/Applications/SpaceKeeper.app"
echo "SpaceKeeper removed. Also remove it from System Settings › Privacy & Security › Accessibility."
