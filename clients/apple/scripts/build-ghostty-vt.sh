#!/usr/bin/env bash
# Build the pinned, static VT engine; no Ghostty app, renderer or GUI resources.
# A cache/vendor hit needs neither Zig nor network access. A cache miss needs
# network access and Xcode with iPhoneOS + iPhoneSimulator SDKs; it uses a
# PATH Zig only at exactly ZIG_VERSION, else the checksummed official release.
set -euo pipefail

# Ghostty main as of 2026-11-10 (libghostty-vt 1.1.0-dev, after the 1.0 C ABI
# freeze). Rex 1642 through 1853 (Rex Beta) encode their pane snapshots with
# ghostty f54340ad7 (main of 2026-10-21, go.mitchellh.com/libghostty
# df1957cbff56, read with `go version -m`); the snapshot wire format is
# unchanged since then (every golden fixture and record tag is identical;
# the changes are prompt-seen for an input cursor, a hyperlink-capacity hint
# that encoder and decoder both compute in the same field and stays
# compatible, and a Style repack), so this decoder reads what that Rex writes. It writes Kitty graphics records (tags 8-10) for a pane that
# showed an image, and decoders from 781c58e96 on skip record tags they do not
# know, so a newer Rex's optional records no longer fail the whole restore.
# Also carries OSC 7501 program status at spec revision 0.4 (b7207b2ef).
# Needs Zig >= 0.17.0 (build.zig.zon minimum_zig_version).
# The 1.0 freeze renamed and reshaped much of the C API; the Swift call sites
# follow the headers in the built xcframework.
# When bumping, re-check SSHTerminalSnapshotFeed (SSHTerminalEngine.swift)
# against src/terminal/snapshot/snapshot.zig: its record tags (`knownTags`)
# and what one `ghostty_snapshot_decoder_next` reads (HISTORY manifests, a
# page, and the header of the next known record, with that page's Kitty
# placements when they follow), since a call that reads past what has
# arrived fails the restore.
COMMIT="de70b9f476c39ce3f5b293ecba813b674f037a80"
# ReleaseFast with SIMD, as Ghostty ships it: both Release modes drop Zig's
# runtime safety checks, so Fast only trades library size for speed, and the
# vendored simdutf/highway build without libc++ into the static archive. On
# SSHTerminalThroughputBench this ran 1.4-2.7x the ReleaseSmall no-SIMD build
# on every workload except long escape codes.
# Kitty graphics is compiled in. PNG decode is an embedder callback, and
# file, temporary-file, and shared-memory loads stay off unless a terminal
# sets those options. Direct and zlib payloads do not need a PNG decoder.
ZIG_VERSION="0.17.1"
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
        arm64) arch=aarch64 sha=75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d ;;
        x86_64) arch=x86_64 sha=9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7 ;;
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
