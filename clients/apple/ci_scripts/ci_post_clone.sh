#!/bin/bash
# Xcode Cloud resolves linked xcframeworks before pre-build scripts run.
# GhosttyVt and TailscaleKit are gitignored, so a clean clone fails unless
# this script materializes them first. A vendor hit needs neither Zig nor Go.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Xcode Cloud images do not have /Applications/Xcode-27.1.app. The shared
# helper (xcode-toolchain.sh) refuses to consult xcode-select, so this script
# exports DEVELOPER_DIR only when Apple's CI_XCODE_CLOUD is TRUE. That
# variable is always available and its documented value is TRUE. CI_WORKSPACE
# is not a documented name; the workspace path is CI_WORKSPACE_PATH.
# `xcode-select -p` is read-only. Do not add this fallback to the shared helper.
oppi_ci_select_xcode() {
  if [[ "${CI_XCODE_CLOUD:-}" != "TRUE" ]]; then
    return 0
  fi

  local pin_file pin name expected selected version_text first_line
  pin_file="$ROOT/scripts/xcode-toolchain.txt"
  if [[ ! -f "$pin_file" ]]; then
    echo "error: missing Xcode pin: $pin_file" >&2
    exit 1
  fi
  pin="$(head -n 1 "$pin_file" | tr -d '[:space:]')"
  name="${pin##*/}"
  expected="${name#Xcode-}"
  expected="${expected%.app}"
  if [[ -z "$expected" || "$expected" == "$name" ]]; then
    echo "error: pinned Xcode app name has no version: $pin" >&2
    exit 1
  fi

  # A set DEVELOPER_DIR makes `xcode-select -p` echo that path, hiding the
  # workflow selection. Query without it. Never `xcode-select -s`.
  if ! selected="$(env -u DEVELOPER_DIR xcode-select -p)"; then
    echo "error: xcode-select -p failed. Xcode Cloud did not report a selected Xcode." >&2
    echo "hint: set the workflow Xcode version to ${expected} in App Store Connect (Environment)." >&2
    exit 1
  fi
  if [[ ! -d "$selected" ]]; then
    echo "error: Xcode Cloud selected Xcode is missing: ${selected:-<empty>}" >&2
    echo "hint: set the workflow Xcode version to ${expected} in App Store Connect (Environment)." >&2
    exit 1
  fi

  if ! version_text="$(DEVELOPER_DIR="$selected" xcodebuild -version)"; then
    echo "error: xcodebuild -version failed for $selected" >&2
    exit 1
  fi
  first_line="${version_text%%$'\n'*}"
  first_line="${first_line%$'\r'}"
  if [[ "$first_line" != "Xcode $expected" ]]; then
    echo "error: Xcode Cloud selected Xcode is not ${expected} (${first_line} at ${selected})." >&2
    echo "hint: set the workflow Xcode version to ${expected} in App Store Connect (Environment)." >&2
    exit 1
  fi

  export DEVELOPER_DIR="$selected"
  printf '%s\n' "$version_text"
  echo "DEVELOPER_DIR=$DEVELOPER_DIR"
}

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

# Sourcing defines oppi_ci_select_xcode and does not install tools or build.
# Executing the script selects the Xcode Cloud toolchain, then vendors frameworks.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

TOOL_ROOT="${OPPI_CI_TOOL_ROOT:-${TMPDIR:-/tmp}/oppi-ci-tools}"
mkdir -p "$TOOL_ROOT/bin"
export PATH="$TOOL_ROOT/bin:$PATH"

oppi_ci_select_xcode
ensure_zig
ensure_go
"$ROOT/scripts/build-ghostty-vt.sh"
"$ROOT/scripts/build-tailscalekit.sh"
echo "Vendored iOS frameworks are ready."
