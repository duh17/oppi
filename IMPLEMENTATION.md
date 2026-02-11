# Pi Remote — Implementation Plan

Last updated: 2026-02-11

Execution plan for pi-remote + clients. Ordered by impact: security and
reliability first, then visible features, then workspace migration/skills,
then macOS expansion.

Source of truth for delivery status and step scope. Architecture targets are
in `WORKSPACE-CONTAINERS.md` (server/workspaces) and
`ios/docs/macos-app-design.md` (desktop). Current shipped behavior is in
`README.md`.

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

## Reality Check (2026-02-11)

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
- 🟡 Step 0 (`TODO-65cabfd5`) — signed invite v2 + `/security/profile` + iOS trust/profile checks landed; key backend hardening + full trust-reset UX still pending.
- 🟡 Step 3 (`TODO-362ce018`) — file content endpoint shipped; directory listing API remains.
- 🟡 Step 4c (`TODO-bd36f35a`) — tappable file access in chat shipped via ToolCall rows (different UX than planned chips).

### Still pending
- ⏳ Step 10 (`TODO-19cb0451`) — fork workflow.
- ⏳ Step 11b/11c (`TODO-d6c60004`, `TODO-bdffb4b5`) — load user skills into sessions + safety gate.
- ⏳ Step 12/13 (`TODO-2cd10bc4`, `TODO-6717558a`, `TODO-a55a58d6`, `TODO-f471ff40`, `TODO-511647e2`) — full skills UI + creation workflow.

### New direction (2026-02-11)
- 🆕 Add native macOS app track (DMG distribution, no Mac App Store dependency).
- 🆕 Require functional parity with core iOS supervision workflows.
- 🆕 Extract shared Swift core (`OppiCore`) before scaling two client shells.
- 🆕 Include macOS local server management mode (launchd-backed lifecycle).
- 🆕 Umbrella tracker: **TODO-2ef5e529**.

---

## Implementation Steps

### Step 0: Security config v2 + signed bootstrap
**TODO-65cabfd5** | Server + iOS | ~2-4 days | **Security** | In progress

Define and ship a server-authored security contract with signed invite bootstrap,
identity pinning, and explicit transport policy.

Design: `pi-remote/docs/security-config-v2.md`

| Deliverable | File |
|-------------|------|
| Config v2 schema (security/identity/invite sections) | `pi-remote/src/types.ts`, `pi-remote/src/storage.ts` |
| Config introspection + validator CLI | `pi-remote/src/index.ts`, `pi-remote/src/storage.ts` |
| Signed invite v2 envelope + signer | `pi-remote/src/index.ts`, `pi-remote/src/security.ts` — NEW |
| Security profile endpoint (`/security/profile`) | `pi-remote/src/routes.ts` |
| iOS invite verification + server identity pinning | `ios/PiRemote/Core/Models/User.swift`, onboarding + connection services |
| Migration compatibility (v1+v2 invites) | server invite command + iOS QR parser |

Acceptance:
- New clients verify signed invites and pin server identity.
- Server policy governs insecure transport allowances.
- Legacy unsigned invites remain explicit compatibility mode only.

---

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

### Step 14: Shared Swift core extraction (MAC Phase 0)
**TODO-5c8b04ac** | iOS + macOS | ~4-6 days | **Architecture**

Extract non-UI app logic into a shared package used by both clients.

| Sub-step | What | Effort | Status |
|----------|------|--------|--------|
| 14a | Create `ios/Packages/OppiCore` + module scaffolding | 0.5d | ⏳ Pending |
| 14b | Move wire models/encoding/decoding (`Session`, `ServerMessage`, `ClientMessage`, etc.) | 1-1.5d | ⏳ Pending |
| 14c | Move networking (`APIClient`, `WebSocketClient`) + protocol tests | 1-1.5d | ⏳ Pending |
| 14d | Move runtime/state (`TimelineReducer`, `DeltaCoalescer`, `ToolEventMapper`, stores) | 1-1.5d | ⏳ Pending |
| 14e | Shared test targets + fixture parity gate against `src/types.ts` | 0.5-1d | ⏳ Pending |

Acceptance: iOS app builds/runs against shared package with no behavior regressions.

---

### Step 15: Native macOS shell + supervision backbone (MAC Phase 1)
**TODO-9a0c8c1c** | macOS | ~4-6 days | **Feature**

| Deliverable | File |
|-------------|------|
| New `OppiMac` app target + schemes | `ios/project.yml` |
| 3-column `NavigationSplitView` shell (sessions/timeline/inspector) | `ios/OppiMac/**` — NEW |
| Session connect/stream/send/stop lifecycle | `ios/OppiMac/**` + shared core |
| Permission queue + approve/deny actions | `ios/OppiMac/**` + shared core |
| Keyboard command set (`⌘1/2/3`, stop, approve/deny, focus input) | `ios/OppiMac/**` |

Acceptance: end-to-end supervision loop works on macOS for one active session.

---

### Step 16: macOS parity surfaces (MAC Phase 2)
**TODO-f1aba990, TODO-d3cefc62** | macOS | ~4-6 days | **Parity**

| Sub-step | What | Effort |
|----------|------|--------|
| 16a | Workspaces UX parity (list/create/edit/select/runtime mode) | 1-1.5d |
| 16b | Skills UX parity (list/detail/files/save-from-session) | 1-1.5d |
| 16c | Tool/file/diff detail inspector parity | 1-1.5d |
| 16d | Diagnostics/reconnect/restoration parity + soak checklist | 1-1.5d |
| 16e | Sentry parity (SDK wiring, breadcrumbs, PII filtering, validation matrix) | 0.5-1d |

Acceptance: all critical iOS supervision workflows are possible on macOS.

---

### Step 17: Local server management mode (MAC Phase 3)
**TODO-1f44cf87** | macOS + Server | ~2-3 days | **Ops**

| Deliverable | Side |
|-------------|------|
| Local mode settings (host/port/data dir) | macOS |
| Start/stop/restart/status controls for local `pi-remote` | macOS |
| launchd agent install/uninstall + health diagnostics | macOS |
| Local logs view (tail) + readiness checks (`/health`) | macOS + Server |

Acceptance: user can run/supervise local server from mac app without terminal.

---

### Step 18: macOS DMG distribution pipeline
**TODO-7224f5e7** | macOS | ~1-1.5 days | **Release**

| Deliverable | File |
|-------------|------|
| Developer ID signing config | build/release scripts — NEW |
| Notarization + stapling automation | build/release scripts — NEW |
| DMG packaging script + CI/local docs | `ios/scripts/` + docs — NEW |

---

### Step 19: Optimistic concurrency + multi-client conflict handling
**TODO-e4a538fe** | Server + iOS + macOS | ~1-2 days | **Reliability**

| Deliverable | Side |
|-------------|------|
| Version fields in session/workspace mutations | Server |
| Conflict detection/retry UX across iOS/macOS | iOS + macOS |
| Cross-client tests (same account, parallel edits/actions) | Server + clients |

Note: previously deferred pending macOS client; now scheduled after Step 15.

---

### Deferred
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

Shared/mac track:
  Step 14 (shared core) → Step 15 (mac shell) → Step 16 (mac parity)
                                                     ├→ Step 17 (local server mode)
                                                     ├→ Step 18 (DMG release pipeline)
                                                     └→ Step 19 (optimistic concurrency)

Docs:
  Step 6 (snapshot docs) — anytime
```

Steps 4+5 (iOS) can run while Step 7 (server refactor) is underway.
Steps 9+10 start after Step 8 ships.
Steps 11+12 can start after Step 8. Server skill CRUD (11) and iOS skills UI (12) can overlap.
Step 14 starts once Step 12/13 feature churn is stable enough for extraction.
Step 15 starts after Step 14b-14d land.
Step 17 and Step 18 can run in parallel late in Step 16.
Step 19 requires Step 15 plus server version-field plumbing.

---

## Cross-Step Guardrails

- Fail-closed permission behavior: unguarded gate blocks tool calls
- No regressions in tool correlation (toolCallId) and output streaming
- Backward-compatible iOS decoding for at least one server release
- No destructive data migration without backup marker + rollback metadata
- Shared-core extraction must keep platform-specific UI code out of shared modules
- macOS local server mode must not weaken host-mode gate/policy defaults
- No hidden behavior changes without tests

---

## Effort Summary

| Category | Steps | Effort |
|----------|-------|--------|
| Security | 1 | ~1d |
| Reliability | 2, 5, 19 | ~4-5d |
| File access | 3, 4 | ~3d |
| Docs | 6 | ~2h |
| Workspace migration | 7, 8, 9, 10 | ~8-10d |
| Skills | 11, 12, 13 | ~7-8d |
| Shared core extraction | 14 | ~4-6d |
| macOS parity client | 15, 16 | ~8-12d |
| macOS local ops + release | 17, 18 | ~3-5d |
| **Total** | | **~38-49d** |
