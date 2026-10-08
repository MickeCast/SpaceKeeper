#!/bin/bash
# Builds SpaceKeeper.app, installs it in ~/Applications and (re)starts its login agent.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.mickecast.SpaceKeeper"
APP="$HOME/Applications/SpaceKeeper.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGS="$HOME/Library/Logs/SpaceKeeper"
BUILT="build/SpaceKeeper.app"

rm -rf build
mkdir -p "$BUILT/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$BUILT/Contents/MacOS/SpaceKeeper" Sources/*.swift
cp Info.plist "$BUILT/Contents/Info.plist"
# Ad-hoc signature with an identifier-only requirement, so the Accessibility permission
# survives rebuilds (an ad-hoc signature's default requirement is the exact binary hash).
codesign --force --sign - --identifier "$LABEL" -r="designated => identifier \"$LABEL\"" "$BUILT"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$LOGS" "$HOME/.local/bin"
rm -rf "$APP"
cp -R "$BUILT" "$APP"
ln -sf "$APP/Contents/MacOS/SpaceKeeper" "$HOME/.local/bin/spacekeeper"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/SpaceKeeper</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$LOGS/launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$LOGS/launchd.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "SpaceKeeper installed at $APP and running. Log: $LOGS/SpaceKeeper.log"
