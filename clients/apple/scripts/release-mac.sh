#!/usr/bin/env bash
#
# release-mac.sh — Build, sign, notarize, and package Oppi for Mac distribution.
#
# Usage:
#   ./scripts/release-mac.sh 1.0.1
#   ./scripts/release-mac.sh 1.0.1 --skip-notarize   # local testing without credentials
#
# Prerequisites:
#   - Xcode with "Developer ID Application" certificate
#   - Sparkle EdDSA private key in Keychain (run generate_keys once)
#   - Notarization profile stored: xcrun notarytool store-credentials "oppi-notary"
#   - XcodeGen installed (brew install xcodegen)
#
# What this script does:
#   1. Regenerates the Xcode project from project.yml
#   2. Archives the OppiMac scheme
#   3. Exports a Developer ID signed .app
#   4. Packages the .app into a DMG
#   5. Code-signs the DMG
#   6. Signs the DMG with Sparkle EdDSA for update verification
#   7. Generates/updates the Sparkle appcast
#   8. Notarizes the DMG with Apple (unless --skip-notarize)
#   9. Staples the notarization ticket to the DMG
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$IOS_DIR/build"
APPCAST_DIR="$SCRIPT_DIR/appcast"

# Sparkle tools path (resolved from Xcode DerivedData)
SPARKLE_BIN="$(ls -d ~/Library/Developer/Xcode/DerivedData/Oppi-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)"

# ── Argument parsing ──

VERSION="${1:-}"
SKIP_NOTARIZE=false

for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
    esac
done

if [[ -z "$VERSION" || "$VERSION" == --* ]]; then
    echo "Usage: $0 <version> [--skip-notarize]"
    echo "  e.g. $0 1.0.1"
    exit 1
fi

if [[ -z "$SPARKLE_BIN" ]]; then
    echo "Error: Sparkle tools not found in DerivedData."
    echo "Build the OppiMac scheme in Xcode first to resolve the Sparkle package."
    exit 1
fi

echo "=== Oppi Mac Release v${VERSION} ==="
echo "Build dir:    $BUILD_DIR"
echo "Appcast dir:  $APPCAST_DIR"
echo "Sparkle bin:  $SPARKLE_BIN"
echo "Notarize:     $( $SKIP_NOTARIZE && echo 'skipped' || echo 'yes' )"
echo ""

# ── Step 1: Generate Xcode project ──

echo "--- Step 1: Generating Xcode project ---"
cd "$IOS_DIR"
xcodegen generate
echo "Done."

# ── Step 2: Archive ──

echo "--- Step 2: Archiving OppiMac ---"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild archive \
    -project Oppi.xcodeproj \
    -scheme OppiMac \
    -archivePath "$BUILD_DIR/OppiMac.xcarchive" \
    MARKETING_VERSION="$VERSION" \
    | tail -5

if [[ ! -d "$BUILD_DIR/OppiMac.xcarchive" ]]; then
    echo "Error: Archive failed — $BUILD_DIR/OppiMac.xcarchive not found."
    exit 1
fi
echo "Archive created."

# ── Step 3: Export ──

echo "--- Step 3: Exporting Developer ID signed app ---"
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/OppiMac.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$IOS_DIR/ExportOptions-Mac.plist" \
    | tail -5

if [[ ! -d "$BUILD_DIR/export/Oppi.app" ]]; then
    echo "Error: Export failed — $BUILD_DIR/export/Oppi.app not found."
    exit 1
fi
echo "Export complete."

# ── Step 4: Create DMG ──

DMG_NAME="Oppi-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "--- Step 4: Creating DMG ---"
hdiutil create \
    -volname "Oppi" \
    -srcfolder "$BUILD_DIR/export/Oppi.app" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [[ ! -f "$DMG_PATH" ]]; then
    echo "Error: DMG creation failed."
    exit 1
fi
echo "DMG created: $DMG_PATH"

# ── Step 5: Code-sign the DMG ──

echo "--- Step 5: Code-signing DMG ---"
if codesign --sign "Developer ID Application" "$DMG_PATH" 2>/dev/null; then
    echo "DMG code-signed."
else
    echo "Warning: Could not sign DMG with 'Developer ID Application' identity."
    echo "  This is expected if you don't have the certificate installed."
    echo "  The DMG will still work but won't pass Gatekeeper without notarization."
fi

# ── Step 6: Sparkle EdDSA signature ──

echo "--- Step 6: Signing DMG with Sparkle EdDSA ---"
EDDSA_SIG=$("$SPARKLE_BIN/sign_update" "$DMG_PATH")
echo "EdDSA signature info:"
echo "$EDDSA_SIG"

# ── Step 7: Generate appcast ──

echo "--- Step 7: Generating appcast ---"
mkdir -p "$APPCAST_DIR"

# Copy the DMG to the appcast directory so generate_appcast can index it.
# generate_appcast scans a directory of DMGs and produces appcast.xml.
cp "$DMG_PATH" "$APPCAST_DIR/"

"$SPARKLE_BIN/generate_appcast" "$APPCAST_DIR"
echo "Appcast updated: $APPCAST_DIR/appcast.xml"

# ── Step 8: Notarize ──

if $SKIP_NOTARIZE; then
    echo "--- Step 8: Notarization skipped (--skip-notarize) ---"
else
    echo "--- Step 8: Submitting for notarization ---"
    echo "  This may take several minutes..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "oppi-notary" \
        --wait

    if [[ $? -ne 0 ]]; then
        echo "Error: Notarization failed."
        echo "  Check the submission log for details."
        exit 1
    fi
    echo "Notarization complete."

    # ── Step 9: Staple ──

    echo "--- Step 9: Stapling notarization ticket ---"
    xcrun stapler staple "$DMG_PATH"
    echo "Stapled."
fi

# ── Summary ──

echo ""
echo "=== Release v${VERSION} complete ==="
echo "DMG:     $DMG_PATH"
echo "Appcast: $APPCAST_DIR/appcast.xml"
echo ""
echo "Next steps:"
echo "  1. Upload $DMG_NAME to GitHub Releases"
echo "  2. Upload appcast.xml to the appcast hosting location"
echo "     (currently: https://github.com/duh17/oppi/releases/download/appcast/appcast.xml)"
echo "  3. Verify 'Check for Updates' in an existing install finds the new version"
