#!/usr/bin/env bash
# Orchestrates iOS E2E tests:
# 1. Starts server (Docker by default, or native process with --native)
# 2. Generates invite URL for pairing
# 3. Runs XCUITests with invite URL passed via temp file
# 4. Tears down server
#
# Usage:
#   ./e2e.sh              # Docker mode (default)
#   ./e2e.sh --native     # Native mode (skips Docker, ~30-60s faster)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/server/e2e/docker-compose.e2e.yml"

# ── Flag parsing ──

NATIVE_MODE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --native) NATIVE_MODE=true; shift ;;
        *) echo "[e2e] Unknown option: $1"; exit 1 ;;
    esac
done

if $NATIVE_MODE; then
    echo "[e2e] Running in NATIVE mode (no Docker)"
else
    echo "[e2e] Running in DOCKER mode"
fi

E2E_PORT="${E2E_PORT:-17760}"
MLX_PORT="${E2E_MLX_PORT:-9847}"
MLX_HOST_URL="http://localhost:${MLX_PORT}"
INVITE_FILE="/tmp/oppi-e2e-invite.txt"
MODELS_JSON=""
SERVER_PID=""
DATA_DIR=""

# ── Cleanup ──

cleanup() {
    if $NATIVE_MODE; then
        echo "[e2e] Stopping native server..."
        [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null || true
        [ -n "$DATA_DIR" ] && rm -rf "$DATA_DIR"
    else
        echo "[e2e] Tearing down Docker server..."
        docker compose -f "$COMPOSE_FILE" down -v --timeout 10 2>/dev/null || true
        [ -n "$MODELS_JSON" ] && rm -f "$MODELS_JSON"
    fi
    rm -f "$INVITE_FILE"
    echo "[e2e] Cleanup complete."
}
trap cleanup EXIT

# ── 1. Probe MLX server for loaded model ──

echo "[e2e] Checking MLX server at $MLX_HOST_URL ..."
MLX_RESPONSE=$(curl -fsS "$MLX_HOST_URL/v1/models" 2>/dev/null) || {
    echo "[e2e] ERROR: MLX server not reachable at $MLX_HOST_URL"
    echo "[e2e] Start an MLX server (e.g. mlx_lm.server) on port $MLX_PORT first."
    exit 1
}

MODEL_ID=$(echo "$MLX_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null) || {
    echo "[e2e] ERROR: No models loaded on MLX server"
    exit 1
}
echo "[e2e] Found MLX model: $MODEL_ID"
E2E_MODEL="mlx-server/$MODEL_ID"

# ── 2. Start server ──

if $NATIVE_MODE; then
    # Build if source is newer than dist
    if [ ! -d "$REPO_ROOT/server/dist" ] || \
       [ "$(find "$REPO_ROOT/server/src" -newer "$REPO_ROOT/server/dist" -print -quit)" ]; then
        echo "[e2e] Building server..."
        (cd "$REPO_ROOT/server" && npm run build)
    else
        echo "[e2e] Server dist/ is up to date, skipping build"
    fi

    # Create temp data dir
    DATA_DIR=$(mktemp -d /tmp/oppi-e2e-native-XXXXXX)
    echo "[e2e] Data dir: $DATA_DIR"

    # Configure server via CLI
    (
        cd "$REPO_ROOT/server"
        OPPI_DATA_DIR="$DATA_DIR" node dist/cli.js config set port "$E2E_PORT"
        OPPI_DATA_DIR="$DATA_DIR" node dist/cli.js config set host "127.0.0.1"
    )

    # Generate models.json in pi-agent dir (localhost, not host.docker.internal)
    PI_AGENT_DIR="$DATA_DIR/pi-agent"
    mkdir -p "$PI_AGENT_DIR"
    cat > "$PI_AGENT_DIR/models.json" <<EOF
{
  "providers": {
    "mlx-server": {
      "baseUrl": "http://localhost:${MLX_PORT}/v1",
      "apiKey": "DUMMY",
      "api": "openai-completions",
      "models": [{
        "id": "$MODEL_ID",
        "name": "E2E MLX Model",
        "contextWindow": 32768,
        "maxTokens": 8192,
        "input": ["text"],
        "reasoning": true,
        "compat": { "thinkingFormat": "qwen" },
        "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
      }]
    }
  }
}
EOF
    echo "[e2e] Generated models.json at $PI_AGENT_DIR/models.json"

    # Start server as background process
    echo "[e2e] Starting native server on port $E2E_PORT ..."
    (
        cd "$REPO_ROOT/server"
        exec env OPPI_DATA_DIR="$DATA_DIR" PI_CODING_AGENT_DIR="$PI_AGENT_DIR" \
            node dist/cli.js serve
    ) > "$DATA_DIR/server.log" 2>&1 &
    SERVER_PID=$!
    echo "[e2e] Server PID: $SERVER_PID"
else
    # Generate models.json for Docker container (host.docker.internal for MLX)
    MODELS_JSON=$(mktemp /tmp/oppi-e2e-models-XXXXXX.json)
    cat > "$MODELS_JSON" <<EOF
{
  "providers": {
    "mlx-server": {
      "baseUrl": "http://host.docker.internal:${MLX_PORT}/v1",
      "apiKey": "DUMMY",
      "api": "openai-completions",
      "models": [{
        "id": "$MODEL_ID",
        "name": "E2E MLX Model",
        "contextWindow": 32768,
        "maxTokens": 8192,
        "input": ["text"],
        "reasoning": true,
        "compat": { "thinkingFormat": "qwen" },
        "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
      }]
    }
  }
}
EOF
    echo "[e2e] Generated models.json at $MODELS_JSON"

    # Start Docker server
    echo "[e2e] Starting Docker server on port $E2E_PORT ..."
    E2E_PORT="$E2E_PORT" E2E_MODELS_JSON="$MODELS_JSON" \
        docker compose -f "$COMPOSE_FILE" up -d --build --wait --wait-timeout 120
fi

# ── 3. Wait for health ──

echo "[e2e] Waiting for server health..."
for i in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${E2E_PORT}/health" >/dev/null 2>&1; then
        echo "[e2e] Server healthy after ${i}s"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[e2e] ERROR: Server did not become healthy within 60s"
        if $NATIVE_MODE && [ -f "$DATA_DIR/server.log" ]; then
            echo "[e2e] Server log tail:"
            tail -20 "$DATA_DIR/server.log"
        fi
        exit 1
    fi
    sleep 1
done

# ── 4. Set default model ──

echo "[e2e] Setting defaultModel to $E2E_MODEL ..."
if $NATIVE_MODE; then
    (cd "$REPO_ROOT/server" && OPPI_DATA_DIR="$DATA_DIR" node dist/cli.js config set defaultModel "$E2E_MODEL")
else
    docker exec oppi-e2e node dist/cli.js config set defaultModel "$E2E_MODEL"
fi

# ── 5. Pre-create a workspace via API ──
# Must happen BEFORE generating the app's invite, because issuePairingToken
# replaces the previous token (single token at a time).

echo "[e2e] Pre-creating workspace via API..."

# Generate a pairing token and pair from the script to get a device token
if $NATIVE_MODE; then
    SCRIPT_PAIRING_TOKEN=$(cd "$REPO_ROOT/server" && OPPI_DATA_DIR="$DATA_DIR" \
        node --input-type=module -e '
import { Storage } from "./dist/storage.js";
const s = new Storage(process.env.OPPI_DATA_DIR);
console.log(s.issuePairingToken(600000));
')
else
    GEN_PAIR_SCRIPT=$(mktemp /tmp/oppi-e2e-gen-pair-XXXXXX.mjs)
    cat > "$GEN_PAIR_SCRIPT" <<'PAIR_EOF'
import { Storage } from "./dist/storage.js";
const storage = new Storage(process.env.OPPI_DATA_DIR);
const pt = storage.issuePairingToken(600000);
console.log(pt);
PAIR_EOF

    docker cp "$GEN_PAIR_SCRIPT" oppi-e2e:/opt/oppi-server/gen-pair.mjs
    rm -f "$GEN_PAIR_SCRIPT"
    SCRIPT_PAIRING_TOKEN=$(docker exec -w /opt/oppi-server oppi-e2e node gen-pair.mjs)
fi

DEVICE_TOKEN=$(curl -fsS "http://127.0.0.1:${E2E_PORT}/pair" \
    -H "Content-Type: application/json" \
    -d "{\"pairingToken\": \"${SCRIPT_PAIRING_TOKEN}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['deviceToken'])")

echo "[e2e] Paired with device token: ${DEVICE_TOKEN:0:12}..."

# Create workspace
WS_RESPONSE=$(curl -fsS "http://127.0.0.1:${E2E_PORT}/workspaces" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${DEVICE_TOKEN}" \
    -d "{\"name\": \"e2e-workspace\", \"skills\": [], \"defaultModel\": \"${E2E_MODEL}\"}")
WS_ID=$(echo "$WS_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['workspace']['id'])")
echo "[e2e] Created workspace: $WS_ID"

# ── 6. Generate invite URL for the app (AFTER workspace creation) ──
# This issues a fresh pairing token that the iOS app will consume.

echo "[e2e] Generating invite URL for iOS app..."

if $NATIVE_MODE; then
    RAW_OUTPUT=$(cd "$REPO_ROOT/server" && OPPI_DATA_DIR="$DATA_DIR" E2E_PORT="$E2E_PORT" \
        node --input-type=module -e '
import { Storage } from "./dist/storage.js";
import { generateInvite } from "./dist/invite.js";
const storage = new Storage(process.env.OPPI_DATA_DIR);
const port = parseInt(process.env.E2E_PORT);
const invite = generateInvite(storage, () => "127.0.0.1", () => "e2e-server", { pairingTokenTtlMs: 600000 });
const payload = {
    v: 3, host: "127.0.0.1", port,
    scheme: "http", token: "",
    pairingToken: invite.pairingToken,
    name: invite.name,
    fingerprint: invite.fingerprint,
};
console.log(JSON.stringify({ inviteURL: invite.inviteURL, invitePayload: payload }));
')
else
    GEN_INVITE_SCRIPT=$(mktemp /tmp/oppi-e2e-gen-invite-XXXXXX.mjs)
    cat > "$GEN_INVITE_SCRIPT" <<'SCRIPT_EOF'
import { Storage } from "./dist/storage.js";
import { generateInvite } from "./dist/invite.js";

const storage = new Storage(process.env.OPPI_DATA_DIR);
const invite = generateInvite(
    storage,
    () => "host.docker.internal",
    () => "e2e-server",
    { pairingTokenTtlMs: 600000 }
);

// Override host/port for simulator connectivity (127.0.0.1 works in iOS simulator)
const payload = {
    v: 3,
    host: "127.0.0.1",
    port: REPLACE_PORT,
    scheme: "http",
    token: "",
    pairingToken: invite.pairingToken,
    name: invite.name,
    fingerprint: invite.fingerprint,
};
console.log(JSON.stringify({ inviteURL: invite.inviteURL, invitePayload: payload }));
SCRIPT_EOF

    sed -i '' "s/REPLACE_PORT/${E2E_PORT}/" "$GEN_INVITE_SCRIPT"
    docker cp "$GEN_INVITE_SCRIPT" oppi-e2e:/opt/oppi-server/gen-invite.mjs
    rm -f "$GEN_INVITE_SCRIPT"

    RAW_OUTPUT=$(docker exec -w /opt/oppi-server oppi-e2e node gen-invite.mjs)
fi

INVITE_PAYLOAD=$(echo "$RAW_OUTPUT" | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
payload = data['invitePayload']
payload_json = json.dumps(payload, separators=(',', ':'))
b64 = base64.urlsafe_b64encode(payload_json.encode()).rstrip(b'=').decode()
print(f'oppi://connect?v=3&invite={b64}')
")

echo "$INVITE_PAYLOAD" > "$INVITE_FILE"
echo "[e2e] Invite URL written to $INVITE_FILE"

# ── 7. Run XCUITests ──

echo "[e2e] Running E2E tests..."
cd "$IOS_DIR"
xcodegen generate

# Build and test in a single xcodebuild invocation to share derived data.
# sim-pool.sh auto-injects -destination and -derivedDataPath.
./scripts/sim-pool.sh run -- xcodebuild \
    -project Oppi.xcodeproj \
    -scheme Oppi \
    test \
    -only-testing:OppiE2ETests

TEST_EXIT=$?

echo "[e2e] Tests finished with exit code $TEST_EXIT"
exit $TEST_EXIT
