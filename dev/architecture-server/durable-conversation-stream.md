# Durable conversation stream (experimental)

Part of [Oppi server architecture](../architecture-server.md). The wire that replicates one durable conversation's `{ entries, docs }` to a client. It is the server half of the durable-only target model; no Apple client reads it yet, and the shapes may change before one does.

## Gate and transport

- `GET /server/info` advertises `capabilities.conversationStream: { version: 1 }` whenever the server has a durable Harness: `experimental.serverDurable` is on, or sessions are still bound to durable conversations after it was turned off.
- The stream rides the existing focused session socket (`/workspaces/:workspaceId/sessions/:sessionId/stream`, and `/control-sessions/:sessionId/stream`) and its auth. A new endpoint would have duplicated the session open, startup-dialog relay, auth expiry, and command routing that socket already owns, and commands still travel on it.
- Nothing changes until the client sends `attach`. A socket that never attaches gets exactly the classic event frames it got before. An attached socket gets both: the event path is untouched until the cutover.
- `attach` is socket-only. It is not a `ClientMessage` command, so `POST /sessions/:id/command` answers it as an unknown type.

## Messages

Types live in `server/src/types/protocol.ts` (`ConversationStreamAttach`, `ConversationStreamServerMessage`, `ConversationEntryView`, `ConversationDocOp`). Canonical examples are in `protocol/conversation-stream.json`, kept apart from `server-messages.json`, whose examples must all decode as known events in the Apple client.

```ts
// client → server
{ type: "attach"; conversationId?: number; sessionId?: string; afterEntryId?: number; requestId?: string }

// server → client
{ type: "snapshot"; conversationId: number; head: number; hasOlder: boolean;
  entries: ConversationEntryView[]; docs: Record<string, JsonObject> }
{ type: "update"; conversationId: number;
  entries?: ConversationEntryView[]; docs?: Record<string, ConversationDocOp[] | null> }
```

- `attach` targets the socket's bound session. `sessionId` and `conversationId`, when present, must name that session and its conversation. A session that is not bound to a durable conversation (classic, mirror, or a durable request that never bound) fails. With a `requestId` the answer is `command_result { command: "attach" }`, sent after the first stream frame; without one a failure is an `error` frame. A second `attach` on the same socket replaces the first.
- Frames carry no `seq`. The socket is ordered and lossless; across reconnects the cursor is the newest entry id the client holds.
- `ConversationEntryView` is the Durable `EntryRecord` without `conversationId`, `byTaskId`, `head`, and `edits`. Tool-result `details` are sanitized like trace history (no server paths). Assistant entries add `toolCalls[callId]` and tool-result entries add `toolResult`, rendered by the same `MobileRendererRegistry` as classic `tool_start`/`tool_end`. Entries never change after commit.
- `snapshot.entries` are the active context in display order. After a reset or compaction the head entry comes first, then the kept entries from its head (which have smaller ids). `head` is that entry's id, or 0. `hasOlder` says entries exist before the first one sent; paging them is not part of v1.

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

`server/src/durable-conversation-stream.ts` keeps one `ConversationRoom` per attached conversation, shared by its sockets and closed with the last one.

- The room loads `conversation.viewState()` plus `harness.snapshot` for listed documents outside the Pi view, after subscribing to `harness.subscribeCommits`. Commits that land during the load are replayed over it; replay is idempotent.
- Each commit publication updates the room synchronously, so the room never holds part of a commit. Each socket remembers what it sent and flushes at most every 100 ms (Durable's progress interval), leading edge after a quiet period. One `update` is therefore a whole number of commits: the new assistant entry and the cleared `pi.live.generation` always share a frame.
- A head entry (reset or compaction) makes the next flush a `snapshot`.
- **Resume:** `attach { afterEntryId }` answers with an `update` when the id is an active entry at or after the head: the entries after it, and every listed document whole (`r`, or `null` when absent) because the client's copies are unknown. Any other cursor (missing, unknown, or older than the head) gets a `snapshot`. The entries come from the room's active set, which is loaded from storage and advanced from durable commit publications, so the gap never expires and needs no second storage read racing the live tail.

## Proof

- `server/tests/durable-conversation-stream.test.ts` runs a real Harness with a faux provider: append ops, the single landing frame, coalescing, tool presentation on entries and `pi.live`, resume after a mid-turn disconnect, head moves, stale and unknown cursors, and document visibility. Every replica is checked against a fresh snapshot.
- `server/tests/durable-conversation-stream.integration.test.ts` drives a real `Server` over WSS: the capability, snapshot on attach, appends, the landing frame, resume after a disconnect while a turn ran, a `compact` command forcing a snapshot, a socket without `attach` getting no stream frames, and a classic session refusing `attach`. It writes payload sizes for one streamed reply to `$TMPDIR/oppi-conversation-stream-payload.json`.

## Not yet covered

The iOS replica and timeline projector are the next step. Before the event path can be deleted for durable sessions, the stream still needs: input cards for extension-generated inputs (today a server join of submissions and `oppi.input-cards`), hiding recovered partial assistant entries (the trace's `isRecoveredPartial`), older-history paging over entries, and child-conversation streams for subagents.
