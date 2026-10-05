#!/bin/bash
# Builds ~/Applications/ClaudeStack.app from ClaudeStack.swift.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/ClaudeStack.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ClaudeStack</string>
  <key>CFBundleDisplayName</key><string>Claude Stack</string>
  <key>CFBundleIdentifier</key><string>local.sundaran.claudestack</string>
  <key>CFBundleExecutable</key><string>ClaudeStack</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Claude Stack opens the Ghostty tab you click.</string>
</dict></plist>
PLIST
swiftc -O -parse-as-library -target arm64-apple-macos14.0 ClaudeStack.swift -o "$APP/Contents/MacOS/ClaudeStack"
codesign --force --sign - --identifier local.sundaran.claudestack "$APP"
echo "Built $APP"
