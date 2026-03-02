# Oppi Chat Timeline Simplification Plan

Status: stale
Owner: Chen
Scope: iOS chat timeline + reducer hot path

Superseded by `docs/design/chat-timeline-execution-plan.md`.

## Why this now

Current timeline behavior is strong, but implementation cost is rising:

- `ChatTimelineCollectionView.swift` is very large
- `ToolTimelineRowContent.swift` is very large
- `TimelineReducer.swift` is very large
- `AssistantMarkdownContentView.swift` is very large

This slows iteration and makes regressions harder to isolate.

## Goals

1. Reduce cognitive load in timeline/chat code.
2. Keep (or improve) robustness and perf.
3. Make future features cheaper to add.

## Non-goals

- No broad UI redesign.
- No protocol changes unless required.
- No rewrite of the whole timeline stack.

## Invariants to preserve

These are non-negotiable:

1. Deterministic replay ordering after reconnect.
2. No duplicate tool rows on replay/reload.
3. Streaming remains smooth (no jank spikes/regression in harness).
4. Scroll behavior remains stable (no yank while scrolled up).
5. Follow-bottom lock behavior preserved.
6. Permission/tool interaction cards remain functionally identical.

## Target architecture

Keep one strict flow with clear ownership:

1. **Ingress/Normalization**
   - Coalesce deltas, normalize events, reject invalid ordering.
2. **Pure reduction**
   - `TimelineReducer` converts normalized events -> timeline model + explicit mutations.
3. **Projection**
   - Convert timeline model -> immutable row render plans.
4. **Rendering/Application**
   - `UICollectionView` layer applies plans/mutations only.

Rule: views render; reducers decide.

## Workstreams

### W1 — Split timeline host orchestration

Extract from `ChatTimelineCollectionView` into focused collaborators:

- `TimelineDataSourceCoordinator`
- `TimelineSnapshotApplier`
- `TimelineScrollCoordinator`
- `TimelineCellFactory`

Outcome: host file becomes assembly + wiring, not behavior soup.

### W2 — Decompose reducer internals

Split `TimelineReducer` internals without changing external API:

- `TurnAssembler` (assistant/thinking/tool turn buffers)
- `HistoryLoadPlanner` (incremental vs full rebuild)
- `ItemIndex` (id->index lookup/update)

Outcome: smaller isolated units + easier invariant testing.

### W3 — Decompose tool row rendering

Split `ToolTimelineRowContent` into:

- `ToolRowShellLayout` (labels/icons/containers)
- `ToolRowExpandedRenderer`
- `ToolRowViewportController`
- `ToolRowContextMenuCoordinator`

Outcome: UI classes stop deciding business behavior.

### W4 — Single vertical scroll owner enforcement

Enforce one policy: outer timeline owns vertical scroll behavior.

- Nested views can scroll horizontally only.
- Long-form tool surfaces use viewport/fullscreen strategy, not nested vertical ownership.
- Add tests for no-yank + stable handoff to fullscreen.

Outcome: fewer scroll edge bugs and simpler reasoning.

### W5 — Complexity budget + test gates

Add lightweight guardrails:

- Soft cap: 700 LOC/file in timeline hot path
- Hard cap: 900 LOC/file (CI fail for touched files)
- Type body length caps for timeline classes

Test policy:

- Keep existing harness + invariant suites as blocking gates
- Add projector contract tests (`ChatItem -> row plan`)
- Add reducer property checks for idempotency/order/dedupe

## Delivery plan (2 weeks)

### Week 1 (mechanical extraction)

- Extract W1 + W2 with no behavior changes
- Keep interfaces stable
- All existing tests must pass unchanged

### Week 2 (behavior ownership cleanup)

- Extract W3 + W4
- Add W5 guardrails
- Add focused projector/reducer contract tests

## Rollout strategy

1. Land in small PRs (one collaborator extraction per PR).
2. Each PR includes:
   - no behavior change statement,
   - targeted tests,
   - before/after file size diff.
3. Final PR enables complexity budget checks.

## Definition of done

- Timeline behavior parity confirmed via existing harness tests.
- No perf regressions in UI hang/perf diagnostics.
- Largest timeline files reduced and responsibilities separated.
- New tests cover projector + reducer contracts.
- Complexity budget check is active for future PRs.

## Risks and mitigations

- **Risk:** hidden behavior coupling during extraction  
  **Mitigation:** no API changes in week 1; extraction-first, behavior-later.

- **Risk:** scroll regressions from ownership changes  
  **Mitigation:** expand harness assertions before changing scroll policy.

- **Risk:** over-refactor stall  
  **Mitigation:** enforce two-week scope; defer optional cleanup.
