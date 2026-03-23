import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Routing")
struct ServerConnectionRoutingTests {

    @MainActor
    @Test func routeConnected() {
        let (conn, pipe) = makeTestConnection()
        let session = makeTestSession(status: .ready)

        pipe.handle(.connected(session: session), sessionId: "s1")

        #expect(conn.sessionStore.sessions.count == 1)
        #expect(conn.sessionStore.sessions[0].status == .ready)
    }

    @MainActor
    @Test func routeState() {
        let (conn, pipe) = makeTestConnection()
        let session = makeTestSession(status: .busy)

        pipe.handle(.state(session: session), sessionId: "s1")

        #expect(conn.sessionStore.sessions.count == 1)
        #expect(conn.sessionStore.sessions[0].status == .busy)
    }

    @MainActor
    @Test func routeQueueStateUpdatesQueueStore() {
        let (conn, pipe) = makeTestConnection()
        let state = MessageQueueState(
            version: 7,
            steering: [MessageQueueItem(id: "q1", message: "steer one", images: nil, createdAt: 1)],
            followUp: [MessageQueueItem(id: "q2", message: "follow one", images: nil, createdAt: 2)]
        )

        pipe.handle(.queueState(queue: state), sessionId: "s1")

        let stored = conn.messageQueueStore.queue(for: "s1")
        #expect(stored.version == 7)
        #expect(stored.steering.count == 1)
        #expect(stored.followUp.count == 1)
    }

    @MainActor
    @Test func routeQueueStateIgnoresStaleVersion() {
        let (conn, pipe) = makeTestConnection()
        conn.messageQueueStore.apply(
            MessageQueueState(
                version: 9,
                steering: [MessageQueueItem(id: "q9", message: "latest", images: nil, createdAt: 9)],
                followUp: []
            ),
            for: "s1"
        )

        pipe.handle(
            .queueState(
                queue: MessageQueueState(
                    version: 8,
                    steering: [MessageQueueItem(id: "q8", message: "stale", images: nil, createdAt: 8)],
                    followUp: []
                )
            ),
            sessionId: "s1"
        )

        let stored = conn.messageQueueStore.queue(for: "s1")
        #expect(stored.version == 9)
        #expect(stored.steering.map(\.message) == ["latest"])
    }

    @MainActor
    @Test func routeQueueItemStartedRemovesItemAndAppendsUserMessage() {
        let (conn, pipe) = makeTestConnection()
        let initial = MessageQueueState(
            version: 2,
            steering: [MessageQueueItem(id: "q1", message: "steer one", images: nil, createdAt: 1)],
            followUp: [MessageQueueItem(id: "q2", message: "follow one", images: nil, createdAt: 2)]
        )
        conn.messageQueueStore.apply(initial, for: "s1")

        pipe.handle(
            .queueItemStarted(
                kind: .followUp,
                item: MessageQueueItem(id: "q2", message: "follow one", images: nil, createdAt: 2),
                queueVersion: 3
            ),
            sessionId: "s1"
        )

        let stored = conn.messageQueueStore.queue(for: "s1")
        #expect(stored.version == 3)
        #expect(stored.followUp.isEmpty)

        guard let first = pipe.reducer.items.first,
              case .userMessage(_, let text, let images, _) = first else {
            Issue.record("Expected queue started user message")
            return
        }
        #expect(text == "follow one")
        #expect(images.isEmpty)
    }

    @MainActor
    @Test func routeGetQueueCommandResultUpdatesQueueStore() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .commandResult(
                command: "get_queue",
                requestId: "req-1",
                success: true,
                data: [
                    "version": 11,
                    "steering": [
                        [
                            "id": "q1",
                            "message": "steer one",
                            "createdAt": 1,
                        ],
                    ],
                    "followUp": [
                        [
                            "id": "q2",
                            "message": "follow one",
                            "createdAt": 2,
                        ],
                    ],
                ],
                error: nil
            ),
            sessionId: "s1"
        )

        let stored = conn.messageQueueStore.queue(for: "s1")
        #expect(stored.version == 11)
        #expect(stored.steering.count == 1)
        #expect(stored.followUp.count == 1)
    }

    @MainActor
    @Test func routeGetQueueCommandResultIgnoresStaleVersion() {
        let (conn, pipe) = makeTestConnection()
        conn.messageQueueStore.apply(
            MessageQueueState(
                version: 12,
                steering: [],
                followUp: [MessageQueueItem(id: "q12", message: "fresh follow", images: nil, createdAt: 12)]
            ),
            for: "s1"
        )

        pipe.handle(
            .commandResult(
                command: "get_queue",
                requestId: "req-stale",
                success: true,
                data: [
                    "version": 11,
                    "steering": [],
                    "followUp": [
                        [
                            "id": "q11",
                            "message": "stale follow",
                            "createdAt": 11,
                        ],
                    ],
                ],
                error: nil
            ),
            sessionId: "s1"
        )

        let stored = conn.messageQueueStore.queue(for: "s1")
        #expect(stored.version == 12)
        #expect(stored.followUp.map(\.message) == ["fresh follow"])
    }

    @MainActor
    @Test func routeGetQueueFailureDoesNotProduceTimelineError() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .commandResult(
                command: "get_queue",
                requestId: "req-fail",
                success: false,
                data: nil,
                error: "Session s1 is not subscribed at level=full"
            ),
            sessionId: "s1"
        )

        pipe.flushNow()
        let errors = pipe.reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(errors.isEmpty, "Failed get_queue command_result should not leak to timeline")
    }

    @MainActor
    @Test func routeSetQueueFailureDoesNotProduceTimelineError() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .commandResult(
                command: "set_queue",
                requestId: "req-fail",
                success: false,
                data: nil,
                error: "version conflict"
            ),
            sessionId: "s1"
        )

        pipe.flushNow()
        let errors = pipe.reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(errors.isEmpty, "Failed set_queue command_result should not leak to timeline")
    }

    @MainActor
    @Test func routeSubscribeFailureDoesNotProduceTimelineError() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .commandResult(
                command: "subscribe",
                requestId: "req-sub",
                success: false,
                data: nil,
                error: "Subscribe rate limit exceeded — try again later"
            ),
            sessionId: "s1"
        )

        pipe.flushNow()
        let errors = pipe.reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(errors.isEmpty, "Failed subscribe command_result should not leak to timeline")
    }

    @MainActor
    @Test func routeUnsubscribeFailureDoesNotProduceTimelineError() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .commandResult(
                command: "unsubscribe",
                requestId: "req-unsub",
                success: false,
                data: nil,
                error: "Session not found"
            ),
            sessionId: "s1"
        )

        pipe.flushNow()
        let errors = pipe.reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(errors.isEmpty, "Failed unsubscribe command_result should not leak to timeline")
    }

    @MainActor
    @Test func routeStopRequestedMarksStopping() {
        let scenario = EventFlowServerConnectionScenario()

        scenario
            .givenStoredSession(status: .busy)
            .whenHandle(
                .stopRequested(source: .user, reason: "Stopping current turn"),
                flushAfter: true
            )

        #expect(scenario.firstSessionStatus() == .stopping)
        #expect(scenario.timelineItemCount(of: .systemEvent) == 1)
    }

    @MainActor
    @Test func routeStopFailedRestoresBusyAndEmitsError() {
        let scenario = EventFlowServerConnectionScenario()

        scenario
            .givenStoredSession(status: .stopping)
            .whenHandle(
                .stopFailed(source: .timeout, reason: "Stop timed out after 8000ms"),
                flushAfter: true
            )

        #expect(scenario.firstSessionStatus() == .busy)
        #expect(scenario.timelineItemCount(of: .error) == 1)
    }

    @MainActor
    @Test func routeStopConfirmedRestoresReady() {
        let scenario = EventFlowServerConnectionScenario()

        scenario
            .givenStoredSession(status: .stopping)
            .whenHandle(.stopConfirmed(source: .user, reason: nil), flushAfter: true)

        #expect(scenario.firstSessionStatus() == .ready)
    }

    @MainActor
    @Test func routeStateSyncsThinkingLevelOnlyWhenChanged() {
        let (conn, pipe) = makeTestConnection()
        #expect(conn.chatState.thinkingLevel == .medium)

        pipe.handle(
            .connected(session: makeTestSession(status: .ready, thinkingLevel: "medium")),
            sessionId: "s1"
        )
        #expect(conn.chatState.thinkingLevel == .medium)

        pipe.handle(
            .state(session: makeTestSession(status: .ready, thinkingLevel: "high")),
            sessionId: "s1"
        )
        #expect(conn.chatState.thinkingLevel == .high)
    }

    @MainActor
    @Test func routeConnectedRequestsSlashCommands() async {
        let (conn, pipe) = makeTestConnection()
        let counter = GetCommandsCounter()

        conn._sendMessageForTesting = { message in
            await counter.record(message: message)
        }

        pipe.handle(.connected(session: makeTestSession(status: .ready)), sessionId: "s1")

        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 1 })
    }

    @MainActor
    @Test func routeStateWorkspaceChangeRequestsSlashCommands() async {
        let (conn, pipe) = makeTestConnection()
        let counter = GetCommandsCounter()

        conn._sendMessageForTesting = { message in
            await counter.record(message: message)
        }

        var initial = makeTestSession(status: .ready)
        initial.workspaceId = "w1"
        pipe.handle(.connected(session: initial), sessionId: "s1")
        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 1 })

        // Same workspace should not re-fetch.
        pipe.handle(.state(session: initial), sessionId: "s1")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count() == 1)

        // Workspace switch should refresh.
        var switched = initial
        switched.workspaceId = "w2"
        pipe.handle(.state(session: switched), sessionId: "s1")
        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 2 })
    }

    @MainActor
    @Test func routeGetCommandsResultUpdatesSlashCommandCache() {
        let (conn, pipe) = makeTestConnection()
        let session = makeTestSession(status: .ready)
        pipe.handle(.connected(session: session), sessionId: "s1")

        pipe.handle(
            .commandResult(
                command: "get_commands",
                requestId: nil,
                success: true,
                data: makeGetCommandsPayload([
                    GetCommandsPayload(name: "compact", description: "Compact context", source: "prompt"),
                    GetCommandsPayload(name: "skill:lint", description: "Run linter skill", source: "skill"),
                ]),
                error: nil
            ),
            sessionId: "s1"
        )

        #expect(conn.chatState.slashCommands.count == 2)
        #expect(conn.chatState.slashCommands.map(\.name) == ["compact", "skill:lint"])
    }

    @MainActor
    @Test func routeAgentStartAndTextAndEnd() {
        let scenario = EventFlowServerConnectionScenario()

        scenario
            .whenHandle(.agentStart)
            .whenFlush()
            .whenHandle(.textDelta(delta: "Hello"))
            .whenHandle(.agentEnd)
            .whenFlush()

        let assistants = scenario.reducer.items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }
        #expect(assistants.count == 1)
        guard case .assistantMessage(_, let text, _) = assistants[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(text == "Hello")
    }

    @MainActor
    @Test func routeAgentStartSetsSessionBusyWithoutStateMessage() {
        let (conn, pipe) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .ready))

        pipe.handle(.agentStart, sessionId: "s1")

        #expect(conn.sessionStore.sessions.first?.status == .busy)
    }

    @MainActor
    @Test func routeAgentEndSetsSessionReadyWithoutStateMessage() {
        let (conn, pipe) = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .busy))

        pipe.handle(.agentEnd, sessionId: "s1")

        #expect(conn.sessionStore.sessions.first?.status == .ready)
    }

    @MainActor
    @Test func routeThinkingDelta() {
        let scenario = EventFlowServerConnectionScenario()

        scenario
            .whenHandle(.agentStart)
            .whenHandle(.thinkingDelta(delta: "thinking..."))
            .whenHandle(.agentEnd)
            .whenFlush()

        #expect(scenario.timelineItemCount(of: .thinking) == 1)
    }

    @MainActor
    @Test func routeToolStartOutputEnd() {
        let scenario = EventFlowServerConnectionScenario()

        scenario
            .whenHandle(.agentStart)
            .whenHandle(.toolStart(tool: "bash", args: ["command": "ls"], toolCallId: "tc-1", callSegments: nil))
            .whenFlush()
            .whenHandle(.toolOutput(output: "file.txt", isError: false, toolCallId: "tc-1", mode: .append, truncated: false, totalBytes: nil))
            .whenFlush()
            .whenHandle(.toolEnd(tool: "bash", toolCallId: "tc-1", details: nil, isError: false, resultSegments: nil))
            .whenFlush()
            .whenHandle(.agentEnd)
            .whenFlush()

        let tools = scenario.reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(tools.count == 1)
        guard case .toolCall(_, let tool, _, _, _, _, let isDone) = tools[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tool == "bash")
        #expect(isDone)
    }

    @MainActor
    @Test func routeSessionEnded() {
        let scenario = EventFlowServerConnectionScenario()

        scenario
            .givenStoredSession(status: .busy)
            .whenHandle(.sessionEnded(reason: "stopped"), flushAfter: true)

        #expect(scenario.firstSessionStatus() == .stopped)
        #expect(scenario.timelineItemCount(of: .systemEvent) == 1)
    }

    @MainActor
    @Test func routeError() {
        let scenario = EventFlowServerConnectionScenario()

        scenario
            .whenHandle(.error(message: "Something failed", code: nil, fatal: false), flushAfter: true)

        #expect(scenario.timelineItemCount(of: .error) == 1)
    }

    @MainActor
    @Test func routeExtensionUIRequest() {
        let (conn, pipe) = makeTestConnection()
        let request = ExtensionUIRequest(
            id: "ext1",
            sessionId: "s1",
            method: "confirm",
            title: "Confirm action",
            message: "Are you sure?"
        )

        pipe.handle(.extensionUIRequest(request), sessionId: "s1")

        #expect(conn.activeExtensionDialog?.id == "ext1")
    }

    @MainActor
    @Test func routeExtensionUINotification() {
        let (conn, pipe) = makeTestConnection()

        pipe.handle(
            .extensionUINotification(method: "notify", message: "Task complete", notifyType: "info", statusKey: nil, statusText: nil),
            sessionId: "s1"
        )

        #expect(conn.extensionToast == "Task complete")
    }

    @MainActor
    @Test func routeUnknownIsNoOp() {
        let (conn, pipe) = makeTestConnection()
        let preCount = pipe.reducer.items.count

        pipe.handle(.unknown(type: "future_type"), sessionId: "s1")

        #expect(pipe.reducer.items.count == preCount)
    }

    @MainActor
    @Test func staleSessionMessageIgnored() {
        let (conn, pipe) = makeTestConnection(sessionId: "s1")

        // Send message for a different session
        let session = makeTestSession(id: "s2", status: .busy)
        pipe.handle(.connected(session: session), sessionId: "s2")

        // Session store should NOT have s2 (message was for wrong active session)
        #expect(conn.sessionStore.sessions.isEmpty)
    }

    @MainActor
    @Test func notSubscribedErrorSuppressedFromStream() {
        let (conn, _) = makeTestConnection(sessionId: "s1")

        // Track what gets yielded to the per-session continuation.
        var yieldedCount = 0
        let _ = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
            continuation.onTermination = { _ in }
        }

        // Patch: wrap the continuation to count yields.
        let realCont = conn.sessionContinuations["s1"]!
        let countingStream = AsyncStream<ServerMessage> { countingCont in
            conn.sessionContinuations["s1"] = countingCont
        }
        // We won't consume countingStream — just check if yield was called
        // by checking whether the error reached the pipeline's test reducer instead.

        // Simpler approach: use the TestEventPipeline path to verify the error
        // is suppressed at the routeStreamMessage level.
        // routeStreamMessage only yields to sessionContinuations — if the continuation
        // is nil, nothing is yielded. So we can remove it and check that the
        // coordinator's silent resubscribe was triggered.
        conn.sessionContinuations.removeAll()

        let errorMsg = StreamMessage(
            sessionId: "s1",
            streamSeq: nil,
            seq: nil,
            currentSeq: nil,
            message: .error(
                message: "Session s1 is not subscribed at level=full",
                code: "stream_not_subscribed_full",
                fatal: false
            )
        )
        conn.routeStreamMessage(errorMsg)

        // The coordinator should have kicked off a silent resubscribe task.
        #expect(
            conn.sessionStreamCoordinator.silentResubscribeTask != nil,
            "Should trigger silent resubscribe"
        )
    }

    @MainActor
    @Test func regularErrorNotSuppressed() {
        let (conn, _) = makeTestConnection(sessionId: "s1")

        // Regular errors should pass through routeStreamMessage normally.
        // Verify by checking that the coordinator does NOT intercept them.
        let errorMsg = StreamMessage(
            sessionId: "s1",
            streamSeq: nil,
            seq: nil,
            currentSeq: nil,
            message: .error(
                message: "Something went wrong",
                code: nil,
                fatal: false
            )
        )
        conn.routeStreamMessage(errorMsg)

        // No silent resubscribe should be triggered for regular errors.
        #expect(
            conn.sessionStreamCoordinator.silentResubscribeTask == nil,
            "Regular errors should not trigger silent resubscribe"
        )
    }
}

// MARK: - Shared scenario helpers

@MainActor
final class EventFlowServerConnectionScenario {
    let connection: ServerConnection
    let activeSessionId: String
    let reducer = TimelineReducer()
    let coalescer = DeltaCoalescer()
    let toolCallCorrelator = ToolCallCorrelator()

    init(sessionId: String = "s1") {
        self.connection = makeTestConnection(sessionId: sessionId).conn
        self.activeSessionId = sessionId

        coalescer.onFlush = { [weak self] events in
            self?.reducer.processBatch(events)
        }
        coalescer.sessionId = sessionId
    }

    @discardableResult
    func givenStoredSession(
        id: String? = nil,
        status: SessionStatus,
        workspaceId: String? = nil,
        thinkingLevel: String? = nil
    ) -> Self {
        connection.sessionStore.upsert(
            makeTestSession(
                id: id ?? activeSessionId,
                workspaceId: workspaceId,
                status: status,
                thinkingLevel: thinkingLevel
            )
        )
        return self
    }

    @discardableResult
    func whenHandle(
        _ message: ServerMessage,
        sessionId: String? = nil,
        flushAfter: Bool = false
    ) -> Self {
        let sid = sessionId ?? activeSessionId
        let storeResult = connection.applySharedStoreUpdate(for: message, sessionId: sid)
        routeToTimeline(message, sessionId: sid, storeResult: storeResult)
        connection.handleActiveSessionUI(message, sessionId: sid)
        if flushAfter {
            coalescer.flushNow()
        }
        return self
    }

    @discardableResult
    func whenFlush() -> Self {
        coalescer.flushNow()
        return self
    }

    func firstSessionStatus() -> SessionStatus? {
        connection.sessionStore.sessions.first?.status
    }

    func timelineItemCount(of kind: EventFlowTimelineItemKind) -> Int {
        reducer.items.filter { item in
            switch kind {
            case .assistantMessage:
                if case .assistantMessage = item { return true }
            case .systemEvent:
                if case .systemEvent = item { return true }
            case .error:
                if case .error = item { return true }
            case .thinking:
                if case .thinking = item { return true }
            case .toolCall:
                if case .toolCall = item { return true }
            }
            return false
        }.count
    }

    private func routeToTimeline(_ message: ServerMessage, sessionId: String, storeResult: ServerConnection.StoreUpdateResult = .notHandled) {
        switch message {
        case .agentStart: coalescer.receive(.agentStart(sessionId: sessionId))
        case .agentEnd: coalescer.receive(.agentEnd(sessionId: sessionId))
        case .textDelta(let d): coalescer.receive(.textDelta(sessionId: sessionId, delta: d))
        case .thinkingDelta(let d): coalescer.receive(.thinkingDelta(sessionId: sessionId, delta: d))
        case .toolStart(let t, let a, let id, let s): coalescer.receive(toolCallCorrelator.start(sessionId: sessionId, tool: t, args: a, toolCallId: id, callSegments: s))
        case .toolOutput(let o, let e, let id, let m, let tr, let tb): coalescer.receive(toolCallCorrelator.output(sessionId: sessionId, output: o, isError: e, toolCallId: id, mode: m, truncated: tr, totalBytes: tb))
        case .toolEnd(_, let id, let d, let e, let s): coalescer.receive(toolCallCorrelator.end(sessionId: sessionId, toolCallId: id, details: d, isError: e, resultSegments: s))
        case .messageEnd(let r, let c):
            if r == "assistant" { coalescer.receive(.messageEnd(sessionId: sessionId, content: c)) }
            else if r == "user", !c.isEmpty, !reducer.hasUserMessage(matching: c) { reducer.appendUserMessage(c) }
        case .error(let msg, _, let fatal):
            coalescer.receive(.error(sessionId: sessionId, message: msg))
            if fatal { connection.fatalSetupError = true }
        case .sessionEnded(let r): coalescer.receive(.sessionEnded(sessionId: sessionId, reason: r))
        case .compactionStart(let r): coalescer.receive(.compactionStart(sessionId: sessionId, reason: r))
        case .compactionEnd(let a, let w, let s, let t): coalescer.receive(.compactionEnd(sessionId: sessionId, aborted: a, willRetry: w, summary: s, tokensBefore: t))
        case .retryStart(let a, let m, let d, let e): coalescer.receive(.retryStart(sessionId: sessionId, attempt: a, maxAttempts: m, delayMs: d, errorMessage: e))
        case .retryEnd(let s, let a, let f): coalescer.receive(.retryEnd(sessionId: sessionId, success: s, attempt: a, finalError: f))
        case .commandResult(let cmd, let rid, let ok, let data, let err):
            let consumed = connection.handleCommandResult(command: cmd, requestId: rid, success: ok, data: data, error: err, sessionId: sessionId)
            if !consumed { coalescer.receive(.commandResult(sessionId: sessionId, command: cmd, requestId: rid, success: ok, data: data, error: err)) }
        case .permissionExpired(let id, _):
            if let req = storeResult.takenPermission { reducer.resolvePermission(id: id, outcome: .expired, tool: req.tool, summary: req.displaySummary) }
            coalescer.receive(.permissionExpired(id: id))
        case .permissionCancelled(let id):
            if let req = storeResult.takenPermission { reducer.resolvePermission(id: id, outcome: .cancelled, tool: req.tool, summary: req.displaySummary) }
        case .permissionRequest(let p): coalescer.receive(.permissionRequest(p))
        case .queueItemStarted(_, let item, _): reducer.appendUserMessage(item.message, images: item.images ?? [])
        case .stopRequested(_, let r): reducer.appendSystemEvent(r ?? "Stopping…")
        case .stopConfirmed(_, let r): coalescer.receive(.agentEnd(sessionId: sessionId)); reducer.appendSystemEvent(r ?? "Stop confirmed")
        case .stopFailed(_, let r): reducer.process(.error(sessionId: sessionId, message: "Stop failed: \(r)"))
        case .state(let session):
            let prev = connection.sessionStore.sessions.first(where: { $0.id == session.id })?.status
            if let prev, prev == .busy || prev == .stopping, session.status == .ready || session.status == .stopped || session.status == .error { coalescer.receive(.agentEnd(sessionId: session.id)) }
        default: break
        }
    }
}

enum EventFlowTimelineItemKind {
    case assistantMessage
    case systemEvent
    case error
    case thinking
    case toolCall
}

enum EventFlowAckCommand: CaseIterable {
    case prompt
    case steer
    case followUp

    var rawValue: String {
        switch self {
        case .prompt: return "prompt"
        case .steer: return "steer"
        case .followUp: return "follow_up"
        }
    }

    @MainActor
    func send(using connection: ServerConnection, text: String) async throws {
        switch self {
        case .prompt:
            try await connection.sendPrompt(text)
        case .steer:
            try await connection.sendSteer(text)
        case .followUp:
            try await connection.sendFollowUp(text)
        }
    }
}

struct EventFlowAckRequest {
    let command: String
    let requestId: String?
    let clientTurnId: String?
}

func extractEventFlowAckRequest(from message: ClientMessage) -> EventFlowAckRequest? {
    switch message {
    case .prompt(_, _, _, let requestId, let clientTurnId):
        return EventFlowAckRequest(command: "prompt", requestId: requestId, clientTurnId: clientTurnId)
    case .steer(_, _, let requestId, let clientTurnId):
        return EventFlowAckRequest(command: "steer", requestId: requestId, clientTurnId: clientTurnId)
    case .followUp(_, _, let requestId, let clientTurnId):
        return EventFlowAckRequest(command: "follow_up", requestId: requestId, clientTurnId: clientTurnId)
    default:
        return nil
    }
}

@MainActor
func makeEventFlowAckTestConnection(
    sessionId: String = "s1",
    timeout: Duration? = nil
) -> (conn: ServerConnection, pipe: TestEventPipeline) {
    let connection = ServerConnection()
    connection._setActiveSessionIdForTesting(sessionId)
    if let timeout {
        connection._sendAckTimeoutForTesting = timeout
    }
    let pipeline = TestEventPipeline(sessionId: sessionId, connection: connection)
    return (connection, pipeline)
}

actor EventFlowAckStageRecorder {
    private var stages: [TurnAckStage] = []

    func record(_ stage: TurnAckStage) {
        stages.append(stage)
    }

    func snapshot() -> [TurnAckStage] {
        stages
    }
}

// MARK: - Private helpers

private struct GetCommandsPayload {
    let name: String
    let description: String
    let source: String
}

private func makeGetCommandsPayload(
    _ commands: [GetCommandsPayload]
) -> JSONValue {
    .object([
        "commands": .array(commands.map { command in
            .object([
                "name": .string(command.name),
                "description": .string(command.description),
                "source": .string(command.source),
            ])
        }),
    ])
}

private actor GetCommandsCounter {
    private var value = 0

    func record(message: ClientMessage) {
        if case .getCommands = message {
            value += 1
        }
    }

    func count() -> Int {
        value
    }
}
