#!/usr/bin/env bash
#
# testflight.sh — Archive, upload to App Store Connect, optionally submit to external beta.
#
# Usage:
#   ./scripts/testflight.sh --bump                          # bump build number, archive, upload
#   ./scripts/testflight.sh --bump --submit-external        # + submit to "Pi Discord Beta"
#   ./scripts/testflight.sh --build-number 25               # explicit build number
#   ./scripts/testflight.sh --build-only                    # archive + export IPA only (no upload)
#
# Prerequisites:
#   - Xcode with automatic signing (team AZAQMY4SPZ)
#   - ASC API key: ~/.appstoreconnect/AuthKey_<KEY_ID>.p8
#   - ASC issuer ID: ~/.appstoreconnect/issuer_id
#   - XcodeGen installed (brew install xcodegen)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_YML="$APPLE_DIR/project.yml"
BUILD_DIR="$APPLE_DIR/build/testflight-$(date +%Y%m%d-%H%M%S)"

# ASC credentials — set ASC_KEY_ID in env or ~/.appstoreconnect/key_id
ASC_KEY_ID="${ASC_KEY_ID:-$(cat ~/.appstoreconnect/key_id 2>/dev/null || echo "")}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(cat ~/.appstoreconnect/issuer_id 2>/dev/null || echo "")}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/AuthKey_${ASC_KEY_ID}.p8}"

# Sentry: disabled for TestFlight by default
SENTRY_DSN="${SENTRY_DSN:-}"

# ── Argument parsing ──

BUMP=false
BUILD_ONLY=false
SUBMIT_EXTERNAL=false
EXTERNAL_GROUP="Pi Discord Beta"
EXPLICIT_BUILD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bump) BUMP=true; shift ;;
        --build-only) BUILD_ONLY=true; shift ;;
        --build-number) EXPLICIT_BUILD="$2"; shift 2 ;;
        --submit-external)
            SUBMIT_EXTERNAL=true
            if [[ "${2:-}" != "" && "${2:-}" != --* ]]; then
                EXTERNAL_GROUP="$2"; shift
            fi
            shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if ! $BUMP && [[ -z "$EXPLICIT_BUILD" ]]; then
    echo "Error: specify --bump or --build-number <N>"
    exit 1
fi

# ── Validate credentials ──

if ! $BUILD_ONLY; then
    if [[ -z "$ASC_ISSUER_ID" ]]; then
        echo "Error: ASC_ISSUER_ID not set and ~/.appstoreconnect/issuer_id not found"
        exit 1
    fi
    if [[ ! -f "$ASC_KEY_PATH" ]]; then
        echo "Error: API key not found at $ASC_KEY_PATH"
        exit 1
    fi
fi

# ── Step 1: Determine build number ──

CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | awk '{print $2}')

if [[ -n "$EXPLICIT_BUILD" ]]; then
    NEW_BUILD="$EXPLICIT_BUILD"
elif $BUMP; then
    NEW_BUILD=$((CURRENT_BUILD + 1))
fi

echo "=== Oppi TestFlight Build ==="
echo "Build number: $CURRENT_BUILD → $NEW_BUILD"
echo "Build dir:    $BUILD_DIR"
echo "Sentry:       ${SENTRY_DSN:-disabled}"
echo ""

# ── Step 2: Update build number in project.yml ──

if [[ "$NEW_BUILD" != "$CURRENT_BUILD" ]]; then
    echo "--- Step 2: Bumping build number to $NEW_BUILD ---"
    # Replace all CURRENT_PROJECT_VERSION entries
    sed -i '' "s/CURRENT_PROJECT_VERSION: ${CURRENT_BUILD}/CURRENT_PROJECT_VERSION: ${NEW_BUILD}/g" "$PROJECT_YML"
    echo "Done."
else
    echo "--- Step 2: Build number unchanged ($CURRENT_BUILD) ---"
fi

# ── Step 3: Generate Xcode project ──

echo "--- Step 3: Generating Xcode project ---"
cd "$APPLE_DIR"
xcodegen generate 2>&1
echo "Done."

# ── Step 4: Archive ──

echo "--- Step 4: Archiving Oppi (Release, iOS device) ---"
mkdir -p "$BUILD_DIR"

xcodebuild archive \
    -project Oppi.xcodeproj \
    -scheme Oppi \
    -archivePath "$BUILD_DIR/Oppi.xcarchive" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates \
    SENTRY_DSN="$SENTRY_DSN" \
    CURRENT_PROJECT_VERSION="$NEW_BUILD" \
    2>&1 | tail -20

if [[ ! -d "$BUILD_DIR/Oppi.xcarchive" ]]; then
    echo "Error: Archive failed — $BUILD_DIR/Oppi.xcarchive not found."
    exit 1
fi
echo "Archive created."

# ── Step 5: Export / Upload ──

if $BUILD_ONLY; then
    echo "--- Step 5: Exporting IPA (build-only, no upload) ---"
    # Use a plain app-store export without upload
    cat > "$BUILD_DIR/ExportOptions-local.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>AZAQMY4SPZ</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/Oppi.xcarchive" \
        -exportPath "$BUILD_DIR/export" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-local.plist" \
        -allowProvisioningUpdates \
        2>&1 | tail -10
    echo ""
    echo "IPA exported to: $BUILD_DIR/export/"
else
    echo "--- Step 5: Exporting + uploading to App Store Connect ---"
    xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/Oppi.xcarchive" \
        -exportPath "$BUILD_DIR/export" \
        -exportOptionsPlist "$APPLE_DIR/ExportOptions-AppStore.plist" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
        2>&1 | tail -20
    echo "Upload complete."
fi

# ── Step 6: Submit for external beta (optional) ──

if $SUBMIT_EXTERNAL && ! $BUILD_ONLY; then
    echo "--- Step 6: Submitting to external beta group '$EXTERNAL_GROUP' ---"
    echo ""
    echo "Note: The build needs to finish processing in App Store Connect before"
    echo "it can be submitted to external beta review. This typically takes 5-15 minutes."
    echo ""
    echo "To submit manually:"
    echo "  1. Open App Store Connect → Oppi → TestFlight"
    echo "  2. Find build $NEW_BUILD"
    echo "  3. Add to group '$EXTERNAL_GROUP'"
    echo "  4. Submit for Beta App Review"
    echo ""
    echo "Or wait for processing and re-run with the ASC API."
fi

# ── Summary ──

echo ""
echo "=== TestFlight build $NEW_BUILD complete ==="
echo "Archive:  $BUILD_DIR/Oppi.xcarchive"
if [[ -d "$BUILD_DIR/export" ]]; then
    echo "Export:   $BUILD_DIR/export/"
fi
if ! $BUILD_ONLY; then
    echo "Status:   Uploaded to App Store Connect"
    echo ""
    echo "Next: check TestFlight in App Store Connect for build $NEW_BUILD"
fi
