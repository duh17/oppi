# Durable conversation stream (experimental)

Part of [Oppi server architecture](../architecture-server.md). The wire that replicates one durable conversation's `{ entries, docs }` to a client. It is the server half of the durable-only target model. The iOS app attaches for durable sessions and feeds their timeline from the replica ([client flow](../architecture-client/flows.md#durable-sessions-the-conversation-stream)); v1 still changes in place.

## Gate and transport

- `GET /server/info` advertises `capabilities.conversationStream: { version: 1 }` whenever the server has a durable runtime: `experimental.serverDurable` is on, or sessions are still bound to durable conversations after it was turned off.
- The stream rides the existing focused session socket (`/workspaces/:workspaceId/sessions/:sessionId/stream`, and `/control-sessions/:sessionId/stream`) and its auth. A new endpoint would have duplicated the session open, startup-dialog relay, auth expiry, and command routing that socket already owns, and commands still travel on it.
- Nothing changes until the client sends `attach`. A socket that never attaches gets exactly the classic event frames it got before. An attached socket gets both: the event path is untouched until the cutover.
- `attach` is socket-only. It is not a `ClientMessage` command, so `POST /sessions/:id/command` answers it as an unknown type.

## Messages

Types live in `server/src/types/protocol.ts` (`ConversationStreamAttach`, `ConversationStreamOlder`, `ConversationStreamServerMessage`, `ConversationEntryView`, `ConversationDocOp`). Canonical examples are in `protocol/conversation-stream.json`, kept apart from `server-messages.json`, whose examples must all decode as known events in the Apple client.

```ts
// client → server
{ type: "attach"; conversationId?: number; sessionId?: string; afterEntryId?: number; requestId?: string }
{ type: "older"; beforeEntryId: number; limit?: number; requestId?: string }

// server → client
{ type: "snapshot"; conversationId: number; head: number; hasOlder: boolean;
  entries: ConversationEntryView[]; docs: Record<string, JsonObject> }
{ type: "update"; conversationId: number;
  entries?: ConversationEntryView[]; docs?: Record<string, ConversationDocOp[] | null> }
{ type: "older"; conversationId: number; entries: ConversationEntryView[]; hasOlder: boolean }
```

- `attach` targets the socket's bound session. `sessionId` and `conversationId`, when present, must name that session and its conversation. A session that is not bound to a durable conversation (classic, mirror, or a durable request that never bound) fails. With a `requestId` the answer is `command_result { command: "attach" }`, sent after the first stream frame; without one a failure is an `error` frame. A second `attach` on the same socket replaces the first.
- Frames carry no `seq`. The socket is ordered and lossless; across reconnects the cursor is the newest entry id the client holds.
- `ConversationEntryView` is the Durable `EntryRecord` without `conversationId`, `byTaskId`, `head`, `edits`, and `data`. Its `model` messages keep only the fields clients read (`CLIENT_MESSAGE_FIELDS` and `CLIENT_BLOCK_FIELDS` in `durable-conversation-view.ts`): `role`, `content`, and `timestamp`; `stopReason` and `errorMessage` on assistant messages; `toolCallId`, `toolName`, `isError`, and `details` on tool results; nothing but `role` and `timestamp` on system messages. Content blocks drop thinking and text signatures. Provider replay state, diagnostics such as `inputTransformations`, usage, and timing stay on the server; storage still has them for replay. Roles and block types the projection does not list arrive whole. Raw `data` is extension bookkeeping that can hold server paths, so it never leaves the server; a display entry reaches the client only as its sanitized `card`. Tool-result `details` are sanitized like trace history (no server paths). Assistant entries add `toolCalls[callId]` and tool-result entries add `toolResult`, rendered by the same `MobileRendererRegistry` as classic `tool_start`/`tool_end`. A result whose details name an MCP server and tool adds `toolResult.display`. Entries also carry the presentation trace history gives them (see [Entry presentation](#entry-presentation)).
- Clients upsert entries by id. An id the client does not hold goes in id order after the head entry; in practice every new entry is newer than all held ones and appends.
- `snapshot.entries` are the shown active context in display order, cut to the newest `CONVERSATION_SNAPSHOT_LIMIT` (100) active entries. After a reset or compaction the head entry comes first, then the kept entries from its head (which have smaller ids). The cut only falls after the head entry, so a snapshot that carries the head entry carries all its kept entries too. `head` is that entry's id, or 0. `hasOlder` says entries exist before the first one sent; the client pages the rest in with `older`. Without the cut, a long uncompacted conversation sent its whole context (megabytes once it held images) as one frame on every fresh attach.
- `older` pages history before the replica: `beforeEntryId` is the smallest entry id the client holds. The answer is an `older` frame with up to `limit` (default 100, at most 500) shown entries before it, oldest first, with the same presentation, then `command_result { command: "older" }` when the request had a `requestId`. It needs an `attach` on the same socket first. The server reads `conversation.entries()` newest first, as the trace pages do.

## Entry presentation

The timeline shows some entries differently from their content. The stream decides this with the helpers trace history uses in `projectEntries` (`server/src/durable-history.ts`), so the replica and the trace agree. No rule branches on an extension or entry kind.

| Entry | Trace rule | On the wire |
| --- | --- | --- |
| Extension-generated input | `readDurableInputCards`: a receipt for a request id with card metadata in `oppi.input-cards` | `{ id, kind, card, inputCard: true }`. The input text is not sent, as the trace does not return it. |
| No model messages and a valid `data.card` | `sanitizeTranscriptCard(data.card)` | `{ id, kind, card }` |
| Input from another agent session (`oppi.agent-message`) | `agentMessageOrigin(kind, data)` | The entry plus the validated `origin` and `textOffset`. The client shows the text after `textOffset` (the model-only header), as `agentMessageText` does. |
| Partial answer of a retried attempt | `isRecoveredPartial` | Left out of snapshots and of `entriesAfter`; an already-sent entry is upserted as `{ id, kind, hidden: true }` |

Input cards and hiding depend on state outside the entry: receipts and card metadata, and the attempt's task record. The room therefore decides them in presentation passes, asynchronous and serialized, that call the trace helpers. A pass runs when entries arrive (input cards for new user entries, hiding for every active aborted attempt), when `oppi.input-cards` changes (all user entries, so a late card still applies), and when a commit changes an attempt's task. Subscribers hold frames while a pass runs and flush when it ends, so a new entry never goes out before its presentation is decided. In practice a recovered partial is therefore never sent at all.

A pass that fails (a store read error) closes the room without flushing, since its entries' presentation is undecided. Each subscription reports the loss to its owner; `SessionHost` re-attaches the socket from its cursor to a fresh room, whose load decides presentation before the first frame. If that attach fails too, the error is logged and the socket gets no more stream frames until the client attaches again.

A presentation that changes after an entry was sent bumps the room's presentation revision for that entry, and the next `update` restates it: `hidden: true`, or the whole entry with its card. A resumed client gets every held aborted attempt and input card restated, since its copies may predate the change.

Restatements stop at the subscription's window floor: the oldest entry its snapshot sent, or for a resume the room's current floor. A restated entry the client does not hold would be placed before its window and make the next `older` skip the entries between. The floor counts hidden entries, so it only rises until the head moves and a resumed client always holds everything from it. Entries the client paged in through `older` keep the presentation they had, like trace history pages.

## Documents

Visibility is metadata, not names in client-facing code. `CONVERSATION_CLIENT_DOCS` in `server/src/durable-conversation-view.ts` lists `{ doc, client: true, view? }` specs; the room iterates the list and never branches on a kind.

| Kind | Source | Client projection |
| --- | --- | --- |
| `pi.live` | Pi built-in | Adds `toolCalls[callId]` for the streaming answer's tool calls and the running round; slot `details` sanitized |
| `pi.inbox`, `pi.agent`, `pi.usage` | Pi built-ins | As committed |
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

- `server/tests/durable-conversation-stream.test.ts` runs a real Harness with a faux provider: append ops, the single landing frame, coalescing, tool presentation on entries and `pi.live`, resume after a mid-turn disconnect, head moves, stale and unknown cursors, document visibility, input and display cards (including card metadata that lands after its input), a partial that a restarted generation retried, an attempt upserted as hidden after the client held it, `older` pages, and a snapshot cut to its window that pages back to the whole context. Every replica is checked against a fresh reference read with the trace's own presentation helpers.
- `server/tests/durable-conversation-stream.integration.test.ts` drives a real `Server` over WSS: the capability, snapshot on attach, appends, the landing frame, resume after a disconnect while a turn ran, a `compact` command forcing a snapshot, `older` after it, `older` refused before `attach`, a socket without `attach` getting no stream frames, and a classic session refusing `attach`. It writes payload sizes for one streamed reply to `$TMPDIR/oppi-conversation-stream-payload.json`.
- `protocol/conversation-stream-golden.json` holds every frame one client received for a real Harness conversation (thinking, a bash call with terminal output, a failing call, an image input, a display card, an input card, a real compaction, a restart that retried an answer, and `older` pages) and that conversation's mobile trace (`view=full` with presentation segments). `server/tests/conversation-stream-golden.ts` writes it, run only by `npm run protocol:fixtures:update`. The Apple `ConversationStreamTests` replays the frames into `ConversationReplica`, projects them with `ConversationTraceProjector`, and requires exactly that trace. The same suite applies `conversation-stream.json` in order and checks each op kind.

## Client

`ChatSessionManager` attaches when the focused socket connects a durable session on a server with the capability, and `ConversationStreamDriver` owns the replica, `attach`/`older`, and the timeline sync. `ServerMessage.conversationStream` decodes the three frames on the focused socket, and `ServerConnection` routes them to the session the socket is bound to, since they carry no `sessionId`. `ClientMessage.conversationAttach` and `.conversationOlder` encode the requests. `OppiTests/Chat/ConversationStreamSessionTests` drives the runtime with scripted frames: resume cursor, fresh attach after a failed apply or attach (one retry per socket), incremental append, the landing keeping live row ids, ignored classic events and the classic-only rows that still show, pending prompts taken in order, and `older`. `ConversationStreamPerfTests` prints per-frame main-thread cost on a 1,600-entry conversation.

## Not yet covered

- The server still sends classic timeline events to an attached socket, and the client ignores them. Stopping them for attached sockets, and deleting the client's event path for durable sessions, is next.
- The busy indicator, stop button, and queue still read session status and `queue_state` rather than `pi.live.run` and `pi.inbox` directly; the server derives both from those documents.
- The Mac app does not attach.
- Child-conversation streams for subagents.
- `toolResult.display` cannot restore an MCP server's configured spelling for `mcp__` tool names, which the trace route does with the session's MCP server names (`resolveToolDisplay`'s `configuredServerNames`). Titles from result details are exact.
- Nested codemode calls (`nestedCalls` on tool results) are not projected; durable sessions do not produce them.
- Paging reads entries before the oldest held id. A second compaction whose kept range starts before the first compaction's marker leaves that marker out of the active view, and `older` never returns it.
