# Session Storage Profile and WSS Relationship

Status: Draft  
Owner: server/runtime  
Updated: 2026-02-21

Implementation checklist: `docs/design/session-storage-implementation-todo.md`

## Scope

This document captures the current Oppi session-storage footprint on Chen's primary machine and explains whether the issue is related to WebSocket architecture.

Dataset sampled:
- `~/.config/oppi/sessions/*.json` (session metadata + persisted message arrays)
- Referenced pi JSONL traces (`session.piSessionFile`)

Sample window:
- 304 sessions
- ~14 days of activity

## Observed Usage Pattern

The dominant pattern is long autonomous coding sessions:
- very low user-input volume
- very high assistant-output volume
- heavy tool output and large assistant messages

Observed ratio in persisted session messages:
- user text: ~0.26 MB
- assistant text: ~184.81 MB
- assistant share: ~99.86%

## Storage Findings

### Session JSON files (`~/.config/oppi/sessions`)

- Total: **~202.92 MB**
- Median file size: **~387 KB**
- P95 file size: **~2.13 MB**
- Max file size: **~14.11 MB**

Concentration:
- Top 20 largest sessions account for ~38.5% of total bytes
- Top 50 largest sessions account for ~58.1% of total bytes

Model skew:
- `openai-codex/gpt-5.3-codex`: ~5.9 KB per message (average)
- `anthropic/claude-opus-4-6`: ~2.0 KB per message (average)

### Trace JSONL files (`session.piSessionFile`)

- Existing referenced traces: 278 files
- Total: **~577.36 MB**
- Median: **~1.15 MB**
- P95: **~6.58 MB**
- Max: **~28.30 MB**

### Main Root Cause

`session` metadata and `messages[]` are stored in the same JSON file, and updates are full read/parse/rewrite operations:

- `Storage.saveSession()` preserves `messages[]` by reading existing file, then rewrites full payload
  - `server/src/storage.ts`
- `Storage.addSessionMessage()` reads full file, appends, rewrites full file (synchronous)
  - `server/src/storage.ts`

If session files were metadata-only (`{ session }`), measured footprint would be ~0.44 MB instead of ~202.92 MB (~99.8% reduction).

## Is this related to WSS design?

Short answer: **not a protocol-design issue, but it does affect runtime behavior around WSS.**

### Not directly related (protocol semantics)

The `/stream` WebSocket protocol, multiplexing model, subscription levels, and sequence logic (`seq`, `streamSeq`) are independent of how session messages are persisted on disk.

### Indirectly related (runtime performance/latency)

Storage behavior can increase event-loop pressure and show up as streaming instability symptoms:

1. **Synchronous full-file rewrites on message append**
   - Can delay handling of inbound/outbound WS frames under load.

2. **Synchronous full-file parse for session lookups**
   - `storage.getSession()` parses large files that include full `messages[]` even when caller only needs `session` metadata.

3. **Reconnect recovery path pressure**
   - Reconnect/fallback paths combine WS + REST; extra blocking I/O increases recovery latency and jitter.

So this is best classified as a **storage-layer hot-path issue that can degrade perceived WSS responsiveness**, not a flaw in WSS architecture itself.

## Decision (2026-02-21)

1. **Pi JSONL trace is the only history source-of-truth.**
   - Session timeline/history comes from `piSessionFile` / `piSessionFiles`.
2. **Oppi session JSON is metadata/index only.**
   - No persisted `messages[]` duplication.
3. **No new sidecar history format** (NDJSON, fallback cache, etc.) unless it directly improves mobile UX.
4. **Trace-missing/corrupt fallback is not a blocker** for this optimization.

## Session Metadata Strategy (useful + efficient)

Keep session metadata small, incremental, and mobile-relevant.

### Keep (control-plane + UX index)

- identity/routing: `id`, `workspaceId`, `workspaceName`
- lifecycle: `status`, `createdAt`, `lastActivity`
- model/runtime state: `model`, `thinkingLevel`, `contextTokens`, `contextWindow`
- trace pointers: `piSessionFile`, `piSessionFiles`, `piSessionId`
- compact UX summaries: `messageCount`, `tokens`, `cost`, `lastMessage`

### Keep for session-change tracking

- `changeStats` aggregate fields:
  - `mutatingToolCalls`
  - `filesChanged`
  - `changedFiles` (bounded sample)
  - `addedLines`, `removedLines` (best-effort)

### Recommended bounds for efficiency

- cap `changedFiles` to a fixed sample (e.g. 50-100)
- store overflow count separately (e.g. `changedFilesOverflow`)
- do not persist full git file lists per session snapshot

### Git tracking guidance

- Live, detailed git state belongs in existing `git_status` push/API.
- Persist only compact session-level git summary if needed for UX:
  - branch/head at start/end
  - uncommitted count at end
  - ahead/behind/stash counts at end

## Optimization Plan

### P0 (highest ROI): metadata-only session files

- Write `sessions/<id>.json` as `{ session }` only.
- Remove persisted `messages[]` writes from hot path.
- Keep history rendering on trace readers (`trace.ts`, `piSessionFile` pointers).

Expected impact:
- ~99% reduction in session-file footprint
- substantially less parse/rewrite overhead
- reduced event-loop blocking risk

### P1: bound change-tracking payloads

- cap `changeStats.changedFiles`
- add overflow counter
- keep aggregate counts only

### P2: optional compact git summary on session

- add tiny persisted git-summary fields only if needed for session-list UX
- avoid persisting full `git_status.files` arrays

## Suggested Acceptance Metrics

After P0/P1:
- `~/.config/oppi/sessions` total size < 5 MB at current workload
- median `storage.getSession()` latency reduced by >80%
- no measurable WS send/receive jitter regression during long codex sessions
- reconnect + catch-up behavior unchanged (protocol tests green)
- session change summaries (`changeStats`) remain available in iOS session rows/context bar

## Compatibility Notes

Migration should be backward-compatible:
- read legacy `{ session, messages }`
- write new `{ session }` format
- preserve iOS-visible session metadata behavior
- do not change `/stream` contract as part of storage migration
