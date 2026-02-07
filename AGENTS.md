# Pi Remote — Agent Instructions

## Overview

Pi Remote is a mobile-first agent supervision platform. An iPhone app controls pi coding agents running on a home server (mac-studio), with permission gating from the phone.

Two modules in this repo:

| Module | Language | Location | Agent config |
|--------|----------|----------|-------------|
| `pi-remote` | TypeScript (Node.js) | `pi-remote/` | This file |
| `ios` | Swift 6 (SwiftUI, iOS 26) | `ios/` | `ios/AGENTS.md` |

Read `DESIGN.md` for architecture, `IMPLEMENTATION.md` for current state and phased plan.

## First Message

If no concrete task given, read `README.md`, then ask which module to work on. Based on the answer:

**pi-remote:** Read these in parallel:
- `pi-remote/src/types.ts` — shared protocol types
- `pi-remote/src/server.ts` — HTTP + WebSocket server
- `pi-remote/src/sessions.ts` — pi process lifecycle (RPC, container spawn)
- `pi-remote/src/gate.ts` — permission gate (TCP, per-session ports)
- `pi-remote/src/policy.ts` — layered policy engine
- `pi-remote/src/sandbox.ts` — Apple container management
- `pi-remote/src/push.ts` — APNs push notifications
- `pi-remote/src/storage.ts` — JSON file persistence
- `pi-remote/src/trace.ts` — pi session JSONL reader
- `pi-remote/extensions/permission-gate/index.ts` — pi extension

**ios:** Read `ios/AGENTS.md` for full architecture and patterns.

## pi-remote Architecture

```
Phone (WebSocket) → server.ts → sessions.ts → pi (RPC over stdin/stdout)
                                    ↓
                               sandbox.ts (Apple containers)
                                    ↓
              gate.ts ← TCP ← permission-gate extension (inside container)
                ↓
           policy.ts (layered rules → allow/ask/deny)
                ↓
           push.ts (APNs → phone notification)
```

Key patterns:
- No frameworks. Raw `http.createServer` + `ws` + `net.createServer`.
- JSON-lines protocol between server and pi (RPC mode)
- TCP gate per session (not Unix sockets — containers need host-gateway access)
- Layered policy evaluation: hard denies → workspace bounds → user rules → learned rules → default
- Fail-closed: unguarded sessions block all tool calls

## pi-remote Source Files

```
pi-remote/
├── src/
│   ├── index.ts       # CLI entrypoint (serve, invite, users, status)
│   ├── server.ts      # HTTP + WebSocket server
│   ├── sessions.ts    # Pi process lifecycle (RPC, container spawn)
│   ├── gate.ts        # Permission gate (TCP, per-session)
│   ├── policy.ts      # Layered policy engine
│   ├── sandbox.ts     # Apple container management
│   ├── push.ts        # APNs push notifications
│   ├── storage.ts     # JSON file persistence
│   ├── trace.ts       # Pi session JSONL reader
│   └── types.ts       # Shared type definitions
├── extensions/
│   └── permission-gate/  # Pi extension (runs inside container)
├── sandbox/
│   └── Containerfile  # Container image definition
├── test-*.ts          # Test scripts
├── package.json
└── tsconfig.json
```

## Code Quality (TypeScript)

- No `any` types unless absolutely necessary
- Check `node_modules` for external API type definitions instead of guessing
- No inline imports — no `await import("./foo.js")`, no `import("pkg").Type` in type positions. Always use standard top-level imports.
- Never remove or downgrade code to fix type errors; upgrade the dependency instead
- Always ask before removing functionality or code that appears intentional

## Commands (pi-remote)

```bash
cd pi-remote

# Type check
npx tsc --noEmit

# Build
npm run build

# Run server (dev)
npx tsx src/index.ts serve

# Run specific test file
npx tsx test-policy.ts
npx tsx test-gate.ts
npx tsx test-gate-client.ts
npx tsx test-e2e.ts
```

## iOS Quick Reference

Read `ios/AGENTS.md` for full architecture, patterns, and code conventions.

### Build + Test

```bash
cd ios
xcodegen generate                # required after adding/removing files
xcodebuild -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build
xcodebuild -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
```

### Deploy to Phone

```bash
# Build + install + launch on connected iPhone
ios/scripts/build-install.sh --launch

# Skip xcodegen (faster, use when no file additions)
ios/scripts/build-install.sh --launch --skip-generate
```

### Device Logs

```bash
ios/scripts/collect-device-logs.sh --last 5m --include-debug --no-sudo
```

## Repeatable iOS Local Flow (tmux + deploy)

From repo root:

```bash
./scripts/ios-dev-up.sh -- --device <iphone-udid>
```

Default behavior:
- Starts/restarts `pi-remote` in tmux window `pi-remote-server`
- Waits for server port `7749`
- Runs `ios/scripts/build-install.sh` with `--launch` unless you pass `--no-launch`

Useful variants:

```bash
# Keep existing server window, deploy only
./scripts/ios-dev-up.sh --no-restart-server -- --device <iphone-udid>

# Build/install without launching app
./scripts/ios-dev-up.sh --no-launch -- --device <iphone-udid>

# Custom tmux session/window
./scripts/ios-dev-up.sh --session main --window pi-remote-server -- --device <iphone-udid>
```

## Wire Protocol

Client-server messages defined in `pi-remote/src/types.ts`. The iOS models in `ios/PiRemote/Core/Models/ServerMessage.swift` and `ClientMessage.swift` must stay in sync.

When changing the protocol:
1. Update `pi-remote/src/types.ts`
2. Update `ios/PiRemote/Core/Models/ServerMessage.swift` (manual `Decodable`)
3. Update `ios/PiRemote/Core/Models/ClientMessage.swift`
4. Update `ios/PiRemoteTests/ServerMessageTests.swift` and `ClientMessageTests.swift`

## Data Directories (Runtime)

```
~/.config/pi-remote/       # Server config + state
├── config.json
├── users.json
└── sessions/<userId>/*.json

~/.pi-remote-sandboxes/<userId>/  # Per-user sandboxes
├── agent/                 # Pi config (auth, models, extensions)
├── workspace/             # Working directory
└── sessions/              # Pi session JSONL files
```

## Debugging Pi Remote Sessions

Inspect running sandboxed sessions from the host. Useful when a user reports issues from the iOS app.

### Paths

| What | Path |
|------|------|
| Server config | `~/.config/pi-remote/config.json` |
| User list | `~/.config/pi-remote/users.json` |
| Session state | `~/.config/pi-remote/sessions/<userId>/<sessionId>.json` |
| JSONL trace | `~/.pi-remote/sandboxes/<userId>/<sessionId>/agent/sessions/<workspace>/` |
| Workspace files | `~/.pi-remote/sandboxes/<userId>/<sessionId>/workspace/` |
| Agent config | `~/.pi-remote/sandboxes/<userId>/<sessionId>/agent/` (auth.json, models.json, extensions/) |

### REST API

```bash
# Health check
curl http://localhost:7749/health

# List sessions (needs user token from users.json)
curl -H "Authorization: Bearer <token>" http://localhost:7749/sessions

# Session detail + trace
curl -H "Authorization: Bearer <token>" http://localhost:7749/sessions/<id>
curl -H "Authorization: Bearer <token>" http://localhost:7749/sessions/<id>/trace
```

### Container + Process

```bash
# Running containers
ps aux | grep "pi-remote-<sessionId>"

# Server logs (tmux window 6 in main session)
tmux capture-pane -t main:6 -p | tail -40

# Read last trace events
tail -5 ~/.pi-remote/sandboxes/<userId>/<sessionId>/agent/sessions/*/*.jsonl
```

### Common Issues

**Expired OAuth token** — Anthropic tokens are short-lived (~8h). Sandbox auth.json is only synced at session creation.
```bash
# Check expiry
python3 -c "import json,datetime; d=json.load(open('$HOME/.pi-remote/sandboxes/<userId>/<sessionId>/agent/auth.json')); print(datetime.datetime.fromtimestamp(d['anthropic']['expires']/1000))"

# Fix: re-sync from host
cp ~/.pi/agent/auth.json ~/.pi-remote/sandboxes/<userId>/<sessionId>/agent/auth.json
```

**Broken extensions** — Check symlinks and extension config:
```bash
ls -la ~/.pi-remote/sandboxes/<userId>/<sessionId>/agent/extensions/
```

**Connect/disconnect cycling in server logs** — Usually the iOS app reconnecting on foreground. Check for rapid loops which may indicate auth or WebSocket handshake failures.

## Commits

- Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`
- Keep subject line under 72 chars
- Prefix with module when relevant: `feat(server):`, `fix(ios):`, `chore(gate):`
- Include `fixes #<number>` or `closes #<number>` when applicable

## Git Rules

- Never `git add -A` or `git add .` — always add specific files
- Never `git reset --hard`, `git checkout .`, `git clean -fd`, `git stash`
- Never `git commit --no-verify`
- Never commit unless asked
- Track which files you created/modified/deleted during the session

## Style

- Keep answers short and concise
- No emojis in commits, issues, PR comments, or code
- No fluff or cheerful filler text
- Technical prose only, be kind but direct
