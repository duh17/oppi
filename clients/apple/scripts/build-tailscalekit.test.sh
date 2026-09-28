#!/usr/bin/env bash
# Proves a matching OPPI_TAILSCALEKIT_CACHE copy does not invoke go or make.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/build-tailscalekit.sh"
[[ -f "$SOURCE_SCRIPT" ]] || { echo "error: missing $SOURCE_SCRIPT" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/oppi-tailscalekit-cache.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

apple="$tmp/apple"
mkdir -p "$apple/scripts"
cp "$SOURCE_SCRIPT" "$apple/scripts/build-tailscalekit.sh"
chmod +x "$apple/scripts/build-tailscalekit.sh"

commit="$(awk -F= '/^LIBTAILSCALE_COMMIT=/{gsub(/"/, "", $2); print $2; exit}' "$apple/scripts/build-tailscalekit.sh")"
[[ -n "$commit" ]] || { echo "error: could not read LIBTAILSCALE_COMMIT" >&2; exit 1; }

cache_root="$tmp/cache"
cache_dir="$cache_root/$commit"
mkdir -p "$cache_dir/TailscaleKit.xcframework"
echo "cached-framework" >"$cache_dir/TailscaleKit.xcframework/marker"
echo "cached-license" >"$cache_dir/LICENSE"
echo "$commit" >"$cache_dir/COMMIT"

invoked="$tmp/invoked"
mkdir -p "$tmp/bin"
for cmd in go make xcodebuild git; do
  cat >"$tmp/bin/$cmd" <<EOF
#!/bin/sh
echo "$cmd" >>"$invoked"
exit 1
EOF
  chmod +x "$tmp/bin/$cmd"
done

export PATH="$tmp/bin:$PATH"
export OPPI_TAILSCALEKIT_CACHE="$cache_root"

"$apple/scripts/build-tailscalekit.sh"

vendor="$apple/Vendor/TailscaleKit"
[[ -d "$vendor/TailscaleKit.xcframework" ]] || { echo "error: vendor xcframework missing" >&2; exit 1; }
[[ "$(cat "$vendor/COMMIT")" == "$commit" ]] || { echo "error: vendor COMMIT mismatch" >&2; exit 1; }
[[ "$(cat "$vendor/LICENSE")" == "cached-license" ]] || { echo "error: vendor LICENSE not copied" >&2; exit 1; }
[[ "$(cat "$vendor/TailscaleKit.xcframework/marker")" == "cached-framework" ]] || {
  echo "error: vendor xcframework not copied from cache" >&2
  exit 1
}

if [[ -f "$invoked" ]]; then
  echo "error: cache hit invoked: $(tr '\n' ' ' <"$invoked")" >&2
  exit 1
fi

echo "ok: cache hit copied $commit without go/make"
