import Foundation
import Testing
@testable import Oppi

/// Tests for the JSONL-first re-entry optimization.
///
/// Design: when re-entering a chat (navigating back), prefer loading the full
/// trace from JSONL via REST over ring-based catch-up. The trace is the canonical
/// source, compressible, and doesn't require the session to be started.
///
/// Strategy:
///   1. Subscribe WSS (get currentSeq from ack)
///   2. Fetch JSONL trace via REST → manager.reducer.loadSession(trace) [full rebuild]
///   3. Seed lastSeenSeq = currentSeq → skip ring catch-up
///   4. Live WSS events with seq > currentSeq append normally
///
/// Ring catch-up is reserved for brief WS drops during active streaming.
///
/// Edge cases tested:
///   - Re-entry with cache: trace fetch + seq seed, no ring catch-up
///   - Re-entry without cache: trace fetch populates timeline, seq seeded
///   - Active session: live events during trace fetch don't get lost
///   - Trace fetch fails: falls back to ring catch-up (existing behavior)
///   - Seq gap between trace snapshot and WSS: live events fill the gap
///   - Server restart (seq reset to 0): full rebuild from trace
///   - Rapid re-entry (double appear): second generation cancels first
///   - WS reconnect during streaming: ring catch-up (not trace)
@Suite("Chat Session Re-entry")
struct ChatSessionReentryTests {

    // MARK: - Edge 1: Re-entry with cache seeds seq from subscribe, skips ring

    /// When re-entering a chat with cached history, the trace fetch should
    /// rebuild the timeline and the seq should be seeded from the subscribe
    /// ack's currentSeq — bypassing the ring catch-up entirely.
    @MainActor
    @Test func reentryWithCacheSeedsSeqFromSubscribeSkipsRing() async {
        let sessionId = "reentry-cache-\(UUID().uuidString)"
        let workspaceId = "w1"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        // Seed cache so the manager has cached history
        await TimelineCache.shared.saveTrace(sessionId, events: [
            makeTraceEvent(id: "cached-1", text: "old cached content"),
        ])

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        // Track whether ring catch-up is called
        var ringCatchUpCalled = false
        manager._loadCatchUpForTesting = { _, _ in
            ringCatchUpCalled = true
            return APIClient.SessionEventsResponse(
                events: [],
                currentSeq: 42,
                session: makeTestSession(id: sessionId, status: .ready),
                catchUpComplete: true
            )
        }

        // Trace fetch returns full history
        manager._fetchSessionTraceForTesting = { _, _ in
            (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .ready),
                [
                    makeTraceEvent(id: "t1", type: .user, text: "Hello"),
                    makeTraceEvent(id: "t2", text: "Hi there!"),
                ]
            )
        }

        // Subscribe ack provides currentSeq = 42
        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 42),
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .ready))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: workspaceId)))

        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { manager.entryState == .streaming }
        })

        // Ring catch-up should NOT have been called (cache present = use trace path)
        #expect(!ringCatchUpCalled, "Re-entry with cache should skip ring catch-up")

        // Seq should be seeded from subscribe ack
        let seededSeq = await connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
        #expect(seededSeq == 42, "Seq should be seeded from subscribe ack currentSeq")

        streams.finish(index: 0)
        await connectTask.value
        await TimelineCache.shared.removeTrace(sessionId)
    }

    // MARK: - Edge 2: Live events during trace fetch are not lost

    /// When the session is actively streaming during re-entry, events that
    /// arrive via WSS after the subscribe (seq > currentSeq) should be
    /// applied after the trace rebuild — not dropped.
    @MainActor
    @Test func liveEventsDuringTraceFetchAreApplied() async {
        let sessionId = "reentry-live-\(UUID().uuidString)"
        let workspaceId = "w1"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        await TimelineCache.shared.saveTrace(sessionId, events: [
            makeTraceEvent(id: "cached-1", text: "old content"),
        ])

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadCatchUpForTesting = { _, _ in nil } // no ring catch-up

        // Slow trace fetch — gives time for live events to arrive
        manager._fetchSessionTraceForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(200))
            return (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy),
                [
                    makeTraceEvent(id: "t1", type: .user, text: "Hello"),
                    makeTraceEvent(id: "t2", text: "Working on it..."),
                ]
            )
        }

        // Subscribe ack: currentSeq = 10
        // Live events: agentStart is durable (has seq), textDelta is ephemeral (no seq)
        var inboundMetaConsumed = false
        var liveEventCount = 0
        manager._consumeInboundMetaForTesting = {
            if !inboundMetaConsumed {
                inboundMetaConsumed = true
                return .init(seq: nil, currentSeq: 10)
            }
            liveEventCount += 1
            if liveEventCount == 1 {
                return .init(seq: 11, currentSeq: nil)
            }
            return nil // ephemeral events have no seq
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        // Live event arrives while trace is being fetched (seq=11 > currentSeq=10)
        streams.yield(index: 0, message: .agentStart)
        streams.yield(index: 0, message: .textDelta(delta: "LIVE_CONTENT"))
        try? await Task.sleep(for: .milliseconds(50))

        // The live event should be accepted (seq 11 > seeded 10)
        let seededSeq = await connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
        #expect(seededSeq >= 11, "Live events with seq > seeded currentSeq should be accepted")

        // Verify live content is in the timeline
        let hasLiveContent = manager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("LIVE_CONTENT")
            }
            return false
        }
        #expect(hasLiveContent, "Live events during trace fetch should appear in timeline")

        streams.finish(index: 0)
        await connectTask.value
        await TimelineCache.shared.removeTrace(sessionId)
    }

    // MARK: - Edge 3: Server restart (seq regression to 0)

    /// When the server restarts, currentSeq drops to 0. The client's persisted
    /// lastSeenSeq is stale. This should trigger a full trace rebuild, not
    /// an infinite catch-up loop.
    @MainActor
    @Test func serverRestartSeqRegressionTriggersTraceRebuild() async {
        let sessionId = "reentry-restart-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        // Persist a high lastSeenSeq from before the server restart
        UserDefaults.standard.set(500, forKey: "chat.lastSeenSeq.\(sessionId)")

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let tracker = HistoryReloadTracker()
        manager._loadHistoryForTesting = { cachedCount, cachedLastId in
            _ = await tracker.recordCall(cachedEventCount: cachedCount, cachedLastEventId: cachedLastId)
            return (eventCount: 20, lastEventId: "evt-20")
        }

        // Subscribe ack: currentSeq = 0 (server restarted)
        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 0),
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))

        // Should trigger full reload due to seq regression (500 → 0)
        #expect(await tracker.waitForCalls(1), "Seq regression should trigger full trace reload")

        // Wait for streaming state (regression triggers reload but still transitions)
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        // Persisted seq should be reset to 0 after regression detection
        let seededSeq = await connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
        #expect(seededSeq == 0, "Coordinator seq should be reset to server's currentSeq after regression")

        streams.finish(index: 0)
        await connectTask.value
        UserDefaults.standard.removeObject(forKey: "chat.lastSeenSeq.\(sessionId)")
    }

    // MARK: - Edge 4: WS reconnect during streaming uses ring (not trace)

    /// Brief WS drops during active streaming should use the ring-based
    /// catch-up (fast, incremental) — NOT the full trace rebuild.
    /// This validates the ring is preserved for its designed purpose.
    @MainActor
    @Test func wsReconnectDuringStreamingUsesRingNotTrace() async {
        let sessionId = "reentry-brief-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        // Track both paths
        var ringCatchUpCalls = 0
        manager._loadCatchUpForTesting = { since, _ in
            ringCatchUpCalls += 1
            return APIClient.SessionEventsResponse(
                events: [
                    .init(seq: since + 1, message: .state(session: makeTestSession(id: sessionId, status: .busy))),
                ],
                currentSeq: since + 1,
                session: makeTestSession(id: sessionId, status: .busy),
                catchUpComplete: true
            )
        }

        // First connect: currentSeq = 5, then reconnect: currentSeq = 8
        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 5),     // first connect
            .init(seq: nil, currentSeq: 8),     // WS reconnect
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        // First connect
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        let firstRingCalls = ringCatchUpCalls

        // Simulate WS reconnect (second .connected in streaming state)
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
        try? await Task.sleep(for: .milliseconds(100))

        // Ring catch-up should have been used for the reconnect
        #expect(ringCatchUpCalls > firstRingCalls, "WS reconnect during streaming should use ring catch-up")

        streams.finish(index: 0)
        await connectTask.value
    }

    // MARK: - Edge 5: Duplicate seq events dropped after trace seed

    /// After seeding lastSeenSeq from the subscribe ack, any live events
    /// with seq <= seeded value should be silently dropped (they're already
    /// in the trace).
    @MainActor
    @Test func duplicateSeqEventsDroppedAfterTraceSeed() async {
        let sessionId = "reentry-dedup-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        await TimelineCache.shared.saveTrace(sessionId, events: [
            makeTraceEvent(id: "cached-1", text: "cached"),
        ])

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        // Subscribe ack: currentSeq = 10
        // Then deliver events with seq 8, 9, 10 (all <= seeded) and seq 11 (new)
        var inboundMetaIndex = 0
        let inboundMetaSequence: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 10),    // subscribe ack
            .init(seq: 8, currentSeq: nil),     // stale
            .init(seq: 9, currentSeq: nil),     // stale
            .init(seq: 10, currentSeq: nil),    // stale (equal to seeded)
            .init(seq: 11, currentSeq: nil),    // new
        ]
        manager._consumeInboundMetaForTesting = {
            guard inboundMetaIndex < inboundMetaSequence.count else { return nil }
            let meta = inboundMetaSequence[inboundMetaIndex]
            inboundMetaIndex += 1
            return meta
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1", status: .ready))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        // Deliver stale events (seq 8, 9, 10) — should be dropped
        streams.yield(index: 0, message: .state(session: makeTestSession(id: sessionId, status: .busy)))
        streams.yield(index: 0, message: .state(session: makeTestSession(id: sessionId, status: .stopping)))
        streams.yield(index: 0, message: .state(session: makeTestSession(id: sessionId, status: .busy)))

        // Deliver new event (seq 11) — should be accepted
        streams.yield(index: 0, message: .state(session: makeTestSession(id: sessionId, status: .ready)))
        try? await Task.sleep(for: .milliseconds(80))

        // Only seq 11 should have been processed — session should be .ready (not .busy or .stopping)
        let finalStatus = sessionStore.sessions.first(where: { $0.id == sessionId })?.status
        #expect(finalStatus == .ready, "Only seq > seeded should be processed; stale events should be dropped")

        let trackedSeq = await connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
        #expect(trackedSeq == 11, "Last seen seq should reflect only the accepted event")

        streams.finish(index: 0)
        await connectTask.value
        await TimelineCache.shared.removeTrace(sessionId)
    }

    // MARK: - Edge 6: No cache, no prior seq — fresh install re-entry

    /// Fresh install with no cache and no persisted seq. The trace fetch
    /// populates the timeline. currentSeq from subscribe seeds the baseline.
    @MainActor
    @Test func freshInstallReentryPopulatesFromTrace() async {
        let sessionId = "reentry-fresh-\(UUID().uuidString)"
        let workspaceId = "w1"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        // No cache, trace fetch provides history
        manager._fetchSessionTraceForTesting = { _, _ in
            (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .ready),
                [
                    makeTraceEvent(id: "t1", type: .user, text: "What is 2+2?"),
                    makeTraceEvent(id: "t2", text: "4"),
                ]
            )
        }

        // Subscribe ack: currentSeq = 15 (session had 15 durable events)
        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 15),
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .ready))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: workspaceId)))

        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { manager.entryState == .streaming }
        })

        // Wait for trace fetch to complete
        try? await Task.sleep(for: .milliseconds(200))

        // Timeline should have content from trace
        let hasContent = manager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text == "4"
            }
            return false
        }
        #expect(hasContent, "Fresh install should populate timeline from trace fetch")

        streams.finish(index: 0)
        await connectTask.value
    }

    // MARK: - Edge 7: Rapid double-appear cancels first generation

    /// When the user navigates away and back quickly (double appear),
    /// the second generation should cleanly cancel the first without
    /// leaving stale state.
    @MainActor
    @Test func rapidDoubleAppearCancelsFirstGeneration() async {
        let sessionId = "reentry-rapid-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()

        // First connect
        let firstConnect = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        // Rapid re-entry: bump generation before first connect settles
        manager.reconnect()
        #expect(manager.connectionGeneration == 1)

        // Finish first stream — triggers generation mismatch exit
        streams.finish(index: 0)
        await firstConnect.value

        // After first connect exits, state should reflect the disconnect
        let stateAfterFirst = manager.entryState
        #expect(
            stateAfterFirst == .disconnected(reason: .generationChanged)
            || stateAfterFirst == .disconnected(reason: .streamEnded),
            "First generation should disconnect, got \(stateAfterFirst)"
        )

        // Second connect with the new generation
        let secondConnect = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(2))

        // Second stream works normally
        streams.yield(index: 1, message: .connected(session: makeTestSession(id: sessionId)))
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        streams.finish(index: 1)
        await secondConnect.value
    }

    // MARK: - Edge 8: Trace fetch failure falls back gracefully

    /// If the trace fetch fails (network error, 500, etc.), the system
    /// should fall back to whatever state it has (cache or ring catch-up)
    /// rather than showing a blank timeline.
    @MainActor
    @Test func traceFetchFailureFallsBackToCache() async {
        let sessionId = "reentry-fail-\(UUID().uuidString)"
        let workspaceId = "w1"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        // Cache has content
        await TimelineCache.shared.saveTrace(sessionId, events: [
            makeTraceEvent(id: "cached-1", text: "cached content survives"),
        ])

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        // Trace fetch fails
        manager._fetchSessionTraceForTesting = { _, _ in
            throw URLError(.notConnectedToInternet)
        }

        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 5),
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .ready))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: workspaceId)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })
        try? await Task.sleep(for: .milliseconds(200))

        // Timeline should still have cached content (not blank)
        let hasCachedContent = manager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("cached content survives")
            }
            return false
        }
        #expect(hasCachedContent, "Trace fetch failure should preserve cached timeline, not blank it")
        // Note: lastSyncFailed may be overwritten by markSyncSucceeded() from
        // the WS .connected message — the sync state is inherently racy between
        // the trace fetch and WS events. The key assertion is cached content survival.

        streams.finish(index: 0)
        await connectTask.value
        await TimelineCache.shared.removeTrace(sessionId)
    }

    // MARK: - Edge 9: Stopped session re-entry loads trace without WSS

    /// Stopped sessions should load the trace via REST without opening
    /// a WebSocket — the WSS subscribe would auto-resume the pi process.
    @MainActor
    @Test func stoppedSessionReentryLoadsTraceWithoutWSS() async {
        let sessionId = "reentry-stopped-\(UUID().uuidString)"
        let workspaceId = "w1"
        let manager = ChatSessionManager(sessionId: sessionId)

        var streamOpened = false
        manager._streamSessionForTesting = { _ in
            streamOpened = true
            return AsyncStream { $0.finish() }
        }

        manager._fetchSessionTraceForTesting = { _, _ in
            (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .stopped),
                [
                    makeTraceEvent(id: "t1", type: .user, text: "Build this"),
                    makeTraceEvent(id: "t2", text: "Done!"),
                ]
            )
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .stopped))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }
        await connectTask.value

        #expect(!streamOpened, "Stopped session should NOT open WebSocket")
        #expect(manager.entryState == .stopped(historyLoaded: true))

        // Timeline should be populated from trace
        let hasContent = manager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text == "Done!"
            }
            return false
        }
        #expect(hasContent, "Stopped session should populate timeline from trace")
    }

    // MARK: - Edge 10: Busy session re-entry fills gap (not deferred)

    /// Reproduces the first-reentry gap bug: re-entering a busy session with
    /// cache shows stale content + live events, but the gap between cache and
    /// live is never filled because the trace rebuild is deferred.
    ///
    /// The fix: the bypass clears `loadedFromCacheAtConnect` before scheduling
    /// the reload, disabling the deferral condition in `loadHistory()`.
    @MainActor
    @Test func busySessionReentryFillsGapNotDeferred() async {
        let sessionId = "reentry-busy-\(UUID().uuidString)"
        let workspaceId = "w1"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        // Stale cache: only has old content
        await TimelineCache.shared.saveTrace(sessionId, events: [
            makeTraceEvent(id: "cached-old", text: "stale cached content"),
        ])

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        // Trace fetch returns full history including gap content.
        // Session is BUSY — the deferral logic would normally skip this rebuild.
        manager._fetchSessionTraceForTesting = { _, _ in
            (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy),
                [
                    makeTraceEvent(id: "t1", type: .user, text: "Build feature X"),
                    makeTraceEvent(id: "t2", text: "GAP_CONTENT_THAT_WAS_MISSING"),
                    makeTraceEvent(id: "t3", text: "More work done..."),
                ]
            )
        }

        // Subscribe ack: currentSeq = 50 (lots of events happened since cache)
        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 50),
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(
            session: makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy)
        ))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        // Wait for background trace reload to complete
        try? await Task.sleep(for: .milliseconds(300))

        // The gap content MUST appear despite the session being busy.
        // Before the fix, this was deferred and the gap was never filled.
        let hasGapContent = manager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("GAP_CONTENT_THAT_WAS_MISSING")
            }
            return false
        }
        #expect(hasGapContent, "Busy session re-entry must fill gap from trace, not defer rebuild")

        streams.finish(index: 0)
        await connectTask.value
        await TimelineCache.shared.removeTrace(sessionId)
    }

    // MARK: - Helpers

    private func makeTraceEvent(
        id: String,
        type: TraceEventType = .assistant,
        text: String = "test content",
        timestamp: String = "2026-02-11T00:00:00Z"
    ) -> TraceEvent {
        TraceEvent(
            id: id,
            type: type,
            timestamp: timestamp,
            text: text,
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        )
    }
}

// MARK: - HistoryReloadTracker (reused from ChatSessionManagerTests)

private struct HistoryReloadCall: Equatable, Sendable {
    let cachedEventCount: Int?
    let cachedLastEventId: String?
}

private struct HistoryReloadSnapshot: Equatable, Sendable {
    let calls: [HistoryReloadCall]
    let cancellations: Int
    let completions: Int
}

private actor HistoryReloadTracker {
    private var calls: [HistoryReloadCall] = []
    private var cancellations = 0
    private var completions = 0

    func recordCall(cachedEventCount: Int?, cachedLastEventId: String?) -> Int {
        calls.append(.init(cachedEventCount: cachedEventCount, cachedLastEventId: cachedLastEventId))
        return calls.count
    }

    func recordCancellation() {
        cancellations += 1
    }

    func recordCompletion() {
        completions += 1
    }

    func snapshot() -> HistoryReloadSnapshot {
        HistoryReloadSnapshot(calls: calls, cancellations: cancellations, completions: completions)
    }

    func waitForCalls(_ expected: Int, timeoutMs: Int = 1_000) async -> Bool {
        let attempts = max(1, timeoutMs / 20)
        for _ in 0..<attempts {
            if calls.count >= expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
