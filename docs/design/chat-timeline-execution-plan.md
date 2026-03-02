# Chat Timeline Refactor — Master Execution Plan

Status: active
Last updated: 2026-02-27
Canonical epic TODO: `TODO-e39b76a5`

## Purpose

This is the single plan we point to and execute against.

It consolidates timeline architecture cleanup, scroll ownership hardening, and guardrail testing into one ordered program.

## Canonical TODO graph

- Epic: `TODO-e39b76a5`
- Discovery done: `TODO-100b8ee6` (audit/design input)
- Execution children:
  - `TODO-2ade47d5` — W1 host collaborator extraction
  - `TODO-8e27ccc9` — W2 reducer decomposition
  - `TODO-9bfa816e` — W3 tool interaction policy/full-screen matrix
  - `TODO-fca039a7` — W4 tool expanded surface single-owner enforcement
  - `TODO-ad3e5b8f` — W4 thinking/trace alignment
  - `TODO-cd9a85a4` — W5 scroll matrix + requirements traceability
  - `TODO-705ae171` — W5 complexity budget + projector/reducer contracts
- Adjacent track (separate): `TODO-05101f4b` (chat performance)

## Progress snapshot (2026-02-27)

- **M1 status: complete**
  - Commits: `b8f6ad1`, `0247034`, `ca081d4`, `e2fdbaf`
  - Retained host primitives: `TimelineCellFactory`, `TimelineSnapshotApplier`, `TimelineScrollCoordinator`
  - Folded back thin wrapper: `TimelineDataSourceCoordinator`
- **M2 status: in progress**
  - Commits: `de79e28`, `a20d40a`, `bf48fb0`, `963da6f`, `dc0bcc2`
  - Current extracted reducer helpers: `TimelineItemIndex`, `TimelineHistoryLoadPlanner`, `TimelineTurnAssembler`
- **Process guardrail active**
  - One approved slice per worker dispatch.
  - No autonomous milestone continuation.
  - No commits unless prompt explicitly authorizes commits.

## Execution principles

1. **One vertical owner in timeline cells** (outer collection view).
2. **No behavior changes during structural extraction phases** (W1/W2).
3. **Tests before risky behavior changes** (W3/W4 guarded by W5-style matrix checks).
4. **Small PR slices** (single collaborator/module extraction or single policy shift per PR).
5. **Primitive budget on mobile**: keep only collaborators that own state, invariants, or measurable hot-path behavior. Thin pass-through wrappers are temporary and should be folded back.
6. **Dispatch discipline**: one approved slice per worker session, then stop for reviewer handoff.

## Ordered milestones (strict)

## M0 — Baseline + lock guardrails (already largely in place)

Inputs:
- `TODO-100b8ee6`
- `docs/testing/scroll-ownership-audit.md`

Exit criteria:
- Audit accepted as source-of-truth for scroll/full-screen target behavior.

---

## M1 — Host extraction (W1)

Primary TODO:
- `TODO-2ade47d5`

Scope:
- Split `ChatTimelineCollectionView` into focused collaborators with a minimal primitive set:
  - snapshot applier
  - scroll coordinator
  - cell factory
- Data source coordinator is **optional**: keep only if it owns real lifecycle/policy behavior; otherwise inline into host wiring.

Rules:
- No behavior change.
- Keep existing diagnostics and scroll behavior identical.
- End milestone with a collaborator-retention pass: keep only necessary primitives.

Gate:
- Existing timeline + UI harness tests green.

---

## M2 — Reducer decomposition (W2)

Primary TODO:
- `TODO-8e27ccc9`

Scope:
- Extract reducer internals (turn assembler/history planner/item index).

Rules:
- No external API changes unless required.
- Preserve replay/order/dedupe semantics.
- Prefer reducer-local/private helpers over micro-files; extract only units that own reusable invariants or shared state transitions.

Gate:
- Reducer + trace rendering suites green.

---

## M3 — Tool interaction policy layer (W3 part A)

Primary TODO:
- `TODO-9bfa816e`

Scope:
- Introduce explicit per-mode interaction policy for:
  - vertical ownership
  - horizontal allowance
  - full-screen eligibility
  - gesture affordances

Rules:
- Centralize decisions before behavior migration.

Gate:
- Mode-dispatch + tool-row content tests green.

---

## M4 — Vertical-owner behavior changes in tool rows (W3/W4 part B)

Primary TODO:
- `TODO-fca039a7`

Scope:
- Enforce no inner vertical competition in tool expanded surfaces.
- Preserve horizontal-only interactions where needed.
- Use full-screen escalation for deep reading.

Gate:
- Tool expand scroll matrix (anchored + detached) green.
- Write expand regression suite green.

---

## M5 — Thinking/trace alignment (W4)

Primary TODO:
- `TODO-ad3e5b8f`

Scope:
- Align thinking/trace long-form behavior with same single-owner + full-screen policy.

Gate:
- Thinking/trace interaction tests green.

---

## M6 — Guardrails + contracts (W5)

Primary TODOs:
- `TODO-cd9a85a4`
- `TODO-705ae171`

Scope:
- Harden scroll/full-screen regression matrix.
- Add requirements traceability updates.
- Add complexity budget + projector/reducer contract tests.

Gate:
- Contract/property suites green.
- Documentation + test matrix updated.

## Definition of done

All are true:
- `TODO-e39b76a5` checklist fully completed.
- Existing harness behavior parity maintained.
- Scroll ownership invariants enforced by tests.
- Full-screen interactions consistent for read/recall/remember/thinking long-form flows.
- Complexity/test guardrails active to prevent regressions.

## Session execution protocol

Per coding session:
1. Claim exactly one child TODO in current milestone.
2. Execute exactly one approved slice.
3. Run milestone gate tests.
4. Update child TODO checklist and notes.
5. Stop and return reviewer handoff.
6. Do **not** continue to another slice or milestone without explicit parent-session dispatch.
7. Do **not** commit unless the prompt explicitly authorizes commits.

## Immediate next executable step

Run a bounded **M2 retention checkpoint slice**:
- evaluate extracted reducer helpers against primitive budget,
- fold back any micro-helper that does not own reusable invariant/state behavior,
- keep one-slice dispatch discipline and reviewer handoff before any M3 dispatch.
