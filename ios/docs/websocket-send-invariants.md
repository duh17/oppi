# WebSocket send invariants (iOS ↔ pi-remote)

This document captures the reliability contract for chat sends.

## Scope

Applies to `prompt`, `steer`, and `follow_up` sends in:
- `ios/PiRemote/Core/Networking/ServerConnection.swift`
- `pi-remote/src/sessions.ts`

## Invariants

1. **Bounded send wait**
   - If socket is not connected, send waits only up to configured timeout.
   - No unbounded wait on `.connecting` / `.reconnecting`.

2. **Bounded ACK wait**
   - After outbound write, ACK wait is bounded (`SendAckError.timeout`).
   - Waiter is explicitly resolved on timeout to avoid task-group hangs.

3. **Idempotent retry identity**
   - Retries reuse the same `(requestId, clientTurnId)` per logical send.
   - Server dedupe is keyed by `clientTurnId`.

4. **Exactly-once persistence / at-most-once dispatch**
   - Duplicate retries do not create duplicate user-message persistence.
   - Duplicate retries do not re-dispatch turn commands to pi.

5. **Stage progression visibility**
   - Server emits staged `turn_ack` (`accepted`, `dispatched`, `started`).
   - iOS tracks and renders stage transitions in composer send progress.

6. **Deterministic terminal outcomes**
   - A logical send always resolves to explicit success or explicit error.
   - No silent drop/no-op completion path.

## Test coverage map

### iOS
- `ServerConnectionTests.sendRetryReusesClientTurnId`
- `ServerConnectionTests.sendAckUsesTurnAckStages`
- `ServerConnectionTests.sendAckTimeoutForPromptSteerAndFollowUp`
- `ServerConnectionTests.sendPromptChurnAlwaysResolvesWithoutSilentDrop`
- `ChatActionHandlerTests.sendPromptTracksAckStageProgress`
- `ChatActionHandlerTests.sendPromptFailureClearsAckStage`

### server
- `turn-delivery.test.ts` (retry storm + conflict + stage replay)
- `turn-dedupe.test.ts`

## Notes

- Delivery completion for the send API is currently anchored at `dispatched`.
- `started` is still surfaced as a later stage event and UI progress signal.
