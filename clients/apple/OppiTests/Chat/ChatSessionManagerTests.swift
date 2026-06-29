import Foundation
import Testing
@testable import Oppi

@Suite("ChatSessionManager")
@MainActor
struct ChatSessionManagerTests {

    private func makeImmediateReleaseScreenAwakeController() -> (
        controller: ScreenAwakeController,
        updates: () -> [Bool]
    ) {
        var captured: [Bool] = []
        let controller = ScreenAwakeController(
            timeoutProvider: { nil },
            idleTimerSetter: { captured.append($0) },
            sleepFunction: { _ in }
        )
        return (controller, { captured })
    }

    @Test func initialState() {
        let manager = ChatSessionManager(sessionId: "test-123")
        #expect(manager.sessionId == "test-123")
        #expect(manager.connectionGeneration == 0)
        #expect(!manager.hasAppeared)
        #expect(manager.entryState == .idle)
        #expect(!manager.needsInitialScroll)
    }

    @Test func firstAppearDoesNotBumpGeneration() {
        let manager = ChatSessionManager(sessionId: "s1")
        #expect(manager.connectionGeneration == 0)
        #expect(!manager.hasAppeared)

        manager.markAppeared()

        #expect(manager.hasAppeared)
        #expect(manager.connectionGeneration == 0, "First appear should not bump generation")
    }

    @Test func subsequentAppearBumpsGeneration() {
        let manager = ChatSessionManager(sessionId: "s1")
        manager.markAppeared()
        #expect(manager.connectionGeneration == 0)

        manager.markAppeared()
        #expect(manager.connectionGeneration == 1, "Second appear should bump generation")

        manager.markAppeared()
        #expect(manager.connectionGeneration == 2, "Third appear should bump again")
    }

    @Test func reconnectBumpsGeneration() {
        let manager = ChatSessionManager(sessionId: "s1")
        #expect(manager.connectionGeneration == 0)

        manager.reconnect()
        #expect(manager.connectionGeneration == 1)

        manager.reconnect()
        #expect(manager.connectionGeneration == 2)
    }

    @Test func forceHistoryReloadUsesTestingHookAndMarksSyncSucceeded() async {
        let manager = ChatSessionManager(sessionId: "force-reload-success")
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        var capturedCachedEventCount: Int?
        var capturedCachedLastEventId: String?
        manager._loadHistoryForTesting = { cachedEventCount, cachedLastEventId in
            capturedCachedEventCount = cachedEventCount
            capturedCachedLastEventId = cachedLastEventId
            return (eventCount: 42, lastEventId: "evt-42")
        }

        let reloaded = await manager.forceHistoryReload(
            connection: connection,
            sessionStore: sessionStore
        )

        #expect(reloaded)
        #expect(capturedCachedEventCount == nil)
        #expect(capturedCachedLastEventId == nil)
        #expect(manager.isSyncing == false)
        #expect(manager.lastSyncFailed == false)
        #expect(manager.lastSuccessfulSyncAt != nil)
    }

    @Test func forceHistoryReloadReturnsFalseWhenTestingHookReturnsNil() async {
        let manager = ChatSessionManager(sessionId: "force-reload-failure")
        manager._loadHistoryForTesting = { _, _ in nil }

        let reloaded = await manager.forceHistoryReload(
            connection: ServerConnection(),
            sessionStore: SessionStore()
        )

        #expect(reloaded == false)
        #expect(manager.isSyncing == false)
        #expect(manager.lastSyncFailed == true)
    }

    @Test func forceHistoryReloadFailsWithoutAPIClientWhenNoTestingHook() async {
        let manager = ChatSessionManager(sessionId: "force-reload-no-api")

        let reloaded = await manager.forceHistoryReload(
            connection: ServerConnection(),
            sessionStore: SessionStore()
        )

        #expect(reloaded == false)
        #expect(manager.isSyncing == false)
        #expect(manager.lastSyncFailed == true)
    }

    @Test func unexpectedConnectedStreamExitSchedulesReconnect() async {
        let sessionId = "auto-reconnect"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
        streams.finish(index: 0)
        await connectTask.value

        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { manager.connectionGeneration == 1 }
        })
        #expect(manager.entryState == .disconnected(reason: .streamEnded))

        manager.cleanup()
    }

    @Test func cancelledStreamExitDoesNotScheduleReconnect() async {
        let manager = ChatSessionManager(sessionId: "cancelled-exit")
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        connectTask.cancel()
        streams.finish(index: 0)
        await connectTask.value

        #expect(manager.connectionGeneration == 0)
        #expect(manager.entryState == .disconnected(reason: .cancelled))

        manager.cleanup()
    }

    @Test func defocusedStreamExitDoesNotScheduleReconnect() async {
        let focusedId = "focused-session"
        let otherId = "other-session"
        let manager = ChatSessionManager(sessionId: focusedId)
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = connection.sessionStore
        sessionStore.upsert(makeTestSession(id: focusedId, workspaceId: "w1", status: .busy))
        sessionStore.upsert(makeTestSession(id: otherId, workspaceId: "w1", status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: focusedId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        connection.focusSession(otherId)
        streams.finish(index: 0)
        await connectTask.value
        try? await Task.sleep(for: .milliseconds(400))

        #expect(manager.connectionGeneration == 0)
        #expect(manager.entryState == .disconnected(reason: .streamEnded))

        manager.cleanup()
        connection.disconnectSession()
    }

    @Test func stoppedSessionDoesNotOpenWebSocket() async {
        let sessionId = "stopped-session"
        let manager = ChatSessionManager(sessionId: sessionId)
        var streamCreated = false
        manager._streamSessionForTesting = { _ in
            streamCreated = true
            return AsyncStream { $0.finish() }
        }
        var historyLoaded = false
        manager._loadHistoryForTesting = { _, _ in
            historyLoaded = true
            return nil
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .stopped))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        await connectTask.value

        // Stopped session should NOT open a WebSocket stream
        #expect(!streamCreated, "Stopped session should not open a WebSocket stream")
        // But should still load history
        #expect(historyLoaded, "Stopped session should still load history")
        #expect(manager.connectionGeneration == 0)
        #expect(manager.entryState == .stopped(historyLoaded: true))

        manager.cleanup()
    }

    /// History reload always runs on entry, even when cache is present.
    /// Cache provides instant display; reload provides ground truth.
    @Test func initialConnectAlwaysSchedulesHistoryReloadWithCache() async {
        let sessionId = "cache-reload-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        var historyReloadCalls = 0
        manager._loadHistoryForTesting = { _, _ in
            historyReloadCalls += 1
            return nil
        }

        await TimelineCache.shared.saveTrace(sessionId, events: [makeTraceEvent(id: "cached-1")])

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        try? await Task.sleep(for: .milliseconds(120))

        if case .awaitingConnected = manager.entryState {
            // good
        } else {
            #expect(Bool(false), "Expected awaitingConnected state")
        }
        #expect(historyReloadCalls >= 1, "History reload must run even with cache present")

        streams.finish(index: 0)
        await connectTask.value
        #expect(manager.entryState == .disconnected(reason: .streamEnded))

        await TimelineCache.shared.removeTrace(sessionId)
    }

    @Test func unchangedStoppedFreshTraceFinalizesOpenToolLoadedFromRunningCache() async {
        let sessionId = "unchanged-stopped-tool-\(UUID().uuidString)"
        let workspaceId = "w1"
        let toolId = "tool-without-result"
        let openToolTrace = [
            TraceEvent(
                id: toolId,
                type: .toolCall,
                timestamp: "2026-02-11T00:00:00Z",
                tool: "read",
                args: ["path": .string("README.md")]
            ),
        ]

        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._fetchSessionTraceForTesting = { _, _ in
            (makeTestSession(id: sessionId, workspaceId: workspaceId, status: .stopped), openToolTrace)
        }

        await TimelineCache.shared.saveTrace(sessionId, events: openToolTrace)

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy)))

        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                guard case .toolCall(let id, _, _, let preview, _, let isError, let isDone) = manager.reducer.items.first else {
                    return false
                }
                return id == toolId && isDone && isError && preview.contains("stopped before returning")
            }
        })

        streams.finish(index: 0)
        await connectTask.value
        await TimelineCache.shared.removeTrace(sessionId)
    }

    /// With per-session reducers, each connect() resets the reducer and
    /// loads from cache. Verify that cache loads correctly on reconnect.
    @Test func reconnectLoadsFromCache() async {
        let sessionId = "reentry-cache-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        // Cache with 2 events (user + assistant).
        await TimelineCache.shared.saveTrace(sessionId, events: [
            makeTraceEvent(id: "u1", type: .user, text: "first message"),
            makeTraceEvent(id: "a1", type: .assistant, text: "first response"),
        ])

        let connection = ServerConnection()
        let sessionStore = SessionStore()
        sessionStore.activeSessionId = sessionId

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        try? await Task.sleep(for: .milliseconds(120))

        // Reducer should have loaded from cache
        #expect(manager.reducer.items.count == 2, "Cache should be loaded on connect")

        streams.finish(index: 0)
        await connectTask.value
        await TimelineCache.shared.removeTrace(sessionId)
    }

    @Test func connectWithoutCacheTransitionsToAwaitingConnectedWithoutCachedHistory() async {
        let sessionId = "state-no-cache-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in
            try? await Task.sleep(for: .milliseconds(250))
            return nil
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                if case .awaitingConnected = manager.entryState {
                    return true
                }
                return false
            }
        })

        streams.finish(index: 0)
        await connectTask.value
        #expect(manager.entryState == .disconnected(reason: .streamEnded))
    }

    @Test func generationChangeDuringStreamingTransitionsToGenerationChanged() async {
        let sessionId = "state-generation-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .ready)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                manager.entryState == .streaming
            }
        })

        manager.reconnect()
        streams.yield(index: 0, message: .state(session: makeTestSession(id: sessionId, status: .busy)))
        streams.finish(index: 0)

        await connectTask.value

        #expect(manager.connectionGeneration == 1)
        #expect(manager.entryState == .disconnected(reason: .generationChanged))
    }

    /// History reload always runs to completion on first connect — it is
    /// never cancelled by catch-up outcomes or state transitions. This is
    /// the fix for blank timelines when entering a READY session without cache.
    @Test func firstConnectAlwaysCompletesHistoryReload() async {
        let sessionId = "first-connect-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let tracker = HistoryReloadTracker()
        manager._loadHistoryForTesting = { cachedCount, cachedLastId in
            _ = await tracker.recordCall(cachedEventCount: cachedCount, cachedLastEventId: cachedLastId)
            return (eventCount: 50, lastEventId: "evt-50")
        }

        // Simulate server at currentSeq=5 — first connect seeds seq directly.
        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 5),
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
        try? await Task.sleep(for: .milliseconds(50))

        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
        try? await Task.sleep(for: .milliseconds(200))

        // History reload must complete regardless of WS/catch-up state.
        let snapshot = await tracker.snapshot()
        #expect(snapshot.calls.count == 1, "History reload must complete on first connect")
        #expect(UserDefaults.standard.integer(forKey: "chat.lastSeenSeq.\(sessionId)") == 5)
        #expect(manager.entryState == .streaming)

        streams.finish(index: 0)
        await connectTask.value
    }

    /// With the persisted lastSeenSeq matching server currentSeq (the exact
    /// scenario that caused blank timelines), history reload still completes.
    @Test func firstConnectNoGapStillCompletesHistoryReload() async {
        let sessionId = "nogap-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let tracker = HistoryReloadTracker()
        manager._loadHistoryForTesting = { cachedCount, cachedLastId in
            _ = await tracker.recordCall(cachedEventCount: cachedCount, cachedLastEventId: cachedLastId)
            return (eventCount: 50, lastEventId: "evt-50")
        }

        // currentSeq == 0, lastSeenSeq == 0 → noGap in old code would cancel reload.
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
        try? await Task.sleep(for: .milliseconds(50))

        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
        try? await Task.sleep(for: .milliseconds(200))

        let snapshot = await tracker.snapshot()
        #expect(snapshot.calls.count == 1, "History reload must complete even with noGap")
        #expect(manager.entryState == .streaming)

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func emptyFreshTraceUsesSessionFirstMessageFallback() async {
        let sessionId = "empty-trace-first-message-\(UUID().uuidString)"
        let workspaceId = "w1"
        let firstMessage = "help me pull couple of data from the workspace"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._fetchSessionTraceForTesting = { _, _ in
            (
                makeTestSession(
                    id: sessionId,
                    workspaceId: workspaceId,
                    status: .busy,
                    messageCount: 1,
                    firstMessage: firstMessage
                ),
                []
            )
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(
            id: sessionId,
            workspaceId: workspaceId,
            status: .busy,
            messageCount: 1,
            firstMessage: firstMessage
        ))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(
            id: sessionId,
            workspaceId: workspaceId,
            status: .busy,
            messageCount: 1,
            firstMessage: firstMessage
        )))

        let showedFirstMessage = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                manager.reducer.items.contains { item in
                    if case .userMessage(_, let text, _, _) = item {
                        return text == firstMessage
                    }
                    return false
                }
            }
        }
        #expect(showedFirstMessage, "Busy sessions with an empty fresh trace should still show the recorded first user message")

        streams.finish(index: 0)
        await connectTask.value
    }

    /// Validates that when catch-up fails on first connect (seq regression),
    /// the scheduled full history reload is NOT cancelled.
    @Test func firstConnectSeqRegressionKeepsHistoryReload() async {
        let sessionId = "regress-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let tracker = HistoryReloadTracker()
        manager._loadHistoryForTesting = { cachedCount, cachedLastId in
            _ = await tracker.recordCall(cachedEventCount: cachedCount, cachedLastEventId: cachedLastId)
            return (eventCount: 10, lastEventId: "evt-10")
        }

        // Persist a lastSeenSeq that is AHEAD of currentSeq to trigger regression.
        UserDefaults.standard.set(100, forKey: "chat.lastSeenSeq.\(sessionId)")

        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 5),
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

        // Wait for the regression-triggered reload to complete.
        #expect(await tracker.waitForCalls(1), "Seq regression should trigger history reload")
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        streams.finish(index: 0)
        await connectTask.value

        // Clean up persisted seq.
        UserDefaults.standard.removeObject(forKey: "chat.lastSeenSeq.\(sessionId)")
    }

    // MARK: - Lifecycle race harness

    @Test func staleGenerationCleanupDoesNotDisconnectNewerReconnectStream() async {
        let manager = ChatSessionManager(sessionId: "s1")
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = SessionStore()

        let firstConnect = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        let firstReady = await streams.waitForCreated(1)
        #expect(firstReady)
        connection._setActiveSessionIdForTesting("s1")

        manager.reconnect()
        #expect(manager.connectionGeneration == 1)

        let secondConnect = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        let secondReady = await streams.waitForCreated(2)
        #expect(secondReady)
        connection._setActiveSessionIdForTesting("s1")

        // Force-drop stale stream #1 while stream #2 is active.
        streams.finish(index: 0)
        await firstConnect.value

        #expect(
            connection.focusedSessionId == "s1",
            "Stale generation cleanup must not disconnect newer stream"
        )

        streams.finish(index: 1)
        await secondConnect.value

        #expect(
            connection.focusedSessionId == nil,
            "Current generation should disconnect on normal loop exit"
        )
    }

    @Test func staleCleanupSkipsDisconnectWhenSocketOwnershipMoved() async {
        let manager = ChatSessionManager(sessionId: "s1")
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        let ready = await streams.waitForCreated(1)
        #expect(ready)

        // Simulate another session taking ownership before stale cleanup runs.
        connection._setActiveSessionIdForTesting("s2")

        streams.finish(index: 0)
        await connectTask.value

        #expect(
            connection.focusedSessionId == "s2",
            "Cleanup must not disconnect socket owned by a different session"
        )
    }

    @Test func reconnectReloadUsesLatestTraceSignature() async {
        let sessionId = "sig-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        let tracker = HistoryReloadTracker()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { cachedEventCount, cachedLastEventId in
            let callIndex = await tracker.recordCall(
                cachedEventCount: cachedEventCount,
                cachedLastEventId: cachedLastEventId
            )

            if callIndex == 1 {
                return (eventCount: 200, lastEventId: "evt-200")
            }
            return (eventCount: 200, lastEventId: "evt-200")
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        #expect(await tracker.waitForCalls(1))

        let session = makeTestSession(id: sessionId)
        streams.yield(index: 0, message: .connected(session: session))
        streams.yield(index: 0, message: .connected(session: session))

        #expect(await tracker.waitForCalls(2))

        streams.finish(index: 0)
        await connectTask.value

        let snapshot = await tracker.snapshot()
        #expect(snapshot.calls.count == 2)
        #expect(snapshot.calls[0].cachedEventCount == nil)
        #expect(snapshot.calls[0].cachedLastEventId == nil)
        #expect(snapshot.calls[1].cachedEventCount == 200)
        #expect(snapshot.calls[1].cachedLastEventId == "evt-200")
    }

    @Test func liveStateReadyRecoveryStopsWatchdogReleasesScreenAwakeAndFinalizesThinking() async {
        let sessionId = "live-state-recovery-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let (screenAwakeController, updates) = makeImmediateReleaseScreenAwakeController()
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        connection.screenAwakeController = screenAwakeController

        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1", status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: "w1", status: .busy)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        streams.yield(index: 0, message: .agentStart)
        streams.yield(index: 0, message: .thinkingDelta(delta: "thinking..."))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                screenAwakeController.isPreventingSleep && connection.silenceWatchdog.lastEventTime != nil
            }
        })

        streams.yield(index: 0, message: .state(session: makeTestSession(id: sessionId, workspaceId: "w1", status: .ready)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                !screenAwakeController.isPreventingSleep && connection.silenceWatchdog.lastEventTime == nil
            }
        })

        manager.coalescer.flushNow()

        let thinkingStates = manager.reducer.items.compactMap { item -> Bool? in
            guard case .thinking(_, _, _, let isDone) = item else { return nil }
            return isDone
        }

        #expect(thinkingStates.count == 1)
        #expect(thinkingStates[0] == true)
        #expect(updates().last == false)

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func reconnectCatchUpStateReadyRecoveryStopsWatchdogReleasesScreenAwakeAndFinalizesThinking() async {
        let sessionId = "catchup-state-recovery-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 0),
            nil,
            nil,
            .init(seq: nil, currentSeq: 2),
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        manager._loadCatchUpForTesting = { _, _ in
            APIClient.SessionEventsResponse(
                events: [
                    .init(seq: 2, message: .state(session: makeTestSession(id: sessionId, workspaceId: "w1", status: .ready))),
                ],
                currentSeq: 2,
                session: makeTestSession(id: sessionId, workspaceId: "w1", status: .ready),
                catchUpComplete: true
            )
        }

        let (screenAwakeController, updates) = makeImmediateReleaseScreenAwakeController()
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        connection.screenAwakeController = screenAwakeController

        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1", status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: "w1", status: .busy)))
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        streams.yield(index: 0, message: .agentStart)
        streams.yield(index: 0, message: .thinkingDelta(delta: "thinking..."))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                screenAwakeController.isPreventingSleep && connection.silenceWatchdog.lastEventTime != nil
            }
        })

        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: "w1", status: .ready)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                !screenAwakeController.isPreventingSleep
                    && connection.silenceWatchdog.lastEventTime == nil
                    && sessionStore.sessions.first(where: { $0.id == sessionId })?.status == .ready
            }
        })

        manager.coalescer.flushNow()

        let thinkingStates = manager.reducer.items.compactMap { item -> Bool? in
            guard case .thinking(_, _, _, let isDone) = item else { return nil }
            return isDone
        }

        #expect(thinkingStates.count == 1)
        #expect(thinkingStates[0] == true)
        #expect(UserDefaults.standard.integer(forKey: "chat.lastSeenSeq.\(sessionId)") == 2)
        #expect(updates().last == false)

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func reconnectWithSequencedCatchUpSkipsFullHistoryReload() async {
        let sessionId = "seq-catchup-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        let tracker = HistoryReloadTracker()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { cachedEventCount, cachedLastEventId in
            _ = await tracker.recordCall(
                cachedEventCount: cachedEventCount,
                cachedLastEventId: cachedLastEventId
            )
            return (eventCount: 100, lastEventId: "evt-100")
        }

        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 0),
            .init(seq: nil, currentSeq: 2),
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        var catchUpCalls = 0
        manager._loadCatchUpForTesting = { _, _ in
            catchUpCalls += 1
            return APIClient.SessionEventsResponse(
                events: [
                    .init(seq: 1, message: .state(session: makeTestSession(id: sessionId, status: .busy))),
                    .init(seq: 2, message: .state(session: makeTestSession(id: sessionId, status: .ready))),
                ],
                currentSeq: 2,
                session: makeTestSession(id: sessionId, status: .ready),
                catchUpComplete: true
            )
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        #expect(await tracker.waitForCalls(1))

        let session = makeTestSession(id: sessionId)
        // First .connected → streaming (seeds seq=0).
        streams.yield(index: 0, message: .connected(session: session))
        try? await Task.sleep(for: .milliseconds(50))
        // Second .connected → reconnection catch-up.
        streams.yield(index: 0, message: .connected(session: session))
        try? await Task.sleep(for: .milliseconds(200))

        let snapshot = await tracker.snapshot()
        #expect(snapshot.calls.count == 1, "Sequenced catch-up should avoid full history reload")
        #expect(catchUpCalls == 1)
        #expect(UserDefaults.standard.integer(forKey: "chat.lastSeenSeq.\(sessionId)") == 2)

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func reconnectReloadCancelsStaleInFlightTasks() async {
        let sessionId = "cancel-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        let tracker = HistoryReloadTracker()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { cachedEventCount, cachedLastEventId in
            let callIndex = await tracker.recordCall(
                cachedEventCount: cachedEventCount,
                cachedLastEventId: cachedLastEventId
            )

            do {
                try await Task.sleep(for: .milliseconds(200))
                await tracker.recordCompletion()
                return (eventCount: callIndex, lastEventId: "evt-\(callIndex)")
            } catch {
                await tracker.recordCancellation()
                return nil
            }
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        #expect(await tracker.waitForCalls(1))

        let session = makeTestSession(id: sessionId)
        streams.yield(index: 0, message: .connected(session: session))
        streams.yield(index: 0, message: .connected(session: session))
        try? await Task.sleep(for: .milliseconds(20))
        streams.yield(index: 0, message: .connected(session: session))

        #expect(await tracker.waitForCalls(3))

        try? await Task.sleep(for: .milliseconds(260))

        let snapshot = await tracker.snapshot()
        #expect(snapshot.cancellations >= 2)
        #expect(snapshot.completions == 1)

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func stateSyncRequestedOnConnectedMessagesOnly() async {
        let sessionId = "state-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        let counter = StateSyncCounter()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        connection._sendMessageForTesting = { message in
            await counter.record(message: message)
        }

        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await counter.count() == 0)

        let session = makeTestSession(id: sessionId)
        streams.yield(index: 0, message: .connected(session: session))
        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 1 })

        streams.yield(index: 0, message: .connected(session: session))
        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 2 })

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func busyHistoryReloadAppliesTraceAndPreservesLiveRows() async {
        let sessionId = "busy-reload-\(UUID().uuidString)"
        let workspaceId = "w-live"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        // Seed cache so replay buffering activates — the buffer captures live
        // events while the trace fetch is in flight, then replays them on top
        // of the freshly loaded trace.
        await TimelineCache.shared.saveTrace(sessionId, events: [
            makeTraceEvent(
                id: "cached-old",
                text: "cached content",
                timestamp: "2026-02-10T00:00:00Z"
            ),
        ])

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._fetchSessionTraceForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            return (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy),
                [
                    makeTraceEvent(id: "trace-assistant", text: "TRACE_RELOAD_MARKER"),
                ]
            )
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
        streams.yield(index: 0, message: .agentStart)
        streams.yield(index: 0, message: .thinkingDelta(delta: "live thinking"))
        streams.yield(index: 0, message: .toolStart(tool: "read", args: [:], toolCallId: "tc-live", callSegments: nil))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                manager.reducer.items.contains { item in
                    if case .toolCall(let id, _, _, _, _, _, _) = item {
                        return id == "tc-live"
                    }
                    return false
                }
            }
        })

        // Wait for trace fetch + replay to complete.
        try? await Task.sleep(for: .milliseconds(220))

        // Live tool call preserved via replay buffer
        #expect(manager.reducer.items.contains { item in
            if case .toolCall(let id, _, _, _, _, _, _) = item {
                return id == "tc-live"
            }
            return false
        })

        // Trace content now appears (was previously deferred)
        #expect(manager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("TRACE_RELOAD_MARKER")
            }
            return false
        })

        streams.finish(index: 0)
        await connectTask.value
        await TimelineCache.shared.removeTrace(sessionId)
    }

    @Test func busyHistoryReloadWithoutCachePreservesLiveRows() async {
        let sessionId = "busy-reload-no-cache-\(UUID().uuidString)"
        let workspaceId = "w-live"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._fetchSessionTraceForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            return (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy),
                [
                    makeTraceEvent(id: "trace-assistant", text: "HISTORY_WITHOUT_CACHE"),
                ]
            )
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
        streams.yield(index: 0, message: .agentStart)
        streams.yield(index: 0, message: .textDelta(delta: "LIVE_WITHOUT_CACHE"))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                manager.reducer.items.contains { item in
                    if case .assistantMessage(_, let text, _) = item {
                        return text.contains("LIVE_WITHOUT_CACHE")
                    }
                    return false
                }
            }
        })

        try? await Task.sleep(for: .milliseconds(220))

        #expect(manager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("HISTORY_WITHOUT_CACHE")
            }
            return false
        })
        #expect(manager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("LIVE_WITHOUT_CACHE")
            }
            return false
        })

        streams.finish(index: 0)
        await connectTask.value
        await TimelineCache.shared.removeTrace(sessionId)
    }


    @Test func reconnectCatchUpReplaysStopConfirmedDeterministically() async {
        let sessionId = "catch-stop-ok-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        // First .connected seeds seq=0, second triggers reconnect catch-up.
        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 0),
            .init(seq: nil, currentSeq: 2),
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        var catchUpCalls = 0
        manager._loadCatchUpForTesting = { _, _ in
            catchUpCalls += 1
            return APIClient.SessionEventsResponse(
                events: [
                    .init(seq: 1, message: .stopRequested(source: .user, reason: "Stopping current turn")),
                    .init(seq: 2, message: .stopConfirmed(source: .user, reason: nil)),
                ],
                currentSeq: 2,
                session: makeTestSession(id: sessionId, status: .ready),
                catchUpComplete: true
            )
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        // First .connected → transitions to streaming (no catch-up).
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .busy)))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(manager.entryState == .streaming)

        // Second .connected → reconnection, triggers catch-up.
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .ready)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                sessionStore.sessions.first(where: { $0.id == sessionId })?.status == .ready
            }
        })

        #expect(catchUpCalls == 1)
        #expect(UserDefaults.standard.integer(forKey: "chat.lastSeenSeq.\(sessionId)") == 2)

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func reconnectCatchUpStopFailedLeavesNoStuckStoppingState() async {
        let sessionId = "catch-stop-fail-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        // First .connected seeds seq=0, second triggers reconnect catch-up.
        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 0),
            .init(seq: nil, currentSeq: 2),
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        var catchUpCalls = 0
        manager._loadCatchUpForTesting = { _, _ in
            catchUpCalls += 1
            return APIClient.SessionEventsResponse(
                events: [
                    .init(seq: 1, message: .stopRequested(source: .user, reason: "Stopping current turn")),
                    .init(seq: 2, message: .stopFailed(source: .timeout, reason: "Stop timed out after 8000ms")),
                ],
                currentSeq: 2,
                session: makeTestSession(id: sessionId, status: .busy),
                catchUpComplete: true
            )
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .stopping))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        // First .connected → streaming.
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .stopping)))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(manager.entryState == .streaming)

        // Second .connected → reconnection catch-up with stop_failed.
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .busy)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                sessionStore.sessions.first(where: { $0.id == sessionId })?.status == .busy
            }
        })

        #expect(!sessionStore.sessions.contains(where: { $0.id == sessionId && $0.status == .stopping }))
        #expect(catchUpCalls == 1)
        #expect(UserDefaults.standard.integer(forKey: "chat.lastSeenSeq.\(sessionId)") == 2)

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func reconnectCatchUpRingMissForcesFullHistoryReload() async {
        let sessionId = "catch-gap-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        let tracker = HistoryReloadTracker()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { cachedEventCount, cachedLastEventId in
            _ = await tracker.recordCall(
                cachedEventCount: cachedEventCount,
                cachedLastEventId: cachedLastEventId
            )
            return (eventCount: 3, lastEventId: "evt-3")
        }

        // First .connected seeds seq=0, second triggers reconnect with ring miss.
        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 0),
            .init(seq: nil, currentSeq: 5),
        ]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        manager._loadCatchUpForTesting = { _, _ in
            APIClient.SessionEventsResponse(
                events: [],
                currentSeq: 5,
                session: makeTestSession(id: sessionId, status: .busy),
                catchUpComplete: false
            )
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        // Wait for initial history reload (always runs on entry).
        #expect(await tracker.waitForCalls(1))

        // First .connected → streaming.
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .busy)))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(manager.entryState == .streaming)

        // Second .connected → reconnection, ring miss → forces new history reload.
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .busy)))

        #expect(await tracker.waitForCalls(2))
        let snapshot = await tracker.snapshot()
        #expect(snapshot.calls.count >= 2)
        #expect(snapshot.calls[1].cachedEventCount == nil)
        #expect(snapshot.calls[1].cachedLastEventId == nil)
        #expect(UserDefaults.standard.integer(forKey: "chat.lastSeenSeq.\(sessionId)") == 5)

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func duplicateSeqEventsAreDroppedAfterReconnect() async {
        let sessionId = "seq-dedupe-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: nil),
            .init(seq: 5, currentSeq: nil),
            .init(seq: 5, currentSeq: nil),
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
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .ready)))
        streams.yield(index: 0, message: .state(session: makeTestSession(id: sessionId, status: .busy)))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                connection.sessionStore.sessions.first(where: { $0.id == sessionId })?.status == .busy
            }
        })

        streams.yield(index: 0, message: .state(session: makeTestSession(id: sessionId, status: .ready)))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(connection.sessionStore.sessions.first(where: { $0.id == sessionId })?.status == .busy)
        #expect(UserDefaults.standard.integer(forKey: "chat.lastSeenSeq.\(sessionId)") == 5)

        streams.finish(index: 0)
        await connectTask.value
    }

    /// Reproduces blank-timeline bug after fresh install.
    ///
    /// Scenario: no cache, session is busy, live stream populates a few reducer
    /// items before the history trace fetch completes. The old code deferred the
    /// trace rebuild because `session.status == .busy && !manager.reducer.items.isEmpty`,
    /// leaving only the last streamed message visible.
    ///
    /// Fix: only defer when the reducer was previously loaded from cache — live
    /// stream items alone are not a valid reason to skip history.
    @Test func noCacheBusySessionAppliesHistoryDespiteLiveStreamItems() async {
        let sessionId = "no-cache-busy-\(UUID().uuidString)"
        let workspaceId = "w-fresh"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        // Trace fetch returns busy session with full history.
        // Add a small delay so live stream items arrive first.
        manager._fetchSessionTraceForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy),
                [
                    makeTraceEvent(
                        id: "trace-user-1",
                        type: .user,
                        text: "HISTORY_USER_MSG"
                    ),
                    makeTraceEvent(
                        id: "trace-assistant-1",
                        text: "HISTORY_ASSISTANT_MSG",
                        timestamp: "2026-02-11T00:00:01Z"
                    ),
                ]
            )
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy))

        // No cache → scheduleHistoryReload fires before WS
        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        // Deliver .connected then live stream events (before trace fetch completes)
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy)))
        streams.yield(index: 0, message: .agentStart)
        streams.yield(index: 0, message: .thinkingDelta(delta: "live thinking"))

        // Wait for reducer to have live items
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { !manager.reducer.items.isEmpty }
        })

        // Wait for history trace fetch to complete (150ms delay + margin)
        try? await Task.sleep(for: .milliseconds(300))

        // History MUST be applied despite busy status + non-empty reducer,
        // because there was no cache — only live stream items.
        let hasHistoryContent = manager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("HISTORY_ASSISTANT_MSG")
            }
            return false
        }
        #expect(hasHistoryContent, "Fresh install with busy session must apply history trace, not defer it")

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func cleanupIsSafe() {
        let manager = ChatSessionManager(sessionId: "s1")
        manager.cleanup()
        manager.cleanup() // idempotent
    }

    @Test func cancelReconciliationIsSafe() {
        let manager = ChatSessionManager(sessionId: "s1")
        manager.cancelReconciliation()
        manager.cancelReconciliation() // idempotent
    }

    @Test func flushSnapshotPersistsTraceWhenAvailable() async {
        let manager = ChatSessionManager(sessionId: "flush-\(UUID().uuidString)")

        var fetchCalls = 0
        var saved: [[TraceEvent]] = []
        let trace = [makeTraceEvent(id: "evt-1"), makeTraceEvent(id: "evt-2")]

        manager._fetchTraceSnapshotForTesting = {
            fetchCalls += 1
            return trace
        }
        manager._saveTraceSnapshotForTesting = { events in
            saved.append(events)
        }

        await manager.flushSnapshotIfNeeded(connection: ServerConnection(), force: true)

        #expect(fetchCalls == 1)
        #expect(saved.count == 1)
        #expect(saved.first?.count == 2)
    }

    @Test func flushSnapshotDebouncesBackToBackCalls() async {
        let manager = ChatSessionManager(sessionId: "flush-\(UUID().uuidString)")

        var fetchCalls = 0
        var saveCalls = 0
        let trace = [makeTraceEvent(id: "evt-1")]

        manager._fetchTraceSnapshotForTesting = {
            fetchCalls += 1
            return trace
        }
        manager._saveTraceSnapshotForTesting = { _ in
            saveCalls += 1
        }

        await manager.flushSnapshotIfNeeded(connection: ServerConnection())
        await manager.flushSnapshotIfNeeded(connection: ServerConnection())

        #expect(fetchCalls == 1)
        #expect(saveCalls == 1)
    }

    @Test func flushSnapshotForceBypassesDebounceWindow() async {
        let manager = ChatSessionManager(sessionId: "flush-\(UUID().uuidString)")

        var fetchCalls = 0
        var saveCalls = 0
        let trace = [makeTraceEvent(id: "evt-1")]

        manager._fetchTraceSnapshotForTesting = {
            fetchCalls += 1
            return trace
        }
        manager._saveTraceSnapshotForTesting = { _ in
            saveCalls += 1
        }

        await manager.flushSnapshotIfNeeded(connection: ServerConnection())
        await manager.flushSnapshotIfNeeded(connection: ServerConnection(), force: true)

        #expect(fetchCalls == 2)
        #expect(saveCalls == 2)
    }

    @Test func flushSnapshotSkipsSaveWhenTraceMissing() async {
        let manager = ChatSessionManager(sessionId: "flush-\(UUID().uuidString)")

        var saveCalls = 0
        manager._fetchTraceSnapshotForTesting = {
            nil
        }
        manager._saveTraceSnapshotForTesting = { _ in
            saveCalls += 1
        }

        await manager.flushSnapshotIfNeeded(connection: ServerConnection(), force: true)

        #expect(saveCalls == 0)
    }

    // MARK: - Helpers

    private func makeTraceEvent(
        id: String,
        type: TraceEventType = .assistant,
        text: String = "offline snapshot",
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

    // MARK: - WSS Connect Dispatch Lag

    /// Reproduces the ~8s `session_loop_dispatch` lag observed in production.
    ///
    /// Root cause: `streamSession()` used to block on connection setup + queue sync
    /// while `.connected` sat buffered in the per-session AsyncStream. The session
    /// loop in `ChatSessionManager.connect()` can't consume until `streamSession()`
    /// returns.
    ///
    /// This test verifies that `.connected` is processed promptly after the stream
    /// starts, rather than being delayed by upstream blocking.
    @Test func connectedMessageIsProcessedWithoutExcessiveDispatchLag() async {
        let sessionId = "dispatch-lag-test"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let sessionStore = SessionStore()

        let connectStartMs = Date.nowMs()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        // Wait for stream to be created
        #expect(await streams.waitForCreated(1))

        // Yield .connected with inbound meta (simulating WS receive)
        let connectedYieldMs = Date.nowMs()
        manager._consumeInboundMetaForTesting = {
            WebSocketClient.InboundMeta(seq: nil, currentSeq: 0, receivedAtMs: connectedYieldMs)
        }
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))

        // Wait for streaming state
        let reachedStreaming = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        }
        let streamingReachedMs = Date.nowMs()
        let dispatchLagMs = streamingReachedMs - connectedYieldMs
        let totalMs = streamingReachedMs - connectStartMs

        #expect(reachedStreaming, "Should reach .streaming state")

        // The dispatch lag from connected-yield to streaming-state should be well under 1s.
        // With test seams (no real WS), it should be near-instant.
        #expect(dispatchLagMs < 500, "Dispatch lag was \(dispatchLagMs)ms — connected message should be processed promptly")
        #expect(totalMs < 2_000, "Total connect time was \(totalMs)ms — should be fast with scripted stream")

        streams.finish(index: 0)
        await connectTask.value
        manager.cleanup()
    }

    // MARK: - Meta race regression: nil currentSeq preserves history reload

    /// Regression test for the blank timeline bug.
    ///
    /// When the stream metadata race drops `currentSeq`, catch-up is skipped.
    /// The safety net is that the pending
    /// history reload stays alive. This test ensures that safety net holds:
    /// nil `currentSeq` → history reload preserved → timeline populated.
    @Test func nilCurrentSeqPreservesHistoryReloadAsSafetyNet() async {
        let sessionId = "meta-race-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let tracker = HistoryReloadTracker()
        manager._loadHistoryForTesting = { cachedCount, cachedLastId in
            _ = await tracker.recordCall(cachedEventCount: cachedCount, cachedLastEventId: cachedLastId)
            return (eventCount: 20, lastEventId: "evt-20")
        }

        // Simulate the old race: inboundMeta has nil currentSeq.
        manager._consumeInboundMetaForTesting = {
            WebSocketClient.InboundMeta(seq: nil, currentSeq: nil)
        }

        // Catch-up should NOT be called — verify via absence of call.
        var catchUpCalled = false
        manager._loadCatchUpForTesting = { _, _ in
            catchUpCalled = true
            return APIClient.SessionEventsResponse(
                events: [],
                currentSeq: 0,
                session: makeTestSession(id: sessionId),
                catchUpComplete: true
            )
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        // Deliver .connected with nil currentSeq (the race scenario).
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .ready)))

        // History reload should complete (not be cancelled).
        #expect(await tracker.waitForCalls(1), "Nil currentSeq must preserve history reload as safety net")
        #expect(!catchUpCalled, "Catch-up should not run when currentSeq is nil")
        let reachedStreaming = await waitForMainActorCondition {
            manager.entryState == .streaming
        }
        #expect(reachedStreaming, "Connected stream should enter streaming after the history reload safety net completes")

        streams.finish(index: 0)
        await connectTask.value
    }

    /// Complement of the nil-meta test: when `currentSeq` is available (the
    /// fix working), catch-up runs and the slow history reload is cancelled.
    /// This validates that the pre-track fix provides the fast path.
    /// First connect seeds seq from the server's currentSeq. History reload
    /// runs independently and is never cancelled by the seq seeding.
    @Test func availableCurrentSeqSeedsSeqAndHistoryReloadCompletes() async {
        let sessionId = "meta-fixed-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let tracker = HistoryReloadTracker()
        manager._loadHistoryForTesting = { cachedCount, cachedLastId in
            _ = await tracker.recordCall(cachedEventCount: cachedCount, cachedLastEventId: cachedLastId)
            return (eventCount: 20, lastEventId: "evt-20")
        }

        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 10),
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
        try? await Task.sleep(for: .milliseconds(50))

        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
        try? await Task.sleep(for: .milliseconds(200))

        let snapshot = await tracker.snapshot()
        #expect(snapshot.calls.count == 1, "History reload must complete on first connect")
        #expect(UserDefaults.standard.integer(forKey: "chat.lastSeenSeq.\(sessionId)") == 10)
        #expect(manager.entryState == .streaming)

        streams.finish(index: 0)
        await connectTask.value
    }
}

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

private actor StateSyncCounter {
    private var value = 0

    func record(message: ClientMessage) {
        if case .getState = message {
            value += 1
        }
    }

    func count() -> Int {
        value
    }
}
