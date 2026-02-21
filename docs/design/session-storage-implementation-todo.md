# Session Storage Optimization — Implementation TODO

Status: Planned  
Owner: server/runtime  
Updated: 2026-02-21

Reference decision: `docs/design/session-storage-analysis.md`

## Goal

Make Oppi session files metadata-only while keeping pi JSONL trace as the sole history source-of-truth.

Non-goals:
- no new sidecar message-history format
- no fallback history cache format
- no `/stream` protocol changes

---

## Phase 0 — Guardrails and acceptance criteria

- [x] Confirm decision invariants in code comments/docs:
  - pi JSONL is history source-of-truth
  - `sessions/<id>.json` is metadata/index only
- [x] Define changed-files cap target (default: 100)
- [ ] Define post-migration success metrics:
  - sessions dir size at current workload
  - no reconnect/catch-up regressions
  - session list and chat history parity

---

## Phase 1 — Metadata-only session file format

### Storage layer

- [x] Update `server/src/storage.ts`:
  - `saveSession(session)` writes `{ session }` only
  - `getSession(sessionId)` reads both legacy and new format
  - `listSessions()` reads both legacy and new format
- [x] Remove/retire message-array write path:
  - stop persisting `messages[]` in `addSessionMessage`
  - keep function as compatibility shim or remove call sites
- [x] Add startup migration (opportunistic, in-place):
  - if legacy file contains `{ session, messages }`, rewrite as `{ session }`

### Session update flow

- [x] Update `server/src/session-protocol.ts`:
  - stop depending on persisted SessionMessage list
  - keep in-memory session counters (`messageCount`, `tokens`, `cost`, `lastMessage`) updated from live events
- [x] Update comments in `server/src/sessions.ts` that mention SessionMessage fallback

### Types and API compatibility

- [ ] Keep public session payload shape unchanged (`Session` fields stay)
- [ ] Confirm no active endpoint requires persisted `messages[]` for iOS flows
- [ ] Keep legacy decode compatibility for old files during transition

---

## Phase 2 — Efficient session change tracking

### Bound `changeStats` payload

- [x] Update `server/src/types.ts` `SessionChangeStats`:
  - add `changedFilesOverflow?: number`
- [x] Update `server/src/session-protocol.ts` `updateSessionChangeStats(...)`:
  - cap `changedFiles` to configured max (e.g. 100)
  - increment `changedFilesOverflow` when new unique files exceed cap
  - keep `filesChanged` as true unique total (not capped)

### iOS contract + UI

- [x] Update iOS model `ios/Oppi/Core/Models/Session.swift` for `changedFilesOverflow`
- [x] Update iOS UI surfaces to show overflow hint (e.g. “... and N more”)
  - `WorkspaceContextBar`
  - any session summary rows that list changed files
- [x] Add/adjust iOS tests for decoding and overflow rendering

### Protocol discipline checks

- [x] Update protocol snapshots/tests on both sides if payload changes:
  - `server/tests/protocol-snapshots.test.ts`
  - `ios/OppiTests/ProtocolSnapshotTests.swift`

---

## Phase 3 — Optional compact git summary on session (only if needed)

Only implement if mobile UX needs historical git summary without opening workspace git panel.

- [ ] Add minimal session-level git summary fields (if required):
  - branch/head start/end
  - uncommitted count end
  - ahead/behind/stash end
- [ ] Do **not** persist full `git_status.files` arrays in session metadata
- [ ] Keep detailed git state in existing `git_status` API + push path

---

## Validation Checklist

### Automated

- [ ] `cd server && npm run check`
- [ ] Targeted server tests:
  - storage/session lifecycle
  - user-stream websocket/reconnect
  - protocol snapshots
- [ ] `cd ios && xcodebuild ... build`
- [ ] `cd ios && xcodebuild ... test`

### Manual

- [ ] Open existing legacy sessions and verify history loads from trace
- [ ] Run long codex session, ensure live streaming unchanged
- [ ] Verify session list metadata (last activity, tokens, change stats) still updates
- [ ] Verify changed-files overflow presentation in iOS

### Operational metrics

- [ ] Measure `~/.config/oppi/sessions` size before/after
- [ ] Spot-check event-loop responsiveness during heavy streaming
- [ ] Confirm no regressions in reconnect catch-up behavior

---

## Rollback Plan

- [ ] Keep backward read compatibility for legacy files
- [ ] Keep migration idempotent and one-way safe (`{session,messages}` -> `{session}`)
- [ ] If regression appears, rollback write behavior while preserving read compatibility
