# Oppi iOS Fork Experience Spike

Date: 2026-02-11
Owner: Oppi iOS + pi-remote
Related: `IMPLEMENTATION.md` Step 10 (`TODO-19cb0451`)

## Why this spike

Fork is one of pi's highest-leverage capabilities: "keep momentum, branch safely, explore alternatives without losing prior work."

In Oppi today, fork works functionally, but the UX still feels like a raw RPC call rather than a first-class branching workflow.

Goal of this spike: define a product + technical plan that makes fork feel native, reliable, and visibly branch-aware while staying aligned with pi semantics.

---

## Product intent

Fork should feel like:

1. **Fast** — one gesture from a message.
2. **Safe** — no accidental destructive context jumps.
3. **Legible** — user always knows what branch they are on.
4. **Reversible** — previous path remains discoverable.
5. **Pi-native** — iOS mirrors pi CLI behavior, not custom semantics.

---

## Current state (as of 2026-02-11)

### What works

- Server supports pi RPC passthrough for:
  - `get_fork_messages`
  - `fork`
- Fork succeeds end-to-end when using canonical `entryId` from `get_fork_messages`.
- iOS now follows CLI-safe flow:
  1) fetch `get_fork_messages`
  2) validate selected entry
  3) send `fork(entryId)`

### Current gaps

1. **Weak success feedback**
   - User gets no strong "you are now on a new branch" transition.

2. **Branch identity is mostly invisible**
   - No persistent branch badge / lineage surface in chat or session detail.

3. **Limited branch navigation UX**
   - Fork is available, but branch history/navigation affordances are minimal.

4. **No explicit lineage metadata in Session model**
   - `Session` does not expose parent branch/session context fields.

---

## Constraints

1. Oppi must remain a thin supervision/interface layer over pi semantics.
2. Fork target IDs must come from server/pi (`get_fork_messages`), never inferred from rendered UI IDs.
3. Host and container runtime paths must behave identically from iOS UX perspective.
4. Any added server metadata must be additive/backward-compatible.

---

## UX proposal

## Phase A — "Reliable and obvious" (near-term)

### A1) Fork affordance rules

- Show "Fork from here" only on **server-backed user messages**.
- Hide fork from assistant/tool/system rows.
- If turn is still in progress, show non-blocking error: "Wait for turn to finish before forking."

### A2) Confirmation + preview

On fork action, show lightweight confirmation sheet:

- Title: `Fork from this message?`
- Body: preview first ~120 chars of selected user text.
- Actions:
  - `Fork` (primary)
  - `Cancel`

### A3) Strong post-fork feedback

After successful fork:

- haptic success (subtle)
- append system event in timeline:
  - `Forked from: <preview>`
- optional toast:
  - `Branch created`
- keep composer focused (no heavy navigation bounce)

### A4) Immediate state refresh

After successful fork:

1. request state (`get_state`) to refresh active `sessionId/sessionFile`
2. refresh trace for branch-correct timeline view
3. preserve scroll behavior (only jump if prior anchor is invalid)

---

## Phase B — "Branch-aware chat"

### B1) Branch chip in session toolbar

Add compact branch indicator:

- `Branch: <short-id>`
- tap opens branch context sheet

### B2) Branch context sheet

Show:

- current branch id
- fork origin message preview
- fork timestamp
- parent session/file reference

### B3) Session detail lineage

Session detail adds lineage card:

- `Forked from session <id>`
- `Fork point: <message preview>`

---

## Phase C — Workspace-level fork productization (Step 10 alignment)

When workspace-scoped session forking lands (REST-level session fork), shift UX from "branch within active session runtime" to "fork creates sibling session":

- Fork action creates a new session in the same workspace.
- User can choose:
  - `Open fork now`
  - `Stay here`
- Workspace session list shows parent/child indicators.

This is the best long-term model for supervision because branches become explicit top-level artifacts.

---

## Technical design

### Current command contract (kept)

- `get_fork_messages` → `{ messages: [{ entryId, text }] }`
- `fork(entryId)` → `{ text, cancelled }`

### Additive server improvements (recommended)

1. **Post-fork state sync in server session manager**
   - After successful `fork`, call `get_state` and persist snapshot.
   - Broadcast updated `state` to clients.

2. **Optional explicit fork event**
   - New server event: `fork_complete` (additive)
   - Payload example:
     - `entryId`
     - `selectedText`
     - `previousPiSessionId`
     - `newPiSessionId`
     - `previousSessionFile`
     - `newSessionFile`

3. **Session lineage fields (additive)**
   - Extend `Session` (server + iOS) with optional fields:
     - `forkParentPiSessionId?`
     - `forkEntryId?`
     - `forkedAt?`
     - `forkPreview?`

These fields should be best-effort and optional so older records decode cleanly.

---

## Failure handling

1. `entry not forkable`
   - Show: "That message can't be forked. Pick a user message from history."

2. `no fork messages returned`
   - Show: "No user messages available for forking yet."

3. RPC timeout/network disconnect
   - Show: "Fork timed out. Check connection and try again."
   - Do not mutate local branch UI state optimistically.

4. server-side cancellation
   - Respect `cancelled=true` as no-op with neutral status message.

---

## Observability

Add fork-specific telemetry/logging fields:

- `fork_start` (entryId hash, sessionId)
- `fork_success` (latency ms, newPiSessionId present?)
- `fork_failure` (error class)
- `fork_cancelled`

Primary SLO candidate:

- P95 `fork_start -> first post-fork assistant delta` < 2.5s (host), < 4s (container)

---

## Test plan

### Unit

1. iOS `ServerConnection`:
   - `get_fork_messages -> fork` sequencing
   - non-forkable selection rejection
   - timeout + disconnect handling

2. Reducer/UI logic:
   - fork success system event insertion
   - fork action shown only on user rows

### Integration

1. pi-remote + iOS:
   - fork updates state and trace to new branch
   - reconnect during fork path remains consistent

2. host + container parity:
   - same UX/messages under both runtimes

### UX acceptance

- User can always answer:
  1) "Where did this branch come from?"
  2) "Am I currently on the forked path?"

---

## Rollout plan

1. **R0 (done)**
   - CLI-style safe fork selection in iOS command path.

2. **R1**
   - Confirmation sheet + post-fork feedback + state/trace refresh.

3. **R2**
   - Branch chip + lineage card.

4. **R3**
   - Workspace-level fork sessions (Step 10) + explicit sibling-session UX.

---

## Open questions

1. Should successful fork always prefill composer with selected user text (CLI parity), or keep composer unchanged on mobile?
2. Should fork default to "open now" once workspace-level fork sessions exist?
3. Do we want a dedicated "Branches" tab in session detail, or keep branch context inline in toolbar + detail card?

---

## Recommendation

Implement **Phase A** immediately (feedback + refresh polish), then use real dogfood sessions to validate whether users need deeper branch navigation before committing to Phase B surface area.

Fork should remain fast and low-friction; branch visualization should increase confidence without adding modal complexity.
