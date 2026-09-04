#!/bin/bash
set -euo pipefail

# ==============================================================================
# scripts/release.sh
#
# Dedicated release-packaging script for "ding".
#
# Builds an optimized release bundle using scripts/build-app.sh, stages the
# resulting .app bundle, packages it into a distributable zip archive under dist/,
# and generates an accompanying SHA-256 checksum file.
#
# Usage:
#   ./scripts/release.sh          # Package release for current VERSION
#   ./scripts/release.sh --force  # Overwrite existing release archive without prompt
# ==============================================================================

# 1. Resolve repository root directory regardless of current working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# 2. Parse command-line flags
FORCE=false

for arg in "$@"; do
    case "$arg" in
        -f|--force)
            FORCE=true
            ;;
        -h|--help)
            echo "Usage: $0 [--force|-f] [--help|-h]"
            echo ""
            echo "Options:"
            echo "  -f, --force    Overwrite existing release zip without confirmation prompt"
            echo "  -h, --help     Show this help message and exit"
            exit 0
            ;;
        *)
            echo "Error: Unknown argument '$arg'." >&2
            echo "Usage: $0 [--force|-f] [--help|-h]" >&2
            exit 1
            ;;
    esac
done

# 3. Validate and read VERSION from repository root
VERSION_FILE="$REPO_ROOT/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: VERSION file not found at $VERSION_FILE" >&2
    echo "A valid VERSION file must exist at the repository root." >&2
    exit 1
fi

APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [ -z "$APP_VERSION" ]; then
    echo "Error: VERSION file at $VERSION_FILE is empty." >&2
    echo "Please specify a valid semantic version string (e.g. 0.1.0)." >&2
    exit 1
fi

# Validate semantic versioning format: x.y.z with numeric digits only
if ! [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Invalid version format '$APP_VERSION' in $VERSION_FILE." >&2
    echo "Version must follow semantic versioning (x.y.z with numeric digits only, e.g. 0.1.0)." >&2
    exit 1
fi

# 4. Define release artifact paths
DIST_DIR="$REPO_ROOT/dist"
STAGE_DIR="$REPO_ROOT/.build/release-staging"
ZIP_NAME="ding-${APP_VERSION}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
CHECKSUM_NAME="${ZIP_NAME}.sha256"
CHECKSUM_PATH="$DIST_DIR/$CHECKSUM_NAME"

echo "=== Preparing Release Package for ding v${APP_VERSION} ==="

# 5. Overwrite safety check
# If a zip archive for this exact version already exists, prompt before overwriting
# to prevent accidental clobbering of previously generated/published release artifacts.
if [ -f "$ZIP_PATH" ] && [ "$FORCE" = false ]; then
    echo "⚠️  Warning: Release artifact already exists at:"
    echo "   $ZIP_PATH"
    echo ""
    read -r -p "Do you want to overwrite this release artifact? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[yY]([eE][sS])?$ ]]; then
        echo "Release packaging cancelled by user. Existing release artifact was preserved."
        exit 0
    fi
    echo "• Overwrite confirmed. Proceeding..."
fi

# 6. Build fresh application bundle using build-app.sh
# Invokes build-app.sh in release mode with --no-run so the app is built and ad-hoc
# signed into .build/ding.app without automatically launching the executable.
echo "• Building fresh release .app bundle via scripts/build-app.sh..."
"$REPO_ROOT/scripts/build-app.sh" release --no-run

BUILT_APP="$REPO_ROOT/.build/ding.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "Error: Expected application bundle not found at $BUILT_APP." >&2
    echo "scripts/build-app.sh did not produce .build/ding.app." >&2
    exit 1
fi

# 7. Create clean staging directory and copy .app bundle
echo "• Staging ding.app into clean staging directory..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
mkdir -p "$DIST_DIR"

cp -R "$BUILT_APP" "$STAGE_DIR/ding.app"

# 8. Create distributable zip archive
# -r: recursive
# -y: preserve symlinks (crucial for macOS frameworks / bundle structures)
# -q: quiet output
echo "• Packaging application into $ZIP_PATH..."
rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
(
    cd "$STAGE_DIR"
    zip -r -y -q "$ZIP_PATH" "ding.app"
)

# Clean up staging directory
rm -rf "$STAGE_DIR"

# 9. Generate SHA-256 checksum file
# Generates relative-path checksum so users can verify using: shasum -a 256 -c ding-x.y.z.zip.sha256
echo "• Generating SHA-256 checksum file ($CHECKSUM_NAME)..."
(
    cd "$DIST_DIR"
    shasum -a 256 "$ZIP_NAME" > "$CHECKSUM_NAME"
)

# Verify checksum integrity
(
    cd "$DIST_DIR"
    shasum -a 256 -c "$CHECKSUM_NAME" >/dev/null 2>&1
)

# 10. Report artifact details and next steps
ZIP_SIZE="$(du -h "$ZIP_PATH" | awk '{print $1}')"
SHA256_HASH="$(awk '{print $1}' "$CHECKSUM_PATH")"

echo ""
echo "======================================================================"
echo "✓ Release package created successfully!"
echo "======================================================================"
echo "Version:       $APP_VERSION"
echo "Archive:       $ZIP_PATH ($ZIP_SIZE)"
echo "Checksum File: $CHECKSUM_PATH"
echo "SHA-256:       $SHA256_HASH"
echo ""
echo "Next steps to publish this release:"
echo ""
echo "1. Create and push a git tag matching the version:"
echo "   git tag v${APP_VERSION}"
echo "   git push origin v${APP_VERSION}"
echo ""
echo "2. Publish the GitHub Release:"
echo "   • Option A: Manual Web UI (Primary)"
echo "     a. Visit: https://github.com/rohpod/ding/releases/new"
echo "     b. Choose tag: v${APP_VERSION}"
echo "     c. Release title: ding v${APP_VERSION}"
echo "     d. Attach release assets from dist/:"
echo "        - dist/${ZIP_NAME}"
echo "        - dist/${CHECKSUM_NAME}"
echo "     e. Click 'Publish release'"
echo ""
echo "   • Option B: GitHub CLI (Optional shortcut if 'gh' is installed)"
echo "     gh release create v${APP_VERSION} \\"
echo "       \"$ZIP_PATH\" \\"
echo "       \"$CHECKSUM_PATH\" \\"
echo "       --title \"ding v${APP_VERSION}\" \\"
echo "       --generate-notes"
echo "======================================================================"
