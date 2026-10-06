#!/usr/bin/env bash
# Build the pinned, static VT engine; no Ghostty app, renderer or GUI resources.
# A cache/vendor hit needs neither Zig nor network access. A cache miss needs
# Zig 0.16.0 and Xcode with iPhoneOS + iPhoneSimulator SDKs.
set -euo pipefail

COMMIT="33da6848d63b3bba2b4f31ab1531d618f2795192"
# SIMD stays off so the static lib does not bundle those C++ libraries.
# Kitty graphics is compiled in. PNG decode is an embedder callback, and
# file, temporary-file, and shared-memory loads stay off unless a terminal
# sets those options. Direct and zlib payloads do not need a PNG decoder.
BUILD_ID="$COMMIT-zig0.16.0-small-nosimd-kitty-v1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/GhosttyVt"
CACHE="${OPPI_GHOSTTY_VT_CACHE:-$HOME/Library/Caches/oppi-ghostty-vt}/$BUILD_ID"
WORK="$ROOT/.build/ghostty-vt"

current() {
    [[ -f "$1/BUILD_ID" && -d "$1/ghostty-vt.xcframework/ios-arm64" &&
       -d "$1/ghostty-vt.xcframework/ios-arm64-simulator" ]] &&
        [[ "$(<"$1/BUILD_ID")" == "$BUILD_ID" ]]
}
install_product() {
    local src="$1" dest="$2" tmp
    mkdir -p "$(dirname "$dest")"
    tmp="$dest.tmp.$$"
    mkdir -p "$tmp"
    cp -R "$src/ghostty-vt.xcframework" "$tmp/"
    printf '%s\n' "$BUILD_ID" > "$tmp/BUILD_ID"
    # Only generated products owned by this script are replaced.
    rm -rf "$dest"
    mv "$tmp" "$dest"
}
if current "$VENDOR"; then
    if ! current "$CACHE"; then install_product "$VENDOR" "$CACHE"; fi
    echo "GhosttyVt is current ($BUILD_ID)."
    exit 0
fi
if current "$CACHE"; then
    install_product "$CACHE" "$VENDOR"
    echo "Reused GhosttyVt from $CACHE."
    exit 0
fi
command -v zig >/dev/null || { echo 'error: install Zig 0.16.0 to build GhosttyVt' >&2; exit 1; }
[[ "$(zig version)" == '0.16.0' ]] || { echo 'error: GhosttyVt requires exactly Zig 0.16.0' >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo 'error: Xcode is required to build GhosttyVt' >&2; exit 1; }
mkdir -p "$WORK"
if [[ ! -d "$WORK/source/.git" ]]; then
    git init -q "$WORK/source"
    git -C "$WORK/source" remote add origin https://github.com/ghostty-org/ghostty.git
fi
git -C "$WORK/source" fetch -q --depth 1 origin "$COMMIT"
git -C "$WORK/source" checkout -q --detach "$COMMIT"
(cd "$WORK/source" && zig build -Demit-lib-vt=true -Demit-xcframework=true \
    -Doptimize=ReleaseSmall -Dsimd=false \
    --prefix "$WORK/output")
mkdir -p "$WORK/product"
cp -R "$WORK/output/lib/ghostty-vt.xcframework" "$WORK/product/"
printf '%s\n' "$BUILD_ID" > "$WORK/product/BUILD_ID"
current "$WORK/product" || { echo 'error: missing iOS device/simulator slices' >&2; exit 1; }
install_product "$WORK/product" "$VENDOR"
install_product "$WORK/product" "$CACHE"
echo "Built $VENDOR/ghostty-vt.xcframework ($BUILD_ID)."
