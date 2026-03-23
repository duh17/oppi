#!/usr/bin/env bash
# Orchestrates iOS E2E tests:
# 1. Starts Docker server (reuses server/e2e/docker-compose.e2e.yml)
# 2. Generates invite URL for pairing
# 3. Runs XCUITests with invite URL passed via temp file
# 4. Tears down Docker server
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/server/e2e/docker-compose.e2e.yml"

E2E_PORT="${E2E_PORT:-17760}"
MLX_PORT="${E2E_MLX_PORT:-9847}"
MLX_HOST_URL="http://localhost:${MLX_PORT}"
INVITE_FILE="/tmp/oppi-e2e-invite.txt"
MODELS_JSON=""

# ── Cleanup ──

cleanup() {
    echo "[e2e] Tearing down Docker server..."
    docker compose -f "$COMPOSE_FILE" down -v --timeout 10 2>/dev/null || true
    [ -n "$MODELS_JSON" ] && rm -f "$MODELS_JSON"
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

# ── 2. Generate models.json for Docker container ──

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

# ── 3. Start Docker server ──

echo "[e2e] Starting Docker server on port $E2E_PORT ..."
E2E_PORT="$E2E_PORT" E2E_MODELS_JSON="$MODELS_JSON" \
    docker compose -f "$COMPOSE_FILE" up -d --build --wait --wait-timeout 120

# Poll health endpoint (compose --wait should handle this, but belt-and-suspenders)
echo "[e2e] Waiting for server health..."
for i in $(seq 1 60); do
    if curl -fsS "http://localhost:${E2E_PORT}/health" >/dev/null 2>&1; then
        echo "[e2e] Server healthy after ${i}s"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[e2e] ERROR: Server did not become healthy within 60s"
        exit 1
    fi
    sleep 1
done

# ── 4. Set default model ──

E2E_MODEL="mlx-server/$MODEL_ID"
echo "[e2e] Setting defaultModel to $E2E_MODEL ..."
docker exec oppi-e2e node dist/cli.js config set defaultModel "$E2E_MODEL"

# ── 5. Pre-create a workspace via API ──
# Must happen BEFORE generating the app's invite, because issuePairingToken
# replaces the previous token (single token at a time).

echo "[e2e] Pre-creating workspace via API..."

# Generate a pairing token and pair from the script to get a device token
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

# ── 6. Run XCUITests ──

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
