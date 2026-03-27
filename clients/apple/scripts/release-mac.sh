#!/usr/bin/env bash
#
# release-mac.sh — Build, sign, bundle server runtime, create DMG, and publish GitHub release.
#
# Usage:
#   ./scripts/release-mac.sh                    # Build + create DMG only
#   ./scripts/release-mac.sh --publish          # Build + DMG + create GitHub release
#   ./scripts/release-mac.sh --publish --tag v0.1.0   # Explicit tag
#
# Prerequisites:
#   - Xcode with Developer ID signing (team AZAQMY4SPZ)
#   - XcodeGen installed (brew install xcodegen)
#   - gh CLI authenticated (gh auth login)
#   - Node.js installed (for server build)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APPLE_DIR/../.." && pwd)"
SERVER_DIR="$REPO_ROOT/server"
PROJECT_YML="$APPLE_DIR/project.yml"

# Read version from project.yml (OppiMac target)
VERSION=$(grep -A20 'OppiMac:' "$PROJECT_YML" | grep 'MARKETING_VERSION:' | head -1 | awk -F'"' '{print $2}')
BUILD_NUMBER=$(grep -A20 'OppiMac:' "$PROJECT_YML" | grep 'CURRENT_PROJECT_VERSION:' | head -1 | awk '{print $2}')

BUILD_DIR="$APPLE_DIR/build/release-mac-${VERSION}"
SIGNING_IDENTITY="Developer ID Application: Da Chen (AZAQMY4SPZ)"
DMG_NAME="Oppi-${VERSION}-mac.dmg"

# ── Argument parsing ──

PUBLISH=false
TAG="v${VERSION}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish) PUBLISH=true; shift ;;
        --tag) TAG="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "=== Oppi Mac Release Build ==="
echo "Version:    $VERSION (build $BUILD_NUMBER)"
echo "Tag:        $TAG"
echo "Build dir:  $BUILD_DIR"
echo "Publish:    $PUBLISH"
echo ""

# ── Step 1: Build server ──

echo "--- Step 1: Building server ---"
cd "$SERVER_DIR"
npm ci --ignore-scripts
npm run build
echo "Server built."

# ── Step 2: Generate Xcode project ──

echo "--- Step 2: Generating Xcode project ---"
cd "$APPLE_DIR"
xcodegen generate 2>&1
echo "Done."

# ── Step 3: Archive ──

echo "--- Step 3: Archiving OppiMac (Release) ---"
mkdir -p "$BUILD_DIR"

xcodebuild archive \
    -project Oppi.xcodeproj \
    -scheme OppiMac \
    -archivePath "$BUILD_DIR/OppiMac.xcarchive" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM=AZAQMY4SPZ \
    2>&1 | tee "$BUILD_DIR/archive.log" | tail -5

if [[ ! -d "$BUILD_DIR/OppiMac.xcarchive" ]]; then
    echo "Error: Archive failed. See $BUILD_DIR/archive.log"
    exit 1
fi
echo "Archive created."

# ── Step 4: Export ──

echo "--- Step 4: Exporting .app ---"
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/OppiMac.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$APPLE_DIR/ExportOptions-Mac.plist" \
    2>&1 | tee "$BUILD_DIR/export.log" | tail -5

APP_PATH="$BUILD_DIR/export/Oppi.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: Export failed. See $BUILD_DIR/export.log"
    exit 1
fi
echo "Exported to $APP_PATH"

# ── Step 5: Bundle server runtime ──

echo "--- Step 5: Bundling server runtime ---"
RESOURCES="$APP_PATH/Contents/Resources"
SERVER_BUNDLE="$RESOURCES/server"

mkdir -p "$SERVER_BUNDLE"

# Copy server dist
cp -R "$SERVER_DIR/dist" "$SERVER_BUNDLE/dist"

# Install production-only node_modules
cp "$SERVER_DIR/package.json" "$SERVER_BUNDLE/"
cp "$SERVER_DIR/package-lock.json" "$SERVER_BUNDLE/"
cd "$SERVER_BUNDLE"
npm ci --production --ignore-scripts 2>&1 | tail -3
# Clean up package files (only node_modules needed at runtime)
rm -f "$SERVER_BUNDLE/package.json" "$SERVER_BUNDLE/package-lock.json"

# Report bundle size
BUNDLE_SIZE=$(du -sh "$SERVER_BUNDLE" | awk '{print $1}')
echo "Server runtime bundled ($BUNDLE_SIZE)"

# ── Step 6: Re-sign (bundle was modified after initial signing) ──

echo "--- Step 6: Re-signing app ---"
codesign --deep --force --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH" \
    2>&1

# Verify signature
codesign --verify --deep --strict "$APP_PATH" 2>&1
echo "Signature verified."

# ── Step 7: Create DMG ──

echo "--- Step 7: Creating DMG ---"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

# Remove existing DMG if present
rm -f "$DMG_PATH"

# Create a temporary folder for the DMG contents
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "Oppi" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" \
    2>&1 | tail -3

rm -rf "$DMG_STAGING"

DMG_SIZE=$(du -sh "$DMG_PATH" | awk '{print $1}')
echo "DMG created: $DMG_PATH ($DMG_SIZE)"

# ── Step 8: Publish GitHub release (optional) ──

if $PUBLISH; then
    echo "--- Step 8: Publishing GitHub release ---"

    if ! command -v gh &>/dev/null; then
        echo "Error: gh CLI not found — brew install gh"
        exit 1
    fi

    cd "$REPO_ROOT"

    RELEASE_NOTES=$(cat <<EOF
## Oppi $VERSION (Mac)

Self-hosted coding agent with mobile supervision.

### What's included
- Oppi Mac app (menu bar) — manages the local server, session monitoring
- Bundled server runtime + pi coding agent

### Prerequisites
- macOS 15.0+
- Node.js 20+ (install from [nodejs.org](https://nodejs.org) or \`brew install node\`)

### Install
1. Download \`$DMG_NAME\` below
2. Drag Oppi to Applications
3. Launch Oppi — it will check prerequisites and guide you through setup
4. Pair with the iOS app by scanning the QR code

### Notes
- The app is Developer ID signed but not notarized. On first launch, right-click the app and choose "Open", or run:
  \`\`\`
  xattr -cr /Applications/Oppi.app
  \`\`\`
- The server runs locally on port 7749 by default
- All data stays on your machine — no accounts, no analytics, no external services
EOF
    )

    gh release create "$TAG" \
        --title "Oppi $VERSION" \
        --notes "$RELEASE_NOTES" \
        --prerelease \
        "$DMG_PATH" \
        2>&1

    echo "Release published: https://github.com/duh17/oppi/releases/tag/$TAG"
else
    echo ""
    echo "--- Build complete (not published) ---"
    echo "DMG: $DMG_PATH"
    echo ""
    echo "To publish:"
    echo "  ./scripts/release-mac.sh --publish"
fi

# ── Summary ──

echo ""
echo "=== Release build $VERSION complete ==="
echo "Archive: $BUILD_DIR/OppiMac.xcarchive"
echo "App:     $APP_PATH"
echo "DMG:     $DMG_PATH"
