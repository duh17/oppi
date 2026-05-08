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

    @Test func prepareForSessionReentryRestoresFocusWithoutOpeningLegacyStream() {
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
                "Re-entry should not reopen legacy /stream; the chat connect task owns the bound session stream")
        #expect(conn.wsClient?.status == .disconnected)
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

        let (_, continuation) = AsyncStream<ServerMessage>.makeStream()
        conn.sessionContinuations["s1"] = continuation

        conn.disconnectStream()

        #expect(conn.streamConsumptionTask == nil,
                "Should nil out consumption task")
        #expect(conn.sessionContinuations.isEmpty,
                "Should clear all session continuations")
    }

    // MARK: - handleStreamReconnected re-subscribes

    @Test func streamConnectedMessageTriggersResubscribe() {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        var yieldedToSession = false
        let stream = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }
        let consumeTask = Task {
            for await _ in stream {
                await MainActor.run { yieldedToSession = true }
            }
        }

        let streamMsg = StreamMessage(
            sessionId: nil,
            streamSeq: nil,
            seq: nil,
            currentSeq: nil,
            message: .streamConnected(userName: "test", asrAvailable: false)
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
        let stream = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }

        let consumeTask = Task {
            for await msg in stream {
                await MainActor.run { receivedMessages.append(msg) }
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
            streamSeq: 1,
            seq: nil,
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
            streamSeq: 1,
            seq: nil,
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
            streamSeq: 1,
            seq: nil,
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

    @Test func routeStreamMessageUsesStreamSeqWhenSessionSeqIsAbsent() async {
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
            streamSeq: 77,
            seq: nil,
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

    @Test func workspaceStreamAdvancesCursorForSessionScopedFrames() {
        let (conn, _) = makeTestConnection()
        conn._setWorkspaceStreamWorkspaceIdForTesting("w1")

        let perm = PermissionRequest(
            id: "p-workspace",
            sessionId: "s-workspace",
            tool: "bash",
            input: [:],
            displaySummary: "bash: test",
            reason: "Needs approval",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )

        conn._routeWorkspaceStreamMessageForTesting(StreamFrameEvent(
            sessionId: "s-workspace",
            message: .permissionRequest(perm),
            meta: InboundStreamMeta(seq: 12, currentSeq: 12)
        ))

        #expect(conn._workspaceStreamLastSeqForTesting(workspaceId: "w1") == 12)
        #expect(conn.permissionStore.pending.first?.id == "p-workspace")

        conn._routeWorkspaceStreamMessageForTesting(StreamFrameEvent(
            sessionId: "s-workspace",
            message: .permissionRequest(perm),
            meta: InboundStreamMeta(seq: 8, currentSeq: 12)
        ))

        #expect(conn._workspaceStreamLastSeqForTesting(workspaceId: "w1") == 12)
        #expect(conn.permissionStore.pending.count == 1)
    }

    @Test func workspaceStreamDefersPermissionExpiryWhenLiveSessionConsumerExists() {
        let (conn, _) = makeTestConnection()
        conn._setWorkspaceStreamWorkspaceIdForTesting("w1")

        let perm = PermissionRequest(
            id: "p-live",
            sessionId: "s-live",
            tool: "bash",
            input: [:],
            displaySummary: "bash: test",
            reason: "Needs approval",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        conn.permissionStore.add(perm)

        let stream = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s-live"] = continuation
        }
        _ = stream

        conn._routeWorkspaceStreamMessageForTesting(StreamFrameEvent(
            sessionId: "s-live",
            message: .permissionExpired(id: "p-live", reason: "Approval timeout"),
            meta: InboundStreamMeta(seq: 13, currentSeq: 13)
        ))

        #expect(conn._workspaceStreamLastSeqForTesting(workspaceId: "w1") == 13)
        #expect(conn.permissionStore.pending.first?.id == "p-live")

        conn.sessionEventContinuations["s-live"]?.finish()
        conn.sessionEventContinuations.removeValue(forKey: "s-live")
    }

    // MARK: - reconnectIfNeeded restarts dead stream

    @Test func reconnectIfNeededRestartsDeadStream() async {
        let (conn, _) = makeTestConnection()

        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        #expect(conn.streamConsumptionTask == nil)

        await conn.reconnectIfNeeded()

        #expect(conn.streamConsumptionTask != nil,
                "reconnectIfNeeded should restart a dead stream")
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

    @Test func routeStreamMessageResolvesSubscribeWaiterBeforePerSessionRouting() async {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        let pending = PendingCommand(command: "subscribe", requestId: "req-1")
        conn.commands.registerCommand(pending)

        _ = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }

        let streamMsg = StreamMessage(
            sessionId: "s1",
            streamSeq: 1,
            seq: nil,
            currentSeq: nil,
            message: .commandResult(
                command: "subscribe", requestId: "req-1",
                success: true, data: nil, error: nil
            )
        )
        conn.routeStreamMessage(streamMsg)

        let result = try? await pending.waiter.wait()
        #expect(result != nil, "Subscribe waiter should be resolved eagerly by routeStreamMessage")
    }

    @Test func routeStreamMessageResolvesGetQueueWaiterEagerly() async {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        let pending = PendingCommand(command: "get_queue", requestId: "req-q")
        conn.commands.registerCommand(pending)

        // Per-session stream exists but nobody is consuming it — same as
        // in streamSession() where get_queue blocks before returning.
        _ = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }

        let streamMsg = StreamMessage(
            sessionId: "s1",
            streamSeq: 1,
            seq: nil,
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

        _ = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }

        let streamMsg = StreamMessage(
            sessionId: "s1",
            streamSeq: 1,
            seq: nil,
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

    @Test func streamSessionRequiresRequiredSplitCapabilities() async {
        let (conn, _) = makeTestConnection(sessionId: "s1")
        conn.wsClient?._setStatusForTesting(.connected)
        conn.setSplitStreamCapabilitiesForTesting(sessionProjection: false)

        let stream = await conn.streamSession("s1", workspaceId: "w1")

        #expect(stream == nil)
        #expect(conn.extensionToast == nil)
        #expect(conn.focusedSessionStreamEndpointKind == "legacy")
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
        #expect(conn.subscriptionRegistry.desiredLevel(for: "s1") == .full)
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
