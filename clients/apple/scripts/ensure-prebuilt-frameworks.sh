#!/usr/bin/env bash
# Puts every untracked prebuilt XCFramework the Oppi target links into Vendor/
# before xcodebuild starts.
#
# Xcode validates linked XCFrameworks while it plans the build, before any Run
# Script phase executes, so the target's preBuild phases cannot restore a
# missing Vendor/ copy in a fresh checkout or worktree. sim-pool.sh run and
# Xcode Cloud run this script first.
#
# Each build script exits immediately when Vendor/ matches its pin, copies from
# the shared host cache when it can, and builds from source only on a cache
# miss. Concurrent runs in one checkout share this lock so one run never
# replaces Vendor/ while another is installing it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK="$APPLE_ROOT/.build/prebuilt-frameworks.lock"
mkdir -p "$APPLE_ROOT/.build"

# Probe with a no-op so exit 75 can only mean "lock held", then say why we wait.
if ! /usr/bin/lockf -k -s -t 0 "$LOCK" /usr/bin/true; then
  echo "Waiting for $LOCK (another run is preparing Vendor/)..." >&2
fi
exec /usr/bin/lockf -k "$LOCK" \
  /bin/bash -c '"$1/build-ghostty-vt.sh" && "$1/build-tailscalekit.sh"' _ "$SCRIPT_DIR"
