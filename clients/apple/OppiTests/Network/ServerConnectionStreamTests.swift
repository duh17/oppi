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

    @Test func prepareForSessionReentryKeepsWorkspaceHintForUncachedSession() {
        let (conn, _) = makeTestConnection(sessionId: "parent")
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        conn.prepareForSessionReentry("new-child", workspaceIdHint: " ws-1 ")

        #expect(conn.focusedSessionId == "new-child")
        #expect(conn.streamConsumptionTask == nil,
                "Unknown sessions should not eagerly open a stream until ChatSessionManager binds it with history context")
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

    @Test func prepareForSessionReentryUsesPendingAskWorkspaceForUncachedSession() {
        let (conn, _) = makeTestConnection(sessionId: "old")
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.askRequestStore.set(
            AskRequest(
                id: "ask-1",
                sessionId: "new-child",
                questions: [AskQuestion(id: "q1", question: "Continue?", options: [], multiSelect: false)],
                allowCustom: true,
                timeout: nil,
                workspaceId: "w1"
            ),
            for: "new-child"
        )
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        conn.prepareForSessionReentry("new-child")

        #expect(conn.focusedSessionId == "new-child")
        #expect(conn.focusedSessionStreamEndpointKind == "split_session")
        #expect(conn.streamConsumptionTask != nil,
                "Notification re-entry should bind the focused stream from the pending permission gate workspace before the session summary arrives")

        conn.disconnectSession()
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

        let streamMsg = StreamMessage(
            sessionId: "s1",
            seq: 1,
            currentSeq: nil,
            message: .agentStart
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

    /// Notification tap / in-app re-entry opens the bound socket before ChatView
    /// registers a per-session continuation. Bootstrap frames must park and then
    /// drain in order when `streamSession` attaches.
    @Test func focusedBootstrapFramesParkUntilStreamSessionAttaches() async {
        let sessionId = "s1"
        let (conn, _) = makeTestConnection(sessionId: sessionId)
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        let session = makeTestSession(id: sessionId, workspaceId: "w1", status: .busy)
        conn.sessionStore.upsert(session)
        conn.wsClient?._setStatusForTesting(.connected)
        conn.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()

        conn.prepareForSessionReentry(sessionId)
        #expect(conn.sessionEventContinuations[sessionId] == nil)
        #expect(conn.focusedSessionId == sessionId)

        conn.routeStreamMessage(StreamMessage(
            sessionId: sessionId,
            seq: 1,
            currentSeq: 3,
            message: .connected(session: session)
        ))
        conn.routeStreamMessage(StreamMessage(
            sessionId: sessionId,
            seq: 2,
            currentSeq: 3,
            message: .state(session: session)
        ))
        conn.routeStreamMessage(StreamMessage(
            sessionId: sessionId,
            seq: 3,
            currentSeq: 3,
            message: .textDelta(delta: "hello")
        ))

        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: sessionId,
            routeScope: .workspace("w1")
        )
        #expect(stream != nil, "streamSession should attach a consumer after the socket is already connected")

        var received: [ServerMessage] = []
        let consumeTask = Task {
            guard let stream else { return }
            for await event in stream {
                await MainActor.run { received.append(event.message) }
                if received.count >= 3 { break }
            }
        }

        let delivered = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { received.count >= 3 }
        }
        consumeTask.cancel()

        #expect(delivered, "Focused bootstrap frames must drain when streamSession attaches")
        #expect(received.count >= 3)
        if received.count >= 3 {
            #expect(received[0] == .connected(session: session))
            #expect(received[1] == .state(session: session))
            #expect(received[2] == .textDelta(delta: "hello"))
        }

        conn.streamConsumptionTask?.cancel()
        conn.disconnectStream()
    }

    @Test func focusedParkedFrameBoundKeepsConnectedAndState() async {
        let sessionId = "s1"
        let (conn, _) = makeTestConnection(sessionId: sessionId)
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        let session = makeTestSession(id: sessionId, workspaceId: "w1", status: .busy)
        conn.sessionStore.upsert(session)
        conn.wsClient?._setStatusForTesting(.connected)
        conn.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()
        conn.prepareForSessionReentry(sessionId)

        conn.routeStreamMessage(StreamMessage(
            sessionId: sessionId,
            seq: 1,
            currentSeq: 80,
            message: .connected(session: session)
        ))
        conn.routeStreamMessage(StreamMessage(
            sessionId: sessionId,
            seq: 2,
            currentSeq: 80,
            message: .state(session: session)
        ))
        for index in 3...80 {
            conn.routeStreamMessage(StreamMessage(
                sessionId: sessionId,
                seq: index,
                currentSeq: 80,
                message: .textDelta(delta: "d\(index)")
            ))
        }

        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: sessionId,
            routeScope: .workspace("w1")
        )
        #expect(stream != nil)

        var received: [ServerMessage] = []
        let consumeTask = Task {
            guard let stream else { return }
            for await event in stream {
                await MainActor.run { received.append(event.message) }
                if received.count >= 64 { break }
            }
        }

        let delivered = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { received.count >= 2 }
        }
        consumeTask.cancel()

        #expect(delivered)
        #expect(received.count <= 64, "Parked focused frames must stay bounded")
        #expect(received.contains(.connected(session: session)))
        #expect(received.contains(.state(session: session)))

        conn.streamConsumptionTask?.cancel()
        conn.disconnectStream()
    }

    @Test func nonFocusedFramesAreNotParkedForLaterAttach() async {
        let (conn, _) = makeTestConnection(sessionId: "focused")
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.sessionStore.upsert(makeTestSession(id: "focused", workspaceId: "w1", status: .ready))
        conn.sessionStore.upsert(makeTestSession(id: "background", workspaceId: "w1", status: .busy))
        conn.wsClient?._setStatusForTesting(.connected)
        conn.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()
        conn.prepareForSessionReentry("focused")

        conn.routeStreamMessage(StreamMessage(
            sessionId: "background",
            seq: 1,
            currentSeq: 1,
            message: .textDelta(delta: "should-not-park")
        ))

        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: "background",
            routeScope: .workspace("w1")
        )
        #expect(stream != nil)

        var received: [ServerMessage] = []
        let consumeTask = Task {
            guard let stream else { return }
            for await event in stream {
                await MainActor.run { received.append(event.message) }
            }
        }
        let stayedEmpty = await waitForMainActorConditionToStayTrue(
            for: .milliseconds(80),
            poll: .milliseconds(10)
        ) {
            received.isEmpty
        }
        consumeTask.cancel()

        #expect(stayedEmpty, "Cross-session frames without a consumer must not replay on later attach")

        conn.streamConsumptionTask?.cancel()
        conn.disconnectStream()
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
        // Mark capabilities loaded so foreground recovery does not issue a live
        // GET /server/info; a real failure would trigger availability route
        // recovery and tear down the transport this test observes.
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")
        let streamFactory = ScriptedFrameStreamFactory()
        conn._connectStreamForTesting = { streamFactory.makeStream() }
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        #expect(conn.streamConsumptionTask == nil)

        await conn.reconnectIfNeeded()

        #expect(await streamFactory.waitForCreated(1, timeoutMs: 100))
        #expect(conn.streamConsumptionTask != nil,
                "reconnectIfNeeded should restart a prepared bound session stream")

        streamFactory.finish(index: 0)
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
        // Keep capability discovery off the network (see restart test above).
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        await conn.reconnectIfNeeded()

        #expect(conn.streamConsumptionTask == nil,
                "Foreground recovery should not open a focused-session WebSocket before a bound stream endpoint is prepared")
        #expect(conn.wsClient?.status == .disconnected)
    }

    @Test func reconnectIfNeededSkipsAliveStream() async {
        let (conn, _) = makeTestConnection()
        // Fresh stores and loaded capabilities keep recovery HTTP-free; a live
        // request failure would trigger route recovery and cancel the sentinel.
        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(id: "s1")])
        conn.sessionStore.markSyncSucceeded(at: now)
        conn.workspaceStore.workspaces = [makeTestWorkspace(id: "w1")]
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)

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
        conn.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")

        let start = ContinuousClock.now
        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: "s1",
            routeScope: .workspace("w1")
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
        conn.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()
        conn._setActiveSessionIdForTesting("s1")
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")

        var sentTypes: [String] = []
        conn._sendMessageForTesting = { message in
            sentTypes.append(message.typeLabel)
            guard case .setModel(_, _, let requestId) = message,
                  let requestId else {
                return
            }
            _ = conn.commands.resolveCommandResult(
                command: "set_model",
                requestId: requestId,
                success: true,
                data: ["provider": "openai", "id": "gpt-5.4"],
                error: nil
            )
        }

        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: "s1",
            routeScope: .workspace("w1")
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
        conn.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")
        conn._sendMessageForTesting = { _ in }

        let start = ContinuousClock.now
        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: "s1",
            routeScope: .workspace("w1")
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
            let staleTask = makeCancellableNeverCompletingTaskForTesting()
            conn.streamConsumptionTask = staleTask
            conn._sendMessageForTesting = { _ in }

            let streamTask = Task { @MainActor in
                await conn.streamSession("new", workspaceId: "w1")
            }

            let didCancelStaleTask = await waitForMainActorCondition(
                timeout: .milliseconds(300),
                poll: .milliseconds(10)
            ) {
                staleTask.isCancelled
            }
            streamTask.cancel()
            _ = await streamTask.value

            #expect(didCancelStaleTask,
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
                routeScope: .workspace("w1")
            )
        }

        let reachedTransportConnect = await waitForMainActorCondition(
            timeout: .milliseconds(300),
            poll: .milliseconds(10)
        ) {
            if case .connectingTransport = conn.sessionStreamCoordinator.state {
                return true
            }
            return false
        }
        #expect(reachedTransportConnect,
                "streamSession should enter transport setup before the cancellation check")

        streamTask.cancel()
        _ = await streamTask.value
        let queueSyncStayedStopped = await waitForMainActorConditionToStayTrue(
            for: .milliseconds(100),
            poll: .milliseconds(10)
        ) {
            !sentTypes.contains("get_queue")
        }

        #expect(queueSyncStayedStopped,
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
        conn.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")

        var sentTypes: [String] = []
        conn._sendMessageForTesting = { message in
            sentTypes.append(message.typeLabel)
        }

        let stream = await conn.sessionStreamCoordinator.streamSession(
            connection: conn,
            sessionId: "s1",
            routeScope: .workspace("w1")
        )

        #expect(stream != nil)
        #expect(!sentTypes.contains("subscribe"))
        #expect(await conn.waitForFocusedFullSubscription(sessionId: "s1", timeout: .milliseconds(100)))

        conn.streamConsumptionTask?.cancel()
    }

    @Test func dictationClientUsesServerBoundStreamWithoutCapabilityPreflight() {
        let (conn, _) = makeTestConnection(sessionId: "s1")

        #expect(conn.makeDictationStreamClient() != nil)
    }

    @Test func controlSessionStreamUsesControlURL() {
        let (conn, _) = makeTestConnection(sessionId: "control-1")
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)

        conn.prepareFocusedSessionStreamEndpointForTesting(
            sessionId: "control-1",
            routeScope: .control
        )

        #expect(conn.focusedSessionStreamURLForTesting?.path == "/control-sessions/control-1/stream")
    }

    @Test func mismatchedSteerRebindsBeforeEmittingFrame() async throws {
        let (conn, _) = makeTestConnection(sessionId: "session-a")
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.sessionStore.upsert(makeTestSession(id: "session-a", workspaceId: "w1", status: .busy))
        conn.sessionStore.upsert(makeTestSession(id: "session-b", workspaceId: "w1", status: .ready))
        conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "session-b", workspaceId: "w1")
        conn._connectStreamForTesting = { AsyncStream { _ in } }

        var emittedBoundPaths: [String] = []
        conn._sendMessageForTesting = { message in
            emittedBoundPaths.append(conn.focusedSessionStreamURLForTesting?.path ?? "none")
            guard case .steer(_, _, let requestId, _) = message,
                  let requestId else { return }
            _ = conn.commands.resolveTurnCommandResult(
                command: "steer",
                requestId: requestId,
                success: true,
                error: nil
            )
        }

        try await conn.sendSteer("redirect safely", sessionIdOverride: "session-a")

        #expect(emittedBoundPaths == ["/workspaces/w1/sessions/session-a/stream"])
        #expect(conn.focusedSessionId == "session-a")
        #expect(conn.focusedSessionStreamURLForTesting?.path == "/workspaces/w1/sessions/session-a/stream")
        conn.disconnectSession()
    }

    @Test func matchingSteerDoesNotPrepareEndpointAgain() async throws {
        let (conn, _) = makeTestConnection(sessionId: "session-a")
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.sessionStore.upsert(makeTestSession(id: "session-a", workspaceId: "w1", status: .busy))
        conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "session-a", workspaceId: "w1")

        var prepareCount = 0
        conn._onPrepareForSessionReentryForTesting = { _ in prepareCount += 1 }
        conn._sendMessageForTesting = { message in
            guard case .steer(_, _, let requestId, _) = message,
                  let requestId else { return }
            _ = conn.commands.resolveTurnCommandResult(
                command: "steer",
                requestId: requestId,
                success: true,
                error: nil
            )
        }

        try await conn.sendSteer("already safe", sessionIdOverride: "session-a")

        #expect(prepareCount == 0)
        #expect(conn.focusedSessionStreamURLForTesting?.path == "/workspaces/w1/sessions/session-a/stream")
    }

    @Test func mismatchedSteerWithoutRouteFailsBeforeEmittingFrame() async {
        let (conn, _) = makeTestConnection(sessionId: "session-a")
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.sessionStore.upsert(makeTestSession(id: "session-b", workspaceId: "w1", status: .ready))
        conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "session-b", workspaceId: "w1")

        var emittedCount = 0
        conn._sendMessageForTesting = { _ in emittedCount += 1 }

        do {
            try await conn.sendSteer("must not cross streams", sessionIdOverride: "session-a")
            Issue.record("A mismatched send without route scope should fail")
        } catch {
            #expect(error.localizedDescription.contains("session-a"))
        }

        #expect(emittedCount == 0)
        #expect(conn.focusedSessionStreamURLForTesting?.path == "/workspaces/w1/sessions/session-b/stream")
    }

    @Test func everyOverriddenTurnCommandRepairsMismatchedBinding() async throws {
        for command in BindingGuardCommand.allCases {
            let (conn, _) = makeTestConnection(sessionId: "session-a")
            conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
            conn.sessionStore.upsert(makeTestSession(id: "session-a", workspaceId: "w1", status: .busy))
            conn.sessionStore.upsert(makeTestSession(id: "session-b", workspaceId: "w1", status: .ready))
            conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "session-b", workspaceId: "w1")
            conn._connectStreamForTesting = { AsyncStream { _ in } }

            var emittedPath: String?
            conn._sendMessageForTesting = { message in
                emittedPath = conn.focusedSessionStreamURLForTesting?.path
                switch message {
                case .prompt(_, _, _, let requestId, _):
                    if let requestId {
                        _ = conn.commands.resolveTurnCommandResult(
                            command: "prompt", requestId: requestId, success: true, error: nil
                        )
                    }
                case .steer(_, _, let requestId, _):
                    if let requestId {
                        _ = conn.commands.resolveTurnCommandResult(
                            command: "steer", requestId: requestId, success: true, error: nil
                        )
                    }
                case .followUp(_, _, let requestId, _):
                    if let requestId {
                        _ = conn.commands.resolveTurnCommandResult(
                            command: "follow_up", requestId: requestId, success: true, error: nil
                        )
                    }
                case .stop(let requestId):
                    if let requestId {
                        _ = conn.commands.resolveCommandResult(
                            command: "stop", requestId: requestId, success: true, data: nil, error: nil
                        )
                    }
                default:
                    break
                }
            }

            try await command.send(using: conn, sessionId: "session-a")

            #expect(
                emittedPath == "/workspaces/w1/sessions/session-a/stream",
                "\(command) must emit only after rebinding"
            )
            conn.disconnectSession()
        }
    }

    @Test func focusArbitrationTelemetryRecordsRequestedCancelledAndWon() {
        let (conn, _) = makeTestConnection(sessionId: "session-a")
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "session-b", workspaceId: "w1")
        conn.wsClient?._setStatusForTesting(.connecting)
        conn.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()

        var events: [(outcome: String, metadata: [String: String])] = []
        conn._onFocusArbitrationForTesting = { events.append(($0, $1)) }

        conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "session-a", workspaceId: "w1")

        #expect(events.map(\.outcome) == ["requested", "cancelled", "won"])
        for event in events {
            #expect(event.metadata["previousSessionId"] == "session-b")
            #expect(event.metadata["nextSessionId"] == "session-a")
        }
    }

    @Test func webSocketRejectsFrameWhenBoundSessionChangesBeforeSend() async {
        let (conn, _) = makeTestConnection(sessionId: "session-a")
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "session-b", workspaceId: "w1")
        guard let wsClient = conn.wsClient else {
            Issue.record("Expected configured WebSocket client")
            return
        }

        do {
            try await wsClient.send(.stopSession(), sessionId: "session-a")
            Issue.record("A frame must not use a stream bound to another session")
        } catch let error as FocusedSessionBindingError {
            #expect(error.localizedDescription.contains("session-a"))
            #expect(error.localizedDescription.contains("session-b"))
        } catch {
            Issue.record("Expected FocusedSessionBindingError, got \(error)")
        }
    }

    @Test func webSocketRejectsFrameWhenBoundSessionChangesWhileWaitingToSend() async {
        let (conn, _) = makeTestConnection(sessionId: "session-a")
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "session-a", workspaceId: "w1")
        guard let wsClient = conn.wsClient else {
            Issue.record("Expected configured WebSocket client")
            return
        }

        var emittedTypes: [String] = []
        wsClient._sendFrameForTesting = { emittedTypes.append($0.typeLabel) }
        wsClient._setStatusForTesting(.connecting)

        let sendTask = Task { @MainActor in
            do {
                try await wsClient.send(.stopSession(), sessionId: "session-a")
                return "sent"
            } catch let error as FocusedSessionBindingError {
                switch error {
                case .boundSessionChanged(let requestedSessionId, let boundSessionId):
                    return "bound_changed:\(requestedSessionId):\(boundSessionId)"
                case .rebindUnavailable:
                    return "wrong_binding_error"
                }
            } catch {
                return "unexpected:\(error.localizedDescription)"
            }
        }

        let sendIsWaiting = await waitForMainActorCondition(
            timeout: .milliseconds(300),
            poll: .milliseconds(5)
        ) {
            wsClient.connectionWaiterCountForTesting == 1
        }
        guard sendIsWaiting else {
            wsClient._setStatusForTesting(.disconnected)
            _ = await sendTask.value
            Issue.record("Send did not suspend in waitForConnection")
            return
        }

        wsClient.setStreamURL(
            URL(string: "wss://localhost/workspaces/w1/sessions/session-b/stream"),
            sessionId: "session-b",
            workspaceId: "w1"
        )
        wsClient._setStatusForTesting(.connected)

        let outcome = await sendTask.value
        #expect(outcome == "bound_changed:session-a:session-b")
        #expect(emittedTypes.isEmpty)
    }

}

private enum BindingGuardCommand: CaseIterable {
    case prompt
    case steer
    case followUp
    case stop
    case stopSession

    @MainActor
    func send(using connection: ServerConnection, sessionId: String) async throws {
        switch self {
        case .prompt:
            try await connection.sendPrompt("prompt", sessionIdOverride: sessionId)
        case .steer:
            try await connection.sendSteer("steer", sessionIdOverride: sessionId)
        case .followUp:
            try await connection.sendFollowUp("follow up", sessionIdOverride: sessionId)
        case .stop:
            try await connection.sendStop(sessionIdOverride: sessionId)
        case .stopSession:
            try await connection.sendStopSession(sessionIdOverride: sessionId)
        }
    }
}
