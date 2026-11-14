#!/bin/bash
# Xcode Cloud resolves linked xcframeworks before pre-build scripts run.
# GhosttyVt and TailscaleKit are gitignored, so a clean clone fails unless
# this script materializes them first. A vendor hit needs neither Zig nor Go.
#
# StampGitCommit reads this clone during the Xcode build. The checkout can
# fail git with "dubious ownership"; stamp-git-commit.sh marks the repo root
# safe for that read and still fails the build if git cannot resolve HEAD.
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

go_is_new_enough() {
  command -v go >/dev/null 2>&1 || return 1
  local version major minor patch
  version="$(go env GOVERSION 2>/dev/null || true)"
  [[ "$version" =~ ^go([0-9]+)\.([0-9]+)(\.([0-9]+))? ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[4]:-0}"
  # libtailscale's go.mod requires go >= 1.27.1, and the vendor script sets
  # GOTOOLCHAIN=local, so an older toolchain cannot upgrade itself. 1.27.3 is
  # the floor because 1.27.1 carries unpatched standard-library advisories that
  # ship inside TailscaleKit.
  [[ "$major" -gt 1 || "$minor" -gt 27 || ( "$minor" -eq 27 && "$patch" -ge 3 ) ]]
}

ensure_go() {
  if go_is_new_enough; then
    return
  fi
  local arch sha tarball url
  arch="$(host_arch)"
  case "$arch" in
    arm64) sha=dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2 ;;
    amd64) sha=b6f8e931e4ab497fcde6da8ae4499a58f9d258e55c8a80824a516eae5950a750 ;;
  esac
  tarball="go1.27.3.darwin-${arch}.tar.gz"
  url="https://go.dev/dl/${tarball}"
  echo "Installing Go 1.27.3"
  curl -fsSL "$url" -o "$TOOL_ROOT/$tarball"
  echo "$sha  $TOOL_ROOT/$tarball" | shasum -a 256 -c -
  rm -rf "$TOOL_ROOT/go"
  tar -xzf "$TOOL_ROOT/$tarball" -C "$TOOL_ROOT"
  ln -sfn "$TOOL_ROOT/go/bin/go" "$TOOL_ROOT/bin/go"
  go_is_new_enough
}

# Oppi.xcodeproj is generated, not tracked, so the clone has none until this script makes it.
# The release zip of the xcodegen version scripts/generate-project.sh pins, checksummed.
ensure_xcodegen() {
  local pin sha
  pin="$(head -n 1 "$ROOT/scripts/xcodegen-version.txt" | tr -d '[:space:]')"
  case "$pin" in
    2.46.0) sha=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806 ;;
    *)
      echo "error: no checksum for xcodegen $pin; add the release zip's SHA-256 to ensure_xcodegen" >&2
      exit 1
      ;;
  esac
  echo "Installing xcodegen $pin"
  curl -fsSL "https://github.com/yonaskolb/XcodeGen/releases/download/${pin}/xcodegen.zip" -o "$TOOL_ROOT/xcodegen.zip"
  echo "$sha  $TOOL_ROOT/xcodegen.zip" | shasum -a 256 -c -
  rm -rf "$TOOL_ROOT/xcodegen"
  unzip -q "$TOOL_ROOT/xcodegen.zip" -d "$TOOL_ROOT"
  # On PATH in place, not symlinked: xcodegen finds its setting presets (share/xcodegen) next to
  # the path it was started from, and without them it writes a project missing the base settings.
  export PATH="$TOOL_ROOT/xcodegen/bin:$PATH"
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
# build-ghostty-vt.sh fetches its own pinned, checksummed Zig on a cache miss.
ensure_go
"$ROOT/scripts/ensure-prebuilt-frameworks.sh"
echo "Vendored iOS frameworks are ready."
ensure_xcodegen
"$ROOT/scripts/generate-project.sh"
echo "Generated Oppi.xcodeproj."
