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
#   - Xcode with Developer ID signing
#   - XcodeGen installed (brew install xcodegen)
#   - gh CLI authenticated (gh auth login)
#   - Node.js installed (for server build and bundled server runtime dependencies)
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
PI_AGENT_VERSION=$(node -e "const pkg = require(process.argv[1]); console.log(pkg.dependencies['@earendil-works/pi-coding-agent'] || pkg.dependencies['@mariozechner/pi-coding-agent'] || 'unknown');" "$SERVER_DIR/package.json")

BUILD_DIR="$APPLE_DIR/build/release-mac-${VERSION}"
DEVELOPMENT_TEAM="${OPPI_DEVELOPMENT_TEAM:-$(grep -A40 'OppiMac:' "$PROJECT_YML" | grep 'DEVELOPMENT_TEAM:' | head -1 | awk '{print $2}')}"
SIGNING_IDENTITY="${OPPI_MAC_SIGNING_IDENTITY:-Developer ID Application}"
GITHUB_URL="${OPPI_GITHUB_URL:-$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')}"
DMG_NAME="Oppi-${VERSION}-mac.dmg"

clean_npm_env() {
    env \
        -u npm_config_before \
        -u NPM_CONFIG_BEFORE \
        -u npm_config_min_release_age \
        -u NPM_CONFIG_MIN_RELEASE_AGE \
        "$@"
}

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
echo "Publish:    $PUBLISH"
echo ""

# ── Step 1: Build server ──

echo "--- Step 1: Building server ---"
cd "$SERVER_DIR"
clean_npm_env npm ci --ignore-scripts
clean_npm_env npm run build
echo "Server built."

# ── Step 1b: Audit production dependencies ──

echo "--- Step 1b: Auditing production dependencies ---"
AUDIT_OUTPUT=$(clean_npm_env npm audit --production --audit-level=high 2>&1) || true
AUDIT_EXIT=$?

# npm audit exits 1 if any vuln at or above audit-level is found
if echo "$AUDIT_OUTPUT" | grep -q "found 0 vulnerabilities"; then
    echo "Audit clean."
elif echo "$AUDIT_OUTPUT" | grep -qi "high\|critical"; then
    echo ""
    echo "$AUDIT_OUTPUT"
    echo ""
    echo "ERROR: npm audit found high/critical vulnerabilities in production dependencies."
    echo "Fix with 'npm audit fix' or update the offending package before releasing."
    echo ""
    echo "To bypass (NOT RECOMMENDED): set SKIP_AUDIT=1"
    if [[ "${SKIP_AUDIT:-}" != "1" ]]; then
        exit 1
    fi
    echo "WARNING: SKIP_AUDIT=1 set — proceeding despite vulnerabilities"
else
    echo "Audit: moderate/low issues only (acceptable)."
    echo "$AUDIT_OUTPUT" | tail -5
fi

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

# ── Step 5: Bundle server seed ──
#
# The server runtime is DECOUPLED from the app binary:
#   - Resources/server-seed/ = immutable seed (dist + deps, for first launch)
#   - ~/.config/oppi/server-runtime/ = mutable copy (updated independently)
#
# On first launch (or app version bump), the app copies the seed to the runtime
# dir. Dependencies can then be updated without rebuilding the DMG.

echo "--- Step 5: Bundling server seed ---"
RESOURCES="$APP_PATH/Contents/Resources"
SERVER_SEED="$RESOURCES/server-seed"
rm -rf "$SERVER_SEED"
mkdir -p "$SERVER_SEED"

# Copy compiled server code and manifests
cp -R "$SERVER_DIR/dist" "$SERVER_SEED/dist"
cp "$SERVER_DIR/package.json" "$SERVER_SEED/"
cp "$SERVER_DIR/package-lock.json" "$SERVER_SEED/"

# Install production deps into the seed using npm so the bundled runtime stays Node-only.
cd "$SERVER_SEED"
clean_npm_env npm ci --omit=dev --ignore-scripts --no-audit --no-fund 2>&1 | tail -3

# Write seed version (app version + build number for change detection)
echo "${VERSION}.${BUILD_NUMBER}" > "$SERVER_SEED/.seed-version"

# ── Step 5b: Strip bloat from seed node_modules ──

echo "--- Step 5b: Stripping bloat ---"
NM="$SERVER_SEED/node_modules"
BEFORE_SIZE=$(du -sh "$SERVER_SEED" | awk '{print $1}')

# Remove entire packages that are dead code on macOS
rm -rf "$NM/koffi"                                     # Windows-only FFI (86MB)
rm -rf "$NM/better-sqlite3"                            # Not needed with built-in SQLite runtimes
rm -rf "$NM/nan" "$NM/buildcheck" "$NM/node-gyp"      # Native build tooling
rm -rf "$NM/@types"                                    # TypeScript declarations
rm -rf "$NM/@mariozechner/clipboard-darwin-universal"   # Redundant with arm64

# Remove test/example dirs ONLY at package root (avoid breaking internal doc/ dirs)
for pkg_dir in "$NM"/*/ "$NM"/@*/*/ ; do
    [ -d "$pkg_dir" ] || continue
    rm -rf "${pkg_dir}test" "${pkg_dir}tests" "${pkg_dir}__tests__" \
           "${pkg_dir}example" "${pkg_dir}examples" 2>/dev/null || true
done

# Remove READMEs, changelogs, source maps (never imported at runtime)
find "$NM" \( -name "README*" -o -name "CHANGELOG*" -o -name "HISTORY*" \
    -o -name "*.map" \) -type f -delete 2>/dev/null || true

AFTER_SIZE=$(du -sh "$SERVER_SEED" | awk '{print $1}')
echo "Server seed: $BEFORE_SIZE -> $AFTER_SIZE (after stripping)"

TOTAL_SIZE=$(du -sh "$RESOURCES" | awk '{print $1}')
echo "Total Resources: $TOTAL_SIZE (server seed $AFTER_SIZE)"

# ── Step 5c: Verify server-seed integrity ──
#
# Static check: verify the bundled server-seed contains everything
# ServerProcessManager.resolveServerCLIPath() expects at runtime.
# This catches path mismatches between the server build output (tsconfig rootDir)
# and the hardcoded paths in the Mac app Swift code.

echo "--- Step 5c: Verifying server-seed integrity ---"
SEED_CLI="$SERVER_SEED/dist/src/cli.js"
if [[ ! -f "$SEED_CLI" ]]; then
    echo "ERROR: Server CLI entrypoint missing!"
    echo "  Expected: $SEED_CLI"
    echo "  This means the server build output structure doesn't match"
    echo "  ServerProcessManager.resolveServerCLIPath()."
    echo ""
    echo "  Check server/tsconfig.json rootDir vs the hardcoded paths in"
    echo "  OppiMac/Server/ServerProcessManager.swift"
    ls -R "$SERVER_SEED/dist/" 2>/dev/null | head -20
    exit 1
fi
echo "  CLI entrypoint: OK ($SEED_CLI)"

# Verify package manifests exist (needed for deterministic runtime reseeding)
if [[ ! -f "$SERVER_SEED/package.json" ]]; then
    echo "ERROR: server-seed/package.json missing!"
    exit 1
fi
echo "  package.json:   OK"
if [[ ! -f "$SERVER_SEED/package-lock.json" ]]; then
    echo "ERROR: server-seed/package-lock.json missing!"
    exit 1
fi
echo "  package-lock:   OK"

# Verify node_modules has key dependencies
for dep in "@anthropic-ai/sdk"; do
    dep_dir="$SERVER_SEED/node_modules/$dep"
    if [[ ! -d "$dep_dir" ]]; then
        echo "ERROR: Missing required dependency: $dep"
        exit 1
    fi
done
PI_AGENT_DEP=""
for dep in "@earendil-works/pi-coding-agent" "@mariozechner/pi-coding-agent"; do
    if [[ -d "$SERVER_SEED/node_modules/$dep" ]]; then
        PI_AGENT_DEP="$dep"
        break
    fi
done
if [[ -z "$PI_AGENT_DEP" ]]; then
    echo "ERROR: Missing required dependency: @earendil-works/pi-coding-agent (or legacy @mariozechner/pi-coding-agent)"
    exit 1
fi
echo "  Dependencies:   OK ($PI_AGENT_DEP)"

# Verify .seed-version was written
if [[ ! -f "$SERVER_SEED/.seed-version" ]]; then
    echo "ERROR: .seed-version missing!"
    exit 1
fi
echo "  Seed version:   $(cat "$SERVER_SEED/.seed-version")"

# ── Step 6: Codesign (inside-out) ──
#
# macOS codesigning requires inside-out: sign leaf Mach-O binaries first, then
# sign the outer .app which seals everything by hash. Using --deep on the outer
# app would clobber inner signatures.

echo "--- Step 6: Signing (inside-out) ---"

# 1. Sign native .node addons (clipboard, ssh2 crypto, cpu-features)
find "$RESOURCES/server-seed/node_modules" -name "*.node" -type f 2>/dev/null | while read -r addon; do
    codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$addon" 2>&1
    echo "  Signed: $(basename "$addon")"
done

# 2. Sign any other Mach-O binaries in Frameworks/ or Helpers/
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

# 3. Sign the outer .app (NO --deep — inner binaries already signed)
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH" \
    2>&1
echo "  Signed: Oppi.app"

# Verify entire bundle
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

create_dmg "$DMG_STAGING" "$DMG_PATH"

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

Oppi $VERSION aligns mobile supervision with the current Pi runtime: live terminal mirroring, a mobile bridge for Pi extension UI, broader extension API compatibility, and clearer iPad workspace navigation.

### What's new
- Mirror live Pi terminal sessions into Oppi while the terminal remains the execution owner.
- Bridge most standard Pi extension UI to Apple clients, including input and confirm flows from extensions.
- Use Pi extension API compatibility instead of custom Oppi server policy UI.
- Improve the iPad workspace shell so workspaces, sessions, and chat are easier to move between.
- Bundle \`oppi-server@$SERVER_VERSION\` with \`@earendil-works/pi-*\` $PI_AGENT_VERSION.

### Prerequisites
- macOS 26.0+
- Node.js 23.6.0 or newer installed on the Mac

### Install
1. Download \`$DMG_NAME\` below
2. Drag Oppi to Applications
3. Launch Oppi — it will check prerequisites and guide you through setup
4. If prompted, install Node.js 23.6.0+ and reopen Oppi
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
