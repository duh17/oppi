# oppi-server

Self-hosted server for the [Oppi](https://github.com/duh17/oppi) mobile coding agent. Pairs with the Oppi iOS app to give you a mobile interface for AI-assisted coding on your own machine.

## Quick Start

```bash
npm install -g oppi-server
oppi init
oppi pair
oppi serve
```

## What It Does

Oppi runs coding agents (Claude, etc.) in sandboxed workspaces on your Mac, controlled from your phone. The server handles:

- **Session management** — create, fork, resume coding sessions
- **Workspace isolation** — each workspace gets its own container or host sandbox
- **Tool gating** — approve/deny file writes, shell commands from your phone
- **Push notifications** — get notified when the agent needs input
- **Live streaming** — real-time agent output over WebSocket

## Requirements

- **Node.js** ≥ 20
- **macOS** (tested on 14+; Linux should work but untested)
- An Anthropic API key (or compatible provider)

## Commands

```
oppi init                  Interactive setup wizard
oppi serve                 Start the server
oppi pair [--host <h>]     Generate QR code for iOS pairing
oppi status                Show server + pairing status
oppi token rotate          Rotate bearer token (invalidates existing clients)
oppi config get <key>      Read a config value
oppi config set <key> <v>  Write a config value
```

## Configuration

Config lives in `~/.config/oppi/config.json` (or `$OPPI_DATA_DIR/config.json`).

Key settings:

| Key | Default | Description |
|-----|---------|-------------|
| `port` | `7749` | HTTP/WS listen port |
| `model` | `anthropic/claude-sonnet-4-20250514` | Default model |
| `maxConcurrentSessions` | `3` | Session limit |
| `apiKeys.anthropic` | — | Anthropic API key |

Run `oppi init` to set these interactively.

## Data Directory

All state (config, sessions, workspaces) lives under one directory:

```
~/.config/oppi/
├── config.json          # Server configuration
├── sessions/            # Session state + history
├── workspaces/          # Workspace definitions
└── sandbox/             # Container/host sandbox mounts
```

Override with `OPPI_DATA_DIR` or `--data-dir`.

## Security

- Bearer token auth on all endpoints
- Config files written 0600, directories 0700
- Optional security profiles: `tailscale-permissive`, `local-trust`, `locked-down`
- Signed pairing invites (Ed25519)

## License

MIT
