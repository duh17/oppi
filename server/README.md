# oppi-server

Server for [Oppi](../README.md). Embeds the [pi SDK](https://github.com/badlogic/pi-mono) to run agent sessions in-process.

## Mac App (recommended on macOS)

On macOS, the recommended way to run the server is the **Oppi for Mac** menu bar app. It handles installation, TCC permissions, server init, and pairing through a guided wizard — no terminal required. See the [main README](../README.md#mac-app-recommended-on-macos) for install steps.

The CLI below remains the primary path on Linux, headless/Docker setups, and for power users. The `serve`, `pair`, `doctor`, and `init` commands are also used internally by the Mac app.

---

## Quickstart

```bash
# 1. Install
git clone https://github.com/duh17/Oppi.git && cd Oppi/server
npm install

# 2. Set up pi auth (needed for LLM API calls)
pi login

# 3. Start (auto-inits config + shows pairing QR on first run)
npx oppi serve
```

Optional: enable local HTTPS/WSS (self-signed + cert pin in invite):

```bash
oppi config set tls '{"mode":"self-signed"}'
```

Optional: enable Tailscale HTTPS/WSS (Let's Encrypt cert via `tailscale cert`):

```bash
oppi config set tls '{"mode":"tailscale"}'
```

Create a workspace in the app and start a session.

## Requirements

- Node.js 20+
- [pi](https://github.com/badlogic/pi-mono) CLI installed (`pi login` for LLM auth)
- macOS or Linux

## Docker (skills-ready compose setup)

A containerized setup is included in this directory:

- `Dockerfile`
- `docker-compose.yml`
- `docker/entrypoint.sh`

The container runs `oppi serve`, persists state in Docker volumes, and seeds PI auth and skills from your host on first start. Mounting the Docker socket is optional — only needed for Docker-backed skill wrappers.

Quick start:

```bash
cd server

# Optional: host/ip or tailnet host encoded into pairing links
export OPPI_PAIR_HOST=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
# export OPPI_PAIR_HOST=<machine>.<tailnet>.ts.net

# Optional: choose container/server port (default 7750 to avoid host conflicts)
export OPPI_PORT=7750

# Optional: host-side SearXNG endpoint for search skill
export SEARXNG_URL=http://host.docker.internal:8888

# Optional: override host paths
# export PI_AGENT_DIR="$HOME/.pi/agent"
# export DOTFILES_DIR="$HOME/.config/dotfiles"

docker compose up -d --build
```

What it does:

- runs `node dist/cli.js serve` as PID 1 in container
- auto-restarts via `restart: unless-stopped`
- binds host `${OPPI_PORT:-7750}` to the same in-container port
- persists server state in Docker volume `oppi-data` (`/data/oppi`)
- persists runtime PI state in Docker volume `pi-agent-data` (`/data/pi-agent`)
- seeds PI auth/skills/extensions from host `${PI_AGENT_DIR}` into container (`copy-once` by default)
- exposes host-side SearXNG via `SEARXNG_URL` (default: `http://host.docker.internal:8888`)
- mounts Docker socket so in-session wrappers can reach sibling containers (e.g. `web-toolkit`)

Important security note:

- Mounting `/var/run/docker.sock` gives the container root-equivalent host control.
- Keep this only if you need Docker-backed skill wrappers (`web-nav`, `web-eval`, `web-screenshot`, etc.).

Useful commands:

```bash
# Logs (watch startup + pairing hints)
docker compose logs -f oppi-server

# Health
curl -s "http://127.0.0.1:${OPPI_PORT:-7750}/health"

# Verify SearXNG reachability from inside container
docker compose exec oppi-server curl -sS "$SEARXNG_URL/healthz"

# Generate pairing QR/deep link explicitly
docker compose exec oppi-server node dist/cli.js pair --host <your-lan-host-or-ip>

# Force resync PI seed from host on next start
PI_AGENT_SYNC_MODE=always docker compose up -d

# Stop / start
docker compose stop
docker compose start
```

## Commands

```bash
npx oppi serve [--host <h>]      # start server (auto-inits on first run)
npx oppi init                    # interactive first-time setup
npx oppi pair [name]             # regenerate pairing QR
npx oppi status                  # show server config and connection overview
npx oppi doctor                  # security + environment diagnostics
npx oppi config show             # show config
npx oppi config get <key>        # get a single config value
npx oppi config set <key> <val>  # update config
npx oppi config validate         # validate config file
npx oppi token rotate            # rotate owner bearer token
```

## Built-in extensions

The server ships two extensions, injected into every agent session by default:

- **ask** — structured Q&A between agent and user. The agent poses questions with predefined options; the iOS app renders them as interactive cards and routes answers back.
- **spawn_agent** — multi-agent orchestration. Spawn child sessions, inspect traces, send messages mid-turn, stop or resume agents. See [docs/sub-agents.md](docs/sub-agents.md).

Extensions are configurable per workspace via the `extensions` field in workspace settings.

## Server stats API

`GET /server/stats?range=7|30|90&tz=<offset>` returns aggregate session counts, cost, token usage, model breakdown, workspace breakdown, and daily trends. `GET /server/stats/daily/YYYY-MM-DD?tz=<offset>` returns an hourly breakdown and session list for a single day. Both the iOS and Mac apps consume these endpoints for the stats dashboard.

## Workspace files API

`GET /workspaces/:id/files/<path>` serves directory listings and file content over HTTP. `GET /workspaces/:id/files?search=<q>` provides filename search. Used by the iOS file browser.

## Configuration

- Config: `~/.config/oppi/config.json`
- Data: `~/.config/oppi/`
- Override with `OPPI_DATA_DIR` or `--data-dir`

See [config-schema.md](docs/config-schema.md).

## Development

```bash
npm test                            # vitest
npm run check                       # typecheck + lint + iOS architecture boundaries + format
npm run check:architecture          # run iOS architecture boundary checks directly
npm run review                      # generate AI review prompt from staged diff
npm run dev                         # watch mode
npm run test:e2e:linux              # linux container E2E
npm run test:e2e:lmstudio:contract  # real model contract tests
```

## Local release telemetry dashboard (SQLite + Grafana)

This stack builds directly on telemetry JSONL files written by oppi-server at:

- `${OPPI_DATA_DIR:-~/.config/oppi}/diagnostics/telemetry/*.jsonl`

### 1) Start telemetry stack (auto-import + Grafana)

```bash
cd server
npm run telemetry:grafana:up
```

This starts two services:

- `telemetry-importer` — watches telemetry JSONL and keeps SQLite in sync.
- `grafana-telemetry` — serves the dashboard.

Importer behavior:

- writes `${OPPI_DATA_DIR:-~/.config/oppi}/diagnostics/telemetry/telemetry.db`
- runs one import immediately on startup
- continues in watch mode (poll interval: `OPPI_TELEMETRY_IMPORT_INTERVAL_MS`, default `15000`)

Open:

- `http://localhost:13001`
- default login: `admin` / `admin`

The datasource and dashboard are provisioned automatically:

- datasource: `Oppi Telemetry SQLite`
- dashboard: `Oppi Release Preflight` (folder: `Oppi`)

### 2) Stop telemetry stack

```bash
cd server
npm run telemetry:grafana:down
```

### Optional manual import commands

Use these if you want to import without Docker:

```bash
cd server
npm run telemetry:import
npm run telemetry:import:watch
```

Notes:

- Services are defined in `server/docker-compose.telemetry.yml`.
- Grafana mounts telemetry read-only; importer mounts the same directory read-write.
- If you use a non-default data dir, export `OPPI_DATA_DIR` before running commands.

## License

MIT
