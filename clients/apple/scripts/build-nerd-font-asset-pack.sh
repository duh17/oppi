#!/usr/bin/env bash
# Builds the Apple-hosted Background Assets pack that delivers Nerd Font icon
# glyphs to the iOS app (NerdFontSymbols, prefetch policy):
#   clients/apple/build/asset-packs/NerdFontSymbols.aar
#
# The pack holds the official Symbols Nerd Font Mono and its license, pinned by
# release and SHA-256. The app registers the font at runtime and lists it as a
# cascade fallback behind every code font (NerdFontSymbols.swift). Nothing is
# bundled in the app binary.
#
# Upload the .aar to App Store Connect (Transporter, altool, or the App Store
# Connect API) before a TestFlight build that needs it; asset packs are versioned
# and reviewed independently of builds. Rebuild only when the pin changes.
#
# Usage: clients/apple/scripts/build-nerd-font-asset-pack.sh
set -euo pipefail

NERD_FONTS_RELEASE="v3.5.1"
FONT_FILE="SymbolsNerdFontMono-Regular.ttf"
FONT_SHA256="fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749"
LICENSE_SHA256="1f6ad4edae6479aaace3112ede5279a23284ae54b2a34db66357aef5f64df160"
BASE_URL="https://raw.githubusercontent.com/ryanoasis/nerd-fonts/$NERD_FONTS_RELEASE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=xcode-toolchain.sh
source "$SCRIPT_DIR/xcode-toolchain.sh"
oppi_use_xcode_toolchain
APPLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$APPLE_ROOT/AssetPacks/NerdFontSymbols/Manifest.json"
STAGE="$APPLE_ROOT/.build/asset-packs/NerdFontSymbols"
OUT_DIR="$APPLE_ROOT/build/asset-packs"
OUT="$OUT_DIR/NerdFontSymbols.aar"

fail() {
  echo "error: $*" >&2
  exit 1
}

fetch_verified() {
  local url="$1" dest="$2" sha="$3"
  if [[ -f "$dest" ]] && [[ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" == "$sha" ]]; then
    return
  fi
  curl -fsSL "$url" -o "$dest.tmp"
  [[ "$(shasum -a 256 "$dest.tmp" | cut -d' ' -f1)" == "$sha" ]] || {
    rm -f "$dest.tmp"
    fail "SHA-256 mismatch for $url"
  }
  mv "$dest.tmp" "$dest"
}

# The manifest's directory selector is resolved against $STAGE, and the app
# reads NerdFontSymbols/<file> from the asset-pack namespace.
mkdir -p "$STAGE/NerdFontSymbols" "$OUT_DIR"
fetch_verified "$BASE_URL/patched-fonts/NerdFontsSymbolsOnly/$FONT_FILE" "$STAGE/NerdFontSymbols/$FONT_FILE" "$FONT_SHA256"
fetch_verified "$BASE_URL/LICENSE" "$STAGE/NerdFontSymbols/LICENSE" "$LICENSE_SHA256"

(cd "$STAGE" && xcrun ba-package "$MANIFEST" -o "$OUT")
echo "Built $OUT ($NERD_FONTS_RELEASE $FONT_FILE)."
