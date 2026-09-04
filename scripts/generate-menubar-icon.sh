#!/bin/bash
set -euo pipefail

# scripts/generate-menubar-icon.sh
# Converts a white-on-transparent menu bar icon into a black-on-transparent template image
# preserving the exact alpha channel for macOS NSImage template rendering.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ICON="${1:-"$ROOT_DIR/Sources/ding/Resources/MenuBarIcon.png"}"
OUTPUT_ICON="${2:-"$ROOT_DIR/Sources/ding/Resources/MenuBarIconTemplate.png"}"

if [ ! -f "$SOURCE_ICON" ]; then
    echo "========================================================================"
    echo "⚠️  WARNING: Menu bar icon source file not found at:"
    echo "   $SOURCE_ICON"
    echo "========================================================================"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_ICON")"

echo "Converting $SOURCE_ICON to black-on-transparent template..."

# Method 1: Python 3 with Pillow
if python3 -c "import PIL" >/dev/null 2>&1; then
    python3 - <<PYEOF
from PIL import Image
im = Image.open("$SOURCE_ICON").convert("RGBA")
r, g, b, a = im.split()
black = Image.new("RGB", im.size, (0, 0, 0))
out = Image.merge("RGBA", (*black.split(), a))
out.save("$OUTPUT_ICON", "PNG")
PYEOF
    echo "Successfully generated template image via Python Pillow: $OUTPUT_ICON"
    exit 0
fi

# Method 2: ImageMagick (magick or convert)
IMAGEMAGICK_BIN=""
if command -v magick >/dev/null 2>&1; then
    IMAGEMAGICK_BIN="magick"
elif command -v convert >/dev/null 2>&1; then
    IMAGEMAGICK_BIN="convert"
fi

if [ -n "$IMAGEMAGICK_BIN" ]; then
    "$IMAGEMAGICK_BIN" "$SOURCE_ICON" -fill black -colorize 100,100,100,0 "$OUTPUT_ICON"
    echo "Successfully generated template image via ImageMagick: $OUTPUT_ICON"
    exit 0
fi

echo "========================================================================"
echo "❌ ERROR: No suitable image processing tool found to generate template icon."
echo "   Please install Pillow for Python:"
echo "       pip3 install Pillow"
echo "   Or install ImageMagick via Homebrew:"
echo "       brew install imagemagick"
echo "========================================================================"
exit 1
