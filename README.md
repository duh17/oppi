# Oppi — Mobile-Supervised Coding Agent

Control a sandboxed [pi](https://github.com/badlogic/pi-mono) coding agent from your iPhone. Your Mac runs the server, your phone supervises.

```
iPhone (Oppi)  ←— Local network / VPN —→  Your Mac (pi-remote)
                                            ↕
                                       pi (coding agent)
                                            ↕
                                       Your code
```

All code stays on your Mac. The agent can't run commands without your approval. Sessions are isolated per workspace.

## Quick Start

### Prerequisites

- **macOS 15+** (Sequoia)
- **Node.js 22+** — `brew install node`
- **pi CLI** — `npm install -g @mariozechner/pi-coding-agent`
- **LLM provider account** — Anthropic or OpenAI (via `pi login`)
- **iPhone** with the **Oppi** app installed via TestFlight invite

### 1. Clone and install

```bash
git clone https://github.com/duh17/pios.git
cd pios/pi-remote
npm install
```

### 2. Set up pi credentials

Set your LLM provider API key as an environment variable:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."   # or OPENAI_API_KEY, GEMINI_API_KEY, etc.
```

See `pi -h` for all supported providers and environment variables.

### 3. Start the server

```bash
npx tsx src/index.ts serve
```

First run creates `~/.pi-remote/`, generates a server identity, and listens on port **7749**.

### 4. Pair your iPhone

In a second terminal:

```bash
npx tsx src/index.ts pair "YourName"
```

Scan the QR code in the Oppi app. Done.

### 5. Start coding

1. Tap **+** in the app to create a workspace (pick a project directory)
2. Choose **Container** (isolated) or **Host** (direct) runtime
3. Start a session — type a message
4. Permission requests appear in chat — tap Allow or Deny

## Runtime Modes

| Mode | Isolation | Startup | Best for |
|------|-----------|---------|----------|
| **Container** | Apple container (lightweight macOS VM) — agent can't access host outside workspace | ~60s first run, fast after | Untrusted or experimental work |
| **Host** | None — agent runs as your user | Instant | Trusted projects, full toolchain access |

## Networking

Your phone and Mac just need to reach each other over the network.

**Same WiFi (simplest):** Works automatically. The pairing QR uses your Mac's local IP or `.local` hostname.

**VPN / overlay network:** If you want remote access, use any VPN or overlay network (Tailscale, WireGuard, ZeroTier, etc.) that puts both devices on the same network. The server auto-detects Tailscale hostnames if available.

```bash
# Force a specific hostname in the QR
npx tsx src/index.ts pair "YourName" --host my-mac.local
```

## CLI Reference

```
pi-remote serve                        Start the server
pi-remote serve --port 8080            Custom port
pi-remote pair <name>                  Show pairing QR
pi-remote pair <name> --host <host>    Force hostname in QR
pi-remote pair <name> --save qr.png    Save QR as image
pi-remote token rotate                 Rotate auth token (forces re-pair)
pi-remote status                       Server status
pi-remote config show                  Show effective config
pi-remote config validate              Validate config schema
```

## Troubleshooting

**"pi not found"** — Install globally: `npm install -g @mariozechner/pi-coding-agent`. Or set `PI_REMOTE_PI_BIN=/path/to/pi`.

**"auth.json not found"** — Set your API key: `export ANTHROPIC_API_KEY="sk-ant-..."` (or another provider). See `pi -h`.

**Can't connect from phone** — Verify both devices are on the same network. Check `curl http://localhost:7749/health`. Check firewall allows port 7749.

**Everything needs approval** — Expected! The server defaults to asking. As you approve commands, you can set up auto-allow rules in the app's policy settings.

## Security

- Communication travels over your local network or VPN — use an encrypted overlay (Tailscale, WireGuard, etc.) for remote access
- Server identity key stored in `~/.pi-remote/identity/` with restrictive permissions
- API credentials managed by `pi login` with restrictive file permissions
- Pairing uses signed, time-limited, single-use envelopes (Ed25519)
- Container mode provides filesystem isolation via Apple's containerization
- Permission gate enforces per-tool-call approval with a layered policy engine

See `pi-remote/docs/` for detailed security documentation.

## Current Limitations (V0)

- **No push notifications** — app must be open to see permission requests
- **Single user** — one owner per server instance

## Project Structure

```
pios/
├── pi-remote/              Server (TypeScript)
│   ├── src/
│   │   ├── index.ts        CLI entrypoint
│   │   ├── server.ts       HTTP + WebSocket server
│   │   ├── sessions.ts     Pi process manager
│   │   ├── gate.ts         Permission gate
│   │   ├── policy.ts       Policy engine
│   │   ├── sandbox.ts      Apple container orchestration
│   │   └── types.ts        Protocol types
│   └── extensions/
│       └── permission-gate/
├── ios/                    Oppi iOS app (SwiftUI)
└── docs/                   Design docs
```

## Development

```bash
# Server typecheck
cd pi-remote && npx tsc --noEmit

# Server tests (703 tests)
cd pi-remote && npx vitest run

# iOS build (requires Xcode 26.2+, iOS 26 SDK)
cd ios && xcodegen generate && xcodebuild build \
  -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```
