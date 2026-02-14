# Oppi — Mobile-Supervised Coding Agent

Control a sandboxed [pi](https://github.com/badlogic/pi-mono) coding agent from your iPhone. Your Mac runs the server, your phone supervises.

```
iPhone (Oppi)  ←— Tailscale / LAN —→  Your Mac (pi-remote)
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
- **Anthropic API key** — [console.anthropic.com](https://console.anthropic.com)
- **Oppi app** — installed via TestFlight invite

### 1. Clone and install

```bash
git clone https://github.com/duh17/pios.git
cd pios/pi-remote
npm install
```

### 2. Set up pi credentials

```bash
mkdir -p ~/.pi/agent
cat > ~/.pi/agent/auth.json << 'EOF'
{
  "anthropic": {
    "type": "api_key",
    "key": "sk-ant-api03-YOUR-KEY-HERE"
  }
}
EOF
chmod 600 ~/.pi/agent/auth.json
```

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

**Same WiFi (LAN):** Works automatically. The pairing QR uses your Mac's local IP.

**Tailscale (recommended for remote):** Install [Tailscale](https://tailscale.com) on both devices and sign in. The QR will use your Tailscale hostname. Encrypted, works from anywhere.

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

**"auth.json not found"** — Create `~/.pi/agent/auth.json` per step 2 above.

**Can't connect from phone** — Verify both devices are on the same network (or Tailscale). Check `curl http://localhost:7749/health`. Check firewall allows port 7749.

**Everything needs approval** — Expected! The server defaults to asking. As you approve commands, you can set up auto-allow rules in the app's policy settings.

## Security

- All communication is encrypted (Tailscale) or local network only
- Server identity key stored in `~/.pi-remote/identity/` with restrictive permissions
- API credentials stored in `~/.pi/agent/auth.json` (mode 600)
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
