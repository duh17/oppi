# Oppi — Design Document

> **Note:** This is the original design document from early development (Jan 2026).
> Many details have been implemented differently — see `README.md` for current
> architecture and `server/docs/` for up-to-date design docs. The system is now
> single-user (no multi-user alice/bob), uses "Oppi" naming throughout, and
> the permission gate uses TCP (not UDS). This document is kept as historical
> architecture context.

## Overview

Pi Remote is a mobile-first agent supervision and control platform. It lets users
interact with pi coding agents running on a home server, with fine-grained permission
control and skill curation from their phone.

**Core insight:** The phone is your agent workshop. You build, refine, and curate
what your agent can do. The permission gate keeps it safe while it learns.

**Two pillars:**
1. **Safety** — permission gate, policy engine, container sandbox. Dangerous actions
   require approval from your pocket.
2. **Growth** — skills that evolve through use, built by the agent, curated by you.
   Every session can produce a reusable tool. Over time, your agent gets specialized
   to your exact needs.

> **Implementation note (Feb 2026):** For Apple containers, permission-gate transport
> is TCP (per-session dynamic ports via host-gateway), not Unix sockets. Any UDS
> references below are historical design context; use `IMPLEMENTATION.md` and
> `WORKSPACE-CONTAINERS.md` as current execution truth.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  iPhone                                                          │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Pi Remote iOS App                                          │ │
│  │                                                             │ │
│  │  • Chat interface (text + images + voice)                   │ │
│  │  • Permission approval UI (approve/deny/always-allow)       │ │
│  │  • Live activity feed (what agent is doing)                 │ │
│  │  • Session management                                       │ │
│  │  • Push notifications                                       │ │
│  └──────────────────────┬─────────────────────────────────────┘ │
└─────────────────────────┼───────────────────────────────────────┘
                          │ WebSocket + REST
                          │ (encrypted)
┌─────────────────────────┼───────────────────────────────────────┐
│  your-mac             │                                        │
│                         ▼                                        │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  pi-remote server                                           │ │
│  │                                                             │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐ │ │
│  │  │ Auth Manager  │  │ Policy Engine │  │ Session Manager  │ │ │
│  │  │ 3 token types │  │ layered rules │  │ spawn, proxy     │ │ │
│  │  └──────────────┘  └──────┬───────┘  └────────┬─────────┘ │ │
│  │                           │                    │            │ │
│  │                    ┌──────┴────────────────────┘            │ │
│  │                    │                                        │ │
│  │                    ▼                                        │ │
│  │  ┌─────────────────────────────────────────────────────┐   │ │
│  │  │  Permission Gate (TCP per session, host-gateway)     │   │ │
│  │  │                                                      │   │ │
│  │  │  1. Receives tool_call from pi extension             │   │ │
│  │  │  2. Evaluates layered policy                         │   │ │
│  │  │  3. Auto-approve → respond immediately               │   │ │
│  │  │  4. Deny → respond with block                        │   │ │
│  │  │  5. Needs approval → push to phone, wait for reply   │   │ │
│  │  │  6. Persists pending decisions (survive restart)      │   │ │
│  │  └─────────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────┘ │
│                         │                                        │
│            ┌────────────┴────────────┐                           │
│            ▼                         ▼                           │
│  ┌─────────────────┐      ┌─────────────────┐                   │
│  │  Pi Instance     │      │  Pi Instance     │                   │
│  │  (user: alice)    │      │  (user: bob)    │                   │
│  │                  │      │                  │                   │
│  │  permission-gate │      │  permission-gate │                   │
│  │  extension       │      │  extension       │                   │
│  │  (hooks tool_call│      │  (hooks tool_call│                   │
│  │   → TCP gate)    │      │   → TCP gate)    │                   │
│  └─────────────────┘      └─────────────────┘                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. Permission Gate Extension

A pi extension installed in each user's sandbox. Hooks `tool_call` events and
delegates permission decisions to the pi-remote server.

**Location:** `pi-remote/extensions/permission-gate/index.ts`

### Extension ↔ Server Transport

**Primary: TCP (current implementation)**. Each session gets a dynamic gate port
on the host. The extension connects from inside the container to host-gateway
(`192.168.64.1:<port>`).

**Fallback: HTTP** remains a possible future option for multi-host deployments.

The extension can abstract transport behind a `GateTransport` interface.

```typescript
interface GateTransport {
  request(req: GateRequest): Promise<GateResponse>;
  sendHeartbeat(): Promise<void>;
  close(): void;
}
```

### Extension Implementation

```typescript
export default function permissionGate(pi: ExtensionAPI) {
  const gateHost = process.env.PI_REMOTE_GATE_HOST; // host-gateway (e.g. 192.168.64.1)
  const gatePort = process.env.PI_REMOTE_GATE_PORT; // per-session dynamic port
  const gateUrl = process.env.PI_REMOTE_GATE_URL;   // optional future HTTP fallback
  const sessionId = process.env.PI_REMOTE_SESSION;

  if ((!gateHost || !gatePort) && !gateUrl) return; // Not under pi-remote, no-op

  const transport = gateHost && gatePort
    ? new TcpGateTransport(gateHost, Number(gatePort))
    : new HttpTransport(gateUrl!, process.env.PI_REMOTE_TOKEN!);

  // --- Handshake: prove extension is loaded ---
  pi.on("before_agent_start", async () => {
    await transport.request({
      type: "guard_ready",
      sessionId,
      extensionVersion: "1.0.0",
    });
  });

  // --- Heartbeat: prove extension is alive ---
  const heartbeat = setInterval(() => {
    transport.sendHeartbeat().catch(() => {});
  }, 15_000);

  pi.on("session_end", () => {
    clearInterval(heartbeat);
    transport.close();
  });

  // --- Permission gate ---
  pi.on("tool_call", async (event, ctx) => {
    const response = await transport.request({
      type: "gate_check",
      tool: event.toolName,
      input: event.input,
      toolCallId: event.toolCallId,
    });

    if (response.action === "deny") {
      return { block: true, reason: response.reason };
    }
    // "allow" → return nothing, tool executes normally
  });
}
```

### Extension Safety: Guarded Sessions

The server marks sessions as "guarded" only after receiving the `guard_ready`
handshake. Critical safety invariant:

1. Server spawns pi with the permission-gate extension installed
2. Extension sends `guard_ready` on `before_agent_start`
3. Server marks session as `guarded`
4. **If `guard_ready` never arrives**: session stays `unguarded`, all tool
   calls blocked (fail-closed)
5. **If heartbeat stops**: server switches to fail-safe mode (deny all or
   read-only, per policy)

This prevents silent fail-open if the extension crashes or isn't loaded.

---

## 2. Policy Engine

Evaluates tool calls against user-specific policies using layered evaluation.

**Location:** `pi-remote/src/policy.ts`

### Layered Evaluation Order

```
1. Platform hard denies (immutable, can't be overridden)
2. Workspace boundary checks (path confinement)
3. User-defined explicit rules (from policy YAML)
4. Learned rules (from "Always Allow" approvals)
5. Default action
```

Hard denies always win. Learned rules never override explicit denies.

### Policy Configuration (per user)

```typescript
interface UserPolicy {
  workspaces: WorkspacePolicy[];

  // Immutable denies — cannot be overridden by learned rules
  hardDeny: PolicyRule[];

  // User-defined rules (evaluated in order)
  rules: PolicyRule[];

  // Learned rules (auto-added by "Always Allow", separate tier)
  learnedRules: LearnedRule[];

  defaultAction: "allow" | "ask" | "deny";

  // What happens when phone is unreachable
  offlineMode: "strict" | "degraded_readonly" | "grace_window";

  // Timeout for approval requests (ms)
  approvalTimeout: number; // default: 120_000 (2 min)

  // Grace window duration for previously-approved actions (ms)
  // Only used when offlineMode is "grace_window"
  graceWindowMs: number; // default: 300_000 (5 min)
}

interface WorkspacePolicy {
  name: string;                        // "my-project"
  hostPath: string;                    // "/Users/dev/workspace/myproject"
  sandboxPath: string;                 // "/workspace/oppi"
  access: "read-write" | "read-only";
}

interface PolicyRule {
  tool?: string;           // "bash" | "write" | "edit" | "read" | "*"

  // For bash: matches against parsed executable name
  exec?: string;           // "git" | "npm" | "rm" | "sudo"

  // For bash: matches against full command (glob)
  // For file tools: matches against resolved path (glob)
  pattern?: string;

  // Path confinement (resolved via realpath before matching)
  pathWithin?: string;     // "/workspace/oppi" — must be inside this dir

  action: "allow" | "ask" | "deny";
  label?: string;
  risk?: "low" | "medium" | "high" | "critical";
}

interface LearnedRule extends PolicyRule {
  scope: "once" | "session" | "workspace" | "persistent";
  learnedAt: string;        // ISO timestamp
  learnedFrom: string;      // toolCallId that triggered learning
  expiresAt?: string;       // ISO timestamp, for session/time-bound scopes
}
```

### Bash Command Parsing

Don't glob-match raw command strings. Parse first:

```typescript
interface ParsedCommand {
  executable: string;       // "git", "npm", "rm"
  args: string[];           // ["push", "origin", "main"]
  raw: string;              // Original command string
  hasPipe: boolean;         // Contains |
  hasRedirect: boolean;     // Contains > >> <
  hasSubshell: boolean;     // Contains $() or backticks
  paths: string[];          // Resolved paths found in args
}

function parseBashCommand(command: string): ParsedCommand {
  // Basic tokenizer — split on whitespace, handle quotes
  // Resolve paths via realpath to defeat ../../../ traversal
  // Flag structural hazards (pipes, redirects, subshells)
}
```

Rules match against parsed fields:

```yaml
# Match any git command
- tool: bash
  exec: git
  action: allow

# Match rm, but only within workspace
- tool: bash
  exec: rm
  pathWithin: /workspace/oppi
  action: ask

# Block anything with pipes or subshells (structural hazard)
- tool: bash
  pattern: "*"
  # Engine auto-denies if hasPipe || hasSubshell (hard deny layer)
```

### Default Policies (presets)

```yaml
# admin.yaml
hardDeny:
  - { tool: bash, exec: sudo, action: deny, label: "No sudo" }
  - { tool: bash, exec: rm, pattern: "rm -rf /", action: deny }
  - { tool: "*", pattern: "~/.ssh/*", action: deny, label: "Protect SSH keys" }
  - { tool: "*", pattern: "*/.env*", action: deny, label: "Protect env files" }

rules:
  # Safe reads — auto-allow
  - { tool: read, action: allow }
  - { tool: bash, exec: ls, action: allow }
  - { tool: bash, exec: cat, action: allow }
  - { tool: bash, exec: grep, action: allow }
  - { tool: bash, exec: rg, action: allow }
  - { tool: bash, exec: find, action: allow }
  - { tool: bash, exec: wc, action: allow }
  - { tool: bash, exec: head, action: allow }
  - { tool: bash, exec: tail, action: allow }

  # Safe git — auto-allow
  - { tool: bash, exec: git, pattern: "git status*", action: allow }
  - { tool: bash, exec: git, pattern: "git diff*", action: allow }
  - { tool: bash, exec: git, pattern: "git log*", action: allow }
  - { tool: bash, exec: git, pattern: "git branch*", action: allow }

  # Structural hazards — always ask
  - { tool: bash, pattern: "* | *", action: ask, risk: high, label: "Pipe detected" }
  - { tool: bash, pattern: "*$(*)*", action: ask, risk: high, label: "Subshell detected" }

defaultAction: ask
offlineMode: degraded_readonly
approvalTimeout: 120000
graceWindowMs: 300000
```

```yaml
# standard.yaml
hardDeny:
  - { tool: bash, exec: sudo, action: deny }
  - { tool: bash, exec: rm, action: deny }
  - { tool: bash, exec: curl, action: deny }
  - { tool: bash, exec: wget, action: deny }
  - { tool: "*", pattern: "~/.ssh/*", action: deny }

rules:
  - { tool: read, action: allow }
  - { tool: bash, exec: ls, action: allow }
  - { tool: bash, exec: cat, action: allow }

defaultAction: ask
offlineMode: strict
approvalTimeout: 120000
```

```yaml
# restricted.yaml
hardDeny:
  - { tool: bash, action: deny, label: "No bash" }
  - { tool: write, action: deny, label: "No writes" }
  - { tool: edit, action: deny, label: "No edits" }

rules:
  - { tool: read, action: allow }

defaultAction: deny
offlineMode: strict
approvalTimeout: 60000
```

### Phone Unreachable — Offline Modes

When the phone doesn't respond within `approvalTimeout`:

| Mode | Behavior |
|------|----------|
| `strict` | Deny. Agent gets clean error. Default for standard/restricted users. |
| `degraded_readonly` | Allow only tools that match existing `allow` rules. Block everything else. Agent told it's in degraded mode. |
| `grace_window` | For `graceWindowMs` after last phone contact, allow actions matching recently-approved patterns. After window expires, fall back to `strict`. |

The extension's `tool_call` handler receives a clear response in each case:

```json
{ "action": "deny", "reason": "Phone unreachable (strict mode)", "retryable": true }
{ "action": "deny", "reason": "Degraded mode: this action requires approval", "retryable": true }
```

### "Always Allow" — Scoped Learning

When a user approves with "Always Allow", the phone presents scope options:

| Scope | What happens |
|-------|-------------|
| **This once** | No rule added. Just allows this specific call. |
| **This session** | Rule added to `learnedRules` with `expiresAt` = session end. |
| **This workspace** | Rule scoped to `pathWithin: <current workspace>`. Persists. |
| **Always** | Unscoped persistent rule. Persists across sessions. |

Learned rules are stored in a separate tier and can never override `hardDeny`:

```yaml
# In alice.yaml, auto-maintained section
learnedRules:
  - tool: bash
    exec: npm
    pattern: "npm test*"
    action: allow
    scope: workspace
    pathWithin: /workspace/oppi
    label: "Approved npm test (2026-02-06)"
    learnedAt: "2026-02-06T13:30:00Z"
    learnedFrom: "tc_abc123"
```

---

## 3. Auth Model

Three token types with different scopes and lifetimes:

| Token | Who holds it | Scope | Lifetime |
|-------|-------------|-------|----------|
| **User API token** | Phone app | REST + WebSocket endpoints | Long-lived, rotatable |
| **Session gate token** | Pi extension | `/internal/gate` only, bound to 1 session | Session lifetime |
| **Admin token** | CLI / admin tools | Config, policy, user management | Long-lived, rotatable |

### Session Gate Token

Created when pi is spawned. Bound to session ID. Passed to extension via env:

```typescript
const gateToken = {
  token: nanoid(32),
  sessionId: session.id,
  userId: user.id,
  createdAt: Date.now(),
  // No expiresAt — dies with the session
};
```

For TCP transport, access control is primarily per-session dynamic ports
allocated by the server and scoped to the active session lifecycle. A session
gate token can still be layered as defense-in-depth.

---

## 4. Server Protocol

### Internal Gate (TCP + optional HTTP)

**TCP protocol:** newline-delimited JSON over the per-session connection.

```
→ Extension sends:
{"type":"guard_ready","sessionId":"sess_abc","extensionVersion":"1.0.0"}

← Server responds:
{"type":"guard_ack","status":"ok"}

→ Extension sends:
{"type":"gate_check","tool":"bash","input":{"command":"git push origin main"},"toolCallId":"tc_abc"}

← Server responds (immediate for allow/deny):
{"type":"gate_result","action":"allow"}

← Server responds (after phone approval):
{"type":"gate_result","action":"allow","approvedBy":"user_alice","scope":"session"}

← Server responds (denied):
{"type":"gate_result","action":"deny","reason":"Blocked by policy: no sudo"}

→ Extension sends (periodic):
{"type":"heartbeat"}

← Server responds:
{"type":"heartbeat_ack"}
```

**HTTP fallback** (same semantics, REST wrapper):

```
POST /internal/gate
Authorization: Bearer <gate-token>

{"type":"gate_check","tool":"bash","input":{"command":"git push"},"toolCallId":"tc_abc"}

→ 200 {"action":"allow"}
→ 200 {"action":"deny","reason":"..."}
```

### WebSocket Protocol (Phone ↔ Server)

New message types for permission flow:

```typescript
// Server → Phone
| {
    type: "permission_request",
    id: string,                      // Unique request ID
    sessionId: string,
    tool: string,
    input: Record<string, unknown>,
    displaySummary: string,          // "git push origin main"
    parsed?: {                       // Structured for rich UI
      executable?: string,
      args?: string[],
      paths?: string[],
    },
    risk: "low" | "medium" | "high" | "critical",
    reason: string,                  // Why asking: matched rule label
    context?: string,                // What agent is working on
    timeoutAt: number,               // Unix ms — when auto-deny fires
  }

| {
    type: "permission_expired",
    id: string,                      // Request that timed out
    reason: string,
  }

| {
    type: "permission_cancelled",
    id: string,                      // Tool call no longer waiting
  }

// Phone → Server
| {
    type: "permission_response",
    id: string,
    action: "allow" | "deny" | "allow_session" | "allow_workspace" | "allow_always",
  }
```

### Permission Storm Handling

Agents can emit rapid-fire tool calls. Prevent phone UI overload:

1. **Coalescing**: Group similar requests. "Agent wants to read 12 files in
   `/workspace/oppi/src/` — approve all?"
2. **Batch templates**: "Allow next N calls matching this pattern"
3. **Per-session queue limit**: Max 10 pending approvals. Beyond that, new
   requests get queued server-side, oldest-first.
4. **Priority ordering**: High-risk requests surface first on phone.

### Durable Pending Decisions

Pending permission requests are persisted (SQLite or JSON file) so they
survive server restarts:

```typescript
interface PendingDecision {
  id: string;
  sessionId: string;
  userId: string;
  tool: string;
  input: Record<string, unknown>;
  createdAt: number;
  timeoutAt: number;
  status: "pending" | "approved" | "denied" | "expired" | "cancelled";
}
```

On restart:
- Re-hydrate pending decisions from store
- Push backlog to reconnecting phone clients
- Expire any that passed `timeoutAt`
- Extension's blocked request gets a clean `retryable_error` on socket
  disconnect, can retry

---

## 5. Audit Log

Every tool call and permission decision is logged:

```typescript
interface AuditEntry {
  timestamp: number;
  userId: string;
  sessionId: string;
  tool: string;
  input: Record<string, unknown>;
  decision: "allow" | "deny" | "ask_allowed" | "ask_denied" | "timeout" | "degraded";
  rule?: string;           // Which rule matched
  layer?: string;          // "hard_deny" | "workspace" | "user_rule" | "learned" | "default"
  responseTime?: number;   // How long approval took (ms)
  scope?: string;          // For learned approvals: "session" | "workspace" | "always"
}
```

Stored as JSONL:
```
~/.config/pi-remote/audit/<userId>/<date>.jsonl
```

---

## 6. Workspace Mounting

When the server spawns pi for a user, it sets up workspace access:

```typescript
// In sessions.ts, spawnPi():

// 1. Create gate TCP server for this session
const gatePort = await createGatePort(session.id, session.userId);

// 2. Create symlinks from sandbox to real directories
for (const ws of policy.workspaces) {
  const linkPath = path.join(sandboxDir, "workspace", ws.name);
  await fs.symlink(ws.hostPath, linkPath);
}

// 3. Spawn pi with extension and gate host/port
const proc = spawn("pi", args, {
  cwd: path.join(sandboxDir, "workspace"),
  env: {
    ...process.env,
    PI_REMOTE_GATE_HOST: "192.168.64.1",
    PI_REMOTE_GATE_PORT: String(gatePort),
    PI_REMOTE_USER: userId,
    PI_REMOTE_SESSION: session.id,
  },
});
```

Path safety for workspace checks:
- All paths resolved via `realpath()` before policy evaluation
- Symlink targets are validated against workspace boundaries
- `..` traversal neutralized by canonicalization

---

## Implementation Plan

### Phase 1: Permission Gate MVP
1. `policy.ts` — Layered policy engine with bash parsing + workspace bounds
2. `gate.ts` — TCP gate server (per-session dynamic ports)
3. `permission-gate/index.ts` — Pi extension with handshake + heartbeat
4. Server: WebSocket `permission_request`/`permission_response` protocol
5. Server: guarded session state machine (`unguarded` → `guarded` → `fail-safe`)
6. Default policy presets (admin, standard, restricted)
7. Durable pending decision store

### Phase 2: Workspace Management
1. Workspace config in user policy YAML
2. Symlink setup on pi spawn
3. Path canonicalization + boundary validation
4. CLI: `pi-remote workspace add/remove/list`

### Phase 3: iOS App MVP
1. Onboarding (QR scan, user API token exchange)
2. Session list + create
3. Chat (text + images)
4. Permission approval UI with risk tiers and scope selection
5. Live activity feed
6. Permission storm coalescing in UI

### Phase 4: Polish
1. Scoped "Always Allow" learning (session/workspace/persistent)
2. Audit log viewer in app
3. Push notifications (APNs) for permission requests
4. Voice input
5. Policy editor in app
6. Grace window and degraded_readonly offline modes

---

## Key Design Decisions

### Why TCP gate (not UDS) for extension ↔ server?
- Apple container mounts can fail with UDS (`ENOTSUP`) in this setup
- Per-session dynamic TCP ports work reliably from container → host-gateway
- Still simple newline-delimited JSON protocol
- Clean per-session isolation via dedicated listener per session
- HTTP can still be layered later if multi-host transport is needed

### Why layered policy evaluation?
- Hard denies are immutable — learned rules can never override them
- Workspace boundaries checked before any rule evaluation
- Learned rules in a separate tier with explicit scope + review
- Deterministic, auditable, explainable (audit log records which layer decided)

### Why parse bash commands instead of glob-matching raw strings?
- `rm -rf /` vs `rm   -rf   /` vs `'rm' '-rf' '/'` — same command, different strings
- Pipes, subshells, redirects are structural hazards that globs can't detect
- Executable-level matching (`exec: git`) is simpler and safer than `pattern: "git *"`
- Path arguments resolved via `realpath()` to defeat `../../../` traversal

### Why not use pi's existing permission system?
- Pi's interactive prompts are for terminal users
- In RPC mode, confirm() always returns false
- Permission decisions must flow through the phone, not the terminal
- The extension approach is additive — doesn't modify pi internals

### Why policy rules instead of AI-based classification?
- Explicit rules are auditable and predictable
- Users can read and edit the YAML
- "Always Allow" grows the ruleset over time
- Critical for trust: you need to KNOW what will be approved

### Why the guarded session handshake?
- Prevents silent fail-open if extension isn't loaded
- Heartbeat detects extension crashes
- Server won't process agent tool calls for unguarded sessions
- Fail-closed by default, explicitly opt into degraded modes
