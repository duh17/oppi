import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session trace runtime wiring")
struct MacSessionTraceStoreRuntimeTests {
    @Test func windowStoreUsesSharedManagerAndUnixSocketAdapter() async throws {
        let transport = RecordingLocalHTTPTransport(response: Self.json("{}"))
        let client = Self.makeClient(transport: transport)
        let store = MacSessionTraceStore()
        let target = Self.makeTarget()
        store.select(target)

        await store.installSessionRuntimeForTesting(client: client)

        let manager = try #require(store._chatSessionManagerForTesting)
        let adapter = try #require(store._runtimeAdapterForTesting)
        #expect(manager.sessionId == target.sessionId)
        #expect(manager.historyPort as? MacChatSessionRuntimeAdapter === adapter)
        #expect(manager.focusedStreamPort as? MacChatSessionRuntimeAdapter === adapter)
        #expect(manager.effectsStatePort as? MacChatSessionRuntimeAdapter === adapter)
        #expect(adapter.transportPath == .unix)
        #expect(store.toolOutputStore === manager.reducer.toolOutputStore)
        #expect(store.items.map(\.id) == manager.reducer.items.map(\.id))
        #expect(await adapter.client.socketPath == "/tmp/oppi-mac-runtime.sock")
        #expect(await transport.requests.isEmpty)
    }

    @Test func historyItemsComeFromManagerReducerNotASecondTimeline() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let store = MacSessionTraceStore()
        let target = Self.makeTarget()
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)

        let manager = try #require(store._chatSessionManagerForTesting)
        manager._fetchSessionTraceForTesting = { _, _ in
            (
                target.summary.session,
                [
                    TraceEvent(
                        id: "event-hello",
                        type: .user,
                        timestamp: "2026-06-28T20:00:00Z",
                        text: "Hello from history"
                    ),
                ]
            )
        }

        #expect(await manager.forceHistoryReload())
        #expect(store.items.contains { item in
            if case .userMessage(_, let text, _, _) = item {
                return text.contains("Hello from history")
            }
            return false
        })
        #expect(store.items.map(\.id) == manager.reducer.items.map(\.id))
        #expect(store.toolOutputStore === manager.reducer.toolOutputStore)
    }

    @Test func composerStopUsesAdapterUnixSocketSendNotASecondWebSocket() async throws {
        let transport = RecordingLocalHTTPTransport(response: Self.json(#"{"messages":[]}"#))
        let client = Self.makeClient(transport: transport)
        let store = MacSessionTraceStore()
        let target = Self.makeTarget(status: .busy)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)
        defer { store.clearSelection() }

        let manager = try #require(store._chatSessionManagerForTesting)
        let adapter = try #require(store._runtimeAdapterForTesting)
        let held = HeldConnectedStream(session: target.summary.session)
        manager._loadHistoryForTesting = { _, _ in nil }
        manager._streamEventsForTesting = held.makeStream
        var sent: ClientMessage?
        adapter._sendClientMessageForTesting = { message in
            sent = message
            return true
        }

        await store.stopTurn(target: target, client: client)

        switch sent {
        case .stop:
            break
        case .stopSession:
            Issue.record("Composer stop must not send stopSession")
        default:
            Issue.record("Expected ClientMessage.stop on the adapter, got \(String(describing: sent))")
        }
        #expect(await transport.requests.allSatisfy { !$0.path.contains("/command") })
        #expect(adapter.transportPath == .unix)
        #expect(!store.isStoppingTurn)
        held.finish()
    }

    @Test func commandsDoNotFallBackToHTTPWhenFocusedStreamIsUnbound() async throws {
        let transport = RecordingLocalHTTPTransport(response: Self.json(#"{"messages":[]}"#))
        let client = Self.makeClient(transport: transport)
        let store = MacSessionTraceStore()
        let target = Self.makeTarget(status: .busy)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)
        defer { store.clearSelection() }

        let manager = try #require(store._chatSessionManagerForTesting)
        manager._loadHistoryForTesting = { _, _ in nil }
        manager._streamEventsForTesting = { _ in
            AsyncStream { _ in }
        }
        store._commandAckTimeoutForTesting = .milliseconds(20)

        await store.stopTurn(target: target, client: client)

        #expect(store.lastError == ChatSessionFocusedStreamBindError.timedOut.errorDescription)
        #expect(await transport.requests.allSatisfy { !$0.path.contains("/command") })
        #expect(!store.isStoppingTurn)
    }

    @Test func queueRefreshDoesNotFallBackToHTTPWhenFocusedStreamIsUnbound() async throws {
        let transport = RecordingLocalHTTPTransport(response: Self.json(#"{"messages":[]}"#))
        let client = Self.makeClient(transport: transport)
        let store = MacSessionTraceStore()
        let target = Self.makeTarget(status: .busy)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)
        defer { store.clearSelection() }

        let manager = try #require(store._chatSessionManagerForTesting)
        manager._loadHistoryForTesting = { _, _ in nil }
        manager._streamEventsForTesting = { _ in
            AsyncStream { _ in }
        }
        store._commandAckTimeoutForTesting = .milliseconds(20)

        await store.refreshQueue(target: target, client: client)

        #expect(store.messageQueueError == ChatSessionFocusedStreamBindError.timedOut.errorDescription)
        #expect(await transport.requests.allSatisfy { !$0.path.contains("/command") })
    }

    @Test func loadStartsTheSameConnectLoopAsLocalConfig() async throws {
        let transport = RecordingLocalHTTPTransport(response: Self.json("{}"))
        let client = Self.makeClient(transport: transport)
        let store = MacSessionTraceStore()
        let target = Self.makeTarget()
        defer { store.clearSelection() }

        await store.load(target: target, client: client)

        #expect(store._sessionRuntimeLoopRunningForTesting)
        #expect(store._chatSessionManagerForTesting?.sessionId == target.sessionId)
        #expect(await transport.requests.allSatisfy { !$0.path.contains("/command") })
    }

    @Test func autoReconnectReinvokesConnectAfterStreamEnds() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let store = MacSessionTraceStore()
        let target = Self.makeTarget()
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)
        defer { store.clearSelection() }

        let manager = try #require(store._chatSessionManagerForTesting)
        let streams = ScriptedMacStreamFactory(session: target.summary.session)
        manager._loadHistoryForTesting = { _, _ in nil }
        manager._streamEventsForTesting = streams.makeStream
        store.startSessionRuntimeLoopForTesting()

        #expect(await streams.waitForCreated(1))
        streams.yieldConnected(index: 0)
        #expect(await waitUntil { manager.entryState == .streaming })
        streams.finish(index: 0)

        #expect(await streams.waitForCreated(2))
        #expect(manager.connectionGeneration >= 1)
        streams.finish(index: 1)
    }

    @Test func ensureFocusedStreamConnectingDoesNotResetWhileAwaitingConnected() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let store = MacSessionTraceStore()
        let target = Self.makeTarget()
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)
        defer { store.clearSelection() }

        let manager = try #require(store._chatSessionManagerForTesting)
        manager._loadHistoryForTesting = { _, _ in nil }
        manager._streamEventsForTesting = { _ in
            AsyncStream { _ in }
        }
        store.startSessionRuntimeLoopForTesting()

        #expect(await waitUntil {
            if case .awaitingConnected = manager.entryState { return true }
            return false
        })

        manager.reducer.appendUserMessage("keep me")
        let generation = manager.connectionGeneration
        store.ensureFocusedStreamConnectingForTesting()

        #expect(manager.connectionGeneration == generation)
        #expect(Self.itemsContainUserText(store, "keep me"))
        if case .awaitingConnected = manager.entryState {
            // Connecting must keep going without a generation bump.
        } else {
            Issue.record("Expected awaitingConnected, got \(manager.entryState)")
        }
    }

    @Test func loadSelectedFromLocalConfigSkipsQueueRefreshForStoppedSession() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let store = MacSessionTraceStore()
        let target = Self.makeTarget(status: .stopped)
        store.select(target)
        store._commandAckTimeoutForTesting = .milliseconds(50)
        defer { store.clearSelection() }

        let started = ContinuousClock.now
        await store.loadSelectedFromLocalConfigForTesting(client: client)
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(1))
        #expect(store.messageQueueError == nil)
        #expect(store.lastError != ChatSessionFocusedStreamBindError.timedOut.errorDescription)
    }

    @Test func refreshQueueSkipsHistoryOnlySessions() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let store = MacSessionTraceStore()
        let target = Self.makeTarget(status: .stopped)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)
        store._commandAckTimeoutForTesting = .milliseconds(50)
        defer { store.clearSelection() }

        await store.refreshQueue(target: target, client: client)

        #expect(store.messageQueueError == nil)
    }

    @Test func waitUntilStreamingTimesOutWhileIdle() async {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let adapter = MacChatSessionRuntimeAdapter(
            client: client,
            token: await client.ownerToken()
        )
        let manager = ChatSessionManager(
            sessionId: "session-runtime",
            workspaceIdHint: "workspace-runtime",
            adapter: adapter
        )
        defer { manager.cleanup() }

        await #expect(throws: ChatSessionFocusedStreamBindError.timedOut) {
            try await manager.waitUntilStreaming(timeout: .milliseconds(20))
        }
        #expect(manager.entryState == .idle)
    }

    @Test func waitUntilStreamingSucceedsAfterConnected() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let adapter = MacChatSessionRuntimeAdapter(
            client: client,
            token: await client.ownerToken()
        )
        let manager = ChatSessionManager(
            sessionId: "session-runtime",
            workspaceIdHint: "workspace-runtime",
            adapter: adapter
        )
        let session = Self.makeTarget().summary.session
        let held = HeldConnectedStream(session: session)
        manager._loadHistoryForTesting = { _, _ in nil }
        manager._streamEventsForTesting = held.makeStream
        let connectTask = Task { await manager.connect() }
        defer {
            held.finish()
            manager.cleanup()
            connectTask.cancel()
        }

        try await manager.waitUntilStreaming(timeout: .seconds(1))
        #expect(manager.entryState == .streaming)
    }

    @Test func waitUntilStreamingFailsImmediatelyWhenStopped() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let adapter = MacChatSessionRuntimeAdapter(
            client: client,
            token: await client.ownerToken()
        )
        let target = Self.makeTarget(status: .stopped)
        adapter.upsert(target.summary.session)
        adapter.setActiveSessionId(target.sessionId)
        let manager = ChatSessionManager(
            sessionId: target.sessionId,
            workspaceIdHint: target.workspaceId,
            adapter: adapter
        )
        defer { manager.cleanup() }
        manager._loadHistoryForTesting = { _, _ in nil }
        manager._streamEventsForTesting = { _ in
            Issue.record("Stopped session must not open a stream")
            return AsyncStream { $0.finish() }
        }

        await manager.connect()
        #expect(manager.entryState == .stopped(historyLoaded: true))

        let started = ContinuousClock.now
        await #expect(throws: ChatSessionFocusedStreamBindError.timedOut) {
            try await manager.waitUntilStreaming(timeout: .seconds(8))
        }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func waitUntilStreamingFailsWhenSessionBecomesStopped() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let adapter = MacChatSessionRuntimeAdapter(
            client: client,
            token: await client.ownerToken()
        )
        let target = Self.makeTarget(status: .stopped)
        adapter.upsert(target.summary.session)
        adapter.setActiveSessionId(target.sessionId)
        let manager = ChatSessionManager(
            sessionId: target.sessionId,
            workspaceIdHint: target.workspaceId,
            adapter: adapter
        )
        defer { manager.cleanup() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let waitTask = Task {
            try await manager.waitUntilStreaming(timeout: .seconds(8))
        }
        let connectTask = Task { await manager.connect() }
        let started = ContinuousClock.now
        let result = await waitTask.result
        await connectTask.value

        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(throws: ChatSessionFocusedStreamBindError.timedOut) {
            try result.get()
        }
        #expect(manager.entryState == .stopped(historyLoaded: true))
    }

    @Test func adapterLiveEffectsUpdateStoreAskState() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let store = MacSessionTraceStore()
        let target = Self.makeTarget(status: .busy)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)

        let adapter = try #require(store._runtimeAdapterForTesting)
        adapter.handleActiveSessionUI(
            .extensionUIRequest(
                ExtensionUIRequest(
                    id: "ask-runtime",
                    sessionId: target.sessionId,
                    method: "ask",
                    askQuestions: [
                        AskQuestion(
                            id: "q1",
                            question: "Continue?",
                            options: [AskOption(value: "yes", label: "Yes")],
                            multiSelect: false
                        ),
                    ]
                )
            ),
            sessionId: target.sessionId,
            storeResult: .notHandled
        )

        #expect(store.currentAskRequest?.id == "ask-runtime")
        #expect(store.currentAskRequest?.questions.first?.question == "Continue?")
    }

    @Test func overlappingLoadsCannotLeaveSessionBSelectedWithManagerA() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let store = MacSessionTraceStore()
        defer { store.clearSelection() }
        let targetA = Self.makeTarget(sessionId: "session-a")
        let targetB = Self.makeTarget(sessionId: "session-b")
        let gate = InstallGate()
        store._sessionRuntimeInstallGateForTesting = {
            guard store.selectedTarget?.sessionId == targetA.sessionId else { return }
            await gate.hold()
        }

        store.select(targetA)
        let loadA = Task {
            await store.load(target: targetA, client: client)
        }
        await gate.waitUntilEntered()
        #expect(store.isLoading)

        store.select(targetB)
        #expect(!store.isLoading)
        #expect(store.selectedTarget?.sessionId == targetB.sessionId)

        await store.load(target: targetB, client: client)
        gate.release()
        await loadA.value

        #expect(store.selectedTarget?.sessionId == targetB.sessionId)
        #expect(store._chatSessionManagerForTesting?.sessionId == targetB.sessionId)
        #expect(store._runtimeAdapterForTesting?.session(id: targetB.sessionId)?.id == targetB.sessionId)
        #expect(store._chatSessionManagerForTesting?.sessionId != targetA.sessionId)
    }

    @Test func sendSuspendedDuringAttachmentUploadCannotEmitThroughNewSelection() async throws {
        let transport = DeferredAttachmentUploadTransport()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-mac-runtime.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacSessionTraceStore()
        let targetA = Self.makeTarget(sessionId: "session-a")
        let targetB = Self.makeTarget(sessionId: "session-b")
        let attachmentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-runtime-send-race-\(UUID().uuidString).txt")
        try Data("attachment from session A".utf8).write(to: attachmentURL, options: .atomic)
        defer {
            store.clearSelection()
            try? FileManager.default.removeItem(at: attachmentURL)
        }
        let attachment = try MacPendingAttachment(url: attachmentURL)
        var sentMessages: [ClientMessage] = []
        store._sendLiveMessageForTesting = { message in
            sentMessages.append(message)
            return true
        }

        store.select(targetA)
        await store.installSessionRuntimeForTesting(client: client)
        let sendA = Task {
            await store.sendPrompt(
                "Send from A",
                attachments: [attachment],
                target: targetA,
                client: client
            )
        }
        await transport.waitUntilCreateStarted()
        #expect(store.isPreparingAttachments)

        store.select(targetB)
        await store.installSessionRuntimeForTesting(client: client)
        #expect(store._chatSessionManagerForTesting?.sessionId == targetB.sessionId)

        await transport.releaseCreate()
        let didSend = await sendA.value

        #expect(!didSend)
        #expect(sentMessages.isEmpty)
        #expect(store.selectedTarget?.sessionId == targetB.sessionId)
        #expect(store._chatSessionManagerForTesting?.sessionId == targetB.sessionId)
        #expect(!store.isPreparingAttachments)
        #expect(await transport.requests.map(\.path) == [
            "/workspaces/workspace-runtime/sessions/session-a/attachments",
        ])
    }

    @Test func controlSessionSendUploadsAttachmentsThroughControlRouteFamily() async throws {
        let transport = ControlAttachmentUploadTransport()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-mac-runtime.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacSessionTraceStore()
        let target = Self.makeControlTarget()
        let attachmentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-control-send-\(UUID().uuidString).txt")
        try Data("control attachment".utf8).write(to: attachmentURL, options: .atomic)
        defer {
            store.clearSelection()
            try? FileManager.default.removeItem(at: attachmentURL)
        }
        let attachment = try MacPendingAttachment(url: attachmentURL)
        var sentMessage: ClientMessage?
        store._sendLiveMessageForTesting = { message in
            sentMessage = message
            return true
        }
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)

        let didSend = await store.sendPrompt(
            "Review this",
            attachments: [attachment],
            target: target,
            client: client
        )

        #expect(didSend)
        #expect(await transport.requests.map(\.path) == [
            "/control-sessions/session-control/attachments",
            "/control-sessions/session-control/attachments/upload-control/content",
        ])
        guard case .prompt(_, let attachments, _, _, _) = sentMessage else {
            Issue.record("Expected a prompt with the uploaded attachment")
            return
        }
        #expect(attachments?.map { $0.id } == ["upload-control"])
    }

    @Test func failedSetModelDoesNotDoubleWriteTimeline() async throws {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let store = MacSessionTraceStore()
        let target = Self.makeTarget()
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)

        let requestIdBox = CommandRequestIdBox()
        store._sendLiveMessageForTesting = { message in
            if case .setModel(_, _, let requestId, _) = message, let requestId {
                requestIdBox.complete(requestId)
            }
            return true
        }

        await store.setModel(Self.gpt, target: target, client: client)
        let requestId = await requestIdBox.value()
        let adapter = try #require(store._runtimeAdapterForTesting)
        let manager = try #require(store._chatSessionManagerForTesting)
        let errorText = "model rejected"

        let consumed = adapter.handleCommandResult(
            command: "set_model",
            requestId: requestId,
            success: false,
            data: nil,
            error: errorText,
            sessionId: target.sessionId
        )
        if !consumed {
            manager.coalescer.receive(
                .commandResult(
                    sessionId: target.sessionId,
                    command: "set_model",
                    requestId: requestId,
                    success: false,
                    data: nil,
                    error: errorText
                )
            )
            manager.coalescer.flushNow()
        }
        adapter.handleActiveSessionUI(
            .commandResult(
                command: "set_model",
                requestId: requestId,
                success: false,
                data: nil,
                error: errorText
            ),
            sessionId: target.sessionId,
            storeResult: .notHandled
        )

        let failureItems = store.items.filter { item in
            switch item {
            case .systemEvent(_, let message), .error(_, let message):
                return message.localizedCaseInsensitiveContains("model")
            default:
                return false
            }
        }
        #expect(consumed)
        #expect(failureItems.count == 1)
        #expect(store.lastError == errorText)
    }

    @Test func clearingSelectionTearsDownManagerAndAdapter() async {
        let client = Self.makeClient(
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
        let store = MacSessionTraceStore()
        store.select(Self.makeTarget())
        await store.installSessionRuntimeForTesting(client: client)
        #expect(store._chatSessionManagerForTesting != nil)

        store.clearSelection()

        #expect(store._chatSessionManagerForTesting == nil)
        #expect(store._runtimeAdapterForTesting == nil)
        #expect(store.items.isEmpty)
        #expect(!store.isStreaming)
        #expect(!store.isLoading)
    }

    private static func json(_ body: String) -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
    }

    private static func makeClient(
        transport: RecordingLocalHTTPTransport
    ) -> MacWorkspaceClient {
        MacWorkspaceClient(
            socketPath: "/tmp/oppi-mac-runtime.sock",
            token: "sk_owner",
            transport: transport
        )
    }

    private static let gpt = ModelInfo(
        id: "gpt-5.5",
        name: "GPT 5.5",
        provider: "openai",
        contextWindow: 200_000
    )

    private static func itemsContainUserText(_ store: MacSessionTraceStore, _ text: String) -> Bool {
        store.items.contains { item in
            if case .userMessage(_, let value, _, _) = item {
                return value.contains(text)
            }
            return false
        }
    }

    private static func makeTarget(
        sessionId: String = "session-runtime",
        status: SessionStatus = .ready
    ) -> MacSelectedSessionTarget {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(
            id: sessionId,
            workspaceId: "workspace-runtime",
            workspaceName: "Workspace",
            status: status,
            createdAt: now,
            lastActivity: now,
            model: "provider/model",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            firstMessage: "Hello"
        )
        return MacSelectedSessionTarget(
            workspaceId: "workspace-runtime",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }

    private static func makeControlTarget() -> MacSelectedSessionTarget {
        var session = makeTarget(sessionId: "session-control").summary.session
        session.workspaceId = nil
        session.workspaceName = "Pi Control"
        session.control = ControlSessionMetadata(
            domain: .agents,
            intent: .revise,
            targetId: "agent-1",
            targetName: "Agent"
        )
        return MacSelectedSessionTarget(
            workspaceId: "",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }
}

@MainActor
private final class InstallGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var didEnter = false

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { continuation in
            if didEnter {
                continuation.resume()
            } else {
                enteredContinuation = continuation
            }
        }
    }

    func hold() async {
        didEnter = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            holdContinuation = continuation
        }
    }

    func release() {
        holdContinuation?.resume()
        holdContinuation = nil
    }
}

private actor DeferredAttachmentUploadTransport: MacLocalHTTPPerforming {
    private(set) var requests: [MacLocalHTTPRequest] = []
    private var createStartedContinuation: CheckedContinuation<Void, Never>?
    private var releaseCreateContinuation: CheckedContinuation<Void, Never>?
    private var didStartCreate = false
    private var didReleaseCreate = false

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        if request.method == "POST",
           request.path == "/workspaces/workspace-runtime/sessions/session-a/attachments" {
            didStartCreate = true
            createStartedContinuation?.resume()
            createStartedContinuation = nil
            if !didReleaseCreate {
                await withCheckedContinuation { continuation in
                    releaseCreateContinuation = continuation
                }
            }
            return Self.response(
                #"{"uploadId":"upload-a","contentUrl":"/content","maxFileBytes":1024,"expiresAt":1800000000}"#
            )
        }
        if request.method == "PUT",
           request.path == "/workspaces/workspace-runtime/sessions/session-a/attachments/upload-a/content" {
            return Self.response(
                #"{"attachment":{"type":"file","id":"upload-a","source":"upload","name":"oppi-runtime-send-race.txt","mimeType":"text/plain","sizeBytes":25,"sha256":null,"kind":"text","workspacePath":".oppi/attachments/upload-a/oppi-runtime-send-race.txt"}}"#
            )
        }
        return Self.response("{}")
    }

    func waitUntilCreateStarted() async {
        if didStartCreate { return }
        await withCheckedContinuation { continuation in
            if didStartCreate {
                continuation.resume()
            } else {
                createStartedContinuation = continuation
            }
        }
    }

    func releaseCreate() {
        didReleaseCreate = true
        releaseCreateContinuation?.resume()
        releaseCreateContinuation = nil
    }

    private static func response(_ body: String) -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
    }
}

private actor ControlAttachmentUploadTransport: MacLocalHTTPPerforming {
    private(set) var requests: [MacLocalHTTPRequest] = []

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        if request.method == "POST" {
            return Self.response(
                #"{"uploadId":"upload-control","contentUrl":"/control-sessions/session-control/attachments/upload-control/content","maxFileBytes":1024,"expiresAt":1800000000}"#
            )
        }
        return Self.response(
            #"{"attachment":{"type":"chat_attachment","id":"upload-control","source":"upload","name":"control.txt","mimeType":"text/plain","sizeBytes":18,"sha256":null,"kind":"text","workspacePath":".pi/attachments/session-control/turn/control.txt"}}"#
        )
    }

    private static func response(_ body: String) -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
    }
}

@MainActor
private final class CommandRequestIdBox {
    private var requestId: String?
    private var continuation: CheckedContinuation<String, Never>?

    func complete(_ requestId: String) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: requestId)
        } else {
            self.requestId = requestId
        }
    }

    func value() async -> String {
        if let requestId {
            return requestId
        }
        return await withCheckedContinuation { continuation in
            if let requestId {
                continuation.resume(returning: requestId)
            } else {
                self.continuation = continuation
            }
        }
    }
}

@MainActor
private final class HeldConnectedStream {
    private let session: Session
    private var continuation: AsyncStream<SessionStreamEvent>.Continuation?

    init(session: Session) {
        self.session = session
    }

    func makeStream(sessionId: String) -> AsyncStream<SessionStreamEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(
                SessionStreamEvent(
                    sessionId: sessionId,
                    message: .connected(session: session),
                    meta: nil
                )
            )
        }
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
    }
    return predicate()
}

@MainActor
private final class ScriptedMacStreamFactory {
    private let session: Session
    private(set) var createCount = 0
    private var continuations: [Int: AsyncStream<SessionStreamEvent>.Continuation] = [:]

    init(session: Session) {
        self.session = session
    }

    func makeStream(sessionId: String) -> AsyncStream<SessionStreamEvent> {
        let index = createCount
        createCount += 1
        return AsyncStream { continuation in
            self.continuations[index] = continuation
        }
    }

    func waitForCreated(_ count: Int, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if createCount >= count { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return createCount >= count
    }

    func yieldConnected(index: Int) {
        continuations[index]?.yield(
            SessionStreamEvent(
                sessionId: session.id,
                message: .connected(session: session),
                meta: nil
            )
        )
    }

    func finish(index: Int) {
        continuations[index]?.finish()
        continuations[index] = nil
    }
}
