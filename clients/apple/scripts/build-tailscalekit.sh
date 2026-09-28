#!/usr/bin/env bash
# Builds the official TailscaleKit.xcframework (github.com/tailscale/libtailscale,
# swift/) for iOS device + simulator and places it where project.yml links it:
#   clients/apple/Vendor/TailscaleKit/TailscaleKit.xcframework
#
# Shared host cache (xcframework + COMMIT + LICENSE):
#   ~/Library/Caches/oppi-tailscalekit/<commit>/
# Override the cache root with OPPI_TAILSCALEKIT_CACHE. The Oppi preBuild
# phase runs this script so a fresh checkout that already has the cache does
# not fail the missing-framework link.
#
# Reuse order (cache/vendor hits do not require go, make, or xcodebuild):
#   1. Vendor stamp matches the pin → exit 0 (seed the cache if it is missing)
#   2. Else the shared cache matches the pin → copy into Vendor
#   3. Else make ios-fat, write Vendor and the shared cache
#
# The output is not tracked: the Go c-archive makes it far larger than the
# repository's 5 MB file limit. A cache miss needs Go (cgo) and Xcode. Go
# module and build caches stay under clients/apple/.build/tailscalekit, and
# GOTOOLCHAIN=local prevents toolchain downloads, so nothing is installed
# outside the checkout.
#
# The frameworks are built unsigned (CODE_SIGNING_ALLOWED=NO). The Oppi target
# embeds them with codeSign: true, so Xcode signs them with the app identity.
#
# Usage: clients/apple/scripts/build-tailscalekit.sh [--force]
set -euo pipefail

LIBTAILSCALE_REPO="https://github.com/tailscale/libtailscale.git"
# Bump deliberately; the stamp file forces a rebuild when this changes.
LIBTAILSCALE_COMMIT="59d4bb82744915815178e0f0776d60026a397ee7"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$APPLE_ROOT/.build/tailscalekit"
SRC_DIR="$WORK_DIR/libtailscale"
OUT_DIR="$APPLE_ROOT/Vendor/TailscaleKit"
STAMP_FILE="$OUT_DIR/COMMIT"
CACHE_ROOT="${OPPI_TAILSCALEKIT_CACHE:-$HOME/Library/Caches/oppi-tailscalekit}"
CACHE_DIR="$CACHE_ROOT/$LIBTAILSCALE_COMMIT"

fail() {
  echo "error: $*" >&2
  exit 1
}

copy_tree() {
  local src="$1"
  local dest="$2"
  if cp -cR "$src" "$dest" 2>/dev/null; then
    return
  fi
  cp -R "$src" "$dest"
}

# $1 = source dir containing TailscaleKit.xcframework, LICENSE, and COMMIT
install_product() {
  local from="$1"
  local to="$2"
  local parent tmp
  parent="$(dirname "$to")"
  tmp="$parent/.$(basename "$to").$$"
  mkdir -p "$parent"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  copy_tree "$from/TailscaleKit.xcframework" "$tmp/"
  cp "$from/LICENSE" "$tmp/LICENSE"
  echo "$LIBTAILSCALE_COMMIT" >"$tmp/COMMIT"
  rm -rf "$to"
  mv "$tmp" "$to"
}

vendor_is_current() {
  [[ -d "$OUT_DIR/TailscaleKit.xcframework" && -f "$STAMP_FILE" ]] &&
    [[ "$(cat "$STAMP_FILE")" == "$LIBTAILSCALE_COMMIT" ]]
}

cache_is_current() {
  [[ -d "$CACHE_DIR/TailscaleKit.xcframework" && -f "$CACHE_DIR/COMMIT" && -f "$CACHE_DIR/LICENSE" ]] &&
    [[ "$(cat "$CACHE_DIR/COMMIT")" == "$LIBTAILSCALE_COMMIT" ]]
}

seed_cache_from_vendor() {
  if cache_is_current; then
    return
  fi
  if [[ ! -f "$OUT_DIR/LICENSE" ]]; then
    return
  fi
  install_product "$OUT_DIR" "$CACHE_DIR" ||
    echo "warning: TailscaleKit cache not updated at $CACHE_DIR" >&2
}

force=0
case "${1:-}" in
  "") ;;
  --force) force=1 ;;
  *) fail "unknown argument: $1 (usage: $0 [--force])" ;;
esac

if [[ $force -eq 0 ]]; then
  if vendor_is_current; then
    seed_cache_from_vendor
    echo "TailscaleKit.xcframework is current ($LIBTAILSCALE_COMMIT)."
    exit 0
  fi
  if cache_is_current; then
    install_product "$CACHE_DIR" "$OUT_DIR"
    echo "Reused TailscaleKit.xcframework from $CACHE_DIR."
    exit 0
  fi
fi

command -v go >/dev/null 2>&1 || fail "Go is required to build libtailscale (cgo c-archive)."
command -v xcodebuild >/dev/null 2>&1 || fail "Xcode is required to build TailscaleKit."

mkdir -p "$WORK_DIR"
if [[ ! -d "$SRC_DIR/.git" ]]; then
  git init --quiet "$SRC_DIR"
  git -C "$SRC_DIR" remote add origin "$LIBTAILSCALE_REPO"
fi
git -C "$SRC_DIR" fetch --quiet --depth 1 origin "$LIBTAILSCALE_COMMIT"
git -C "$SRC_DIR" checkout --quiet --force "$LIBTAILSCALE_COMMIT"
git -C "$SRC_DIR" clean --quiet -fdx

export GOMODCACHE="$WORK_DIR/gomodcache"
export GOCACHE="$WORK_DIR/gocache"
export GOFLAGS="-modcacherw"
export GOTOOLCHAIN="local"
# Newer Go toolchains enable the jsonv2 experiment by default, which switches
# github.com/go-json-experiment/json (pinned by tailscale.com) to an alias file
# that no longer matches encoding/json/v2. Build with the Go 1.25 default.
export GOEXPERIMENT="nojsonv2"

# ios-fat builds the device and simulator c-archives, the two frameworks, and
# the combined xcframework. The Makefile's CC wrappers resolve from $PWD.
(cd "$SRC_DIR/swift" && make ios-fat)

built="$SRC_DIR/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"
[[ -d "$built" ]] || fail "make ios-fat did not produce $built"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
copy_tree "$built" "$OUT_DIR/"
cp "$SRC_DIR/LICENSE" "$OUT_DIR/LICENSE"
echo "$LIBTAILSCALE_COMMIT" >"$STAMP_FILE"
install_product "$OUT_DIR" "$CACHE_DIR" ||
  echo "warning: TailscaleKit cache not updated at $CACHE_DIR" >&2
echo "Built $OUT_DIR/TailscaleKit.xcframework ($LIBTAILSCALE_COMMIT)."
