{
  "id": "ec1d9be8",
  "title": "Stabilize iOS↔server WebSocket (TDD): eliminate send freezes",
  "tags": [
    "ios",
    "pi-remote",
    "websocket",
    "reliability",
    "tdd",
    "server"
  ],
  "status": "open",
  "created_at": "2026-02-09T15:43:20.244Z",
  "assigned_to_session": "c67a264c-354a-4063-8376-998d14b3fe1a"
}

## Problem
Intermittent chat freeze on iOS when tapping **Send** after typing a message. In affected cases, prompt is not received by server (`/ws` logs show abnormal disconnect `code=1006` around interaction windows).

## Goal
Make WebSocket behavior deterministic and resilient so send is always one of:
1. delivered, or
2. fails fast with explicit UI error + input restored.

No silent hangs. No non-deterministic send dead zones.

## Constraints
- Use **TDD first**: reproduce bug with failing tests before changing runtime behavior.
- Keep protocol compatibility with current server/iOS message types.
- Preserve one-active-session policy unless explicitly redesigned.

## Phase 1 — Characterization tests (red)
- [ ] Add failing tests for `WebSocketClient` reconnect/send edge cases:
  - send while `.connecting`
  - send while `.reconnecting`
  - socket drops (`1006`) between tap and send completion
  - ping watchdog + reconnect race
- [ ] Add failing tests for `ChatActionHandler.sendPrompt`:
  - message restore on async send failure
  - no UI deadlock when reconnect callback fires
- [ ] Add failing tests for `ChatSessionManager` lifecycle races:
  - stale `onTermination` / generation mismatch cannot kill new stream
  - reconnect loop doesn’t thrash active session
- [ ] Add integration test harness (mock WS server) that force-drops connections mid-turn and verifies eventual recovery semantics.

## Phase 2 — Instrumentation + diagnostics
- [ ] Add structured counters/timestamps for:
  - send attempt, send enqueue, send success/failure
  - reconnect attempt/result
  - disconnect reason/code
- [ ] Add trace IDs to correlate one user tap → WS write → server receive.
- [ ] Keep persisted logs at `.error` only where required, but avoid high-volume log spam on hot paths.

## Phase 3 — Fixes (green)
- [ ] Refactor send path to avoid hangs during reconnect windows (queue or bounded retry strategy).
- [ ] Eliminate reconnect/disconnect ping-pong from lifecycle races.
- [ ] Ensure UI state machine remains responsive while transport is degraded.
- [ ] Harden timeout behavior: bounded wait + deterministic fallback.

## Phase 4 — Regression protection
- [ ] Add long-run soak test (reconnect churn + repeated sends).
- [ ] Add explicit regression tests for any bugs discovered in phase 1.
- [ ] Document invariants for `WebSocketClient` and chat send flow.

## Acceptance criteria
- [ ] Under forced disconnect/reconnect, tapping Send never freezes UI.
- [ ] Prompt is either delivered or surfaced as explicit failure within bounded time.
- [ ] No silent message loss in tested reconnect scenarios.
- [ ] Full test suite passes (existing + new reliability tests).
- [ ] Manual validation on device: repeated foreground/background + send during reconnect behaves predictably.

## Initial evidence snapshot
- Active problematic session observed: `UGkuQ67T`
- Repeated server-side WS disconnects with code `1006`
- User reports: typed input visible but Send causes app freeze/non-deterministic no-op

## Execution plan (proposed)

### Slice A — Test seams (no behavior change)
- Add small dependency-injection seams so reliability tests are deterministic:
  - `WebSocketClient`: injectable transport + timeout config (wait/send/poll)
  - `ServerConnection`: hook for prompt-ack tracking in tests
- Keep production defaults unchanged.

### Slice B — Red tests (characterization)
- New `WebSocketClientTests.swift`:
  - send while `.connecting` (waits bounded, then sends)
  - send while `.reconnecting` (bounded outcome)
  - drop between tap and send completion (fails bounded)
  - ping watchdog + reconnect race (no stuck state)
- Expand `ChatActionHandlerTests.swift`:
  - async send failure restores input/images via callback path
  - reconnect callback fires exactly once per reconnectable failure
- Expand `ChatSessionManagerTests.swift`:
  - stale generation/onTermination cannot disconnect newer stream
  - reconnect trigger does not cause connect/disconnect thrash

### Slice C — Deterministic delivery/failure semantics
- Adopt request correlation for prompts:
  - iOS sends `requestId` on prompt/steer/follow_up
  - server emits `rpc_result` (`command: "prompt"|"steer"|"follow_up"`) when accepted/rejected
- iOS send path waits for ack with bounded timeout; if timeout/failure:
  - remove optimistic user row
  - restore composer text + images
  - emit explicit error row

### Slice D — Reconnect hardening
- Ensure only one reconnect path is active at a time (debounce/singleflight in manager/client).
- Bound all waits (no unbounded `await` on reconnect/send).
- Keep UI responsive during degraded transport.

### Slice E — Regression harness + manual validation
- Add WS churn integration harness (forced close/reconnect mid-turn).
- Run soak: repeated sends under reconnect churn; assert no silent drops.
- Manual device run: fg/bg cycles + send during reconnect windows.

## Progress update (session)

Completed in this pass:
- [x] Added fast-fail reliability tests for WebSocket send wait windows:
  - `sendWhileConnectingHonorsConfiguredWaitTimeout`
  - `sendWhileReconnectingHonorsConfiguredWaitTimeout`
- [x] Added ChatActionHandler async failure tests:
  - restore callback receives original text/images
  - reconnect callback fires once on reconnectable send failure
- [x] Wired ChatView composer restore on async send failure (`onAsyncFailure` now restores `inputText` + `pendingImages`).
- [x] Hardened WebSocketClient send wait behavior with configurable bounded timeouts (defaults now fail faster) + test seam for deterministic status testing.

Validation:
- Ran iOS targeted tests:
  - `ChatActionHandlerTests`
  - `ReliabilityTests`
- Result: pass (27 tests across the selected suites).

## Progress update (session 2)

Completed in this pass:
- [x] Implemented request/ack correlation for prompt path:
  - iOS `ServerConnection.sendPrompt/sendSteer/sendFollowUp` now sends `requestId` and awaits `rpc_result` ack with bounded timeout.
  - Added pending-ack waiter lifecycle + disconnect cleanup in `ServerConnection`.
- [x] Server now emits `rpc_result` for `prompt`/`steer`/`follow_up` when `requestId` is present (success + failure).
- [x] Prompt persistence on server now happens only after SessionManager accepts the prompt (avoids persisting failed sends).
- [x] Chat action steer path now uses acked `connection.sendSteer(...)`.

Validation:
- iOS targeted tests passed:
  - `ChatActionHandlerTests`
  - `ReliabilityTests`
  - `ServerConnectionTests`
- server typecheck passed:
  - `cd pi-remote && npx tsc --noEmit`

## Progress update (session 3)

Completed in this pass:
- [x] Added ChatSessionManager lifecycle race harness with scripted AsyncStream injection:
  - `staleGenerationCleanupDoesNotDisconnectNewerReconnectStream`
  - `staleCleanupSkipsDisconnectWhenSocketOwnershipMoved`
- [x] Added minimal test seam in `ChatSessionManager`:
  - `_streamSessionForTesting` to inject deterministic streams (no real WS required)
- [x] Added WebSocketClient ownership seam for lifecycle tests:
  - `_setConnectedSessionIdForTesting(_:)`

Validation:
- Ran targeted iOS suites:
  - `ChatSessionManagerTests`
  - `ChatActionHandlerTests`
  - `ReliabilityTests`
  - `ServerConnectionTests`
- Result: pass (53 tests in selected suites).

## Progress update (session 4)

Completed in this pass:
- [x] Added server-side load/reliability harness: `pi-remote/test-load-ws.ts`
  - HTTP benchmark: `/health` throughput + latency percentiles
  - WS benchmark: connect latency + `get_state` RTT under configurable forced-drop churn (`ws.terminate()` mid-flight)
  - Configurable via CLI/env (`--ws-drop-rate`, clients, connections, requests, timeouts)
- [x] Added npm script: `npm run test:load:ws`
- [x] Documented harness usage in root `README.md` under “Performance & Reliability Harnesses”.

Validation:
- `cd pi-remote && npx tsx test-load-ws.ts --help` ✅
- `cd pi-remote && npx tsc --noEmit` ✅
- Smoke run: `npx tsx test-load-ws.ts --http-duration-ms 1000 --http-workers 4`
  - observed ~30k req/s local `/health` with p95 ~0.17ms (host-local baseline).

2026-02-09 late PM: fixed a deterministic hang in ServerConnection ACK-timeout tests. Root cause: `sendWithAck` used `withThrowingTaskGroup` with `SendAckWaiter.wait()` (continuation-based, non-cancellation-aware). When timeout task threw, group canceled waiter but waiter never exited, so group drain could hang. Fix in `ios/PiRemote/Core/Networking/ServerConnection.swift`: on timeout catch, explicitly `waiter.resolve(.failure(timeout))` before leaving task group.

Also removed remaining real WS usage in unit tests to prevent orphan ping/reconnect loops:
- `ios/PiRemoteTests/BugBashTests.swift` `makeConnection()` now uses `_setActiveSessionIdForTesting` instead of `streamSession`.
- `ios/PiRemoteTests/ReliabilityTests.swift` `extensionDialogClearedOnSessionSwitch` now simulates switch with `disconnectSession()` + `_setActiveSessionIdForTesting("s2")`.

Validation:
- Single test: `sendAckTimeoutForPromptSteerAndFollowUp()` now passes (~0.37s).
- ACK trio (success/rejected/timeout) passes.
- `ServerConnectionTests` full suite passes.
- Combined focused suites pass without hang:
  - `ServerConnectionTests`
  - `ReliabilityTests`
  - `BugBashTests`
  (58 tests total, ~0.9s execution).

Validation follow-up (post-hang fix):

Ran additional targeted suites:
- `ChatActionHandlerTests`
- `ChatSessionManagerTests`
- `StreamRecoveryTests`

Result: 32 tests passed, no hang.

Then ran full iOS test suite:
- `xcodebuild -project PiRemote.xcodeproj -scheme PiRemote -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test`

Result: **565 tests passed in 46 suites**, no hangs/regressions observed in this run.

Additional flake soak (simulator):
- Repeated reliability-focused suites 3x in a loop:
  - `ServerConnectionTests`
  - `ReliabilityTests`
  - `BugBashTests`
  - `ChatSessionManagerTests`
  - `ChatActionHandlerTests`
- Each iteration passed (`75 tests / 5 suites`), no hangs across loops.

2026-02-09 follow-up: fixed `/compact` false-timeout regression in server RPC correlation.

Symptom observed from iOS:
- App showed `compact failed: RPC timeout: compact`.
- Server log showed `RECV compact` while session ready.

Root cause:
- pi can emit `response` errors without `id` for parse/validation failures (e.g. `Failed to parse command: Already compacted`).
- `SessionManager.sendRpcCommandAsync` waited on `pendingResponses[id]`; uncorrelated error never resolved waiter, leading to 30s timeout and misleading `rpc_result` timeout.

Fix:
- `pi-remote/src/sessions.ts` `handleRpcLine(...)` now handles all `response` events explicitly.
- For `response` without `id` and exactly one pending RPC command, attribute the failure to that pending command and reject immediately.
- Avoid duplicate broadcast paths for correlated responses; keep orphan/ambiguous errors surfaced as `error` events.

Validation:
- `npx tsc --noEmit` passed.
- Manual WS probe before fix: compact `rpc_result` failed after ~30s (`RPC timeout: compact`).
- Manual WS probe after fix: compact `rpc_result` failed in ~0.5s with actual error (`Failed to parse command: Already compacted`).

UX polish: normalized compact parse error messaging.

Change in `pi-remote/src/sessions.ts`:
- Added `normalizeRpcError(command, error)`.
- Strips noisy prefix `Failed to parse command:`.
- Special-cases compact parse failure `Already compacted` -> `Already compacted`.
- Applied normalization to both `rpc_result` failures and `response` handling path.

Validation:
- `npx tsc --noEmit` passed.
- Manual WS probe now returns `rpc_result compact ... error="Already compacted"` (~0.5s), no timeout and no raw parse prefix.

## 2026-02-09 incident follow-up (device log forensic)
Analyzed `/Users/chenda/Library/Logs/PiRemote/device/piremote-device-20260209-105501.txt` and correlated with server tmux logs + session artifacts for reported “new turn send hang”.

Findings:
- Two send attempts in this log (`10:50:27`, `10:53:50`) both completed full client send path:
  - `SEND tap` -> `SEND prompt appended` -> `WS send ... complete` -> `SEND prompt OK`
- Corresponding server receipts confirmed:
  - `RECV prompt` + `PROMPT sent to pi` for both turns.
- Prompts persisted in session state and pi JSONL transcript:
  - `~/.config/pi-remote/sessions/7AfAqNs9/t9iE9G1M.json`
  - `~/.pi/agent/sessions/--Users-chenda-workspace-pios--/2026-02-09T17-37-53-830Z_adbd53f5-0a2a-44b1-9df1-eeb6a906c0e2.jsonl`
- No client evidence of send-path failure in this capture (`SEND FAILED`, ack timeout, notConnected, prompt rejection, etc. absent).

Observed noise/perf context:
- During long busy windows, `ChatView` renderVersion logs are high-frequency while item count is mostly stable; can look like “hang” despite active processing.
- `1006` disconnects still occur post-turn; reconnect path appears to recover, but this remains a reliability/perception risk to harden in churn testing.

Conclusion for this incident:
- Not reproduced as transport/send failure in this log.
- Most likely user-perceived latency/state-visibility issue during busy/reconnect windows rather than prompt drop.

Next targeted work:
- Add/complete forced-drop integration around mid-turn reconnect + post-reconnect timeline reconciliation.
- Run authenticated foreground/background churn with immediate-send scenarios on device.
- Add lightweight persisted diagnostics for send trace IDs and reconnect milestones (without hot-path log spam).

## 2026-02-09 debugging UX improvements (operator tooling)
- Added chat-header session ID affordance in iOS:
  - `ios/PiRemote/Features/Chat/ChatView.swift`
  - Navigation title now uses `sessionId`.
  - Added tappable principal title that copies full `sessionId` to clipboard with checkmark feedback.
- Added one-command focused capture script:
  - `scripts/capture-session.sh`
  - Wraps `ios/scripts/collect-device-logs.sh` and produces a per-session bundle with:
    - `raw-app.log` (subsystem-filtered app logs)
    - `core.log` (Action/WebSocket/Connection/ChatSession categories)
    - `session.log` (fixed-string session-id matches)
    - `focused.log` (deduped union of session-id + core categories)
    - `meta.txt`
  - Default is intentionally low-noise (PiRemote app logs only), with optional `--include-perf` and `--include-debug`.
- README updated with `capture-session.sh` usage examples.

2026-02-09 12:19 PT update:
- Added server-side fallback for turns where assistant text only appears in `message_end` (no `text_delta` stream).
  - `pi-remote/src/sessions.ts` now tracks per-session `streamedAssistantText` from `message_update.text_delta`.
  - On `message_end` for assistant role, it emits missing text tail via `text_delta` using new helper `computeAssistantTextTailDelta(...)`, then emits thinking blocks.
  - Resets streamed text on `agent_start`/`agent_end` and after `message_end`.
- Added regression tests:
  - `pi-remote/tests/message-end.test.ts` covers tail-delta behavior (no-stream case, suffix case, exact match, divergence fallback).
- Validation:
  - `cd pi-remote && npx vitest run tests/message-end.test.ts tests/tool-events.test.ts` ✅
  - `cd pi-remote && npx tsc --noEmit` ✅
- Note: full `vitest run` currently fails on unrelated pre-existing gate/policy/trace test regressions in working tree.
