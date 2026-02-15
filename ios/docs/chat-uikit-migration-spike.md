# Oppi iOS Chat — Full UIKit Migration Spike

> Historical migration spike document.
> Migration is complete; active state lives in `docs/chat-renderer-active-path-checklist.md`.

Date: 2026-02-10
Owner: iOS chat durability lane (`TODO-f0126679`)

## Why this spike

We already moved timeline virtualization to `UICollectionView` (`ChatTimelineCollectionView`), but row rendering is still SwiftUI-hosted (`UIHostingConfiguration` + `ChatItemRow`).

Given recurring chat App Hang regressions and increasing UI complexity, we want a durable architecture with maximal rendering headroom.

Goal of this spike: define a migration plan that preserves current UX while reducing layout/observation risk and main-thread volatility.

---

## Incidents reviewed (what failed before)

### 1) SwiftUI invalidation storms on large timelines
- Symptom: App Hang in `LazyVStack` / `ForEach` / `AttributeGraph` paths.
- Root cause: large dynamic SwiftUI trees with many identity/trait updates during keyboard + streaming + scroll interactions.
- Prior mitigations: render windowing, collection backend, reduced row trait load, scroll throttles.
- Preventive rule (new architecture): timeline row rendering must not depend on parent SwiftUI observation churn.

### 2) `UIViewRepresentable` sizing + keyboard transition loops
- Symptom: multi-second hangs during send/keyboard transitions.
- Root cause: `sizeThatFits` and safe-area/layout cascades interacting with timeline updates.
- Prior mitigations: fixed-height inline composer, keyboard settle gating, removing forced keyboard dismiss on send.
- Preventive rule: isolate composer and timeline into separate UIKit components with explicit sizing contracts.

### 3) Synchronous heavy work inside view render path
- Symptom: frame drops and occasional stalls under streaming/expanded tool rows.
- Root causes seen: markdown parsing, regex image extraction, JSON pretty-printing, diff computation, image decoding in hot render paths.
- Prior mitigations: `Task.detached`, caches, output caps, memory warning cleanup.
- Preventive rule: no expensive parse/transform/regex/image decode in `cellForItemAt`, `preferredLayoutAttributes`, or view body equivalents.

### 4) Scroll command thrash under streaming
- Symptom: scroll jitter and additional layout pressure under high delta rates.
- Root cause: frequent auto-scroll attempts while timeline was already near bottom, plus keyboard transitions.
- Prior mitigations: heavy-timeline thresholds, throttles, keyboard transition suppressors.
- Preventive rule: scroll scheduler must be stateful, cadence-limited, and driven by explicit trigger conditions.

### 5) Session lifecycle races during switching/reconnect
- Symptom: old session cleanup disconnecting new WS, reconnect loops, stale cleanup affecting current session.
- Root cause: ownership/generation races.
- Prior mitigations: `connectedSessionId` guards, generation checks, tests.
- Preventive rule: all async render/stream tasks must be keyed by session-generation tokens.

### 6) Memory pressure from large traces / base64 payloads
- Symptom: watchdog/memory pressure under heavy reloads.
- Root causes: wasteful decode paths, large retained blobs.
- Prior mitigations: direct decode paths, stripping image attachment data on memory warnings, bounded stores.
- Preventive rule: byte-bounded caches + preemptive payload compaction in render pipeline.

---

## Architecture target (post-migration)

`ChatView` can remain SwiftUI as shell/navigation, but chat surface should be fully UIKit-driven.

### New chat surface stack

1. `ChatViewController` (UIKit container)
   - owns collection view + composer + permission overlay container
   - no SwiftUI observation dependency for per-frame timeline updates

2. `ChatTimelineDataSource` (diffable + typed row models)
   - stable row identifiers
   - selective reconfigure (no global reload)

3. `ChatCellRenderer` layer
   - one native cell class per row family (`user`, `assistant`, `tool`, `thinking`, `system`, `permission`)
   - attributed text and layout metrics precomputed off-main

4. `ChatRenderPipeline` actor
   - markdown parse/highlight/diff/image decode queue
   - caches keyed by `(itemID, contentHash, widthClass, themeID, streamingState)`
   - strict byte budgets + eviction

5. `ChatScrollScheduler`
   - coalesced scroll commands (display cadence)
   - near-bottom + keyboard transition aware

6. `ChatComposerView` (UIKit)
   - fixed sizing model
   - no timeline coupling

---

## Migration phases

### Phase 0 — Baseline and guardrails (required)
- Add signposts/metrics for:
  - collection apply duration
  - cell configure duration by row type
  - cell sizing duration
  - scroll command rate
  - main-thread frame overruns
- Freeze acceptance metrics before refactor (device baselines).

Exit criteria:
- Repeatable benchmark traces on device (normal + stress workloads).

### Phase 1 — UIKit row model + two native cells
- Keep current collection infra.
- Replace `UIHostingConfiguration` only for highest-volume rows first:
  - assistant text row
  - tool call row header + collapsed preview
- Retain SwiftUI fallback cells for remaining row types behind feature flag.

Exit criteria:
- No regression in behavior.
- Measured lower configure/sizing cost on target scenarios.

### Phase 2 — Full native timeline row set
- Convert remaining rows (`user`, `thinking`, `permission`, `system/error`, media).
- Remove `ChatItemRow` from timeline hot path.
- Preserve visual parity tokens (spacing, colors, typography).

Exit criteria:
- Timeline no longer depends on SwiftUI-hosted cells.
- Stress harness passes without stall increments.

### Phase 3 — Native composer integration
- Introduce UIKit composer container and input controls.
- Keep existing action handlers/session manager logic.
- Maintain slash/image/bash behavior parity.

Exit criteria:
- Keyboard transitions and send flows stable under streaming.

### Phase 4 — Optimization pass
- Height cache hardening + invalidation correctness.
- Prefetch strategy for markdown/image decode.
- Memory pressure handling and cache shedding.

Exit criteria:
- Target frame pacing maintained under long sessions and expansion-heavy traces.

### Phase 5 — Cleanup and default-on rollout
- Remove legacy hosted-cell path after dogfood window.
- Keep temporary runtime kill switch during rollout.

Exit criteria:
- 7-day dogfood: no chat App Hang >2s.

---

## Pre-mortem checklist (must pass before each phase lands)

1. No synchronous expensive transforms in render methods.
2. All async tasks have cancellation tied to session-generation + cell reuse.
3. No global reloads for streaming deltas.
4. Scroll auto-follow only when near-bottom and cadence permits.
5. Keyboard/frame transition suppression windows remain active.
6. Caches have explicit per-entry and total byte caps.
7. UI tests cover session switching + stream pulse + expand/collapse churn.

---

## Test strategy

- Keep existing reducer stress tests.
- Extend UI harness (`UIHangHarnessUITests`) to run both feature-flag paths:
  - hosted SwiftUI cells
  - native UIKit cells
- Add timeline-specific perf assertions (configure/sizing budgets) in debug perf tests.
- Add session-switch race tests for generation cancellation of render tasks.

---

## Metal stance

- UIKit/Core Animation already uses GPU compositing (Metal-backed on modern iOS).
- Custom Metal text rendering is high complexity and poor ROI for chat markdown/tool logs.
- Priority should be: native cells + TextKit/AttributedString caching + off-main preprocessing.
- Revisit custom drawing only if profiling shows text rasterization as dominant post-migration bottleneck.

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Feature parity regressions | phased rollout + feature flag + visual parity checklist |
| Reintroducing lifecycle races | generation tokens + cancellation tests |
| Height cache invalidation bugs | deterministic keys + width/theme invalidation tests |
| Scope creep into redesign | explicit non-goal: preserve current UX and styling |
| Test flake from streaming | harness deterministic mode (`PI_UI_HANG_NO_STREAM`) |

---

## 2026-02-10 implementation update

- Phase 0 instrumentation landed (`ChatTimelinePerf`) and is wired into:
  - `ChatTimelineCollectionView` (apply/layout/cell/scroll metrics)
  - UI harness diagnostics (`diag.applyMs`, `diag.layoutMs`, `diag.cellMs`, `diag.scrollRate`)
- Phase 1 scaffolding now includes native UIKit rows for:
  - assistant rows (`AssistantTimelineRowContent`, opt-in `PI_CHAT_NATIVE_ASSISTANT=1`)
  - text-only user rows (`UserTimelineRowContent`, opt-in `PI_CHAT_NATIVE_USER=1`)
  - collapsed thinking rows (`ThinkingTimelineRowContent`, opt-in `PI_CHAT_NATIVE_THINKING=1`)
  - collapsed tool rows (`ToolTimelineRowContent`, opt-in `PI_CHAT_NATIVE_TOOL=1`)
- collection view routing behavior:
  - assistant rows route to native content when enabled
  - user rows route to native content when enabled and no image attachments are present
  - thinking rows route to native content only when collapsed; expanded thinking rows stay on existing SwiftUI path
  - tool rows route to native content only when collapsed; expanded tool rows stay on existing SwiftUI path
  - hosted SwiftUI path remains default for parity safety
- Harness diagnostics now expose native-path toggles:
  - `diag.nativeMode` (assistant)
  - `diag.nativeUserMode` (user)
  - `diag.nativeThinkingMode` (thinking)
  - `diag.nativeToolMode` (tool)

Validation:
- iOS simulator build passes.
- `UIHangHarnessUITests.testSessionSwitchNoStalls` passes in:
  - default hosted mode
  - combined native assistant + user + thinking + tool flags (`PI_CHAT_NATIVE_ASSISTANT=1 PI_CHAT_NATIVE_USER=1 PI_CHAT_NATIVE_THINKING=1 PI_CHAT_NATIVE_TOOL=1`)

## Decision (updated 2026-02-10)

Proceed with phased full UIKit chat rendering migration, preserving current UX,
with metrics-first gates and rollback flag at each phase.

### 2026-02-10 closure update — `TODO-f0126679`

The durability lane is now considered complete for current scope.

Shipped outcomes:
- Native `UICollectionView` timeline backend is default-on (no runtime env flag
  gating required in app runtime).
- Native row coverage includes assistant (plain text), user (text-only), thinking
  (collapsed), and tool calls (collapsed), with SwiftUI fallback retained where
  it preserves quality or interaction parity:
  - assistant markdown-like content (high-fidelity fallback heuristics)
  - expanded thinking/tool rows
  - collapsed read/write/edit rows that require direct file-open interaction
- Tool row parity improvements landed:
  - highlighted tool prefixes/names in native collapsed rows
  - diff-style edit stats (`+N` green / `-N` red)
  - compact single-line file path display (`parent/file[:range]`)
  - subtle non-bouncy collapse behavior for expanded output

Validation at closeout:
- `UIHangHarnessUITests.testSessionSwitchNoStalls` passes in hosted and native
  paths.
- Full simulator suite passes: `715 tests in 52 suites`.
- Real-device build/install/launch succeeds on Duh Ifone
  (`00000000-0000-0000-0000-000000000000`).
- Manual dogfood feedback: no recent stuck/freeze incidents in chat.

Closeout decision:
- Mark `TODO-f0126679` done.
- Continue passive monitoring via UI harness and Sentry App Hang reports; reopen
  only on reproducible regressions.
