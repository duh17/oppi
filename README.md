# Oppi — Mobile-Supervised Coding Agent

Control a sandboxed [pi](https://github.com/badlogic/pi-mono) coding agent from your iPhone. Your Mac runs the server, your phone supervises.

```
iPhone (Oppi app)  ←— Local network / VPN —→  Your Mac (oppi server)
                                                 ↕
                                            pi (coding agent)
                                                 ↕
                                            Your code
```

All code stays on your machine. The agent can't run dangerous commands without your approval. Sessions are isolated per workspace.

## Features

- **Permission gate** — Every risky tool call (writes, deletes, installs, network access) routes to your phone for approval. Tap Allow or Deny from anywhere.
- **Policy engine** — Layered rules auto-allow safe operations and block dangerous ones. Learns from your decisions over time.
- **Workspaces** — Isolated environments with their own skills, policies, and project mounts.
- **Two runtime modes** — Container (Apple sandbox, full isolation) or Host (direct, full toolchain access).
- **Push notifications** — Permission requests and session events pushed via APNs. No need to keep the app open.
- **Multi-server** — Pair your phone with multiple Mac servers. Browse all workspaces from one screen.
- **Skills** — Curate what your agent can do. Built-in skill registry with container compatibility detection.
- **Session traces** — Full conversation history with tool calls, diffs, and branching rendered as a timeline.
- **Streaming** — Real-time text, thinking, and tool output streamed over WebSocket.

## Quick Start

### Prerequisites

- **macOS 15+** (Sequoia)
- **Node.js 22+** — `brew install node`
- **pi CLI** — `npm install -g @mariozechner/pi-coding-agent`
- **LLM provider account** — Anthropic or OpenAI (via `pi login`)
- **iPhone** with the **Oppi** app (free on the App Store, or build from source)

### 1. Install and set up

```bash
git clone https://github.com/duh17/oppi.git
cd oppi/server
npm install
```

First-time interactive setup:

```bash
npx oppi init
```

This creates `~/.config/oppi/`, generates an Ed25519 server identity, and walks you through port, model, and session limit configuration.

### 2. Set up pi credentials

```bash
pi
# Then type /login to authenticate with Anthropic, OpenAI, or another provider
```

### 3. Start the server

```bash
npx oppi serve
```

Listens on port **7749** by default. Auto-detects Tailscale and local network hostnames.

### 4. Pair your iPhone

In a second terminal:

```bash
npx oppi pair
```

Scan the QR code in the Oppi app. The pairing uses a signed, time-limited Ed25519 envelope — no passwords to type.

### 5. Start coding

1. Tap **+** in the app to create a workspace (pick a project directory)
2. Choose **Container** (isolated) or **Host** (direct) runtime
3. Start a session — type a message
4. Permission requests appear as push notifications — tap to approve or deny

## Runtime Modes

| Mode | Isolation | Startup | Best for |
|------|-----------|---------|----------|
| **Container** | Apple container sandbox — agent can't access host outside workspace | ~60s first run, fast after | Untrusted or experimental work |
| **Host** | None — agent runs as your user | Instant | Trusted projects, full toolchain access |

## Architecture

```
┌──────────────────┐         ┌──────────────────────────────────────┐
│  iPhone           │         │  Your Mac                             │
│                   │         │                                       │
│  Oppi iOS app    │◄──WS──►│  oppi server (Node.js)                │
│  - Chat timeline  │         │  ├── Session manager                  │
│  - Permission UI  │         │  ├── Policy engine (layered rules)    │
│  - Workspace mgmt │  REST   │  ├── Permission gate (TCP per-session)│
│  - Push notifs    │◄──────►│  ├── Auth proxy (credential isolation) │
│  - Multi-server   │         │  ├── Sandbox manager (containers)     │
│                   │         │  └── Skill registry + push client     │
└──────────────────┘         │                                       │
                              │  pi (coding agent, RPC over stdio)    │
                              │  └── runs in container or on host     │
                              └──────────────────────────────────────┘
```

## Networking

Your phone and Mac just need to reach each other over the network.

**Same WiFi (simplest):** Works automatically. The pairing QR uses your Mac's local IP or `.local` hostname.

**VPN / overlay network:** For remote access, use any VPN or overlay network (Tailscale, WireGuard, ZeroTier, etc.) that puts both devices on the same network. The server auto-detects Tailscale hostnames if available.

```bash
# Force a specific hostname in the pairing QR
npx oppi pair --host my-mac.example.com
```

## CLI Reference

```
oppi init                          Interactive first-time setup
oppi serve                         Start the server
oppi serve --port 8080             Custom port
oppi pair                          Show pairing QR
oppi pair --host <host>            Force hostname in QR
oppi pair --save qr.png            Save QR as image
oppi status                        Server status
oppi token rotate                  Rotate auth token (forces re-pair)
oppi config show                   Show effective config
oppi config set <key> <value>      Update a config value
oppi config get <key>              Get a config value
oppi config validate               Validate config file
oppi env init                      Capture shell PATH for host sessions
oppi env show                      Show resolved host PATH
```

## Security

- **Credential isolation** — API keys never enter containers. The auth proxy on the host injects real credentials into outbound requests.
- **Signed pairing** — Ed25519 signed, time-limited, single-use pairing envelopes. No shared passwords.
- **Permission gate** — Every tool call evaluated against a layered policy engine. Dangerous operations require explicit phone approval. Fail-closed: if the phone is unreachable, risky operations are denied.
- **Container sandbox** — Apple container isolation for untrusted work. Agent can only access mounted workspace directories.
- **Timing-safe auth** — Bearer token comparison uses `timingSafeEqual` to prevent timing attacks.
- **Hard denies** — Immutable rules block the most dangerous operations (e.g., `rm -rf /`, modifying system files) regardless of user policy.

See `server/docs/` for detailed security documentation including the [threat model](server/docs/security-prompt-injection-residual-risk.md) and [policy engine design](server/docs/policy-engine-v2.md).

## Project Structure

```
oppi/
├── server/                 Server runtime (TypeScript)
│   ├── src/
│   │   ├── index.ts        CLI entrypoint
│   │   ├── server.ts       HTTP + WebSocket server
│   │   ├── sessions.ts     Pi process lifecycle + RPC bridge
│   │   ├── policy.ts       Layered policy engine
│   │   ├── gate.ts         Permission gate (TCP)
│   │   ├── sandbox.ts      Apple container orchestration
│   │   ├── auth-proxy.ts   Credential-isolating reverse proxy
│   │   ├── push.ts         APNs push notification client
│   │   ├── storage.ts      Persistent config + session storage
│   │   ├── stream.ts       Multiplexed WebSocket streams
│   │   ├── skills.ts       Skill registry + user skills
│   │   └── types.ts        Protocol types (shared with iOS)
│   ├── extensions/
│   │   └── permission-gate/ Pi extension for tool call interception
│   ├── tests/              vitest test suite
│   └── docs/               Design documents
├── ios/                    Oppi iOS app (SwiftUI, iOS 26+)
│   ├── Oppi/               Main app target
│   │   ├── App/            App entry point
│   │   ├── Core/           Networking, services, models, formatting
│   │   └── Features/       Chat, workspaces, permissions, skills, settings
│   ├── OppiTests/          Swift Testing unit tests
│   └── scripts/            Build, deploy, and debug scripts
└── skills/                 Agent skills for oppi development
```

## Development

### Server

```bash
cd server
npm install
npm test          # vitest test suite
npm run build     # TypeScript compile
npm run check     # typecheck + lint + format check
npm start         # Start server (from compiled dist/)
npm run dev       # Start with tsx watch (auto-reload)
```

### iOS

Requires **Xcode 26.2+** with the iOS 26 SDK.

```bash
cd ios
# Install XcodeGen if needed: brew install xcodegen
xcodegen generate
open Oppi.xcodeproj
# Or build from command line:
xcodebuild build -scheme Oppi -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
xcodebuild test -scheme Oppi -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

> **Fork setup:** Update `bundleIdPrefix` and `DEVELOPMENT_TEAM` in `ios/project.yml` to your own Apple Developer values.

## Troubleshooting

**"pi not found"** — Install globally: `npm install -g @mariozechner/pi-coding-agent`. Or set `OPPI_PI_BIN=/path/to/pi`.

**"auth.json not found"** — Run `pi` then `/login` to authenticate with your LLM provider.

**Can't connect from phone** — Verify both devices are on the same network. Check `curl http://<your-mac>:7749/health`. Check firewall allows port 7749.

**Container startup slow** — First container launch builds the image (~60s). Subsequent launches reuse it.

**Everything needs approval** — Expected! The server defaults to asking. As you approve commands, learned rules accumulate and common operations auto-allow.

## Current Limitations

- **Single user** — one owner per server instance
- **macOS only** — server requires macOS for Apple container support (host mode works conceptually on Linux but is untested)

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions and guidelines.

## License

[MIT](LICENSE)
