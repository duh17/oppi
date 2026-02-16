#!/usr/bin/env bash
set -euo pipefail

# ─── TestFlight Build & Upload ───────────────────────────────────
#
# Builds a release archive, exports for App Store distribution,
# and uploads to App Store Connect / TestFlight.
#
# Prerequisites (one-time setup):
#   1. Apple Developer account (set OPPI_TEAM_ID or edit TEAM_ID below)
#   2. App Store Connect API key (.p8 file) with "Admin" or "App Manager" role
#   3. App created in App Store Connect matching your bundle ID in project.yml
#
# Setup:
#   mkdir -p ~/.appstoreconnect
#   mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/
#   # Add to your shell profile:
#   export ASC_KEY_ID="XXXXXXXXXX"
#   export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#   export OPPI_TEAM_ID="YOUR_TEAM_ID"   # optional, defaults to project.yml value
#
# Usage:
#   ios/scripts/testflight.sh              # build + upload
#   ios/scripts/testflight.sh --build-only # archive + export, skip upload
#   ios/scripts/testflight.sh --bump       # auto-increment build number
#   ios/scripts/testflight.sh --skip-generate  # skip xcodegen
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCHEME="Oppi"
TEAM_ID="${OPPI_TEAM_ID:-AZAQMY4SPZ}"

BUILD_ONLY=0
BUMP=0
SKIP_GENERATE=0
BUILD_NUMBER=""

usage() {
  cat <<'EOF'
Build, archive, and upload Oppi to TestFlight.

Usage:
  ios/scripts/testflight.sh [options]

Options:
  --build-only       Archive and export IPA, skip upload
  --bump             Auto-increment build number (CURRENT_PROJECT_VERSION)
  --build-number N   Set explicit build number
  --skip-generate    Skip xcodegen generate
  -h, --help         Show this help

Environment:
  ASC_KEY_ID         App Store Connect API Key ID
  ASC_ISSUER_ID      App Store Connect Issuer ID
  ASC_KEY_PATH       Path to AuthKey .p8 file (optional, auto-detected)
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=1; shift ;;
    --bump) BUMP=1; shift ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --skip-generate) SKIP_GENERATE=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1"; usage 1 ;;
  esac
done

# ─── Resolve API key ────────────────────────────────────────────

resolve_asc_key() {
  if [[ -n "${ASC_KEY_PATH:-}" && -f "$ASC_KEY_PATH" ]]; then
    return 0
  fi

  if [[ -n "${ASC_KEY_ID:-}" ]]; then
    local candidates=(
      "$HOME/.appstoreconnect/AuthKey_${ASC_KEY_ID}.p8"
      "$HOME/.private_keys/AuthKey_${ASC_KEY_ID}.p8"
      "$HOME/AuthKey_${ASC_KEY_ID}.p8"
    )
    for path in "${candidates[@]}"; do
      if [[ -f "$path" ]]; then
        ASC_KEY_PATH="$path"
        return 0
      fi
    done
  fi

  # Search for any .p8 key
  for dir in "$HOME/.appstoreconnect" "$HOME/.private_keys"; do
    if [[ -d "$dir" ]]; then
      local found
      found=$(find "$dir" -name "AuthKey_*.p8" -print -quit 2>/dev/null)
      if [[ -n "$found" ]]; then
        ASC_KEY_PATH="$found"
        local basename
        basename=$(basename "$found" .p8)
        ASC_KEY_ID="${ASC_KEY_ID:-${basename#AuthKey_}}"
        return 0
      fi
    fi
  done

  return 1
}

if ! resolve_asc_key; then
  echo "error: No App Store Connect API key found."
  echo ""
  echo "One-time setup:"
  echo "  1. Go to https://appstoreconnect.apple.com/access/integrations/api"
  echo "  2. Create a new key with 'Admin' or 'App Manager' role"
  echo "  3. Download the .p8 file"
  echo "  4. mkdir -p ~/.appstoreconnect"
  echo "  5. mv ~/Downloads/AuthKey_XXXXXXXX.p8 ~/.appstoreconnect/"
  echo "  6. export ASC_KEY_ID=XXXXXXXX"
  echo "  7. export ASC_ISSUER_ID=xxxxxxxx-xxxx-... (shown on the API keys page)"
  echo ""
  exit 1
fi

if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
  echo "error: ASC_KEY_ID and ASC_ISSUER_ID must be set."
  echo "  export ASC_KEY_ID=<your-key-id>"
  echo "  export ASC_ISSUER_ID=<your-issuer-id>"
  exit 1
fi

echo "── API Key: $ASC_KEY_ID (${ASC_KEY_PATH})"

# Common xcodebuild auth flags — used for archive, export, and upload.
# This lets xcodebuild auto-create Distribution certificates and profiles.
AUTH_FLAGS=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

# ─── Directories ─────────────────────────────────────────────────

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_DIR="$IOS_DIR/build/testflight-$TIMESTAMP"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

mkdir -p "$BUILD_DIR"

# ─── Version bump ────────────────────────────────────────────────

cd "$IOS_DIR"

if [[ -n "$BUILD_NUMBER" ]]; then
  echo "── Setting build number: $BUILD_NUMBER"
  sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD_NUMBER/" project.yml
elif [[ "$BUMP" -eq 1 ]]; then
  CURRENT=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | awk '{print $2}')
  NEXT=$((CURRENT + 1))
  echo "── Bumping build number: $CURRENT → $NEXT"
  sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $NEXT/" project.yml
  BUILD_NUMBER="$NEXT"
else
  BUILD_NUMBER=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | awk '{print $2}')
fi

VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)"/\1/')
echo "── Version: $VERSION ($BUILD_NUMBER)"

# ─── Generate project ───────────────────────────────────────────

if [[ "$SKIP_GENERATE" -eq 0 ]]; then
  echo "── Generating Xcode project..."
  xcodegen generate
fi

# ─── Archive ─────────────────────────────────────────────────────

echo "── Archiving $SCHEME (Release)..."

ARCHIVE_LOG="$BUILD_DIR/archive.log"

xcodebuild archive \
  -project Oppi.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH_FLAGS[@]}" \
  2>&1 | tee "$ARCHIVE_LOG" | tail -5

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "error: Archive failed. Full log: $ARCHIVE_LOG"
  exit 1
fi

echo "── Archive OK"

# ─── Export Options plist ────────────────────────────────────────

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
PLIST

# ─── Export IPA ──────────────────────────────────────────────────

echo "── Exporting IPA..."

EXPORT_LOG="$BUILD_DIR/export.log"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  "${AUTH_FLAGS[@]}" \
  2>&1 | tee "$EXPORT_LOG" | tail -5

# With destination=upload, xcodebuild uploads directly during export.
# Check if export log confirms success (no local IPA created in this mode).
if grep -q "EXPORT SUCCEEDED" "$EXPORT_LOG"; then
  if grep -q "Upload succeeded" "$EXPORT_LOG"; then
    echo ""
    echo "── Done! Version $VERSION ($BUILD_NUMBER) uploaded via cloud signing."
    echo "   TestFlight build available in ~5-15 minutes."
    echo "   https://appstoreconnect.apple.com/apps"
    exit 0
  fi
fi

# Fallback: check for local IPA (build-only or non-upload destination)
IPA_PATH="$EXPORT_DIR/$SCHEME.ipa"
if [[ ! -f "$IPA_PATH" ]]; then
  echo "error: Export failed. Full log: $EXPORT_LOG"
  exit 1
fi

echo "── IPA: $IPA_PATH ($(du -h "$IPA_PATH" | cut -f1))"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo ""
  echo "── Build complete (--build-only). IPA at:"
  echo "   $IPA_PATH"
  exit 0
fi

echo "── Uploading to App Store Connect..."

xcrun altool --upload-package "$IPA_PATH" \
  -t ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID" \
  2>&1

echo ""
echo "── Done! Version $VERSION ($BUILD_NUMBER) uploaded."
echo "   TestFlight build available in ~5-15 minutes."
echo "   https://appstoreconnect.apple.com/apps"
