#!/usr/bin/env bash
# Orchestrates iOS E2E tests:
# 1. Starts server (Docker by default, or native process with --native)
# 2. Runs model-backed sessions on Claude Haiku via your Pi Anthropic login
#    (server/e2e/model-lane.ts)
# 3. Generates invite URL for pairing
# 4. Runs XCUITests with invite URL passed via temp file
# 5. Tears down server
#
# Usage:
#   ./e2e.sh              # Docker mode (default)
#   ./e2e.sh --native     # Native mode (skips Docker, ~30-60s faster)
#   ./e2e.sh --only-testing OppiE2ETests/ChatTimelineE2ETests/testSendMessageAndReceiveResponse
#   ./e2e.sh --skip-testing OppiE2ETests/WorkspaceHomeScreenshotLabE2ETests
#   ./e2e.sh --record-video=always
#   ./e2e.sh --native --durable --faux-model --only-testing OppiE2ETests/DurableSessionE2ETests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# This script lives in the checkout it tests: clients/apple/scripts.
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/server/e2e/docker-compose.e2e.yml"

# ── Flag parsing ──

usage() {
    cat <<'EOF'
Usage: e2e.sh [--native] [--durable] [--faux-model] [--group GROUP] [--only-testing TARGET] [--skip-testing TARGET] [--record-video=POLICY]

Runs Oppi iOS E2E tests by starting an E2E server, pairing the app, and
executing XCUITests through sim-pool.sh.

Options:
  --native              Use a native local server instead of Docker.
  --durable             Set experimental.serverDurable on the E2E server and have
                        E2ETestCase create sessions with engine "durable". Needs --native.
  --faux-model          Serve the scripted test-only model oppi-e2e-faux/oppi-e2e-faux-1
                        instead of Haiku (no Anthropic login needed). Needs --durable.
  --group GROUP         E2E target group: gate (default), extended, recovery, history, quick-session, extension-attention, all, smoke, regression, full-regression, media, or screenshot.
  --only-testing TARGET Run one XCTest bundle, suite, or test target. May be repeated.
  --skip-testing TARGET Skip one XCTest bundle, suite, or test target. May be repeated.
  --record-video[=POLICY]
                        Simulator video policy: on-failure (default), always, or off.
                        Bare --record-video means always for compatibility.
  --no-record-video     Disable simulator video recording.
  -h, --help            Show this help.

Environment:
  OPPI_E2E_GROUP        Default --group value.
  OPPI_RELEASE_E2E_GROUP Release-wrapper alias for OPPI_E2E_GROUP.
  OPPI_E2E_ONLY_TESTING Default --only-testing target. Overrides group target defaults.
  OPPI_E2E_RECORD_VIDEO Default simulator video policy (default: on-failure).
  OPPI_E2E_DURABLE      1 = --durable.
  OPPI_E2E_FAUX_MODEL   1 = --faux-model.
  E2E_ARTIFACT_DIR      Absolute or repo-relative directory for E2E run artifacts.
  E2E_DOCKER_LOG_DIR    Absolute or repo-relative Docker log directory.
  E2E_SOURCE_PI_AGENT_DIR  Pi agent dir with the Anthropic login (default: ~/.pi/agent).
  E2E_ANTHROPIC_EXTENSION  Pi extension for Anthropic subscription requests
                        (native mode only; unset by default).
  E2E_PORT              Local E2E server port.

Examples:
  e2e.sh --native
  e2e.sh --group gate
  e2e.sh --group extended
  e2e.sh --group smoke
  e2e.sh --native --only-testing OppiE2ETests/WebSocketLifecycleE2ETests/testNavigationKeepsWorkspaceListOnHTTPAndUsesBoundSessionStreams
  e2e.sh --group regression --skip-testing OppiE2ETests/WorkspaceCRUDHappyPathE2ETests
  e2e.sh --native --record-video=always
  e2e.sh --record-video=off
EOF
}

normalize_video_policy() {
    local raw="${1:-on-failure}"
    case "$raw" in
        1|true|TRUE|yes|YES|always)
            echo "always"
            ;;
        on-failure|on_failure|failure|fail|failed)
            echo "on-failure"
            ;;
        0|false|FALSE|no|NO|off|"")
            echo "off"
            ;;
        *)
            echo "[e2e] ERROR: invalid simulator video policy '$raw' (expected on-failure, always, or off)" >&2
            exit 1
            ;;
    esac
}

NATIVE_MODE=false
DURABLE_MODE=false
[[ "${OPPI_E2E_DURABLE:-0}" == "1" ]] && DURABLE_MODE=true
FAUX_MODEL=false
[[ "${OPPI_E2E_FAUX_MODEL:-0}" == "1" ]] && FAUX_MODEL=true
E2E_GROUP="${OPPI_E2E_GROUP:-${OPPI_RELEASE_E2E_GROUP:-gate}}"
ONLY_TESTING=()
ONLY_TESTING_EXPLICIT=false
if [[ -n "${OPPI_E2E_ONLY_TESTING:-}" ]]; then
    ONLY_TESTING+=("$OPPI_E2E_ONLY_TESTING")
    ONLY_TESTING_EXPLICIT=true
fi
E2E_RECORD_VIDEO="${OPPI_E2E_RECORD_VIDEO:-${OPPI_SIM_POOL_VIDEO_POLICY:-${OPPI_SIM_POOL_RECORD_VIDEO:-on-failure}}}"
SKIP_TESTING=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --native) NATIVE_MODE=true; shift ;;
        --durable) DURABLE_MODE=true; shift ;;
        --faux-model) FAUX_MODEL=true; shift ;;
        --group)
            if [[ $# -lt 2 ]]; then
                echo "[e2e] ERROR: --group requires a value" >&2
                exit 1
            fi
            E2E_GROUP="$2"
            shift 2
            ;;
        --group=*) E2E_GROUP="${1#*=}"; shift ;;
        --only-testing)
            if [[ $# -lt 2 ]]; then
                echo "[e2e] ERROR: --only-testing requires a target" >&2
                exit 1
            fi
            ONLY_TESTING+=("$2")
            ONLY_TESTING_EXPLICIT=true
            shift 2
            ;;
        --skip-testing)
            if [[ $# -lt 2 ]]; then
                echo "[e2e] ERROR: --skip-testing requires a target" >&2
                exit 1
            fi
            SKIP_TESTING+=("$2")
            shift 2
            ;;
        --record-video|--video)
            if [[ $# -ge 2 && "$2" != --* ]]; then
                E2E_RECORD_VIDEO="$2"
                shift 2
            else
                E2E_RECORD_VIDEO="always"
                shift
            fi
            ;;
        --record-video=*|--video=*) E2E_RECORD_VIDEO="${1#*=}"; shift ;;
        --no-record-video) E2E_RECORD_VIDEO="off"; shift ;;
        *) echo "[e2e] Unknown option: $1"; exit 1 ;;
    esac
done

apply_group_defaults() {
    if $ONLY_TESTING_EXPLICIT; then
        return
    fi

    case "$E2E_GROUP" in
        full|full-regression)
            E2E_GROUP="full-regression"
            # Preserve broad release coverage. Release wrappers may add their
            # own explicit skip list for labs known to be non-blocking.
            ONLY_TESTING+=("OppiE2ETests")
            ;;
        all)
            ONLY_TESTING+=("OppiE2ETests")
            ;;
        release-gate|gate|release-smoke|smoke)
            E2E_GROUP="gate"
            # Preferred release gate: high-value chat/composer/ask/attachment/session
            # journeys with fresh app launches and stable accessibility identifiers.
            ONLY_TESTING+=(
                "OppiE2ETests/ReleaseGateE2ETests/testComposerAskAnswerAndIgnoreUseInlineCard"
                "OppiE2ETests/ReleaseGateE2ETests/testExpandedComposerAttachmentSendAndStop"
                "OppiE2ETests/ReleaseGateE2ETests/testFocusedSessionStreamSurvivesSessionSwitch"
            )
            ;;
        recovery)
            ONLY_TESTING+=("OppiE2ETests/RecoveryE2ETests")
            ;;
        history)
            ONLY_TESTING+=("OppiE2ETests/SessionHistoryE2ETests")
            ;;
        quick|quick-session)
            E2E_GROUP="quick-session"
            ONLY_TESTING+=("OppiE2ETests/QuickSessionE2ETests")
            ;;
        attention|extension-attention)
            E2E_GROUP="extension-attention"
            ONLY_TESTING+=("OppiE2ETests/ExtensionAttentionE2ETests")
            ;;
        extended|release-extended)
            E2E_GROUP="extended"
            ONLY_TESTING+=(
                "OppiE2ETests/ReleaseGateE2ETests"
                "OppiE2ETests/RecoveryE2ETests"
                "OppiE2ETests/SessionHistoryE2ETests"
                "OppiE2ETests/QuickSessionE2ETests"
                "OppiE2ETests/ExtensionAttentionE2ETests"
            )
            ;;
        regression)
            ONLY_TESTING+=("OppiE2ETests")
            SKIP_TESTING+=(
                "OppiE2ETests/BrowserAutomationVideoToolRowE2ETests"
                "OppiE2ETests/ExtensionUISnapshotLabE2ETests"
                "OppiE2ETests/FeatureEducationTipsPreviewE2ETests"
                "OppiE2ETests/FileBrowserVideoPlaybackE2ETests"
                "OppiE2ETests/IPadAdaptiveShellScreenshotE2ETests"
                "OppiE2ETests/ToolRowAudioArtifactE2ETests"
                "OppiE2ETests/ToolRowImageViewportE2ETests"
                "OppiE2ETests/ToolRowVideoPlaybackE2ETests"
                "OppiE2ETests/WorkspaceHomeScreenshotLabE2ETests"
            )
            ;;
        media)
            ONLY_TESTING+=(
                "OppiE2ETests/BrowserAutomationVideoToolRowE2ETests"
                "OppiE2ETests/FileBrowserVideoPlaybackE2ETests"
                "OppiE2ETests/ToolRowAudioArtifactE2ETests"
                "OppiE2ETests/ToolRowImageViewportE2ETests"
                "OppiE2ETests/ToolRowVideoPlaybackE2ETests"
            )
            ;;
        screenshot)
            ONLY_TESTING+=(
                "OppiE2ETests/ExtensionUISnapshotLabE2ETests"
                "OppiE2ETests/FeatureEducationTipsPreviewE2ETests"
                "OppiE2ETests/IPadAdaptiveShellScreenshotE2ETests"
                "OppiE2ETests/WorkspaceHomeScreenshotLabE2ETests"
            )
            ;;
        *)
            echo "[e2e] ERROR: invalid E2E group '$E2E_GROUP' (expected gate, release-gate, extended, recovery, history, quick-session, extension-attention, all, smoke, regression, full-regression, release-smoke, media, or screenshot)" >&2
            exit 1
            ;;
    esac
}

normalize_artifact_path() {
    local raw="$1"
    if [[ "$raw" = /* ]]; then
        echo "$raw"
    else
        echo "$REPO_ROOT/$raw"
    fi
}

# Durable config and the faux model are set up through the native server's data and
# pi-agent dirs; Docker mode has no hook for either.
if $DURABLE_MODE && ! $NATIVE_MODE; then
    echo "[e2e] ERROR: --durable needs --native" >&2
    exit 1
fi
# The faux model is registered on the server-wide model runtime, which only durable
# sessions use; classic sessions would not find it.
if $FAUX_MODEL && ! $DURABLE_MODE; then
    echo "[e2e] ERROR: --faux-model needs --durable" >&2
    exit 1
fi
E2E_SESSION_ENGINE=classic
$DURABLE_MODE && E2E_SESSION_ENGINE=durable
E2E_FAUX_PROVIDER=0
$FAUX_MODEL && E2E_FAUX_PROVIDER=1

E2E_RECORD_VIDEO=$(normalize_video_policy "$E2E_RECORD_VIDEO")
apply_group_defaults

E2E_RUN_ID="${E2E_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
E2E_ARTIFACT_DIR="$(normalize_artifact_path "${E2E_ARTIFACT_DIR:-.internal/reports/e2e-runs/$E2E_RUN_ID}")"
mkdir -p "$E2E_ARTIFACT_DIR"
if [[ -n "${E2E_DOCKER_LOG_DIR:-}" ]]; then
    E2E_DOCKER_LOG_DIR="$(normalize_artifact_path "$E2E_DOCKER_LOG_DIR")"
elif ! $NATIVE_MODE; then
    E2E_DOCKER_LOG_DIR="$E2E_ARTIFACT_DIR/docker"
fi
if [[ -n "${E2E_DOCKER_LOG_DIR:-}" ]]; then
    mkdir -p "$E2E_DOCKER_LOG_DIR"
    export E2E_DOCKER_LOG_DIR
fi

if $NATIVE_MODE; then
    echo "[e2e] Running in NATIVE mode (no Docker)"
else
    echo "[e2e] Running in DOCKER mode"
fi

echo "[e2e] Session engine: $E2E_SESSION_ENGINE"
$FAUX_MODEL && echo "[e2e] Model: scripted faux model (no Haiku)"
echo "[e2e] E2E group: $E2E_GROUP"
echo "[e2e] XCTest only-testing: ${ONLY_TESTING[*]}"
if [[ ${#SKIP_TESTING[@]} -gt 0 ]]; then
    echo "[e2e] XCTest skip-testing: ${SKIP_TESTING[*]}"
fi
echo "[e2e] Artifact dir: $E2E_ARTIFACT_DIR"
echo "[e2e] Simulator video policy: $E2E_RECORD_VIDEO"

choose_e2e_port() {
    if [ -n "${E2E_PORT:-}" ]; then
        echo "$E2E_PORT"
        return
    fi
    if lsof -nP -iTCP:17760 -sTCP:LISTEN >/dev/null 2>&1; then
        python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
        return
    fi
    echo "17760"
}
E2E_PORT="$(choose_e2e_port)"
detect_e2e_app_host() {
    ipconfig getifaddr en0 2>/dev/null \
        || ipconfig getifaddr en1 2>/dev/null \
        || echo "127.0.0.1"
}
E2E_APP_HOST="${E2E_APP_HOST:-$(detect_e2e_app_host)}"
echo "[e2e] App invite host: $E2E_APP_HOST"
# Pairing files live in a per-run directory handed to the UI test runner as
# TEST_RUNNER_OPPI_E2E_RUN_DIR, so concurrent runs from other sessions never
# read each other's server or device token.
RUN_DIR=$(mktemp -d /tmp/oppi-e2e-run-XXXXXX)
INVITE_FILE="$RUN_DIR/invite.txt"
DEVICE_TOKEN_FILE="$RUN_DIR/device-token.txt"
BOOTSTRAP_CREDENTIAL_FILE="$RUN_DIR/bootstrap-device.json"
# Isolated Pi auth.json + settings.json for the Haiku lane (inside RUN_DIR).
MODEL_LANE_DIR=""
SERVER_PID=""
APPROVER_PID=""
DATA_DIR=""
E2E_BASE_URL=""
CURL_TLS_ARGS=()
OPPI_E2E_UI_HARNESS="${OPPI_E2E_UI_HARNESS:-1}"

# ── Cleanup ──

cleanup() {
    local exit_code=$?
    if [ -n "$APPROVER_PID" ]; then
        kill "$APPROVER_PID" 2>/dev/null && wait "$APPROVER_PID" 2>/dev/null || true
    fi
    if $NATIVE_MODE; then
        echo "[e2e] Stopping native server..."
        [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null || true
        if [ -n "$DATA_DIR" ]; then
            if [ "$exit_code" -eq 0 ]; then
                rm -rf "$DATA_DIR"
            else
                # Keep logs and state, not the Anthropic access token.
                rm -f "$DATA_DIR/pi-agent/auth.json"
                echo "[e2e] Preserving native data dir for failure debugging: $DATA_DIR"
            fi
        fi
    else
        if [ -n "${E2E_DOCKER_LOG_DIR:-}" ]; then
            mkdir -p "$E2E_DOCKER_LOG_DIR"
            LOG_FILE="$E2E_DOCKER_LOG_DIR/docker-e2e-$(date +%Y%m%d-%H%M%S).log"
            echo "[e2e] Capturing Docker server logs to $LOG_FILE"
            docker compose -f "$COMPOSE_FILE" logs --no-color --timestamps oppi-e2e > "$LOG_FILE" 2>&1 || true
        fi
        echo "[e2e] Tearing down Docker server..."
        docker compose -f "$COMPOSE_FILE" down -v --timeout 10 2>/dev/null || true
    fi
    rm -rf "$RUN_DIR"
    echo "[e2e] Cleanup complete."
}
trap cleanup EXIT

# ── 1. Prepare the Haiku model lane ──

if $FAUX_MODEL; then
    # server/src/e2e-faux-provider.ts registers the faux model only under both gates.
    if [[ "$OPPI_E2E_UI_HARNESS" != "1" ]]; then
        echo "[e2e] ERROR: --faux-model needs OPPI_E2E_UI_HARNESS=1" >&2
        exit 1
    fi
    echo "[e2e] Skipping the Haiku lane: using the faux model"
else
    # Only a current Anthropic access token and enabledModels; the refresh
    # token stays in the source Pi login.
    MODEL_LANE_DIR="$RUN_DIR/pi-agent"
    # Subscription OAuth through Pi's built-in provider bills as extra usage;
    # a subscription login needs E2E_ANTHROPIC_EXTENSION (native mode only).
    E2E_MODEL=$(node "$REPO_ROOT/server/e2e/model-lane.ts" write "$MODEL_LANE_DIR") || {
        echo "[e2e] ERROR: could not prepare the Haiku model lane"
        exit 1
    }
    echo "[e2e] Model: $E2E_MODEL"
fi

# Remove stale E2E listeners/containers so health checks cannot accidentally
# attach the app to a previous failed run.
echo "[e2e] Cleaning stale E2E server state..."
E2E_CLEAN_NATIVE=0
$NATIVE_MODE && E2E_CLEAN_NATIVE=1
(cd "$REPO_ROOT/server" && E2E_NATIVE="$E2E_CLEAN_NATIVE" E2E_PORT="$E2E_PORT" node scripts/e2e-clean.mjs) || true

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
        OPPI_DATA_DIR="$DATA_DIR" node dist/src/cli.js config set port "$E2E_PORT"
        OPPI_DATA_DIR="$DATA_DIR" node dist/src/cli.js config set host "0.0.0.0"
        # /pair and /auth/* require HTTPS. Default to the same self-signed
        # posture as server/e2e/harness.ts. Do not weaken TLS to make pairing
        # succeed over HTTP.
        E2E_TLS_MODE="${E2E_TLS_MODE:-self-signed}"
        if [ "$E2E_TLS_MODE" = "disabled" ]; then
            echo "[e2e] ERROR: E2E_TLS_MODE=disabled cannot pair; POST /pair requires HTTPS" >&2
            exit 1
        fi
        OPPI_DATA_DIR="$DATA_DIR" node dist/src/cli.js config set tls '{"mode":"self-signed"}'
        if [ "$E2E_SESSION_ENGINE" = "durable" ]; then
            OPPI_DATA_DIR="$DATA_DIR" node dist/src/cli.js config set experimental.serverDurable true
        fi
        OPPI_DATA_DIR="$DATA_DIR" node --input-type=module -e '
import { Storage } from "./dist/src/storage.js";
new Storage(process.env.OPPI_DATA_DIR).ensurePaired();
'
    )

    PI_AGENT_DIR="$DATA_DIR/pi-agent"
    mkdir -p "$PI_AGENT_DIR"
    if $FAUX_MODEL; then
        # The faux model is the default so durable sessions never pick an ambient provider.
        cat > "$PI_AGENT_DIR/settings.json" <<'EOF'
{ "defaultProvider": "oppi-e2e-faux", "defaultModel": "oppi-e2e-faux-1" }
EOF
        echo "[e2e] Generated faux-model settings.json at $PI_AGENT_DIR/settings.json"
    else
        node "$REPO_ROOT/server/e2e/model-lane.ts" write "$PI_AGENT_DIR" >/dev/null
        echo "[e2e] Installed the Haiku lane in $PI_AGENT_DIR"
    fi

    # Start server as background process
    echo "[e2e] Starting native server on port $E2E_PORT ..."
    (
        cd "$REPO_ROOT/server"
        exec env OPPI_DATA_DIR="$DATA_DIR" PI_CODING_AGENT_DIR="$PI_AGENT_DIR" \
            OPPI_LOCAL_SESSIONS_ROOT="$PI_AGENT_DIR/sessions" \
            OPPI_E2E_UI_HARNESS="$OPPI_E2E_UI_HARNESS" \
            OPPI_E2E_FAUX_PROVIDER="$E2E_FAUX_PROVIDER" \
            node dist/src/cli.js serve
    ) > "$DATA_DIR/server.log" 2>&1 &
    SERVER_PID=$!
    echo "[e2e] Server PID: $SERVER_PID"
else
    # Start Docker server with the Haiku lane mounted as the container's Pi auth/settings
    echo "[e2e] WARNING: Docker cannot load the Anthropic subscription extension; a subscription login is billed as extra usage. Use --native." >&2
    echo "[e2e] Starting Docker server on port $E2E_PORT ..."
    E2E_PORT="$E2E_PORT" OPPI_E2E_UI_HARNESS="$OPPI_E2E_UI_HARNESS" \
        E2E_PI_AUTH_JSON="$MODEL_LANE_DIR/auth.json" E2E_PI_SETTINGS_JSON="$MODEL_LANE_DIR/settings.json" \
        docker compose -f "$COMPOSE_FILE" up -d --build --wait --wait-timeout 120
fi

# ── 3. Wait for health ──

echo "[e2e] Waiting for server health..."
for i in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${E2E_PORT}/health" >/dev/null 2>&1; then
        E2E_BASE_URL="http://127.0.0.1:${E2E_PORT}"
        CURL_TLS_ARGS=()
        echo "[e2e] Server healthy after ${i}s over HTTP"
        break
    fi
    if curl -fsSk "https://127.0.0.1:${E2E_PORT}/health" >/dev/null 2>&1; then
        E2E_BASE_URL="https://127.0.0.1:${E2E_PORT}"
        CURL_TLS_ARGS=(-k)
        echo "[e2e] Server healthy after ${i}s over HTTPS"
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

# ── 4. Pre-create a workspace via API ──
# Must happen BEFORE generating the app's invite, because issuePairingToken
# replaces the previous token (single token at a time).

echo "[e2e] Pre-creating workspace via API..."

# Generate a pairing token and pair from the script to get a device token
if $NATIVE_MODE; then
    SCRIPT_PAIRING_TOKEN=$(cd "$REPO_ROOT/server" && OPPI_DATA_DIR="$DATA_DIR" \
        node --input-type=module -e '
import { Storage } from "./dist/src/storage.js";
const s = new Storage(process.env.OPPI_DATA_DIR);
console.log(s.issuePairingToken(600000));
')
else
    GEN_PAIR_SCRIPT=$(mktemp /tmp/oppi-e2e-gen-pair-XXXXXX.mjs)
    cat > "$GEN_PAIR_SCRIPT" <<'PAIR_EOF'
import { Storage } from "./dist/src/storage.js";
const storage = new Storage(process.env.OPPI_DATA_DIR);
const pt = storage.issuePairingToken(600000);
console.log(pt);
PAIR_EOF

    docker cp "$GEN_PAIR_SCRIPT" oppi-e2e:/opt/oppi-server/gen-pair.mjs
    rm -f "$GEN_PAIR_SCRIPT"
    SCRIPT_PAIRING_TOKEN=$(docker exec -w /opt/oppi-server oppi-e2e node gen-pair.mjs)
fi

SCRIPT_PAIRING_TOKEN="$(printf '%s' "$SCRIPT_PAIRING_TOKEN" | tr -d '\r\n')"
if [ -z "$SCRIPT_PAIRING_TOKEN" ]; then
    echo "[e2e] ERROR: issuePairingToken returned an empty pairing token"
    exit 1
fi

# POST /pair requires a P-256 devicePublicKey and returns accessToken (at_).
# Do not use curl -f: it swallows the JSON error body on 400/401.
PAIR_HELPER="$REPO_ROOT/server/scripts/e2e-precreate-pair.mjs"
if [ ${#CURL_TLS_ARGS[@]} -gt 0 ]; then
    export NODE_TLS_REJECT_UNAUTHORIZED=0
fi
DEVICE_TOKEN=$(PAIRING_TOKEN="$SCRIPT_PAIRING_TOKEN" E2E_BASE_URL="$E2E_BASE_URL" \
    E2E_BOOTSTRAP_CREDENTIAL_FILE="$BOOTSTRAP_CREDENTIAL_FILE" node "$PAIR_HELPER")
# A helper that exits 0 without printing (e.g. its isMain check misfiring) must not pass an empty token on.
if [ -z "$DEVICE_TOKEN" ]; then
    echo "[e2e] ERROR: POST /pair helper printed no access token" >&2
    exit 1
fi

echo "$DEVICE_TOKEN" > "$DEVICE_TOKEN_FILE"
echo "[e2e] Paired with device token: ${DEVICE_TOKEN:0:12}..."

# The app's invite outlives the server's short-invite window so it survives a
# cold build, and the bootstrap device above is already paired, so the app's
# pairing waits for an approval. The approver signs it as the bootstrap device
# through the real /auth/pairing-approvals API.
APPROVER_HELPER="$REPO_ROOT/server/scripts/e2e-pairing-approver.mjs"
APPROVER_LOG="$E2E_ARTIFACT_DIR/pairing-approver.log"
E2E_BASE_URL="$E2E_BASE_URL" E2E_BOOTSTRAP_CREDENTIAL_FILE="$BOOTSTRAP_CREDENTIAL_FILE" \
    node "$APPROVER_HELPER" > "$APPROVER_LOG" 2>&1 &
APPROVER_PID=$!
echo "[e2e] Pairing approver PID $APPROVER_PID, log: $APPROVER_LOG"

INFO_RESPONSE=$(curl -fsS "${CURL_TLS_ARGS[@]}" "${E2E_BASE_URL}/server/info" \
    -H "Authorization: Bearer ${DEVICE_TOKEN}")
echo "$INFO_RESPONSE" | python3 -c '
import json, sys
info = json.load(sys.stdin)
caps = info.get("capabilities") or {}
missing = [name for name in ("sessionStream",) if (caps.get(name) or {}).get("version", 0) < 1]
if missing:
    raise SystemExit(f"[e2e] ERROR: server missing required focused stream capabilities: {missing}")
'
echo "[e2e] Server exposes required focused stream capabilities"

# Create workspace. Do not send defaultModel: Pi settings own the default.
WS_RESPONSE=$(curl -fsS "${CURL_TLS_ARGS[@]}" "${E2E_BASE_URL}/workspaces" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${DEVICE_TOKEN}" \
    -d "{\"name\": \"e2e-workspace\", \"hostMount\": \"/tmp\", \"skills\": []}")
WS_ID=$(echo "$WS_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['workspace']['id'])")
echo "[e2e] Created workspace: $WS_ID"

# ── 5. Generate invite URL for the app (AFTER workspace creation) ──
# This issues a fresh pairing token that the iOS app will consume.

echo "[e2e] Generating invite URL for iOS app..."

GEN_INVITE_HELPER="$REPO_ROOT/server/scripts/e2e-gen-invite.mjs"
if $NATIVE_MODE; then
    RAW_OUTPUT=$(cd "$REPO_ROOT/server" && OPPI_DATA_DIR="$DATA_DIR" E2E_APP_HOST="$E2E_APP_HOST" \
        node scripts/e2e-gen-invite.mjs)
else
    docker exec oppi-e2e mkdir -p /opt/oppi-server/scripts
    docker cp "$GEN_INVITE_HELPER" oppi-e2e:/opt/oppi-server/scripts/e2e-gen-invite.mjs
    RAW_OUTPUT=$(docker exec -e E2E_APP_HOST="$E2E_APP_HOST" -w /opt/oppi-server oppi-e2e node scripts/e2e-gen-invite.mjs)
fi

INVITE_PAYLOAD=$(echo "$RAW_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data['inviteURL'])
")

echo "$INVITE_PAYLOAD" > "$INVITE_FILE"
echo "[e2e] Invite URL written to $INVITE_FILE"

# ── 6. Run XCUITests ──

echo "[e2e] Running E2E tests..."
cd "$IOS_DIR"
xcodegen generate

# Build and test in a single xcodebuild invocation to share derived data.
# sim-pool.sh auto-injects -destination and -derivedDataPath.
xcodebuild_args=(
    -project Oppi.xcodeproj
    -scheme Oppi
    test
)
for target in "${ONLY_TESTING[@]}"; do
    xcodebuild_args+=("-only-testing:$target")
done
for skip in "${SKIP_TESTING[@]}"; do
    xcodebuild_args+=("-skip-testing:$skip")
done

# Hand E2E values to the UI test runner with xcodebuild's TEST_RUNNER_ prefix
# (stripped before the runner sees them). Never use SIMCTL_CHILD_* here: the
# pool boots the simulator under this environment, and simctl bakes SIMCTL_CHILD_*
# into device-level launchd env that outlives the run and flips later unit runs
# into E2E mode. The runner sets XCUIApplication.launchEnvironment for the app.
E2E_SCHEME="${E2E_BASE_URL%%:*}"
APP_DEVICE_TOKEN="$DEVICE_TOKEN"
set +e
TEST_RUNNER_OPPI_E2E_RUN_DIR="$RUN_DIR" \
E2E_PORT="$E2E_PORT" \
E2E_SCHEME="$E2E_SCHEME" \
PI_E2E_INVITE_URL="$INVITE_PAYLOAD" \
OPPI_E2E_DEVICE_TOKEN="$APP_DEVICE_TOKEN" \
TEST_RUNNER_E2E_PORT="$E2E_PORT" \
TEST_RUNNER_E2E_SCHEME="$E2E_SCHEME" \
TEST_RUNNER_PI_E2E_INVITE_URL="$INVITE_PAYLOAD" \
TEST_RUNNER_OPPI_E2E_DEVICE_TOKEN="$APP_DEVICE_TOKEN" \
TEST_RUNNER_OPPI_E2E_SESSION_ENGINE="$E2E_SESSION_ENGINE" \
OPPI_SIM_POOL_VIDEO_POLICY="$E2E_RECORD_VIDEO" \
  "$IOS_DIR/scripts/sim-pool.sh" run -- xcodebuild "${xcodebuild_args[@]}"
TEST_EXIT=$?
set -e

if [ "$TEST_EXIT" -ne 0 ]; then
    HEALTH_ARTIFACT="$E2E_ARTIFACT_DIR/server-health-after-test-failure.txt"
    {
        echo "timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "base_url=$E2E_BASE_URL"
        echo "group=$E2E_GROUP"
        echo "only_testing=${ONLY_TESTING[*]}"
        echo "skip_testing=${SKIP_TESTING[*]}"
        if curl -fsS "${CURL_TLS_ARGS[@]}" "${E2E_BASE_URL}/health"; then
            echo
            echo "health=ok"
        else
            status=$?
            echo "health=failed status=$status"
        fi
    } > "$HEALTH_ARTIFACT" 2>&1 || true
    echo "[e2e] Server health after test failure: $HEALTH_ARTIFACT"
fi

echo "[e2e] Tests finished with exit code $TEST_EXIT"
exit $TEST_EXIT
