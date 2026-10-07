#!/bin/bash
# Builds ~/Applications/ClaudeStack.app from the .swift files and the web/ reader page.
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSAppleEventsUsageDescription</key><string>Claude Stack opens the Ghostty tab you click, and types the prompts you send.</string>
</dict></plist>
PLIST
swiftc -O -parse-as-library -target arm64-apple-macos14.0 *.swift -o "$APP/Contents/MacOS/ClaudeStack"
rm -rf "$APP/Contents/Resources/web"
mkdir -p "$APP/Contents/Resources"
cp -R web "$APP/Contents/Resources/web"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with a real certificate when one is named in ./sign-identity (kept out of git), so macOS
# keeps its permissions across rebuilds. Without it, ad-hoc signing changes the app's identity
# on every build and macOS asks again. Example content: Apple Development: you@example.com (ABCDE12345)
ID=$(cat sign-identity 2>/dev/null || true)
if [ -n "$ID" ] && security find-identity -v -p codesigning | grep -qF "$ID"; then
  codesign --force --sign "$ID" --identifier local.sundaran.claudestack "$APP"
else
  codesign --force --sign - --identifier local.sundaran.claudestack "$APP"
fi
echo "Built $APP"
