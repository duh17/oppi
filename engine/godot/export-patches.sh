#!/usr/bin/env bash
# Writes the Godot checkout's commits on top of the pinned tag back to
# patches/, and marks the checkout current so build.sh does not reset it.
# Use after editing engine sources in the checkout (build.sh's OPPI_GODOT_SRC).
set -euo pipefail
GODOT_COMMIT="ed1daf0bf001b61586d9930840f2f1394092c079"
HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="${OPPI_GODOT_CACHE:-$HOME/Library/Caches/oppi-godot}"
SRC="${OPPI_GODOT_SRC:-$CACHE/src}"
rm -f "$HERE"/patches/*.patch
git -C "$SRC" format-patch -q --no-signature --zero-commit -o "$HERE/patches" "$GODOT_COMMIT..HEAD"
patch_id="$(cat "$HERE"/patches/*.patch | shasum -a 256 | cut -c1-16)"
git -C "$SRC" config oppi.patchid "$GODOT_COMMIT-$patch_id"
ls "$HERE/patches"
