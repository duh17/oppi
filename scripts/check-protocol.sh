#!/bin/bash
# Protocol contract check — runs both server and iOS tests to ensure
# the protocol snapshot is in sync.
#
# Usage: ./scripts/check-protocol.sh
#
# Exits 0 if both pass, 1 if either fails.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0

echo -e "${BOLD}═══ Protocol Contract Check ═══${NC}"
echo ""

# 1. Generate server snapshot + run server protocol tests
echo -e "${BOLD}[1/3] Server protocol tests...${NC}"
cd "$REPO_ROOT/server"
if npx vitest run tests/protocol-snapshots.test.ts tests/pi-event-replay.test.ts --reporter=dot 2>&1 | tail -5; then
    echo -e "${GREEN}✓ Server protocol tests passed${NC}"
else
    echo -e "${RED}✗ Server protocol tests FAILED${NC}"
    FAILURES=$((FAILURES + 1))
fi
echo ""

# 2. Run full server test suite
echo -e "${BOLD}[2/3] Server tests (full suite)...${NC}"
if npm test -- --reporter=dot 2>&1 | tail -5; then
    echo -e "${GREEN}✓ Server tests passed${NC}"
else
    echo -e "${RED}✗ Server tests FAILED${NC}"
    FAILURES=$((FAILURES + 1))
fi
echo ""

# 3. Run iOS protocol tests
echo -e "${BOLD}[3/3] iOS protocol tests...${NC}"
cd "$REPO_ROOT/ios"

# Find an iPhone simulator destination that xcodebuild accepts.
# Prefer xcodebuild's own destination list (most reliable for this scheme),
# then fall back to simctl if needed.
SIM_ID=$(xcodebuild -scheme Oppi -showdestinations 2>&1 | awk '
  /platform:iOS Simulator/ && /name:iPhone/ && $0 !~ /placeholder/ {
    line = $0
    sub(/^.*id:/, "", line)
    sub(/,.*/, "", line)
    gsub(/[[:space:]]/, "", line)
    if (line != "") {
      print line
      exit
    }
  }
')

if [ -z "$SIM_ID" ]; then
    SIM_ID=$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    if 'iOS' not in runtime: continue
    for d in devices:
        if d.get('isAvailable') and 'iPhone' in d.get('name', ''):
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null || echo "")
fi

if [ -z "$SIM_ID" ]; then
    echo -e "${RED}✗ No iOS simulator found${NC}"
    FAILURES=$((FAILURES + 1))
else
    if xcodebuild test \
        -scheme Oppi \
        -destination "platform=iOS Simulator,id=$SIM_ID" \
        -only-testing:OppiTests/ProtocolSnapshotTests \
        -quiet 2>&1 | tail -3; then
        echo -e "${GREEN}✓ iOS protocol tests passed${NC}"
    else
        echo -e "${RED}✗ iOS protocol tests FAILED${NC}"
        FAILURES=$((FAILURES + 1))
    fi
fi
echo ""

# Summary
echo -e "${BOLD}═══════════════════════════════${NC}"
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All protocol checks passed ✓${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}${FAILURES} check(s) failed ✗${NC}"
    exit 1
fi
