# Durable conversation stream (experimental)

Part of [Oppi server architecture](../architecture-server.md). The wire that replicates one durable conversation's `{ entries, docs }` to a client. It is the server half of the durable-only target model. The iOS app attaches for durable sessions and feeds their timeline from the replica ([client flow](../architecture-client/flows.md#durable-sessions-the-conversation-stream)); v1 still changes in place.

## Gate and transport

- `GET /server/info` advertises `capabilities.conversationStream: { version: 2 }` whenever the server has a durable runtime (version 2 added [live tails](#live-tails) and `detach`; a client sends neither to a version 1 server, whose `attach` replaced the socket's only stream): `experimental.serverDurable` is on, or sessions are still bound to durable conversations after it was turned off.
- The stream rides the existing focused session socket (`/workspaces/:workspaceId/sessions/:sessionId/stream`, and `/control-sessions/:sessionId/stream`) and its auth. A new endpoint would have duplicated the session open, startup-dialog relay, auth expiry, and command routing that socket already owns, and commands still travel on it.
- Nothing changes until the client sends `attach`. A socket that never attaches gets exactly the classic event frames it got before.
- A socket that holds its own conversation's stream in full stops getting the classic events those entries and documents restate (`restatedByConversationStream` in `stream.ts`); a socket that only follows children's live tails keeps them all: `text_delta`, `thinking_delta`, `message_end`, `tool_start`/`tool_update`/`tool_output`/`tool_end`, `custom_card`, `compaction_start`/`compaction_end`, `retry_start`/`retry_end`, the broadcast `queue_state` and `queue_item_started`, and a `notice` whose id is `entry:<id>` (a committed card). The filter covers session broadcasts only: the bootstrap replay sent before `attach`, and a `queue_state` answering this socket's own `get_queue`, still go out.
- Everything else still goes to an attached socket, because no entry or document carries it to clients yet: `connected`, `state`, `session_summary`; `agent_start`, `agent_end`, `agent_settled` (the shared session row's status, screen-awake, Live Activity, the silence watchdog, TTFT); `stop_requested`/`stop_confirmed`/`stop_failed`; `error` (prompt and extension UI failures, connection errors, the fatal flag); other `notice`s (worktree rebind, store recovered); `cache_miss`; `session_ended`; `extension_ui_*`; `turn_ack`; `command_result`; `audio_stream`; `git_status`.
- `attach` is socket-only. It is not a `ClientMessage` command, so `POST /sessions/:id/command` answers it as an unknown type.

## Messages

Types live in `server/src/types/protocol.ts` (`ConversationStreamAttach`, `ConversationStreamOlder`, `ConversationStreamServerMessage`, `ConversationEntryView`, `ConversationDocOp`). Canonical examples are in `protocol/conversation-stream.json`, kept apart from `server-messages.json`, whose examples must all decode as known events in the Apple client.

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

- `attach` targets the socket's bound session. `sessionId`, when present, must name that session. `conversationId` defaults to its conversation; in `live` mode it may name a conversation in that conversation's ownership subtree (see [Live tails](#live-tails)). A session that is not bound to a durable conversation (classic, mirror, or a durable request that never bound) fails. With a `requestId` the answer is `command_result { command: "attach" }`, sent after the first stream frame; without one a failure is an `error` frame. A socket streams each conversation at most once: a second `attach` of the same conversation replaces the first, and `detach { conversationId }` ends it (`command_result { command: "detach" }`; detaching a conversation the socket does not stream succeeds).
- Frames carry no `seq`. The socket is ordered and lossless; across reconnects the cursor is the newest entry id the client holds.
- `ConversationEntryView` is the Durable `EntryRecord` without `conversationId`, `byTaskId`, `head`, `edits`, and `data`. Its `model` messages keep only the fields clients read (`CLIENT_MESSAGE_FIELDS` and `CLIENT_BLOCK_FIELDS` in `durable-conversation-view.ts`): `role`, `content`, and `timestamp`; `stopReason` and `errorMessage` on assistant messages; `toolCallId`, `toolName`, `isError`, and `details` on tool results; nothing but `role` and `timestamp` on system messages. Content blocks drop thinking and text signatures. A user message's image block leaves as a reference to the session attachment store (`{ type: "image", mimeType, attachment }`, no `data`): `projectEntry` stores its bytes with `storeUserMessageImages` at projection time, content-addressed and idempotent, and the reference carries the owning `sessionId` so a client fetches from the right session. An image it cannot store keeps its data URI as the tool-result fallback does; the Apple projector then adds a `{ kind, mimeType, inline: true }` placeholder in `media` for it, so a mixed message keeps content order. Provider replay state, diagnostics such as `inputTransformations`, usage, and timing stay on the server; storage still has them for replay. Roles and block types the projection does not list arrive whole. Raw `data` is extension bookkeeping that can hold server paths, so it never leaves the server; a display entry reaches the client only as its sanitized `card`. Tool-result `details` are sanitized like trace history (no server paths). Assistant entries add `toolCalls[callId]` and tool-result entries add `toolResult`, rendered by the same `MobileRendererRegistry` as classic `tool_start`/`tool_end`. A result whose details name an MCP server and tool adds `toolResult.display`. Entries also carry the presentation trace history gives them (see [Entry presentation](#entry-presentation)).
- Clients upsert entries by id. An id the client does not hold goes in id order after the head entry; in practice every new entry is newer than all held ones and appends.
- `snapshot.entries` are the shown active context in display order, cut to the newest `CONVERSATION_SNAPSHOT_LIMIT` (100) active entries. After a reset or compaction the head entry comes first, then the kept entries from its head (which have smaller ids). The cut only falls after the head entry, so a snapshot that carries the head entry carries all its kept entries too. `head` is that entry's id, or 0. `hasOlder` says entries exist before the first one sent; the client pages the rest in with `older`. Without the cut, a long uncompacted conversation sent its whole context (megabytes once it held images) as one frame on every fresh attach.
- `older` pages history before the replica: `beforeEntryId` is the smallest entry id the client holds. The answer is an `older` frame with up to `limit` (default 100, at most 500) shown entries before it, oldest first, with the same presentation, then `command_result { command: "older" }` when the request had a `requestId`. It pages the bound conversation and needs its full `attach` on the same socket first. The server reads `conversation.entries()` newest first, as the trace pages do.

## Live tails

A parent shows what its subagents are doing without opening them. `attach { conversationId, mode: "live" }` streams a conversation's live tail on the parent's socket: the documents marked `live` in `CONVERSATION_CLIENT_DOCS` (`pi.live` and `pi.inbox`) and no entries. Its frames multiplex with the bound conversation's by `conversationId`.

- **Who.** The target must be the bound conversation or one it owns, directly or through its children: `DurableThreads.ownsWithin` walks the target's owner edges (the edge `forCaller` checks) up to the bound conversation, within the bound session's store. Anything else, an ancestor included, fails like any refused `attach`. `full` mode stays limited to the bound conversation, so `older` and resume cursors keep one meaning.
- **Frames.** Every live attach answers with a `snapshot` whose `entries` are `[]`, `head` is 0, and `hasOlder` is false, and whose `docs` hold only the live documents; then `update` frames carry only those documents' ops. There is no cursor (`afterEntryId` with `live` is refused) and head moves send nothing, since no entries were sent. A room lost and re-attached sends a new live snapshot.
- **Cost.** A live subscription joins the conversation's shared room, which loads the conversation's active entries (the live view reads committed tool calls from them), so the first live attach of an unopened child reads its context. The client caps how many it follows.
- **Opening the child.** Its own Session's socket attaches it in `full` mode as before.

## Entry presentation

The timeline shows some entries differently from their content. The stream decides this with the helpers trace history uses in `projectEntries` (`server/src/durable-history.ts`), so the replica and the trace agree. No rule branches on an extension or entry kind.

| Entry | Trace rule | On the wire |
| --- | --- | --- |
| Extension-generated input | `readDurableInputCards`: a receipt for a request id with card metadata in `oppi.input-cards` | `{ id, kind, card, inputCard: true }`. The input text is not sent, as the trace does not return it. |
| No model messages and a valid `data.card` | `sanitizeTranscriptCard(data.card)` | `{ id, kind, card }` |
| Input from another agent session (`oppi.agent-message`) | `agentMessageOrigin(kind, data)` | The entry plus the validated `origin` and `textOffset`. The client shows the text after `textOffset` (the model-only header), as `agentMessageText` does. |
| Partial answer of a retried attempt | `isRecoveredPartial` | Left out of snapshots and of `entriesAfter`; an already-sent entry is upserted as `{ id, kind, hidden: true }` |

Input cards and hiding depend on state outside the entry: receipts and card metadata, and the attempt's task record. The room therefore decides them in presentation passes, asynchronous and serialized, that call the trace helpers. A pass runs when entries arrive (input cards for new user entries, hiding for every active aborted attempt), when `oppi.input-cards` changes (all user entries, so a late card still applies), and when a commit changes an attempt's task. Subscribers hold frames while a pass runs and flush when it ends, so a new entry never goes out before its presentation is decided. In practice a recovered partial is therefore never sent at all.

The `pi.inbox` view depends on the same kind of outside state: each queued input's stored display (`readQueuedInput` in `durable-agent-controller.ts`, which `get_queue` uses too) and whether an input-card receipt makes it a generated input. The same passes decide it when `pi.inbox` or `oppi.input-cards` changes, so a queued input never goes out with its raw content or before it is known not to be generated. A display is read once per input; generated inputs are checked again on every such pass.

A commit the room cannot apply closes it the same way, since the room no longer matches the store. A pass that fails (a store read error) closes the room without flushing, since its entries' presentation is undecided. Each subscription reports the loss to its owner; `SessionHost` re-attaches the socket from its cursor to a fresh room, whose load decides presentation before the first frame. If that attach fails too, the error is logged and the socket gets no more stream frames until the client attaches again.

A presentation that changes after an entry was sent bumps the room's presentation revision for that entry, and the next `update` restates it: `hidden: true`, or the whole entry with its card. A resumed client gets every held aborted attempt and input card restated, since its copies may predate the change.

Restatements stop at the subscription's window floor: the oldest entry its snapshot sent, or for a resume the room's current floor. A restated entry the client does not hold would be placed before its window and make the next `older` skip the entries between. The floor counts hidden entries, so it only rises until the head moves and a resumed client always holds everything from it. Entries the client paged in through `older` keep the presentation they had, like trace history pages.

## Documents

Visibility is metadata, not names in client-facing code. `CONVERSATION_CLIENT_DOCS` in `server/src/durable-conversation-view.ts` lists `{ doc, client: true, view? }` specs; the room iterates the list and never branches on a kind.

| Kind | Source | Client projection |
| --- | --- | --- |
| `pi.live` | Pi built-in | Adds `toolCalls[callId]` for the streaming answer's tool calls and the running round; slot `details` sanitized |
| `pi.inbox` | Pi built-in | The queue as `get_queue` shows it (`ConversationQueueView`): `{ steering, followUp }` of `MessageQueueItem` (`id` is the submission id; `message`, `attachments`, and `createdAt` from the prompt's stored display, else the content's text), in inbox order. Writes, extension-generated inputs, and model content (image data included) stay on the server |
| `pi.agent`, `pi.usage` | Pi built-ins | As committed |
| `oppi.extension-ui` | `DurableUIClientDoc` in `pi-extensions/durable-ui.ts` | Open requests and notification slots through the existing allowlist; answered requests and task ids stay private |

`pi.provider` and every other document stay on the server. An extension makes a document visible by exporting its own spec and adding it to the list; the §4 extension loader will collect them instead.

Documents travel as Chord ops (`@earendil-works/chord/delta`), computed per socket with `diffRevisions(lastSent, current)` over the projected values:

| Op | Meaning |
| --- | --- |
| `["r", value]` | Replace the whole document |
| `["s", path, value]` | Set |
| `["d", path]` | Delete (array index or key) |
| `["a", path, text]` | Append to a string |
| `["t", path, n]` | Drop the first `n` characters of a string (bounded tool output windows) |
| `["p", path, index, deleteCount, items]` | Splice an array |
| `["m", path, permutation]` | Reorder an array, `new[i] = old[permutation[i]]` |

Paths are arrays of keys and indexes, always inline (no Chord wire interning). `null` instead of ops means the document is gone. Text that only grew is always an `a` op; `diffRevisions` falls back to `["r", value]` only when the delta would cost more than the document.

## Delivery

`server/src/durable-conversation-stream.ts` keeps one `ConversationRoom` per attached conversation, shared by its sockets and closed with the last one. Sockets reach it through `SessionHost.transcript(conversationId, { renderers, afterEntryId?, send })`, which holds the store open (`stream`) until the returned function ends the subscription. `older` pages go through `SessionHost.olderEntries(conversationId, { renderers, beforeEntryId, limit? })`, which reads storage without a room.

- The room loads `conversation.viewState()` plus `harness.snapshot` for listed documents outside the Pi view, after subscribing to `harness.subscribeCommits`. Commits that land during the load are replayed over it; replay is idempotent.
- Each commit publication updates the room synchronously, so the room never holds part of a commit. Each socket remembers what it sent and flushes at most every 100 ms (Durable's progress interval), leading edge after a quiet period. One `update` is therefore a whole number of commits: the new assistant entry and the cleared `pi.live.generation` always share a frame.
- A head entry (reset or compaction) makes the next flush a `snapshot`.
- A presentation pass (see [Entry presentation](#entry-presentation)) holds every subscriber's next frame, and the first frame of an attach, until it ends.
- **Resume:** `attach { afterEntryId }` answers with an `update` when the id is an active entry at or after the head: restated presentation (above), the entries after it, and every listed document whole (`r`, or `null` when absent) because the client's copies are unknown. Any other cursor (missing, unknown, or older than the head) gets a `snapshot`. The entries come from the room's active set, which is loaded from storage and advanced from durable commit publications, so the gap never expires and needs no second storage read racing the live tail.

## Proof

- `server/tests/durable-conversation-view.test.ts` checks entry projection: a user image arrives as a stored reference with no bytes, an unstorable image stays inline, and repeated projection stores it once.
- `server/tests/durable-conversation-stream.test.ts` runs a real Harness with a faux provider: append ops, the single landing frame, coalescing, tool presentation on entries and `pi.live`, resume after a mid-turn disconnect, head moves, stale and unknown cursors, document visibility, the busy run with a queued steer and follow-up in the `pi.inbox` view (a generated input left out), input and display cards (including card metadata that lands after its input), a partial that a restarted generation retried, an attempt upserted as hidden after the client held it, `older` pages, and a snapshot cut to its window that pages back to the whole context. Every replica is checked against a fresh reference read with the trace's own presentation helpers.
- `server/tests/durable-conversation-stream.integration.test.ts` drives a real `Server` over WSS: the capability, snapshot on attach, appends, the landing frame, an attached socket getting no restated classic event while a plain socket gets them all, a steer and a follow-up sent mid-turn showing only in `pi.inbox` and `pi.live.run`, resume after a disconnect while a turn ran, a `compact` command forcing a snapshot, `older` after it, `older` refused before `attach`, a socket without `attach` getting no stream frames, a classic session refusing `attach`, and a subagent's live tail on its parent's socket (refused in full mode, outside the thread, and upward from the child; no entries; a reconnect mid-answer; `detach`). The unit suite checks that a live subscription gets only the live documents through turns and a head move. It writes payload sizes for one streamed reply to `$TMPDIR/oppi-conversation-stream-payload.json`.
- `protocol/conversation-stream-golden.json` holds every frame one client received for a real Harness conversation (thinking, a bash call with terminal output, a failing call, an image input, a display card, an input card, a real compaction, a restart that retried an answer, and `older` pages) and that conversation's mobile trace (`view=full` with presentation segments). `server/tests/conversation-stream-golden.ts` writes it, run only by `npm run protocol:fixtures:update`. The Apple `ConversationStreamTests` replays the frames into `ConversationReplica`, projects them with `ConversationTraceProjector`, and requires exactly th`ChatSessionManager` attaches when the focused socket connects a durable session on a server with the capability, and `ConversationStreamDriver` owns the replica, `attach`/`older`, and the timeline sync. On a version 2 server it also follows its subagents' [live tails](#live-tails) with one live `ConversationStreamDriver` each, routing frames by `conversationId`; the timeline shows each busy child's tail under the tool row whose details name it (see the [client flow](../architecture-client/flows.md#durable-sessions-the-conversation-stream)). `ServerMessage.conversationStream` decodes the three frames on the focused socket, and `ServerConnection` routes them to the session the socket is bound to, since they carry no `sessionId`. `ClientMessage.conversationAttach` and `.conversationOlder` encode the requests.

## Client

`ChatSessionManager` attaches when the focused socket connects a durable session on a server with the capability, and `ConversationStreamDriver` owns the replica, `attach`/`older`, and the timeline sync. On a version 2 server it also follows its subagents' [live tails](#live-tails) with one live `ConversationStreamDriver` each, routing frames by `conversationId`; the timeline shows each busy child's tail under the tool row whose details name it (see the [client flow](../architecture-client/flows.md#durable-sessions-the-conversation-stream)). `ServerMessage.conversationStream` decodes the three frames on the focused socket, and `ServerConnection` routes them to the session the socket is bound to, since they carry no `sessionId`. `ClientMessage.conversationAttach` and `.conversationOlder` encode the requests.

- **Busy, stop, and queue.** The session's own driver (full mode) reads `pi.live.run` into `isRunning`, which the chat's busy indicator and stop button use while it is set; it is nil before a socket's first frame, including a socket that replaced the last one in place, and after the socket ends; the chat reads the session status then. After every applied frame it hands the decoded `pi.inbox` view to `MessageQueueStore.applyConversationQueue`, which takes that session's queue over from `queue_state` until the runtime ends: items a `get_queue` answer put there first are replaced, later `get_queue` answers and `queue_item_started` no longer change it, and a stop keeps what the replica holds. Child live tails feed neither: their frames go to their own drivers and touch only the tail rows. An in-place reconnect resets only the own driver's run state; the followed children attach again on the new socket. Only items `enqueueOptimisticItem` added stay as pending: a sent steer or follow-up shows until its acknowledgement, then gives way at the next frame (or at once when the replica already shows its text), so it neither lingers nor shows twice. A `pi.inbox` that does not decode as the queue view (an older server) shows an empty queue and is logged as an error with the decode failure.
- **Rows only classic frames carry.** `ChatSessionManager.routeToConversationTimeline` turns `notice` (not `entry:<id>`), `error`, `cache_miss`, `session_ended`, stop feedback, and a failed or model/thinking `command_result` into `TimelineClientRow`s that it writes with `TimelineReducer.appendClientRow`, not through `DeltaCoalescer`. Rows that arrive while the scene is paused wait and follow the resync on resume.
- **Other effects.** A committed tool result whose `outputPresentation.settingEffect` is `voiceReplyMode` applies it when an `update` brings it (snapshots and `older` pages are history). Conversation frames feed the silence watchdog, and the first content in `pi.live.generation` completes TTFT.

`OppiTests/Chat/ConversationStreamSessionTests` drives the runtime with scripted frames: resume cursor, fresh attach after a failed apply or attach (one retry per socket), incremental append, the landing keeping live row ids, ignored classic events and the classic-only rows that still show (including while paused), busy state and the queue from the replica, a landed setting result, pending prompts taken in order, and `older`. `ConversationStreamPerfTests` prints per-frame main-thread cost on a 1,600-entry conversation. `OppiE2ETests/DurableSessionE2ETests` runs the faux model on a real server: a reply streaming live and landing once, a steer and a follow-up queued mid-turn, stop mid-turn, and a dropped connection while busy that resumes and lands each reply once.

## Not yet covered

- The classic events listed under [Gate and transport](#gate-and-transport) still reach an attached socket. The shared session row's status, Live Activity, and screen-awake still follow `agent_start`/`agent_settled` and `state`; prompt errors, notices, cache misses, and why a session ended exist only as frames.
- The Mac app does not attach, so its durable sessions keep the classic event path, `DeltaCoalescer`, and the reducer's event handling.
- `toolResult.display` cannot restore an MCP server's configured spelling for `mcp__` tool names, which the trace route does with the session's MCP server names (`resolveToolDisplay`'s `configuredServerNames`). Titles from result details are exact.
- Nested codemode calls (`nestedCalls` on tool results) are not projected; durable sessions do not produce them.
- Paging reads entries before the oldest held id. A second compaction whose kept range starts before the first compaction's marker leaves that marker out of the active view, and `older` never returns it.
