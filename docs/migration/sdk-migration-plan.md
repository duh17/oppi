# Oppi Server: RPC-to-SDK Migration Plan

Last updated: 2026-02-20

## Goal

Replace the pi RPC child process approach (`pi --mode rpc` over stdin/stdout)
with pi's native SDK (`createAgentSession()`). Preserve the iOS protocol
contract. Eliminate ~2,000 lines of translation/process management code.

## Status Quo

- Server spawns `pi --mode rpc` as a child process per session
- Communicates via stdin (JSON commands) / stdout (JSON events)
- `session-protocol.ts` translates pi RPC events to Oppi ServerMessages
- `session-spawn.ts` manages process lifecycle, args, env, readiness detection
- Permission gate runs as a pi extension inside the child process, connects
  back to server over a per-session TCP socket on localhost
- Server has zero npm dependency on `@mariozechner/pi-coding-agent`

## Invariants (Must Not Break)

1. **ServerMessage protocol** — iOS decodes `protocol/server-messages.json`.
   Every `ServerMessage` variant must continue to serialize identically.
2. **ClientMessage contract** — iOS sends the same messages. No client changes.
3. **Permission gate behavior** — tool_call interception, approval flow,
   learned rules, policy evaluation, audit log.
4. **Session lifecycle** — start, ready, busy, stopping, stopped, error
   transitions. Idle timeout. Reconnect catch-up.
5. **Turn delivery** — prompt/steer/follow_up, turn_ack stages, dedupe.
6. **Extension UI forwarding** — select/confirm/input dialogs routed to phone.
7. **Git status, change stats, mobile renderers** — unchanged.
8. **All 1,038 existing tests pass** (minus tests for deleted code).

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| SDK event shape differs from RPC | Medium | High | Phase 1 builds adapter, validated by protocol snapshot tests |
| Extension loading order changes | Low | Medium | Explicit extension list (same as current --extension args) |
| Permission gate timing changes | Medium | High | Phase 2 has dedicated integration test |
| Session file path changes | Low | Medium | Explicit sessionManager configuration |
| In-process crash kills server | Low | High | Phase 5 adds process-level isolation option |
| SDK API changes in pi updates | Low | Medium | Pin pi version, test on upgrade |

---

## Phase 0: Preparation (no code changes)

**Goal:** Baseline everything before touching anything.

### 0.1 — Snapshot green state
```bash
cd server && npm run check && npm test
./scripts/check-protocol.sh
```
Save output. This is the rollback target.

### 0.2 — Add pi SDK dependency
```bash
cd server && npm install @mariozechner/pi-coding-agent
```
Verify `npm run check && npm test` still passes (no type conflicts).

### 0.3 — Write SDK exploration spike (throwaway)
Create `server/spike/sdk-session.ts`:
- Call `createAgentSession()` with a known model
- Subscribe to events, log them
- Send a prompt, observe event types and shapes
- Compare event shapes against current `translatePiEvent` input format
- Document any differences in event field names/structures

**Deliverable:** A mapping document: `pi RPC event type` -> `SDK AgentSessionEvent type` -> delta from current translation.

### 0.4 — Extract the ServerMessage adapter interface
Before changing any implementation, define the adapter boundary:

```typescript
// server/src/session-adapter.ts (new)
export interface SessionAdapter {
  start(session: Session, workspace?: Workspace): Promise<void>;
  prompt(message: string, opts?: PromptOpts): Promise<void>;
  steer(message: string, opts?: SteerOpts): Promise<void>;
  followUp(message: string, opts?: FollowUpOpts): Promise<void>;
  abort(): Promise<void>;
  stop(): Promise<void>;
  getState(): Promise<PiState>;
  runRpcCommand(cmd: Record<string, unknown>, timeout?: number): Promise<unknown>;
  respondToUIRequest(response: ExtensionUIResponse): boolean;
  subscribe(callback: (msg: ServerMessage) => void): () => void;
  dispose(): void;
}
```
`SessionManager` calls this interface instead of touching `ChildProcess` directly.
Current implementation: `RpcSessionAdapter` (wraps existing logic).
New implementation: `SdkSessionAdapter` (Phase 2).

### Tests affected: None (interface extraction only)

---

## Phase 1: Model Catalog + Local Sessions (low risk, immediate wins)

**Goal:** Replace two self-contained subsystems with SDK equivalents.

### 1.1 — Model catalog via ModelRegistry

**Current:** `server.ts` shells out to `pi --list-models`, parses table text.
**New:** Import `ModelRegistry`, `AuthStorage` from pi SDK.

```typescript
import { AuthStorage, ModelRegistry } from "@mariozechner/pi-coding-agent";

const authStorage = AuthStorage.create();
const modelRegistry = new ModelRegistry(authStorage);
const models = await modelRegistry.getAvailable();
```

**Files changed:** `server.ts` (remove `parseModelTable`, `parseCompactTokenCount`, `resolvePiExecutable` for models, `FALLBACK_MODELS`, `refreshModelCatalog`, `modelCatalogRefresh` promise)

**Files deleted:** None (functions are inline in server.ts)

**Tests to update:**
- None directly (model catalog has no unit tests, tested via integration)
- Run `server-integration.test.ts` to verify `/models` endpoint

**Validation:**
```bash
npm test -- tests/server-integration.test.ts
```

### 1.2 — Local sessions via SessionManager.list()

**Current:** `local-sessions.ts` (358 lines) parses JSONL files manually.
**New:** Import `SessionManager` from pi SDK.

```typescript
import { SessionManager } from "@mariozechner/pi-coding-agent";

const sessions = await SessionManager.list(cwd);
// or SessionManager.listAll() for cross-project
```

Map the SDK `SessionListItem` to our existing `LocalSession` type.

**Files changed:** `local-sessions.ts` (rewrite internals, keep exported types)
**Tests to update:** `local-sessions.test.ts` (385 lines)
  - Most tests verify parsing behavior — replace with SDK output mapping tests
  - Keep tests for edge cases (missing files, corrupt JSONL) but expect SDK behavior

**Validation:**
```bash
npm test -- tests/local-sessions.test.ts
npm test -- tests/server-integration.test.ts  # /local-sessions endpoint
```

---

## Phase 2: Session Adapter Abstraction (medium risk, core change)

**Goal:** Introduce the adapter boundary so Phase 3 can swap implementations.

### 2.1 — Extract RpcSessionAdapter

Refactor `SessionManager` to use the `SessionAdapter` interface from Phase 0.4.
Move all ChildProcess/stdin/stdout/RPC logic into `RpcSessionAdapter`:

```
sessions.ts (SessionManager)
  └── calls SessionAdapter interface
        └── rpc-session-adapter.ts (current impl, extracted)
              ├── session-spawn.ts (process spawning)
              └── session-protocol.ts (event translation)
```

**Key constraint:** `SessionManager` must not import `ChildProcess` or `child_process`.

**Files changed:**
- `sessions.ts` — Remove process-specific code, call adapter interface
- New `rpc-session-adapter.ts` — Contains extracted logic

**Files unchanged:** `session-spawn.ts`, `session-protocol.ts` (still used by RpcAdapter)

**Tests affected:**
- `session-lifecycle.test.ts` (1173 lines) — Currently mocks ChildProcess directly.
  Introduce mock adapter instead. This is the biggest test migration.
- `turn-delivery.test.ts` (513 lines) — Same pattern, mock adapter.
- `stop-lifecycle.test.ts` (242 lines) — Same.
- `session-spawn-*.test.ts` (444 lines) — Keep as-is (testing RpcAdapter internals).

**Strategy for test migration:**
1. Create `tests/helpers/mock-adapter.ts` that implements `SessionAdapter`
2. Tests that verify SessionManager behavior use mock adapter
3. Tests that verify RPC translation behavior keep testing RpcSessionAdapter directly
4. Both adapter implementations must produce identical ServerMessage output

**Validation:**
```bash
npm test  # all 1038 tests must pass
./scripts/check-protocol.sh  # protocol unchanged
```

### 2.2 — Adapter conformance test suite

New test file: `tests/adapter-conformance.test.ts`

Tests that run against the `SessionAdapter` interface (not a specific impl):
- Start session -> receive `state` event with status `ready`
- Send prompt -> receive `agent_start`, `text_delta`*, `agent_end`, `message_end`
- Send abort -> receive appropriate stop lifecycle
- Extension UI request -> forwarded, response -> routed back
- Session state queries return correct shape

Run against both `RpcSessionAdapter` and (later) `SdkSessionAdapter`.

Initially: only `RpcSessionAdapter` implementation. This proves the interface.

---

## Phase 3: SDK Session Adapter (high value, high risk)

**Goal:** Implement `SdkSessionAdapter` using `createAgentSession()`.

### 3.1 — SdkSessionAdapter implementation

New file: `sdk-session-adapter.ts`

```typescript
import {
  createAgentSession,
  DefaultResourceLoader,
  AuthStorage,
  ModelRegistry,
  SessionManager as PiSessionManager,
  type AgentSession,
  type AgentSessionEvent,
} from "@mariozechner/pi-coding-agent";

export class SdkSessionAdapter implements SessionAdapter {
  private session: AgentSession | null = null;
  private unsubscribe: (() => void) | null = null;

  async start(session: Session, workspace?: Workspace): Promise<void> {
    const loader = new DefaultResourceLoader({
      cwd: workspace?.hostMount || homedir(),
      additionalExtensionPaths: resolveExtensions(workspace),
      // ...
    });
    await loader.reload();

    const { session: piSession } = await createAgentSession({
      resourceLoader: loader,
      model: resolveModel(session.model),
      sessionManager: session.piSessionFile
        ? PiSessionManager.open(session.piSessionFile)
        : PiSessionManager.create(cwd),
      // ...
    });

    this.session = piSession;
    this.unsubscribe = piSession.subscribe((event) => {
      this.translateAndBroadcast(event);
    });
  }

  // ...
}
```

### 3.2 — SDK Event -> ServerMessage translation

New file: `sdk-event-adapter.ts`

Translates `AgentSessionEvent` to `ServerMessage[]`. This is the SDK equivalent
of `session-protocol.ts` but much thinner because:
- Events are typed (no `any`)
- No partialResult replace->delta conversion needed (SDK may handle this)
- No RPC correlation needed
- No process readiness detection needed

**Critical test:** The output for identical agent behavior must produce identical
`ServerMessage` sequences. Verify with:

1. **Protocol snapshot test** — `protocol-snapshots.test.ts` unchanged
2. **Pi event replay test** — Create SDK-equivalent replay that feeds the
   same scenarios and asserts identical output
3. **Adapter conformance test** — From Phase 2.2, run against SdkSessionAdapter

### 3.3 — In-process permission gate

Replace the TCP socket + pi extension with a direct extension factory:

```typescript
const gateExtension = (pi: ExtensionAPI) => {
  pi.on("tool_call", async (event) => {
    const decision = await gate.evaluate(sessionId, {
      tool: event.toolName,
      input: event.input,
      toolCallId: event.toolCallId,
    });
    if (decision.action === "deny") {
      return { block: true, reason: decision.reason };
    }
    if (decision.action === "ask") {
      const approval = await gate.requestApproval(sessionId, event);
      if (approval.action === "deny") {
        return { block: true, reason: approval.reason };
      }
    }
  });
};
```

This eliminates:
- `gate.ts` TCP server management (~200 lines)
- `extensions/permission-gate/index.ts` (~250 lines)
- TCP heartbeat, guard state machine, socket lifecycle

The `GateServer` class still exists but its `createSessionSocket`/`destroySessionSocket`
methods are replaced with direct method calls. Policy evaluation, rule store,
audit log are unchanged.

**Files deleted:** `extensions/permission-gate/index.ts`, TCP portions of `gate.ts`
**Files changed:** `gate.ts` (simplify to direct API), `sdk-session-adapter.ts`

**Tests affected:**
- `gate.test.ts` (440 lines) — Remove TCP-specific tests, keep policy/approval tests
- `gate-cleanup.test.ts` — Simplify or remove

**Validation:**
```bash
npm test -- tests/gate.test.ts tests/gate-cleanup.test.ts
npm test -- tests/adapter-conformance.test.ts  # gate behavior via adapter
```

### 3.4 — Feature flag: adapter selection

Config option in `ServerConfig`:

```typescript
sessionAdapter?: "rpc" | "sdk";  // default: "rpc"
```

Both adapters coexist. Default remains `rpc`. Switch to `sdk` for testing.
This is the safety net — if SDK adapter has issues, flip back to RPC.

**Validation:**
```bash
# Run full suite with SDK adapter
OPPI_SESSION_ADAPTER=sdk npm test
# Run E2E with SDK adapter
OPPI_SESSION_ADAPTER=sdk npm run test:e2e:lmstudio:contract
```

---

## Phase 4: Extension + Skill Loader Simplification

**Goal:** Replace custom scanning with `DefaultResourceLoader`.

### 4.1 — Extension resolution via ResourceLoader

**Current:** `extension-loader.ts` scans `~/.pi/agent/extensions/` manually.
**New:** Use `DefaultResourceLoader` discovery, filter by workspace config.

The SDK already does exactly this scanning. We only need the workspace filtering
logic (which extensions are enabled for this workspace).

**Files changed:** `extension-loader.ts` (simplify to thin filter)
**Tests affected:** `extension-loader.test.ts`

### 4.2 — Skill registry scanning via ResourceLoader

**Current:** `SkillRegistry.scan()` reimplements pi's skill discovery.
**New:** Use `DefaultResourceLoader.getSkills()` for discovery.

Keep `UserSkillStore` (custom skill CRUD — no pi equivalent).
Keep `SkillRegistry` as a wrapper that merges SDK-discovered + user skills.

**Files changed:** `skills.ts` (replace scan internals)
**Tests affected:** `skills.test.ts`, `skills-api.test.ts`

**Validation:**
```bash
npm test -- tests/skills.test.ts tests/skills-api.test.ts tests/extension-loader.test.ts
```

---

## Phase 5: Cleanup + RPC Removal

**Goal:** Remove the RPC code path once SDK adapter is proven.

### 5.1 — Remove feature flag, make SDK the only adapter

**Prerequisite:** SDK adapter has been running in production for at least 2 weeks
with no regressions.

### 5.2 — Delete RPC artifacts

**Files to delete:**
- `rpc-session-adapter.ts`
- `session-spawn.ts` (391 lines)
- `session-protocol.ts` (558 lines)
- `extensions/permission-gate/` directory

**Tests to delete:**
- `session-spawn-host.test.ts` (307 lines)
- `session-spawn-proc-handlers.test.ts` (61 lines)
- `session-spawn-resolve.test.ts` (76 lines)
- `pi-event-replay.test.ts` (350 lines) — replaced by SDK replay test
- RPC-specific sections of `session-lifecycle.test.ts`

### 5.3 — Simplify SessionManager

With adapter abstraction and only one impl, inline the adapter if desired.
Remove `safeStdinWrite`, `ChildProcess` imports, `rpcIdCounter`, `pendingResponses`.

### 5.4 — Simplify gate.ts

Remove TCP server code, socket management, heartbeat timers.
`GateServer` becomes a pure evaluation + approval tracking service.

**Validation (final):**
```bash
npm run check && npm test
./scripts/check-protocol.sh
npm run test:e2e:lmstudio:contract
```

---

## Testing Strategy Per Phase

### Gate: Tests That Must Pass at Every Phase

These are the non-negotiable gates. Run after every phase completion:

```bash
# 1. Type check + lint + format
npm run check

# 2. All unit/component tests
npm test

# 3. Protocol contract (iOS compatibility)
./scripts/check-protocol.sh
```

### Phase-Specific Test Strategies

| Phase | New Tests | Modified Tests | Deleted Tests |
|-------|-----------|---------------|---------------|
| 0 | None | None | None |
| 1.1 | None | Integration (model endpoint) | None |
| 1.2 | SDK mapping tests | `local-sessions.test.ts` | None |
| 2.1 | `mock-adapter.ts` helper | `session-lifecycle.test.ts`, `turn-delivery.test.ts`, `stop-lifecycle.test.ts` | None |
| 2.2 | `adapter-conformance.test.ts` | None | None |
| 3.1-3.2 | `sdk-session-adapter.test.ts`, `sdk-event-adapter.test.ts` | None | None |
| 3.3 | Gate direct-call tests | `gate.test.ts` | TCP-specific gate tests |
| 3.4 | Feature flag tests | None | None |
| 4 | None | `extension-loader.test.ts`, `skills.test.ts` | None |
| 5 | None | Simplify lifecycle tests | RPC spawn tests, pi-event-replay |

### Adapter Conformance Tests (Phase 2.2, critical)

These tests define the contract between `SessionManager` and any adapter:

```
adapter-conformance.test.ts
├── start
│   ├── resolves to "ready" session
│   ├── restores session from piSessionFile
│   └── applies workspace model/thinking prefs
├── prompt
│   ├── emits agent_start, text_delta*, agent_end, message_end
│   ├── emits tool_start, tool_output*, tool_end for tool calls
│   ├── emits thinking_delta for thinking models
│   └── updates session.status to busy then ready
├── steer
│   ├── rejects when not streaming
│   └── delivers interrupt during active turn
├── follow_up
│   ├── rejects when not streaming
│   └── delivers after agent finishes
├── abort
│   └── stops current turn, session stays alive
├── stop
│   └── kills session process/disposal
├── getState
│   └── returns model, thinkingLevel, sessionFile, isStreaming
├── extension_ui
│   ├── forwards select/confirm/input to callback
│   └── routes response back to extension
└── permission_gate
    ├── intercepts tool_call
    ├── routes to policy engine
    ├── forwards ask -> phone -> response
    └── learned rules persist
```

### Protocol Snapshot Stability

`protocol-snapshots.test.ts` is the iOS compatibility contract. It must pass
unchanged through every phase. The test generates `protocol/server-messages.json`
which iOS tests decode.

**Rule:** If this test fails, the migration introduced a protocol break. Fix the
adapter, never change the snapshot.

### E2E Validation Cadence

Run at phase boundaries (not every commit):

```bash
# After Phase 1 (model + local sessions)
npm run test:e2e:lmstudio:contract

# After Phase 2 (adapter abstraction)
npm run test:e2e:lmstudio:contract

# After Phase 3 (SDK adapter, run with both adapters)
OPPI_SESSION_ADAPTER=rpc npm run test:e2e:lmstudio:contract
OPPI_SESSION_ADAPTER=sdk npm run test:e2e:lmstudio:contract

# After Phase 4 (extension/skill loader)
npm run test:e2e:lmstudio:contract

# After Phase 5 (cleanup)
npm run test:e2e:lmstudio:contract  # SDK only
```

---

## Estimated Effort

| Phase | Effort | Lines changed | Lines removed | Risk |
|-------|--------|--------------|---------------|------|
| 0 | 1 day | ~100 (spike + interface) | 0 | None |
| 1 | 1-2 days | ~200 | ~400 | Low |
| 2 | 2-3 days | ~600 (refactor + tests) | 0 | Medium |
| 3 | 3-5 days | ~800 (adapter + gate) | ~300 | High |
| 4 | 1-2 days | ~200 | ~300 | Low |
| 5 | 1 day | ~50 | ~1,200 | Low |
| **Total** | **~10-14 days** | | **~2,200 net reduction** | |

## Decision Points

### After Phase 0 spike:
- Are SDK events shape-compatible enough? If major divergence, reassess scope.
- Does `createAgentSession()` support all the session options we need?

### After Phase 2:
- Is the adapter abstraction clean? Does it feel natural?
- Are the conformance tests comprehensive enough?

### After Phase 3 with feature flag:
- Has SDK adapter been stable for 2+ weeks in daily use?
- Any edge cases not caught by tests?
- Ready to remove RPC path?

---

## Open Questions

1. **Process isolation:** SDK runs pi in-process. A bad tool execution or
   extension crash could kill the server. Options:
   - Accept it (extensions are trusted, tools are sandboxed by pi)
   - Add Node.js `worker_threads` isolation later if needed
   - Keep RPC as a fallback adapter for untrusted environments

2. **SDK version pinning:** How tightly to pin `@mariozechner/pi-coding-agent`?
   Pi is actively developed. Options:
   - Pin exact version, upgrade deliberately
   - Use `^` range, test on CI before upgrading

3. **Session file location:** SDK's `SessionManager.create(cwd)` puts sessions
   in `~/.pi/agent/sessions/`. We currently track `piSessionFile` on our Session
   object. Need to verify the SDK respects our session path preferences.

4. **Extension discovery suppression:** We use `--no-extensions` + explicit
   `--extension` args. SDK equivalent is `DefaultResourceLoader` with no
   auto-discovery + explicit paths. Need to verify we can fully control
   which extensions load.

5. **Multiple concurrent sessions:** SDK creates one `AgentSession` per call.
   We need multiple concurrent sessions (one per workspace). Need to verify
   no singleton state conflicts in the SDK.
