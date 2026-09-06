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

# 10. Locate Sparkle's sign_update tool and generate EdDSA signature
SIGN_UPDATE_BIN=""
if [ -f "$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update" ]; then
    SIGN_UPDATE_BIN="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
elif [ -f "$REPO_ROOT/.build/checkouts/Sparkle/bin/sign_update" ]; then
    SIGN_UPDATE_BIN="$REPO_ROOT/.build/checkouts/Sparkle/bin/sign_update"
else
    SIGN_UPDATE_BIN="$(find "$REPO_ROOT/.build" -name "sign_update" -type f -perm +111 2>/dev/null | grep -v "\.dSYM" | head -n 1 || true)"
fi

ED_SIGNATURE=""
if [ -n "$SIGN_UPDATE_BIN" ] && [ -x "$SIGN_UPDATE_BIN" ]; then
    echo "• Found Sparkle sign_update tool at: $SIGN_UPDATE_BIN"
    echo "• Signing $ZIP_NAME with EdDSA private key..."
    ED_SIGNATURE="$("$SIGN_UPDATE_BIN" -p "$ZIP_PATH" 2>/dev/null || true)"
    if [ -z "$ED_SIGNATURE" ]; then
        echo "⚠️  Warning: Sparkle sign_update failed (no ed25519 private key found in Keychain)." >&2
        echo "   Please run '$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys' to generate your keypair." >&2
        ED_SIGNATURE="PLACEHOLDER_ED25519_SIGNATURE"
    else
        echo "• Successfully signed release archive with EdDSA key."
    fi
else
    echo "⚠️  Warning: Sparkle sign_update tool not found in .build/." >&2
    ED_SIGNATURE="PLACEHOLDER_ED25519_SIGNATURE"
fi

# 11. Generate or update appcast.xml at repository root
APPCAST_PATH="$REPO_ROOT/appcast.xml"
ZIP_LENGTH="$(stat -f%z "$ZIP_PATH" 2>/dev/null || wc -c < "$ZIP_PATH" | tr -d ' ')"
PUB_DATE="$(LC_ALL=C date +"%a, %d %b %Y %H:%M:%S %z")"
DOWNLOAD_URL="https://github.com/rohpod/ding/releases/download/v${APP_VERSION}/ding-${APP_VERSION}.zip"

NEW_ITEM="        <item>
            <title>ding v${APP_VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${APP_VERSION}</sparkle:version>
            <sparkle:shortVersionString>${APP_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure
                url=\"${DOWNLOAD_URL}\"
                sparkle:edSignature=\"${ED_SIGNATURE}\"
                length=\"${ZIP_LENGTH}\"
                type=\"application/octet-stream\" />
        </item>"

if [ ! -f "$APPCAST_PATH" ]; then
    echo "• Creating initial appcast.xml at $APPCAST_PATH..."
    cat << EOF > "$APPCAST_PATH"
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>ding Changelog</title>
        <link>https://raw.githubusercontent.com/rohpod/ding/main/appcast.xml</link>
        <description>Most recent releases and updates for ding.</description>
        <language>en</language>
$NEW_ITEM
    </channel>
</rss>
EOF
else
    echo "• Updating existing appcast.xml with entry for v${APP_VERSION}..."
    python3 -c '
import sys

appcast_path = sys.argv[1]
new_item = sys.argv[2]
version = sys.argv[3]

with open(appcast_path, "r", encoding="utf-8") as f:
    content = f.read()

version_tag = f"<sparkle:version>{version}</sparkle:version>"
if version_tag in content:
    print(f"• Version {version} already present in {appcast_path}; skipping duplicate entry.")
    sys.exit(0)

if "<item>" in content:
    idx = content.find("<item>")
    new_content = content[:idx] + new_item.strip() + "\n\n        " + content[idx:]
elif "</channel>" in content:
    idx = content.find("</channel>")
    new_content = content[:idx] + new_item.strip() + "\n    " + content[idx:]
else:
    print(f"Error: Malformed appcast XML in {appcast_path}", file=sys.stderr)
    sys.exit(1)

with open(appcast_path, "w", encoding="utf-8") as f:
    f.write(new_content)
print(f"• Prepended v{version} entry into {appcast_path}")
' "$APPCAST_PATH" "$NEW_ITEM" "$APP_VERSION"
fi

# 12. Report artifact details and next steps
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
echo "Appcast File:  $APPCAST_PATH"
echo "EdDSA Sig:     $ED_SIGNATURE"
echo ""
echo "Next steps to publish this release:"
echo ""
echo "1. Commit and push appcast.xml to the main branch:"
echo "   git add appcast.xml"
echo "   git commit -m \"chore: update appcast for v${APP_VERSION}\""
echo "   git push origin main"
echo "   ⚠️  REMINDER: appcast.xml MUST be pushed to the 'main' branch"
echo "   for SUFeedURL to serve the update to users!"
echo ""
echo "2. Create and push a git tag matching the version:"
echo "   git tag v${APP_VERSION}"
echo "   git push origin v${APP_VERSION}"
echo ""
echo "3. Publish the GitHub Release:"
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
