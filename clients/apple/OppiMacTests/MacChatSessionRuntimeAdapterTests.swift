import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac chat session runtime adapter")
struct MacChatSessionRuntimeAdapterTests {
    @Test func historyFetchUsesOwnerUnixSocketNotHTTPS() async throws {
        let transport = RecordingLocalHTTPTransport(response: .json(Self.tracePageJSON))
        let adapter = Self.makeAdapter(transport: transport)

        let snapshot = try await adapter.fetchLatestTrace(
            scope: .workspace("ws-1"),
            sessionId: "sess-1",
            previewBytes: 4_096
        )

        let request = try #require(await transport.requests.first)
        #expect(await adapter.client.socketPath == "/tmp/oppi-mac-chat.sock")
        #expect(request.method == "GET")
        #expect(request.path.hasPrefix("/workspaces/ws-1/sessions/sess-1/trace-page?"))
        #expect(request.path.contains("presentation=mobile"))
        #expect(request.path.contains("previewBytes=4096"))
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("wss"))
        #expect(!request.path.contains("sk_"))
        #expect(snapshot.session.id == "sess-1")
        #expect(snapshot.trace.map(\.id) == ["event-1"])
        #expect(await transport.requests.count == 1)
    }

    @Test func olderTracePageUsesCursorOnOwnerUnixSocket() async throws {
        let transport = RecordingLocalHTTPTransport(response: .json(Self.tracePageJSON))
        let adapter = Self.makeAdapter(transport: transport)

        _ = try await adapter.fetchOlderTracePage(
            scope: .workspace("ws-1"),
            sessionId: "sess-1",
            cursor: "older-1",
            previewBytes: 4_096
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path.contains("/workspaces/ws-1/sessions/sess-1/trace-page?"))
        #expect(request.path.contains("cursor=older-1"))
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("sk_"))
    }

    @Test func aroundTracePageUsesEntryIdOnOwnerUnixSocket() async throws {
        let transport = RecordingLocalHTTPTransport(response: .json(Self.tracePageJSON))
        let adapter = Self.makeAdapter(transport: transport)

        _ = try await adapter.fetchTracePageAround(
            scope: .workspace("ws-1"),
            sessionId: "sess-1",
            entryId: "event-1",
            previewBytes: 4_096
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path.contains("/workspaces/ws-1/sessions/sess-1/trace-page?"))
        #expect(request.path.contains("aroundEntryId=event-1"))
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("sk_"))
    }

    @Test func catchUpUsesEventsOnOwnerUnixSocket() async throws {
        let transport = RecordingLocalHTTPTransport(response: .json(Self.catchUpJSON))
        let adapter = Self.makeAdapter(transport: transport)

        let response = try await adapter.fetchCatchUp(
            scope: .workspace("ws-1"),
            sessionId: "sess-1",
            since: 12
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/workspaces/ws-1/sessions/sess-1/events?since=12")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("wss"))
        #expect(!request.path.contains("sk_"))
        #expect(response.currentSeq == 13)
        #expect(response.catchUpComplete)
        #expect(response.events.map(\.seq) == [13])
    }

    @Test func focusedStreamUsesOwnerUnixSocketNotWSS() {
        let adapter = Self.makeAdapter(
            transport: RecordingLocalHTTPTransport(response: .json("{}"))
        )

        let transport = adapter.makeFocusedStreamTransport(
            workspaceId: "ws-1",
            sessionId: "sess-1"
        )

        #expect(transport.socketPath == "/tmp/oppi-mac-chat.sock")
        #expect(transport.path == MacUnixWebSocketTransport.focusedSessionPath(
            workspaceId: "ws-1",
            sessionId: "sess-1"
        ))
        #expect(transport.path == "/workspaces/ws-1/sessions/sess-1/stream")
        #expect(transport.headers["Authorization"] == "Bearer sk_owner")
        #expect(!transport.socketPath.contains("https"))
        #expect(!transport.path.contains("https"))
        #expect(!transport.path.contains("wss"))
        #expect(!transport.path.contains("sk_"))
    }

    @Test func permanentFocusedStreamRejectionsAreTerminalButServerFailureCanRetry() {
        #expect(MacChatSessionRuntimeAdapter.isTerminalStreamConnectError(
            WebSocketTransportError.upgradeRejected(statusCode: 401)
        ))
        #expect(MacChatSessionRuntimeAdapter.isTerminalStreamConnectError(
            WebSocketTransportError.upgradeRejected(statusCode: 403)
        ))
        #expect(MacChatSessionRuntimeAdapter.isTerminalStreamConnectError(
            WebSocketTransportError.upgradeRejected(statusCode: 404)
        ))
        #expect(MacChatSessionRuntimeAdapter.isTerminalStreamConnectError(
            WebSocketTransportError.upgradeRejected(statusCode: 405)
        ))
        #expect(!MacChatSessionRuntimeAdapter.isTerminalStreamConnectError(
            WebSocketTransportError.upgradeRejected(statusCode: 503)
        ))
        #expect(!MacChatSessionRuntimeAdapter.isTerminalStreamConnectError(
            WebSocketTransportError.handshakeFailed("Network is down")
        ))
    }

    @Test func terminalStreamErrorSurvivesConcurrentHistoryReplay() {
        let reducer = TimelineReducer()
        let replayID = UUID()
        reducer.beginHistoryReplayBuffer(id: replayID)
        reducer.process(.error(
            sessionId: "sess-1",
            message: "Session stream unavailable"
        ))

        reducer.applyTraceWithLiveReplay([
            TraceEvent(
                id: "history-user",
                type: .user,
                timestamp: "2026-08-29T12:00:00Z",
                text: "History remains visible"
            ),
        ], replayID: replayID)

        #expect(!reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.contains { item in
            if case .userMessage(_, let text, _, _) = item {
                return text == "History remains visible"
            }
            return false
        })
        #expect(reducer.items.contains { item in
            if case .error(_, let message) = item {
                return message == "Session stream unavailable"
            }
            return false
        })
    }

    @Test func chatSessionManagerCanBeConstructedWithAdapter() {
        let adapter = Self.makeAdapter(
            transport: RecordingLocalHTTPTransport(response: .json("{}"))
        )

        let manager = ChatSessionManager(
            sessionId: "sess-1",
            workspaceIdHint: "ws-1",
            adapter: adapter
        )

        #expect(manager.sessionId == "sess-1")
        #expect(manager.historyPort as? MacChatSessionRuntimeAdapter === adapter)
        #expect(manager.focusedStreamPort as? MacChatSessionRuntimeAdapter === adapter)
        #expect(manager.effectsStatePort as? MacChatSessionRuntimeAdapter === adapter)
        #expect(manager.focusedStreamPort.transportPath == .unix)
        #expect(adapter.canFetchRemoteHistory)
        #expect(adapter.canFetchCatchUp)
    }

    @Test func liveRuntimeTelemetryRecordsUnixTransportWithoutTokenInURLs() async throws {
        let http = RecordingLocalHTTPTransport(response: .json(Self.tracePageJSON))
        let adapter = Self.makeAdapter(transport: http)
        let manager = ChatSessionManager(
            sessionId: "sess-1",
            workspaceIdHint: "ws-1",
            adapter: adapter
        )
        manager._streamEventsForTesting = { _ in
            AsyncStream { continuation in
                continuation.finish()
            }
        }
        defer { manager.cleanup() }

        await manager.connect()
        #expect(await manager.forceHistoryReload())

        let stream = adapter.makeFocusedStreamTransport(
            workspaceId: "ws-1",
            sessionId: "sess-1"
        )
        let transports = adapter._recordedTelemetryForTesting.compactMap { event -> String? in
            if case .freshContentLag(_, _, _, _, let transport) = event {
                return transport
            }
            return nil
        }
        let requests = await http.requests

        #expect(manager.focusedStreamPort.transportPath == .unix)
        #expect(adapter.transportPath == .unix)
        #expect(transports == [ConnectionTransportPath.unix.rawValue])
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.headers["Authorization"] == "Bearer sk_owner")
            #expect(!request.path.contains("sk_"))
            #expect(!request.path.contains("https"))
            #expect(!request.path.contains("wss"))
        }
        #expect(stream.headers["Authorization"] == "Bearer sk_owner")
        #expect(!stream.path.contains("sk_"))
        #expect(!stream.path.contains("https"))
        #expect(!stream.path.contains("wss"))
        #expect(!stream.socketPath.contains("sk_"))
    }

    @Test func historyCacheIsNoOp() async {
        let adapter = Self.makeAdapter(
            transport: RecordingLocalHTTPTransport(response: .json("{}"))
        )

        #expect(await adapter.loadCachedTrace(sessionId: "sess-1")?.eventCount == nil)
        await adapter.saveCachedTrace(sessionId: "sess-1", events: [], page: nil)
        #expect(await adapter.loadCachedTrace(sessionId: "sess-1")?.eventCount == nil)
        #expect(await adapter.client.socketPath == "/tmp/oppi-mac-chat.sock")
    }

    @Test func correlatedCommandResultsAreConsumed() {
        let adapter = Self.makeAdapter(
            transport: RecordingLocalHTTPTransport(response: .json("{}"))
        )

        #expect(adapter.handleCommandResult(
            command: "prompt",
            requestId: "prompt-1",
            success: true,
            data: nil,
            error: nil,
            sessionId: "sess-1"
        ))
        #expect(adapter.handleCommandResult(
            command: "steer",
            requestId: "steer-1",
            success: true,
            data: nil,
            error: nil,
            sessionId: "sess-1"
        ))
        #expect(adapter.handleCommandResult(
            command: "follow_up",
            requestId: "follow-1",
            success: true,
            data: nil,
            error: nil,
            sessionId: "sess-1"
        ))
        #expect(adapter.handleCommandResult(
            command: "get_queue",
            requestId: "queue-1",
            success: true,
            data: nil,
            error: nil,
            sessionId: "sess-1"
        ))
        #expect(adapter.handleCommandResult(
            command: "set_queue",
            requestId: "queue-2",
            success: false,
            data: nil,
            error: "conflict",
            sessionId: "sess-1"
        ))
        #expect(adapter.handleCommandResult(
            command: "set_model",
            requestId: "req-1",
            success: false,
            data: nil,
            error: "model rejected",
            sessionId: "sess-1"
        ))
        #expect(adapter.handleCommandResult(
            command: "set_thinking_level",
            requestId: "think-1",
            success: true,
            data: nil,
            error: nil,
            sessionId: "sess-1"
        ))
        #expect(adapter.handleCommandResult(
            command: "stop",
            requestId: "ack-1",
            success: true,
            data: nil,
            error: nil,
            sessionId: "sess-1"
        ))
    }

    @Test func uncorrelatedCommandResultIsNotConsumed() {
        let adapter = Self.makeAdapter(
            transport: RecordingLocalHTTPTransport(response: .json("{}"))
        )

        #expect(
            adapter.handleCommandResult(
                command: "bash",
                requestId: nil,
                success: false,
                data: nil,
                error: "Permission denied",
                sessionId: "sess-1"
            ) == false
        )
    }

    @Test func applyVoiceReplyModeDetailsPersistsSessionOverride() {
        let snapshot = captureVoiceReplyDefaults()
        defer { restoreVoiceReplyDefaults(snapshot) }

        let adapter = Self.makeAdapter(
            transport: RecordingLocalHTTPTransport(response: .json("{}"))
        )
        AppPreferenceStore.Voice.setReplyMode(.autoplay)
        adapter.applyVoiceReplyModeDetails(
            ["kind": "voice_reply_mode", "mode": "manual"],
            sessionId: "sess-1"
        )

        #expect(AppPreferenceStore.Voice.sessionReplyMode(for: "sess-1") == .manual)
        #expect(!AppPreferenceStore.Voice.shouldAutoplay(playbackBehavior: .playNow, sessionId: "sess-1"))
    }

    @Test func voiceReplyPlayerExtractsAutoplayWAVAndSkipsManual() {
        let snapshot = captureVoiceReplyDefaults()
        defer { restoreVoiceReplyDefaults(snapshot) }

        AppPreferenceStore.Voice.setReplyMode(.autoplay)
        AppPreferenceStore.Voice.setSessionReplyMode(nil, for: "sess-1")
        let wav = Data("RIFF".utf8)
        let playNow = AudioStreamMessage(
            id: "voice-1",
            event: .chunk,
            mimeType: "audio/wav",
            sampleRate: 24_000,
            channels: 1,
            chunkIndex: 0,
            audioBase64: wav.base64EncodedString(),
            text: nil,
            durationSeconds: 0.2,
            playbackBehavior: .playNow
        )
        let tapToPlay = AudioStreamMessage(
            id: "voice-2",
            event: .chunk,
            mimeType: "audio/wav",
            sampleRate: 24_000,
            channels: 1,
            chunkIndex: 0,
            audioBase64: wav.base64EncodedString(),
            text: nil,
            durationSeconds: 0.2,
            playbackBehavior: .tapToPlay
        )
        let pcm = AudioStreamMessage(
            id: "voice-3",
            event: .chunk,
            mimeType: "audio/pcm; codecs=s16le",
            sampleRate: 24_000,
            channels: 1,
            chunkIndex: 0,
            audioBase64: wav.base64EncodedString(),
            text: nil,
            durationSeconds: nil,
            playbackBehavior: .playNow
        )

        #expect(MacVoiceReplyPlayer.wavDataForPlayback(from: playNow, sessionId: "sess-1") == wav)
        #expect(MacVoiceReplyPlayer.wavDataForPlayback(from: tapToPlay, sessionId: "sess-1") == nil)
        #expect(MacVoiceReplyPlayer.wavDataForPlayback(from: pcm, sessionId: "sess-1") == nil)

        AppPreferenceStore.Voice.setSessionReplyMode(.manual, for: "sess-1")
        #expect(MacVoiceReplyPlayer.wavDataForPlayback(from: playNow, sessionId: "sess-1") == nil)
    }

    @Test func sendThrowsWhenFocusedStreamIsNotBound() async {
        let adapter = Self.makeAdapter(
            transport: RecordingLocalHTTPTransport(response: .json("{}"))
        )

        await #expect(throws: MacChatSessionRuntimeAdapterError.streamUnavailable) {
            try await adapter.send(.stop(requestId: "stop-1"))
        }
        #expect(adapter.transportPath == .unix)
    }

    @Test func sendUsesTestHookOnOwnerUnixSocketAdapter() async throws {
        let adapter = Self.makeAdapter(
            transport: RecordingLocalHTTPTransport(response: .json("{}"))
        )
        var sent: ClientMessage?
        adapter._sendClientMessageForTesting = { message in
            sent = message
            return true
        }

        try await adapter.send(.stop(requestId: "stop-2"))
        switch sent {
        case .stop(let requestId):
            #expect(requestId == "stop-2")
        default:
            Issue.record("Expected stop on the Unix-socket adapter, got \(String(describing: sent))")
        }
        #expect(await adapter.client.socketPath == "/tmp/oppi-mac-chat.sock")
        #expect(adapter.transportPath == .unix)
    }

    @Test func controlScopeHistoryUsesControlSessionsOnOwnerUnixSocket() async throws {
        let transport = RecordingLocalHTTPTransport(response: .json(Self.tracePageJSON))
        let adapter = Self.makeAdapter(transport: transport)

        let snapshot = try await adapter.fetchLatestTrace(
            scope: .control,
            sessionId: "control-1",
            previewBytes: 4_096
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path.hasPrefix("/control-sessions/control-1/trace-page?"))
        #expect(request.path.contains("previewBytes=4096"))
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("/workspaces/"))
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("wss"))
        #expect(snapshot.session.id == "sess-1")
    }

    @Test func controlScopeCatchUpUsesControlSessionEvents() async throws {
        let transport = RecordingLocalHTTPTransport(response: .json(Self.catchUpJSON))
        let adapter = Self.makeAdapter(transport: transport)

        _ = try await adapter.fetchCatchUp(
            scope: .control,
            sessionId: "control-1",
            since: 12
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/control-sessions/control-1/events?since=12")
        #expect(!request.path.contains("/workspaces/"))
    }

    @Test func controlFocusedStreamUsesControlSessionsPath() {
        let adapter = Self.makeAdapter(
            transport: RecordingLocalHTTPTransport(response: .json("{}"))
        )

        let transport = adapter.makeFocusedStreamTransport(
            scope: .control,
            sessionId: "control-1"
        )

        #expect(transport.path == "/control-sessions/control-1/stream")
        #expect(transport.path == MacUnixWebSocketTransport.focusedSessionPath(
            scope: .control,
            sessionId: "control-1"
        ))
        #expect(!transport.path.contains("/workspaces/"))
        #expect(!transport.path.contains("wss"))
        #expect(transport.headers["Authorization"] == "Bearer sk_owner")
    }

    @Test func agentStartPreventsDisplaySleepAndSettledReleasesWhenOff() {
        let (adapter, controller, updates) = Self.makeScreenAwakeAdapter()

        _ = adapter.applySharedStoreUpdate(for: .agentStart, sessionId: "sess-1")
        #expect(controller.isPreventingSleep)
        #expect(updates() == [true])

        _ = adapter.applySharedStoreUpdate(for: .agentSettled, sessionId: "sess-1")
        #expect(!controller.isPreventingSleep)
        #expect(updates() == [true, false])
    }

    @Test func runningSessionStatePreventsDisplaySleep() {
        let (adapter, controller, updates) = Self.makeScreenAwakeAdapter()

        _ = adapter.applySharedStoreUpdate(
            for: .state(session: Self.makeSession(status: .busy)),
            sessionId: "sess-1"
        )
        #expect(controller.isPreventingSleep)
        #expect(updates() == [true])

        _ = adapter.applySharedStoreUpdate(
            for: .state(session: Self.makeSession(status: .ready)),
            sessionId: "sess-1"
        )
        #expect(!controller.isPreventingSleep)
        #expect(updates() == [true, false])
    }

    @Test func sessionEndedClearsDisplaySleepPrevention() {
        let (adapter, controller, updates) = Self.makeScreenAwakeAdapter()

        _ = adapter.applySharedStoreUpdate(for: .agentStart, sessionId: "sess-1")
        _ = adapter.applySharedStoreUpdate(
            for: .sessionEnded(reason: "stopped"),
            sessionId: "sess-1"
        )
        #expect(!controller.isPreventingSleep)
        #expect(updates() == [true, false])
    }

    private static func makeAdapter(
        transport: RecordingLocalHTTPTransport,
        screenAwakeController: MacScreenAwakeController = .shared
    ) -> MacChatSessionRuntimeAdapter {
        MacChatSessionRuntimeAdapter(
            client: MacWorkspaceClient(
                socketPath: "/tmp/oppi-mac-chat.sock",
                token: "sk_owner",
                transport: transport
            ),
            token: "sk_owner",
            screenAwakeController: screenAwakeController
        )
    }

    private static func makeScreenAwakeAdapter() -> (
        MacChatSessionRuntimeAdapter,
        MacScreenAwakeController,
        () -> [Bool]
    ) {
        var updates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { nil },
            activitySetter: { updates.append($0) }
        )
        let adapter = makeAdapter(
            transport: RecordingLocalHTTPTransport(response: .json("{}")),
            screenAwakeController: controller
        )
        return (adapter, controller, { updates })
    }

    private static func makeSession(status: SessionStatus) -> Session {
        Session(
            id: "sess-1",
            workspaceId: "ws-1",
            workspaceName: "Oppi",
            name: "Mac Chat",
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_760_000_002),
            messageCount: 1,
            tokens: TokenUsage(input: 1, output: 1),
            cost: 0
        )
    }

    private static let sessionJSON = """
        {
          "id": "sess-1",
          "workspaceId": "ws-1",
          "name": "Mac Chat",
          "status": "ready",
          "createdAt": 1760000000000,
          "lastActivity": 1760000002000,
          "messageCount": 1,
          "tokens": { "input": 1, "output": 1 },
          "cost": 0
        }
        """

    private static var tracePageJSON: String {
        """
        {
          "session": \(sessionJSON),
          "trace": [
            {
              "id": "event-1",
              "type": "user",
              "timestamp": "2026-06-28T20:00:00Z",
              "text": "Hello"
            }
          ],
          "page": {
            "hasOlder": false,
            "olderCursor": null,
            "traceVersion": "v1",
            "previewBytes": 4096,
            "staleCursor": false
          }
        }
        """
    }

    private static var catchUpJSON: String {
        """
        {
          "events": [
            { "seq": 13, "type": "agent_start" }
          ],
          "currentSeq": 13,
          "runtimeEpoch": "epoch-1",
          "catchUpComplete": true,
          "session": \(sessionJSON)
        }
        """
    }
}

private extension MacLocalHTTPResponse {
    static func json(_ body: String) -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
    }
}
