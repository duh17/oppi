#!/usr/bin/env bash
#
# release-mac.sh — Build, sign, create a DMG, and publish a GitHub release.
#
# Usage:
#   ./scripts/release-mac.sh                    # Build + create DMG only
#   ./scripts/release-mac.sh --publish          # Build + DMG + create GitHub release
#   ./scripts/release-mac.sh --publish --tag v0.1.0   # Explicit tag
#
# Prerequisites:
#   - Xcode with Developer ID signing
#   - XcodeGen installed (brew install xcodegen)
#   - gh CLI authenticated (gh auth login)
#   - Node.js and the global Oppi CLI installed (`npm install -g oppi-server`)
#
# Optional overrides:
#   OPPI_DEVELOPMENT_TEAM, OPPI_MAC_SIGNING_IDENTITY, OPPI_GITHUB_URL
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APPLE_DIR/../.." && pwd)"
SERVER_DIR="$REPO_ROOT/server"
PROJECT_YML="$APPLE_DIR/project.yml"

# Read version from project.yml (OppiMac target)
VERSION=$(grep -A40 'OppiMac:' "$PROJECT_YML" | grep 'MARKETING_VERSION:' | head -1 | awk -F'"' '{print $2}')
BUILD_NUMBER=$(grep -A40 'OppiMac:' "$PROJECT_YML" | grep 'CURRENT_PROJECT_VERSION:' | head -1 | awk '{print $2}')
SERVER_VERSION=$(node -e "const pkg = require(process.argv[1]); console.log(pkg.version);" "$SERVER_DIR/package.json")
BUILD_DIR="$APPLE_DIR/build/release-mac-${VERSION}"
DEVELOPMENT_TEAM="${OPPI_DEVELOPMENT_TEAM:-$(grep -A40 'OppiMac:' "$PROJECT_YML" | grep 'DEVELOPMENT_TEAM:' | head -1 | awk '{print $2}')}"
REQUESTED_SIGNING_IDENTITY="${OPPI_MAC_SIGNING_IDENTITY:-}"
GITHUB_URL="${OPPI_GITHUB_URL:-$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')}"
DMG_NAME="Oppi-${VERSION}-mac.dmg"

resolve_signing_identity() {
    if [[ -n "$REQUESTED_SIGNING_IDENTITY" ]]; then
        printf '%s\n' "$REQUESTED_SIGNING_IDENTITY"
        return 0
    fi

    local identities matches count
    identities=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application:/{print $2}' \
        | sort -u)

    if [[ -n "$DEVELOPMENT_TEAM" ]]; then
        matches=$(printf '%s\n' "$identities" | grep -F "($DEVELOPMENT_TEAM)" || true)
    else
        matches="$identities"
    fi

    count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
    if [[ "$count" == "1" ]]; then
        printf '%s\n' "$matches"
        return 0
    fi

    echo "ERROR: Could not resolve a unique Developer ID Application signing identity." >&2
    echo "Set OPPI_MAC_SIGNING_IDENTITY to the full identity name, for example:" >&2
    echo "  OPPI_MAC_SIGNING_IDENTITY='Developer ID Application: Example Corp (TEAMID)'" >&2
    exit 1
}

SIGNING_IDENTITY="$(resolve_signing_identity)"

create_dmg() {
    local source_dir="$1"
    local output_path="$2"
    local log_path="$BUILD_DIR/dmg-create.log"
    local attempt rc volume_name

    : > "$log_path"

    for attempt in 1 2; do
        volume_name="Oppi-${VERSION//./-}-${attempt}-$$"
        echo "Attempt $attempt: hdiutil create -volname $volume_name" | tee -a "$log_path"

        if hdiutil create \
            -volname "$volume_name" \
            -srcfolder "$source_dir" \
            -ov -format UDZO \
            "$output_path" >>"$log_path" 2>&1; then
            tail -5 "$log_path"
            return 0
        fi

        rc=$?
        echo "warning: DMG creation failed on attempt $attempt (exit $rc)" | tee -a "$log_path"
        sleep 1
    done

    echo "Error: DMG creation failed after 2 attempts. See $log_path"
    tail -20 "$log_path"
    exit 1
}

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
echo "Team:       ${DEVELOPMENT_TEAM:-auto}"
echo "Signing:    $SIGNING_IDENTITY"
echo "Publish:    $PUBLISH"
echo ""

# ── Step 1: Verify the published npm CLI prerequisite ──

echo "--- Step 1: Verifying Oppi CLI ---"
if ! git -C "$REPO_ROOT" diff --quiet -- server || \
   ! git -C "$REPO_ROOT" diff --cached --quiet -- server; then
    echo "Error: server changes must be committed and published before building the Mac app."
    exit 1
fi
if ! command -v oppi >/dev/null 2>&1; then
    echo "Error: Oppi CLI not found. Run: npm install -g oppi-server@latest"
    exit 1
fi
INSTALLED_SERVER_VERSION="$(oppi version | awk '{print $NF}')"
PUBLISHED_LATEST_VERSION="$(npm view oppi-server@latest version)"
PUBLISHED_GIT_HEAD="$(npm view "oppi-server@$SERVER_VERSION" gitHead)"
SOURCE_GIT_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [[ "$PUBLISHED_LATEST_VERSION" != "$SERVER_VERSION" ]]; then
    echo "Error: oppi-server@latest is $PUBLISHED_LATEST_VERSION, not $SERVER_VERSION."
    echo "Publish and promote oppi-server@$SERVER_VERSION before building the Mac app."
    exit 1
fi
if [[ -z "$PUBLISHED_GIT_HEAD" || "$PUBLISHED_GIT_HEAD" != "$SOURCE_GIT_HEAD" ]]; then
    echo "Error: published oppi-server@$SERVER_VERSION does not come from $SOURCE_GIT_HEAD."
    echo "Publish the current commit before building the Mac app."
    exit 1
fi
if [[ "$INSTALLED_SERVER_VERSION" != "$SERVER_VERSION" ]]; then
    echo "Error: Oppi CLI $INSTALLED_SERVER_VERSION does not match published server $SERVER_VERSION."
    echo "Run: npm install -g oppi-server@$SERVER_VERSION"
    exit 1
fi
echo "Oppi CLI $INSTALLED_SERVER_VERSION ($PUBLISHED_GIT_HEAD)"

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
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
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

# ── Step 5: Codesign (inside-out) ──
#
# macOS codesigning requires inside-out: sign leaf Mach-O binaries first, then
# sign the outer .app which seals everything by hash. Using --deep on the outer
# app would clobber inner signatures.

echo "--- Step 5: Signing (inside-out) ---"
RESOURCES="$APP_PATH/Contents/Resources"

# 1. Sign any Mach-O binaries in Frameworks/ or Helpers/
SIGN_DIRS=()
[[ -d "$APP_PATH/Contents/Frameworks" ]] && SIGN_DIRS+=("$APP_PATH/Contents/Frameworks")
[[ -d "$APP_PATH/Contents/Helpers" ]] && SIGN_DIRS+=("$APP_PATH/Contents/Helpers")
find "${SIGN_DIRS[@]}" -type f -perm +111 2>/dev/null | while read -r binary; do
    # Skip non-Mach-O files
    file "$binary" | grep -q "Mach-O" || continue
    codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$binary" 2>&1
    echo "  Signed: $(basename "$binary")"
done

# 2. Sign the outer .app (NO --deep — inner binaries already signed)
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH" \
    2>&1
echo "  Signed: Oppi.app"

# Verify entire bundle
codesign --verify --deep --strict "$APP_PATH" 2>&1
echo "Signature verified."

# ── Step 6: Create DMG ──

echo "--- Step 6: Creating DMG ---"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

# Remove existing DMG if present
rm -f "$DMG_PATH"

# Create a temporary folder for the DMG contents
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

create_dmg "$DMG_STAGING" "$DMG_PATH"

rm -rf "$DMG_STAGING"

DMG_SIZE=$(du -sh "$DMG_PATH" | awk '{print $1}')
echo "DMG created: $DMG_PATH ($DMG_SIZE)"

# ── Step 7: Publish GitHub release (optional) ──

if $PUBLISH; then
    echo "--- Step 7: Publishing GitHub release ---"

    if ! command -v gh &>/dev/null; then
        echo "Error: gh CLI not found — brew install gh"
        exit 1
    fi

    cd "$REPO_ROOT"

    RELEASE_NOTES=$(cat <<EOF
## Oppi $VERSION (Mac)

Oppi $VERSION aligns mobile supervision with the current Pi runtime: live terminal mirroring, a mobile bridge for Pi extension UI, broader extension API compatibility, and clearer iPad workspace navigation.

### What's new
- Mirror live Pi terminal sessions into Oppi while the terminal remains the execution owner.
- Install the separate \`oppi-mirror\` Pi extension package with \`pi install npm:oppi-mirror\` after it is published.
- Bridge most standard Pi extension UI to Apple clients, including input and confirm flows from extensions.
- Replace Oppi's built-in permission gate with standard Pi extension permission flows, improving compatibility for extension-driven tools.
- Improve the iPad workspace shell so workspaces, sessions, and chat are easier to move between.
- Use one globally installed \`oppi\` CLI for both the Mac app and terminal workflows.

### Prerequisites
- macOS 26.0+
- Node.js 24.0.0 or newer installed on the Mac
- \`npm install -g oppi-server@latest\`

### Install
1. Download \`$DMG_NAME\` below
2. Drag Oppi to Applications
3. Launch Oppi — it will check prerequisites and guide you through setup
4. If prompted, run \`npm install -g oppi-server@latest\` and reopen Oppi
5. Pair with the iOS app by scanning the QR code

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

    if [[ -n "$GITHUB_URL" ]]; then
        echo "Release published: ${GITHUB_URL}/releases/tag/$TAG"
    else
        echo "Release published: $TAG"
    fi
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
