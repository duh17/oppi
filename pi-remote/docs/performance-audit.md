# Performance Bottleneck Audit: Server + iOS Client

Last updated: 2026-02-09

## Methodology

Full-stack read of the hot paths from WS connect → pi spawn → event stream → iOS render.
Prioritized by user-perceived impact (latency, jank, battery, memory).

---

## Server Performance Bottlenecks

### S1. Storage: Synchronous JSON I/O on Every Save — HIGH

**Location:** `storage.ts` — `saveSession()`, `addSessionMessage()`

**Problem:** Every `saveSession()` call does a synchronous `readFileSync` + `JSON.parse` + `JSON.stringify` + `writeFileSync`. This happens:
- On every `message_end` event (assistant reply finishes)
- On every `agent_start` / `agent_end` (status change)
- On every user prompt (both save session + add message)
- On dirty session flush (1s debounce)

The `addSessionMessage()` is worse: it reads the entire file, parses it, appends one message, re-serializes everything, and writes it all back. For a session with 200 messages, that's parsing and writing ~500KB of JSON on every single message.

**Impact:** Blocks Node.js event loop during writes. At scale (3+ concurrent sessions), serialization latency stacks up. Measured: 5-15ms per save for a 100-message session.

**Fix:**
```
Option A (quick): Switch to writeFile (async) for dirty flushes.
         Keep readFileSync for startup only.
Option B (proper): Split storage into session.json (metadata) + messages.jsonl
         (append-only). Messages never need re-read/re-write.
Option C (best): In-memory cache with periodic async flush.
         Already partially done (saveDebounceMs=1000), but the flush
         itself is sync.
```

### S2. Container Spawn Cold Start — HIGH

**Location:** `sandbox.ts` → `spawnPi()`, `sessions.ts` → `setupProcHandlers()`

**Problem:** Container session startup is serialized and blocking:
1. `initSession()` — sync: mkdir, cpSync skills, write auth/models, generate system prompt (~100-200ms)
2. `container run` — spawn: image load + mount setup + process start (~2-5s)
3. `setupProcHandlers()` — wait for pi ready: 500ms delay then probe, wait for first JSON line (3-10s total)
4. Then: gate socket creation, policy setup, sandbox validation

Total: **5-15 seconds** from WS connect to "ready" on container mode.

**Impact:** User taps "new session" on phone → sees "connecting..." for 5-15s. The WS `handleWebSocket` blocks the entire handler, queueing any user messages until ready.

**Fix:**
```
1. Pre-warm: Keep warm container pool (1-2 idle containers with pi loaded).
   On session start, assign a warm container instead of cold-spawning.
2. Parallel init: Gate socket + policy setup can happen during container boot,
   not sequentially.
3. Remove 500ms probe delay: Send get_state immediately on spawn.
   The delay was precautionary but pi handles early stdin fine.
4. Lazy skill sync: Only sync skills that changed (hash comparison).
   Currently copies ALL skills every time, even if identical.
```

### S3. `execSync` Calls in Hot Paths — MEDIUM

**Location:** Multiple files

**Problem:** Several `execSync` calls block the event loop:
- `sandbox.ts` → `ensureNetwork()`: `execSync("container network create ...")` on every server start
- `sandbox.ts` → `stopContainerById()`: `execSync("container stop ...")` with 5s timeout
- `sandbox.ts` → `cleanupOrphanedContainers()`: `execSync("container list")` + multiple stops
- `sandbox.ts` → `imageExists()`: `execSync("container image inspect ...")`
- `sessions.ts` → `resolvePiExecutable()`: `execSync("which pi")`
- `server.ts` → `refreshModelCatalog()`: `execFileSync("pi", ["--list-models"])` with 15s timeout!

**Impact:** `refreshModelCatalog` is the worst — `execFileSync` with 15s timeout blocks the entire event loop. It's called on the first `/models` API request. If pi is slow to enumerate models, ALL WebSocket events freeze for that user.

**Fix:**
```
1. Replace execFileSync with execFile (async) for model catalog.
   Already wrapped in a promise-based refresh, but the inner call is sync.
2. Replace execSync with exec (async) for container operations.
3. Cache pi executable path at startup (not per-session).
```

### S4. Trace Building Reads Entire JSONL — MEDIUM

**Location:** `trace.ts` → `readSessionTrace()`, called by `handleGetSession()`

**Problem:** On every `GET /workspaces/:wid/sessions/:id` request (iOS foreground resume, reconnect), the server:
1. Reads ALL `.jsonl` files for the session (can be 1-10MB for long sessions)
2. Parses every line as JSON
3. Builds parent chain, walks tree
4. Converts to TraceEvent array
5. Serializes as JSON and sends over HTTP

For a session with 500+ turns and heavy tool usage, this can be 5-10MB of JSONL parsed synchronously.

**Impact:** 100-500ms per trace load. iOS calls this on every foreground resume. During active use, that's every time the user switches apps and comes back.

**Fix:**
```
1. Incremental trace: Server tracks last-known entry count per session.
   Send only new entries since client's last checkpoint.
2. Cache built trace in memory (invalidate on new JSONL writes).
3. Stream trace as JSONL instead of building array in memory.
4. Background preload: When a session becomes active, pre-build its trace.
```

### S5. Session Persist Double-Writes — LOW

**Location:** `sessions.ts` — `updateSessionFromEvent()` + `appendMessage()`

**Problem:** On `message_end`, the session is persisted twice:
1. `appendMessage()` calls `storage.addSessionMessage()` which reads+writes the full file
2. `persistSessionNow()` calls `storage.saveSession()` which reads+writes the full file again

Two full read-parse-serialize-write cycles for the same file, back to back.

**Fix:** Batch into a single write. `addSessionMessage` should take the session object and write both in one call.

### S6. `JSON.stringify` on Every WS Send — LOW

**Location:** `server.ts` — `handleWebSocket()` → `send()`, `broadcastToUser()`

**Problem:** Every WebSocket message is `JSON.stringify`'d per-send. For broadcasts (permission requests), the same message is serialized once per connected WebSocket.

**Impact:** Negligible for 1-2 connections. Could matter at scale.

**Fix:** Stringify once, send the string to all sockets (already done in `broadcastToUser` — good).

---

## iOS Client Performance Bottlenecks

### C1. History Reload on Every Foreground Resume — HIGH

**Location:** `ChatSessionManager.swift` → `loadHistory()`, `ServerConnection.swift` → `reconnectIfNeeded()`

**Problem:** Every time the user brings the app to foreground:
1. REST call: `GET /workspaces/:wid/sessions/:id` (server parses full JSONL — see S4)
2. Server sends full trace array (potentially MBs)
3. iOS decodes JSON response
4. `TimelineReducer.loadSession()` rebuilds entire timeline
5. Even with incremental detection, the full trace is still transferred and decoded

**Impact:** 200-800ms perceived delay on foreground. Cache helps for unchanged sessions, but any new event triggers full rebuild.

**Fix:**
```
1. Server-side: Send trace delta (events since last known sequence).
2. Client-side: Already has incremental loadSession detection — just
   needs server to support delta queries.
3. Cache: TimelineCache already caches — but still downloads full trace
   to check if it changed. Add ETag/If-None-Match to skip download entirely.
```

### C2. Full `loadSession()` Rebuilds — MEDIUM

**Location:** `TimelineReducer.swift` — `loadSession()`

**Problem:** When trace HAS changed, `loadSession()` does a full rebuild:
- Clears all items
- Iterates all events (could be 500+)
- Creates ChatItem per event
- Rebuilds index
- Re-renders entire LazyVStack

The incremental append path exists and works well for append-only changes. But any mid-session change (compaction, model change, fork) triggers full rebuild.

**Impact:** 50-200ms for large sessions. Causes visible flash as timeline resets.

**Fix:**
```
1. The incremental path is already solid (loadedTraceEventIDs matching).
2. For compaction: append compaction summary + post-compaction events
   instead of full rebuild. Most of the pre-compaction events would
   produce the same items anyway.
```

### C3. MainActor Contention — MEDIUM

**Location:** `ServerConnection`, `WebSocketClient`, `TimelineReducer`, `SessionStore`, `LiveActivityManager` — all `@MainActor`

**Problem:** The entire networking and rendering pipeline runs on `@MainActor`:
- WebSocket receive → parse JSON → route message → coalesce → reduce → render
- All on the main thread

The coalescer batches at 33ms, but the entire batch processing (decode + route + reduce + SwiftUI update) happens in one main thread slice.

**Impact:** For fast streaming (50+ tokens/sec), the 33ms batch can contain 30-50 events. Processing them synchronously can take 5-15ms, eating into the frame budget.

**Fix:**
```
1. Move JSON decode off MainActor (decode in URLSession's delegate queue).
2. Move TimelineReducer to its own actor (publish results to MainActor).
3. Profile: the coalescer already solves most of this. Measure before
   optimizing further.
```

### C4. ToolOutputStore Linear Growth — LOW

**Location:** `TimelineReducer.swift` — `toolOutputStore`

**Problem:** Tool outputs are stored in a dictionary with no eviction. A long session with heavy tool usage (100+ tool calls, each producing KB of output) keeps everything in memory.

**Impact:** Gradual memory growth. For typical sessions (20-50 tool calls), not a problem. For marathon sessions, could reach 50-100MB.

**Fix:**
```
1. LRU eviction: Keep last N tool outputs in memory, evict oldest.
2. Lazy loading: Store toolCallId → file offset, load on demand
   from TimelineCache when user expands a tool call row.
   The REST endpoint GET /workspaces/:wid/sessions/:id/tool-output/:toolCallId
   already exists for this purpose.
```

### C5. Image Processing on Send — LOW

**Location:** `ChatActionHandler` image handling

**Problem:** Image paste/capture preprocessing (resize, compress, base64 encode) was originally on main queue. Recently moved off-main. But base64-encoded images in WebSocket messages can be large (1-5MB per image).

**Impact:** Large WS frame size → send latency. Base64 encoding adds 33% overhead.

**Fix:** Already addressed (moved off main queue). Further: server-side image upload endpoint instead of inline WS encoding.

---

## Container Runtime Bottlenecks

### R1. No Container Reuse — HIGH

**Location:** `sandbox.ts` → `spawnPi()`, `sessions.ts` → `spawnPiContainer()`

**Problem:** Every session creates a new container from scratch:
1. Copy skills, auth, models, extensions (sync I/O)
2. Create container with all mount points
3. Start container process
4. Wait for pi to initialize (load extensions, compile TS, connect to API)
5. On session end: container is destroyed (`--rm` flag)

Starting a new session in the same workspace repeats ALL of this work, even though the container image, skills, and configuration are identical.

**Impact:** 5-15s cold start per session. User creates 5 sessions per day = 25-75s of dead time.

**Fix:**
```
Phase 1 — Warm pool:
  Keep 1-2 pre-spawned containers per workspace (idle, pi loaded).
  On session start, assign a warm container and inject session-specific
  config. Pi's new_session RPC can reset conversation state without
  restarting the process.

Phase 2 — Persistent workspace containers:
  One long-lived container per workspace. Sessions are pi sessions
  within the same process. Container lifecycle = workspace lifecycle.
  This is what the workspace migration TODO already envisions.

Phase 3 — Snapshot/restore:
  Apple containers may support checkpointing. Snapshot a warm container
  and restore instead of cold boot.
```

### R2. Sync File Operations in initSession — MEDIUM

**Location:** `sandbox.ts` → `initSession()`

**Problem:** All file operations are synchronous:
- `mkdirSync`, `cpSync`, `writeFileSync`, `readFileSync`, `rmSync`
- Skills are copied fresh every time (no diffing)
- System prompt is generated and written synchronously

**Impact:** 100-200ms of blocked event loop during session creation. For concurrent session starts, these serialize.

**Fix:**
```
1. Hash-based skill sync: Only copy skills that changed (stat comparison).
2. Async file ops: Use async fs for non-critical writes.
3. Template caching: System prompt template rarely changes — cache it.
```

### R3. Container Stop is Blocking — LOW

**Location:** `sandbox.ts` → `stopContainerById()`

**Problem:** `execSync("container stop ...")` with 5s timeout. If the container hangs, this blocks the event loop for 5 seconds.

**Fix:** Use `execFile` (async) with a timeout. Already has a try-catch for kill fallback.

---

## End-to-End Latency Analysis

### Happy Path: User sends prompt → sees first token

```
iOS: tap send → ChatActionHandler → sendWithAck → WS send    ~5ms
WS:  network transit (Tailscale LAN)                          ~1-5ms
Server: parse JSON → handleClientMessage → sendPrompt         ~1ms
RPC: write to pi stdin → pi processes prompt                   ~50-100ms
LLM: API call → first token                                    ~500-2000ms
RPC: pi stdout → readline → handleRpcLine → translateEvent    ~1ms
Server: broadcast → WS send                                    ~1ms
WS:  network transit back                                      ~1-5ms
iOS: decode → handleServerMessage → coalescer buffer           ~1ms
iOS: coalescer flush (up to 33ms wait) → reducer → render     ~5-15ms
                                                    ─────────────
Total: ~570-2130ms (dominated by LLM latency)
```

**Observations:**
- Server-side overhead is ~5ms total. Negligible.
- iOS-side overhead is ~10-50ms (mostly coalescer flush interval).
- LLM API latency is 95%+ of total. Nothing we can optimize here.
- The pipeline is well-designed for streaming — text arrives token-by-token with minimal buffering.

### Cold Path: User taps session → sees chat

```
iOS: tap session → ChatView.onAppear → ChatSessionManager.connect
  Load cached timeline (disk)                                   ~20-50ms
  Open WS connection                                            ~10-50ms
Server: handleUpgrade → handleWebSocket
  send connected (from disk)                                    ~1ms
  startSession:
    [container] initSession + container run + pi ready          ~5-15s ← BOTTLENECK
    [host] spawn pi + pi ready                                  ~1-3s
  send state (live)                                             ~1ms
  send pending permissions                                     ~1ms
iOS: receive connected → scheduleHistoryReload
  REST: GET /workspaces/:wid/sessions/:id                      ~100-500ms ← S4
  loadSession (full rebuild)                                   ~50-200ms ← C2
                                                    ─────────────
Total container: ~5.5-16s
Total host: ~1.2-4s
```

**The container cold start is the dominant bottleneck for perceived responsiveness.**

---

## Priority Matrix

| ID | Issue | Impact | Effort | Priority |
|---|---|---|---|---|
| R1 | No container reuse | Cold start 5-15s | High (warm pool) | **P0** |
| S1 | Sync JSON I/O storage | Event loop blocking | Medium (split files) | **P0** |
| S2 | Container spawn serial | Adds to cold start | Low (parallelize) | **P1** |
| C1 | Full trace reload on fg | 200-800ms delay | Medium (delta API) | **P1** |
| S3 | execSync in hot paths | Event loop freeze | Low (use async) | **P1** |
| S4 | Full JSONL parse per request | 100-500ms per load | Medium (cache) | **P1** |
| C3 | MainActor contention | Frame drops at high throughput | Medium (actor split) | **P2** |
| R2 | Sync file ops in initSession | 100-200ms blocked | Low (hash + async) | **P2** |
| S5 | Double persist on message_end | Wasteful I/O | Low | **P2** |
| C2 | Full loadSession rebuilds | 50-200ms flash | Low (already mitigated) | **P3** |
| C4 | ToolOutputStore growth | Memory over hours | Low (LRU) | **P3** |
| R3 | Container stop blocking | 5s freeze on stop | Low (async exec) | **P3** |

---

## Recommended Execution Order

### Sprint 1: Kill the Cold Start (R1 + S2)
- Implement warm container pool (1 pre-spawned per workspace)
- Parallelize gate socket + policy setup with container boot
- Remove 500ms probe delay

### Sprint 2: Storage Modernization (S1 + S5)
- Split storage: `session-meta.json` + `messages.jsonl` (append-only)
- Single-write for message_end (batch session + message)
- Async flush for dirty sessions

### Sprint 3: Trace Delta API (S4 + C1)
- Server caches built trace in memory per session
- `GET /workspaces/:wid/sessions/:id/events?since=<seq>` returns only new events
- iOS uses ETag/sequence for skip-if-unchanged
- Eliminates full JSONL re-parse on foreground

### Sprint 4: Async Everything (S3 + R2 + R3)
- Replace all `execSync` → `exec` / `execFile`
- Hash-based skill sync (skip unchanged)
- Async container stop
