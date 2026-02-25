#!/usr/bin/env bash
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-docker}"
MODE="${E2E_MODE:-smoke}" # smoke | full
E2E_TLS="${E2E_TLS:-0}"   # 0 | 1
PORT="${PORT:-17749}"
TOKEN="${TOKEN:-oppi-e2e-token}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oppi-linux-e2e.XXXXXX")"
DATA_DIR="$TMP_DIR/data"
FAKE_PI="$TMP_DIR/fake-pi.sh"
ENTRYPOINT_SH="$TMP_DIR/container-entry.sh"
CONTAINER_NAME="oppi-linux-e2e-$$"
CONTAINER_ID=""

USE_HOST_NPM_CACHE="${USE_HOST_NPM_CACHE:-1}"
HOST_NPM_CACHE="${HOST_NPM_CACHE:-$HOME/.npm}"
HOST_PI_DIR="${HOST_PI_DIR:-$HOME/.pi}"

cleanup() {
  local exit_code=$?

  if [[ -n "$CONTAINER_ID" ]]; then
    if [[ $exit_code -ne 0 ]]; then
      echo ""
      echo "[e2e] Container logs (failure):"
      "$RUNTIME" logs "$CONTAINER_ID" || true
      echo ""
    fi

    "$RUNTIME" rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMP_DIR"
  exit $exit_code
}
trap cleanup EXIT

if [[ "$MODE" != "smoke" && "$MODE" != "full" ]]; then
  echo "[e2e] Invalid E2E_MODE '$MODE' (expected smoke or full)"
  exit 1
fi

if [[ "$E2E_TLS" != "0" && "$E2E_TLS" != "1" ]]; then
  echo "[e2e] Invalid E2E_TLS '$E2E_TLS' (expected 0 or 1)"
  exit 1
fi

if ! command -v "$RUNTIME" >/dev/null 2>&1; then
  echo "[e2e] Container runtime '$RUNTIME' not found"
  exit 1
fi

mkdir -p "$DATA_DIR"

if [[ "$E2E_TLS" == "1" ]]; then
cat > "$DATA_DIR/config.json" <<JSON
{
  "host": "0.0.0.0",
  "port": $PORT,
  "token": "$TOKEN",
  "defaultModel": "openai-codex/gpt-5.3-codex",
  "tls": {
    "mode": "self-signed"
  }
}
JSON
else
cat > "$DATA_DIR/config.json" <<JSON
{
  "host": "0.0.0.0",
  "port": $PORT,
  "token": "$TOKEN",
  "defaultModel": "openai-codex/gpt-5.3-codex"
}
JSON
fi

cat > "$FAKE_PI" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# Unblock session start immediately.
echo '{"type":"agent_start"}'

# Minimal RPC loop to keep process alive and respond to prompts.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue

  case "$line" in
    *'"type":"prompt"'*)
      echo '{"type":"message_start","message":{"role":"assistant"}}'
      echo '{"type":"message_delta","delta":"ok"}'
      echo '{"type":"message_end","message":{"role":"assistant","content":"ok"},"usage":{"input_tokens":1,"output_tokens":1}}'
      echo '{"type":"agent_end"}'
      ;;
    *'"type":"abort"'*)
      echo '{"type":"agent_end"}'
      ;;
  esac
done
SH
chmod +x "$FAKE_PI"

cat > "$ENTRYPOINT_SH" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p /e2e/workspace

tar -C /src \
  --exclude=node_modules \
  --exclude=dist \
  --exclude=coverage \
  -cf - . | tar -C /e2e/workspace -xf -

npm ci --prefer-offline --no-audit --no-fund >/e2e/npm-ci.log 2>&1
npm run build >/e2e/npm-build.log 2>&1

if [[ "${E2E_MODE:-smoke}" == "full" ]]; then
  npm install -g --prefer-offline --no-audit --no-fund @mariozechner/pi-coding-agent >/e2e/npm-pi.log 2>&1

  if [[ -d /e2e/host-pi ]]; then
    mkdir -p /root/.pi
    cp -R /e2e/host-pi/. /root/.pi/
  fi

  if [[ -z "${OPPI_PI_BIN:-}" ]]; then
    OPPI_PI_BIN="$(command -v pi || true)"
    export OPPI_PI_BIN
  fi

  if [[ -z "$OPPI_PI_BIN" ]]; then
    echo "[e2e-container] pi executable not found after install" >&2
    exit 1
  fi

  echo "[e2e-container] using pi at $OPPI_PI_BIN"
fi

node dist/cli.js serve
SH
chmod +x "$ENTRYPOINT_SH"

DOCKER_ARGS=(
  run --rm -d
  --name "$CONTAINER_NAME"
  -p "$PORT:$PORT"
  -e OPPI_DATA_DIR=/e2e/data
  -e E2E_MODE="$MODE"
  -v "$ROOT_DIR:/src:ro"
  -v "$TMP_DIR:/e2e"
  -w /e2e/workspace
)

if [[ "$MODE" == "smoke" ]]; then
  DOCKER_ARGS+=( -e OPPI_PI_BIN=/e2e/fake-pi.sh )
fi

if [[ "$USE_HOST_NPM_CACHE" == "1" && -d "$HOST_NPM_CACHE" ]]; then
  echo "[e2e] Reusing host npm cache: $HOST_NPM_CACHE"
  DOCKER_ARGS+=( -v "$HOST_NPM_CACHE:/e2e/host-cache/npm" )
  DOCKER_ARGS+=( -e NPM_CONFIG_CACHE=/e2e/host-cache/npm )
fi

if [[ "$MODE" == "full" && -d "$HOST_PI_DIR" ]]; then
  echo "[e2e] Reusing host pi config: $HOST_PI_DIR"
  DOCKER_ARGS+=( -v "$HOST_PI_DIR:/e2e/host-pi:ro" )
fi

DOCKER_ARGS+=( node:22-bookworm bash -lc /e2e/container-entry.sh )

echo "[e2e] Starting linux containerized server on port $PORT (mode=$MODE tls=$E2E_TLS)"
CONTAINER_ID="$($RUNTIME "${DOCKER_ARGS[@]}")"

SCHEME="http"
CURL_TLS_ARGS=()
CA_CERT_PATH=""
if [[ "$E2E_TLS" == "1" ]]; then
  SCHEME="https"
  CA_CERT_PATH="$DATA_DIR/tls/self-signed/ca.crt"
  echo "[e2e] Waiting for self-signed CA at $CA_CERT_PATH"
  for _ in {1..90}; do
    if [[ -f "$CA_CERT_PATH" ]]; then
      break
    fi
    sleep 1
  done

  if [[ ! -f "$CA_CERT_PATH" ]]; then
    echo "[e2e] Self-signed CA was not generated in time"
    exit 1
  fi

  CURL_TLS_ARGS=(--cacert "$CA_CERT_PATH")
fi

HEALTH_URL="$SCHEME://127.0.0.1:$PORT/health"

echo "[e2e] Waiting for /health via $SCHEME"
for _ in {1..90}; do
  if curl -fsS "${CURL_TLS_ARGS[@]}" "$HEALTH_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "${CURL_TLS_ARGS[@]}" "$HEALTH_URL" >/dev/null 2>&1; then
  echo "[e2e] Server did not become healthy in time"
  exit 1
fi

if [[ "$E2E_TLS" == "1" ]]; then
  echo "[e2e] Verifying WSS upgrade over TLS"
  PORT="$PORT" AUTH_TOKEN="$TOKEN" CA_CERT_PATH="$CA_CERT_PATH" node <<'NODE'
const fs = require("node:fs");
const tls = require("node:tls");

const port = Number(process.env.PORT);
const token = process.env.AUTH_TOKEN;
const caPath = process.env.CA_CERT_PATH;

if (!Number.isFinite(port) || !token || !caPath) {
  throw new Error("missing PORT/AUTH_TOKEN/CA_CERT_PATH for WSS check");
}

const ca = fs.readFileSync(caPath, "utf-8");

const request = [
  "GET /stream HTTP/1.1",
  `Host: 127.0.0.1:${port}`,
  "Upgrade: websocket",
  "Connection: Upgrade",
  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
  "Sec-WebSocket-Version: 13",
  `Authorization: Bearer ${token}`,
  "",
  "",
].join("\r\n");

async function verifyWssUpgrade() {
  await new Promise((resolve, reject) => {
    const socket = tls.connect({
      host: "127.0.0.1",
      port,
      ca,
      servername: "localhost",
    });

    socket.setEncoding("utf8");

    let response = "";
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("timed out waiting for WSS upgrade response"));
    }, 7000);

    socket.on("secureConnect", () => {
      socket.write(request);
    });

    socket.on("data", (chunk) => {
      response += chunk;
      if (!response.includes("\r\n\r\n")) {
        return;
      }

      clearTimeout(timeout);
      const statusLine = response.split("\r\n", 1)[0] || "";
      if (!statusLine.includes("101")) {
        reject(new Error(`expected 101 Switching Protocols, got: ${statusLine}`));
      } else {
        resolve();
      }
      socket.destroy();
    });

    socket.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
  });
}

verifyWssUpgrade()
  .then(() => {
    console.log("[e2e] WSS upgrade check passed");
  })
  .catch((err) => {
    console.error("[e2e] WSS upgrade check failed:", err.message);
    process.exit(1);
  });
NODE
fi

echo "[e2e] Running API smoke checks"
if [[ "$E2E_TLS" == "1" ]]; then
  export NODE_EXTRA_CA_CERTS="$CA_CERT_PATH"
fi

BASE_URL="$SCHEME://127.0.0.1:$PORT" AUTH_TOKEN="$TOKEN" node <<'NODE'
const base = process.env.BASE_URL;
const token = process.env.AUTH_TOKEN;

async function request(method, path, body) {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await res.text();
  let json;
  try {
    json = text.length ? JSON.parse(text) : null;
  } catch {
    json = { raw: text };
  }

  return { status: res.status, json };
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

(async () => {
  const wsCreate = await request("POST", "/workspaces", { name: "linux-e2e", skills: [] });
  assert(wsCreate.status === 201, `create workspace failed: ${wsCreate.status}`);

  const workspace = wsCreate.json.workspace;
  assert(
    !Object.prototype.hasOwnProperty.call(workspace, "runtime"),
    "workspace runtime should be omitted",
  );

  const wsList = await request("GET", "/workspaces");
  assert(wsList.status === 200, `list workspaces failed: ${wsList.status}`);
  assert(Array.isArray(wsList.json.workspaces), "workspaces payload missing array");

  const sessCreate = await request("POST", `/workspaces/${workspace.id}/sessions`, {
    prompt: "ping",
  });
  assert(sessCreate.status === 201, `create session failed: ${sessCreate.status}`);
  assert(
    !Object.prototype.hasOwnProperty.call(sessCreate.json.session, "runtime"),
    "session runtime should be omitted",
  );

  const sessList = await request("GET", `/workspaces/${workspace.id}/sessions`);
  assert(sessList.status === 200, `list sessions failed: ${sessList.status}`);
  assert(Array.isArray(sessList.json.sessions), "sessions payload missing array");

  const del = await request("DELETE", `/workspaces/${workspace.id}`);
  assert(del.status === 200, `delete workspace failed: ${del.status}`);

  console.log("[e2e] Linux container smoke checks passed");
})().catch((err) => {
  console.error("[e2e] Smoke checks failed:", err.message);
  process.exit(1);
});
NODE

if [[ "$E2E_TLS" == "1" ]]; then
  unset NODE_EXTRA_CA_CERTS
fi

echo "[e2e] Done"
