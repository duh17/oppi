# Oppi Test Requirements Matrix

Last updated: 2026-02-26
Owner: Oppi maintainers (iOS + server)

This matrix tracks core product requirements/invariants against current test coverage.

Status legend:
- **covered**: invariant has direct tests on at least one side and no known blind spot
- **partial**: tests exist but leave meaningful edge cases or cross-side gaps
- **gap**: no targeted test currently mapped

## Requirements / Invariants Coverage

| ID | Requirement / Invariant | Current iOS test file(s) | Current server test file(s) | Status | Notes |
|---|---|---|---|---|---|
| RQ-PROTO-001 | Protocol decoding is forward-compatible (unknown message types are tolerated) | `ios/OppiTests/Protocol/ServerMessageTests.swift`, `ios/OppiTests/Protocol/ProtocolSnapshotTests.swift` | `server/tests/protocol-snapshots.test.ts`, `server/tests/pi-events.test.ts` | covered | Contract snapshots exist on both sides; keep snapshot updates paired with protocol changes. |
| RQ-PROTO-002 | Client/server message schemas remain synchronized for core message families | `ios/OppiTests/Protocol/ClientMessageTests.swift`, `ios/OppiTests/Protocol/ServerConnectionTypesTests.swift` | `server/tests/session-protocol.test.ts`, `server/tests/ws-message-handler.test.ts` | partial | Good coverage for known types; add explicit negative tests for schema drift across versioned fields. |
| RQ-WS-001 | WebSocket lifecycle handles connect, disconnect, reconnect, and recovery without session corruption | `ios/OppiTests/Network/ServerConnectionLifecycleTests.swift`, `ios/OppiTests/Network/ServerConnectionForegroundRecoveryTests.swift`, `ios/OppiTests/Network/StreamRecoveryTests.swift` | `server/tests/user-stream-websocket.test.ts`, `server/tests/session-lifecycle.test.ts`, `server/tests/stop-lifecycle.test.ts` | covered | Core lifecycle/recovery paths are exercised on both sides. |
| RQ-WS-002 | Concurrent/rapid WS command flows do not reorder or duplicate turn semantics | `ios/OppiTests/Network/ServerConnectionStreamTests.swift`, `ios/OppiTests/Network/ReliabilityTests.swift` | `server/tests/ws-command-race.test.ts`, `server/tests/turn-dedupe.test.ts`, `server/tests/turn-delivery.test.ts` | partial | Race/dedupe exists server-side; iOS needs more deterministic high-frequency ordering assertions. |
| RQ-ROUTE-001 | Server API routing is stable: expected routes respond, unknown routes fail deterministically | `ios/OppiTests/Network/APIClientTests.swift` | `server/tests/api-routes.test.ts`, `server/tests/routes-modules.test.ts`, `server/tests/server-integration.test.ts` | covered | Route-level contract is tested; keep errors stable for client handling. |
| RQ-ROUTE-002 | Workspace/session routing binds events to the correct server/workspace/session scope | `ios/OppiTests/Network/ServerConnectionRoutingTests.swift`, `ios/OppiTests/Stores/WorkspaceStoreTests.swift`, `ios/OppiTests/Network/MultiServerStoreTests.swift` | `server/tests/workspace-crud.test.ts`, `server/tests/workspace-runtime.test.ts`, `server/tests/session-context.test.ts` | partial | Multi-server routing exists; add more mixed-session replay/misroute regressions. |
| RQ-TL-001 | Timeline reducer is deterministic for streaming deltas and preserves ordering invariants | `ios/OppiTests/Timeline/TimelineReducerStreamingTests.swift`, `ios/OppiTests/Network/DeltaCoalescerTests.swift`, `ios/OppiTests/Timeline/TimelineReducerTests.swift` | `server/tests/message-end.test.ts`, `server/tests/tool-events.test.ts` | covered | iOS reducer invariants are broad; server event sequencing has targeted checks. |
| RQ-TL-002 | Timeline rendering avoids no-op churn (no render-version bump when content is unchanged) | `ios/OppiTests/Timeline/TimelineReducerStreamingTests.swift`, `ios/OppiTests/Stores/ToolOutputStoreTests.swift` | `server/tests/mobile-renderer.test.ts` | partial | Recent regression test exists on iOS; server does not currently assert render-no-op invariants end-to-end. |
| RQ-PERM-001 | Permission gate enforces allow/deny policy and pending-approval lifecycle correctly | `ios/OppiTests/Network/ServerConnectionPermissionTests.swift`, `ios/OppiTests/Platform/PermissionApprovalPolicyTests.swift`, `ios/OppiTests/Timeline/TimelineReducerPermissionTests.swift` | `server/tests/gate.test.ts`, `server/tests/policy-approval.test.ts`, `server/tests/permissions-pending-api.test.ts` | covered | Core approval flows and policy precedence are exercised. |
| RQ-PERM-002 | Permission UX routing (deep link/notification) lands on correct approval context | `ios/OppiTests/Platform/PermissionDeepLinkTests.swift`, `ios/OppiTests/Platform/PermissionNotificationServiceTests.swift` | `server/tests/live-activity.test.ts`, `server/tests/push-redaction.test.ts` | partial | Strong iOS behavior coverage; server side is mostly adjacent transport/notification checks. |
| RQ-OFFLINE-001 | Offline/foreground transitions recover safely and preserve user-visible session continuity | `ios/OppiTests/Network/ForegroundReconnectGateTests.swift`, `ios/OppiTests/Network/ServerConnectionForegroundRecoveryTests.swift`, `ios/OppiTests/Stores/RestorationStateTests.swift` | `server/tests/user-stream-replay.test.ts`, `server/tests/local-sessions.test.ts` | partial | Recovery exists, but explicit airplane-mode/offline UX assertions are limited. |
| RQ-OFFLINE-002 | Explicit offline UX states (banner, disabled actions, retry affordance) are tested | `ios/OppiUITests/UIHangHarnessUITests.swift` | _(none mapped)_ | gap | Add dedicated offline UX scenario tests (UI + integration) and link regressions here. |

## Bug-bash Traceability

Use this section to map bug-bash findings to explicit invariants and permanent regression tests.

Reference workflow: [`docs/testing/bug-bash-playbook.md`](./bug-bash-playbook.md)

### Mapping fields

- **Bug ID**: tracker ID (issue/todo)
- **Invariant violated**: `RQ-*` requirement ID
- **Repro artifact**: trace, video, logs, transcript, or steps doc
- **Regression test path**: concrete iOS/server test file + test name
- **Status**: open / fixed / verified

### Template

| Bug ID | Invariant violated | Repro artifact | Regression test path | Status | Notes |
|---|---|---|---|---|---|
| BUG-YYYYMMDD-001 | RQ-TL-002 | `docs/testing/bug-bash/fixtures/<BUG-ID>/` | `ios/OppiTests/Timeline/TimelineReducerStreamingTests.swift :: <testName>` | open | Add server-side regression if protocol/event ordering contributed. |

## Update Process

1. For every feature/protocol change, map affected invariants (`RQ-*`) before merge.
2. If status is `partial` or `gap`, add a follow-up TODO with owner and target test path.
3. For every bug-bash defect, add one mapping row and keep it until regression test is merged and verified.
4. Revisit this matrix during release gate prep and update statuses with concrete test evidence.
