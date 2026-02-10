# Timeline Cache — Design

Make ChatView instant on session switch and foreground recovery by caching server responses locally.

## Problem

Every time the user opens a session (switch, foreground, cold launch), the app:
1. Fetches full session trace via REST (`GET /sessions/:id`)
2. Parses JSON into `[TraceEvent]`
3. Rebuilds entire `[ChatItem]` timeline via `reducer.loadSession()`

This means a blank/loading state on every session open. For long sessions with hundreds of tool calls, the parse + rebuild is noticeable even after the network round-trip.

## Solution

Cache `[TraceEvent]` per session + `[Session]` list + `[Workspace]` list to `Library/Caches/`. Show cached data immediately, refresh from server in background, update only if changed.

## Cache Layout

```
Library/Caches/dev.chenda.PiRemote/
├── session-list.json           # [Session] list
├── workspaces.json             # [Workspace] list
├── skills.json                 # [SkillInfo] list
└── traces/
    ├── <sessionId>.json        # CachedTrace per session
    └── ...
```

All in `cachesDirectory` — iOS can evict under storage pressure (correct behavior for a cache).

## CachedTrace Format

```swift
struct CachedTrace: Codable {
    let sessionId: String
    let eventCount: Int
    let lastEventId: String?  // ID of last TraceEvent (for staleness check)
    let savedAt: Date
    let events: [TraceEvent]
}
```

Staleness check: compare `(eventCount, lastEventId)` from server response vs cached. If same → skip `loadSession()`. If different → update cache + reload.

## Cache Service

```swift
actor TimelineCache {
    // Trace per session
    func loadTrace(_ sessionId: String) -> CachedTrace?
    func saveTrace(_ sessionId: String, events: [TraceEvent])
    func removeTrace(_ sessionId: String)

    // Session list
    func loadSessionList() -> [Session]?
    func saveSessionList(_ sessions: [Session])

    // Workspaces + skills
    func loadWorkspaces() -> [Workspace]?
    func saveWorkspaces(_ workspaces: [Workspace])
    func loadSkills() -> [SkillInfo]?
    func saveSkills(_ skills: [SkillInfo])

    // Cleanup
    func clear()
    func evictStaleTraces(keepIds: Set<String>)
}
```

- `actor` for thread-safe disk I/O off main thread
- All methods are async (disk reads)
- Decode failures → return nil (cache miss, not crash)
- No schema versioning — Codable decode failure = automatic cache invalidation

## Integration Points

### 1. ChatSessionManager.connect() — Session Open

**Before (current):**
```
open WS → fetch trace from REST → loadSession(trace) → render
```

**After:**
```
open WS → load cached trace → loadSession(cached) → render immediately
         ↘ fetch trace from REST (background)
           → if changed: loadSession(fresh), save to cache
           → if same: no-op
```

```swift
// ChatSessionManager.connect()
func connect(...) async {
    // ... open WS stream ...

    // Show cached timeline immediately
    if let cached = await cache.loadTrace(sessionId) {
        reducer.loadSession(cached.events)
        needsInitialScroll = true
    }

    // Fetch fresh trace in background
    let historyTask = Task { @MainActor in
        let (session, trace) = try await api.getSession(id: sessionId)
        sessionStore.upsert(session)

        // Only rebuild if trace actually changed
        let lastId = trace.last?.id
        if cached == nil || cached?.eventCount != trace.count || cached?.lastEventId != lastId {
            reducer.loadSession(trace)
            needsInitialScroll = true
            await cache.saveTrace(sessionId, events: trace)
        }
    }

    // ... consume WS stream ...
}
```

### 2. ServerConnection.reconnectIfNeeded() — Foreground Recovery

**Before:** Fetches session list + workspaces + active session trace on every foreground.

**After:** Load all from cache first, then refresh in background.

```swift
func reconnectIfNeeded() async {
    // Instant: show cached lists
    if let cached = await cache.loadSessionList() {
        sessionStore.sessions = cached
    }

    // Background refresh
    if let fresh = try? await apiClient.listSessions() {
        sessionStore.sessions = fresh
        await cache.saveSessionList(fresh)
    }

    // ... rest of foreground recovery ...
}
```

### 3. WorkspaceStore.load() — Workspaces + Skills

Same pattern: load cached → show → fetch fresh → update if changed.

### 4. Save on Receive

Update caches when fresh data arrives:
- `sessionStore.sessions` changes → save session list
- `workspaceStore` loads → save workspaces + skills  
- `loadHistory()` completes → save trace

### 5. Cleanup

When a session is deleted, remove its trace cache:
```swift
func deleteSession(id: String) async throws {
    try await apiClient.deleteSession(id: id)
    sessionStore.remove(id: id)
    await cache.removeTrace(id)
}
```

Periodic eviction: after loading session list, evict traces for sessions that no longer exist:
```swift
let activeIds = Set(sessions.map(\.id))
await cache.evictStaleTraces(keepIds: activeIds)
```

## What NOT to Cache

- **Live WebSocket deltas** — real-time, can't predict
- **Permission state** — server-authoritative, must be fresh
- **ToolOutputStore contents** — already has its own FIFO eviction + REST lazy-load
- **Extension UI dialogs** — ephemeral, session-scoped

## Performance Budget

| Operation | Target | Notes |
|-----------|--------|-------|
| Cache read (trace, 200 events) | < 10ms | JSON decode on actor thread |
| Cache write (trace) | < 20ms | Fire-and-forget, doesn't block UI |
| `loadSession()` rebuild | < 15ms | Already optimized with index cache |
| Total: cached session open | < 25ms | vs ~100-300ms current (network + parse) |

## Size Budget

- Typical trace: 50-200 events, ~50-200KB JSON
- 20 cached sessions: ~2-4MB total
- Session list + workspaces: < 50KB
- Well within iOS cache directory norms

## Edge Cases

**Compaction:** Server trace is compaction-aware (hides pre-compaction events). If compaction happened since cache, the trace will be shorter/different. The staleness check (eventCount + lastEventId) catches this — cache is invalidated and rebuilt.

**Session fork:** New session gets a new ID. Cache miss → normal load path.

**Schema migration:** If `TraceEvent` gains new fields, old cached JSON just decodes with nil optionals. If fields are removed or types change, decode fails → cache miss → fresh load. No explicit migration needed.

**Concurrent writes:** `actor` serialization prevents races. Two foreground recoveries can't corrupt the same file.

## Implementation Order

1. `TimelineCache` actor + file I/O
2. Wire into `ChatSessionManager.connect()` (biggest win)
3. Wire into `ServerConnection.reconnectIfNeeded()` for session list
4. Wire into `WorkspaceStore.load()` for workspaces/skills
5. Cleanup: eviction on session delete + stale trace pruning
