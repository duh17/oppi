# oppi-server

Self-hosted server for the [Oppi](https://github.com/duh17/oppi) mobile coding agent. Pairs with the Oppi iOS app to give you a mobile interface for AI-assisted coding on your own machine.

## Quick Start

```bash
git clone https://github.com/duh17/oppi.git
cd oppi/server
npm install
npx oppi init
npx oppi pair
npx oppi serve
```

## What It Does

Oppi runs [pi](https://github.com/badlogic/pi-mono) sessions on your Mac — in Apple containers or directly on the host — controlled from your phone. The server handles:

- **Session management** — create, fork, resume coding sessions
- **Workspace isolation** — each workspace gets its own container or host sandbox
- **Tool gating** — approve/deny file writes, shell commands from your phone
- **Push notifications** — get notified when the agent needs input
- **Live streaming** — real-time agent output over WebSocket
- **Skill registry** — curate what your agent can do, with container compatibility detection

## Requirements

- **Node.js** ≥ 22
- **[pi](https://github.com/badlogic/pi-mono)** — the coding agent runtime (`npm install -g @mariozechner/pi-coding-agent`)
- **macOS 15+** (Sequoia) — required for Apple container support; host mode may work on Linux but is untested
- An LLM provider account (Anthropic, OpenAI, etc. — via `pi login`)

## Commands

```
oppi init                  Interactive setup wizard
oppi serve                 Start the server
oppi pair [--host <h>]     Generate QR code for iOS pairing
oppi status                Show server + pairing status
oppi token rotate          Rotate bearer token (invalidates existing clients)
oppi config get <key>      Read a config value
oppi config set <key> <v>  Write a config value
oppi config show           Show effective config
oppi config validate       Validate config file
oppi env init              Capture shell PATH for host sessions
oppi env show              Show resolved host PATH
```

## Configuration

Config lives in `~/.config/oppi/config.json` (or `$OPPI_DATA_DIR/config.json`).

Key settings:

| Key | Default | Description |
|-----|---------|-------------|
| `port` | `7749` | HTTP/WS listen port |
| `defaultModel` | `anthropic/claude-sonnet-4-20250514` | Default model for new sessions |
| `maxSessionsPerWorkspace` | `3` | Session limit per workspace |
| `maxSessionsGlobal` | `5` | Total session limit |
| `security.profile` | `tailscale-permissive` | Security profile (`tailscale-permissive` or `strict`) |

Run `oppi init` to set these interactively.

## Data Directory

All state (config, sessions, workspaces) lives under one directory:

```
~/.config/oppi/
├── config.json          # Server configuration
├── identity/            # Ed25519 server keys
├── sessions/            # Session state + history
├── workspaces/          # Workspace definitions
├── rules.json           # Learned policy rules
├── skills/              # User-defined skills
└── sandbox/             # Container/host sandbox mounts
```

Override with `OPPI_DATA_DIR` or `--data-dir`.

## Development

```bash
npm install
npm test          # vitest test suite
npm run build     # TypeScript compile
npm run check     # typecheck + lint + format check
npm start         # Start server (from compiled dist/)
npm run dev       # Start with tsx watch (auto-reload)
```

## Security

- Ed25519 signed pairing invites (time-limited, single-use)
- Timing-safe bearer token auth on all endpoints
- Credential isolation — API keys never enter containers (auth proxy injects on the host)
- Config files written 0600, directories 0700
- Security profiles: `tailscale-permissive` (default) or `strict`
- Hard deny rules block dangerous operations regardless of user policy

See `docs/` for detailed security documentation.

## License

MIT
