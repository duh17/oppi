# Oppi Test Requirements Matrix

Last updated: 2026-03-03
Owner: Oppi maintainers (iOS + server)

This matrix tracks core product requirements/invariants against current test coverage.

Gate policy for when tests are required on PR vs nightly is defined in:
- [`docs/testing/README.md`](./README.md)

Status legend:
- **covered**: invariant has direct tests on at least one side and no known blind spot
- **partial**: tests exist but leave meaningful edge cases or cross-side gaps
- **gap**: no targeted test currently mapped

## Requirements / Invariants Coverage

| ID | Requirement / Invariant | Current iOS test file(s) | Current server test file(s) | Status | Notes |
|---|---|---|---|---|---|
| RQ-PROTO-001 | Protocol decoding is forward-compatible (unknown message types are tolerated) | `ios/OppiTests/Protocol/ServerMessageTests.swift`, `ios/OppiTests/Protocol/ProtocolSnapshotTests.swift` | `server/tests/protocol-snapshots.test.ts`, `server/tests/pi-events.test.ts` | covered | Contract snapshots exist on both sides; keep snapshot updates paired with protocol changes. |
| RQ-PROTO-002 | Client/server message schemas remain synchronized for core message families | `ios/OppiTests/Protocol/ClientMessageTests.swift`, `ios/OppiTests/Protocol/ServerConnectionTypesTests.swift` | `server/tests/session-protocol.test.ts`, `server/tests/ws-message-handler.test.ts`, `server/tests/protocol-schema-drift.test.ts` | covered | Schema drift tests cover extra fields, missing optionals, type discriminator stability, and cross-platform invariants. |
| RQ-WS-001 | WebSocket lifecycle handles connect, disconnect, reconnect, and recovery without session corruption | `ios/OppiTests/Network/ServerConnectionLifecycleTests.swift`, `ios/OppiTests/Network/ServerConnectionForegroundRecoveryTests.swift`, `ios/OppiTests/Network/StreamRecoveryTests.swift` | `server/tests/user-stream-websocket.test.ts`, `server/tests/session-lifecycle.test.ts`, `server/tests/stop-lifecycle.test.ts` | covered | Core lifecycle/recovery paths are exercised on both sides. |
| RQ-WS-002 | Concurrent/rapid WS command flows do not reorder or duplicate turn semantics | `ios/OppiTests/Network/ServerConnectionStreamTests.swift`, `ios/OppiTests/Network/ReliabilityTests.swift` | `server/tests/ws-command-race.test.ts`, `server/tests/turn-dedupe.test.ts`, `server/tests/turn-delivery.test.ts`, `server/tests/ws-ordering-invariants.test.ts` | covered | Server-side: monotonic seq ordering, 1000-event burst, notification-level classification, catch-up replay validation. iOS: existing stream/reliability tests. |
| RQ-ROUTE-001 | Server API routing is stable: expected routes respond, unknown routes fail deterministically | `ios/OppiTests/Network/APIClientTests.swift` | `server/tests/api-routes.test.ts`, `server/tests/routes-modules.test.ts`, `server/tests/server-integration.test.ts` | covered | Route-level contract is tested; keep errors stable for client handling. |
| RQ-ROUTE-002 | Workspace/session routing binds events to the correct server/workspace/session scope | `ios/OppiTests/Network/ServerConnectionRoutingTests.swift`, `ios/OppiTests/Stores/WorkspaceStoreTests.swift`, `ios/OppiTests/Network/MultiServerStoreTests.swift` | `server/tests/workspace-crud.test.ts`, `server/tests/workspace-runtime.test.ts`, `server/tests/session-context.test.ts`, `server/tests/session-routing-isolation.test.ts` | covered | Event recording isolation, subscriber callback isolation, cross-workspace scoping, orphan event handling, and sessionId stamping invariants. |
| RQ-TL-001 | Timeline reducer is deterministic for streaming deltas and preserves ordering invariants | `ios/OppiTests/Timeline/TimelineReducerStreamingTests.swift`, `ios/OppiTests/Network/DeltaCoalescerTests.swift`, `ios/OppiTests/Timeline/TimelineReducerTests.swift` | `server/tests/message-end.test.ts`, `server/tests/tool-events.test.ts` | covered | iOS reducer invariants are broad; server event sequencing has targeted checks. |
| RQ-TL-002 | Timeline rendering avoids no-op churn (no render-version bump when content is unchanged) | `ios/OppiTests/Timeline/TimelineReducerStreamingTests.swift`, `ios/OppiTests/Stores/ToolOutputStoreTests.swift` | `server/tests/mobile-renderer.test.ts`, `server/tests/render-noop-invariant.test.ts` | covered | Server renderer idempotency proven for all built-in tools (renderCall + renderResult). Segment structural invariants (style set, non-empty text) enforced. |
| RQ-TL-003 | Expanded tool rows never compete with outer timeline for vertical scroll ownership (anchored + detached). | `ios/OppiTests/Timeline/ToolExpandScrollMatrixTests.swift`, `ios/OppiTests/Timeline/ToolTimelineRowModeDispatchTests.swift`, `ios/OppiTests/Timeline/WriteExpandScrollTests.swift` | _(none mapped)_ | covered | Matrix now asserts inner vertical drift remains pinned while outer scroll remains the sole vertical owner. |
| RQ-TL-004 | Timeline hot-path complexity + projection/reducer contracts stay within budget and deterministic semantics. | `ios/OppiTests/Timeline/TimelineReducerInvariantTests.swift`, `ios/OppiTests/Timeline/ToolPresentationConfigTests.swift`, `ios/OppiTests/Timeline/TraceRenderingTests.swift` | _(none mapped)_ | covered | Guardrail tests enforce source-size budgets, batch partition equivalence, and projector/full-screen contract parity. |
| RQ-PERM-001 | Permission gate enforces allow/deny policy and pending-approval lifecycle correctly | `ios/OppiTests/Network/ServerConnectionPermissionTests.swift`, `ios/OppiTests/Platform/PermissionApprovalPolicyTests.swift`, `ios/OppiTests/Timeline/TimelineReducerPermissionTests.swift` | `server/tests/gate.test.ts`, `server/tests/policy-approval.test.ts`, `server/tests/permissions-pending-api.test.ts` | covered | Core approval flows and policy precedence are exercised. |
| RQ-PERM-002 | Permission UX routing (deep link/notification) lands on correct approval context | `ios/OppiTests/Platform/PermissionDeepLinkTests.swift`, `ios/OppiTests/Platform/PermissionNotificationServiceTests.swift` | `server/tests/live-activity.test.ts`, `server/tests/push-redaction.test.ts`, `server/tests/permission-routing.test.ts` | covered | Session-scoped pending decisions, cross-session isolation (resolving A preserves B), destroySessionGuard cleanup, buildPermissionMessage context fidelity, and LA bridge event routing. |
| RQ-OFFLINE-001 | Offline/foreground transitions recover safely and preserve user-visible session continuity | `ios/OppiTests/Network/ForegroundReconnectGateTests.swift`, `ios/OppiTests/Network/ServerConnectionForegroundRecoveryTests.swift`, `ios/OppiTests/Stores/RestorationStateTests.swift` | `server/tests/user-stream-replay.test.ts`, `server/tests/local-sessions.test.ts`, `server/tests/offline-recovery.test.ts` | covered | Full replay, partial replay, multi-turn history, tool permission flows, ring miss recovery, multiple reconnect cycles, and in-flight tool execution recovery. |
| RQ-OFFLINE-002 | Explicit offline UX states (banner, disabled actions, retry affordance) are tested | `ios/OppiUITests/UIHangHarnessUITests.swift` | `server/tests/offline-recovery.test.ts` | partial | Server-side: catchUpComplete signal paths (ring miss triggers banner, successful catch-up dismisses it, currentSeq cursor for state tracking, EventRing boundary conditions). iOS UI-level offline banner tests remain a gap. |

## Using this matrix with gate policy

- Use this matrix to decide **what must be tested** based on impacted invariants.
- Use [`README.md`](./README.md) to decide **when each lane must run** (PR vs nightly/release).
- If a change touches any `RQ-PROTO-*` invariant, run `./scripts/check-protocol.sh` on PR.

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
