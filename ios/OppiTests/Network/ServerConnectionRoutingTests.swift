import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Routing")
struct ServerConnectionRoutingTests {

    @MainActor
    @Test func routeConnected() {
        let conn = makeTestConnection()
        let session = makeTestSession(status: .ready)

        conn.handleServerMessage(.connected(session: session), sessionId: "s1")

        #expect(conn.sessionStore.sessions.count == 1)
        #expect(conn.sessionStore.sessions[0].status == .ready)
    }

    @MainActor
    @Test func routeState() {
        let conn = makeTestConnection()
        let session = makeTestSession(status: .busy)

        conn.handleServerMessage(.state(session: session), sessionId: "s1")

        #expect(conn.sessionStore.sessions.count == 1)
        #expect(conn.sessionStore.sessions[0].status == .busy)
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
        let conn = makeTestConnection()
        #expect(conn.thinkingLevel == .medium)

        conn.handleServerMessage(
            .connected(session: makeTestSession(status: .ready, thinkingLevel: "medium")),
            sessionId: "s1"
        )
        #expect(conn.thinkingLevel == .medium)

        conn.handleServerMessage(
            .state(session: makeTestSession(status: .ready, thinkingLevel: "high")),
            sessionId: "s1"
        )
        #expect(conn.thinkingLevel == .high)
    }

    @MainActor
    @Test func routeConnectedRequestsSlashCommands() async {
        let conn = makeTestConnection()
        let counter = GetCommandsCounter()

        conn._sendMessageForTesting = { message in
            await counter.record(message: message)
        }

        conn.handleServerMessage(.connected(session: makeTestSession(status: .ready)), sessionId: "s1")

        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 1 })
    }

    @MainActor
    @Test func routeStateWorkspaceChangeRequestsSlashCommands() async {
        let conn = makeTestConnection()
        let counter = GetCommandsCounter()

        conn._sendMessageForTesting = { message in
            await counter.record(message: message)
        }

        var initial = makeTestSession(status: .ready)
        initial.workspaceId = "w1"
        conn.handleServerMessage(.connected(session: initial), sessionId: "s1")
        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 1 })

        // Same workspace should not re-fetch.
        conn.handleServerMessage(.state(session: initial), sessionId: "s1")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count() == 1)

        // Workspace switch should refresh.
        var switched = initial
        switched.workspaceId = "w2"
        conn.handleServerMessage(.state(session: switched), sessionId: "s1")
        #expect(await waitForTestCondition(timeoutMs: 500) { await counter.count() == 2 })
    }

    @MainActor
    @Test func routeGetCommandsResultUpdatesSlashCommandCache() {
        let conn = makeTestConnection()
        let session = makeTestSession(status: .ready)
        conn.handleServerMessage(.connected(session: session), sessionId: "s1")

        conn.handleServerMessage(
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

        #expect(conn.slashCommands.count == 2)
        #expect(conn.slashCommands.map(\.name) == ["compact", "skill:lint"])
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

        let assistants = scenario.connection.reducer.items.filter {
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
        let conn = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .ready))

        conn.handleServerMessage(.agentStart, sessionId: "s1")

        #expect(conn.sessionStore.sessions.first?.status == .busy)
    }

    @MainActor
    @Test func routeAgentEndSetsSessionReadyWithoutStateMessage() {
        let conn = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .busy))

        conn.handleServerMessage(.agentEnd, sessionId: "s1")

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
            .whenHandle(.toolOutput(output: "file.txt", isError: false, toolCallId: "tc-1"))
            .whenFlush()
            .whenHandle(.toolEnd(tool: "bash", toolCallId: "tc-1", details: nil, isError: false, resultSegments: nil))
            .whenFlush()
            .whenHandle(.agentEnd)
            .whenFlush()

        let tools = scenario.connection.reducer.items.filter {
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
    @Test func routeMissingFullSubscriptionErrorTriggersAutoRecover() async {
        let conn = makeTestConnection()
        let subscribeCounter = MessageCounter()

        conn._sendMessageForTesting = { message in
            switch message {
            case .subscribe(let sessionId, let level, _, let requestId):
                await subscribeCounter.increment()
                #expect(sessionId == "s1")
                #expect(level == .full)
                conn.handleServerMessage(
                    .commandResult(
                        command: "subscribe",
                        requestId: requestId,
                        success: true,
                        data: nil,
                        error: nil
                    ),
                    sessionId: "s1"
                )
            default:
                break
            }
        }

        conn.handleServerMessage(
            .error(message: "Session s1 is not subscribed at level=full", code: nil, fatal: false),
            sessionId: "s1"
        )

        #expect(await waitForTestCondition(timeoutMs: 500) { await subscribeCounter.count() == 1 })

        conn.flushAndSuspend()
        let errors = conn.reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(errors.isEmpty)
    }

    @MainActor
    @Test func routeExtensionUIRequest() {
        let conn = makeTestConnection()
        let request = ExtensionUIRequest(
            id: "ext1",
            sessionId: "s1",
            method: "confirm",
            title: "Confirm action",
            message: "Are you sure?"
        )

        conn.handleServerMessage(.extensionUIRequest(request), sessionId: "s1")

        #expect(conn.activeExtensionDialog?.id == "ext1")
    }

    @MainActor
    @Test func routeExtensionUINotification() {
        let conn = makeTestConnection()

        conn.handleServerMessage(
            .extensionUINotification(method: "notify", message: "Task complete", notifyType: "info", statusKey: nil, statusText: nil),
            sessionId: "s1"
        )

        #expect(conn.extensionToast == "Task complete")
    }

    @MainActor
    @Test func routeUnknownIsNoOp() {
        let conn = makeTestConnection()
        let preCount = conn.reducer.items.count

        conn.handleServerMessage(.unknown(type: "future_type"), sessionId: "s1")

        #expect(conn.reducer.items.count == preCount)
    }

    @MainActor
    @Test func staleSessionMessageIgnored() {
        let conn = makeTestConnection(sessionId: "s1")

        // Send message for a different session
        let session = makeTestSession(id: "s2", status: .busy)
        conn.handleServerMessage(.connected(session: session), sessionId: "s2")

        // Session store should NOT have s2 (message was for wrong active session)
        #expect(conn.sessionStore.sessions.isEmpty)
    }
}

// MARK: - Shared scenario helpers

@MainActor
final class EventFlowServerConnectionScenario {
    let connection: ServerConnection
    let activeSessionId: String

    init(sessionId: String = "s1") {
        self.connection = makeTestConnection(sessionId: sessionId)
        self.activeSessionId = sessionId
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
        connection.handleServerMessage(message, sessionId: sessionId ?? activeSessionId)
        if flushAfter {
            connection.flushAndSuspend()
        }
        return self
    }

    @discardableResult
    func whenFlush() -> Self {
        connection.flushAndSuspend()
        return self
    }

    func firstSessionStatus() -> SessionStatus? {
        connection.sessionStore.sessions.first?.status
    }

    func timelineItemCount(of kind: EventFlowTimelineItemKind) -> Int {
        connection.reducer.items.filter { item in
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
) -> ServerConnection {
    let connection = ServerConnection()
    connection._setActiveSessionIdForTesting(sessionId)
    if let timeout {
        connection._sendAckTimeoutForTesting = timeout
    }
    return connection
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
