#!/bin/bash
set -e

# Change to the project root directory
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Terminate any previously running instance of ding to avoid status bar collisions
if pgrep -x ding >/dev/null 2>&1; then
    echo "Terminating running ding process..."
    pkill -x ding || true
    sleep 0.5
fi

echo "Building ding executable with SwiftPM..."
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
else
    swift build
fi

APP_DIR="$ROOT_DIR/build/ding.app"
echo "Creating application bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp ".build/arm64-apple-macosx/debug/ding" "$APP_DIR/Contents/MacOS/ding"

cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.ding.mac</string>
    <key>CFBundleName</key>
    <string>ding</string>
    <key>CFBundleDisplayName</key>
    <string>ding</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>ding</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "Ad-hoc code signing ding.app..."
codesign --force --deep --sign - "$APP_DIR"

echo "ding.app built successfully at $APP_DIR"

if [ "$1" != "--no-run" ]; then
    echo "Launching ding.app..."
    open "$APP_DIR"
fi
