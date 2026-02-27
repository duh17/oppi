#!/usr/bin/env bash
set -euo pipefail

OPPI_DATA_DIR="${OPPI_DATA_DIR:-/data/oppi}"
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-/data/pi-agent}"
PI_AGENT_SEED_DIR="${PI_AGENT_SEED_DIR:-/seed/pi-agent}"
PI_AGENT_SYNC_MODE="${PI_AGENT_SYNC_MODE:-copy-once}"
WEB_TOOLKIT_CONTAINER="${WEB_TOOLKIT_CONTAINER:-web-toolkit}"
OPPI_PORT="${OPPI_PORT:-}"

mkdir -p "$OPPI_DATA_DIR" "$PI_AGENT_DIR"
mkdir -p "$PI_AGENT_DIR/skills" "$PI_AGENT_DIR/extensions" "$PI_AGENT_DIR/sessions" "$PI_AGENT_DIR/themes"
chmod 700 "$OPPI_DATA_DIR" "$PI_AGENT_DIR" || true

seed_marker="$PI_AGENT_DIR/.seeded-from-host"

sync_seed() {
  if [[ ! -d "$PI_AGENT_SEED_DIR" ]]; then
    return
  fi

  echo "[oppi-entrypoint] syncing pi agent seed from $PI_AGENT_SEED_DIR"

  # Prefer dereferenced copy so symlink-based skills resolve into container files.
  # If dereference fails (missing target), keep original links as fallback.
  if ! cp -aL "$PI_AGENT_SEED_DIR/." "$PI_AGENT_DIR/" 2>/tmp/oppi-seed-copy.err; then
    echo "[oppi-entrypoint] warning: dereferenced seed copy failed; falling back to regular copy" >&2
    cat /tmp/oppi-seed-copy.err >&2 || true
    cp -a "$PI_AGENT_SEED_DIR/." "$PI_AGENT_DIR/" || true
  fi

  if [[ -f "$PI_AGENT_SEED_DIR/auth.json" ]]; then
    cp -f "$PI_AGENT_SEED_DIR/auth.json" "$PI_AGENT_DIR/auth.json"
    chmod 600 "$PI_AGENT_DIR/auth.json" || true
  fi

  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$seed_marker"
}

ensure_exec_link() {
  local target="$1"
  local name="$2"
  if [[ -x "$target" ]]; then
    ln -sf "$target" "/usr/local/bin/$name"
  fi
}

install_web_wrapper() {
  local name="$1"
  local tool_path="$2"

  cat > "/usr/local/bin/$name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${WEB_TOOLKIT_CONTAINER:-web-toolkit}"
TOOL_PATH="__TOOL_PATH__"

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "Error: $CONTAINER container is not running." >&2
  echo "Start it first, then retry." >&2
  exit 1
fi

exec docker exec -i "$CONTAINER" "$TOOL_PATH" "$@"
EOF

  # Inject tool path placeholder.
  sed -i.bak "s|__TOOL_PATH__|$tool_path|g" "/usr/local/bin/$name"
  rm -f "/usr/local/bin/$name.bak"
  chmod +x "/usr/local/bin/$name"
}

setup_skill_commands() {
  # Use skill scripts directly when they exist in PI agent dir.
  ensure_exec_link "$PI_AGENT_DIR/skills/search/scripts/search" "search"
  ensure_exec_link "$PI_AGENT_DIR/skills/web-fetch/scripts/web-fetch" "web-fetch"
  ensure_exec_link "$PI_AGENT_DIR/skills/web-fetch/scripts/web-fetch-allow" "web-fetch-allow"

  # Browser wrappers are often host-only; install container-safe fallbacks.
  if ! command -v web-nav >/dev/null 2>&1; then
    install_web_wrapper "web-nav" "/app/bin/cdp-nav"
  fi
  if ! command -v web-eval >/dev/null 2>&1; then
    install_web_wrapper "web-eval" "/app/bin/cdp-eval"
  fi
  if ! command -v web-screenshot >/dev/null 2>&1; then
    install_web_wrapper "web-screenshot" "/app/bin/cdp-screenshot"
  fi
}

expose_recovered_scripts() {
  local recovered="$PI_AGENT_DIR/recovered/skill-extension-demo"
  if [[ -d "$recovered" ]]; then
    ln -sfn "$recovered" /root/skill-extension-demo
  fi
}

ensure_server_config() {
  # Keep container bind host safe for docker port publishing.
  node dist/cli.js config set host 0.0.0.0 >/tmp/oppi-config-host.log 2>&1 || true

  if [[ -z "$OPPI_PORT" ]]; then
    return
  fi

  if [[ "$OPPI_PORT" =~ ^[0-9]+$ ]] && (( OPPI_PORT > 0 && OPPI_PORT <= 65535 )); then
    if ! node dist/cli.js config set port "$OPPI_PORT" >/tmp/oppi-config-port.log 2>&1; then
      echo "[oppi-entrypoint] warning: failed to set port to $OPPI_PORT" >&2
      cat /tmp/oppi-config-port.log >&2 || true
    fi
  else
    echo "[oppi-entrypoint] warning: invalid OPPI_PORT='$OPPI_PORT' (expected 1-65535); keeping existing config port" >&2
  fi
}

if [[ "$PI_AGENT_SYNC_MODE" == "always" ]]; then
  sync_seed
elif [[ ! -f "$seed_marker" ]]; then
  sync_seed
fi

setup_skill_commands
expose_recovered_scripts
ensure_server_config

echo "[oppi-entrypoint] PI_CODING_AGENT_DIR=$PI_AGENT_DIR"
if [[ -n "${SEARXNG_URL:-}" ]]; then
  echo "[oppi-entrypoint] SEARXNG_URL=$SEARXNG_URL"
fi

if [[ -n "${OPPI_PAIR_HOST:-}" ]]; then
  echo "[oppi-entrypoint] starting oppi with pairing host: $OPPI_PAIR_HOST"
  exec node dist/cli.js serve --host "$OPPI_PAIR_HOST"
fi

echo "[oppi-entrypoint] starting oppi"
exec node dist/cli.js serve
