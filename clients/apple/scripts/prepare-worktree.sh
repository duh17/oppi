#!/usr/bin/env bash
# Symlink gitignored directories from the main tree into a worktree.
#
# Usage: prepare-worktree.sh <worktree-path>
#
# Problem: ios/scripts/ and server/scripts/ are mostly gitignored.
# Worktrees get a clean checkout without sim-pool.sh, architecture
# boundary checks, etc. Builds fail in the worktree.
#
# Solution: symlink the gitignored script dirs from the main tree.
# Also handles node_modules which are never in git.

set -euo pipefail

WORKTREE="${1:?Usage: prepare-worktree.sh <worktree-path>}"

# Find the main working tree (the one that isn't a worktree)
MAIN_TREE="$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$MAIN_TREE" ]]; then
    echo "Error: $WORKTREE is not inside a git repository" >&2
    exit 1
fi

# The main tree is the commondir for worktrees
GIT_COMMON="$(git -C "$WORKTREE" rev-parse --git-common-dir)"
MAIN_TREE="$(cd "$GIT_COMMON/.." && pwd)"

# If this IS the main tree, nothing to do
if [[ "$WORKTREE" -ef "$MAIN_TREE" ]]; then
    echo "This is the main tree, nothing to symlink."
    exit 0
fi

echo "Main tree: $MAIN_TREE"
echo "Worktree:  $WORKTREE"

# Directories to symlink (gitignored in main, needed for builds)
SYMLINK_DIRS=(
    "ios/scripts"
    "server/scripts"
    "server/node_modules"
    "server/config"
)

# Per-worktree exclude file — prevents symlinks from being tracked.
# This is the worktree-local equivalent of .gitignore but never shared
# with other worktrees or committed. Avoids the merge-back gotcha where
# tracked symlinks replace real directories on main.
EXCLUDE_FILE="$(git -C "$WORKTREE" rev-parse --git-dir)/info/exclude"
mkdir -p "$(dirname "$EXCLUDE_FILE")"

for dir in "${SYMLINK_DIRS[@]}"; do
    src="$MAIN_TREE/$dir"
    dst="$WORKTREE/$dir"

    if [[ ! -d "$src" ]]; then
        echo "  skip $dir (not in main tree)"
        continue
    fi

    if [[ -L "$dst" ]]; then
        echo "  ok   $dir (already symlinked)"
        # Still ensure exclude entry exists
    else
        if [[ -d "$dst" ]]; then
            # Worktree has a real dir (from tracked files) — merge by
            # removing the dir and symlinking. The tracked files exist
            # in the symlink target too (it's the same repo).
            rm -rf "$dst"
        fi

        mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst"
        echo "  link $dir -> $src"
    fi

    # Add to worktree-local exclude if not already present
    if ! grep -qxF "/$dir" "$EXCLUDE_FILE" 2>/dev/null; then
        echo "/$dir" >> "$EXCLUDE_FILE"
        echo "  exclude /$dir (added to .git/info/exclude)"
    fi
done

echo "Done. Worktree is ready for builds."
