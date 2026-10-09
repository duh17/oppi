#!/bin/bash
# Write the git commit for Info.plist preprocessing.
# ProcessInfoPlistFile runs after script phases and would overwrite a
# post-build PlistBuddy edit, so the value has to be in the plist input.
# Format: 12-char SHA, plus -dirty when the worktree is not clean.
#
# Git must succeed. A missing checkout fails the build; do not stamp a
# placeholder. Inherited GIT_DIR (pre-push) is ignored so status reads this
# checkout. safe.directory covers Xcode Cloud's dubious-ownership refusal
# without skipping the stamp. OPPI_REPO_ROOT overrides SRCROOT/../.. .
set -euo pipefail

repo_root="${OPPI_REPO_ROOT:-$(cd "$SRCROOT/../.." && pwd)}"

if [ -z "${DERIVED_FILE_DIR:-}" ]; then
  echo "error: DERIVED_FILE_DIR is unset; cannot write OPPIGitCommit.h" >&2
  exit 1
fi

# Hook and CI environments can export GIT_DIR. Discover the checkout ourselves.
git_in_repo() {
  env \
    -u GIT_DIR \
    -u GIT_WORK_TREE \
    -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY \
    -u GIT_COMMON_DIR \
    -u GIT_PREFIX \
    -u GIT_NAMESPACE \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    git -c safe.directory='*' -c "safe.directory=${repo_root}" -C "$repo_root" "$@"
}

fail_stamp() {
  echo "error: cannot stamp OPPIGitCommit from ${repo_root}: $1" >&2
  echo "hint: build the Oppi target from a git checkout, or set OPPI_REPO_ROOT to the repository root" >&2
  exit 1
}

inside=""
if ! inside="$(git_in_repo rev-parse --is-inside-work-tree 2>&1)"; then
  fail_stamp "git rev-parse failed (${inside})"
fi
if [ "$inside" != "true" ]; then
  fail_stamp "not a git work tree"
fi

commit=""
if ! commit="$(git_in_repo rev-parse --short=12 HEAD 2>&1)"; then
  fail_stamp "git rev-parse HEAD failed (${commit})"
fi
# --short=12 is a minimum; git lengthens an ambiguous abbreviation.
if ! [[ "$commit" =~ ^[0-9a-f]{12,40}$ ]]; then
  fail_stamp "expected a 12-40 character commit, got '${commit}'"
fi

status_output=""
if ! status_output="$(git_in_repo status --porcelain --untracked-files=normal 2>&1)"; then
  fail_stamp "git status failed (${status_output})"
fi
dirty=""
if [ -n "$status_output" ]; then
  dirty="-dirty"
fi
value="${commit}${dirty}"

header="$DERIVED_FILE_DIR/OPPIGitCommit.h"
mkdir -p "$DERIVED_FILE_DIR"
tmp="${header}.tmp.$$"
printf '#define OPPI_GIT_COMMIT_VALUE %s\n' "$value" > "$tmp"
if [ -f "$header" ] && cmp -s "$tmp" "$header"; then
  rm -f "$tmp"
  echo "note: OPPIGitCommit=$value unchanged; left $header"
else
  mv -f "$tmp" "$header"
  echo "note: stamped OPPIGitCommit=$value into $header"
fi
