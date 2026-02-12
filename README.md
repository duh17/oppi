# Pi iOS - Mobile Client for Pi Coding Agent

Control your sandboxed [pi](https://github.com/badlogic/pi-mono) agents from your iPhone over Tailscale.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  iPhone (on tailnet)                                             │
│                                                                  │
│  Pi App                                                          │
│  • Scan QR to connect                                            │
│  • Chat with pi                                                  │
│  • Voice dictation                                               │
│  • View past sessions                                            │
└──────────────────────────────────┬──────────────────────────────┘
                                   │
                    Tailscale (WireGuard encrypted)
                                   │
┌──────────────────────────────────┴──────────────────────────────┐
│  mac-studio.tailnet:7749                                         │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  pi-remote                                                  │ │
│  │                                                             │ │
│  │  ┌─────────────────────┐    ┌─────────────────────┐        │ │
│  │  │  Chen's Sandbox     │    │  Wife's Sandbox     │        │ │
│  │  │  ~/.../chen/        │    │  ~/.../wife/        │        │ │
│  │  │                     │    │                     │        │ │
│  │  │  [container]        │    │  [container]        │        │ │
│  │  │  └─ pi --rpc        │    │  └─ pi --rpc        │        │ │
│  │  │                     │    │                     │        │ │
│  │  │  workspace/         │    │  workspace/         │        │ │
│  │  │  sessions/          │    │  sessions/          │        │ │
│  │  └─────────────────────┘    └─────────────────────┘        │ │
│  │                                                             │ │
│  │  Users can't see each other's files or sessions            │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Start Server

```bash
cd pi-remote
npm install
npx tsx src/index.ts serve
```

### 2. Create Pairing QR

```bash
# Show pairing QR in terminal
npx tsx src/index.ts pair "Chen"

# Save pairing QR as image
npx tsx src/index.ts pair "Chen" --save owner-pair.png
```

### 3. Connect from iPhone

1. Open Oppi on iPhone
2. Scan pairing QR
3. Done — this phone is now paired to this server owner identity

## Documentation Map (Source of Truth)

- `README.md` (this file): current setup and implemented API/runtime behavior.
- `IMPLEMENTATION.md`: execution checklist, phase status, acceptance criteria.
- `WORKSPACE-CONTAINERS.md`: target `workspace = container` architecture and migration plan.
- `DESIGN.md`: high-level product design (contains some historical sections).
- `WORKSPACES.md`: concise workspace contract summary + links.

## iOS Build + Deploy from mac-studio (SSH/local network)

One-time prerequisites on mac-studio:

1. Pair iPhone with Xcode once (trust computer, enable Developer Mode)
2. Enable wireless debugging / local-network pairing
3. Ensure signing works locally in Xcode at least once

Build + install directly on mac-studio:

```bash
./ios/scripts/build-install.sh --device <iphone-udid> --launch
```

Trigger the same flow remotely over SSH:

```bash
./scripts/ios-deploy-ssh.sh --host mac-studio -- --device <iphone-udid> --launch
```

Auto-redeploy on file changes (watch mode):

```bash
./scripts/ios-deploy-ssh.sh --watch -- --skip-generate --launch
```

If SSH signing fails (`errSecInternalComponent`), unlock keychain in the remote build:

```bash
ssh mac-studio '
  export PI_KEYCHAIN_PASSWORD="<login-password>"
  cd /Users/chenda/workspace/pios
  ./ios/scripts/build-install.sh --unlock-keychain --device <iphone-udid> --launch
'
```

### Debug logging for deploy + runtime

Persist build/install/launch logs:

```bash
./ios/scripts/build-install.sh --logs-dir ~/Library/Logs/PiRemote --launch
./scripts/ios-deploy-ssh.sh --local-log-dir ~/Library/Logs/PiRemote -- --logs-dir ~/Library/Logs/PiRemote --launch
```

Collect device OSLog entries for PiRemote:

```bash
./ios/scripts/collect-device-logs.sh --device <iphone-udid> --last 30m --include-debug
```

Capture a focused per-session bundle (minimal noise, app logs only):

```bash
# Tip: copy session ID from chat title, then run
./scripts/capture-session.sh --session <session-id> --last 20m

# Optional: include perf categories when debugging render/reducer behavior
./scripts/capture-session.sh --session <session-id> --include-perf --include-debug
```

### UI hang regression harness (XCUITest + watchdog diagnostics)

Run the dedicated reliability suite (simulator, CI-friendly):

```bash
./ios/scripts/test-ui-reliability.sh
```

Fast local rerun (skip XcodeGen when project files are unchanged):

```bash
./ios/scripts/test-ui-reliability.sh --skip-generate
```

Simulator-only gate:

```bash
./ios/scripts/test-ui-reliability.sh --destination "platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro"
```

This suite launches a debug-only fixture mode (`--ui-hang-harness`) with a heavy chat timeline + synthetic stream churn and asserts accessibility diagnostics. The harness is disabled on physical devices even if launch args/env vars are present:
- `diag.heartbeat` (main-thread watchdog heartbeat)
- `diag.stallCount` (watchdog stall counter)
- `diag.itemCount` (rendered timeline row count)

If `pi-remote pair` should use LAN instead of Tailscale:

```bash
cd pi-remote
npx tsx src/index.ts pair "Chen" --host mac-studio.local
```

## Onboarding Flow

### One-Time Pairing

```bash
# 1. Start pi-remote
pi-remote serve

# 2. Generate pairing QR for owner identity
pi-remote pair "Chen" --save pair.png

# 3. Scan in Oppi on iPhone
```

### Paired Phone

1. Open Oppi
2. Scan pairing QR
3. Start chatting

## CLI Reference

```bash
pi-remote serve                    # Start the server
pi-remote pair [name]              # Create pairing QR for owner identity
pi-remote pair [name] --host ...   # Force LAN/tailnet host in QR payload
pi-remote status                   # Show server status
pi-remote config show              # Show effective config JSON
pi-remote config validate          # Validate config schema
```

## Performance & Reliability Harnesses

```bash
cd pi-remote

# Existing full-stack E2E (real server + container + pi + LLM)
npx tsx test-e2e.ts

# New lightweight load harness
# - HTTP /health throughput + latency
# - WS connect + get_state RTT under forced-drop churn
npx tsx test-load-ws.ts --host 127.0.0.1 --port 7749

# WS churn mode (requires auth + workspace + session)
LOAD_TOKEN=<token> LOAD_WORKSPACE_ID=<workspaceId> LOAD_SESSION_ID=<sessionId> npx tsx test-load-ws.ts
```

## API

### REST

```
GET    /health                     # Health check (no auth)
GET    /me                         # Current owner identity info
GET    /security/profile           # Server security posture + trust metadata

# Workspaces
GET    /workspaces                 # List workspaces
POST   /workspaces                 # Create workspace
GET    /workspaces/:id             # Get workspace
PUT    /workspaces/:id             # Update workspace
DELETE /workspaces/:id             # Delete workspace
GET    /workspaces/:id/graph       # Fork/session lineage graph

# Workspace sessions (authoritative)
GET    /workspaces/:wid/sessions                          # List sessions
POST   /workspaces/:wid/sessions                          # Create session
GET    /workspaces/:wid/sessions/:sid                     # Get session + trace
POST   /workspaces/:wid/sessions/:sid/stop               # Stop session process
POST   /workspaces/:wid/sessions/:sid/resume             # Resume stopped session
GET    /workspaces/:wid/sessions/:sid/events?since=<seq> # Durable event catch-up replay
GET    /workspaces/:wid/sessions/:sid/files?path=<path>  # Read workspace file
GET    /workspaces/:wid/sessions/:sid/tool-output/:tid   # Full tool output blob
GET    /workspaces/:wid/sessions/:sid/overall-diff?path=<path>
DELETE /workspaces/:wid/sessions/:sid                    # Stop + delete metadata
POST   /workspaces/:wid/sessions/:sid/client-logs        # Upload client diagnostics

# Built-in skills (host-discovered)
GET    /skills
GET    /skills/:name
GET    /skills/:name/file?path=<relativePath>
POST   /skills/rescan

# User skills
GET    /me/skills
GET    /me/skills/:name
GET    /me/skills/:name/files?path=<relativePath>
POST   /me/skills                  # body: { name, sessionId, path? }
DELETE /me/skills/:name
```

### WebSocket

```
Session stream:           ws://host:7749/workspaces/:wid/sessions/:sid/stream
User stream mux:          ws://host:7749/stream
Authorization: Bearer <token>

# Client → Server
{ "type": "prompt", "message": "Hello" }
{ "type": "prompt", "message": "What's this?", "images": [{ "data": "...", "mimeType": "image/jpeg" }] }
{ "type": "steer", "message": "continue" }
{ "type": "follow_up", "message": "next" }
{ "type": "abort" }
{ "type": "stop" }
{ "type": "get_state" }
{ "type": "permission_response", "id": "req-1", "action": "allow" }

# Server → Client
{ "type": "connected", "session": {...} }
{ "type": "state", "session": {...} }
{ "type": "agent_start" }
{ "type": "text_delta", "delta": "Hello!" }
{ "type": "thinking_delta", "delta": "..." }
{ "type": "tool_start", "tool": "bash", "args": {...}, "toolCallId": "call_1" }
{ "type": "tool_output", "output": "...", "toolCallId": "call_1" }
{ "type": "tool_end", "tool": "bash", "toolCallId": "call_1" }
{ "type": "permission_request", "id": "req-1", "sessionId": "s1", "tool": "bash", ... }
{ "type": "permission_expired", "id": "req-1", "reason": "timeout" }
{ "type": "permission_cancelled", "id": "req-1" }
{ "type": "agent_end" }
{ "type": "session_ended", "reason": "completed" }
{ "type": "error", "error": "..." }
```

## Security

### Transport + bootstrap contract

- Server publishes runtime posture at `GET /security/profile` (profile, transport toggles, identity fingerprint).
- Pairing onboarding uses signed `v2` envelopes (Ed25519, expiry, nonce, key id).
- iOS enforces server-authored transport rules:
  - tailnet/local HTTP/WS allowed only when profile permits
  - non-tailnet insecure transport is blocked when `requireTlsOutsideTailnet=true` (default)
  - pinned identity mismatch is hard-blocked when `requirePinnedServerIdentity=true` (default)
- On startup, server logs explicit warnings for insecure posture (wildcard bind, legacy profile, disabled pinning, plaintext outside tailnet, long pairing TTL).

### At-rest protection assumptions

- iOS credentials are stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Server metadata files (`config.json`, `users.json`, session/workspace records) are written with owner-only permissions (`0600` files, `0700` directories).
- Server identity private key is stored at `identity.privateKeyPath` with restrictive file permissions.
- Operator hardening assumptions: FileVault enabled on macOS host and device passcode/biometric lock enabled on iOS.

### Threat model + residual risk

- P0 model covers pairing payload tampering/replay, unsigned-bootstrap downgrade, fake-server bootstrap, and post-pairing transport downgrade.
- Residual risks remain for host compromise (attacker can read local data/keys), bearer-token leakage until rotation, and network exposure from misconfigured tailnet/LAN ACLs.

See `pi-remote/docs/security-config-v2.md` and `pi-remote/docs/security-release-gate-v0.md` for full matrix and release-gate evidence.

## Project Structure

```
pios/
├── pi-remote/               # Server (TypeScript)
│   ├── src/
│   │   ├── index.ts         # CLI
│   │   ├── server.ts        # HTTP shell + WS upgrades + orchestrator
│   │   ├── routes.ts        # REST route handlers
│   │   ├── stream.ts        # /stream mux (ring replay + subscriptions)
│   │   ├── sessions.ts      # Pi process manager + RPC translation
│   │   ├── workspace-runtime.ts # Workspace lifecycle + concurrency limits
│   │   ├── gate.ts          # Permission gate TCP server
│   │   ├── policy.ts        # Layered policy engine
│   │   ├── sandbox.ts       # Apple container orchestration
│   │   ├── storage.ts       # Persistent state
│   │   ├── skills.ts        # Skill registry/discovery
│   │   └── types.ts         # Shared protocol types
│   ├── extensions/
│   │   └── permission-gate/
│   └── package.json
│
├── ios/                     # iOS app (SwiftUI)
│   ├── PiRemote/
│   └── PiRemoteTests/
│
├── WORKSPACE-CONTAINERS.md  # Workspace=container architecture target
└── IMPLEMENTATION.md        # Execution checklist
```

## Data Storage

```
~/.config/pi-remote/                 # Server data
├── config.json                      # Server config
├── users.json                       # Owner identity + device tokens (single-user mode)
├── sessions/
│   └── <sessionId>.json             # Flat owner layout (current)
└── workspaces/
    └── <workspaceId>.json           # Flat owner layout (current)

~/.pi-remote/sandboxes/              # Workspace-scoped sandbox runtime
└── <ownerId>/
    └── <workspaceId>/
        ├── workspace/               # Shared /work for all sessions in this workspace
        └── sessions/
            └── <sessionId>/
                ├── agent/           # Per-session Pi home (auth/models/extensions/sessions)
                └── system-prompt.md # Generated prompt for that session

~/.pi-remote/memory/                 # Optional memory namespaces
└── <namespace>/
```

On startup, storage migrates legacy owner-scoped records (`sessions/<ownerId>/...`, `workspaces/<ownerId>/...`) into flat owner layout and removes migrated legacy files.

Isolation model (current):
- Single-owner identity per server instance
- Per-workspace sandbox container + shared workspace filesystem
- Per-session Pi home/state under workspace `sessions/<sessionId>/`
- Permission-gate decisions enforced per tool call

## Status

### ✅ Implemented

- [x] pi-remote server + RPC bridge
- [x] Single-owner pairing auth flow
- [x] Session lifecycle + persistence
- [x] Permission gate (extension + TCP gate + policy engine)
- [x] Workspace-scoped runtime + multi-session concurrency in one workspace
- [x] Sequenced durable event replay (`seq` + catch-up endpoint + iOS dedupe)
- [x] User skill CRUD API (`/me/skills`)
- [x] iOS app core flows (onboarding, sessions, chat, workspace management)
- [x] Tool event correlation (`toolCallId`) end-to-end

### 🚧 In Progress

- [ ] Session file API directory listing + full iOS file browser/preview flow
- [ ] Fork workflow (API + UI)
- [ ] User-skill session loading + promotion safety gate
- [ ] iOS skills UI + skill creation workflow
- [ ] Skill import + security scanning pipeline
- [ ] Push notifications / background approval UX hardening

See `WORKSPACE-CONTAINERS.md` and `IMPLEMENTATION.md` for current roadmap.
