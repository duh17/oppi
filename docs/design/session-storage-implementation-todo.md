# Session Storage Optimization — Implementation TODO

Status: Phase 1/2 complete (manual validation in progress)  
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
- [x] Define post-migration success metrics:
  - sessions dir size at current workload (target: < 5 MB)
  - no reconnect/catch-up regressions
  - session list and chat history parity

---

## Phase 1 — Metadata-only session file format

### Storage layer

- [x] Update `server/src/storage.ts`:
  - `saveSession(session)` writes `{ session }` only
  - `getSession(sessionId)` reads `{ session }` only
  - `listSessions()` reads `{ session }` only
- [x] Remove message-array write/read paths:
  - stop persisting `messages[]`
  - remove related storage APIs/call sites

### Session update flow

- [x] Update `server/src/session-protocol.ts`:
  - stop depending on persisted SessionMessage list
  - keep in-memory session counters (`messageCount`, `tokens`, `cost`, `lastMessage`) updated from live events
- [x] Update comments in `server/src/sessions.ts` that mention SessionMessage fallback

### Types and API

- [x] Keep public session payload shape unchanged (`Session` fields stay)
- [x] Confirm no active endpoint requires persisted `messages[]` for iOS flows

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

## Phase 3 — Deferred (not needed)

Decision: skip compact session-level git summary fields for now.
Current UX uses live `git_status` API/push; no additional persisted git summary is required.

---

## Validation Checklist

### Automated

- [ ] `cd server && npm run check`
- [x] Targeted server tests:
  - storage/session lifecycle
  - user-stream websocket/reconnect
  - protocol snapshots
- [ ] `cd ios && xcodebuild ... build`
- [ ] `cd ios && xcodebuild ... test`

### Manual

- [x] Open existing sessions and verify history loads from trace
- [ ] Run long codex session, ensure live streaming unchanged
- [ ] Verify session list metadata (last activity, tokens, change stats) still updates
- [x] Verify changed-files overflow presentation in iOS

### Operational metrics

- [x] Measure `~/.config/oppi/sessions` size before/after
  - current: 307 files, ~0.44 MB total
- [ ] Spot-check event-loop responsiveness during heavy streaming
- [x] Confirm no regressions in reconnect catch-up behavior

---

## Roll-forward Plan

- [x] If regression appears, fix forward with metadata-only storage intact
