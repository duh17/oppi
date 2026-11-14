#!/usr/bin/env bash
# Generate clients/apple/Oppi.xcodeproj from project.yml. The project is not tracked: every
# build, test, and release entry point runs this first (sim-pool.sh run does it for its runs).
#
# - xcodegen must be the version in xcodegen-version.txt; any other version fails, because two
#   versions can write different projects from the same spec.
# - Generation is skipped while the spec and its file list are unchanged (xcodegen --use-cache,
#   with the cache inside the project), so a call in a generated checkout writes nothing.
# - SwiftPM pins live in the tracked clients/apple/Package.resolved, copied into the project after
#   generation. When package resolution (Xcode, a bare xcodebuild) changed the project's copy since
#   the last copy-in, that copy is written back to the tracked file, which then shows in git diff.
#   When both changed, this fails instead of picking one.
#
# Concurrent calls in one checkout (gate lanes) are serialized on a lock inside the project.
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APPLE_DIR/Oppi.xcodeproj"

if [[ -z "${OPPI_GENERATE_PROJECT_LOCKED:-}" ]]; then
  pin="$(head -n 1 "$APPLE_DIR/scripts/xcodegen-version.txt" | tr -d '[:space:]')"
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found; this checkout pins xcodegen $pin (clients/apple/scripts/xcodegen-version.txt)." >&2
    echo "hint: install it from https://github.com/yonaskolb/XcodeGen/releases/tag/$pin (or brew install xcodegen while Homebrew ships $pin)." >&2
    exit 1
  fi
  found="$(xcodegen --version 2>/dev/null | sed -n 's/^Version: //p')"
  if [[ "$found" != "$pin" ]]; then
    echo "error: xcodegen ${found:-of unknown version} at $(command -v xcodegen), but this checkout pins $pin (clients/apple/scripts/xcodegen-version.txt)." >&2
    echo "hint: install $pin from https://github.com/yonaskolb/XcodeGen/releases/tag/$pin, or change the pin deliberately in its own commit." >&2
    exit 1
  fi
  mkdir -p "$PROJECT"
  OPPI_GENERATE_PROJECT_LOCKED=1 exec /usr/bin/lockf -k "$PROJECT/.generate.lock" /bin/bash "${BASH_SOURCE[0]}" "$@"
fi

tracked="$APPLE_DIR/Package.resolved"
copy="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
stamp="$PROJECT/.package-resolved.sha256"
cache="$PROJECT/.xcodegen-cache"

if [[ ! -f "$tracked" ]]; then
  echo "error: missing $tracked, the tracked Swift package pins." >&2
  exit 1
fi
sha() { shasum -a 256 "$1" | cut -d ' ' -f 1; }

# The cache says nothing about a project someone deleted from under it.
[[ -f "$PROJECT/project.pbxproj" ]] || rm -f "$cache"
xcodegen generate --quiet --use-cache --cache-path "$cache" --spec "$APPLE_DIR/project.yml"

tracked_sha="$(sha "$tracked")"
if [[ -f "$copy" && -f "$stamp" ]]; then
  copied_sha="$(<"$stamp")"
  copy_sha="$(sha "$copy")"
  if [[ "$copy_sha" != "$copied_sha" && "$copy_sha" != "$tracked_sha" ]]; then
    if [[ "$tracked_sha" != "$copied_sha" ]]; then
      echo "error: Swift package pins changed in both $tracked and $copy since the last generation." >&2
      echo "hint: keep the pins you want in clients/apple/Package.resolved, delete $copy, and run this again." >&2
      exit 1
    fi
    cp "$copy" "$tracked"
    tracked_sha="$copy_sha"
    echo "generate-project: package resolution changed the Swift package pins; copied them to clients/apple/Package.resolved (commit it)." >&2
  fi
fi
if ! cmp -s "$tracked" "$copy"; then
  mkdir -p "$(dirname "$copy")"
  cp "$tracked" "$copy"
fi
if [[ ! -f "$stamp" || "$(<"$stamp")" != "$tracked_sha" ]]; then
  printf '%s\n' "$tracked_sha" > "$stamp"
fi
