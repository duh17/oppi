# Chat Timeline Code Paths (Streaming + Normal Output)

Status: active

This doc maps the concrete code paths that build the chat timeline in Oppi, for:

1. **Live streaming output** (`text_delta`, `thinking_delta`, tool events)
2. **Normal/finalized output** (`message_end`, history/trace reload)
3. **Reconnect catch-up** (`/events?since=` + fallback reload)

It is written as a debugging/optimization map for freshness and lag issues.

For the product-level behavior contract (what should happen, in what order), see:
- `docs/design/chat-freshness-contract.md`

---

## 1) Core pipeline (one-line view)

```text
WebSocket /stream
  -> WebSocketClient.decode(StreamMessage)
  -> ServerConnection.handleServerMessage(...)
  -> ToolCallCorrelator + DeltaCoalescer
  -> TimelineReducer.processBatch/process
  -> reducer.items + reducer.renderVersion
  -> ChatTimelineView
  -> ChatTimelineCollectionHost (UIKit diffable + layout)
  -> pixels
```

Key files:
- `ios/Oppi/Core/Networking/WebSocketClient.swift`
- `ios/Oppi/Core/Networking/ServerConnection+MessageRouter.swift`
- `ios/Oppi/Core/Runtime/DeltaCoalescer.swift`
- `ios/Oppi/Core/Runtime/TimelineReducer.swift`
- `ios/Oppi/Features/Chat/Timeline/ChatTimelineView.swift`
- `ios/Oppi/Features/Chat/Timeline/TimelineSnapshotApplier.swift`
- `ios/Oppi/Features/Chat/Timeline/ChatTimelineCollectionView.swift`

---

## 2) Session entry path (what happens when user opens chat)

Entry owner:
- `ChatSessionManager.connect(...)`
  - `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift`

Current flow:
1. Disconnect old session stream + cancel pending sync tasks.
2. Set active session.
3. Start freshness measurement (`fresh_content_lag_ms` start).
4. Load cache immediately:
   - `TimelineCache.shared.loadTrace(sessionId)`
   - if present: `reducer.loadSession(cached.events)`
5. Open `/stream` subscription (`connection.streamSession(...)`).
6. Schedule background history reload (`scheduleHistoryReload(...)`).
7. Process live stream loop.

Important consequence:
- Cache-first render is fast, but users can see stale content until stream/catch-up/reload catches up.

---

## 3) Live streaming path (token/tool streaming)

### 3.1 Decode + inbound sequencing

`WebSocketClient.startReceiveLoop(...)`:
- receives websocket frames
- decodes `StreamMessage.decode(from:)`
- records `chat.ws_decode_ms`
- stores `InboundMeta(seq,currentSeq)` per session queue
- records `chat.inbound_queue_depth` high-water marks

File:
- `ios/Oppi/Core/Networking/WebSocketClient.swift`

### 3.2 Message routing

`ServerConnection.handleServerMessage(...)` routes active-session messages.

Streaming-related mappings:
- `.textDelta` -> `coalescer.receive(.textDelta(...))`
- `.thinkingDelta` -> `coalescer.receive(.thinkingDelta(...))`
- `.toolStart/.toolOutput/.toolEnd` -> through `ToolCallCorrelator`, then coalescer
- `.agentStart/.agentEnd/.messageEnd` -> coalescer

File:
- `ios/Oppi/Core/Networking/ServerConnection+MessageRouter.swift`

### 3.3 Coalescing

`DeltaCoalescer` behavior:
- batches high-frequency events: `textDelta`, `thinkingDelta`, `toolOutput`
- flush interval: ~33ms
- non-high-frequency events flush immediately
- records:
  - `chat.coalescer_flush_events`
  - `chat.coalescer_flush_bytes`

File:
- `ios/Oppi/Core/Runtime/DeltaCoalescer.swift`

### 3.4 Reducer state machine

`TimelineReducer.processBatch(...)`:
- accumulates assistant/thinking buffers
- upserts only affected rows per batch
- handles tool row lifecycle (`toolStart/output/end`)
- bumps `renderVersion` once per mutating batch

File:
- `ios/Oppi/Core/Runtime/TimelineReducer.swift`

### 3.5 UI apply + layout

`ChatTimelineView` listens to `reducer.renderVersion`:
- computes visible slice
- issues scroll commands (auto-follow bottom behavior)
- passes config to `ChatTimelineCollectionHost`

`TimelineSnapshotApplier.applySnapshot(...)`:
- builds diff snapshot
- reconfigures changed IDs
- applies via diffable data source

`ChatTimelineCollectionHost.Controller.apply(...)`:
- applies snapshot
- runs `collectionView.layoutIfNeeded()`
- updates scroll state/hints

Perf instrumentation:
- `chat.timeline_apply_ms`
- `chat.timeline_layout_ms`

Files:
- `ios/Oppi/Features/Chat/Timeline/ChatTimelineView.swift`
- `ios/Oppi/Features/Chat/Timeline/TimelineSnapshotApplier.swift`
- `ios/Oppi/Features/Chat/Timeline/ChatTimelineCollectionView.swift`
- `ios/Oppi/Features/Chat/Timeline/ChatTimelinePerf.swift`

---

## 4) Normal output paths (non-streaming/finalized)

There are two practical "normal" paths:

## 4.1 `message_end` finalization path

If server emits finalized assistant content:
- `ServerConnection` routes `.messageEnd`
- reducer `handleMessageEnd(content)` finalizes assistant/thinking rows
- no token-by-token dependence needed to finalize

Path:
- `ServerConnection+MessageRouter.handleServerMessage` -> `.messageEnd`
- `TimelineReducer.processInternal(.messageEnd)`

## 4.2 History/trace load path

Used for:
- initial load
- reconnect fallback
- explicit refresh path

`ChatSessionManager.loadHistory(...)`:
- calls `api.getSession(..., traceView: .full)`
- compares trace signature `(eventCount,lastEventId)` vs cached signature
- if changed and not deferred, calls `reducer.loadSession(trace)`
- always updates `TimelineCache.saveTrace(...)`
- records `chat.full_reload_ms`
- records freshness lag completion reason + duration

`TimelineReducer.loadSession(...)`:
- chooses mode:
  - no-op
  - incremental append
  - full rebuild
- applies trace events via `applyTraceEvent(...)` into timeline rows

Files:
- `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift`
- `ios/Oppi/Core/Services/TimelineCache.swift`
- `ios/Oppi/Core/Runtime/TimelineReducer.swift`

---

## 5) Reconnect + catch-up path

Owner:
- `ChatSessionManager.performCatchUpIfNeeded(...)`

Flow:
1. On connected message with `currentSeq`, compare to `lastSeenSeq`.
2. If gap exists, fetch:
   - `GET /workspaces/:workspaceId/sessions/:id/events?since=<lastSeenSeq>`
3. If `catchUpComplete == true`:
   - apply returned events via `connection.handleServerMessage(...)`
   - update `lastSeenSeq`
4. If `catchUpComplete == false` (ring miss), seq regression, or fetch failure:
   - schedule full history reload

Metrics:
- `chat.catchup_ms` (+ result tags)
- `chat.catchup_ring_miss`

Server-side ring behavior:
- bounded ring in `server/src/event-ring.ts`
- catch-up completeness from `SessionBroadcaster.getCatchUp(...)`

Files:
- `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift`
- `server/src/event-ring.ts`
- `server/src/session-broadcast.ts`
- `server/src/routes/sessions.ts`

---

## 6) Freshness telemetry (new)

Metric:
- `chat.fresh_content_lag_ms`

Meaning:
- time from entering session (`connect()`) to first confirmed fresh content signal.

Current completion reasons:
- `stream_seq`
- `catchup_applied`
- `catchup_no_gap`
- `history_applied`
- `history_unchanged`
- `history_deferred`
- `history_empty`

Tags:
- `cache`: `1|0` (whether cache was rendered at connect)

Files:
- `ios/Oppi/Core/Services/MetricKitModels.swift`
- `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift`
- `server/src/types.ts`
- `server/src/routes/telemetry.ts`

---

## 7) Where stale-first lag comes from (today)

Observed user symptom:
- enter chat, see older cached tail, then latest content appears late.

Code-level contributors:
1. **Cache-first render is immediate** (intentional).
2. **Initial history reload is scheduled in background** even when cache exists.
3. History apply (`reducer.loadSession`) + collection layout run on main/UI path.
4. During bursts, inbound meta queue can rise (`chat.inbound_queue_depth`), indicating consumer lag.

So background fetch does not mean free: apply/layout still contends with live rendering.

---

## 8) Freshness-first policy proposal (simple)

For session entry:
- If cache exists and catch-up succeeds, **skip initial full reload**.
- Only full reload when:
  - ring miss,
  - seq regression,
  - catch-up fetch failure,
  - no cache,
  - explicit user refresh.

This prioritizes "show newest now" over "reconcile everything immediately".

---

## 9) Quick debugging checklist

When user reports stale tail / delayed newest messages, check in this order:

1. `chat.fresh_content_lag_ms` p95 / max and reasons
2. `chat.catchup_ms` + result tags
3. `chat.full_reload_ms` spikes and trace event counts
4. `chat.inbound_queue_depth` high-water
5. `chat.timeline_apply_ms` / `chat.timeline_layout_ms` spikes
6. `chat.coalescer_flush_bytes` burst correlation

If ring concerns exist, also check `chat.catchup_ring_miss` rate.
