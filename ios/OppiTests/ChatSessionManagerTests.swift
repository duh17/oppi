import Foundation
import Testing
@testable import Oppi

@Suite("ChatSessionManager")
struct ChatSessionManagerTests {

    @MainActor
    @Test func initialState() {
        let manager = ChatSessionManager(sessionId: "test-123")
        #expect(manager.sessionId == "test-123")
        #expect(manager.connectionGeneration == 0)
        #expect(!manager.hasAppeared)
        #expect(!manager.needsInitialScroll)
    }

    @MainActor
    @Test func firstAppearDoesNotBumpGeneration() {
        let manager = ChatSessionManager(sessionId: "s1")
        #expect(manager.connectionGeneration == 0)
        #expect(!manager.hasAppeared)

        manager.markAppeared()

        #expect(manager.hasAppeared)
        #expect(manager.connectionGeneration == 0, "First appear should not bump generation")
    }

    @MainActor
    @Test func subsequentAppearBumpsGeneration() {
        let manager = ChatSessionManager(sessionId: "s1")
        manager.markAppeared()
        #expect(manager.connectionGeneration == 0)

        manager.markAppeared()
        #expect(manager.connectionGeneration == 1, "Second appear should bump generation")

        manager.markAppeared()
        #expect(manager.connectionGeneration == 2, "Third appear should bump again")
    }

    @MainActor
    @Test func reconnectBumpsGeneration() {
        let manager = ChatSessionManager(sessionId: "s1")
        #expect(manager.connectionGeneration == 0)

        manager.reconnect()
        #expect(manager.connectionGeneration == 1)

        manager.reconnect()
        #expect(manager.connectionGeneration == 2)
    }

    @MainActor
    @Test func unexpectedConnectedStreamExitSchedulesReconnect() async {
        let sessionId = "auto-reconnect"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
        streams.finish(index: 0)
        await connectTask.value

        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { manager.connectionGeneration == 1 }
        })

        manager.cleanup()
    }

    @MainActor
    @Test func cancelledStreamExitDoesNotScheduleReconnect() async {
        let manager = ChatSessionManager(sessionId: "cancelled-exit")
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        connectTask.cancel()
        streams.finish(index: 0)
        await connectTask.value

        #expect(manager.connectionGeneration == 0)

        manager.cleanup()
    }

    @MainActor
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

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .stopped))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        await connectTask.value

        // Stopped session should NOT open a WebSocket stream
        #expect(!streamCreated, "Stopped session should not open a WebSocket stream")
        // But should still load history
        #expect(historyLoaded, "Stopped session should still load history")
        #expect(manager.connectionGeneration == 0)

        manager.cleanup()
    }

    // MARK: - Lifecycle race harness

    @MainActor
    @Test func staleGenerationCleanupDoesNotDisconnectNewerReconnectStream() async {
        let manager = ChatSessionManager(sessionId: "s1")
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let firstConnect = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        let firstReady = await streams.waitForCreated(1)
        #expect(firstReady)
        connection._setActiveSessionIdForTesting("s1")

        manager.reconnect()
        #expect(manager.connectionGeneration == 1)

        let secondConnect = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        let secondReady = await streams.waitForCreated(2)
        #expect(secondReady)
        connection._setActiveSessionIdForTesting("s1")

        // Force-drop stale stream #1 while stream #2 is active.
        streams.finish(index: 0)
        await firstConnect.value

        #expect(
            connection.activeSessionId == "s1",
            "Stale generation cleanup must not disconnect newer stream"
        )

        streams.finish(index: 1)
        await secondConnect.value

        #expect(
            connection.activeSessionId == nil,
            "Current generation should disconnect on normal loop exit"
        )
    }

    @MainActor
    @Test func staleCleanupSkipsDisconnectWhenSocketOwnershipMoved() async {
        let manager = ChatSessionManager(sessionId: "s1")
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        let ready = await streams.waitForCreated(1)
        #expect(ready)

        // Simulate another session taking ownership before stale cleanup runs.
        connection._setActiveSessionIdForTesting("s2")

        streams.finish(index: 0)
        await connectTask.value

        #expect(
            connection.activeSessionId == "s2",
            "Cleanup must not disconnect socket owned by a different session"
        )
    }

    @MainActor
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
        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
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

    @MainActor
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
        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        #expect(await tracker.waitForCalls(1))

        let session = makeTestSession(id: sessionId)
        streams.yield(index: 0, message: .connected(session: session))
        streams.yield(index: 0, message: .connected(session: session))
        try? await Task.sleep(for: .milliseconds(80))

        let snapshot = await tracker.snapshot()
        #expect(snapshot.calls.count == 1, "Sequenced catch-up should avoid full history reload")
        #expect(catchUpCalls == 1)
        #expect(UserDefaults.standard.integer(forKey: "chat.lastSeenSeq.\(sessionId)") == 2)

        streams.finish(index: 0)
        await connectTask.value
    }

    @MainActor
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
        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
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

    @MainActor
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

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
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

    @MainActor
    @Test func busyHistoryReloadDoesNotClobberLiveStreamingRows() async {
        let sessionId = "busy-reload-\(UUID().uuidString)"
        let workspaceId = "w-live"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._fetchSessionTraceForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            return (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy),
                [
                    TraceEvent(
                        id: "trace-assistant",
                        type: .assistant,
                        timestamp: "2026-02-11T00:00:00Z",
                        text: "TRACE_RELOAD_MARKER",
                        tool: nil,
                        args: nil,
                        output: nil,
                        toolCallId: nil,
                        toolName: nil,
                        isError: nil,
                        thinking: nil
                    ),
                ]
            )
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())

        let reducer = connection.reducer
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy)))
        streams.yield(index: 0, message: .agentStart)
        streams.yield(index: 0, message: .thinkingDelta(delta: "live thinking"))
        streams.yield(index: 0, message: .toolStart(tool: "read", args: [:], toolCallId: "tc-live", callSegments: nil))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                reducer.items.contains { item in
                    if case .toolCall(let id, _, _, _, _, _, _) = item {
                        return id == "tc-live"
                    }
                    return false
                }
            }
        })

        // Wait for deferred history reload attempt to complete.
        try? await Task.sleep(for: .milliseconds(220))

        #expect(reducer.items.contains { item in
            if case .toolCall(let id, _, _, _, _, _, _) = item {
                return id == "tc-live"
            }
            return false
        })

        #expect(!reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("TRACE_RELOAD_MARKER")
            }
            return false
        })

        streams.finish(index: 0)
        await connectTask.value
    }

    @MainActor
    @Test func reconnectCatchUpReplaysStopConfirmedDeterministically() async {
        let sessionId = "catch-stop-ok-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
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
        let reducer = TimelineReducer()
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
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

    @MainActor
    @Test func reconnectCatchUpStopFailedLeavesNoStuckStoppingState() async {
        let sessionId = "catch-stop-fail-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
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
        let reducer = TimelineReducer()
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .stopping))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
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

    @MainActor
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

        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [
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
        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        #expect(await tracker.waitForCalls(1))

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

    @MainActor
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
        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
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

    @MainActor
    @Test func cleanupIsSafe() {
        let manager = ChatSessionManager(sessionId: "s1")
        manager.cleanup()
        manager.cleanup() // idempotent
    }

    @MainActor
    @Test func cancelReconciliationIsSafe() {
        let manager = ChatSessionManager(sessionId: "s1")
        manager.cancelReconciliation()
        manager.cancelReconciliation() // idempotent
    }

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    private func makeTraceEvent(id: String) -> TraceEvent {
        TraceEvent(
            id: id,
            type: .assistant,
            timestamp: "2026-02-11T00:00:00Z",
            text: "offline snapshot",
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
