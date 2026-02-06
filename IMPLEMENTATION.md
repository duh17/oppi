# Pi Remote — Implementation Plan

## Honest Assessment of Current State

### What exists (and works)
- `server.ts` — HTTP + WebSocket server, manual routing, bearer auth ✅
- `sessions.ts` — Session lifecycle, pi process spawning in RPC mode, event streaming ✅
- `storage.ts` — JSON file storage, user management, sandbox directories ✅
- `types.ts` — Clean type definitions ✅
- `index.ts` — CLI entrypoint with QR invite codes ✅

### What's wrong with the existing code
1. **Readline race** (`sessions.ts:114-130`): `waitForReady()` creates a second
   readline on `proc.stdout` that competes with the main one. First message gets
   misrouted to `unknown/<sessionId>` key.
2. **Sync FS everywhere** (`storage.ts`): `readFileSync`/`writeFileSync` in hot
   paths. Fine for <5 users but will stall event loop under load.
3. **No guarded session concept**: Pi spawns and immediately accepts prompts with
   no proof that the permission extension loaded.
4. **CORS `*`**: Open to any origin. Fine for native clients, risky if browser
   exposure happens.

### What the design doc asks for (DESIGN.md v2)
- Unix socket gate (per-session)
- Layered policy engine with bash parsing
- Guarded session handshake + heartbeat
- Scoped "Always Allow" learning
- Three token types
- Offline modes
- Permission storm handling
- Durable pending decisions
- Audit logging

### The problem: scope creep
DESIGN.md v2 is a production-grade system. We're a single developer building
a personal tool. We need to be ruthless about scope.

---

## What Actually Matters

The entire value of Pi Remote is ONE flow:

```
Pi wants to run `git push` →
Extension intercepts it →
Server evaluates policy →
Policy says "ask" →
Phone gets a card →
User taps "Allow" →
Extension unblocks →
Pi runs `git push`
```

**Everything else is supporting infrastructure.** If this flow works end-to-end,
we have a product. If it doesn't, nothing else matters.

---

## v1: Permission Flow (build this first)

### Scope
- Permission gate extension (pi side)
- Unix socket gate server (server side)
- Simple policy engine (glob matching, hard-coded presets)
- WebSocket permission forwarding to phone
- Guarded session handshake
- Test with CLI client before building iOS app

### Explicitly out of scope for v1
- ❌ Bash command AST parsing (glob match raw commands — imperfect but testable)
- ❌ YAML policy files (presets in TypeScript, editable later)
- ❌ "Always Allow" / learned rules (just allow/deny/ask per request)
- ❌ Offline modes beyond strict timeout-deny
- ❌ Durable pending decisions (in-memory Map, fine for single-process)
- ❌ Token separation (existing bearer tokens work)
- ❌ Audit logging (console.log for now)
- ❌ Workspace mounting (use cwd, add later)
- ❌ Permission storm coalescing (handle when it's a real problem)
- ❌ iOS app (use test CLI client)

### Files to create

```
pi-remote/
├── src/
│   ├── index.ts          # (existing) CLI entrypoint
│   ├── server.ts         # (existing, modify) Add WS permission messages
│   ├── sessions.ts       # (existing, modify) Fix readline race, spawn gate socket
│   ├── storage.ts        # (existing, minor) Add policy preset field to User
│   ├── types.ts          # (existing, extend) Add permission types
│   ├── policy.ts         # NEW: policy engine
│   └── gate.ts           # NEW: Unix socket gate server
└── extensions/
    └── permission-gate/
        ├── index.ts      # Pi extension
        └── package.json  # Extension manifest
```

### Implementation order

#### Step 1: Fix existing bugs (30 min)
- Fix readline race in `sessions.ts` (single readline consumer)
- Keep everything else as-is

#### Step 2: Policy engine — `src/policy.ts` (1-2 hours)
- `PolicyEngine` class
- `evaluate(toolCall)` → `{ action, reason, risk }`
- Glob matching against tool name + command/path
- Three presets: admin, standard, restricted
- Unit testable (no I/O, no sockets)

```typescript
// Minimal v1 API
class PolicyEngine {
  constructor(preset: "admin" | "standard" | "restricted")
  evaluate(tool: string, input: Record<string, unknown>): PolicyDecision
}

interface PolicyDecision {
  action: "allow" | "ask" | "deny";
  reason: string;
  risk: "low" | "medium" | "high" | "critical";
}
```

#### Step 3: Gate socket server — `src/gate.ts` (2-3 hours)
- `GateServer` class
- Creates Unix socket per session at `/tmp/pi-remote-gate/<sessionId>.sock`
- Handles ndjson protocol (guard_ready, gate_check, heartbeat)
- Uses PolicyEngine for evaluation
- When policy says "ask" → emits event for server to forward to WebSocket
- Manages pending decisions in-memory Map with timeout cleanup
- Cleans up socket on session end

```typescript
class GateServer extends EventEmitter {
  constructor(policy: PolicyEngine)
  createSessionSocket(sessionId: string, userId: string): string // returns socket path
  destroySessionSocket(sessionId: string): void
  resolveDecision(requestId: string, action: "allow" | "deny"): void

  // Events:
  // "approval_needed" → { requestId, sessionId, userId, tool, input, risk, timeout }
  // "guard_ready" → { sessionId }
  // "guard_lost" → { sessionId }
}
```

#### Step 4: Permission gate extension — `extensions/permission-gate/index.ts` (1-2 hours)
- Connects to Unix socket via `net.createConnection()`
- `before_agent_start` → sends `guard_ready`
- `tool_call` → sends `gate_check`, blocks on response
- Heartbeat timer (15s)
- Handles socket errors gracefully (→ block all on disconnect)

Test: run pi with extension locally, verify tool calls go through socket.

#### Step 5: Wire into server (2-3 hours)
- `sessions.ts`: On spawn, create gate socket, pass path via env, install extension
- `server.ts`: Forward `approval_needed` events to phone's WebSocket
- `server.ts`: Handle `permission_response` from phone WebSocket, call `gate.resolveDecision()`
- `types.ts`: Add `permission_request` and `permission_response` to WS message types

#### Step 6: Test client (1 hour)
- Simple CLI script that connects via WebSocket
- Prints permission requests
- Auto-approves with keyboard input (y/n/a)
- Verifies full flow end-to-end

### Session state machine (v1, simplified)

```
STARTING → SPAWNED → GUARDED → READY ↔ BUSY → STOPPED
              ↓         ↓                         ↑
           (no guard_ready within 10s)            │
              ↓         ↓                         │
           FAILED ←── FAIL_SAFE ──────────────────┘
```

- `SPAWNED`: Pi process running, waiting for extension handshake
- `GUARDED`: Extension confirmed loaded, accepting tool calls
- `READY/BUSY`: Normal operation
- `FAIL_SAFE`: Heartbeat lost, all tool calls denied until extension reconnects

### How extension gets installed

Server copies the extension directory into the user's sandbox on first session:

```typescript
// In sessions.ts
const extensionDir = path.join(sandboxDir, "agent", "extensions", "permission-gate");
await fs.cp(BUNDLED_EXTENSION_PATH, extensionDir, { recursive: true });
```

Pi discovers extensions from the agent directory. The extension reads
`PI_REMOTE_GATE_SOCK` from env to find its socket.

---

## v2: Hardening (after v1 works)

Add after the permission flow is proven end-to-end:

1. **Bash command parsing** — Tokenize into (executable, args) before matching
2. **YAML policy files** — Per-user editable policy with `learnedRules` section
3. **"Always Allow" with scope** — once / session / workspace / persistent
4. **Offline modes** — `strict` / `degraded_readonly` / `grace_window`
5. **Audit logging** — JSONL files per user per day
6. **Session gate tokens** — Separate from user API tokens, bound to session
7. **Async FS** — Replace sync reads/writes in hot paths

## v3: iOS App

Build after server stack is solid and tested with CLI client:

1. **Onboarding** — QR scan, API token exchange
2. **Session list** — Create/stop/resume sessions
3. **Chat** — Text + image input, streaming response display
4. **Permission cards** — The money feature. Rich cards with risk tiers + scope selection.
5. **Live activity feed** — What agent is doing right now
6. **Push notifications** — APNs for permission requests when app is backgrounded

## v4: Polish

1. Workspace mounting + management
2. Permission storm coalescing
3. Policy editor in app
4. Voice input
5. Durable pending decisions (for multi-device)
6. Tamper-evident audit logs

---

## Server Stack Decision: Keep TypeScript

**Don't rewrite.** The current TypeScript + Node.js stack is the right choice:

1. **Pi is TypeScript** — Extensions are TypeScript. Policy engine, protocol
   types, gate server all share types with the extension. One language.
2. **Node excels at this** — WebSocket server + Unix socket server + HTTP +
   async I/O + process management. This is exactly what Node is for.
3. **The code is clean** — server.ts, sessions.ts, storage.ts are well-structured.
   Fix bugs, don't rewrite.
4. **No framework needed** — We're not building a web app. Raw `http.createServer`
   + `ws` + `net.createServer` is exactly right. Express/Fastify add nothing here.

### Dependencies (v1, keep minimal)
```
ws           — WebSocket server (already have)
nanoid       — ID generation (already have)
chalk        — CLI colors (already have)
minimatch    — Glob matching for policy rules (add)
yaml         — YAML policy file parsing (defer to v2)
```

### Testing
```
vitest       — Unit tests for policy engine, gate protocol
```

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Unix socket permissions wrong | Medium | Test immediately, 0600 perms, clean up on exit |
| Extension not loading in pi | Medium | Test in isolation first, check pi extension docs |
| Extension blocking pi's event loop | Low | `tool_call` handler is async, fetch/socket reads are non-blocking |
| Phone never connects to approve | High | Strict timeout + clear error to agent. v2 adds offline modes. |
| Policy globs too permissive | Medium | Start restrictive (admin preset still asks for unknowns) |
| Session socket leak on crash | Medium | Cleanup script + socket path includes PID for uniqueness |

---

## Definition of Done (v1)

✅ Pi spawns with permission-gate extension loaded
✅ Extension handshakes with server (guard_ready → guard_ack)
✅ Tool calls intercepted and evaluated against policy
✅ Auto-allow rules pass through without delay
✅ Hard-deny rules block immediately
✅ "Ask" rules create pending decision, push to WebSocket
✅ CLI test client receives permission request, can approve/deny
✅ Approved tool call unblocks extension, pi executes tool
✅ Denied tool call returns `{ block: true }` to pi
✅ Timeout after 2 minutes returns deny
✅ Extension heartbeat works, server detects lost extension
✅ Socket cleanup on session end
