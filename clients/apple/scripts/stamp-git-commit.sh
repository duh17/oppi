#!/bin/bash
# Write the git commit for Info.plist preprocessing.
# ProcessInfoPlistFile runs after script phases and would overwrite a
# post-build PlistBuddy edit, so the value has to be in the plist input.
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

if [ -z "${DERIVED_FILE_DIR:-}" ]; then
  echo "error: DERIVED_FILE_DIR is unset; cannot write OPPIGitCommit.h" >&2
  exit 1
fi
header="$DERIVED_FILE_DIR/OPPIGitCommit.h"
mkdir -p "$DERIVED_FILE_DIR"
printf '#define OPPI_GIT_COMMIT_VALUE %s\n' "$value" > "$header"
echo "note: stamped OPPIGitCommit=$value into $header"
