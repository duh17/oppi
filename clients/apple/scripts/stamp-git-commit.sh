#!/bin/bash
# Stamp the current git commit into the built Info.plist.
# Format: 12-char SHA, plus -dirty when the worktree is not clean.
set -euo pipefail

repo_root="${OPPI_REPO_ROOT:-$(cd "$SRCROOT/../.." && pwd)}"
commit="unknown"
dirty=""
if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  commit="$(git -C "$repo_root" rev-parse --short=12 HEAD)"
  if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]; then
    dirty="-dirty"
  fi
fi
value="${commit}${dirty}"

plist="${CODESIGNING_FOLDER_PATH:-}/Info.plist"
if [ ! -f "$plist" ]; then
  plist="${TARGET_BUILD_DIR:-}/${INFOPLIST_PATH:-}"
fi
if [ ! -f "$plist" ]; then
  echo "error: built Info.plist missing; cannot stamp OPPIGitCommit" >&2
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c "Set :OPPIGitCommit $value" "$plist" 2>/dev/null; then
  /usr/libexec/PlistBuddy -c "Add :OPPIGitCommit string $value" "$plist"
fi
echo "note: stamped OPPIGitCommit=$value into $plist"

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
  exit 0
fi
if [ -z "${CODESIGNING_FOLDER_PATH:-}" ] || [ ! -d "$CODESIGNING_FOLDER_PATH" ]; then
  exit 0
fi
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity="${CODE_SIGN_IDENTITY:--}"
fi
if [ -z "$identity" ]; then
  identity="-"
fi
if ! /usr/bin/codesign --force --sign "$identity" --preserve-metadata=identifier,entitlements "$CODESIGNING_FOLDER_PATH"; then
  echo "warning: re-sign after OPPIGitCommit stamp failed" >&2
fi
