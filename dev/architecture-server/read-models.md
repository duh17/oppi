# Oppi server architecture: Read models and event stream

Part of [Oppi server architecture](../architecture-server.md); same standard (owners, boundaries, invariants, entry points).

## Session list and history read models

- `SessionListService` builds lists from live snapshots, `session-sqlite-store.ts`, and the cached `local-sessions.ts` catalog, never full JSONL traces. The catalog's optional compact Git summary uses a lightweight status probe, not the review status payload.
- The recent lane is time-bounded (`sinceMs`, `untilMs`). `SessionListService` alone places older and importable sessions in archive buckets in the server's local time zone: a day for the last 30 days, else a month, each ending at local midnight. The client caps bucket requests at its recent lane's start (`beforeMs`), so a session is never in both; a time-zone mismatch can still split one calendar day.
- `SessionTraceService` owns trace paging, outlines, recovery, tool output lookup, diffs, and changed-file previews. Full trace reads (`readSessionTrace`, `readSessionTraceFromFile(s)`, `readSessionTraceByUuid`) stay behind recovery and compatibility paths.

## Session change views

- **Touched list** (`changeStats.changedFiles`, `GET …/changes`, `…/diff?path=`): paths the session's own `edit`/`write` calls named, recorded without git by `updateSessionChangeStats`; approximate, and the only view a main-checkout session has. Harness URLs (`agent://`, `local://`) never count. The per-file diff is rebuilt from the trace (`diff-core.ts`).
- **Worktree view** (`changeStats.worktree`, `GET …/worktree-changes`, `…/worktree-diff?path=`): for a session in its own worktree, git's change set against the merge-base with `main-worktree/HEAD`, shared by every session in that worktree; `sessionTouched` marks this session's files.

`session-git-changes.ts` owns the worktree view and its git budget:

- Git is read-only plumbing (`rev-parse`, `merge-base`, `diff-index`, `ls-files`, `cat-file`). Porcelain `git diff`/`status` rewrite the index and collide with an agent's own `git commit` on `index.lock`.
- Nothing runs per tool call: a tool end bumps an in-memory generation. One read runs on `agent_settled` (not `agent_end`, which precedes an automatic retry) of a turn that ran a tool, stores a bounded result (up to 100 paths), and summaries carry counts only, so list rows never run git. One read per worktree at a time, shared by concurrent callers; `worktree-changes` reuses the snapshot while generation, index/HEAD/reflog mtimes, and a 10 s age match.
- A HEAD that is the merge-base counts as a landing only with evidence of commits made in the worktree: the main checkout's reflog entry naming the worktree's HEAD (last 64 KB, no git process) plus the worktree's own HEAD reflog showing it made that commit; else the commits stored at the last turn end. A HEAD that arrived from outside (fast-forward sync, reset, checkout) is never a landing. Known misses: a commit and landing in the same turn with reflogs off or past 64 KB, and `--no-ff` landings.
- A removed worktree answers the list stored at the last turn end (`live: false`) and diffs from the main checkout's object store, falling back to the trace diff.

## App event stream

`AppEventStreamMux` sends only allowlisted `AppEventMessage` types: session created/imported/discovered/deleted/ended, summaries, stop requested/confirmed/failed, errors, extension UI request/settled and notifications other than surface and editor methods, workspace git changed, and connected. It never sends timeline deltas, full state, queue state, command results, dictation, or raw `GitStatus`. Surface and editor notifications (`setStatus`, `setWidget`, `setTitle`, `setWorking*`, `setHiddenThinkingLabel`, `setToolsExpanded`, `set_editor_text`) stay on the session's own stream, which replays persistent ones on subscribe. On connect it sends `app_events_connected { snapshotRequired: true }`; clients repair through HTTP.
