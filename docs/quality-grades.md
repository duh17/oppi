# Quality Grades

Last updated: 2026-03-01
Owner: Oppi maintainers (iOS + server)

This complements `docs/testing/requirements-matrix.md` with per-domain health grades for agent effectiveness.

## Grade scale

- **A**: All dimensions green, agent can work autonomously
- **B**: Minor gaps, agent needs some guidance
- **C**: Significant gaps, agent likely to make mistakes
- **D**: Major issues, human must drive

## Server

### Session lifecycle — **B**
- **Test coverage:** **covered**
- **Doc freshness:** **current**
- **Architecture compliance:** **clean**
- **Known tech debt:** **tracked**
- **Agent legibility:** **needs context**
- **Evidence:** `server/tests/session-lifecycle.test.ts`, `server/tests/stop-lifecycle.test.ts`, `server/tests/lifecycle-locks.test.ts`; architecture map in `ARCHITECTURE.md` (session coordinator inventory, lifecycle path). Debt is mostly reconnect/offline-adjacent behavior tracked in `docs/testing/requirements-matrix.md` (`RQ-OFFLINE-001`: partial).

### WebSocket transport — **B**
- **Test coverage:** **partial**
- **Doc freshness:** **current**
- **Architecture compliance:** **minor drift**
- **Known tech debt:** **tracked**
- **Agent legibility:** **needs context**
- **Evidence:** `server/tests/user-stream-websocket.test.ts`, `server/tests/ws-command-race.test.ts`, `server/tests/ws-invariants.test.ts`, `server/tests/ws-stress.test.ts`; architecture flow in `ARCHITECTURE.md` (`stream.ts`, `ws-message-handler.ts`). `docs/testing/requirements-matrix.md` marks `RQ-WS-002` as partial.

### Policy engine — **B**
- **Test coverage:** **covered**
- **Doc freshness:** **current**
- **Architecture compliance:** **clean**
- **Known tech debt:** **none**
- **Agent legibility:** **needs context**
- **Evidence:** `server/tests/policy.test.ts`, `server/tests/policy-precedence-golden.test.ts`, `server/tests/policy-fuzz.test.ts`, `server/tests/gate.test.ts`; docs in `server/docs/policy-engine.md`, invariants in `docs/golden-principles.md` (declarative policy rule).

### Storage — **B**
- **Test coverage:** **covered**
- **Doc freshness:** **stale**
- **Architecture compliance:** **clean**
- **Known tech debt:** **untracked**
- **Agent legibility:** **needs context**
- **Evidence:** `server/tests/storage-single-user.test.ts`, `server/tests/storage-flat-layout.test.ts`, `server/tests/storage-session-metadata.test.ts`, `server/tests/storage-permissions.test.ts`. Architecture references exist (`ARCHITECTURE.md`, `server/src/storage.ts`), but no dedicated storage behavior doc beyond config schema (`server/docs/config-schema.md`).

### API routes — **B**
- **Test coverage:** **partial**
- **Doc freshness:** **stale**
- **Architecture compliance:** **clean**
- **Known tech debt:** **tracked**
- **Agent legibility:** **easy**
- **Evidence:** `server/tests/api-routes.test.ts`, `server/tests/routes-modules.test.ts`, `server/tests/server-integration.test.ts`; route inventory in `ARCHITECTURE.md`. `docs/testing/requirements-matrix.md` flags scoped routing (`RQ-ROUTE-002`) as partial.

### Push/live activity — **C**
- **Test coverage:** **partial**
- **Doc freshness:** **missing**
- **Architecture compliance:** **minor drift**
- **Known tech debt:** **tracked**
- **Agent legibility:** **needs context**
- **Evidence:** `server/tests/live-activity.test.ts`, `server/tests/push-redaction.test.ts`; high-level mention only in `ARCHITECTURE.md` (no dedicated push/live activity doc). `docs/testing/requirements-matrix.md` maps adjacent behavior (`RQ-PERM-002`) as partial.

## iOS

### Network layer (ServerConnection, API client) — **B**
- **Test coverage:** **partial**
- **Doc freshness:** **current**
- **Architecture compliance:** **minor drift**
- **Known tech debt:** **tracked**
- **Agent legibility:** **needs context**
- **Evidence:** `ios/OppiTests/Network/ServerConnectionLifecycleTests.swift`, `ios/OppiTests/Network/ServerConnectionStreamTests.swift`, `ios/OppiTests/Network/ServerConnectionForegroundRecoveryTests.swift`, `ios/OppiTests/Network/ReliabilityTests.swift`, `ios/OppiTests/Network/APIClientTests.swift`; architecture + event flow in `ARCHITECTURE.md`. Matrix marks `RQ-WS-002` and `RQ-OFFLINE-001` partial.

### Timeline (reducer, coalescer, rendering) — **B**
- **Test coverage:** **partial**
- **Doc freshness:** **current**
- **Architecture compliance:** **minor drift**
- **Known tech debt:** **tracked**
- **Agent legibility:** **needs context**
- **Evidence:** `ios/OppiTests/Timeline/TimelineReducerStreamingTests.swift`, `ios/OppiTests/Timeline/TimelineReducerInvariantTests.swift`, `ios/OppiTests/Timeline/ToolExpandScrollMatrixTests.swift`, `ios/OppiTests/Network/DeltaCoalescerTests.swift`, `ios/OppiTests/Timeline/TraceRenderingTests.swift`; docs in `docs/chat-rendering.md` and `ARCHITECTURE.md`. Matrix marks `RQ-TL-002` partial.

### Permissions UX — **B**
- **Test coverage:** **partial**
- **Doc freshness:** **missing**
- **Architecture compliance:** **clean**
- **Known tech debt:** **tracked**
- **Agent legibility:** **needs context**
- **Evidence:** `ios/OppiTests/Platform/PermissionDeepLinkTests.swift`, `ios/OppiTests/Platform/PermissionNotificationServiceTests.swift`, `ios/OppiTests/Platform/PermissionApprovalPolicyTests.swift`, `ios/OppiTests/Network/ServerConnectionPermissionTests.swift`, `ios/OppiTests/Timeline/TimelineReducerPermissionTests.swift`; no dedicated permissions UX doc in `docs/` beyond matrix references.

### Stores (session, workspace, permission) — **A**
- **Test coverage:** **covered**
- **Doc freshness:** **current**
- **Architecture compliance:** **clean**
- **Known tech debt:** **none**
- **Agent legibility:** **easy**
- **Evidence:** `ios/OppiTests/Stores/SessionStoreTests.swift`, `ios/OppiTests/Stores/WorkspaceStoreTests.swift`, `ios/OppiTests/Network/MultiServerStoreTests.swift`, `ios/OppiTests/Stores/MessageQueueStoreTests.swift`; store isolation invariants in `docs/golden-principles.md` and module map in `ARCHITECTURE.md`.

### Chat UI (chat, settings, onboarding) — **C**
- **Test coverage:** **partial**
- **Doc freshness:** **stale**
- **Architecture compliance:** **needs refactor**
- **Known tech debt:** **tracked**
- **Agent legibility:** **opaque**
- **Evidence:** strong timeline/UI harness coverage in `ios/OppiUITests/UIHangHarnessUITests.swift` and `ios/OppiTests/Timeline/*`, plus chat session/action tests (`ios/OppiTests/Chat/ChatSessionManagerTests.swift`, `ios/OppiTests/Chat/ChatActionHandlerTests.swift`), but little direct test mapping for Settings/Onboarding behavior. `docs/testing/requirements-matrix.md` has explicit UI gap (`RQ-OFFLINE-002`).

## Review cadence

- Reassess monthly, or after major architecture/protocol changes.
- Prioritize improvement work in **C/D** domains first.
- Keep this file and `docs/testing/requirements-matrix.md` in sync when statuses shift.
