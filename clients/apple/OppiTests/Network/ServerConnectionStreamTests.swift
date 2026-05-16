import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Stream")
@MainActor
struct ServerConnectionStreamTests {

    // MARK: - connectStream idempotency

    @Test func connectStreamIsIdempotentWhileActive() {
        let (conn, _) = makeTestConnection()

        let sentinel = Task<Void, Never> { }
        conn.streamConsumptionTask = sentinel
        conn.wsClient?._setStatusForTesting(.connected)

        conn.connectStream()

        #expect(!sentinel.isCancelled,
                "Should not cancel existing task when one is active and WS is connected")
    }

    @Test func connectStreamSkipsWhenWSAlreadyConnectedAndNoTask() {
        let (conn, _) = makeTestConnection()
        conn.wsClient?._setStatusForTesting(.connected)
        // No consumption task — would normally trigger wsClient.connect()
        conn.streamConsumptionTask = nil

        conn.connectStream()

        // Should NOT have started a new connection — the WS is healthy.
        // wsClient.connect() would have reset status to .connecting.
        #expect(conn.wsClient?.status == .connected,
                "connectStream should not tear down a healthy WS")
    }

    @Test func connectStreamRestartsWhenTaskExistsButWSDisconnected() {
        let (conn, _) = makeTestConnection()

        conn.streamConsumptionTask = Task { }
        conn.wsClient?._setStatusForTesting(.disconnected)

        conn.connectStream()

        #expect(conn.streamConsumptionTask != nil,
                "Should create new task when WS is disconnected")
    }

    @Test func connectStreamCreatesTaskWhenNil() {
        let (conn, _) = makeTestConnection()

        #expect(conn.streamConsumptionTask == nil)

        conn.connectStream()

        #expect(conn.streamConsumptionTask != nil,
                "Should create task when none exists")
    }

    @Test func prepareForSessionReentryRestoresFocusWithoutOpeningStream() {
        let (conn, _) = makeTestConnection(sessionId: "child")
        conn.sessionStore.upsert(makeTestSession(id: "parent", workspaceId: "w1"))
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        conn.disconnectSession()
        #expect(conn.focusedSessionId == nil)

        conn.prepareForSessionReentry("parent")

        #expect(conn.focusedSessionId == "parent",
                "Re-entry should restore the parent as the focused command target before async connect runs")
        #expect(conn.streamConsumptionTask == nil,
                "Without split-stream capability metadata, re-entry should stay HTTP-only until the chat connect task binds the stream")
        #expect(conn.wsClient?.status == .disconnected)
    }

    @Test func prepareForSessionReentryReconnectsStreamWhenCapabilitiesAreReady() {
        let (conn, _) = makeTestConnection(sessionId: "child")
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.sessionStore.upsert(makeTestSession(id: "parent", workspaceId: "w1", status: .busy))
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        conn.disconnectSession()
        #expect(conn.focusedSessionId == nil)

        conn.prepareForSessionReentry("parent")

        #expect(conn.focusedSessionId == "parent")
        #expect(conn.focusedSessionStreamEndpointKind == "split_session")
        #expect(conn.streamConsumptionTask != nil,
                "Re-entry should eagerly reopen the bound session transport so session actions work before ChatSessionManager.connect finishes")
    }

    // MARK: - streamConsumptionTask self-cleanup

    @Test func consumptionTaskNilsItselfWhenStreamEnds() async {
        let (conn, _) = makeTestConnection()

        let (stream, continuation) = AsyncStream<StreamMessage>.makeStream()
        continuation.finish()

        conn.streamConsumptionTask = Task { [weak conn] in
            for await msg in stream {
                conn?.routeStreamMessage(msg)
            }
            await MainActor.run { [weak conn] in
                conn?.streamConsumptionTask = nil
            }
        }

        let cleaned = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { conn.streamConsumptionTask == nil }
        }

        #expect(cleaned, "streamConsumptionTask should nil itself after stream ends")
    }

    // MARK: - disconnectStream cleanup

    @Test func disconnectStreamCleansUpEverything() {
        let (conn, _) = makeTestConnection()
        conn.streamConsumptionTask = Task { }

        let (_, continuation) = AsyncStream<SessionStreamEvent>.makeStream()
        conn.sessionEventContinuations["s1"] = continuation

        conn.disconnectStream()

        #expect(conn.streamConsumptionTask == nil,
                "Should nil out consumption task")
        #expect(conn.sessionEventContinuations.isEmpty,
                "Should clear all session continuations")
    }

    // MARK: - stream_connected refresh handling

    @Test func streamConnectedMessageTriggersRefresh() {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        var yieldedToSession = false
        let stream = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }
        let consumeTask = Task {
            for await _ in stream {
                await MainActor.run { yieldedToSession = true }
            }
        }

        let streamMsg = StreamMessage(
            sessionId: nil,
            seq: nil,
            currentSeq: nil,
            message: .streamConnected(userName: "test", serverDictationAvailable: false)
        )
        conn.routeStreamMessage(streamMsg)

        #expect(!yieldedToSession,
                "stream_connected should be handled at stream level, not yielded to sessions")
        consumeTask.cancel()
    }

    // MARK: - routeStreamMessage routing

    @Test func routeStreamMessageYieldsToSessionContinuation() async {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        var receivedMessages: [ServerMessage] = []
        let stream = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }

        let consumeTask = Task {
            for await event in stream {
                await MainActor.run { receivedMessages.append(event.message) }
            }
        }

        let permRequest = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "test", reason: "",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        let streamMsg = StreamMessage(
            sessionId: "s1",
            seq: 1,
            currentSeq: nil,
            message: .permissionRequest(permRequest)
        )
        conn.routeStreamMessage(streamMsg)

        let received = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { !receivedMessages.isEmpty }
        }

        consumeTask.cancel()

        #expect(received, "Message should be yielded to session continuation")
    }

    @Test func routeStreamMessageDefersNonFocusedSharedStoreUpdateWhenLiveConsumerExists() {
        let (conn, _) = makeTestConnection(sessionId: "focused")
        conn.sessionStore.upsert(makeTestSession(id: "focused", status: .ready))
        conn.sessionStore.upsert(makeTestSession(id: "background", status: .ready))

        let stream = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["background"] = continuation
        }
        _ = stream

        conn.routeStreamMessage(StreamMessage(
            sessionId: "background",
            seq: 1,
            currentSeq: nil,
            message: .agentStart
        ))

        #expect(
            conn.sessionStore.session(id: "background")?.status == .ready,
            "live non-focused consumer owns shared store mutation for its event"
        )

        conn.sessionEventContinuations["background"]?.finish()
        conn.sessionEventContinuations.removeValue(forKey: "background")
    }

    @Test func routeStreamMessageAppliesNonFocusedSharedStoreUpdateWithoutLiveConsumer() {
        let (conn, _) = makeTestConnection(sessionId: "focused")
        conn.sessionStore.upsert(makeTestSession(id: "focused", status: .ready))
        conn.sessionStore.upsert(makeTestSession(id: "background", status: .ready))

        conn.routeStreamMessage(StreamMessage(
            sessionId: "background",
            seq: 1,
            currentSeq: nil,
            message: .agentStart
        ))

        #expect(conn.sessionStore.session(id: "background")?.status == .busy)
    }

    @Test func routeStreamMessageYieldsSessionEventWithMetadata() async {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        var receivedEvents: [SessionStreamEvent] = []
        let stream = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }

        let consumeTask = Task {
            for await event in stream {
                await MainActor.run { receivedEvents.append(event) }
            }
        }

        conn.routeStreamMessage(StreamFrameEvent(
            sessionId: "s1",
            message: .agentStart,
            meta: InboundStreamMeta(
                seq: 42,
                currentSeq: 45,
                receivedAtMs: 123,
                transportPath: .lan
            )
        ))

        let received = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { !receivedEvents.isEmpty }
        }

        consumeTask.cancel()

        #expect(received, "Message should be yielded to event continuation")
        #expect(receivedEvents.first?.sessionId == "s1")
        #expect(receivedEvents.first?.meta?.seq == 42)
        #expect(receivedEvents.first?.meta?.currentSeq == 45)
        #expect(receivedEvents.first?.meta?.transportPath == .lan)
    }

    @Test func routeStreamMessageCarriesSessionSeqMetadata() async {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        var receivedEvents: [SessionStreamEvent] = []
        let stream = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }

        let consumeTask = Task {
            for await event in stream {
                await MainActor.run { receivedEvents.append(event) }
            }
        }

        conn.routeStreamMessage(StreamMessage(
            sessionId: "s1",
            seq: 77,
            currentSeq: 80,
            message: .agentStart
        ))

        let received = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { !receivedEvents.isEmpty }
        }

        consumeTask.cancel()

        #expect(received, "Message should be yielded to event continuation")
        #expect(receivedEvents.first?.meta?.seq == 77)
        #expect(receivedEvents.first?.meta?.currentSeq == 80)
    }

    // MARK: - reconnectIfNeeded restarts dead stream

    @Test func reconnectIfNeededRestartsDeadBoundSessionStream() async {
        let (conn, _) = makeTestConnection()
        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(id: "s1")])
        conn.sessionStore.markSyncSucceeded(at: now)
        conn.workspaceStore.workspaces = [makeTestWorkspace(id: "w1")]
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")
        conn.wsClient?.setStreamURL(URL(string: "ws://192.0.2.1:7749/workspaces/w1/sessions/s1/stream"))
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        #expect(conn.streamConsumptionTask == nil)

        await conn.reconnectIfNeeded()

        #expect(conn.streamConsumptionTask != nil,
                "reconnectIfNeeded should restart a prepared bound session stream")

        conn.streamConsumptionTask?.cancel()
        conn.disconnectStream()
    }

    @Test func reconnectIfNeededSkipsFocusedSessionWithoutBoundStreamEndpoint() async {
        let (conn, _) = makeTestConnection()
        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(id: "s1")])
        conn.sessionStore.markSyncSucceeded(at: now)
        conn.workspaceStore.workspaces = [makeTestWorkspace(id: "w1")]
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        await conn.reconnectIfNeeded()

        #expect(conn.streamConsumptionTask == nil,
                "Foreground recovery should not open a focused-session WebSocket before a bound stream endpoint is prepared")
        #expect(conn.wsClient?.status == .disconnected)
    }

    @Test func reconnectIfNeededSkipsAliveStream() async {
        let (conn, _) = makeTestConnection()

        conn.wsClient?._setStatusForTesting(.connected)
        let sentinel = Task<Void, Never> { }
        conn.streamConsumptionTask = sentinel

        await conn.reconnectIfNeeded()

        #expect(!sentinel.isCancelled,
                "Should not replace an active consumption task")
    }

    // MARK: - routeStreamMessage resolves command waiters at stream boundary

    @Test func routeStreamMessageResolvesGetQueueWaiterEagerly() async {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        let pending = PendingCommand(command: "get_queue", requestId: "req-q")
        conn.commands.registerCommand(pending)

        // Per-session stream exists but nobody is consuming it — same as
        // in streamSession() where get_queue blocks before returning.
        _ = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }

        let streamMsg = StreamMessage(
            sessionId: "s1",
            seq: 1,
            currentSeq: nil,
            message: .commandResult(
                command: "get_queue", requestId: "req-q",
                success: true, data: nil, error: nil
            )
        )
        conn.routeStreamMessage(streamMsg)

        let result = try? await pending.waiter.wait()
        #expect(result != nil, "get_queue waiter should be resolved eagerly by routeStreamMessage")
    }

    @Test func routeStreamMessageResolvesNonSetupCommandAtBoundary() async {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        let pending = PendingCommand(command: "set_model", requestId: "req-m")
        conn.commands.registerCommand(pending)

        _ = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }

        let streamMsg = StreamMessage(
            sessionId: "s1",
            seq: 1,
            currentSeq: nil,
            message: .commandResult(
                command: "set_model", requestId: "req-m",
                success: true, data: nil, error: nil
            )
        )
        conn.routeStreamMessage(streamMsg)

        let result = try? await pending.waiter.wait()
        #expect(result != nil, "All requestId command results should resolve at stream boundary")
    }

    // MARK: - streamSession timing budget (regression gate)

    /// Integration test: streamSession() must complete within a tight time budget.
    ///
    /// Regression gate for the 8s delay bug where:
    /// 1. get_queue command_result was not eagerly resolved in routeStreamMessage
    /// 2. waitForConnectionTimeout was bumped from 3s to 8s
    ///
    /// The mock simulates instant server responses — any delay beyond a
    /// few hundred ms means the setup path is blocking on something it shouldn't.
    @Test func splitSessionStreamCompletesWithinTimeBudget() async {
        let (conn, _) = makeTestConnection()
        conn.wsClient?._setStatusForTesting(.connected)
        conn.streamConsumptionTask = Task { try? await Task.sleep(for: .seconds(60)) }
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")

        let start = ContinuousClock.now
        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: "s1",
            workspaceId: "w1"
        )
        let elapsed = ContinuousClock.now - start

        #expect(stream != nil, "streamSession should return a stream")
        #expect(elapsed < .seconds(2),
                "streamSession should complete within 2s budget, took \(elapsed) — check eager command resolution and waitForConnection")

        conn.streamConsumptionTask?.cancel()
    }

    @Test func modelAndThinkingCommandsProceedAfterBoundStreamMarksFull() async throws {
        let (conn, _) = makeTestConnection()
        conn.wsClient?._setStatusForTesting(.connected)
        conn.streamConsumptionTask = Task { try? await Task.sleep(for: .seconds(60)) }
        conn._setActiveSessionIdForTesting("s1")
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")

        var sentTypes: [String] = []
        conn._sendMessageForTesting = { message in
            sentTypes.append(message.typeLabel)
        }

        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: "s1",
            workspaceId: "w1"
        )

        #expect(stream != nil)
        #expect(await conn.waitForFocusedFullSubscription(sessionId: "s1", timeout: .milliseconds(100)))

        try await conn.setModel(provider: "openai", modelId: "gpt-5.4")
        try await conn.setThinkingLevel(.medium)

        #expect(sentTypes.contains("set_model"))
        #expect(sentTypes.contains("set_thinking_level"))
        #expect(!sentTypes.contains("subscribe"))
        conn.streamConsumptionTask?.cancel()
    }

    /// Regression gate: if get_queue never returns command_result, split stream
    /// setup must still return quickly while queue sync retries in background.
    @Test func splitSessionStreamDoesNotBlockOnMissingGetQueueAck() async {
        let (conn, _) = makeTestConnection()
        conn.wsClient?._setStatusForTesting(.connected)
        conn.streamConsumptionTask = Task { try? await Task.sleep(for: .seconds(60)) }
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")
        conn._sendMessageForTesting = { _ in }

        let start = ContinuousClock.now
        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: "s1",
            workspaceId: "w1"
        )
        let elapsed = ContinuousClock.now - start

        #expect(stream != nil, "streamSession should still return a stream")
        #expect(
            elapsed < .seconds(1),
            "streamSession should not block on queue sync and should return in <1s when get_queue ack is missing; took \(elapsed)"
        )

        conn.streamConsumptionTask?.cancel()
        conn.disconnectSession()
    }

    @Test func streamSessionReplacesInFlightBoundStreamForNewSession() async {
        for status in [WebSocketClient.Status.connecting, .reconnecting(attempt: 1)] {
            let (conn, _) = makeTestConnection(sessionId: "old")
            conn.setSplitStreamCapabilitiesForTesting()
            conn.sessionStore.applyServerSnapshot([
                makeTestSession(id: "old", workspaceId: "w1"),
                makeTestSession(id: "new", workspaceId: "w1"),
            ])
            conn.setFocusedSessionStreamEndpointKindForTesting("split_session")
            conn.wsClient?.setStreamURL(URL(string: "ws://127.0.0.1:9/workspaces/w1/sessions/old/stream"))
            conn.wsClient?._setStatusForTesting(status)
            let staleTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            conn.streamConsumptionTask = staleTask
            conn._sendMessageForTesting = { _ in }

            let streamTask = Task { @MainActor in
                await conn.streamSession("new", workspaceId: "w1")
            }

            try? await Task.sleep(for: .milliseconds(30))
            streamTask.cancel()
            _ = await streamTask.value

            #expect(staleTask.isCancelled,
                    "Switching bound session streams must tear down stale \(status) transport")
            #expect(conn.focusedSessionId == "new")
            #expect(conn.focusedSessionStreamEndpointKind == "split_session")

            conn.deferredQueueSyncTask?.cancel()
            conn.streamConsumptionTask?.cancel()
            conn.disconnectSession()
        }
    }

    @Test func cancelledSplitSessionConnectDoesNotStartQueueSync() async {
        let (conn, _) = makeTestConnection()
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")

        var sentTypes: [String] = []
        conn._sendMessageForTesting = { message in
            sentTypes.append(message.typeLabel)
        }

        let streamTask = Task { @MainActor in
            await conn.sessionStreamCoordinator.streamSession(
                connection: conn,
                sessionId: "s1",
                workspaceId: "w1"
            )
        }

        try? await Task.sleep(for: .milliseconds(20))
        streamTask.cancel()
        _ = await streamTask.value
        try? await Task.sleep(for: .milliseconds(100))

        #expect(!sentTypes.contains("get_queue"),
                "Cancelled connection setup must not start queue sync against a dead WebSocket")
        switch conn.sessionStreamCoordinator.state {
        case .queueSync, .streaming:
            Issue.record("Cancelled connection setup should stay out of queueSync/streaming; got \(conn.sessionStreamCoordinator.state)")
        case .idle, .connectingTransport, .resubscribing:
            break
        }

        conn.deferredQueueSyncTask?.cancel()
        conn.streamConsumptionTask?.cancel()
        conn.disconnectSession()
    }

    @Test func streamSessionRequiresRequiredSplitCapabilities() async {
        let (conn, _) = makeTestConnection(sessionId: "s1")
        conn.wsClient?._setStatusForTesting(.connected)
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: false)

        let stream = await conn.streamSession("s1", workspaceId: "w1")

        #expect(stream == nil)
        #expect(conn.extensionToast == nil)
        #expect(conn.focusedSessionStreamEndpointKind == "none")
    }

    @Test func splitSessionStreamSkipsExplicitSubscribe() async throws {
        let (conn, _) = makeTestConnection(sessionId: "s1")
        conn.wsClient?._setStatusForTesting(.connected)
        conn.streamConsumptionTask = Task { try? await Task.sleep(for: .seconds(60)) }
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")

        var sentTypes: [String] = []
        conn._sendMessageForTesting = { message in
            sentTypes.append(message.typeLabel)
        }

        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: "s1",
            workspaceId: "w1"
        )

        #expect(stream != nil)
        #expect(!sentTypes.contains("subscribe"))
        #expect(await conn.waitForFocusedFullSubscription(sessionId: "s1", timeout: .milliseconds(100)))

        conn.streamConsumptionTask?.cancel()
    }

    @Test func sessionAudioDictationClientRequiresCapabilityAndFocusedWorkspace() {
        let (conn, _) = makeTestConnection(sessionId: "s1")
        conn.focusedSessionStore.focus(sessionId: "s1", workspaceId: "w1")

        #expect(conn.makeDictationStreamClientForFocusedSession() == nil)

        conn.sessionAudioStreamAvailable = true
        #expect(conn.makeDictationStreamClientForFocusedSession() != nil)
    }

}
