# Pi Remote — Implementation Plan

Last updated: 2026-02-10

Execution plan for pi-remote. Ordered by impact: security and reliability
first, then visible features, then the workspace migration, then skills.

Source of truth for delivery status and step scope. Architecture target
is in `WORKSPACE-CONTAINERS.md`. Current shipped behavior is in `README.md`.

---

## Current Baseline (Shipped)

### Server (pi-remote)
- [x] HTTP + WebSocket server with bearer auth
- [x] Pi session lifecycle and RPC streaming
- [x] Permission gate extension + host TCP gate server
- [x] Layered policy engine
- [x] Workspace CRUD + skill discovery endpoints
- [x] Session references workspace (workspaceId, workspaceName)
- [x] Tool event parity (toolCallId plumbing + partialResult delta handling)
- [x] Vitest test suite (policy, gate, bootstrap, sync, trace, tool-events)

### iOS
- [x] Session list + chat runtime
- [x] Workspace picker + management screens
- [x] Skills listing from server
- [x] Tool event decoding with toolCallId
- [x] Comprehensive test suite (decoding, reducer, reliability, bugbash)

### Security
- [x] Apple container isolation (process + filesystem)
- [x] Permission gate blocks unguarded tool calls (fail-closed)
- [x] Auth proxy — container auth now uses stub credentials + host proxy injection (Step 1 complete; internal-network variant was superseded by NAT mode decision)

---

## Reality Check (2026-02-10)

### Completed since initial plan
- ✅ Step 1 (`TODO-5d327779`) — auth proxy landed in server/sandbox/session lifecycle.
- ✅ Step 2/5 (`TODO-fb28452c`) — sequenced durable replay + reconnect catch-up shipped (server + iOS).
- ✅ Step 6 (`TODO-aa0f8e35`) — snapshot semantics docs covered.
- ✅ Step 7 (`TODO-78eba302`) — workspace-scoped runtime core complete.
- ✅ Step 8 (`TODO-31efdce1`) — workspace-scoped API migration complete.
- ✅ Step 9 (`TODO-1fe2951f`) — iOS workspace-first UX shipped.
- ✅ Step 11a (`TODO-eabe2bf3`) — server-side user skill CRUD shipped.
- ✅ Infra refactor (2026-02-10) — server orchestration split into `server.ts` + `routes.ts` + `stream.ts`.
- ✅ iOS chat durability lane (`TODO-f0126679`) — chat timeline no longer exhibits
  reproducible freeze/hang behavior in current dogfood; native timeline migration
  and validation complete for current scope.

### In progress / partially delivered
- 🟡 Step 3 (`TODO-362ce018`) — file content endpoint shipped; directory listing API remains.
- 🟡 Step 4c (`TODO-bd36f35a`) — tappable file access in chat shipped via ToolCall rows (different UX than planned chips).

### Still pending
- ⏳ Step 10 (`TODO-19cb0451`) — fork workflow.
- ⏳ Step 11b/11c (`TODO-d6c60004`, `TODO-bdffb4b5`) — load user skills into sessions + safety gate.
- ⏳ Step 12/13 (`TODO-2cd10bc4`, `TODO-6717558a`, `TODO-a55a58d6`, `TODO-f471ff40`, `TODO-511647e2`) — full skills UI + creation workflow.

---

## Implementation Steps

### Step 1: Auth proxy + internal network
**TODO-5d327779** | Server | ~1 day | **Security**

Replace auth.json copying with a host-side auth proxy so secrets never enter
container auth files. (Original `--internal` network requirement was superseded
by NAT networking after implementation tradeoff review.)

Design: `pi-remote/docs/auth-proxy-design.md`

| Deliverable | File |
|-------------|------|
| HTTP reverse proxy (~150 LOC) | `src/auth-proxy.ts` — NEW |
| Stub auth.json + models.json rewrite | `src/sandbox.ts` |
| Session registration with proxy | `src/sessions.ts` |
| Container network policy wiring | `src/sandbox.ts` (server startup) |

Current behavior: containers run on a NAT network for internet access; credential isolation is enforced by auth proxy credential substitution.

---

### Step 2: Sequenced updates — server side
**TODO-fb28452c (steps 1-6)** | Server | ~1.5 days | **Reliability**

Add per-session monotonic sequence numbers to durable events. Enable
reconnect catch-up without losing tool call history.

| Deliverable | File |
|-------------|------|
| EventRing class (bounded buffer) | `src/sessions.ts` |
| Durable/ephemeral broadcast split | `src/sessions.ts` |
| `message_end` broadcast (new durable event) | `src/sessions.ts` |
| `currentSeq` in connected message | `src/sessions.ts` |
| `GET /sessions/:id/events?since=` | `src/routes.ts` |
| Type updates (seq, message_end) | `src/types.ts` |
| EventRing unit tests | `tests/event-ring.test.ts` — NEW |

---

### Step 3: File access — server API
**TODO-362ce018** | Server | ~0.5 day | **Feature**

Expose workspace files over REST so the iOS app can browse agent output.

| Deliverable | File |
|-------------|------|
| Workspace path guard + MIME handling | `src/routes.ts` (shipped) |
| `GET /sessions/:id/files?path=` (file content) | `src/routes.ts` (shipped) |
| Directory listing API (`/sessions/:id/files?path=<dir>`) | ⏳ pending |

---

### Step 4: File browser + previews — iOS
**TODO-15956340, TODO-cf1dbddf, TODO-bd36f35a** | iOS | ~2.5 days | **Feature**

| Sub-step | What | Effort | Status |
|----------|------|--------|--------|
| 4a | FileService + FileListView + FileRowView | 1d | ⏳ Pending |
| 4b | FilePreviewView router (markdown, image, HTML, code) | 1d | ⏳ Pending |
| 4c | FileChipView in chat bubbles for write/edit tool calls | 0.5d | 🟡 Partial (implemented as tappable tool-row file paths) |

Can run in parallel with Step 5.

---

### Step 5: Sequenced updates — iOS side
**TODO-fb28452c (steps 7-9)** | iOS | ~1.5 days | **Reliability**

| Deliverable | File |
|-------------|------|
| Decode optional `seq`, add `messageEnd` case | `ServerMessage.swift` |
| Track `lastSeenSeq`, catch-up on reconnect, dedup | `ServerConnection.swift` |
| Handle `messageEnd` (finalized text without deltas) | `TimelineReducer.swift` |

Can run in parallel with Step 4.

---

### Step 6: Docs — snapshot semantics
**TODO-aa0f8e35** | Docs | ~2 hours

Document extension/skill sync behavior in container sessions:
- Snapshot semantics (synced at session creation, not live)
- Why symlink dereference is required
- Troubleshooting checklist

---

### Step 7: Workspace runtime core (IMPL Phase 0)
**TODO-78eba302** | Server | ~2-3 days | **Architecture** | Medium risk

Container lifecycle moves from session-scoped to workspace-scoped.
Multiple pi processes per workspace.

| Deliverable | File |
|-------------|------|
| ActiveWorkspace → ActiveSession[] | `src/workspace-runtime.ts` — NEW |
| Sandbox layout: `userId/workspaceId/` | `src/sandbox.ts` |
| Per-workspace + per-session mutexes | `src/workspace-runtime.ts` |
| Configurable limits | `src/types.ts` |
| Legacy sandbox migration | `src/workspace-runtime.ts` |
| Tests | `tests/workspace-runtime.test.ts` — NEW |
| Tests | `tests/lifecycle-locks.test.ts` — NEW |
| Tests | `tests/session-limits.test.ts` — NEW |

Acceptance: two sessions in same workspace run concurrently, share files,
stopping one doesn't affect the other.

---

### Step 8: API migration (IMPL Phase 1)
**TODO-31efdce1** | Server | ~1-2 days | **Architecture**

| Deliverable | File |
|-------------|------|
| Workspace-scoped session APIs | `src/routes.ts` |
| Legacy route compat + deprecation warnings | `src/routes.ts` |
| Protocol version signal | `src/types.ts` |
| Background reconciliation job | `src/workspace-runtime.ts` |
| API contract tests | `tests/api-compat.test.ts` — NEW |

---

### Step 9: iOS workspace-first UX (IMPL Phase 2)
**TODO-1fe2951f** | iOS | ~2-3 days | **UX**

Promote workspaces to top-level navigation. Workspace detail shows
session states with start/resume/stop actions.

Can run in parallel with Step 10.

---

### Step 10: Fork workflow (IMPL Phase 3)
**TODO-19cb0451** | Server + iOS | ~1-2 days | **Feature**

| Deliverable | Side |
|-------------|------|
| `POST /workspaces/:wid/sessions/:sid/fork` | Server |
| JSONL copy + new pi process | Server |
| Fork lineage metadata | Server |
| Long-press → Fork action | iOS |
| Lineage display in session detail | iOS |

Can run in parallel with Step 9.

---

### Step 11: Skill CRUD (IMPL Phase 4)
**TODO-eabe2bf3, TODO-d6c60004, TODO-bdffb4b5** | Server | ~2 days

| Sub-step | What | Effort | Status |
|----------|------|--------|--------|
| 11a | Skill storage + CRUD API | 1d | ✅ Done |
| 11b | Load user skills into sessions | 0.5d | ⏳ Pending |
| 11c | Skill promotion safety gate | 0.5d | ⏳ Pending |

---

### Step 12: iOS Skills UI (IMPL Phase 4)
**TODO-2cd10bc4, TODO-6717558a, TODO-a55a58d6** | iOS | ~3 days

| Sub-step | What | Effort |
|----------|------|--------|
| 12a | Skills tab with list view | 1d |
| 12b | Skill detail view with file browser | 1d |
| 12c | Save skill from session workspace | 1d |

---

### Step 13: Skill creation (IMPL Phase 5)
**TODO-f471ff40, TODO-511647e2** | Server + iOS | ~2-3 days

| Sub-step | What | Effort |
|----------|------|--------|
| 13a | Server: skill-creation + refinement session setup | 1-2d |
| 13b | iOS: skill creation sheet + refinement flow | 1-2d |

---

### Deferred
- **TODO-fca8f6b6** — Optimistic concurrency. Wait for macOS client.
- GitHub skill import + security scanning pipeline (Phase 4 in WORKSPACE-CONTAINERS.md)
- Workspace templates (Phase 6 in WORKSPACE-CONTAINERS.md)

---

## Step Dependencies

```
Server track:
  Step 1 (auth proxy) → Step 2 (seq server) → Step 3 (files API)
                                                     ↓
  Step 7 (ws runtime) → Step 8 (API migration) → Step 11 (skill CRUD)
                                                     ↓
                                                  Step 13a (skill sessions)

iOS track:
  Step 4 (file browser) ─────┐
  Step 5 (seq iOS) ──────────┤
                              ↓
  Step 9 (workspace UX) ─────┤
  Step 10 (fork) ────────────┤
  Step 12 (skills UI) ───────┤
                              ↓
  Step 13b (skill creation)

Docs:
  Step 6 (snapshot docs) — anytime
```

Steps 4+5 (iOS) can run while Step 7 (server refactor) is underway.
Steps 9+10 start after Step 8 ships.
Steps 11+12 can start after Step 8. Server skill CRUD (11) and iOS skills UI (12) can overlap.

---

## Cross-Step Guardrails

- Fail-closed permission behavior: unguarded gate blocks tool calls
- No regressions in tool correlation (toolCallId) and output streaming
- Backward-compatible iOS decoding for at least one server release
- No destructive data migration without backup marker + rollback metadata
- No hidden behavior changes without tests

---

## Effort Summary

| Category | Steps | Effort |
|----------|-------|--------|
| Security | 1 | ~1d |
| Reliability | 2, 5 | ~3d |
| File access | 3, 4 | ~3d |
| Docs | 6 | ~2h |
| Workspace migration | 7, 8, 9, 10 | ~8-10d |
| Skills | 11, 12, 13 | ~7-8d |
| **Total** | | **~22-25d** |
