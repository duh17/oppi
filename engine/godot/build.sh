#!/usr/bin/env bash
# Builds OppiGodot.xcframework, the Godot pane's engine: official Godot at a
# pinned tag, the patch series in patches/, and the oppigodot module
# (modules/oppigodot, C API in include/OppiGodot.h), as a static
# template_debug library for iOS devices (Metal) and the simulator (OpenGL;
# Godot compiles Metal out of simulator builds). template_debug because
# script reload and script backtraces exist only in debug templates.
#
# The binary never enters the repository. It lands in a local cache keyed by
# its inputs (BUILD_ID: the Godot commit, this script, the patches and the
# module), and clients/apple/scripts/install-oppi-godot.sh installs it into
# Vendor/ when the cache holds the current id. An app built without it has
# no game engine; nothing else changes.
#
#   build.sh               build the product (VARIANT=stripped) into the cache
#   build.sh --print-id    print the product's BUILD_ID and exit (no build)
#
#   OPPI_GODOT_CACHE  cache root (default ~/Library/Caches/oppi-godot): one
#                     <BUILD_ID>/ folder per product, and the Godot checkout
#   OPPI_GODOT_SRC    the Godot checkout (default $OPPI_GODOT_CACHE/src); any
#                     checkout of the pinned tag, reset to it plus patches/
#   JOBS              scons -j (default 12; other work shares the machine)
#   VARIANT           stripped (the product) | stripped-size | stripped-fb | stock.
#                     stripped-size (optimize=size) is the smaller candidate,
#                     to adopt only if it costs the device under 5% frame time;
#                     the others compare sizes (design §4). No variant uses
#                     LTO: its archives are bitcode, which an xcframework
#                     cannot hold and the app would re-optimise on every link.
#   SLICES            "device simulator" (default) or a subset
#
# The compiler is the Xcode the app builds with (clients/apple/scripts/
# xcode-toolchain.txt, through DEVELOPER_DIR), so the archive and the app
# share one toolchain.
set -euo pipefail

GODOT_TAG="4.7.2-stable"
GODOT_COMMIT="ed1daf0bf001b61586d9930840f2f1394092c079"

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLCHAIN="$HERE/../../clients/apple/scripts"
CACHE="${OPPI_GODOT_CACHE:-$HOME/Library/Caches/oppi-godot}"
SRC="${OPPI_GODOT_SRC:-$CACHE/src}"
JOBS="${JOBS:-12}"
VARIANT="${VARIANT:-stripped}"
SLICES="${SLICES:-device simulator}"

inputs_hash() {
    (cd "$HERE" && {
        cat build.sh size-probe.c patches/*.patch "$TOOLCHAIN/xcode-toolchain.txt"
        find modules -type f ! -name '*.pyc' | LC_ALL=C sort | xargs cat
    }) | shasum -a 256 | cut -c1-16
}
BUILD_ID="${GODOT_COMMIT:0:12}-$(inputs_hash)-$VARIANT"
if [[ "${1:-}" == "--print-id" ]]; then
    echo "$BUILD_ID"
    exit 0
fi
# shellcheck source=../../clients/apple/scripts/xcode-toolchain.sh
source "$TOOLCHAIN/xcode-toolchain.sh"
oppi_use_xcode_toolchain

# Checkout: the pinned commit plus our patches, reset only when either changes.
patch_id="$(cat "$HERE"/patches/*.patch | shasum -a 256 | cut -c1-16)"
if [[ ! -d "$SRC/.git" ]]; then
    mkdir -p "$SRC"
    git -C "$SRC" init -q
    git -C "$SRC" remote add origin https://github.com/godotengine/godot.git
fi
if [[ "$(git -C "$SRC" config --get oppi.patchid || true)" != "$GODOT_COMMIT-$patch_id" ]]; then
    git -C "$SRC" fetch -q --depth 1 origin tag "$GODOT_TAG"
    [[ "$(git -C "$SRC" rev-parse "$GODOT_TAG^{commit}")" == "$GODOT_COMMIT" ]] || {
        echo "error: $GODOT_TAG is not $GODOT_COMMIT" >&2
        exit 1
    }
    git -C "$SRC" checkout -q -B oppi "$GODOT_COMMIT"
    git -C "$SRC" -c user.name=oppi -c user.email=oppi@localhost am -q "$HERE"/patches/*.patch
    git -C "$SRC" config oppi.patchid "$GODOT_COMMIT-$patch_id"
fi
# A checkout with changes the patches do not hold, new files included, would
# build under an id that does not describe it: export them (export-patches.sh)
# or drop them. Build products are in Godot's own .gitignore.
patches=("$HERE"/patches/*.patch)
if [[ -n "$(git -C "$SRC" status --porcelain)" ]] ||
    [[ "$(git -C "$SRC" rev-list --count "$GODOT_COMMIT..HEAD")" != "${#patches[@]}" ]]; then
    echo "error: $SRC holds changes patches/ does not; run export-patches.sh or reset it" >&2
    exit 1
fi

common=(
    platform=ios target=template_debug arch=arm64
    library_type=static_library
    vulkan=no metal=yes
    custom_modules="$HERE/modules"
    # Source paths reach the binary through __FILE__ in error messages; name
    # them from neutral roots, never this machine's folders. (scons splits
    # ccflags on spaces, so neither root may hold one.)
    ccflags="-ffile-prefix-map=$HERE/=oppi-engine/ -ffile-prefix-map=$SRC/=godot/"
    debug_symbols=no
    # Templates refuse --main-pack unless path overrides are compiled in;
    # the host names its pack on the command line.
    disable_path_overrides=no
    "-j$JOBS"
)
# Design §4: module groups a pane game never needs. Networking is off in the
# sandbox anyway; camera off keeps the privacy rule; the import-time modules
# only matter to the editor (exported packs carry imported resources).
stripped=(
    disable_xr=yes deprecated=no
    module_enet_enabled=no module_multiplayer_enabled=no module_webrtc_enabled=no
    module_websocket_enabled=no module_upnp_enabled=no module_mbedtls_enabled=no
    module_jsonrpc_enabled=no
    module_openxr_enabled=no module_webxr_enabled=no module_mobile_vr_enabled=no
    module_camera_enabled=no module_mono_enabled=no
    module_gltf_enabled=no module_fbx_enabled=no module_vhacd_enabled=no
    module_meshoptimizer_enabled=no module_xatlas_unwrap_enabled=no
    module_lightmapper_rd_enabled=no module_astcenc_enabled=no module_betsy_enabled=no
    module_cvtt_enabled=no module_etcpak_enabled=no
    module_tinyexr_enabled=no module_hdr_enabled=no module_dds_enabled=no
    module_ktx_enabled=no module_tga_enabled=no module_bmp_enabled=no
    module_theora_enabled=no module_basis_universal_enabled=no
    module_godot_physics_3d_enabled=no
)
case "$VARIANT" in
    stock) flags=() ;;
    stripped) flags=("${stripped[@]}") ;;
    stripped-fb) flags=("${stripped[@]}" module_text_server_adv_enabled=no module_text_server_fb_enabled=yes) ;;
    stripped-size) flags=("${stripped[@]}" optimize=size) ;;
    *) echo "error: unknown VARIANT $VARIANT" >&2; exit 1 ;;
esac

libs=()
for slice in $SLICES; do
    sim=no
    [[ "$slice" == simulator ]] && sim=yes
    # extra_suffix names objects and libraries per variant (and Godot adds
    # .simulator), so variants and slices build side by side incrementally.
    (cd "$SRC" && scons "${common[@]}" "${flags[@]}" simulator="$sim" extra_suffix="$VARIANT")
    lib="$SRC/bin/libgodot.ios.template_debug.arm64.$VARIANT.a"
    [[ "$sim" == yes ]] && lib="$SRC/bin/libgodot.ios.template_debug.arm64.simulator.$VARIANT.a"
    [[ -f "$lib" ]] || { echo "error: missing $lib" >&2; exit 1; }
    libs+=("$lib")
done

# Headers sit in an OppiGodot/ subfolder: clang finds a module map in a
# folder named after the module under an include path.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/headers" "$work/headers/OppiGodot"
cp "$HERE/modules/oppigodot/include/OppiGodot.h" "$work/headers/OppiGodot/"
cat > "$work/headers/OppiGodot/module.modulemap" <<'EOF'
module OppiGodot {
    header "OppiGodot.h"
    link "c++"
    link "z"
    export *
}
EOF

# Linked size: size-probe.c calls every entry point, so -dead_strip keeps what
# the app's link keeps; stripped of local symbols, as the spike measured it
# (MB = 10^6 bytes).
linked_size() {
    local lib="$1"
    xcrun --sdk iphoneos clang -target arm64-apple-ios26.0 -O2 -I "$work/headers" \
        "$HERE/size-probe.c" "$lib" -lc++ -lz -dead_strip -o "$work/probe" 2>"$work/link.log" || {
        echo "warning: size link failed: $(tail -3 "$work/link.log")" >&2
        return 0
    }
    strip -x "$work/probe"
    printf '%s: %.1f MB linked and stripped\n' "$VARIANT" "$(($(stat -f %z "$work/probe")))e-6"
}

dest="$CACHE/$BUILD_ID"
rm -rf "$dest.tmp"
mkdir -p "$dest.tmp"
args=()
for lib in "${libs[@]}"; do
    args+=(-library "$lib" -headers "$work/headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$dest.tmp/OppiGodot.xcframework" >/dev/null
printf '%s\n' "$BUILD_ID" > "$dest.tmp/BUILD_ID"
for lib in "${libs[@]}"; do
    [[ "$lib" == *simulator* ]] && continue
    linked_size "$lib" | tee "$dest.tmp/LINKED_SIZE"
done
rm -rf "$dest"
mv "$dest.tmp" "$dest"
echo "$dest/OppiGodot.xcframework"
