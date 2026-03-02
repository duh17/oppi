# Chat Freshness Contract (Predictable Timeline Behavior)

Status: active

This document defines a **simple, deterministic contract** for chat entry/re-entry behavior so users (and agents changing code) can reason about what happens without guessing.

---

## 1) Product goal

When opening a chat, the app should prioritize:

1. **Freshness of latest messages**
2. **Continuity of streaming updates**
3. **Completeness reconciliation** (full trace rebuild) only when needed

Short version:

> Show latest content fast. Reconcile heavy history later, only on failure paths.

---

## 2) Single mental model

On session entry, timeline is in one of three states:

1. `cache_visible` — local snapshot shown immediately
2. `live_sync` — websocket connected + catch-up/stream flowing
3. `reconcile_full` — expensive full trace fetch/rebuild (exception path)

Expected path for healthy sessions:

```text
cache_visible -> live_sync
```

Not expected unless necessary:

```text
cache_visible -> live_sync -> reconcile_full
```

---

## 3) Freshness-first rules

### Rule A — Cache is allowed, but stale window must be short

- Cache may render instantly for responsiveness.
- Entry should transition to fresh content as soon as live data is available.

### Rule B — No eager full reload on healthy cached entry

If cache exists and catch-up/stream is healthy, do **not** trigger full trace reload on entry.

### Rule C — Full reload is only for explicit failure/repair paths

Allowed triggers for `reconcile_full`:
- no cache exists
- catch-up ring miss (`catchUpComplete == false`)
- sequence regression (`currentSeq < lastSeenSeq`)
- catch-up fetch failure
- explicit user refresh/debug action

### Rule D — Streaming must remain higher priority than reconciliation

When live stream is active, timeline updates from stream/catch-up must not be blocked behind heavy history apply/layout work.

---

## 4) Deterministic entry algorithm (target)

```text
onEnterSession(sessionId):
  load cache and render immediately (if exists)
  connect stream
  attempt catch-up using seq

  if catch-up succeeds OR stream seq advances:
    mark timeline fresh
    DO NOT start full reload (unless user requested)

  if catch-up fails/ring-miss/seq-regression/no-cache:
    run full reload
```

---

## 5) Observability contract

These metrics must be present and used for regressions:

- `chat.fresh_content_lag_ms` (primary user-perceived freshness)
- `chat.catchup_ms`
- `chat.catchup_ring_miss`
- `chat.full_reload_ms`
- `chat.inbound_queue_depth`
- `chat.timeline_apply_ms`
- `chat.timeline_layout_ms`

Interpretation:
- rising `fresh_content_lag_ms` with `cache=1` means stale-window problem
- high `full_reload_ms` during normal entry means reconciliation is overused
- high `inbound_queue_depth` means client is falling behind live updates

---

## 6) UX contract

- Entering/re-entering chat auto-follows latest message.
- If cache is shown but freshness is pending, UI should surface clear sync state (e.g. `Syncing latest…`).
- User should never need to infer whether they are seeing stale or fresh data.

---

## 7) Agent implementation guardrails

When changing chat entry/sync code:

1. Preserve this priority order:
   - stream/catch-up first
   - full reload as fallback
2. Do not add unconditional full reload on connect.
3. Keep behavior deterministic (no hidden side paths based on timing races).
4. Update telemetry + tests when changing freshness transitions.
5. Validate with real-session metrics, not simulator feel alone.

---

## 8) Acceptance criteria (for PRs changing this path)

A change is acceptable when:

1. `fresh_content_lag_ms` improves (or at least does not regress) at p50/p95.
2. Entry-time `full_reload_ms` incidence drops for healthy reconnect/entry cases.
3. No regression in catch-up correctness (`ring_miss` behavior still safe).
4. Manual refresh still performs full reconciliation correctly.

---

## 9) Non-goals

- Eliminating cache-first rendering.
- Removing full reload fallback entirely.
- Premature micro-optimizations without telemetry evidence.

The contract is about **predictability and freshness-first ordering**, not removing safety nets.
