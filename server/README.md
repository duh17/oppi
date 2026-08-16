# oppi-server

Server for [Oppi](../README.md). It embeds the [Pi SDK](https://github.com/badlogic/pi-mono) for server-owned sessions and supports terminal-owned mirror sessions through the `oppi-mirror` Pi extension.

## Quickstart

### npm global install

```bash
npm install -g oppi-server
oppi --version
oppi serve
```

On the first `serve`, Oppi creates `~/.config/oppi/`, generates owner credentials, starts the local CLI API at `~/.config/oppi/run/oppi.sock`, bootstraps remote HTTPS/WSS with `tls.mode=self-signed`, and prints a pairing QR and invite link for the iPhone/iPad app. Use `oppi pair` later to generate a fresh single-use invite.

Upgrade or uninstall the global CLI with npm:

```bash
npm install -g oppi-server@latest
npm uninstall -g oppi-server
```

### Source checkout install

Use a source checkout only for development or unreleased server changes. For regular use, prefer the npm global install above.

For a foreground one-off run:

```bash
git clone https://github.com/duh17/oppi.git && cd oppi/server
npm install
npm run build
node dist/src/cli.js serve
```

For ongoing development, source-link the machine-wide `oppi` command and install the LaunchAgent from that link:

```bash
cd oppi/server
bash setup.sh --install
```

The global npm link points `oppi` to this checkout's `dist/src/cli.js`. Rebuilding the checkout therefore updates the terminal CLI, background server, and managed host-session CLI together. Run `setup.sh --install` again if another npm install replaces the link.

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

Use this command only when you need to switch back to self-signed later:

```bash
oppi config set tls '{"mode":"self-signed"}'
```

Optional: enable Tailscale HTTPS/WSS (Let's Encrypt cert via `tailscale cert`):

```bash
oppi config set tls '{"mode":"tailscale"}'
```

Tailscale must be connected to obtain or renew this certificate and for remote Tailnet access. Existing locally valid certificate and key material can restart the remote listener while Tailscale is stopped. Without usable material, the remote listener stays unavailable and fails closed. The local Unix-socket CLI remains available because it uses neither Tailscale nor TLS.

Oppi checks the certificate's full validity interval, Tailnet DNS SAN, and
certificate/key match. It assumes that material renewed by the local
`tailscale` command or placed at the configured paths has the intended
provenance. During startup and `oppi doctor`, it does not independently
validate a public CA chain. HTTPS clients keep normal certificate-chain
verification enabled and reject untrusted material.

Create a workspace in the app and start a session.

## Requirements

- Node.js 24+
- [Pi](https://github.com/badlogic/pi-mono) runtime dependency, installed automatically with the npm package
- At least one Pi provider configured with `pi auth` or an API key such as `ANTHROPIC_API_KEY`
- macOS or Linux
- OpenSSL on PATH for `tls.mode=self-signed` certificate generation

Remote clients use authenticated HTTPS/WSS, including HTTPS through Tailscale.

## Docker (skills-ready compose setup)

This directory includes a containerized setup:

- `Dockerfile`
- `docker-compose.yml`
- `docker/entrypoint.sh`

The container runs `oppi serve`, persists state in Docker volumes, and seeds Pi auth and skills from your host on its first start. Mount the Docker socket only for Docker-backed skill wrappers.

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

This setup:

- installs `oppi` as the canonical CLI inside the image and runs `oppi serve` as PID 1
- auto-restarts via `restart: unless-stopped`
- binds host `${OPPI_PORT:-7750}` to the same in-container port
- persists server state in Docker volume `oppi-data` (`/data/oppi`)
- persists runtime Pi state in Docker volume `pi-agent-data` (`/data/pi-agent`)
- seeds Pi auth/skills/extensions from host `${PI_AGENT_DIR}` into container (`copy-once` by default)
- exposes host-side SearXNG via `SEARXNG_URL` (default: `http://host.docker.internal:8888`)
- mounts Docker socket so in-session wrappers can reach sibling containers (e.g. `web-toolkit`)

Important security note:

- Mounting `/var/run/docker.sock` gives the container root-equivalent host control.
- Keep this only if you need Docker-backed skill wrappers (`web-nav`, `web-eval`, `web-screenshot`, etc.).

Use these commands:

```bash
# Logs (watch startup + pairing hints)
docker compose logs -f oppi-server

# Health
curl -sk "https://127.0.0.1:${OPPI_PORT:-7750}/health"

# Verify SearXNG reachability from inside container
docker compose exec oppi-server curl -sS "$SEARXNG_URL/healthz"

# Run CLI commands inside the container so they reach its Unix socket
docker compose exec oppi-server oppi workspace list

# Generate pairing QR/deep link explicitly
docker compose exec oppi-server oppi pair --host <your-lan-host-or-ip>

# Force resync Pi seed from host on next start
PI_AGENT_SYNC_MODE=always docker compose up -d

# Stop / start
docker compose stop
docker compose start
```

## Commands

Use `oppi ...` for npm/global and Docker installs. In a source checkout before linking, use `node dist/src/cli.js ...` from the `server/` directory. Docker commands run inside the server container, for example `docker compose exec oppi-server oppi session list`, because Docker Desktop does not bridge the container's Unix socket to the host.

```bash
oppi serve [--host <h>]      # start server
oppi init                    # interactive first-time setup
oppi pair [--host <h>]       # regenerate pairing QR + invite link
oppi status                  # server, network, and pairing status
oppi doctor                  # security and environment diagnostics
oppi workspace ...           # list/inspect/create/update/delete workspaces
oppi worktree ...            # list/create/open/preview/remove worktrees
oppi session ...             # create/send/watch/wait/inspect/resume/fork/delete sessions
oppi agent ...               # manage saved Agents
oppi schedule ...            # manage schedules and run history
oppi server ...              # install/status/restart/stop/uninstall launchd service
oppi config ...              # show/get/set/validate config
oppi token rotate            # rotate owner bearer token
oppi update                  # update the npm-installed server and CLI
```

Commands that call the local API use bearer-authenticated HTTP over `$OPPI_DATA_DIR/run/oppi.sock`. They never fall back automatically to a network host or plaintext TCP. Deep custom data-directory paths use a deterministic owner-only socket under the system temporary directory to stay within Unix socket path limits. Local CLI commands continue to work when remote HTTPS/WSS is unavailable. The bearer-free Oppi Mirror bridge also uses this owner-only Unix socket and is not exposed by the network listener.

`oppi session inspect` consolidates session-history reads. Start with its default turn outline, use `--view summary` for counts, and request `--turns <spec> --view messages|tools` only for the smallest relevant turn set.

Managed host sessions cannot use `oppi session` to target themselves. They may create direct child sessions. A root can pass `oppi session create --allow-nested-delegation` to authorize a child to spawn its own children; the grant propagates down the subtree, so an explicitly requested grandchild session can always be created under an authorized child. Human terminal CLI invocations remain unrestricted.

### Saved Agents and schedules

Saved Agents store reusable Agent definitions. An optional `icon` string accepts one Unicode emoji or an SF Symbol name; `icon: null` clears it. Saved-Agent launches and Oppi control sessions snapshot the current Agent version and icon into session launch metadata, so later Agent edits do not change existing session rows or chat identity. Unsupported SF Symbols and malformed persisted values render the generic Agent icon without affecting execution. The shipped Oppi agent is limited to server-managed `oppi`, structured `ask`, and Pi's stock `read` and `edit`, with a minimal system prompt that points at `oppi help` and packaged docs. It can ask native clarifying questions and wait for session status with `oppi session wait` or its bounded one-session `oppi session watch` alias. Destructive Oppi commands require explicit approval by default; stock file reads/edits use host permissions and do not pass through Oppi approval, while `write`, `bash`, and other filesystem tools remain unavailable. Launch inputs such as workspace, worktree, prompt, and session name stay on `oppi session create`, so the same Agent definition can run in different workspaces.

Schedules store a trigger and an action. `oppi schedule create` accepts `--at`, `--every`, or `--cron`; actions can start a new session in a workspace or send input to an existing session. The background schedule runner materializes due runs, dispatches active schedules, and records run history. Pause or archive a schedule to stop future automatic runs.

### Install and update modes

- **npm global install:** npm owns both server code and the `oppi` executable used by humans, the Mac app, and managed host sessions. Use `oppi update` or `npm install -g oppi-server@latest` to upgrade, and `npm uninstall -g oppi-server` to remove it.
- **Mac app:** requires the npm global install and does not bundle or seed another server runtime.
- **Git/bootstrap install:** git owns server code. Use `git pull && npm install && npm run build` to upgrade a checkout. For a machine-wide development CLI, run `bash setup.sh --install`; it source-links `oppi` to the checkout and installs the LaunchAgent from that exact link. `OPPI_SERVER_PATH` remains available for explicit Mac development launches.

## Extensions

Oppi uses Pi's extension system and adds mobile rendering for standard extension UI requests. Pi extensions own approval behavior, not server config.

See [Oppi extension behavior](../docs/extensions.md) for extension loading, per-workspace Pi resource toggles, and mobile rendering. Use [Oppi Mirror mode](../docs/oppi-mirror.md) for terminal-owned sessions.

## Server stats API

`GET /server/stats?range=7|30|90&tz=<offset>` returns aggregate session counts, cost, token usage, model breakdown, workspace breakdown, and daily trends. `GET /server/stats/daily/YYYY-MM-DD?tz=<offset>` returns an hourly breakdown and session list for a single day. Both the iOS and Mac apps consume these endpoints for the stats dashboard.

## Workspace files API

`GET /workspaces/:id/files/<path>` serves directory listings and file content over HTTP. `GET /workspaces/:id/file-index` returns a flat path index for client-side filename search in the iOS file browser.

## Configuration

- **Config file**: `~/.config/oppi/config.json`
- **Data directory**: `~/.config/oppi/`
- **Local CLI socket**: `$OPPI_DATA_DIR/run/oppi.sock` for normal-length paths
- Override the config and data directory with `OPPI_DATA_DIR` or `--data-dir`

Key config sections:

| Section  | What it controls                                                            |
| -------- | --------------------------------------------------------------------------- |
| `tls`    | HTTPS mode: `self-signed`, `tailscale`, `manual`, or explicit insecure HTTP |
| `asr`    | Dictation pipeline: STT backend endpoint                                    |
| `images` | Image attachment preprocessing before upload                                |

Manage provider API keys with `pi auth`, not Oppi config. See [model-selection.md](docs/model-selection.md) for model routing. Unknown config keys are ignored on startup and reported by `oppi config validate`.

Use the redacted CLI view and typed setters; do not print the raw credential-bearing config:

```bash
oppi config show
oppi config get asr
oppi config set images.autoResize false
oppi config set tls '{"mode":"self-signed"}'
# Source checkouts: use `node dist/src/cli.js` instead of `oppi`.
```

See [config-schema.md](docs/config-schema.md) for full reference.

## Development

### Dependency installation and script runtimes

CI, Docker builds, and development checks use `npm`; `package-lock.json` is the
authoritative dependency lockfile for those flows. Use `npm ci` when you need
CI's dependency tree. Otherwise, Bun executes only the TypeScript repository
scripts referenced by `package.json`.

The source-checkout bootstrapper is currently an exception. Root `install.sh`
delegates to `server/setup.sh`, which prefers Bun when installed and runs `bun install --ignore-scripts`. That documented flow consumes `bun.lock`, so the Bun lockfile cannot be removed until the bootstrapper installs dependencies with
npm. In the meantime, its dependency tree can diverge from the npm/CI tree.

```bash
npm test                            # vitest unit tests
npm run test:coverage               # coverage gate
npm run check                       # typecheck + lint + dead-code + format check
npm run dev                         # watch mode
npm run test:e2e                    # Docker E2E harness
npm run test:e2e:pairing            # pairing flow only
npm run test:e2e:session            # paired session flow only
E2E_NATIVE=1 npm run test:e2e       # native E2E harness without Docker
npm run bench:correctness           # check + test before perf measurements
npm run bench                       # correctness + perf regression gate
npm run telemetry:review            # telemetry summary
npm run diagnostics:review          # diagnostics summary
```

Benchmark conventions, baselines, and comparison workflow live in [bench/README.md](bench/README.md).

## Local release telemetry dashboard (SQLite + Grafana)

This stack reads telemetry JSONL files that oppi-server writes to:

- `${OPPI_DATA_DIR:-~/.config/oppi}/diagnostics/telemetry/*.jsonl`

### 1) Start telemetry stack (auto-import + Grafana)

```bash
cd server
npm run telemetry:grafana:up
```

This starts two services:

- `telemetry-importer`: watches telemetry JSONL and keeps SQLite in sync.
- `grafana-telemetry`: serves the dashboard.

Importer behavior:

- reads telemetry JSONL from `${OPPI_DATA_DIR:-~/.config/oppi}/diagnostics/telemetry/*.jsonl`
- writes SQLite into a Docker-managed volume mounted at `/var/lib/oppi-telemetry-db/telemetry.db`
- runs one import immediately on startup
- runs SQLite integrity checks on startup and recovery by default, not on every watch tick
- continues in watch mode; `OPPI_TELEMETRY_IMPORT_INTERVAL_MS` defaults to `15000`
- ingests append-only daily JSONL files incrementally instead of reimporting the whole hot file each cycle
- normalizes source-file keys so Docker and host imports target the same rows
- flattens common server-ops tags (`path`, `type`, `level`, `lane`, `ring`, `code`, `outcome`) for split-stream Grafana panels
- keeps at most `OPPI_TELEMETRY_BROKEN_DB_KEEP_COUNT` malformed-db backups; the default is `1`
- uses a short-lived lock file so overlapping importer runs skip rather than clobber each other

Open:

- `http://localhost:13001`
- default login: `admin` / `admin`

The stack provisions this datasource and these dashboards automatically:

- datasource: `Oppi Telemetry SQLite`
- dashboards: `Oppi Release Preflight` and `Oppi Server Health` (folder: `Oppi`)

### 2) Stop telemetry stack

```bash
cd server
npm run telemetry:grafana:down
```

### Optional manual import commands

Use these commands to import without Docker:

```bash
cd server
npm run telemetry:import
npm run telemetry:import:watch
```

Notes:

- Services are defined in `server/docker-compose.telemetry.yml`.
- The Docker stack keeps SQLite in a named volume rather than the host-mounted telemetry directory. It avoids SQLite corruption on macOS bind mounts while still reading host JSONL input files. Grafana opens this database read-write because SQLite WAL-mode readers may need sidecar shared-memory files, even for read queries.
- Manual `telemetry:import` runs still write `${OPPI_DATA_DIR:-~/.config/oppi}/diagnostics/telemetry/telemetry.db` on the host, share the Docker watcher's normalized file keys, and skip when another importer run holds the lock.
- Importer integrity-check mode defaults to `startup`; use `--integrity-check always` for old every-run checking or `--integrity-check never` for trusted throwaway databases.
- When you use a non-default data dir, export `OPPI_DATA_DIR` before running commands.

## License

MIT
