# oppi-server

Server for [Oppi](../README.md). Embeds the [pi SDK](https://github.com/earendil-works/pi) to run agent sessions in-process.

## Quickstart

### npm global install

```bash
npm install -g oppi-server
oppi --version
oppi serve
```

On first `serve`, Oppi creates `~/.config/oppi/`, generates owner credentials,
and bootstraps local HTTPS/WSS with `tls.mode=self-signed`. Run `oppi pair` to
show a pairing QR for the iOS/macOS app.

Upgrade or uninstall the global CLI with npm:

```bash
npm install -g oppi-server@latest
npm uninstall -g oppi-server
```

### Source checkout install

```bash
git clone https://github.com/duh17/oppi.git && cd oppi/server
npm install
npm run build
node dist/src/cli.js serve
```

If you prefer the repo bootstrapper from outside the repo, use:

```bash
curl -fsSL https://raw.githubusercontent.com/duh17/oppi/main/install.sh | bash
```

Equivalent explicit steps:

```bash
git clone https://github.com/duh17/oppi.git
cd oppi
bash install.sh
```

Use this command only if you need to switch back to self-signed later:

```bash
oppi config set tls '{"mode":"self-signed"}'
```

Optional: enable Tailscale HTTPS/WSS (Let's Encrypt cert via `tailscale cert`):

```bash
oppi config set tls '{"mode":"tailscale"}'
```

Create a workspace in the app and start a session.

## Requirements

- Node.js 23.6+
- [pi](https://github.com/earendil-works/pi) runtime dependency (installed automatically with npm package)
- macOS or Linux
- OpenSSL on PATH for `tls.mode=self-signed` certificate generation

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

- runs `node dist/src/cli.js serve` as PID 1 in container
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
docker compose exec oppi-server node dist/src/cli.js pair --host <your-lan-host-or-ip>

# Force resync PI seed from host on next start
PI_AGENT_SYNC_MODE=always docker compose up -d

# Stop / start
docker compose stop
docker compose start
```

## Commands

Use `oppi ...` for npm/global installs. In a source checkout before linking, use
`node dist/src/cli.js ...` from the `server/` directory.

```bash
oppi serve [--host <h>]      # start server
oppi init                    # interactive first-time setup
oppi pair [name]             # regenerate pairing QR
oppi status                  # server config overview
oppi doctor                  # check prerequisites
oppi update                  # update mutable runtime dependencies only
oppi update --self           # update the global npm server install
oppi config show             # show config
oppi config get <key>        # get a config value, including nested paths
oppi config set <key> <val>  # update config, e.g. asr.sttEndpoint
oppi config validate         # validate config file
oppi token rotate            # rotate owner bearer token
oppi server install          # install LaunchAgent (macOS)
oppi server uninstall        # remove LaunchAgent
oppi server status           # check background service
oppi server restart          # restart background server
oppi server stop             # stop background server
```

### Install and update modes

- **App-managed runtime:** Oppi.app owns server code and seeds
  `~/.config/oppi/server-runtime`. `oppi update` updates mutable runtime
  dependencies only; update Oppi.app to update server code.
- **npm global install:** npm owns server code. Use `oppi update --self` or
  `npm install -g oppi-server@latest` to upgrade, and `npm uninstall -g
oppi-server` to remove. `oppi update` updates mutable runtime dependencies only.
- **Git/bootstrap install:** git owns server code. Use
  `git pull && npm install && npm run build` to upgrade a checkout.

## Built-in extensions

The server ships four built-in extension names:

- **ask** — structured Q&A between agent and user. The agent poses questions with predefined options; the iOS app renders them as interactive cards and routes answers back.
- **subagents** — multi-agent orchestration. Includes the `spawn_agent`, `stop_agent`, `send_message`, and `inspect_agent` tools. See [docs/sub-agents.md](docs/sub-agents.md).
- **voice** — server-managed voice creation and playback helpers exposed through the Oppi voice tools. See [Voice replies / TTS](docs/tts.md).
- **oppi-admin** — workspace and theme administration tools, including `build_theme`. See [Custom themes](docs/themes.md).

Oppi built-in names are `ask`, `subagents`, `voice`, and `oppi-admin`.
The reserved server-managed name is `permission-gate`.

Workspace extension behavior is explicit:

- when `workspace.extensions` is unset, Oppi keeps normal pi discovery and does **not** auto-enable its own built-ins
- when `workspace.extensions` is set, it becomes an authoritative allowlist for optional extensions; include `ask`, `subagents`, `voice`, and/or `oppi-admin` explicitly if you want them

Pi provides the core runtime and extension model. Oppi builds on top of that with the mobile client, transport, server orchestration, native rendering, and server-managed capabilities.

## Server stats API

`GET /server/stats?range=7|30|90&tz=<offset>` returns aggregate session counts, cost, token usage, model breakdown, workspace breakdown, and daily trends. `GET /server/stats/daily/YYYY-MM-DD?tz=<offset>` returns an hourly breakdown and session list for a single day. Both the iOS and Mac apps consume these endpoints for the stats dashboard.

## Workspace files API

`GET /workspaces/:id/files/<path>` serves directory listings and file content over HTTP. `GET /workspaces/:id/file-index` returns a flat path index for client-side filename search in the iOS file browser.

## Configuration

- **Config file**: `~/.config/oppi/config.json`
- **Data directory**: `~/.config/oppi/`
- Override both with `OPPI_DATA_DIR` or `--data-dir`

Key config sections:

| Section  | What it controls                                                        |
| -------- | ----------------------------------------------------------------------- |
| `tls`    | HTTPS mode: `self-signed`, `tailscale`, or `none`                       |
| `asr`    | Dictation pipeline: STT backend endpoint                                |
| `policy` | Permission gate rules (allow/deny/ask per tool, guardrails, heuristics) |

Model routing and API keys are managed by pi (`pi auth`), not the oppi config.

Quick inspection:

```bash
cat ~/.config/oppi/config.json | jq .          # raw config
cat ~/.config/oppi/config.json | jq '.asr'     # single section
node dist/src/cli.js config show                # formatted overview
node dist/src/cli.js config get asr             # top-level key
node dist/src/cli.js config set tls '{"mode":"self-signed"}'  # set via CLI (SETTABLE_KEYS only)
```

For sections not in `SETTABLE_KEYS` (like `asr`, `policy`), edit `config.json` directly and restart the server.

See [config-schema.md](docs/config-schema.md) for full reference.

## Development

```bash
npm test                            # vitest
npm run check                       # typecheck + lint + iOS architecture boundaries + format
npm run check:architecture          # run iOS architecture boundary checks directly
npm run review                      # generate AI review prompt from staged diff
npm run dev                         # watch mode
npm run bench:correctness           # check + test before perf measurements
npm run bench                       # correctness + perf regression gate (median vs baseline)
npm run bench:perf                  # hotpath microbenchmark once (skip compare)
npm run bench:perf:gate             # hotpath benchmark gate (median vs baseline)
npm run bench:hotpath               # critical event pipeline benchmark
npm run bench:hotpath:gate          # hotpath gate (correctness + median compare)
npm run test:e2e:linux              # linux container E2E
npm run test:e2e:lmstudio:contract  # real model contract tests
```

Benchmark conventions, baselines, and comparison workflow live in [bench/README.md](bench/README.md).

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

- reads telemetry JSONL from `${OPPI_DATA_DIR:-~/.config/oppi}/diagnostics/telemetry/*.jsonl`
- writes SQLite into a Docker-managed volume mounted at `/var/lib/oppi-telemetry-db/telemetry.db`
- runs one import immediately on startup
- continues in watch mode (poll interval: `OPPI_TELEMETRY_IMPORT_INTERVAL_MS`, default `15000`)
- ingests incrementally for append-only daily JSONL files instead of reimporting the whole hot file each cycle
- normalizes source file keys so Docker and host imports target the same rows
- flattens common server-ops tags (`path`, `type`, `level`, `lane`, `ring`, `code`, `outcome`) for split-stream Grafana panels
- keeps at most `OPPI_TELEMETRY_BROKEN_DB_KEEP_COUNT` malformed-db backups (default `1`)
- uses a short-lived lock file so overlapping importer runs skip instead of clobbering each other

Open:

- `http://localhost:13001`
- default login: `admin` / `admin`

The datasource and dashboard are provisioned automatically:

- datasource: `Oppi Telemetry SQLite`
- dashboards: `Oppi Release Preflight` and `Oppi Server Health` (folder: `Oppi`)

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
- The Docker stack keeps SQLite inside a named volume instead of the host-mounted telemetry directory. This avoids SQLite corruption on macOS bind mounts while still reading host JSONL input files.
- Manual `telemetry:import` runs still write `${OPPI_DATA_DIR:-~/.config/oppi}/diagnostics/telemetry/telemetry.db` on the host, share the same normalized file keys as the Docker watcher, and skip if another importer run currently holds the lock.
- If you use a non-default data dir, export `OPPI_DATA_DIR` before running commands.

## License

MIT
