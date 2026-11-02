# Durable conversation stream (experimental)

Part of [Oppi server architecture](../architecture-server.md); same standard (owners, boundaries, invariants, entry points). The wire that replicates one durable conversation's `{ entries, docs }` to a client; the client half is in [client flows](../architecture-client/flows.md#durable-sessions-the-conversation-stream).

## Gate and transport

- `GET /server/info` advertises `capabilities.conversationStream: { version: 2 }` whenever the server has a durable runtime. Version 2 added [live tails](#live-tails) and `detach`; a client sends neither to a version 1 server, whose `attach` replaced the socket's only stream.
- The stream rides the focused session socket (`/workspaces/:workspaceId/sessions/:sessionId/stream`, `/control-sessions/:sessionId/stream`) and its auth, because that socket already owns session open, startup dialogs, auth expiry, and command routing. `attach` is socket-only, not a `ClientMessage` command.
- Nothing changes until the client sends `attach`. A socket that holds its own conversation in full stops getting the classic events the stream restates (`restatedByConversationStream` in `stream.ts`: text/thinking deltas, `message_end`, tool events, `custom_card`, compaction and retry, broadcast `queue_state`/`queue_item_started`, `entry:<id>` notices); the bootstrap replay and a `queue_state` answering its own `get_queue` still go out. Everything else (`state`, run boundaries, stop feedback, `error`, other notices, `cache_miss`, `session_ended`, `extension_ui_*`, `command_result`, audio, `git_status`) still goes to an attached socket, because no entry or document carries it yet.

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
- `ConversationEntryView` sends only the fields clients read (`CLIENT_MESSAGE_FIELDS`, `CLIENT_BLOCK_FIELDS` in `durable-conversation-view.ts`); signatures, provider replay state, diagnostics, and usage stay on the server. Tool-call arguments are resolved once by `resolveToolArguments` (`tool-call-arguments.ts`), which the stream, the trace, and Session Outline all read. User images leave as session attachment references (`storeUserMessageImages`, content-addressed). Raw entry `data` never leaves the server (it can hold paths); display entries leave only as a sanitized `card`, and tool details are sanitized like trace history. Codemode script calls become `toolResult.nestedCalls` (`durableNestedCalls`, recognized by shape, not tool name).
- `snapshot.entries` are the newest `CONVERSATION_SNAPSHOT_LIMIT` (100) active entries, cut only after the head entry; `hasOlder` says more exist. Without the cut, a long uncompacted conversation sent megabytes per attach.
- `older` pages before `beforeEntryId` (default 100, at most 500) and needs a full `attach` on the same socket. Recovered partials are hidden by the same `isRecoveredPartial`/`readRetryEvidence` rule as trace pages (`durable-history.ts`).

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

Presentation passes run asynchronously and serialized when entries, `oppi.input-cards`, or an attempt's task change; subscribers hold frames until a pass ends, so a new entry never goes out before its presentation is decided. The `pi.inbox` view is decided the same way, so a queued input never leaves with raw content. A pass that fails, or a commit the room cannot apply, closes the room without flushing; `SessionHost` re-attaches the socket from its cursor. A changed presentation is restated in the next `update`, but never below the subscription's window floor, since an entry placed before the client's window would make `older` skip entries.

## Documents

`CONVERSATION_CLIENT_DOCS` lists `{ doc, client: true, view? }` specs; the room never branches on a kind. Client-visible: `pi.live` (messages projected like entries, `toolCalls`, `nestedCalls`; unchanged parts project to identical objects so `diffRevisions` sends small ops), `pi.inbox` (the `get_queue` view), `pi.agent`, `pi.usage`, `oppi.extension-ui` (through the extension UI allowlist). `pi.provider` and everything else stay on the server.

Documents travel as Chord ops (`@earendil-works/chord/delta`) from `diffRevisions(lastSent, current)`: `["r", value]` replace, `["s", path, value]` set, `["d", path]` delete, `["a", path, text]` append, `["t", path, n]` drop leading characters, `["p", path, index, deleteCount, items]` splice, `["m", path, permutation]` reorder (`new[i] = old[permutation[i]]`). Paths are inline arrays; `null` means the document is gone. Grown text is always `a`; `r` only when a delta would cost more.

## Delivery

`durable-conversation-stream.ts` keeps one `ConversationRoom` per attached conversation, reached through `SessionHost.transcript(...)` (holds the store open) and `SessionHost.olderEntries(...)` (reads storage, no room).

- The room subscribes to commits before loading, then replays commits that landed during the load (idempotent). Each commit updates the room synchronously, and each socket flushes at most every 100 ms, so one `update` is a whole number of commits: a new assistant entry and the cleared `pi.live.generation` always share a frame.
- A head entry (reset or compaction) makes the next flush a `snapshot`.
- **Resume:** `attach { afterEntryId }` at or after the head answers an `update` with restated presentation, the later entries, and every document whole; any other cursor gets a `snapshot`. Entries come from the room's active set, so the gap never expires.

## Proof

`server/tests/durable-conversation-view.test.ts` (projection), `durable-conversation-stream.test.ts` (real Harness: ops, landing frame, presentation, resume, `older`, live tails), `durable-conversation-stream.integration.test.ts` (real server over WSS). `protocol/conversation-stream-golden.json` is written only by `npm run protocol:fixtures:update` (`server/tests/conversation-stream-golden.ts`); Apple `ConversationStreamTests` replays it into `ConversationReplica` and requires the identical trace, and fails if the fixture stops covering every trace event type and doc op.

## Not yet covered

- The classic events above still reach an attached socket; session status, Live Activity, and screen-awake still follow them.
- The Mac app does not attach.
- `toolResult.display` cannot restore an MCP server's configured spelling for `mcp__` names (the trace route can).
- Codemode call arguments over 200 characters arrive as `argumentsBytes` of pi-durable's cut text.
- A second compaction whose kept range starts before the first compaction's marker hides that marker from `older`.
