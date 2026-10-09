#!/usr/bin/env bash
# Builds the official TailscaleKit.xcframework (github.com/tailscale/libtailscale,
# swift/) for iOS device + simulator and places it where project.yml links it:
#   clients/apple/Vendor/TailscaleKit/TailscaleKit.xcframework
#
# Shared host cache (xcframework + BUILD_ID + LICENSE):
#   ~/Library/Caches/oppi-tailscalekit/<build-id>/
# Override the cache root with OPPI_TAILSCALEKIT_CACHE. Xcode checks linked
# XCFrameworks before any Run Script phase, so the Oppi preBuild phase cannot
# restore a missing copy; ensure-prebuilt-frameworks.sh runs this script before
# xcodebuild starts.
#
# Reuse order (cache/vendor hits do not require go, make, or xcodebuild):
#   1. Vendor stamp matches the pin → exit 0 (seed the cache if it is missing)
#   2. Else the shared cache matches the pin → copy into Vendor
#   3. Else build the Go c-archives with OMIT_FEATURES, make ios-fat, write
#      Vendor and the shared cache
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
# Bump the suffix whenever OMIT_FEATURES changes so stale vendor/cache copies rebuild.
BUILD_ID="$LIBTAILSCALE_COMMIT-omit-v2"

# tailscale.com feature tags compiled out (ts_omit_<name>; list them with
# `go run tailscale.com/cmd/featuretags --list` in the libtailscale checkout).
# Oppi's node is a userspace tsnet client: interactive login, IPN bus, status,
# the loopback SOCKS5 proxy, and tailscale_dial to tailnet peers by MagicDNS
# name or tailnet IP. Everything below is unused on that path.
#
# Must stay compiled in:
# - netstack, outboundproxy: the userspace stack and the loopback SOCKS5 proxy.
# - peerapiclient: tsnet.Server.Close panics ("unreachable") without it.
# - tailnetlock: without it the node silently skips Tailnet Lock signature
#   checks, removing Lock's protection in tailnets that enable it.
# - clientmetrics, acme, serve: netstack and tsnet do not compile without them.
# MagicDNS names still resolve without `dns`: tsdial reads them from the netmap.
OMIT_FEATURES=(
  # Daemon, CLI, and host-integration features with no tsnet/iOS consumer.
  cli cliconndiag completion qrcodes doctor hujsonconf clientupdate
  desktop_sessions debug debugeventbus debugportmapper
  # Linux, cloud, and hardware integrations.
  iptables linuxdnsfight linkspeed listenrawdisco networkmanager resolved
  dbus sdnotify synology systray bird aws kube cloud tpm tap
  # Serving and advertising from this node.
  webclient ssh taildrop drive peerapiserver relayserver appconnectors
  advertiseexitnode advertiseroutes portlist wakeonlan capture netlog
  # Auth-key and policy sources Oppi does not use (it signs in interactively).
  oauthkey identityfederation syspolicy posture
  # Client extras: OS DNS config and split DNS, system HTTP proxies for control,
  # NAT-PMP/UPnP (the peer's tailscaled still maps ports), exit-node use,
  # health/captive-portal warnings and user metrics Oppi never reads, and log
  # upload to log.tailscale.com.
  dns useproxy portmapper useexitnode health captiveportal usermetrics logtail
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$APPLE_ROOT/.build/tailscalekit"
SRC_DIR="$WORK_DIR/libtailscale"
OUT_DIR="$APPLE_ROOT/Vendor/TailscaleKit"
STAMP_FILE="$OUT_DIR/BUILD_ID"
CACHE_ROOT="${OPPI_TAILSCALEKIT_CACHE:-$HOME/Library/Caches/oppi-tailscalekit}"
CACHE_DIR="$CACHE_ROOT/$BUILD_ID"

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

# $1 = source dir containing TailscaleKit.xcframework and LICENSE
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
  echo "$BUILD_ID" >"$tmp/BUILD_ID"
  rm -rf "$to"
  mv "$tmp" "$to"
}

vendor_is_current() {
  [[ -d "$OUT_DIR/TailscaleKit.xcframework" && -f "$STAMP_FILE" ]] &&
    [[ "$(cat "$STAMP_FILE")" == "$BUILD_ID" ]]
}

cache_is_current() {
  [[ -d "$CACHE_DIR/TailscaleKit.xcframework" && -f "$CACHE_DIR/BUILD_ID" && -f "$CACHE_DIR/LICENSE" ]] &&
    [[ "$(cat "$CACHE_DIR/BUILD_ID")" == "$BUILD_ID" ]]
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
    echo "TailscaleKit.xcframework is current ($BUILD_ID)."
    exit 0
  fi
  if cache_is_current; then
    install_product "$CACHE_DIR" "$OUT_DIR"
    echo "Reused TailscaleKit.xcframework from $CACHE_DIR."
    exit 0
  fi
fi

command -v go >/dev/null 2>&1 || fail "Go is required to build libtailscale (cgo c-archive)."
# shellcheck source=xcode-toolchain.sh
source "$SCRIPT_DIR/xcode-toolchain.sh"
oppi_use_xcode_toolchain
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

# The upstream Makefile hardcodes `-tags ios` and command-line tags override
# GOFLAGS, so build its three c-archive targets here with the omit tags (same
# flags and CC wrappers otherwise). -trimpath keeps this machine's module-cache
# paths out of the shipped binary. Its archive rules have no prerequisites, so
# `make ios-fat` keeps these files and only builds the frameworks + xcframework.
go_tags="ios"
for feature in "${OMIT_FEATURES[@]}"; do
  go_tags+=",ts_omit_$feature"
done
build_archive() {
  local out="$1" goarch="$2" cc="$3"
  (cd "$SRC_DIR" && CGO_ENABLED=1 GOOS=ios GOARCH="$goarch" CC="$SRC_DIR/swift/script/$cc" \
    go build -v -trimpath -ldflags -w -tags "$go_tags" -o "$out" -buildmode=c-archive)
}
build_archive libtailscale_ios.a arm64 clangwrap-ios.sh
build_archive libtailscale_ios_sim_arm64.a arm64 clangwrap-ios-sim-arm.sh
build_archive libtailscale_ios_sim_x86_64.a amd64 clangwrap-ios-sim-x86.sh

(cd "$SRC_DIR/swift" && make ios-fat)

built="$SRC_DIR/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"
[[ -d "$built" ]] || fail "make ios-fat did not produce $built"
# Fail if an upstream Makefile change rebuilt the archives without the omit tags.
if grep -q "github.com/aws/aws-sdk-go-v2" "$built/ios-arm64/TailscaleKit.framework/TailscaleKit"; then
  fail "TailscaleKit still contains omitted features; check libtailscale's Makefile archive rules"
fi
# Xcode does not strip prebuilt frameworks it embeds. Drop local symbols (~2 MB);
# Go tracebacks use pclntab, and exported C/Swift symbols stay.
for binary in "$built"/*/TailscaleKit.framework/TailscaleKit; do
  strip -x "$binary"
done

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
copy_tree "$built" "$OUT_DIR/"
cp "$SRC_DIR/LICENSE" "$OUT_DIR/LICENSE"
echo "$BUILD_ID" >"$STAMP_FILE"
install_product "$OUT_DIR" "$CACHE_DIR" ||
  echo "warning: TailscaleKit cache not updated at $CACHE_DIR" >&2
echo "Built $OUT_DIR/TailscaleKit.xcframework ($BUILD_ID)."
