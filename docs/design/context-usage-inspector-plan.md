# Context Usage Ring + Inspector Plan

Status: active
Last updated: 2026-03-01
Canonical TODO: `TODO-7d592cd4`

## Goal

Expose persistent context awareness in chat without reintroducing toolbar clutter.

- Keep tool controls contextual (can disappear while reading history)
- Keep context usage visible at all times (top-right nav affordance)
- Let users inspect what is currently in context and why

## UX proposal

### Top-right affordance

Replace the current server status icon in ChatView top-right with a **context usage ring**.

Display:
- `used / window` (derived percent)
- state color bands:
  - normal: <70%
  - warning: 70–90%
  - critical: >90%
  - unknown: hollow/neutral state

Tap behavior:
- Opens **Context Inspector** sheet.

### Context Inspector contents

1) Session context usage
- Context tokens
- Context window
- Percent used
- Unknown state messaging when post-compaction value is unavailable

2) Token usage stats (session-wide)
- Input
- Output
- Cache read
- Cache write
- Total

3) Skills in scope
- Workspace enabled skills
- Loaded skill command metadata
- For each skill: estimated prompt-footprint contribution

4) Context composition (best effort)
- Base/system prompt contribution (estimated)
- AGENTS/context files contribution (estimated)
- Skills metadata contribution (estimated)
- Dynamic runtime messages (remainder)

## Data we already have

### Available now (no pi changes required)

- `Session.contextTokens` + `Session.contextWindow` in Oppi protocol
- pi session stats via `get_session_stats` (input/output/cacheRead/cacheWrite/total/cost)
- Workspace enabled skills
- Slash command metadata via `get_commands` (includes skill commands)

## Limitation

pi does not currently expose exact per-source/per-skill token attribution for active context.

Therefore:
- per-skill numbers in inspector are **estimates**, not exact counters
- UI must label this clearly (e.g. “Estimated”)

## Delivery plan

### Phase 1 (MVP)

- Add context ring in top-right
- Add Context Inspector sheet
- Show exact session-level context usage + session token stats
- Show enabled/loaded skills list
- Add estimated footprint section with clear “estimated” labeling

### Phase 2 (instrumentation)

- Server-side context composition estimator service
- Better attribution for:
  - system prompt components
  - skills metadata
  - dynamic reads/tool outputs
- Optional trace-backed debug view for advanced inspection

## iOS/server touchpoints

- iOS:
  - `ios/Oppi/Features/Chat/ChatView.swift`
  - replace `RuntimeStatusBadge` usage in top-right
  - new `ContextUsageRingView`
  - new `ContextInspectorView`

- Server:
  - optional: add endpoint/WS command for context composition estimates
  - optional: enrich state payload with composition metadata

## Non-goals

- Exact token accounting per individual skill (not supported natively by pi today)
- Reworking toolbar visibility logic as part of this task

## Acceptance criteria

1. While reading history (toolbar hidden), context usage remains visible in top-right.
2. Tapping the ring opens inspector with context + token stats.
3. Inspector includes skills list and per-skill estimated footprint.
4. Unknown/indeterminate context states are handled explicitly in UI.
5. No regressions in current chat scroll + toolbar behavior.
