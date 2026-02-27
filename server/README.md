# oppi-server

Server for [Oppi](../README.md). Embeds the [pi SDK](https://github.com/badlogic/pi-mono) to run agent sessions in-process.

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
npx oppi pair [name]             # regenerate pairing QR
npx oppi status                  # show running sessions
npx oppi config show             # show config
npx oppi config set <key> <val>  # update config
npx oppi token rotate            # rotate owner bearer token
```

## Configuration

- Config: `~/.config/oppi/config.json`
- Data: `~/.config/oppi/`
- Override with `OPPI_DATA_DIR` or `--data-dir`

See [config-schema.md](docs/config-schema.md).

## Development

```bash
npm test                            # vitest
npm run check                       # typecheck + lint + format
npm run dev                         # watch mode
npm run test:e2e:linux              # linux container E2E
npm run test:e2e:lmstudio:contract  # real model contract tests
```

## License

MIT
