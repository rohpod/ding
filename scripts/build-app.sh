#!/bin/bash
set -euo pipefail

# ==============================================================================
# scripts/build-app.sh
#
# Packages the "ding" SwiftPM executable into a valid macOS application bundle
# (.build/ding.app) and applies an ad-hoc code signature.
#
# Usage:
#   ./scripts/build-app.sh         # Builds optimized release bundle (default)
#   ./scripts/build-app.sh release # Explicit release configuration
#   ./scripts/build-app.sh debug   # Builds debug bundle for troubleshooting
# ==============================================================================

# 1. Resolve repository root directory regardless of current working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# 2. Parse build configuration argument
# Release mode (-c release): Enables compiler optimizations (-O), strips debug
# overhead, and produces a significantly smaller and faster binary suitable for
# a 24/7 menu bar utility.
# Debug mode (-c debug): Unoptimized with full debug symbols, useful when
# troubleshooting with LLDB or diagnosing runtime crashes.
BUILD_CONFIG="release"
if [ $# -ge 1 ]; then
    case "$1" in
        release|--release)
            BUILD_CONFIG="release"
            ;;
        debug|--debug)
            BUILD_CONFIG="debug"
            ;;
        *)
            echo "Error: Unknown build configuration '$1'."
            echo "Usage: $0 [release|debug]"
            exit 1
            ;;
    esac
fi

# 3. Ensure DEVELOPER_DIR points to Xcode if available
# This prevents SDK/compiler version mismatches if the system default
# xcode-select points to standalone Command Line Tools.
if [ -d "/Applications/Xcode.app/Contents/Developer" ] && [ -z "${DEVELOPER_DIR:-}" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# 4. Terminate any currently running instance of ding
# This prevents "text file busy" file-lock errors during binary copying and
# avoids duplicate status bar items or conflicting SMAppService instances.
if pgrep -x ding >/dev/null 2>&1; then
    echo "• Terminating running ding instance..."
    pkill -x ding || true
    sleep 0.5
fi

# 5. Build executable using SwiftPM
echo "• Building ding executable with SwiftPM (configuration: $BUILD_CONFIG)..."
swift build -c "$BUILD_CONFIG"

# 6. Locate compiled binary output
BIN_DIR="$(swift build -c "$BUILD_CONFIG" --show-bin-path)"
BIN_PATH="$BIN_DIR/ding"

if [ ! -f "$BIN_PATH" ]; then
    echo "Error: Compiled binary not found at $BIN_PATH"
    exit 1
fi

# 7. Create application bundle directory structure
# Target location is inside .build/ so it remains gitignored per .gitignore.
APP_DIR="$REPO_ROOT/.build/ding.app"
echo "• Assembling application bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 8. Copy compiled binary into bundle
# The binary inside Contents/MacOS/ding must match CFBundleExecutable in Info.plist.
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/ding"
chmod +x "$APP_DIR/Contents/MacOS/ding"

# 9. Check for custom app icon in Sources/ding/Resources/
RESOURCES_SRC="$REPO_ROOT/Sources/ding/Resources"
ICON_PLIST_ENTRY=""
ICON_FILE="$(find "$RESOURCES_SRC" -maxdepth 1 -name "*.icns" 2>/dev/null | head -n 1 || true)"

if [ -n "$ICON_FILE" ] && [ -f "$ICON_FILE" ]; then
    ICON_NAME="$(basename "$ICON_FILE")"
    echo "• Bundling app icon: $ICON_NAME"
    cp "$ICON_FILE" "$APP_DIR/Contents/Resources/"
    ICON_PLIST_ENTRY="    <key>CFBundleIconFile</key>
    <string>$ICON_NAME</string>"
else
    echo "• Notice: No .icns app icon found in Sources/ding/Resources/ (using system default)."
    echo "  // TODO: Add a proper .icns asset to Sources/ding/Resources/ for production packaging."
fi

# 10. Generate Info.plist
# Key specifications:
# - CFBundleName & CFBundleDisplayName: strictly lowercase "ding".
# - CFBundleIdentifier: "com.ding.mac" matching os.Logger subsystems and Keychain service prefix.
# - CFBundlePackageType: "APPL" declaring an application bundle.
# - CFBundleExecutable: "ding" matching the binary name in Contents/MacOS/.
# - LSMinimumSystemVersion: "13.0" matching macOS 13+ platform target.
# - LSUIElement: true (<true/>) — CRITICAL: instructs LaunchServices to run this as
#   an agent/accessory menu bar application with no Dock tile, reinforcing AppDelegate.
# - NSHumanReadableCopyright: placeholder copyright string.
#
# Note on UNUserNotificationCenter:
# On macOS 13+, local notifications do not require privacy usage strings
# (like iOS NSUserNotificationsUsageDescription) or legacy keys (NSUserNotificationAlertStyle).
# UNUserNotificationCenter relies on CFBundleIdentifier, .app structure, and code signing.
echo "• Generating Info.plist..."
cat << EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Basic Bundle Information -->
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleName</key>
    <string>ding</string>
    <key>CFBundleDisplayName</key>
    <string>ding</string>
    <key>CFBundleIdentifier</key>
    <string>com.ding.mac</string>
    <key>CFBundleExecutable</key>
    <string>ding</string>

    <!-- Versioning -->
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>

    <!-- Minimum System Version (macOS 13+ Ventura) -->
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>

    <!-- Menu Bar Only Operation (No Dock Tile) -->
    <key>LSUIElement</key>
    <true/>

    <!-- Copyright Information -->
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 ding. All rights reserved.</string>
$ICON_PLIST_ENTRY
</dict>
</plist>
EOF

# 11. Ad-hoc Code Signing
# The '-' identity indicates ad-hoc signing (free, self-signed, no Apple Developer ID needed).
#
# Purpose:
# - Keychain Services: Grants the binary a stable designated requirement / cdhash so macOS
#   remembers "Always Allow" access grants across repeated launches of the same built app.
# - ServiceManagement: SMAppService requires a valid code-signed bundle to register login items.
# - UNUserNotificationCenter: macOS TCC requires code signing to track notification permissions.
#
# Limitation:
# Ad-hoc signing does NOT satisfy Apple Gatekeeper's "identified developer" requirement.
# Local test runs will need Gatekeeper bypass (right-click -> Open or 'xattr -cr .build/ding.app').
echo "• Ad-hoc code signing ding.app..."
codesign --force --deep --sign - "$APP_DIR"

# 12. Verification and Summary
echo ""
echo "============================================================"
echo " ding.app packaged successfully!"
echo " Location:      $APP_DIR"
echo " Configuration: $BUILD_CONFIG"
echo " Bundle ID:     com.ding.mac"
echo " Executable:    $APP_DIR/Contents/MacOS/ding"
echo "============================================================"
echo ""
echo "To launch the application:"
echo "  open \"$APP_DIR\""
echo ""
echo "Gatekeeper / First-launch notes:"
echo "  Because this bundle is ad-hoc signed, if macOS blocks first launch:"
echo "    1. Run: xattr -cr \"$APP_DIR\""
echo "    or"
echo "    2. In Finder, right-click '$APP_DIR' and click 'Open'."
