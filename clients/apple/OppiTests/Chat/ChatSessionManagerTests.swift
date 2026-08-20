import Foundation
import Testing
@testable import Oppi

@Suite("ChatSessionManager", .serialized)
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

    private func makeURLProtocolAPIClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
            configuration: config
        )
    }

    private func mockAPIResponse(status: Int = 200, json: String) -> (Data, HTTPURLResponse) {
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://localhost:7749")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    @Test func staleTracePageFallsBackToFullSessionTrace() {
        #expect(
            ChatSessionManager.shouldFallbackToFullTrace(
                APIError.server(status: 409, message: "Session trace is not synchronized")
            )
        )
        #expect(
            ChatSessionManager.shouldFallbackToFullTrace(
                APIError.server(status: 404, message: "not found")
            )
        )
        #expect(
            !ChatSessionManager.shouldFallbackToFullTrace(
                APIError.server(status: 500, message: "boom")
            )
        )
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

    @Test func connectSchedulesHistoryReloadWhenSessionStreamUnavailable() async {
        let sessionId = "history-fallback-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId, workspaceIdHint: "w1")
        var loadCalls = 0
        manager._loadHistoryForTesting = { _, _ in
            loadCalls += 1
            return (eventCount: 4, lastEventId: "evt-4")
        }

        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: false)
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1"))

        await manager.connect(connection: connection, sessionStore: sessionStore)

        let loaded = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { loadCalls == 1 && manager.lastSuccessfulSyncAt != nil }
        }
        #expect(loaded, "History reload should still run when the session stream cannot open")
        if case .disconnected(let reason) = manager.entryState {
            #expect(reason == .fatalError)
        } else {
            Issue.record("Expected disconnected fatalError, got \(manager.entryState)")
        }
        manager.cleanup()
    }

    @Test func connectRetriesTemporaryStreamSetupWithoutErrorThenBinds() async {
        let sessionId = "stream-retry-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId, workspaceIdHint: "w1")
        manager._loadHistoryForTesting = { _, _ in
            (eventCount: 2, lastEventId: "evt-2")
        }

        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.setAPIClientForTesting(nil)
        connection._focusedStreamReadinessPollForTesting = .milliseconds(5)
        connection.wsClient?._setStatusForTesting(.disconnected)
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1"))

        var startedWait = false
        connection._onFocusedStreamReadinessWaitForTesting = {
            startedWait = true
        }
        let frames = ScriptedFrameStreamFactory()
        connection._connectStreamForTesting = {
            connection.wsClient?._setStatusForTesting(.connected)
            return frames.makeStream()
        }

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }
        defer {
            connectTask.cancel()
            manager.cleanup()
            connection.disconnectSession()
        }

        #expect(await waitForMainActorCondition {
            startedWait && connection.isFocusedSessionStreamRecovering
        })
        #expect(manager.entryState != .disconnected(reason: .fatalError))
        #expect(!manager.reducer.items.contains { item in
            if case .error(_, let message) = item {
                return message.contains("Session stream unavailable")
            }
            return false
        })

        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        let bound = await waitForMainActorCondition(timeout: .seconds(2)) {
            if case .awaitingConnected = manager.entryState { return true }
            return manager.entryState == .streaming
        }
        #expect(bound, "The same connect task should bind once the focused stream is ready")
        #expect(await frames.waitForCreated(1, timeoutMs: 1_000))
        #expect(!connection.isFocusedSessionStreamRecovering)
        #expect(!manager.reducer.items.contains { item in
            if case .error = item { return true }
            return false
        })

        frames.finish(index: 0)
        connectTask.cancel()
        _ = await connectTask.value
    }

    @Test func connectMissingRouteStaysTerminalWithoutRetry() async {
        let sessionId = "missing-route-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        manager._loadHistoryForTesting = { _, _ in
            (eventCount: 1, lastEventId: "evt-1")
        }

        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: nil))

        await manager.connect(connection: connection, sessionStore: sessionStore)

        if case .disconnected(let reason) = manager.entryState {
            #expect(reason == .fatalError)
        } else {
            Issue.record("Expected disconnected fatalError, got \(manager.entryState)")
        }
        #expect(manager.reducer.items.contains { item in
            if case .error(_, let message) = item {
                return message.contains("Missing session route context")
            }
            return false
        })
        manager.cleanup()
    }

    @Test func connectTemporaryStreamSetupExhaustionDoesNotEmitFatalError() async {
        let sessionId = "stream-exhaust-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId, workspaceIdHint: "w1")
        manager._loadHistoryForTesting = { _, _ in
            (eventCount: 2, lastEventId: "evt-2")
        }
        manager._focusedStreamSetupRetryDelayForTesting = .zero

        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.setAPIClientForTesting(nil)
        connection._focusedStreamReadinessPollForTesting = .milliseconds(1)
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1"))

        await manager.connect(connection: connection, sessionStore: sessionStore)

        if case .disconnected(let reason) = manager.entryState {
            #expect(reason != .fatalError)
        } else {
            Issue.record("Expected disconnected after temporary exhaustion, got \(manager.entryState)")
        }
        #expect(!manager.reducer.items.contains { item in
            if case .error(_, let message) = item {
                return message.contains("Session stream unavailable")
            }
            return false
        })
        #expect(connection.isFocusedSessionStreamRecovering)
        #expect(await waitForMainActorCondition {
            manager.connectionGeneration >= 1
        })
        manager.cleanup()
        connection.disconnectSession()
    }

    @Test func connectExternalOpenClaimDoesNotEmitFatalError() async {
        let sessionId = "claim-blocked-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId, workspaceIdHint: "w1")
        manager._loadHistoryForTesting = { _, _ in
            (eventCount: 1, lastEventId: "evt-1")
        }

        let (connection, _) = makeTestConnection(sessionId: sessionId)
        // Avoid a real localhost:7749 probe; availability teardown would drop
        // the claim before connect() can observe it.
        connection.setAPIClientForTesting(nil)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection._connectStreamForTesting = { AsyncStream { $0.finish() } }
        await connection.prepareExternalSessionOpen(sessionId: "other-\(UUID().uuidString)")
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1"))

        await manager.connect(connection: connection, sessionStore: sessionStore)

        if case .disconnected(let reason) = manager.entryState {
            #expect(reason == .cancelled)
        } else {
            Issue.record("Expected cancelled while another session holds the open claim, got \(manager.entryState)")
        }
        #expect(!manager.reducer.items.contains { item in
            if case .error(_, let message) = item {
                return message.contains("Session stream unavailable")
            }
            return false
        })
        manager.cleanup()
        connection.disconnectSession()
    }

    @Test func forceHistoryReloadTreatsEmptyTreeTraceAsAuthoritative() async {
        let sessionId = "force-reload-empty-tree"
        let firstMessage = "Root prompt restored to the composer"
        let manager = ChatSessionManager(sessionId: sessionId)
        manager.reducer.appendUserMessage("stale abandoned branch")
        manager._fetchSessionTraceForTesting = { _, _ in
            (
                makeTestSession(
                    id: sessionId,
                    workspaceId: "w1",
                    status: .ready,
                    messageCount: 1,
                    firstMessage: firstMessage
                ),
                []
            )
        }

        let connection = ServerConnection()
        connection.setAPIClientForTesting(makeURLProtocolAPIClient())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(
            id: sessionId,
            workspaceId: "w1",
            status: .ready,
            messageCount: 1,
            firstMessage: firstMessage
        ))

        let reloaded = await manager.forceHistoryReload(
            connection: connection,
            sessionStore: sessionStore
        )

        #expect(reloaded)
        #expect(manager.reducer.items.isEmpty)
    }

    @Test func forceHistoryReloadFallsBackToFullTraceWhenTracePageRouteIsMissing() async {
        defer { TestURLProtocol.handler = nil }

        let sessionId = "trace-page-fallback"
        let manager = ChatSessionManager(sessionId: sessionId)
        let connection = ServerConnection()
        connection.setAPIClientForTesting(makeURLProtocolAPIClient())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1"))

        TestURLProtocol.handler = { request in
            if request.url?.path == "/workspaces/w1/sessions/\(sessionId)/trace-page" {
                return mockAPIResponse(status: 404, json: #"{"error":"Not found"}"#)
            }

            #expect(request.url?.path == "/workspaces/w1/sessions/\(sessionId)")
            #expect(request.url?.query == "view=full")
            return mockAPIResponse(json: """
            {
                "session":{"id":"\(sessionId)","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":2,"tokens":{"input":10,"output":5},"cost":0},
                "trace":[
                    {"id":"u1","type":"user","timestamp":"2025-01-01T00:00:00Z","text":"Old server"},
                    {"id":"a1","type":"assistant","timestamp":"2025-01-01T00:00:01Z","text":"Full trace"}
                ]
            }
            """)
        }

        let reloaded = await manager.forceHistoryReload(
            connection: connection,
            sessionStore: sessionStore
        )

        #expect(reloaded)
        #expect(manager.tracePage == nil)
        #expect(manager.reducer.items.map(\.id) == ["u1", "a1"])
        #expect(manager.lastSyncFailed == false)
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

    @Test func staleSessionConnectYieldsToExternalSessionOpen() async {
        let staleId = "stale-\(UUID().uuidString)"
        let targetId = "target-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: staleId)

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

        let (connection, _) = makeTestConnection(sessionId: staleId)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.sessionStore.upsert(makeTestSession(id: staleId, workspaceId: "w1", status: .busy))
        connection.sessionStore.upsert(makeTestSession(id: targetId, workspaceId: "w1", status: .busy))
        connection._connectStreamForTesting = { AsyncStream { _ in } }

        await connection.prepareExternalSessionOpen(sessionId: targetId)

        await manager.connect(connection: connection, sessionStore: connection.sessionStore)

        #expect(!streamCreated, "A stale session must not open a stream over the notification target")
        #expect(!historyLoaded)
        #expect(connection.focusedSessionId == targetId)
        #expect(connection.sessionStore.activeSessionId == targetId)
        #expect(manager.entryState == .disconnected(reason: .cancelled))

        manager.cleanup()
        connection.disconnectStream()
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

    @Test func unchangedStoppedFreshTraceInterruptsOldOpenTool() async {
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
                return id == toolId
                    && isDone
                    && !isError
                    && manager.reducer.isToolInterrupted(toolId)
                    && preview.isEmpty
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

    @Test func liveStateReadyFinalizesTerminalTimelineArtifacts() async {
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
        #expect(thinkingStates[0], "Terminal recovery must stop unresolved timeline artifacts")
        #expect(updates().last == false)

        streams.finish(index: 0)
        await connectTask.value
    }

    @Test func reconnectCatchUpStateReadyFinalizesTerminalTimelineArtifacts() async {
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
        #expect(thinkingStates[0], "Catch-up terminal recovery must stop unresolved artifacts")
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

    // MARK: - Presentation pause gating

    @Test func pausedDirectMutationsMarkReloadAndDoNotMutateReducer() async {
        let sessionId = "pause-gate-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .busy)))
        let reachedStreaming = await waitForMainActorCondition {
            manager.entryState == .streaming
        }
        #expect(reachedStreaming)

        // Seed one visible item while presentation is active.
        streams.yield(index: 0, message: .messageEnd(role: "user", content: "before-pause"))
        #expect(await waitForMainActorCondition {
            manager.reducer.items.contains { item in
                if case .userMessage(_, let text, _, _) = item { return text == "before-pause" }
                return false
            }
        })
        let itemCountBeforePause = manager.reducer.items.count

        manager.coalescer.pause()

        streams.yield(index: 0, message: .messageEnd(role: "user", content: "while-paused"))
        streams.yield(index: 0, message: .queueItemStarted(
            kind: .followUp,
            item: MessageQueueItem(id: "q1", message: "queued-while-paused", createdAt: 1),
            queueVersion: 1
        ))
        streams.yield(index: 0, message: .stopRequested(source: .user, reason: "Stopping…"))
        streams.yield(index: 0, message: .stopConfirmed(source: .user, reason: "Stop confirmed"))
        streams.yield(index: 0, message: .stopFailed(source: .user, reason: "nope"))
        streams.yield(
            index: 0,
            message: .state(session: makeTestSession(id: sessionId, status: .ready))
        )

        try? await Task.sleep(for: .milliseconds(80))

        #expect(manager.reducer.items.count == itemCountBeforePause)
        #expect(!manager.reducer.items.contains { item in
            if case .userMessage(_, let text, _, _) = item {
                return text == "while-paused" || text.contains("queued-while-paused")
            }
            if case .systemEvent(_, let message) = item {
                return message.contains("Stopping")
                    || message.contains("Stop confirmed")
                    || message.contains("Stop failed")
            }
            if case .error(_, let message) = item {
                return message.contains("Stop failed")
            }
            return false
        })
        #expect(
            manager.coalescer.needsPresentationTraceReload,
            "Paused direct mutations must arm authoritative reload"
        )
        #expect(manager.coalescer.resume())

        streams.finish(index: 0)
        await connectTask.value
        manager.cleanup()
    }

    @Test func connectWhilePresentationPausedAppliesCacheAndHistoryWithoutLivePublication() async {
        let sessionId = "paused-connect-\(UUID().uuidString)"
        let workspaceId = "paused-workspace"
        let cachedText = "CACHED_TIMELINE"
        let historyText = "AUTHORITATIVE_TIMELINE"
        let manager = ChatSessionManager(sessionId: sessionId)
        manager.coalescer.pause()
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._fetchSessionTraceForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(60))
            return (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy),
                [
                    makeTraceEvent(id: "history-user", type: .user, text: "history prompt"),
                    makeTraceEvent(id: "history-assistant", text: historyText),
                ]
            )
        }

        await TimelineCache.shared.saveTrace(sessionId, events: [
            makeTraceEvent(id: "cached-assistant", text: cachedText),
        ])
        defer {
            Task { await TimelineCache.shared.removeTrace(sessionId) }
        }

        let connection = ServerConnection()
        connection.setAPIClientForTesting(makeURLProtocolAPIClient())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        #expect(await waitForMainActorCondition {
            manager.reducer.items.contains { item in
                if case .assistantMessage(_, let text, _) = item { return text == cachedText }
                return false
            }
        }, "Paused connect should still apply cached timeline state")

        streams.yield(index: 0, message: .connected(
            session: makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy)
        ))
        #expect(await waitForMainActorCondition {
            manager.reducer.items.contains { item in
                if case .assistantMessage(_, let text, _) = item { return text == historyText }
                return false
            }
        }, "Paused connect should still apply authoritative history")

        streams.yield(index: 0, message: .textDelta(delta: "LIVE_WHILE_PAUSED"))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!manager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("LIVE_WHILE_PAUSED")
            }
            return false
        }, "Live deltas must remain unpublished while paused")
        #expect(!manager.coalescer.needsPresentationTraceReload)

        #expect(!manager.coalescer.resume())
        #expect(await waitForMainActorCondition {
            manager.reducer.items.contains { item in
                if case .assistantMessage(_, let text, _) = item {
                    return text.contains("LIVE_WHILE_PAUSED")
                }
                return false
            }
        })

        streams.finish(index: 0)
        await connectTask.value
        manager.cleanup()
    }

    @Test func tracePageAroundDeepLinkAppliesReducerWhilePresentationPaused() async {
        defer { TestURLProtocol.handler = nil }

        let sessionId = "paused-trace-page-\(UUID().uuidString)"
        let workspaceId = "w1"
        let session = makeTestSession(id: sessionId, workspaceId: workspaceId, status: .ready)
        let currentTrace = [makeTraceEvent(id: "current", text: "current page")]
        let olderTrace = [makeTraceEvent(id: "older", type: .user, text: "older page")]
        let initialPage = TracePageMetadata(
            hasOlder: true,
            olderCursor: "older-cursor",
            traceVersion: "v1",
            previewBytes: 4_096,
            staleCursor: false
        )
        let aroundPage = TracePageMetadata(
            hasOlder: false,
            olderCursor: nil,
            traceVersion: "v1",
            previewBytes: 4_096,
            staleCursor: false
        )
        let metrics = TracePageMetrics(
            rawEntryCount: 1,
            traceEventCount: 1,
            selectedRawEntryCount: 1,
            jsonlBytes: 1,
            scannedBytes: 1,
            readMs: 0,
            parseMs: 0,
            selectMs: 0,
            formatMs: 0,
            previewMs: 0,
            jsonBytes: nil,
            gzipBytes: nil,
            stringifyMs: nil,
            gzipMs: nil
        )
        struct TracePagePayload: Encodable {
            let session: Session
            let trace: [TraceEvent]
            let page: TracePageMetadata
            let metrics: TracePageMetrics
        }
        let encodedInitial = try! JSONEncoder().encode(
            TracePagePayload(session: session, trace: currentTrace, page: initialPage, metrics: metrics)
        )
        let encodedAround = try! JSONEncoder().encode(
            TracePagePayload(session: session, trace: olderTrace, page: aroundPage, metrics: metrics)
        )
        let initialResponse = HTTPURLResponse(
            url: URL(string: "http://localhost:7749")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        TestURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/\(workspaceId)/sessions/\(sessionId)/trace-page")
            if request.url?.query?.contains("aroundEntryId=older") == true {
                return (encodedAround, initialResponse)
            }
            return (encodedInitial, initialResponse)
        }

        let manager = ChatSessionManager(sessionId: sessionId)
        let connection = ServerConnection()
        connection.setAPIClientForTesting(makeURLProtocolAPIClient())
        let sessionStore = SessionStore()
        sessionStore.upsert(session)

        #expect(await manager.forceHistoryReload(connection: connection, sessionStore: sessionStore))
        manager.coalescer.pause()

        let loaded = await manager.loadTracePageAround(
            entryId: "older",
            connection: connection,
            sessionStore: sessionStore
        )

        #expect(loaded)
        #expect(manager.coalescer.isPresentationPaused)
        #expect(!manager.coalescer.needsPresentationTraceReload)
        #expect(manager.reducer.items.contains { $0.id == "older" })
    }

    @Test func resumeAfterOverflowAutomaticallyRetriesFailedHistoryReload() async {
        let sessionId = "overflow-retry-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        manager._presentationReloadRetryDelayForTesting = .milliseconds(20)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let tracker = HistoryReloadTracker()
        manager._loadHistoryForTesting = { cachedCount, cachedLastId in
            let call = await tracker.recordCall(
                cachedEventCount: cachedCount,
                cachedLastEventId: cachedLastId
            )
            if call == 2 {
                await tracker.recordCancellation()
                return nil
            }
            await tracker.recordCompletion()
            return (eventCount: 3, lastEventId: "evt-3")
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .busy))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .busy)))
        #expect(await waitForMainActorCondition { manager.entryState == .streaming })
        #expect(await tracker.waitForCalls(1))

        manager.coalescer.pause()
        // Exceed the paused event-count bound so resume requires full reload.
        for _ in 0...512 {
            manager.coalescer.receive(.textDelta(sessionId: sessionId, delta: "x"))
        }
        #expect(manager.coalescer.needsPresentationTraceReload)

        #expect(manager.coalescer.resume())
        manager.reloadTimelineAfterPresentationOverflow(
            connection: connection,
            sessionStore: sessionStore
        )

        #expect(await tracker.waitForCalls(2))
        #expect(
            manager.coalescer.needsPresentationTraceReload,
            "Failed overflow reload must keep the pending reload armed"
        )
        #expect(manager.lastSyncFailed)

        // The production overflow path retries without another scene callback.
        #expect(await tracker.waitForCalls(3))
        let completed = await waitForMainActorCondition {
            !manager.coalescer.needsPresentationTraceReload && manager.lastSyncFailed == false
        }
        #expect(completed, "Successful overflow reload must clear the pending reload arm")
        #expect(!manager.coalescer.resume())

        streams.finish(index: 0)
        await connectTask.value
        manager.cleanup()
    }

    @Test func overflowHistoryRetryStopsAtBoundAndCancelsWithLifecycle() async {
        let manager = ChatSessionManager(sessionId: "overflow-retry-bound-\(UUID().uuidString)")
        manager._presentationReloadRetryDelayForTesting = .milliseconds(20)
        let tracker = HistoryReloadTracker()
        manager._loadHistoryForTesting = { cachedCount, cachedLastId in
            _ = await tracker.recordCall(
                cachedEventCount: cachedCount,
                cachedLastEventId: cachedLastId
            )
            return nil
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()
        manager.coalescer.pause()
        manager.coalescer.markPresentationNeedsTraceReload()
        #expect(manager.coalescer.resume())
        manager.reloadTimelineAfterPresentationOverflow(
            connection: connection,
            sessionStore: sessionStore
        )

        #expect(await tracker.waitForCalls(3, timeoutMs: 1_000))
        try? await Task.sleep(for: .milliseconds(80))
        let boundedSnapshot = await tracker.snapshot()
        #expect(boundedSnapshot.calls.count == 3, "Overflow repair must use a bounded retry policy")

        manager._presentationReloadRetryDelayForTesting = .milliseconds(200)
        manager.coalescer.pause()
        manager.coalescer.markPresentationNeedsTraceReload()
        #expect(manager.coalescer.resume())
        manager.reloadTimelineAfterPresentationOverflow(
            connection: connection,
            sessionStore: sessionStore
        )
        #expect(await tracker.waitForCalls(4, timeoutMs: 500))
        manager.cleanup()
        try? await Task.sleep(for: .milliseconds(80))
        let canceledSnapshot = await tracker.snapshot()
        #expect(canceledSnapshot.calls.count == 4, "Cleanup must cancel a pending overflow retry")
    }

    @Test func pausedToolStartUpdateResumeSetsToolStartTimeWithoutReload() {
        let manager = ChatSessionManager(sessionId: "pause-tool-start-\(UUID().uuidString)")

        manager.coalescer.pause()
        manager.coalescer.receive(.toolStart(
            sessionId: manager.sessionId,
            toolEventId: "tool-1",
            tool: "bash",
            args: ["command": "echo hi"]
        ))
        manager.coalescer.receive(.toolUpdate(
            sessionId: manager.sessionId,
            toolEventId: "tool-1",
            tool: "bash",
            args: ["command": "echo hello"]
        ))

        #expect(!manager.coalescer.resume())
        #expect(manager.reducer.toolStartTime(for: "tool-1") != nil)
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
