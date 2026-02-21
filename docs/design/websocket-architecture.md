# WebSocket Architecture

Oppi uses persistent WebSocket connections between the iOS client and
self-hosted Node.js servers. Each server services **one user** (one phone).
One phone can connect to **multiple servers** simultaneously.

---

## System Topology

```
                          Tailnet / LAN
 ┌──────────────────────┐              ┌─────────────────────────────┐
 │      iOS Client       │    WSS      │        Oppi Server          │
 │                        │◄──────────►│                             │
 │  ConnectionCoordinator │  /stream   │  HTTP + WS (single user)   │
 │  ├─ ServerConnection A │            │  ├─ UserStreamMux           │
 │  │  └─ WebSocketClient │            │  │  └─ EventRing (user)     │
 │  ├─ ServerConnection B │            │  ├─ SessionManager          │
 │  │  └─ WebSocketClient │            │  │  ├─ ActiveSession 1      │
 │  └─ ...                │            │  │  │  ├─ SdkBackend (pi)   │
 │                        │            │  │  │  ├─ EventRing (sess)  │
 │  Per server:           │            │  │  │  └─ TurnDedupeCache   │
 │   1 WS, N sessions     │            │  │  └─ ActiveSession 2      │
 │   via subscribe/unsub  │            │  ├─ GateServer (permissions)│
 └────────────────────────┘            │  └─ PolicyEngine            │
                                       └─────────────────────────────┘
```

**Key constraint:** 1 server = 1 user. The server has no concept of
multi-tenancy. Auth tokens identify the single paired device.

---

## Connection Lifecycle

```
┌─────────┐                                 ┌─────────┐
│  Client  │                                 │  Server  │
└────┬─────┘                                 └────┬─────┘
     │                                            │
     │  WSS UPGRADE /stream                       │
     │  Authorization: Bearer <token>             │
     │───────────────────────────────────────────►│
     │                                            │
     │  101 Switching Protocols                   │
     │◄───────────────────────────────────────────│
     │                                            │
     │  { type: "stream_connected",               │
     │    userName: "chen" }                       │
     │◄───────────────────────────────────────────│
     │                                            │
     │  ── Per-session subscribe ──               │
     │                                            │
     │  { type: "subscribe",                      │
     │    sessionId: "abc",                       │
     │    level: "full",                          │
     │    requestId: "r1" }                       │
     │───────────────────────────────────────────►│
     │                                            │  startSession()
     │  { type: "connected",                      │  (spawns pi if idle)
     │    session: {...},                          │
     │    currentSeq: 42 }                        │
     │◄───────────────────────────────────────────│
     │                                            │
     │  { type: "state",                          │
     │    session: {...} }                         │
     │◄───────────────────────────────────────────│
     │                                            │
     │  { type: "rpc_result",                     │
     │    command: "subscribe",                   │
     │    requestId: "r1",                        │
     │    success: true,                          │
     │    data: { currentSeq: 42,                 │
     │            catchUpComplete: true } }       │
     │◄───────────────────────────────────────────│
     │                                            │
     │  ── Streaming events flow ──               │
     │                                            │
```

---

## Multiplexed Stream Design

A single WebSocket (`/stream`) carries events for **all sessions** on
that server. Sessions are multiplexed via `subscribe`/`unsubscribe`
commands.

### Subscription Levels

| Level           | Events delivered                                    |
|-----------------|-----------------------------------------------------|
| `full`          | All events (deltas, tools, state, lifecycle)        |
| `notifications` | Permissions, agent start/end, state, errors only    |

**Constraint:** Only **one** session can be `full` at a time (the
active chat). All others are `notifications` level. When a new
session subscribes at `full`, the previous one is auto-downgraded.

### Message Envelope

Every server message on `/stream` includes `sessionId` so the client
can route it:

```json
{
  "type": "text_delta",
  "delta": "Hello",
  "sessionId": "abc-123",
  "seq": 7,
  "streamSeq": 14
}
```

---

## Sequence Numbers

Two independent sequence domains prevent event loss across reconnects:

```
Per-Session seq (SessionManager)          Per-User streamSeq (UserStreamMux)
─────────────────────────────────         ──────────────────────────────────
Scope:    One session                     Scope:    All sessions on server
Covers:   Durable events only             Covers:   Notification-level only
          (agent_start, agent_end,                   (same set as "durable"
           tool_start, tool_end,                      minus streaming deltas)
           message_end, permission_*,
           stop_*, session_ended,
           error)
Storage:  Per-session EventRing           Storage:  User-wide EventRing
          (default 500 entries)                      (default 2000 entries)
Resets:   On server restart               Resets:   On server restart
Client    ChatSessionManager              Client    Not consumed for ordering
usage:    .lastSeenSeq (UserDefaults)     usage:    (attached to messages but
          → catch-up on reconnect                    not used for dedup)
```

### Catch-Up Flow on Reconnect

```
Client                                    Server
  │                                         │
  │  subscribe(sessionId, sinceSeq?)        │
  │────────────────────────────────────────►│
  │                                         │
  │  IF ring.canServe(sinceSeq):            │
  │    replay missed durable events         │
  │    { catchUpComplete: true }            │
  │◄────────────────────────────────────────│
  │                                         │
  │  IF ring too old / sinceSeq too stale:  │
  │    { catchUpComplete: false }           │
  │◄────────────────────────────────────────│
  │                                         │
  │  Client falls back to REST:             │
  │  GET /sessions/:id/events?since=N       │
  │────────────────────────────────────────►│
  │                                         │
  │  OR: full history reload via            │
  │  GET /sessions/:id?traceView=full       │
  │────────────────────────────────────────►│
```

### Server Restart Detection

```
Before restart:  client lastSeenSeq = 42
After restart:   server currentSeq = 0 (reset)

Client sees currentSeq(0) < lastSeenSeq(42)
  → Forces full history reload (trace fetch)
  → Resets lastSeenSeq to 0
```

---

## Event Classification

```
                    ┌──────────────────────┐
                    │   Pi SDK Event        │
                    └──────────┬───────────┘
                               │
                    translatePiEvent()
                               │
               ┌───────────────┴───────────────┐
               │                               │
        Durable Event                   Ephemeral Event
        (sequenced, ring-buffered,      (not sequenced,
         survives reconnect)             lost on disconnect)
               │                               │
  ┌────────────┴──────────┐          ┌─────────┴──────────┐
  │ agent_start           │          │ text_delta          │
  │ agent_end             │          │ thinking_delta      │
  │ tool_start            │          │ tool_output         │
  │ tool_end              │          │ state               │
  │ message_end           │          │ compaction_start    │
  │ permission_request    │          │ compaction_end      │
  │ permission_expired    │          │ retry_start         │
  │ permission_cancelled  │          │ retry_end           │
  │ stop_requested        │          │ rpc_result          │
  │ stop_confirmed        │          │ extension_ui_*      │
  │ stop_failed           │          │ git_status          │
  │ session_ended         │          └────────────────────┘
  │ error                 │
  └───────────────────────┘
```

**Recovery strategy for ephemeral events:** After reconnect, the
client loads the full session trace from REST. The trace contains
complete tool output and assistant text. Ephemeral deltas are only
needed for live streaming — they're inherently transient.

---

## iOS Client Architecture

### Object Ownership

```
ConnectionCoordinator                 (1 per app)
 │
 ├─ ServerConnection [server-A]       (1 per paired server)
 │   ├─ WebSocketClient               (1 persistent WSS to /stream)
 │   ├─ APIClient                     (REST, stateless)
 │   ├─ SessionStore                  (all sessions on this server)
 │   ├─ PermissionStore               (pending permission requests)
 │   ├─ WorkspaceStore                (workspace + skill catalog)
 │   ├─ TimelineReducer               (active session timeline)
 │   ├─ DeltaCoalescer                (batches deltas at 33ms)
 │   └─ ToolEventMapper               (tool lifecycle state machine)
 │
 └─ ServerConnection [server-B]
     └─ (same structure)
```

### Message Pipeline (Hot Path)

```
WS frame received
  │
  ▼
WebSocketClient.startReceiveLoop()
  │  decode JSON → StreamMessage
  │  enqueue InboundMeta (seq, currentSeq) per sessionId
  │  yield to AsyncStream
  │
  ▼
ServerConnection.routeStreamMessage()
  │  IF streamConnected → handleStreamReconnected()
  │  IF sessionId matches active → yield to per-session stream
  │  IF cross-session notification → handleCrossSessionMessage()
  │
  ▼
ChatSessionManager.connect() — for await loop
  │  consume InboundMeta (seq dedup)
  │  IF connected message → catch-up logic
  │  IF seq <= lastSeenSeq → skip (duplicate)
  │
  ▼
ServerConnection.handleServerMessage()
  │  route by message type:
  │  ├─ text_delta, thinking_delta → DeltaCoalescer.receive()
  │  ├─ tool_start/output/end     → ToolEventMapper → Coalescer
  │  ├─ agent_start/end           → SessionStore + Coalescer
  │  ├─ permission_*              → PermissionStore + Coalescer
  │  ├─ state, connected          → SessionStore
  │  ├─ rpc_result                → resolve pending acks/RPCs
  │  └─ error                     → Coalescer
  │
  ▼
DeltaCoalescer (33ms batched flush)
  │
  ▼
TimelineReducer.processBatch()
  │
  ▼
ChatTimelineCollectionView (UIKit diffable datasource)
```

---

## Reconnection

### WebSocket-Level (WebSocketClient)

```
              CONNECTED
                 │
         receive error / ping timeout
                 │
                 ▼
           RECONNECTING(1)
                 │
            wait 1s ± jitter
                 │
                 ▼
         open new WS task
           ┌─────┴─────┐
           │            │
        success       failure
           │            │
           ▼            ▼
       CONNECTED   RECONNECTING(2)
                        │
                   wait 2s ± jitter
                        │
                       ...
                        │
                   RECONNECTING(10)
                        │
                   wait 30s ± jitter
                        │
                     failure
                        │
                        ▼
                   DISCONNECTED
                   (terminal — requires
                    external restart via
                    connectStream())
```

**Backoff:** `2^(attempt-1)` seconds, ±25% jitter, capped at 30s.
Max 10 attempts before giving up.

### Session-Level (ChatSessionManager)

```
              stream ends unexpectedly
                      │
                      ▼
         ┌─ shouldAutoReconnect? ──┐
         │                         │
        yes                       no (cancelled, fatal error,
         │                             stopped session)
         ▼                         ▼
  schedule reconnect          cleanup + disconnect
  (250ms → 750ms →
   2s → 4s backoff)
         │
         ▼
  connectionGeneration++
         │
         ▼
  connect() re-enters
  (cache → stream → catch-up)
```

### Foreground Recovery (ServerConnection+Refresh)

```
  App returns to foreground
           │
           ▼
  reconnectIfNeeded()
    ├─ Restart /stream WS if dead (max retries exhausted)
    ├─ Refresh session list (freshness-gated, 120s min interval)
    ├─ Refresh workspace catalog (same)
    ├─ Sweep expired permissions
    ├─ Refresh active session metadata via REST
    └─ Request state via WS (if stream is connected)
```

---

## Turn Idempotency

Prompts, steers, and follow-ups use `clientTurnId` for exactly-once
delivery across reconnect retries.

```
Client                                     Server
  │                                          │
  │  prompt(clientTurnId: "t1",              │
  │         requestId: "r1",                 │
  │         message: "hello")                │
  │─────────────────────────────────────────►│
  │                                          │  TurnDedupeCache.set("t1")
  │  turn_ack(stage: "accepted",             │
  │           clientTurnId: "t1")            │
  │◄─────────────────────────────────────────│
  │                                          │  sendRpcCommand → pi
  │  turn_ack(stage: "dispatched",           │
  │           clientTurnId: "t1")            │
  │◄─────────────────────────────────────────│
  │                                          │
  │  ── WS drops, client retries ──          │
  │                                          │
  │  prompt(clientTurnId: "t1",              │
  │         requestId: "r2",                 │
  │         message: "hello")                │
  │─────────────────────────────────────────►│
  │                                          │  Cache hit: "t1" already
  │  turn_ack(stage: "dispatched",           │  dispatched → echo back
  │           clientTurnId: "t1",            │  current stage, skip
  │           duplicate: true)               │  re-dispatch to pi
  │◄─────────────────────────────────────────│
```

**Cache:** LRU, 256 entries, 15-minute TTL. SHA-1 payload hash
ensures `clientTurnId` reuse with different content is rejected
as a conflict.

---

## Keepalive

### Client → Server

```
WebSocketClient.startPingTimer():
  every 30s:
    ws.sendPing()
    if 2 consecutive pong failures:
      cancel socket
      trigger reconnect
```

### Server → Client

```
startServerPing(ws, label, intervalMs=30000):
  alive = true
  ws.on('pong', () => alive = true)

  every 30s:
    if !alive → ws.terminate() (fires 'close' event)
    alive = false
    ws.ping()
```

Both `/stream` and legacy WS endpoints use the same keepalive.
A missed pong triggers immediate termination — no second chance.
The `close` event fires existing cleanup (untrack connection,
clear subscriptions) and unblocks push notification fallback.

---

## Silence Watchdog

Detects zombie connections where TCP is alive but no WS frames
arrive (e.g., middlebox silently dropping packets).

```
          agent_start
              │
              ▼
     start watchdog timer
              │
         ┌────┴────┐
         │         15s passes without
    event arrives   any event arriving
    (reset timer)       │
         │              ▼
         │     Tier 1: Probe
         │       requestState()
         │              │
         │         ┌────┴────┐
         │         │        30s more passes
         │    event arrives  (45s total)
         │    (reset timer)     │
         │         │            ▼
         │         │     Tier 2: Force Reconnect
         │         │       onSilenceReconnect()
         │         │       → ChatSessionManager.reconnect()
         │         │
         ▼         ▼
     agent_end → stop watchdog
```

---

## Known Limitations

1. ~~**No server-side WS ping.**~~ **Fixed.** Both `/stream` and
   legacy endpoints now run a 30-second ping/pong keepalive. Missing
   pong terminates the connection immediately, which fires the
   existing `close` cleanup and unblocks push notification fallback.

2. ~~**Fire-and-forget resubscription.**~~ **Fixed.**
   `handleStreamReconnected()` now retries the active session
   subscribe (3 attempts, 500ms backoff). On failure, a system event
   is surfaced so the user knows to reconnect. Notification-level
   sessions are best-effort (single attempt).

3. ~~**No send-side backpressure.**~~ **Fixed.** Server checks
   `ws.bufferedAmount` before sending high-frequency ephemeral
   frames (`text_delta`, `thinking_delta`, `tool_output`). Frames
   are dropped when the buffer exceeds 64 KB. Durable events are
   always delivered.

4. **Ephemeral events lost on disconnect.** Text deltas and tool
   output are not ring-buffered. Recovery requires full trace reload
   from REST — correct but slow for long sessions.

5. **Legacy per-session WS endpoint still active.** `/workspaces/
   :wid/sessions/:sid/stream` duplicates much of `/stream` logic.
   Maintenance burden.

6. ~~**EventRing object mutation leak.**~~ **Fixed.** The
   `session_event` listener no longer mutates `payload.event`. The
   user-level stream ring creates its own copy via
   `recordUserStreamEvent()`.

7. **Storage-layer write amplification can mimic WS instability.**
   Session metadata files currently persist full `messages[]` and are
   read/rewritten synchronously. This is not a `/stream` protocol flaw,
   but under long assistant-heavy sessions it can add event-loop latency
   that degrades perceived WebSocket responsiveness.
   See: `docs/design/session-storage-analysis.md`.

---

## File Map

| Component                  | Path                                                |
|----------------------------|-----------------------------------------------------|
| Stream multiplexer         | `server/src/stream.ts`                              |
| Session manager            | `server/src/sessions.ts`                            |
| Event ring buffer          | `server/src/event-ring.ts`                          |
| Turn dedupe cache          | `server/src/turn-cache.ts`                          |
| Server (WS upgrade + auth) | `server/src/server.ts`                              |
| Protocol types             | `server/src/types.ts`                               |
| iOS WebSocket client       | `ios/Oppi/Core/Networking/WebSocketClient.swift`    |
| iOS server connection      | `ios/Oppi/Core/Networking/ServerConnection.swift`   |
| iOS message router         | `ios/Oppi/Core/Networking/ServerConnection+MessageRouter.swift` |
| iOS reconnect/refresh      | `ios/Oppi/Core/Networking/ServerConnection+Refresh.swift` |
| iOS session lifecycle      | `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift` |
| iOS multi-server pool      | `ios/Oppi/Core/Services/ConnectionCoordinator.swift`|
| iOS turn tracking          | `ios/Oppi/Core/Networking/TurnSendTracking.swift`   |
| iOS connection types       | `ios/Oppi/Core/Networking/ServerConnectionTypes.swift` |
| Storage footprint analysis | `docs/design/session-storage-analysis.md`              |
