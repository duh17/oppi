#!/usr/bin/env bash
# Scan for unused Swift code using Periphery.
# Requires: brew install periphery
#
# Usage:
#   bash ios/scripts/dead-code.sh              # xcode format (default)
#   bash ios/scripts/dead-code.sh --json       # json output
#   bash ios/scripts/dead-code.sh --summary    # counts only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(dirname "$SCRIPT_DIR")"

if ! command -v periphery &>/dev/null; then
  echo "error: periphery not installed. Run: brew install periphery"
  exit 1
fi

cd "$IOS_DIR"

FORMAT="xcode"
SUMMARY_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --json) FORMAT="json" ;;
    --summary) SUMMARY_ONLY=true ;;
  esac
done

if [ "$SUMMARY_ONLY" = true ]; then
  OUTPUT=$(periphery scan --format json 2>/dev/null)
  TOTAL=$(echo "$OUTPUT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  ASSIGN_ONLY=$(echo "$OUTPUT" | python3 -c "
import json, sys
results = json.load(sys.stdin)
print(len([r for r in results if 'assignOnlyProperty' in r.get('hints', [])]))
")
  REAL=$((TOTAL - ASSIGN_ONLY))
  echo "Periphery dead code scan:"
  echo "  Total findings: $TOTAL"
  echo "  Assign-only (noisy): $ASSIGN_ONLY"
  echo "  Real unused: $REAL"
else
  periphery scan --format "$FORMAT"
fi
