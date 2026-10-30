#!/usr/bin/env bash
# Build the pinned, static VT engine; no Ghostty app, renderer or GUI resources.
# A cache/vendor hit needs neither Zig nor network access. A cache miss needs
# network access and Xcode with iPhoneOS + iPhoneSimulator SDKs; it uses a
# PATH Zig only at exactly ZIG_VERSION, else the checksummed official release.
set -euo pipefail

# The ghostty revision Rex 1642 encodes its pane snapshots with (main as of
# 2026-10-21, pinned by go.mitchellh.com/libghostty df1957cbff56). It writes
# Kitty graphics records (tags 8-10) for a pane that showed an image, and
# decoders from 781c58e96 on skip record tags they do not know, so a newer
# Rex's optional records no longer fail the whole restore. Also carries OSC
# 7501 program status at spec revision 0.4 (b7207b2ef).
COMMIT="f54340ad77814fe319d136e5e915d6a48de8dd23"
# ReleaseFast with SIMD, as Ghostty ships it: both Release modes drop Zig's
# runtime safety checks, so Fast only trades library size for speed, and the
# vendored simdutf/highway build without libc++ into the static archive. On
# SSHTerminalThroughputBench this ran 1.4-2.7x the ReleaseSmall no-SIMD build
# on every workload except long escape codes.
# Kitty graphics is compiled in. PNG decode is an embedder callback, and
# file, temporary-file, and shared-memory loads stay off unless a terminal
# sets those options. Direct and zlib payloads do not need a PNG decoder.
ZIG_VERSION="0.17.0"
BUILD_ID="$COMMIT-zig$ZIG_VERSION-fast-simd-kitty-v1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/GhosttyVt"
CACHE_ROOT="${OPPI_GHOSTTY_VT_CACHE:-$HOME/Library/Caches/oppi-ghostty-vt}"
CACHE="$CACHE_ROOT/$BUILD_ID"
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
# Ghostty's build refuses any other Zig, and Homebrew moves past the pin.
# Runs inside $(...), where errexit is off, so every step returns on failure.
# Extraction goes to a private directory renamed into place, so a concurrent
# or interrupted install never leaves a partial toolchain at $dir.
pinned_zig() {
    if command -v zig >/dev/null && [[ "$(zig version)" == "$ZIG_VERSION" ]]; then
        command -v zig
        return
    fi
    local arch sha dir tmp
    case "$(uname -m)" in
        arm64) arch=aarch64 sha=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a ;;
        x86_64) arch=x86_64 sha=4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6 ;;
        *) echo "error: no Zig $ZIG_VERSION download for $(uname -m)" >&2; return 1 ;;
    esac
    dir="$CACHE_ROOT/zig-$arch-macos-$ZIG_VERSION"
    if [[ ! -x "$dir/zig" ]]; then
        tmp="$CACHE_ROOT/.zig-$ZIG_VERSION.$$"
        rm -rf "$tmp"
        mkdir -p "$tmp" || return 1
        echo "Downloading Zig $ZIG_VERSION" >&2
        curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-$arch-macos-$ZIG_VERSION.tar.xz" \
            -o "$tmp/zig.tar.xz" || { rm -rf "$tmp"; return 1; }
        echo "$sha  $tmp/zig.tar.xz" | shasum -a 256 -c - >&2 || { rm -rf "$tmp"; return 1; }
        tar -xJf "$tmp/zig.tar.xz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
        # Another run may have installed it meanwhile; keep theirs. A $dir with
        # no zig was damaged outside this script (installs arrive by rename), so
        # replace it. mv onto an existing directory would nest inside it.
        [[ -x "$dir/zig" ]] || rm -rf "$dir"
        if [[ ! -e "$dir" ]]; then
            mv "$tmp/zig-$arch-macos-$ZIG_VERSION" "$dir" || [[ -x "$dir/zig" ]] ||
                { rm -rf "$tmp"; return 1; }
        fi
        rm -rf "$tmp"
    fi
    [[ "$("$dir/zig" version)" == "$ZIG_VERSION" ]] || { echo "error: $dir/zig is not $ZIG_VERSION" >&2; return 1; }
    printf '%s\n' "$dir/zig"
}
ZIG="$(pinned_zig)"
# shellcheck source=xcode-toolchain.sh
source "$ROOT/scripts/xcode-toolchain.sh"
oppi_use_xcode_toolchain
command -v xcodebuild >/dev/null || { echo 'error: Xcode is required to build GhosttyVt' >&2; exit 1; }
mkdir -p "$WORK"
if [[ ! -d "$WORK/source/.git" ]]; then
    git init -q "$WORK/source"
    git -C "$WORK/source" remote add origin https://github.com/ghostty-org/ghostty.git
fi
git -C "$WORK/source" fetch -q --depth 1 origin "$COMMIT"
git -C "$WORK/source" checkout -q --detach "$COMMIT"
(cd "$WORK/source" && "$ZIG" build -Demit-lib-vt=true -Demit-xcframework=true \
    -Doptimize=ReleaseFast -Dsimd=true \
    --prefix "$WORK/output")
# A fresh product dir: copying into a previous one would keep a stale archive
# beside the new one when the library file name changes.
rm -rf "$WORK/product"
mkdir -p "$WORK/product"
cp -R "$WORK/output/lib/ghostty-vt.xcframework" "$WORK/product/"
printf '%s\n' "$BUILD_ID" > "$WORK/product/BUILD_ID"
current "$WORK/product" || { echo 'error: missing iOS device/simulator slices' >&2; exit 1; }
install_product "$WORK/product" "$VENDOR"
install_product "$WORK/product" "$CACHE"
echo "Built $VENDOR/ghostty-vt.xcframework ($BUILD_ID)."
