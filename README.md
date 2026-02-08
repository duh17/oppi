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

### 2. Create Invite

```bash
# Show QR code in terminal
npx tsx src/index.ts invite "Wife"

# Save QR as image to send
npx tsx src/index.ts invite "Wife" --save wife-invite.png
```

### 3. Connect from iPhone

1. Wife opens Pi app
2. Scans QR code
3. Done! She can start chatting

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

If `pi-remote invite` should use LAN instead of Tailscale:

```bash
cd pi-remote
npx tsx src/index.ts invite "Chen" --host mac-studio.local
```

## Onboarding Flow

### For You (One-Time Setup)

```bash
# 1. Add wife to your Tailscale network
#    (via Tailscale admin console)

# 2. Set up ACL so she can only access mac-studio
#    (via Tailscale ACL config)

# 3. Start pi-remote
pi-remote serve

# 4. Create her invite
pi-remote invite "Wife" --save invite.png

# 5. Send her the QR code (AirDrop, iMessage, etc.)
```

### For Her

1. Install Tailscale on iPhone (you help once)
2. Install Pi app
3. Scan the QR code you sent
4. Start chatting!

## CLI Reference

```bash
pi-remote serve                    # Start the server
pi-remote invite <name>            # Create invite QR
pi-remote invite <name> --host ... # Force LAN/tailnet host in QR payload
pi-remote users                    # List users
pi-remote users remove <n>         # Remove a user
pi-remote status                   # Show server status
```

## API

### REST

```
GET    /health                     # Health check (no auth)
GET    /me                         # Current user info

# Sessions
GET    /sessions                   # List user's sessions
POST   /sessions                   # Create new session (optional workspaceId)
GET    /sessions/:id               # Get session + messages
POST   /sessions/:id/stop          # Stop session process
GET    /sessions/:id/trace         # Parse pi JSONL trace
DELETE /sessions/:id               # Stop + delete session metadata

# Workspaces
GET    /workspaces                 # List workspaces
POST   /workspaces                 # Create workspace
GET    /workspaces/:id             # Get workspace
PUT    /workspaces/:id             # Update workspace
DELETE /workspaces/:id             # Delete workspace

# Skills
GET    /skills                     # List available skills
POST   /skills/rescan              # Rescan host skill directories
```

### WebSocket

```
Connect: ws://host:7749/sessions/:id/stream
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

- **Network**: Tailscale (WireGuard) encrypts all traffic
- **Auth**: Bearer tokens per user
- **Isolation**: Each user gets their own sandbox environment
  - Separate workspace directory
  - Separate auth credentials
  - Separate session history
  - Can't see other users' files or sessions
- **Sandbox**: All pi sessions run in containers
- **ACL**: Use Tailscale ACLs to limit which devices users can access

## Project Structure

```
pios/
├── pi-remote/              # Server (TypeScript)
│   ├── src/
│   │   ├── index.ts       # CLI
│   │   ├── server.ts      # HTTP + WebSocket + REST routes
│   │   ├── sessions.ts    # Pi process manager + RPC translation
│   │   ├── gate.ts        # Permission gate TCP server
│   │   ├── policy.ts      # Layered policy engine
│   │   ├── sandbox.ts     # Apple container orchestration
│   │   ├── storage.ts     # Persistent state
│   │   ├── skills.ts      # Skill registry/discovery
│   │   └── types.ts       # Shared protocol types
│   ├── extensions/
│   │   └── permission-gate/
│   └── package.json
│
├── ios/                    # iOS app (SwiftUI)
│   ├── PiRemote/
│   └── PiRemoteTests/
│
├── WORKSPACE-CONTAINERS.md # Workspace=container architecture spike
└── IMPLEMENTATION.md       # Execution checklist
```

## Data Storage

```
~/.config/pi-remote/                 # Server data
├── config.json                      # Server config
├── users.json                       # User accounts + device tokens
├── sessions/
│   └── <userId>/
│       └── <sessionId>.json         # Session metadata
└── workspaces/
    └── <userId>/
        └── <workspaceId>.json       # Workspace configs

~/.pi-remote/sandboxes/              # Session sandboxes (current runtime)
└── <userId>/
    └── <sessionId>/
        ├── agent/                   # Pi home: auth/models/extensions/skills/sessions
        ├── workspace/               # Working directory (/work in container)
        └── system-prompt.md         # Generated prompt with workspace context

~/.pi-remote/memory/                 # Optional memory namespaces
└── <namespace>/
```

Isolation model (current):
- Per-user metadata separation in config store
- Per-session sandbox directories (process + filesystem isolation)
- Permission-gate decisions enforced per tool call

## Status

### ✅ Implemented

- [x] pi-remote server + RPC bridge
- [x] Multi-user auth + invite flow
- [x] Session lifecycle + persistence
- [x] Permission gate (extension + TCP gate + policy engine)
- [x] Workspace CRUD + skill discovery APIs
- [x] iOS app core flows (onboarding, sessions, chat, workspace management)
- [x] Tool event correlation (`toolCallId`) end-to-end

### 🚧 In Progress

- [ ] Workspace-scoped runtime (workspace owns container lifecycle)
- [ ] Multi-session concurrency inside one workspace container
- [ ] Fork workflow (API + UI)
- [ ] Skill import + security scanning pipeline
- [ ] Push notifications / background approval UX hardening

See `WORKSPACE-CONTAINERS.md` and `IMPLEMENTATION.md` for current roadmap.
