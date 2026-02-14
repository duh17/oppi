# Oppi Server

Self-hosted server for the [Oppi](https://apps.apple.com/app/oppi) iOS app — a mobile-supervised coding agent.

Oppi Server runs on your Mac (or Linux box), spawns [pi](https://github.com/nicholasgasior/pi-coding-agent) coding agent sessions, and streams them to your phone over WebSocket. Every tool call goes through a permission gate — you approve or deny from your pocket.

## Quick Start

### Prerequisites

- **Node.js 22+** — `brew install node` or [nodejs.org](https://nodejs.org)
- **pi CLI** — `npm install -g @nicholasgasior/pi-coding-agent`
- **LLM credentials** — run `pi`, then `/login` to authenticate (or set `ANTHROPIC_API_KEY` etc.)

### Install & Run

```bash
git clone https://github.com/duh17/oppi.git
cd oppi
npm install
npm run build
npx oppi-server serve
```

The server starts on `http://0.0.0.0:7779` by default. A QR code appears in the terminal — scan it with the Oppi iOS app to pair.

### Pair a Device

```bash
npx oppi-server pair           # generates a pairing QR code
```

Open the Oppi app → Settings → Add Server → scan the QR.

## Architecture

```
┌──────────┐    WebSocket     ┌──────────────┐     stdio/RPC     ┌─────┐
│  Oppi    │ ◄──────────────► │ oppi-server   │ ◄───────────────► │ pi  │
│  (iOS)   │   permissions    │ (this repo)   │   tool calls      │ CLI │
└──────────┘                  └──────────────┘                    └─────┘
```

- **Permission gate**: Pi extension that intercepts tool calls and routes approval requests to connected mobile clients.
- **Policy engine**: Rule-based auto-allow/deny. Reduces notification noise for safe operations (reads, linting, tests).
- **Sessions**: Each conversation is a pi session. Multiple sessions can run concurrently.
- **Storage**: Sessions, workspaces, and config live in `~/.config/oppi/`.

## Configuration

Config file at `~/.config/oppi/config.json`:

```json
{
  "host": "0.0.0.0",
  "port": 7779,
  "runtime": "host"
}
```

`runtime` can be `"host"` (default, runs pi directly) or `"container"` (Linux containers via podman/docker).

## Commands

| Command | Description |
|---------|-------------|
| `oppi-server serve` | Start the server |
| `oppi-server pair <name>` | Generate pairing QR for a new device |
| `oppi-server token rotate` | Rotate the server auth token |
| `oppi-server config show` | Print current configuration |
| `oppi-server config validate` | Validate config and repair issues |
| `oppi-server identity` | Show server identity (Ed25519 public key) |

## Development

```bash
npm run dev          # watch mode with tsx
npm test             # run test suite
npm run check        # typecheck + lint + format check
```

## Security

- All connections require a shared secret established during pairing.
- Tool calls are gated by default — nothing executes without approval (or a matching policy rule).
- Host mode gives pi full access to your machine. Use policy rules to constrain dangerous operations.
- See `docs/` for security design docs.

## License

MIT
