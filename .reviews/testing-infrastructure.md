# Testing Infrastructure Review (since TestFlight/19)

## Coverage Assessment

### Well-covered areas
- **iOS invariant testing is substantially stronger** for core runtime behavior:
  - `TimelineReducer` invariants include seeded batch runs, replay/idempotency checks, chunking equivalence, and complexity budgets (`ios/OppiTests/Timeline/TimelineReducerInvariantTests.swift:9`, `:96`, `:145`, `:162`, `:367-378`).
  - `ServerConnection` invariants include deterministic state-machine sequence exploration and non-active-session isolation (`ios/OppiTests/Network/ServerConnectionInvariantTests.swift:9`, `:28`, `:71`, `:99`).
- **Scroll ownership and stability coverage is broad**:
  - Tool matrix across all cases + anchored/detached variants + fullscreen policy checks (`ios/OppiTests/Timeline/ToolExpandScrollMatrixTests.swift:9`, `:66`, `:111`).
  - Streaming matrix expands combinations across content/phase/follow-state (`ios/OppiTests/Support/TimelineStreamingScrollMatrixSupport.swift:115-129`).
  - Property/stress suites exist (`ios/OppiTests/Timeline/ScrollInvariantPropertyTests.swift:8-41`, `ios/OppiTests/Timeline/ScrollStressTests.swift:9-81`).
- **Server WS invariants and race coverage improved**:
  - Seeded lifecycle programs and ordering/correlation assertions (`server/tests/ws-invariants.test.ts:128-152`).
  - Dedicated race matrix with queue/order/catchup/state interleaving sections (`server/tests/ws-command-race.test.ts:217`, `:423`, `:610`).
  - Seeded protocol fuzz and turn-ack fuzz (`server/tests/protocol-fuzz.test.ts:13`, `:119`).
- **Requirements traceability is explicit** in matrix form (`docs/testing/requirements-matrix.md:20-33`).

### Gaps / weaker coverage
- **Offline UX remains partial by matrix’s own admission** (`docs/testing/requirements-matrix.md:33`).
- **RQ-TL-003 and RQ-TL-004 have no server-side mapping** (`docs/testing/requirements-matrix.md:28-29`).
- **Protocol drift tests are mostly JSON round-trip shape checks**, not runtime decoder/validator behavior (`server/tests/protocol-schema-drift.test.ts:21-22`).

## Test Quality

### Strengths
- Good deterministic patterns:
  - iOS wait helpers (`ios/OppiTests/Support/TestWaiters.swift:3`, `:34`, `:53`).
  - Server async helpers (`server/tests/harness/async.ts:9`, `:32`, `:66`).
- Assertions often include contextual failure messages (e.g., seeded repro tags, scroll drift detail) (`ios/OppiTests/Timeline/ToolExpandScrollMatrixTests.swift:23-33`, `server/tests/protocol-fuzz.test.ts:78-93`).
- Explicit no-op/idempotency checks are present (`ios/OppiTests/Timeline/TimelineReducerInvariantTests.swift:85-94`, `server/tests/render-noop-invariant.test.ts:8-14`).

### Maintainability concerns
- **Refactor is incomplete; duplicated tests still exist**:
  - `configureWithValidCredentials` exists in both monolith and split file (`ios/OppiTests/Network/ServerConnectionTests.swift:13`, `ios/OppiTests/Network/ServerConnectionLifecycleTests.swift:9`).
  - `disconnectSessionClearsActiveId` duplicated (`ios/OppiTests/Network/ServerConnectionTests.swift:494`, `ios/OppiTests/Network/ServerConnectionLifecycleTests.swift:21`).
  - `basicAgentTurn` duplicated (`ios/OppiTests/Timeline/TimelineReducerTests.swift:9`, `ios/OppiTests/Timeline/TimelineReducerBasicTests.swift:9`).
- **Heavy private-implementation coupling via `Mirror`** in tool row mode tests (`ios/OppiTests/Timeline/ToolTimelineRowModeDispatchTests.swift:1341-1357`, plus many call sites such as `:113-115`). This is useful for deep coverage but brittle against harmless refactors.
- `ProtocolSnapshotTests` is still XCTest style (`ios/OppiTests/Protocol/ProtocolSnapshotTests.swift:1`, `:12`), inconsistent with broader Swift Testing adoption.

## Fuzz Testing

### What’s good
- Seeded RNG and repro formatting are in place (`server/tests/harness/fuzz.ts:3`, `:13`; `server/tests/protocol-fuzz.test.ts:7`).
- Stream fuzz validates request correlation, terminal uniqueness, ordering assumptions (`server/tests/protocol-fuzz.test.ts:74-111`).
- Turn-ack fuzz checks monotonic stage progression and dedupe invariants (`server/tests/protocol-fuzz.test.ts:176-216`).

### Limits
- Command surface in fuzz is narrow: subscribe/unsubscribe/prompt/steer/follow_up/get_state (`server/tests/protocol-fuzz.test.ts:34-63`). No fuzzing of permission responses, queue commands, extension UI, etc.
- Seed count is still relatively small (8 seeds per fuzz suite) (`server/tests/protocol-fuzz.test.ts:13`, `:119`).
- Additional “schema drift” suite is not true parser fuzz; it uses serialize/deserialize identity (`server/tests/protocol-schema-drift.test.ts:21-22`).

## CI Gates

### What works
- Clean PR/nightly split workflows with single-runner lock and PR cancellation (`.github/workflows/pr-fast-gate.yml:12-13`, `:26-27`; `.github/workflows/nightly-deep-gate.yml:4-6`, `:24`).
- Gate runner supports selective execution (`TEST_GATE_FROM`, `TEST_GATE_ONLY`) (`server/scripts/testing-gates.mjs:12-13`, `:37-61`).

### Reliability / coherence issues
- **Docs drift exists today**:
  - README says `pr-fast: check -> test` (`docs/testing/README.md:46`),
  - policy actually runs `check -> test:coverage` (`server/testing-policy.json:4-6`).
- Coherence check only verifies command strings are mentioned, not step parity (`server/scripts/check-testing-policy.mjs:47-55`).
- “Mechanical AI review gate” is not enforced in gate workflows:
  - script exists (`server/package.json:71`),
  - but gate/check paths do not run it (`server/package.json:72`, workflows only run gate commands at `.github/workflows/pr-fast-gate.yml:45`, `.github/workflows/nightly-deep-gate.yml:42`).
- “PR fast” currently includes coverage (`server/testing-policy.json:6`), which may not remain fast at scale.

## Test Helpers

### Good patterns
- Reusable deterministic wait helpers on both stacks (`ios/OppiTests/Support/TestWaiters.swift:3-65`, `server/tests/harness/async.ts:9-73`).
- Reusable stream fuzz harness extracted (`server/tests/harness/stream-fuzz-harness.ts:73-155`).

### Anti-patterns
- `FakeWebSocket` and `makeSession` are duplicated across multiple server tests (`server/tests/ws-command-race.test.ts:37`, `server/tests/user-stream-websocket.test.ts:22`, `server/tests/harness/stream-fuzz-harness.ts:8`; and `makeSession` at `:22`, `:8`, `:63` respectively).
- Time-window collection helper (`collectMessages`) is duration-based (`server/tests/harness/ws-harness.ts:84-95`), which encourages fixed sleeps instead of event predicates.
- Queue drain helpers still use `setTimeout(0)` loops in some suites (`server/tests/ws-command-race.test.ts:190-197`).

## Flakiness Risk

- **UI tests still contain fixed sleeps** (`ios/OppiUITests/UIHangHarnessUITests.swift:46-50`, `:273`, `:339`, `:435`, `:496`).
- **High-value stress/perf tests are opt-in and skipped by default**:
  - require env (`ios/OppiUITests/UIHangHarnessUITests.swift:14-17`, `:453`, `:508`),
  - nightly gate command does not pass `--stress` (`server/package.json:52`, `ios/scripts/test-ui.sh:24`, `:32`, `:97`).
- WS integration suites still use fixed-duration windows and random ports (`server/tests/ws-invariants.test.ts:28`, `:146`; `server/tests/ws-stress.test.ts:43`, `:176`, `:314`).
- Some tests close sockets without awaiting closure in invariants suite (`server/tests/ws-invariants.test.ts:158`, `:194`, `:241`, `:295`).

## Suggestions (ordered by impact)

1. **Enforce currently-optional gates in CI**
   - Add `npm run review` to PR fast gate or `npm run check` (currently absent from `server/package.json:72` and workflows at `.github/workflows/pr-fast-gate.yml:45`).
   - Add a nightly stress UI lane (`ios/scripts/test-ui.sh --stress`) so perf/stall tests stop being mostly skipped (`ios/OppiUITests/UIHangHarnessUITests.swift:14-17`, `server/package.json:52`).

2. **Finish iOS test suite split and remove duplicates**
   - Remove duplicated tests still present in monolith + focused files (examples above). This will reduce runtime and maintenance confusion.

3. **Replace duration-based WS waits with condition-based polling helpers**
   - Migrate `collectMessages(...durationMs)` usages to predicate waits tied to expected message counts/IDs (`server/tests/harness/ws-harness.ts:84-95`).

4. **Broaden fuzz command surface and seed depth (nightly)**
   - Extend protocol fuzz to include permission/queue/extension command families (currently limited at `server/tests/protocol-fuzz.test.ts:34-63`).
   - Increase seed counts on nightly while keeping a lean deterministic subset on PR.

5. **Tighten policy/docs drift checks**
   - Update docs to reflect `test:coverage` lanes (`docs/testing/README.md:46-47` vs `server/testing-policy.json:4-11`).
   - Extend `check-testing-policy` to compare gate step definitions, not just command presence (`server/scripts/check-testing-policy.mjs:47-55`).

6. **Consolidate duplicated server test harness primitives**
   - Centralize `FakeWebSocket` and `makeSession` into shared harness modules to reduce divergence and subtle behavior drift.

7. **Strengthen security-boundary tests to assert secure store behavior directly**
   - Current workspace traversal tests explicitly accept API-layer-only defense (`server/tests/filesystem-boundary.test.ts:444`, `:528`). Add storage-layer rejection assertions so internal misuse is harder to weaponize.
