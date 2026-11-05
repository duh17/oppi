# Durable conversation stream (experimental)

Part of [Oppi server architecture](../architecture-server.md). The wire that replicates one durable conversation's `{ entries, docs }` to a client, and the [Apple client](#apple-client) replica.

## Gate and transport

- `GET /server/info` advertises `capabilities.conversationStream: { version: 2 }` whenever the server has a durable runtime. A client sends version 2's [live tails](#live-tails) and `detach` only to version 2: a version 1 `attach` replaced the socket's only stream.
- The stream rides the focused session socket (`/workspaces/:workspaceId/sessions/:sessionId/stream`, `/control-sessions/:sessionId/stream`) and its auth, because that socket already owns session open, startup dialogs, auth expiry, and command routing. `attach` is socket-only, not a `ClientMessage` command.
- Nothing changes until the client sends `attach`. A socket holding its own conversation in full stops getting the classic events the stream restates (`restatedByConversationStream` in `stream.ts`), `cache_miss` included; the bootstrap replay and a `queue_state` answering its own `get_queue` still go out. Everything else (`state`, run boundaries, stop feedback, `error`, other notices, `session_ended`, `extension_ui_*`, `command_result`, audio, `git_status`) still reaches an attached socket, because no entry or document carries it yet; session status, Live Activity, and screen-awake still follow those events.

## Messages

Types: `server/src/types/protocol.ts` (`ConversationStreamAttach`, `ConversationStreamOlder`, `ConversationStreamServerMessage`, `ConversationEntryView`, `ConversationDocOp`). Examples: `protocol/conversation-stream.json`, kept apart from `server-messages.json` because every example there must decode as a known Apple event.

```ts
// client → server
{ type: "attach"; conversationId?: number; sessionId?: string; mode?: "full" | "live"; afterEntryId?: number; requestId?: string }
{ type: "detach"; conversationId: number; requestId?: string }
{ type: "older"; beforeEntryId: number; limit?: number; requestId?: string }

// server → client
{ type: "snapshot"; conversationId: number; head: number; hasOlder: boolean;
  entries: ConversationEntryView[]; docs: Record<string, JsonObject> }
{ type: "update"; conversationId: number;
  entries?: ConversationEntryView[]; docs?: Record<string, ConversationDocOp[] | null> }
{ type: "older"; conversationId: number; entries: ConversationEntryView[]; hasOlder: boolean }
```

- `attach` targets the socket's bound session; a session not bound to a conversation fails. With a `requestId` the answer is `command_result { command: "attach" }` after the first frame. A socket streams each conversation at most once: a second `attach` replaces the first; `detach` ends it.
- Frames carry no `seq`: the socket is ordered and lossless, and across reconnects the cursor is the newest entry id the client holds. Clients upsert entries by id.
- `ConversationEntryView` sends only the fields clients read (`CLIENT_MESSAGE_FIELDS`, `CLIENT_BLOCK_FIELDS` in `durable-conversation-view.ts`). Tool-call arguments are resolved once by `resolveToolArguments` (`tool-call-arguments.ts`) for the stream, the trace, and Session Outline. User images leave as session attachment references (`storeUserMessageImages`). Raw entry `data` never leaves the server (it can hold paths); display entries leave only as a sanitized `card`, and tool details are sanitized like trace history. Codemode script calls become `toolResult.nestedCalls` (`durableNestedCalls`, recognized by shape, not tool name).
- `snapshot.entries` are the newest `CONVERSATION_SNAPSHOT_LIMIT` (100) active entries, cut only after the head entry (uncut, a long conversation sent megabytes per attach); `hasOlder` says more exist.
- `older` pages before `beforeEntryId` (default 100, at most 500) and needs a full `attach` on the same socket. Recovered partials are hidden by the trace pages' rule (`isRecoveredPartial`/`readRetryEvidence`, `durable-history.ts`).

## Live tails

`attach { conversationId, mode: "live" }` streams only the documents marked `live` in `CONVERSATION_CLIENT_DOCS` (`pi.live`, `pi.inbox`), multiplexed by `conversationId`. The target must be the bound conversation or one it owns (`DurableThreads.ownsWithin`, within the bound store); ancestors are refused. `full` mode stays limited to the bound conversation. A live snapshot has `entries: []`, `head: 0`; there is no cursor (`afterEntryId` with `live` is refused).

## Entry presentation

The stream uses the trace's helpers (`projectEntries` in `durable-history.ts`), so the replica and the trace agree; no rule branches on an extension or entry kind.

| Entry | Rule | On the wire |
| --- | --- | --- |
| Extension-generated input | `readDurableInputCards` | `{ id, kind, card, inputCard: true }`, no input text |
| No model messages, valid `data.card` | `sanitizeTranscriptCard` | `{ id, kind, card }` |
| `oppi.agent-message` input | `agentMessageOrigin` | entry plus `origin` and `textOffset` |
| Retried attempt's partial | `isRecoveredPartial` | omitted; a sent one is upserted `{ id, kind, hidden: true }` |
| Answer that re-billed cached context | `trackDurableCacheMisses` | entry plus `cacheMiss: { id, message }` |

Cache-miss notices are derived from saved usage, never stored, and only while the running backend's Pi `showCacheMissNotices` is on (a stopped session shows none). `cacheMiss.id` is the id of the runtime's live `cache_miss` frame for the same answer. The room feeds each entry to its tracker once, as it adds it; the room's first entry and each `older` page are compared through `readCacheMissSeed` (`durable-history.ts`), which reads back only to the newest answer that reported cache activity or the newest compaction or reset, at most 200 entries. An answer's notice therefore never changes, and an answer a compaction keeps keeps its notice.

Presentation passes run asynchronously and serialized when entries, `oppi.input-cards`, or an attempt's task change; subscribers hold frames until a pass ends, so a new entry (or a queued `pi.inbox` input) never goes out before its presentation is decided. A failed pass, or a commit the room cannot apply, closes the room without flushing; `SessionHost` re-attaches the socket from its cursor. A changed presentation is restated in the next `update`, never below the subscription's window floor (an entry placed before the client's window would make `older` skip entries).

## Documents

`CONVERSATION_CLIENT_DOCS` lists `{ doc, client: true, view? }` specs; the room never branches on a kind. Client-visible: `pi.live` (projected like entries; unchanged parts project to identical objects so `diffRevisions` sends small ops), `pi.inbox` (the `get_queue` view), `pi.agent`, `pi.usage`, `oppi.extension-ui` (through the extension UI allowlist); everything else stays on the server.

Documents travel as Chord ops (`@earendil-works/chord/delta`) from `diffRevisions(lastSent, current)`, decoded by `OppiCore/Models/ConversationStream.swift`; `null` means the document is gone. Grown text is always `a` (append); `r` (replace) only when a delta would cost more.

## Delivery

`durable-conversation-stream.ts` keeps one `ConversationRoom` per attached conversation, reached through `SessionHost.transcript(...)` (holds the store open) and `SessionHost.olderEntries(...)` (reads storage, no room).

- The room subscribes to commits before loading, then replays commits that landed during the load (idempotent). Each commit updates the room synchronously, and each socket flushes at most every 100 ms, so one `update` is a whole number of commits: a new assistant entry and the cleared `pi.live.generation` always share a frame.
- `pi.live` comes from a synchronous view observer (`observeConversation`), never from publications: pi-durable defers streamed text and tool output and publishes them only once stored, up to a second later. The observer advances inside a commit's adoption and the commit observer a microtask later, both before the flush timer.
- A head entry (reset or compaction) makes the next flush a `snapshot`.
- **Resume:** `attach { afterEntryId }` at or after the head answers an `update` with restated presentation, the later entries, and every document whole; any other cursor gets a `snapshot`. Entries come from the room's active set, so the gap never expires.

## Apple client

When the server advertises `capabilities.conversationStream` and the session is `engine: durable`, the timeline comes from this stream, with no flag and no fallback to events; stopped durable sessions are history-only.

- **Attach:** `ConversationStreamDriver` keeps the `ConversationReplica` across reconnects and resumes with `conversationId`/`afterEntryId`. A failed attach retries without a cursor once per socket; a second failure is fatal. A frame the replica cannot apply re-attaches without a cursor and drops frames until the snapshot.
- **Committed rows:** `ConversationCommittedProjection` projects only entries newer than the replica onto `TimelineReducer.applyConversationCommitted`'s incremental path (a full comparison is linear in the conversation); snapshots, `older` pages, and restated entries re-project. Each new committed user entry consumes the oldest pending optimistic prompt.
- **Live tail:** `ConversationLiveProjector` reads only `pi.live`. The frame that commits an answer also clears it from `pi.live` and applies in one main-actor turn, so there is no gap or duplicate; live rows keep their ids and `TimelineReducer.timelineItemID(for:)` maps committed ids to them.
- **Busy:** `ChatSessionManager.isBusy` is the one busy rule (`pi.live.run` from the session's own replica once seen, else session status); a child's tail never feeds it. Each owned apply stamps `isBusy`, so the frame that ends a run clears the working indicator in the same apply. The queue comes from `pi.inbox`.
- **Cache misses:** `ConversationTraceProjector` turns an entry's `cacheMiss` into a system trace event with `cacheMiss: true` after the answer, which `TimelineReducer` shows as the cache-miss row; it replaces a live `cache_miss` row with the same id, on the append path too.
- **Classic frames** that still arrive (`notice`, `error`, `session_ended`, stop feedback, failed command results) become `TimelineClientRow`s via `ChatSessionManager.routeToConversationTimeline` and survive rebuilds from the replica.
- **Child tails:** `ConversationChildIndex` finds children from tool `details` (`conversationId`, `sessionId`), never tool or extension names. The manager follows children the parent waits on, others only while a drawer is expanded (`followsReturnedChildren`), and none on a version 1 server. Frames route by `conversationId` (others are dropped); a refused live attach never touches the session's own stream; tails publish at most four times a second.
- **Paging** is `older { beforeEntryId }`. While the scene is paused, frames update only the replica and the timeline resyncs on resume.

## Proof

`server/tests/durable-conversation-view.test.ts` (projection), `durable-conversation-stream.test.ts` (real Harness), `durable-conversation-stream.integration.test.ts` (real server over WSS). `protocol/conversation-stream-golden.json` is written only by `npm run protocol:fixtures:update` (`server/tests/conversation-stream-golden.ts`); Apple `ConversationStreamTests` replays it into `ConversationReplica`, requires the identical trace, and fails if the fixture stops covering every trace event type and doc op.

## Not yet covered

- The Mac app does not attach.
- `toolResult.display` cannot restore an MCP server's configured spelling for `mcp__` names (the trace route can).
- Codemode call arguments over 200 characters arrive as `argumentsBytes` of pi-durable's cut text.
- A second compaction whose kept range starts before the first compaction's marker hides that marker from `older`.
