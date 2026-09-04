#!/bin/bash
set -euo pipefail

# scripts/generate-icon.sh
# Generates AppIcon.icns from Sources/ding/Resources/AppIcon.png using macOS sips and iconutil.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ICON="${1:-"$ROOT_DIR/Sources/ding/Resources/AppIcon.png"}"
OUTPUT_ICNS="${2:-"$ROOT_DIR/build/ding.app/Contents/Resources/AppIcon.icns"}"

if [ ! -f "$SOURCE_ICON" ]; then
    echo "========================================================================"
    echo "⚠️  WARNING: App icon source file not found at:"
    echo "   $SOURCE_ICON"
    echo "   Continuing build without AppIcon.icns..."
    echo "========================================================================"
    exit 0
fi

echo "Generating AppIcon.icns from $SOURCE_ICON..."

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT_ICNS")"

# Create a temporary directory for the iconset
TEMP_ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TEMP_ICONSET"

cleanup() {
    rm -rf "$(dirname "$TEMP_ICONSET")"
}
trap cleanup EXIT

# Generate all 10 required Apple icon resolutions
sips -z 16 16     "$SOURCE_ICON" --out "$TEMP_ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$SOURCE_ICON" --out "$TEMP_ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$SOURCE_ICON" --out "$TEMP_ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$SOURCE_ICON" --out "$TEMP_ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$SOURCE_ICON" --out "$TEMP_ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$SOURCE_ICON" --out "$TEMP_ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SOURCE_ICON" --out "$TEMP_ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$SOURCE_ICON" --out "$TEMP_ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SOURCE_ICON" --out "$TEMP_ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SOURCE_ICON" --out "$TEMP_ICONSET/icon_512x512@2x.png" >/dev/null

# Compile iconset into .icns binary
iconutil -c icns "$TEMP_ICONSET" -o "$OUTPUT_ICNS"

echo "Successfully generated $OUTPUT_ICNS"
