#!/bin/bash
# Xcode Cloud resolves linked xcframeworks before pre-build scripts run.
# GhosttyVt and TailscaleKit are gitignored, so a clean clone fails unless
# this script materializes them first. A vendor hit needs neither Zig nor Go.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL_ROOT="${OPPI_CI_TOOL_ROOT:-${TMPDIR:-/tmp}/oppi-ci-tools}"
mkdir -p "$TOOL_ROOT/bin"
export PATH="$TOOL_ROOT/bin:$PATH"

host_arch() {
  case "$(uname -m)" in
    arm64) printf 'arm64\n' ;;
    x86_64) printf 'amd64\n' ;;
    *)
      echo "error: unsupported arch $(uname -m)" >&2
      exit 1
      ;;
  esac
}

ensure_zig() {
  if command -v zig >/dev/null 2>&1 && [[ "$(zig version)" == "0.16.0" ]]; then
    return
  fi
  local zarch tarball url
  case "$(uname -m)" in
    arm64) zarch="aarch64" ;;
    x86_64) zarch="x86_64" ;;
    *)
      echo "error: unsupported arch $(uname -m)" >&2
      exit 1
      ;;
  esac
  tarball="zig-${zarch}-macos-0.16.0.tar.xz"
  url="https://ziglang.org/download/0.16.0/${tarball}"
  echo "Installing Zig 0.16.0"
  curl -fsSL "$url" -o "$TOOL_ROOT/$tarball"
  tar -xJf "$TOOL_ROOT/$tarball" -C "$TOOL_ROOT"
  ln -sfn "$TOOL_ROOT/zig-${zarch}-macos-0.16.0/zig" "$TOOL_ROOT/bin/zig"
  [[ "$(zig version)" == "0.16.0" ]]
}

go_is_new_enough() {
  command -v go >/dev/null 2>&1 || return 1
  local version major minor patch
  version="$(go env GOVERSION 2>/dev/null || true)"
  [[ "$version" =~ ^go([0-9]+)\.([0-9]+)(\.([0-9]+))? ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[4]:-0}"
  # libtailscale's go.mod requires go >= 1.25.5, and the vendor script sets
  # GOTOOLCHAIN=local, so an older toolchain cannot upgrade itself.
  [[ "$major" -gt 1 || "$minor" -gt 25 || ( "$minor" -eq 25 && "$patch" -ge 5 ) ]]
}

ensure_go() {
  if go_is_new_enough; then
    return
  fi
  local arch tarball url
  arch="$(host_arch)"
  tarball="go1.27.1.darwin-${arch}.tar.gz"
  url="https://go.dev/dl/${tarball}"
  echo "Installing Go 1.27.1"
  curl -fsSL "$url" -o "$TOOL_ROOT/$tarball"
  rm -rf "$TOOL_ROOT/go"
  tar -xzf "$TOOL_ROOT/$tarball" -C "$TOOL_ROOT"
  ln -sfn "$TOOL_ROOT/go/bin/go" "$TOOL_ROOT/bin/go"
  go_is_new_enough
}

ensure_zig
ensure_go
"$ROOT/scripts/build-ghostty-vt.sh"
"$ROOT/scripts/build-tailscalekit.sh"
echo "Vendored iOS frameworks are ready."
