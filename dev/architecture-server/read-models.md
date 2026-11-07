# Oppi server architecture: Read models and event stream

Part of [Oppi server architecture](../architecture-server.md).

## Session list and history read models

- `SessionListService` builds lists from live snapshots, `session-sqlite-store.ts`, and the cached `local-sessions.ts` catalog, never full JSONL traces. The catalog's optional compact Git summary uses a lightweight status probe, not the review status payload.
- The recent lane is time-bounded (`sinceMs`, `untilMs`). `SessionListService` alone places older and importable sessions in archive buckets (server local time: a day for the last 30 days, else a month). The client caps bucket requests at its recent lane's start (`beforeMs`), so a session is never in both; a time-zone mismatch can still split one calendar day.
- `SessionTraceService` owns trace paging, outlines, recovery, tool output lookup, diffs, and changed-file previews. Full trace reads (`readSessionTrace`, `readSessionTraceFromFile(s)`, `readSessionTraceByUuid`) stay behind recovery and compatibility paths.
- Cache-miss notices are derived, never stored. `cache-miss.ts` ports Pi's `cache-stats` (thresholds, compaction and branch-summary resets, none on aborted or failed answers) but ignores `cache_warm` usage entries. Session start seeds the runtime's tracker from saved history (`replayCacheMissHistory`). While the running backend shows notices (`getCacheMissNotices`), `buildSessionContext` adds a `system` event with `cacheMiss: true` and the live `cache_miss` frame's id after the answer that paid. A trace page compares only answers inside its window.

## Session change views

- **Touched list** (`changeStats.changedFiles`, `GET …/changes`, `…/diff?path=`): paths the session's own `edit`/`write` calls named, recorded without git by `updateSessionChangeStats`; approximate, and the only view a main-checkout session has. Harness URLs (`agent://`, `local://`) never count. The per-file diff is rebuilt from the trace (`diff-core.ts`).

## App event stream

`AppEventStreamMux` sends only allowlisted `AppEventMessage` types (session lifecycle and summaries, stop feedback, errors, extension UI requests and non-surface notifications, workspace git changes); what it never carries is a [cross-system invariant](../architecture.md#cross-system-invariants). Surface and editor notifications (`setStatus`, `setWidget`, `setTitle`, `setWorking*`, `setHiddenThinkingLabel`, `setToolsExpanded`, `set_editor_text`) stay on the session's own stream, which replays persistent ones on subscribe. On connect it sends `app_events_connected { snapshotRequired: true }`; clients repair through HTTP.
