# Fresh Docker Server Recipe (No Custom Extensions/Skills)

Use this when you want a clean pairing test with:
- fresh `oppi` server build
- fresh `pi` CLI install
- **no** host `~/.pi` extensions or skills mounted

## 1) Start clean container

From repo root:

```bash
cd server

PORT=17759
NAME="oppi-fresh-clean-$(date +%H%M%S)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oppi-fresh-clean.XXXXXX")"
DATA_DIR="$TMP_DIR/data"
mkdir -p "$DATA_DIR"

# Your Mac LAN IP used in pair links (adjust interface if needed)
PAIR_HOST="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"

docker run -d \
  --name "$NAME" \
  -p "$PORT:$PORT" \
  -e OPPI_DATA_DIR=/data \
  -e PI_CODING_AGENT_DIR=/pi-agent \
  -v "$(pwd):/src:ro" \
  -v "$DATA_DIR:/data" \
  -v "$HOME/.npm:/root/.npm" \
  node:22-bookworm \
  bash -lc '
    set -euo pipefail
    mkdir -p /app
    tar -C /src --exclude=node_modules --exclude=dist --exclude=coverage -cf - . | tar -C /app -xf -
    cd /app

    npm ci --prefer-offline --no-audit --no-fund >/tmp/npm-ci.log 2>&1
    npm install -g --prefer-offline --no-audit --no-fund @mariozechner/pi-coding-agent >/tmp/npm-pi.log 2>&1

    # fresh pi agent home (no custom extensions/skills)
    mkdir -p /pi-agent/extensions /pi-agent/skills /pi-agent/sessions /pi-agent/themes
    chmod -R 700 /pi-agent

    # set server bind/port
    node dist/cli.js config set port '"$PORT"' >/tmp/oppi-config.log 2>&1
    node dist/cli.js config set host 0.0.0.0 >>/tmp/oppi-config.log 2>&1

    # bootstrap token once so non-loopback serve is allowed
    node dist/cli.js pair "Bootstrap" --host 127.0.0.1 >/tmp/oppi-bootstrap-pair.log 2>&1

    node dist/cli.js serve
  '

# wait for health
curl -fsS "http://127.0.0.1:$PORT/health"
```

## 2) Verify it is clean

```bash
docker inspect "$NAME" --format '{{json .HostConfig.Binds}}'
docker exec "$NAME" bash -lc 'ls -la /root/.pi /root/.pi/agent /root/.pi/agent/extensions /root/.pi/agent/skills || true'
```

Expected:
- no bind mount of `~/.pi`
- `/root/.pi/...` missing or empty

## 3) Generate a fresh pairing link (90s TTL)

```bash
docker exec "$NAME" bash -lc "cd /app && node dist/cli.js pair 'Fresh Clean' --host '$PAIR_HOST'"
```

Open the `oppi://connect?...` link from Notes/Messages/Discord on iPhone.

## 4) Cleanup

```bash
docker rm -f "$NAME"
rm -rf "$TMP_DIR"
```

## Optional: allow real prompts without loading host extensions/skills

If you need provider auth inside container, mount only `auth.json` into `/pi-agent/auth.json` (do **not** mount full `~/.pi`).

```bash
# add to docker run:
-v "$HOME/.pi/agent/auth.json:/seed/auth.json:ro"

# then in container startup before serve:
cp /seed/auth.json /pi-agent/auth.json
chmod 600 /pi-agent/auth.json
```
