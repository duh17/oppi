# ChatSessionManager State Machine Design

**Status:** Draft  
**Created:** 2026-03-02  
**Author:** pi (on behalf of Chen)  
**Related:** TODO-c01b5ed1

## Executive Summary

Refactor `ChatSessionManager.connect()` from implicit state (booleans + optional Tasks) into an explicit state machine with exhaustive transitions. This eliminates orphaned Tasks, makes cancellation automatic, and catches lifecycle bugs at compile time instead of runtime.

**Key Benefit:** The double-work bug fixed on 2026-03-02 (catch-up success not cancelling pending history reload) becomes impossible by construction — state transitions automatically cancel previous operations.

## Design Corrections (2026-03-02 Review)

This design was reviewed and corrected to match the actual code structure:

### 1. **Driver Loop is Stream-Driven (CRITICAL FIX)**

**Original Design (WRONG):** Proposed a `while` loop with `switch state` that dispatches to handlers, each containing a nested `for await message in stream` loop. This creates double stream iteration.

**Corrected Design:** The `for await message in stream` loop **IS** the driver. State transitions happen INSIDE this loop as events arrive. This matches the actual code.

```swift
// CORRECT (matches actual code):
for await message in stream {
    state = state.handle(message)
}

// WRONG (original proposal):
while true {
    switch state {
    case .awaitingConnected:
        for await message in stream { ... }  // nested iteration = bad
    }
}
```

### 2. **Catch-Up Blocks the Stream (MEDIUM FIX)**

**Original Design:** Modeled catch-up as a separate `.catchingUp(...)` state.

**Corrected Design:** `performCatchUpIfNeeded()` is an **`await` call INSIDE the stream loop** that takes 200-2000ms. During this await, the stream is paused. The state machine models this as a **blocking operation** within `.awaitingConnected` and `.streaming` states, not a separate state.

This blocking behavior must be preserved — it ensures catch-up completes before processing new messages.

### 3. **External Triggers via Per-Message Checks (LOW FIX)**

**Original Design:** Mentioned "any → disconnected on generation change" in transition table but didn't show how external triggers interact with the stream loop.

**Corrected Design:** External events (silence watchdog reconnect) fire via `reconnect()` which bumps `connectionGeneration`. The stream loop checks `generation != connectionGeneration` at the **top of each message iteration** to detect stale loops. This is a **per-message check**, not a separate state handler.

## Problem

Current `connect()` manages 5+ concurrent async paths with implicit state:

**Implicit State Variables:**
- `hasReceivedConnected: Bool` — tracks first vs reconnect .connected
- `historyReloadTask: Task<Void, Never>?` — background trace fetch
- `stateSyncTask: Task<Void, Never>?` — WS state request
- `autoReconnectTask: Task<Void, Never>?` — delayed reconnect
- `latestTraceSignature: TraceSignature?` — cache freshness tracking
- `lastSeenSeq: Int` — persisted sequence cursor (UserDefaults)
- `needsInitialScroll: Bool` — UI scroll trigger

**Symptoms:**
- Every fix adds another guard or cancellation check
- Task cancellation is manual and error-prone (`cancelHistoryReload()` called in 2 of 3 branches)
- Compiler cannot verify exhaustiveness — missing cancellation = runtime bug
- Lifecycle races require defensive `generation == connectionGeneration` checks scattered throughout

## Goal

Replace implicit state with an explicit state machine:

1. **Exhaustive transitions** — compiler enforces all cases handled
2. **Automatic cancellation** — entering a new state cancels the previous state's Task
3. **No orphaned Tasks** — each state owns exactly one async operation
4. **Preserve all 28 existing test contracts** — mechanical refactor, not behavioral change
5. **Preserve all metrics instrumentation** — `ChatMetricsService.record()` calls move into state handlers
6. **Keep SwiftUI `.task(id: connectionGeneration)` contract** — outer lifecycle unchanged

## State Definition

```swift
@MainActor
enum SessionEntryState: Equatable {
    case idle
    case loadingCache
    case cached(events: [TraceEvent], signature: TraceSignature)
    case connecting(workspaceId: String)
    case awaitingConnected(workspaceId: String, hasCachedHistory: Bool)
    case streaming
    case stopped(historyLoaded: Bool)
    case disconnected(reason: DisconnectReason)
}

enum DisconnectReason: Equatable {
    case cancelled
    case generationChanged
    case fatalError
    case streamEnded
}

struct TraceSignature: Equatable {
    let eventCount: Int
    let lastEventId: String?
}
```

**Removed States:**
- `.catchingUp(...)` — Catch-up is a **blocking operation** inside `.awaitingConnected` and `.streaming`, not a separate state
- `.reloadingHistory(...)` — History reload runs in a **background Task** during `.awaitingConnected`, `.streaming`, or `.stopped`, not a separate state

### State Ownership

Each state owns **at most one** async operation. Entering a new state cancels the previous operation.

| State | Owned Async Operation | Cancels On Exit |
|-------|----------------------|-----------------|
| `.idle` | None | N/A |
| `.loadingCache` | `TimelineCache.loadTrace()` | Yes |
| `.cached(...)` | None (waiting for WS) | N/A |
| `.connecting(...)` | `connection.streamSession()` | Yes |
| `.awaitingConnected(...)` | Optional history reload Task (background) | Yes |
| `.streaming` | `for await message in stream` | Yes |
| `.stopped(...)` | History reload Task (foreground, blocks until done) | Yes |
| `.disconnected(...)` | None (terminal) | N/A |

**Note on Catch-Up:** The `.catchingUp(...)` state from the original design is **not** modeled as a separate state. Instead, catch-up happens as a **blocking operation INSIDE** `.awaitingConnected` and `.streaming` states when a `.connected` message arrives. During the `await performCatchUpIfNeeded()` call (200-2000ms), the stream loop is paused. This is intentional to ensure catch-up completes before processing new messages.

## State Transition Table

| From State | Event | To State | Side Effects |
|------------|-------|----------|--------------|
| `.idle` | `connect()` called | `.loadingCache` | Reset connection, cancel all tasks, mark sync started |
| `.loadingCache` | Cache loaded (empty) | `.connecting(workspaceId)` | Record `cache_load_ms` (miss) |
| `.loadingCache` | Cache loaded (has events) | `.cached(events, signature)` | Render cache, record `cache_load_ms` + `reducer_load_ms`, set `needsInitialScroll = true` |
| `.cached(...)` | Session is stopped | `.stopped(historyLoaded: false)` | Schedule foreground history reload Task (blocks until done) |
| `.cached(...)` | WS opened successfully | `.awaitingConnected(workspaceId, true)` | No background history reload (cache present) |
| `.connecting(...)` | WS opened successfully | `.awaitingConnected(workspaceId, false)` | Schedule background history reload Task (no cache) |
| `.awaitingConnected(...)` | `.connected` received (no currentSeq) | `.streaming` | Schedule state sync, mark sync succeeded |
| `.awaitingConnected(...)` | `.connected` received + **catch-up blocks** (noGap) | `.streaming` | Cancel background history reload, record `catchup_ms` (no_gap), record `fresh_content_lag_ms` |
| `.awaitingConnected(...)` | `.connected` received + **catch-up blocks** (applied) | `.streaming` | Cancel background history reload, record `catchup_ms` (applied), record `fresh_content_lag_ms` |
| `.awaitingConnected(...)` | `.connected` received + **catch-up blocks** (seq regression) | `.streaming` | Schedule background history reload, record `catchup_ms` (seq_regression) |
| `.awaitingConnected(...)` | `.connected` received + **catch-up blocks** (ring miss) | `.streaming` | Schedule background history reload, record `catchup_ring_miss`, record `catchup_ms` (ring_miss) |
| `.awaitingConnected(...)` | `.connected` received + **catch-up blocks** (fetch failed) | `.streaming` | Schedule background history reload, record `catchup_ms` (fetch_failed), mark sync failed |
| `.streaming` | `.connected` received (reconnect) + **catch-up blocks** (noGap or applied) | `.streaming` | Record `catchup_ms`, record `fresh_content_lag_ms`, log "skipping full reload" |
| `.streaming` | `.connected` received (reconnect) + **catch-up blocks** (seq regression, ring miss, or fetch failed) | `.streaming` | Schedule background history reload |
| `.streaming` | `.connected` received (reconnect, no currentSeq) | `.streaming` | Schedule background history reload |
| `.streaming` | Stream ended (should reconnect) | `.disconnected(.streamEnded)` | Schedule auto-reconnect Task, increment `unexpectedStreamExitCount` |
| `.streaming` | Stream ended (Task.isCancelled) | `.disconnected(.cancelled)` | No reconnect |
| `.streaming` | **Per-message check:** generation changed | `.disconnected(.generationChanged)` | Break stream loop, no reconnect |
| `.stopped(historyLoaded: false)` | Background history reload completed | `.stopped(historyLoaded: true)` | Render timeline, mark sync succeeded |
| **any** | Fatal error during setup | `.disconnected(.fatalError)` | Cancel all tasks, no reconnect |

### Notes on Blocking Catch-Up

**Critical:** `performCatchUpIfNeeded()` is an **`await` call INSIDE the stream loop**. During this await (200-2000ms), the stream is paused — no new messages are processed.

This is shown in the transition table as "**catch-up blocks**" to emphasize that state transitions during catch-up happen SYNCHRONOUSLY within the message handler, not as separate states.

### Notes on External Triggers

External events (silence watchdog, user tap "Reconnect") fire via `reconnect()` which bumps `connectionGeneration`. The stream loop checks `generation != connectionGeneration` at the **top of each message iteration** to detect stale loops.

This is a **per-message check**, not a separate state. The transition table shows this as `.streaming` → `.disconnected(.generationChanged)` with the note "Per-message check".

### Notes on Reconnect Logic

The "should reconnect" decision in `.streaming → .disconnected(.streamEnded)` depends on:
- `hasReceivedConnected == true` (at least one .connected received)
- `generation == connectionGeneration` (not stale)
- `wantsAutoReconnect == true` (not in background)
- `!connection.fatalSetupError` (no unrecoverable error)
- Session status != `.stopped` (not intentionally stopped)

This logic stays identical to current implementation.

## Driver Loop Pseudocode

**Critical Design Choice:** The WebSocket stream drives the state machine, NOT a while-loop dispatcher. State transitions happen INSIDE the `for await message in stream` loop as events arrive.

**Why:** The actual code is `for await message in stream` — the stream IS the driver. A while loop with switch-case handlers that each contain nested `for await` loops creates double stream iteration, which is worse than current code.

```swift
@MainActor
func connect(
    connection: ServerConnection,
    reducer: TimelineReducer,
    sessionStore: SessionStore
) async {
    let generation = connectionGeneration
    var state: SessionEntryState = .idle
    var historyReloadTask: Task<Void, Never>? = nil
    var hasReceivedConnected = false
    
    // 1. Reset connection state
    connection.disconnectSession()
    connection.fatalSetupError = false
    cancelAllTasks()
    
    // 2. Load cached timeline (synchronously from disk)
    state = .loadingCache
    let cacheLoadStartMs = ChatMetricsService.nowMs()
    let cached = await TimelineCache.shared.loadTrace(sessionId)
    recordMetric(.cacheLoadMs, duration: cacheLoadStartMs, hit: cached != nil, events: cached?.eventCount ?? 0)
    
    if let cached, !cached.events.isEmpty {
        state = .cached(events: cached.events, signature: TraceSignature(eventCount: cached.eventCount, lastEventId: cached.lastEventId))
        let reducerLoadStartMs = ChatMetricsService.nowMs()
        reducer.loadSession(cached.events)
        recordMetric(.reducerLoadMs, duration: reducerLoadStartMs, source: "cache", events: cached.eventCount, items: reducer.items.count)
        needsInitialScroll = true
    } else {
        state = .connecting(workspaceId: resolveWorkspaceId(from: sessionStore))
    }
    
    // 3. Check if session is stopped (history-only path, no WebSocket)
    if sessionStore.sessions.first(where: { $0.id == sessionId })?.status == .stopped {
        state = .stopped(historyLoaded: false)
        scheduleHistoryReload(generation: generation, connection: connection, reducer: reducer, sessionStore: sessionStore, signature: latestTraceSignature, task: &historyReloadTask)
        // Wait for history to complete, then exit
        await historyReloadTask?.value
        return
    }
    
    // 4. Open WebSocket stream
    guard let stream = await openSessionStream(connection: connection, sessionStore: sessionStore) else {
        state = .disconnected(.fatalError)
        return
    }
    
    // 5. Schedule background history reload if no cache
    if case .connecting = state {
        scheduleHistoryReload(generation: generation, connection: connection, reducer: reducer, sessionStore: sessionStore, signature: nil, task: &historyReloadTask)
        state = .awaitingConnected(workspaceId: resolveWorkspaceId(from: sessionStore), hasCachedHistory: false)
    } else if case .cached = state {
        // Cache present — skip eager reload, rely on catch-up or reconnect triggers
        state = .awaitingConnected(workspaceId: resolveWorkspaceId(from: sessionStore), hasCachedHistory: true)
    }
    
    // 6. Wire external reconnect trigger (silence watchdog)
    connection.silenceWatchdog.onReconnect = { [weak self] in
        self?.reconnect()  // Bumps connectionGeneration, cancels current connect() task
    }
    
    // 7. Main event loop — stream messages drive state transitions
    for await message in stream {
        // External trigger check: generation changed (reconnect() called from outside)
        if generation != connectionGeneration {
            state = .disconnected(.generationChanged)
            break
        }
        
        // Task cancellation check (SwiftUI .task(id:) cancelled)
        if Task.isCancelled {
            state = .disconnected(.cancelled)
            break
        }
        
        markSyncSucceeded()
        
        // State-driven message handling
        switch state {
        case .awaitingConnected(let workspaceId, let hasCachedHistory):
            if case .connected(let session) = message {
                sessionStore.upsert(session)
                scheduleStateSync(generation: generation, connection: connection)
                
                let inboundMeta = connection.wsClient?.consumeInboundMeta(sessionId: sessionId)
                
                // Catch-up logic: BLOCKS the stream until fetch completes (200-2000ms)
                if let currentSeq = inboundMeta?.currentSeq {
                    let catchUpOutcome = await performCatchUpIfNeeded(
                        currentSeq: currentSeq,
                        generation: generation,
                        connection: connection,
                        reducer: reducer,
                        sessionStore: sessionStore
                    )
                    
                    // Transition based on catch-up result
                    switch catchUpOutcome {
                    case .noGap:
                        historyReloadTask?.cancel()
                        historyReloadTask = nil
                        recordFreshContentLagIfNeeded(reason: "catchup_no_gap")
                        state = .streaming
                        
                    case .applied:
                        historyReloadTask?.cancel()
                        historyReloadTask = nil
                        recordFreshContentLagIfNeeded(reason: "catchup_applied")
                        state = .streaming
                        
                    case .fullReloadScheduled:
                        // Seq regression or ring miss — history reload already scheduled
                        state = .streaming  // Continue streaming while reload happens in background
                    }
                } else {
                    // No seq metadata — go streaming
                    state = .streaming
                }
                
                hasReceivedConnected = true
            }
            
        case .streaming:
            // Reconnect detection: second .connected means WS dropped and recovered
            if case .connected(let session) = message {
                sessionStore.upsert(session)
                scheduleStateSync(generation: generation, connection: connection)
                
                let inboundMeta = connection.wsClient?.consumeInboundMeta(sessionId: sessionId)
                
                // BLOCKS stream for 200-2000ms during catch-up fetch
                if let currentSeq = inboundMeta?.currentSeq {
                    let catchUpOutcome = await performCatchUpIfNeeded(
                        currentSeq: currentSeq,
                        generation: generation,
                        connection: connection,
                        reducer: reducer,
                        sessionStore: sessionStore
                    )
                    
                    // Log reconnect outcome
                    switch catchUpOutcome {
                    case .noGap, .applied:
                        log.info("WS reconnected — catch-up complete, skipping full reload")
                        recordFreshContentLagIfNeeded(reason: catchUpOutcome == .noGap ? "catchup_no_gap" : "catchup_applied")
                    case .fullReloadScheduled:
                        log.info("WS reconnected — scheduled full history reload")
                    }
                } else {
                    log.warning("WS reconnected without currentSeq — falling back to full history reload")
                    scheduleHistoryReload(generation: generation, connection: connection, reducer: reducer, sessionStore: sessionStore, signature: latestTraceSignature, task: &historyReloadTask)
                }
            }
            
            // Seq tracking for deduplication
            if let seq = connection.wsClient?.consumeInboundMeta(sessionId: sessionId)?.seq {
                if seq <= lastSeenSeq {
                    continue  // Skip duplicate
                }
                recordFreshContentLagIfNeeded(reason: "stream_seq")
                updateLastSeenSeq(seq)
            }
            
            // TTFT measurement
            if case .turnAck(let command, _, let stage, _, _) = message,
               stage == .dispatched,
               command == "prompt" || command == "steer" || command == "follow_up",
               pendingTTFTStartMs == nil {
                pendingTTFTStartMs = ChatMetricsService.nowMs()
            }
            
            if case .agentEnd = message {
                pendingTTFTStartMs = nil
            }
            
            if case .textDelta = message, let startedAt = pendingTTFTStartMs {
                recordMetric(.ttftMs, duration: startedAt)
                pendingTTFTStartMs = nil
            }
            
        case .stopped, .loadingCache, .cached, .connecting, .disconnected:
            // Invalid states for message processing
            log.warning("Received message in invalid state: \(state)")
        }
        
        // Forward all messages to ServerConnection for pipeline processing
        connection.handleServerMessage(message, sessionId: sessionId)
    }
    
    // 8. Stream ended — determine if reconnect is needed
    if state != .disconnected(.cancelled) && state != .disconnected(.generationChanged) {
        state = .disconnected(.streamEnded)
    }
    
    // 9. Cleanup
    historyReloadTask?.cancel()
    connection.silenceWatchdog.onReconnect = nil
    disconnectIfCurrent(generation, connection: connection)
    
    // 10. Auto-reconnect if appropriate
    if case .disconnected(.streamEnded) = state,
       shouldAutoReconnect(generation: generation, hasReceivedConnected: hasReceivedConnected, connection: connection, sessionStore: sessionStore) {
        scheduleAutoReconnect(generation: generation)
    }
}
```

### Key Architectural Points

**1. Stream-Driven State Machine**

The `for await message in stream` loop is the driver. State transitions happen INSIDE this loop as messages arrive. This matches the actual code structure.

**NOT** a while loop with handlers that each contain nested `for await` loops (which would be double iteration).

**2. Blocking Catch-Up**

`performCatchUpIfNeeded()` is an `await` call INSIDE the stream loop. During this await (200-2000ms), the stream is paused — no new messages are processed. This is intentional to ensure catch-up completes before streaming resumes.

The state machine must model this explicitly:
- `.awaitingConnected` → **BLOCKS on catch-up** → `.streaming`
- `.streaming` → **BLOCKS on catch-up** → `.streaming`

**3. External Triggers**

External events (silence watchdog, user tap "Reconnect") fire via `reconnect()` which bumps `connectionGeneration`. The stream loop checks `generation != connectionGeneration` at the top of each iteration to detect stale loops.

This is a **per-message check**, not a separate state handler.

**4. Background Tasks**

History reload runs in a background Task while streaming continues. The state machine doesn't block on history completion — it's fire-and-forget with cancellation on state transitions.

Only exception: `.stopped` sessions wait for history to complete before exiting.

## Test Mapping

Each of the 28 existing tests maps to specific state transitions:

### Lifecycle Tests

| Test | States Involved | Transition |
|------|----------------|------------|
| `initialState` | `.idle` | N/A (precondition) |
| `firstAppearDoesNotBumpGeneration` | N/A | Lifecycle precondition |
| `subsequentAppearBumpsGeneration` | N/A | Lifecycle trigger |
| `reconnectBumpsGeneration` | N/A | Lifecycle trigger |
| `cleanupIsSafe` | any → `.disconnected(...)` | Cleanup idempotency |
| `cancelReconciliationIsSafe` | N/A | Reconciliation cleanup |

### Auto-Reconnect Tests

| Test | States Involved | Transition |
|------|----------------|------------|
| `unexpectedConnectedStreamExitSchedulesReconnect` | `.streaming` → `.disconnected(.streamEnded)` | Auto-reconnect scheduled |
| `cancelledStreamExitDoesNotScheduleReconnect` | `.streaming` → `.disconnected(.cancelled)` | No reconnect |

### Stopped Session Tests

| Test | States Involved | Transition |
|------|----------------|------------|
| `stoppedSessionDoesNotOpenWebSocket` | `.cached(...)` → `.stopped(false)` → `.stopped(true)` | History-only load |

### Cache Optimization Tests

| Test | States Involved | Transition |
|------|----------------|------------|
| `initialConnectSkipsEagerHistoryReloadWhenCachePresent` | `.cached(...)` → `.awaitingConnected(..., true)` | No reload scheduled |

### First-Connect Catch-Up Tests (2026-03-02 double-work fix)

| Test | States Involved | Transition |
|------|----------------|------------|
| `firstConnectCatchUpAppliedCancelsPendingHistoryReload` | `.awaitingConnected(...)` + **blocking catch-up** → `.streaming` | Cancel background reload on catch-up success |
| `firstConnectNoGapCancelsPendingHistoryReload` | `.awaitingConnected(...)` + **blocking catch-up** → `.streaming` | Cancel background reload on no-gap |
| `firstConnectSeqRegressionKeepsHistoryReload` | `.awaitingConnected(...)` + **blocking catch-up** → `.streaming` | Schedule background reload on seq regression |

### Lifecycle Race Tests

| Test | States Involved | Transition |
|------|----------------|------------|
| `staleGenerationCleanupDoesNotDisconnectNewerReconnectStream` | `.disconnected(...)` cleanup | Generation guard |
| `staleCleanupSkipsDisconnectWhenSocketOwnershipMoved` | `.disconnected(...)` cleanup | ActiveSessionId guard |

### Reconnect Tests

| Test | States Involved | Transition |
|------|----------------|------------|
| `reconnectReloadUsesLatestTraceSignature` | `.streaming` + second `.connected` → **blocking catch-up** → `.streaming` | Background reload with signature tracking |
| `reconnectWithSequencedCatchUpSkipsFullHistoryReload` | `.streaming` + second `.connected` → **blocking catch-up** (applied/noGap) → `.streaming` | Skip background reload when catch-up succeeds |
| `reconnectReloadCancelsStaleInFlightTasks` | `.streaming` + second `.connected` → **blocking catch-up** → `.streaming` | Cancel old background reload, start new one |

### State Sync Tests

| Test | States Involved | Transition |
|------|----------------|------------|
| `stateSyncRequestedOnConnectedMessagesOnly` | `.awaitingConnected(...)` → `.streaming` | State sync side effect |

### History Reload Tests

| Test | States Involved | Transition |
|------|----------------|------------|
| `busyHistoryReloadDoesNotClobberLiveStreamingRows` | `.reloadingHistory(...)` while streaming | Reload deferral |

### Catch-Up Replay Tests

| Test | States Involved | Transition |
|------|----------------|------------|
| `reconnectCatchUpReplaysStopConfirmedDeterministically` | `.streaming` + **blocking catch-up** → `.streaming` | Message replay during catch-up |
| `reconnectCatchUpStopFailedLeavesNoStuckStoppingState` | `.streaming` + **blocking catch-up** → `.streaming` | Message replay during catch-up |
| `reconnectCatchUpRingMissForcesFullHistoryReload` | `.streaming` + **blocking catch-up** (ring miss) → `.streaming` | Schedule background reload on ring miss |

### Seq Deduplication Tests

| Test | States Involved | Transition |
|------|----------------|------------|
| `duplicateSeqEventsAreDroppedAfterReconnect` | `.streaming` | Seq filtering |

### Snapshot Flush Tests (not in state machine)

| Test | States Involved | Transition |
|------|----------------|------------|
| `flushSnapshotPersistsTraceWhenAvailable` | Background operation | N/A |
| `flushSnapshotDebouncesBackToBackCalls` | Background operation | N/A |
| `flushSnapshotForceBypassesDebounceWindow` | Background operation | N/A |
| `flushSnapshotSkipsSaveWhenTraceMissing` | Background operation | N/A |

## Metrics Preservation

All existing `ChatMetricsService.record()` calls are preserved. They move into the appropriate state handler:

| Metric | Current Location | New Location (State Handler) |
|--------|-----------------|------------------------------|
| `cache_load_ms` | `connect()` after cache load | `.loadingCache` handler |
| `reducer_load_ms` | `connect()` after reducer load (cache) | `.cached(...)` handler |
| `reducer_load_ms` | `loadHistory()` after reducer load (history) | `.reloadingHistory(...)` handler |
| `catchup_ms` | `performCatchUpIfNeeded()` | `.catchingUp(...)` handler |
| `catchup_ring_miss` | `performCatchUpIfNeeded()` | `.catchingUp(...)` handler |
| `full_reload_ms` | `loadHistory()` | `.reloadingHistory(...)` handler |
| `ttft_ms` | `connect()` stream loop | `.streaming` handler |
| `fresh_content_lag_ms` | `recordFreshContentLagIfNeeded()` | Various transition points |
| `timeline_apply_ms` | `TimelineReducer` | Unchanged (reducer internal) |
| `timeline_layout_ms` | `ChatTimelineCollectionView` | Unchanged (view internal) |

## Migration Plan

### Phase 1: Add state enum + event-driven transitions (2-3 days)

**Goal:** Mechanical refactor with zero behavior change — replace implicit state with explicit state enum, keeping the existing stream-driven control flow.

**Steps:**
1. Define `SessionEntryState` enum with associated values (8 states: idle, loadingCache, cached, connecting, awaitingConnected, streaming, stopped, disconnected)
2. Add `private(set) var entryState: SessionEntryState = .idle`
3. Add `transitionTo(_:from:)` helper to log state changes (no automatic cancellation yet)
4. Instrument existing `connect()` with state tracking:
   - Set `entryState = .loadingCache` before cache load
   - Set `entryState = .cached(...)` or `.connecting(...)` after cache load
   - Set `entryState = .stopped(...)` if session is stopped
   - Set `entryState = .awaitingConnected(...)` after WS opens
   - Set `entryState = .streaming` in the stream loop after first `.connected`
   - Set `entryState = .disconnected(...)` when stream ends
5. Wrap catch-up logic with state tracking (no extraction yet):
   ```swift
   // Before catch-up
   log.debug("Performing catch-up (state: \(entryState))")
   let outcome = await performCatchUpIfNeeded(...)
   // After catch-up
   log.debug("Catch-up outcome: \(outcome) (state: \(entryState))")
   ```
6. All 28 existing tests must pass
7. Add `entryState` assertions to 3-5 key tests to validate tracking

**Verification:**
- Run full test suite: `xcodebuild -scheme Oppi -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test -only-testing:OppiTests/ChatSessionManagerTests`
- Verify state transitions appear in logs with expected sequence
- Verify no new warnings or build errors
- Manually test on device: enter session, reconnect, go background, return

**Risks:**
- Low-Medium: Adding state tracking without changing control flow is low-risk, but touches critical path
- Mitigation: Add state enum first (compile-only change), then add tracking line-by-line
- Rollback: `git revert` if tests fail

### Phase 2: Wire state transitions to existing tests (1 day)

**Goal:** Add state transition assertions to existing tests without changing production code.

**Steps:**
1. Add `entryState` assertions to lifecycle tests:
   ```swift
   #expect(manager.entryState == .awaitingConnected(workspaceId: "...", hasCachedHistory: false))
   #expect(manager.entryState == .streaming)
   ```
2. Add 3-5 new transition-level tests:
   - "First connect with cache → .cached → .awaitingConnected (true) → .streaming"
   - "First connect without cache → .connecting → .awaitingConnected (false) → .streaming"
   - "Reconnect with catch-up → .streaming (blocks on catch-up) → .streaming"
   - "Stream ends with .connected received → .disconnected(.streamEnded) → auto-reconnect"
   - "Generation bumped during streaming → .disconnected(.generationChanged) → no reconnect"
3. Verify all metrics still fire correctly (spot-check in Xcode console)
4. All 31+ tests must pass

**Verification:**
- Full test suite passes
- State assertions match expected lifecycle flow
- No flakiness introduced by state checks
- Metrics logs still appear in console output

**Risks:**
- Low: Test changes only, no production code
- Mitigation: Keep existing test logic intact, only add state assertions
- Rollback: Remove new assertions if flaky

### Phase 3: Use state for Task cancellation (1-2 days)

**Goal:** Make state transitions automatically cancel background Tasks.

**Steps:**
1. Add `private var historyReloadTask: Task<Void, Never>?` to state enum (or keep as instance var)
2. Modify `transitionTo(_:from:)` to cancel Tasks owned by the previous state:
   ```swift
   private func transitionTo(_ newState: SessionEntryState, from oldState: SessionEntryState) -> SessionEntryState {
       // Cancel Tasks owned by old state
       switch oldState {
       case .awaitingConnected, .streaming:
           historyReloadTask?.cancel()
           historyReloadTask = nil
       default:
           break
       }
       
       // Log transition
       if oldState != newState {
           log.debug("State transition: \(oldState) → \(newState)")
       }
       
       return newState
   }
   ```
3. Remove manual `cancelHistoryReload()` calls — now automatic via state transitions
4. Keep `hasReceivedConnected` as local var in `connect()` (needed for reconnect logic)
5. Keep `stateSyncTask` and `autoReconnectTask` as instance vars (orthogonal to session entry state)
6. All tests must still pass

**Verification:**
- Full test suite passes
- No orphaned Tasks (verify with Instruments → Leaks)
- No unexpected reconnects (manual testing)
- Double-work bug (2026-03-02) remains fixed

**Risks:**
- Medium: Changes Task cancellation strategy
- Mitigation: Verify state transitions are exhaustive via compiler, run full test suite
- Rollback: Keep Phase 1+2 changes, revert Phase 3 if issues arise

**Optional Incremental Rollout:**
- Ship Phase 1+2 to TestFlight first
- Monitor Sentry for new crash patterns
- Deploy Phase 3 after confidence builds

## Success Criteria

1. ✅ All 28 existing tests pass
2. ✅ State transitions are explicit and logged (easier to debug lifecycle issues)
3. ✅ No orphaned Tasks — state transitions automatically cancel background work
4. ✅ `connect()` method keeps existing stream-driven structure (~200 lines, but with explicit state tracking)
5. ✅ Double-work bug (2026-03-02) remains fixed: catch-up success cancels pending history reload
6. ✅ All `ChatMetricsService` instrumentation points preserved
7. ✅ SwiftUI `.task(id: connectionGeneration)` contract unchanged
8. ✅ `ServerConnection.handleServerMessage()` still called synchronously from stream loop
9. ✅ `DeltaCoalescer` batching at 33ms unchanged
10. ✅ Blocking catch-up behavior preserved (stream pauses during `await performCatchUpIfNeeded()`)
11. ✅ External triggers (silence watchdog) work via per-message generation checks

## Risk Analysis

### Overall Risk: Medium

**Why Medium:**
- Touches the most critical path in the app (session lifecycle)
- 28 existing tests + 3 new catch-up tests = solid regression net
- Refactor is mechanical (states already exist implicitly)
- Compiler will enforce exhaustive state handling
- Can ship Phase 1+2 first, defer Phase 3 if nervous

**Mitigation Strategies:**
1. Extract one handler at a time, run tests after each
2. Ship Phase 1 to TestFlight before Phase 2
3. Monitor Sentry for new crash patterns
4. Keep manual cancellation as belt-and-suspenders until confidence builds
5. Rollback plan: `git revert` + emergency patch release

### Phase-Specific Risks

**Phase 1:**
- **Risk:** Break existing behavior during mechanical extraction
- **Mitigation:** Run tests after each handler extraction
- **Rollback:** Git revert to last passing commit

**Phase 2:**
- **Risk:** Test assertions introduce flakiness
- **Mitigation:** Keep existing test logic intact, only add state checks
- **Rollback:** Remove new assertions, keep Phase 1 changes

**Phase 3:**
- **Risk:** Removing manual cancellation uncovers hidden race conditions
- **Mitigation:** Verify exhaustive state handling first, ship Phase 1+2 to TestFlight
- **Rollback:** Keep manual cancellation as defensive code

## Open Questions

1. **Should `hasReceivedConnected` become part of the state enum?**
   - Current design: Track as `var hasReceivedConnected` in `connect()` method
   - Alternative: Add `.streaming(firstConnect: Bool)` to encode this
   - **Decision:** Keep as local var in `connect()` — only needed for reconnect detection logic, not core to state machine

2. **Should catch-up be a separate state or a blocking operation?**
   - Current design: **Blocking operation** inside `.awaitingConnected` and `.streaming`
   - Alternative: Add `.catchingUp(...)` state
   - **Decision:** Keep as blocking operation — matches actual code structure where `await performCatchUpIfNeeded()` pauses the stream loop

3. **Should history reload be a separate state or a background Task?**
   - Current design: **Background Task** that runs concurrently with streaming
   - Alternative: Add `.reloadingHistory(...)` state
   - **Decision:** Keep as background Task — history reload doesn't block message processing, and `.stopped` sessions need foreground history fetch

4. **Should auto-reconnect scheduling be a state?**
   - Current design: Happens in cleanup after `.disconnected(.streamEnded)`
   - Alternative: Add `.schedulingReconnect(delay: Duration)`
   - **Decision:** Keep in cleanup — not a session entry state, just a side effect of stream exit

5. **Should state transitions automatically cancel Tasks?**
   - Current design (Phase 1+2): Manual cancellation via `cancelHistoryReload()`
   - Alternative (Phase 3): Automatic cancellation in `transitionTo(_:from:)`
   - **Decision:** Start with manual (Phase 1+2), migrate to automatic (Phase 3) after confidence builds

## Appendix: Code Size Comparison

**Before (current implementation):**
- `connect()` method: ~200 lines
- State management: Implicit (booleans + optional Tasks)
- Cancellation: Manual (`cancelHistoryReload()`, `cancelStateSync()`, etc.)
- Debugging: Requires tracing multiple boolean flags and Task states

**After (state machine):**
- `connect()` method: ~200 lines (same structure, with explicit state tracking)
- State enum: ~15 lines (8 states)
- `transitionTo(_:from:)` helper: ~10 lines (logs transitions, optional Task cancellation)
- State tracking: ~20 lines added to existing logic (set `entryState = ...`)
- Total code: ~245 lines (slight increase)
- **But:** Explicit state tracking, logged transitions, automatic Task cancellation via state changes

**Net Win:** Slightly higher LoC but much easier to debug (state transitions visible in logs), easier to test (state assertions), and safer (automatic Task cancellation).

## References

- TODO-c01b5ed1: Original refactor request
- 2026-03-02 double-work fix: Catch-up success not cancelling pending history reload
- `ChatSessionManager.swift`: Current implementation
- `ChatSessionManagerTests.swift`: 28 existing test contracts
- State machine pattern: https://en.wikipedia.org/wiki/Finite-state_machine
