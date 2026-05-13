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
#   - Node.js installed (for server build — tsc compilation)
#   - Internet access (downloads pinned Bun binary from GitHub)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APPLE_DIR/../.." && pwd)"
SERVER_DIR="$REPO_ROOT/server"
PROJECT_YML="$APPLE_DIR/project.yml"

# Pinned Bun version — update deliberately, not accidentally
BUN_VERSION_PIN="1.3.11"

# Read version from project.yml (OppiMac target)
VERSION=$(grep -A40 'OppiMac:' "$PROJECT_YML" | grep 'MARKETING_VERSION:' | head -1 | awk -F'"' '{print $2}')
BUILD_NUMBER=$(grep -A40 'OppiMac:' "$PROJECT_YML" | grep 'CURRENT_PROJECT_VERSION:' | head -1 | awk '{print $2}')

BUILD_DIR="$APPLE_DIR/build/release-mac-${VERSION}"
SIGNING_IDENTITY="Developer ID Application: Da Chen (AZAQMY4SPZ)"
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

# ── Step 5: Bundle Bun runtime (pinned version) ──

echo "--- Step 5: Bundling Bun v$BUN_VERSION_PIN ---"
RESOURCES="$APP_PATH/Contents/Resources"

BUN_CACHE_DIR="$BUILD_DIR/bun-cache"
BUN_ZIP="$BUN_CACHE_DIR/bun-darwin-aarch64-v${BUN_VERSION_PIN}.zip"
BUN_URL="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION_PIN}/bun-darwin-aarch64.zip"

# Download if not cached from a previous build
if [[ ! -f "$BUN_ZIP" ]]; then
    mkdir -p "$BUN_CACHE_DIR"
    echo "Downloading Bun v$BUN_VERSION_PIN from GitHub..."
    curl -fsSL "$BUN_URL" -o "$BUN_ZIP"

    # Verify SHA-256 checksum against Bun's published checksums
    echo "Verifying SHA-256 checksum..."
    SHASUMS_URL="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION_PIN}/SHASUMS256.txt"
    curl -fsSL "$SHASUMS_URL" -o "$BUN_CACHE_DIR/SHASUMS256.txt"
    # SHASUMS file references "bun-darwin-aarch64.zip" but our cached file has versioned name
    EXPECTED_SHA=$(grep "bun-darwin-aarch64.zip" "$BUN_CACHE_DIR/SHASUMS256.txt" | awk '{print $1}')
    ACTUAL_SHA=$(shasum -a 256 "$BUN_ZIP" | awk '{print $1}')
    [[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] || {
        echo "ERROR: SHA-256 checksum verification failed!"
        rm -f "$BUN_ZIP"
        exit 1
    }
else
    echo "Using cached Bun download."
fi

# Extract — zip contains bun-darwin-aarch64/bun
BUN_EXTRACT="$BUN_CACHE_DIR/extract"
rm -rf "$BUN_EXTRACT"
unzip -qo "$BUN_ZIP" -d "$BUN_EXTRACT"
BUN_BIN="$BUN_EXTRACT/bun-darwin-aarch64/bun"

if [[ ! -x "$BUN_BIN" ]]; then
    echo "Error: Bun binary not found in downloaded archive"
    exit 1
fi

# Verify version matches pin
ACTUAL_VERSION=$("$BUN_BIN" --version 2>/dev/null || echo "unknown")
if [[ "$ACTUAL_VERSION" != "$BUN_VERSION_PIN" ]]; then
    echo "Error: Downloaded Bun is v$ACTUAL_VERSION, expected v$BUN_VERSION_PIN"
    exit 1
fi

# Verify architecture
BUN_ARCH=$(file "$BUN_BIN" | grep -o 'arm64\|x86_64')
if [[ "$BUN_ARCH" != "arm64" ]]; then
    echo "Error: Bun binary is $BUN_ARCH, expected arm64"
    exit 1
fi

BUN_SIZE=$(du -sh "$BUN_BIN" | awk '{print $1}')
echo "Bun v$BUN_VERSION_PIN (arm64, $BUN_SIZE)"

cp "$BUN_BIN" "$RESOURCES/bun"
chmod +x "$RESOURCES/bun"

# ── Step 6: Bundle server seed ──
#
# The server runtime is DECOUPLED from the app binary:
#   - Resources/server-seed/ = immutable seed (dist + deps, for first launch)
#   - ~/.config/oppi/server-runtime/ = mutable copy (updated independently)
#
# On first launch (or app version bump), the app copies the seed to the runtime
# dir. Dependencies can then be updated without rebuilding the DMG.

echo "--- Step 6: Bundling server seed ---"
SERVER_SEED="$RESOURCES/server-seed"
mkdir -p "$SERVER_SEED"

# Copy compiled server code
cp -R "$SERVER_DIR/dist" "$SERVER_SEED/dist"

# Copy dependency manifest (needed for bun install in runtime dir)
cp "$SERVER_DIR/package.json" "$SERVER_SEED/"

# Install production deps into seed
cp "$SERVER_DIR/package-lock.json" "$SERVER_SEED/"
[[ -f "$SERVER_DIR/bun.lock" ]] && cp "$SERVER_DIR/bun.lock" "$SERVER_SEED/"
cd "$SERVER_SEED"
"$RESOURCES/bun" install --production --ignore-scripts 2>&1 | tail -3
rm -f "$SERVER_SEED/package-lock.json" "$SERVER_SEED/bun.lock"

# Write seed version (app version + build number for change detection)
echo "${VERSION}.${BUILD_NUMBER}" > "$SERVER_SEED/.seed-version"

# ── Step 6b: Strip bloat from seed node_modules ──

echo "--- Step 6b: Stripping bloat ---"
NM="$SERVER_SEED/node_modules"
BEFORE_SIZE=$(du -sh "$SERVER_SEED" | awk '{print $1}')

# Remove entire packages that are dead code on macOS
rm -rf "$NM/koffi"                                     # Windows-only FFI (86MB)
rm -rf "$NM/better-sqlite3"                            # Not needed under Bun (bun:sqlite)
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
echo "Total Resources: $TOTAL_SIZE (Bun $BUN_SIZE + seed $AFTER_SIZE)"

# ── Step 6c: Verify server-seed integrity ──
#
# Static check: verify the bundled server-seed contains everything
# ServerProcessManager.resolveServerCLIPath() expects at runtime.
# This catches path mismatches between the server build output (tsconfig rootDir)
# and the hardcoded paths in the Mac app Swift code.

echo "--- Step 6c: Verifying server-seed integrity ---"
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

# Verify package.json exists (needed for bun install in runtime dir)
if [[ ! -f "$SERVER_SEED/package.json" ]]; then
    echo "ERROR: server-seed/package.json missing!"
    exit 1
fi
echo "  package.json:   OK"

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

# ── Step 7: Codesign (inside-out) ──
#
# macOS codesigning requires inside-out: sign leaf Mach-O binaries first with
# their specific entitlements, then sign the outer .app which seals everything
# by hash. Using --deep on the outer app would clobber inner entitlements.

echo "--- Step 7: Signing (inside-out) ---"
BUN_ENTITLEMENTS="$APPLE_DIR/BunRuntime.entitlements"

# 1. Sign the bundled Bun binary with JIT entitlements.
#    Bun's JavaScriptCore JIT requires: allow-jit, allow-unsigned-executable-memory,
#    disable-executable-page-protection, disable-library-validation.
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$BUN_ENTITLEMENTS" \
    "$RESOURCES/bun" \
    2>&1
echo "  Signed: bun (JIT entitlements)"

# 2. Sign native .node addons (clipboard, ssh2 crypto, cpu-features)
find "$RESOURCES/server-seed/node_modules" -name "*.node" -type f 2>/dev/null | while read -r addon; do
    codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$addon" 2>&1
    echo "  Signed: $(basename "$addon")"
done

# 3. Sign any other Mach-O binaries in Frameworks/ or Helpers/
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

# 4. Sign the outer .app (NO --deep — inner binaries already signed)
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH" \
    2>&1
echo "  Signed: Oppi.app"

# Verify entire bundle
codesign --verify --deep --strict "$APP_PATH" 2>&1
echo "Signature verified."

# Verify Bun's JIT entitlements survived
if ! codesign -d --entitlements :- "$RESOURCES/bun" 2>&1 | grep -q "allow-jit"; then
    echo "ERROR: Bun lost JIT entitlements! Build is broken."
    exit 1
fi
echo "Bun JIT entitlements confirmed."

# ── Step 8: Create DMG ──

echo "--- Step 8: Creating DMG ---"
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

# ── Step 9: Publish GitHub release (optional) ──

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
- Bundled Bun runtime + server + pi coding agent (no external dependencies)

### Prerequisites
- macOS 15.0+

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
