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
GET  /health              # Health check (no auth)
GET  /me                  # Current user info
GET  /sessions            # List user's sessions
POST /sessions            # Create new session
GET  /sessions/:id        # Get session + messages
DELETE /sessions/:id      # Stop and delete session
```

### WebSocket

```
Connect: ws://host:7749/sessions/:id/stream
Authorization: Bearer <token>

# Client → Server
{ "type": "prompt", "message": "Hello" }
{ "type": "prompt", "message": "What's this?", "images": [{ "data": "...", "mimeType": "image/jpeg" }] }
{ "type": "abort" }
{ "type": "get_state" }

# Server → Client
{ "type": "connected", "session": {...} }
{ "type": "agent_start" }
{ "type": "text_delta", "delta": "Hello!" }
{ "type": "tool_start", "tool": "bash", "args": {...} }
{ "type": "tool_output", "output": "..." }
{ "type": "tool_end", "tool": "bash" }
{ "type": "agent_end" }
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
│   │   ├── server.ts      # HTTP + WebSocket
│   │   ├── sessions.ts    # Pi process manager
│   │   ├── storage.ts     # Persistent state
│   │   └── types.ts       # Type definitions
│   └── package.json
│
├── ios/                    # iOS App (TODO)
│   └── PiMobile/
│
└── README.md
```

## Data Storage

```
~/.config/pi-remote/           # Server data
├── config.json                # Server config
├── users.json                 # User accounts
└── sessions/
    ├── chen/                  # Chen's session metadata
    │   └── abc123.json
    └── wife/                  # Wife's session metadata
        └── def456.json

~/.pi-remote-sandboxes/        # User sandboxes (isolated)
├── <chen-id>/
│   ├── agent/                 # Pi config (auth, models)
│   │   ├── auth.json
│   │   └── models.json
│   ├── workspace/             # Working directory
│   └── sessions/              # Pi session files
│
└── <wife-id>/                 # Wife's completely separate sandbox
    ├── agent/
    ├── workspace/
    └── sessions/
```

Each user gets their own isolated sandbox with:
- Separate auth tokens (can use different API keys per user)
- Separate workspace (files don't mix)
- Separate session history

## Status

### ✅ Done

- [x] pi-remote server
- [x] Multi-user auth (tokens)
- [x] Session management
- [x] Pi sandbox integration
- [x] REST API
- [x] WebSocket streaming
- [x] QR code invites
- [x] Persistent storage

### 🚧 TODO

- [ ] iOS app
- [ ] Voice dictation
- [ ] Session history UI
- [ ] Push notifications
- [ ] Launchd service installer
