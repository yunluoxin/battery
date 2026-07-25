#!/bin/bash
# Build BatteryGUI.app from the SwiftPM package.
# Usage: ./build-app.sh [output-dir]   (default: ./build)
set -euo pipefail
cd "$(dirname "$0")"

OUT_DIR="${1:-build}"
APP_NAME="BatteryGUI"
APP_DIR="$OUT_DIR/$APP_NAME.app"

echo "🔨 Building release binaries…"
swift build -c release --arch arm64

BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "📦 Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/battery-gui-helper" "$APP_DIR/Contents/MacOS/battery-gui-helper"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Battery GUI</string>
    <key>CFBundleIdentifier</key>
    <string>co.palokaj.battery.gui</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Ad-hoc sign so launchd and Gatekeeper treat it consistently.
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "✅ Done: $APP_DIR"
echo "   Run with: open $APP_DIR"
