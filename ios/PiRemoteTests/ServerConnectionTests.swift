import Testing
import Foundation
@testable import PiRemote

@Suite("ServerConnection")
struct ServerConnectionTests {

    // MARK: - Helpers

    @MainActor
    private func makeConnection(sessionId: String = "s1") -> ServerConnection {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "localhost", port: 7749, token: "sk_test", name: "Test"
        ))
        // Avoid opening a real WebSocket in unit tests.
        conn._setActiveSessionIdForTesting(sessionId)
        return conn
    }

    private func makeSession(
        id: String = "s1",
        status: SessionStatus = .ready,
        thinkingLevel: String? = nil
    ) -> Session {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Session(
            id: id,
            userId: "u1",
            workspaceId: nil,
            workspaceName: nil,
            name: "Session",
            status: status,
            createdAt: now,
            lastActivity: now,
            model: nil,
            runtime: nil,
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            contextTokens: nil,
            contextWindow: nil,
            lastMessage: nil,
            thinkingLevel: thinkingLevel
        )
    }

    // MARK: - configure

    @MainActor
    @Test func configureWithValidCredentials() {
        let conn = ServerConnection()
        let result = conn.configure(credentials: ServerCredentials(
            host: "192.168.1.10", port: 7749, token: "sk_abc", name: "Test"
        ))
        #expect(result == true)
        #expect(conn.apiClient != nil)
        #expect(conn.wsClient != nil)
        #expect(conn.credentials?.host == "192.168.1.10")
    }

    // MARK: - handleServerMessage routing

    @MainActor
    @Test func routeConnected() {
        let conn = makeConnection()
        let session = makeSession(status: .ready)

        conn.handleServerMessage(.connected(session: session), sessionId: "s1")

        #expect(conn.sessionStore.sessions.count == 1)
        #expect(conn.sessionStore.sessions[0].status == .ready)
    }

    @MainActor
    @Test func routeState() {
        let conn = makeConnection()
        let session = makeSession(status: .busy)

        conn.handleServerMessage(.state(session: session), sessionId: "s1")

        #expect(conn.sessionStore.sessions.count == 1)
        #expect(conn.sessionStore.sessions[0].status == .busy)
    }

    @MainActor
    @Test func routeStateSyncsThinkingLevelOnlyWhenChanged() {
        let conn = makeConnection()
        #expect(conn.thinkingLevel == .medium)

        conn.handleServerMessage(
            .connected(session: makeSession(status: .ready, thinkingLevel: "medium")),
            sessionId: "s1"
        )
        #expect(conn.thinkingLevel == .medium)

        conn.handleServerMessage(
            .state(session: makeSession(status: .ready, thinkingLevel: "high")),
            sessionId: "s1"
        )
        #expect(conn.thinkingLevel == .high)
    }

    @MainActor
    @Test func routeConnectedRequestsSlashCommands() async {
        let conn = makeConnection()
        let counter = GetCommandsCounter()

        conn._sendMessageForTesting = { message in
            await counter.record(message: message)
        }

        conn.handleServerMessage(.connected(session: makeSession(status: .ready)), sessionId: "s1")

        #expect(await waitForCondition(timeoutMs: 500) { await counter.count() == 1 })
    }

    @MainActor
    @Test func routeStateWorkspaceChangeRequestsSlashCommands() async {
        let conn = makeConnection()
        let counter = GetCommandsCounter()

        conn._sendMessageForTesting = { message in
            await counter.record(message: message)
        }

        var initial = makeSession(status: .ready)
        initial.workspaceId = "w1"
        conn.handleServerMessage(.connected(session: initial), sessionId: "s1")
        #expect(await waitForCondition(timeoutMs: 500) { await counter.count() == 1 })

        // Same workspace should not re-fetch.
        conn.handleServerMessage(.state(session: initial), sessionId: "s1")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count() == 1)

        // Workspace switch should refresh.
        var switched = initial
        switched.workspaceId = "w2"
        conn.handleServerMessage(.state(session: switched), sessionId: "s1")
        #expect(await waitForCondition(timeoutMs: 500) { await counter.count() == 2 })
    }

    @MainActor
    @Test func routeGetCommandsResultUpdatesSlashCommandCache() {
        let conn = makeConnection()
        let session = makeSession(status: .ready)
        conn.handleServerMessage(.connected(session: session), sessionId: "s1")

        conn.handleServerMessage(
            .rpcResult(
                command: "get_commands",
                requestId: nil,
                success: true,
                data: makeGetCommandsPayload([
                    ("compact", "Compact context", "prompt"),
                    ("skill:lint", "Run linter skill", "skill"),
                ]),
                error: nil
            ),
            sessionId: "s1"
        )

        #expect(conn.slashCommands.count == 2)
        #expect(conn.slashCommands.map(\.name) == ["compact", "skill:lint"])
    }

    @MainActor
    @Test func routePermissionRequest() {
        let conn = makeConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: ["command": .string("rm -rf /")],
            displaySummary: "bash: rm -rf /",
            risk: .critical, reason: "Destructive",
            timeoutAt: Date().addingTimeInterval(120)
        )

        conn.handleServerMessage(.permissionRequest(perm), sessionId: "s1")

        #expect(conn.permissionStore.count == 1)
        #expect(conn.permissionStore.pending[0].id == "p1")
    }

    @MainActor
    @Test func routePermissionExpired() {
        let conn = makeConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: test",
            risk: .low, reason: "Test",
            timeoutAt: Date().addingTimeInterval(120)
        )
        conn.permissionStore.add(perm)

        conn.handleServerMessage(.permissionExpired(id: "p1", reason: "timeout"), sessionId: "s1")

        #expect(conn.permissionStore.count == 0)
    }

    @MainActor
    @Test func routePermissionCancelled() {
        let conn = makeConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: test",
            risk: .low, reason: "Test",
            timeoutAt: Date().addingTimeInterval(120)
        )
        conn.permissionStore.add(perm)

        conn.handleServerMessage(.permissionCancelled(id: "p1"), sessionId: "s1")

        #expect(conn.permissionStore.count == 0)
    }

    @MainActor
    @Test func routeAgentStartAndTextAndEnd() {
        let conn = makeConnection()

        conn.handleServerMessage(.agentStart, sessionId: "s1")
        conn.flushAndSuspend()
        conn.handleServerMessage(.textDelta(delta: "Hello"), sessionId: "s1")
        conn.handleServerMessage(.agentEnd, sessionId: "s1")
        conn.flushAndSuspend()

        let assistants = conn.reducer.items.filter {
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
    @Test func routeThinkingDelta() {
        let conn = makeConnection()

        conn.handleServerMessage(.agentStart, sessionId: "s1")
        conn.handleServerMessage(.thinkingDelta(delta: "thinking..."), sessionId: "s1")
        conn.handleServerMessage(.agentEnd, sessionId: "s1")
        conn.flushAndSuspend()

        let thinking = conn.reducer.items.filter {
            if case .thinking = $0 { return true }
            return false
        }
        #expect(thinking.count == 1)
    }

    @MainActor
    @Test func routeToolStartOutputEnd() {
        let conn = makeConnection()

        conn.handleServerMessage(.agentStart, sessionId: "s1")
        conn.handleServerMessage(.toolStart(tool: "bash", args: ["command": "ls"], toolCallId: "tc-1"), sessionId: "s1")
        conn.flushAndSuspend()
        conn.handleServerMessage(.toolOutput(output: "file.txt", isError: false, toolCallId: "tc-1"), sessionId: "s1")
        conn.flushAndSuspend()
        conn.handleServerMessage(.toolEnd(tool: "bash", toolCallId: "tc-1"), sessionId: "s1")
        conn.flushAndSuspend()
        conn.handleServerMessage(.agentEnd, sessionId: "s1")
        conn.flushAndSuspend()

        let tools = conn.reducer.items.filter {
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
        let conn = makeConnection()

        conn.handleServerMessage(.sessionEnded(reason: "stopped"), sessionId: "s1")
        conn.flushAndSuspend()

        let system = conn.reducer.items.filter {
            if case .systemEvent = $0 { return true }
            return false
        }
        #expect(system.count == 1)
    }

    @MainActor
    @Test func routeError() {
        let conn = makeConnection()

        conn.handleServerMessage(.error(message: "Something failed", code: nil, fatal: false), sessionId: "s1")
        conn.flushAndSuspend()

        let errors = conn.reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(errors.count == 1)
    }

    @MainActor
    @Test func routeExtensionUIRequest() {
        let conn = makeConnection()
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
        let conn = makeConnection()

        conn.handleServerMessage(
            .extensionUINotification(method: "notify", message: "Task complete", notifyType: "info", statusKey: nil, statusText: nil),
            sessionId: "s1"
        )

        #expect(conn.extensionToast == "Task complete")
    }

    @MainActor
    @Test func routeUnknownIsNoOp() {
        let conn = makeConnection()
        let preCount = conn.reducer.items.count

        conn.handleServerMessage(.unknown(type: "future_type"), sessionId: "s1")

        #expect(conn.reducer.items.count == preCount)
    }

    // MARK: - Stale session guard

    @MainActor
    @Test func staleSessionMessageIgnored() {
        let conn = makeConnection(sessionId: "s1")

        // Send message for a different session
        let session = makeSession(id: "s2", status: .busy)
        conn.handleServerMessage(.connected(session: session), sessionId: "s2")

        // Session store should NOT have s2 (message was for wrong active session)
        #expect(conn.sessionStore.sessions.isEmpty)
    }

    // MARK: - disconnectSession

    @MainActor
    @Test func disconnectSessionClearsActiveId() {
        let conn = makeConnection(sessionId: "s1")

        conn.disconnectSession()

        // After disconnect, messages should be ignored (no active session)
        let session = makeSession(status: .busy)
        conn.handleServerMessage(.connected(session: session), sessionId: "s1")
        #expect(conn.sessionStore.sessions.isEmpty)
    }

    // MARK: - flushAndSuspend

    @MainActor
    @Test func flushAndSuspendDelivers() {
        let conn = makeConnection()

        conn.handleServerMessage(.agentStart, sessionId: "s1")
        conn.handleServerMessage(.textDelta(delta: "buffered"), sessionId: "s1")
        // textDelta is buffered in coalescer — not yet in reducer
        // flushAndSuspend forces delivery
        conn.flushAndSuspend()

        let has = conn.reducer.items.contains {
            if case .assistantMessage = $0 { return true }
            return false
        }
        #expect(has)
    }

    // MARK: - Send ACK integration

    @MainActor
    @Test func sendAckSuccessForPromptSteerAndFollowUp() async throws {
        for command in AckCommand.allCases {
            let conn = ServerConnection()
            conn._setActiveSessionIdForTesting("s1")

            var sentRequestId: String?
            conn._sendMessageForTesting = { message in
                guard let sent = extractAckRequest(from: message) else {
                    Issue.record("Expected prompt/steer/follow_up message")
                    return
                }
                #expect(sent.command == command.rawValue)
                #expect(sent.clientTurnId != nil)
                sentRequestId = sent.requestId

                if let requestId = sent.requestId {
                    conn.handleServerMessage(
                        .rpcResult(
                            command: sent.command,
                            requestId: requestId,
                            success: true,
                            data: nil,
                            error: nil
                        ),
                        sessionId: "s1"
                    )
                }
            }

            try await command.send(using: conn, text: "hello")
            #expect(sentRequestId != nil, "\(command.rawValue) should include requestId")
        }
    }

    @MainActor
    @Test func sendAckUsesTurnAckStages() async throws {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        conn._sendMessageForTesting = { message in
            guard let sent = extractAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId else {
                Issue.record("Expected turn command with clientTurnId")
                return
            }

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .accepted,
                    requestId: sent.requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: sent.requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        try await conn.sendPrompt("hello")
    }

    @MainActor
    @Test func sendRetryReusesClientTurnId() async throws {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        var attempt = 0
        var seenTurnIds: [String] = []
        var seenRequestIds: [String] = []

        conn._sendMessageForTesting = { message in
            guard let sent = extractAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId,
                  let requestId = sent.requestId else {
                Issue.record("Expected turn command with requestId/clientTurnId")
                return
            }

            attempt += 1
            seenTurnIds.append(clientTurnId)
            seenRequestIds.append(requestId)

            if attempt == 1 {
                throw WebSocketError.notConnected
            }

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        try await conn.sendPrompt("hello")

        #expect(attempt == 2)
        #expect(seenTurnIds.count == 2)
        #expect(seenTurnIds[0] == seenTurnIds[1])
        #expect(seenRequestIds.count == 2)
        #expect(seenRequestIds[0] == seenRequestIds[1])
    }

    @MainActor
    @Test func sendAckRejectedForPromptSteerAndFollowUp() async {
        for command in AckCommand.allCases {
            let conn = ServerConnection()
            conn._setActiveSessionIdForTesting("s1")

            conn._sendMessageForTesting = { message in
                guard let sent = extractAckRequest(from: message) else {
                    Issue.record("Expected prompt/steer/follow_up message")
                    return
                }
                #expect(sent.clientTurnId != nil)

                if let requestId = sent.requestId {
                    conn.handleServerMessage(
                        .rpcResult(
                            command: sent.command,
                            requestId: requestId,
                            success: false,
                            data: nil,
                            error: "rejected-by-test"
                        ),
                        sessionId: "s1"
                    )
                }
            }

            do {
                try await command.send(using: conn, text: "hello")
                Issue.record("Expected \(command.rawValue) rejection")
            } catch let error as SendAckError {
                switch error {
                case .rejected(let rejectedCommand, let reason):
                    #expect(rejectedCommand == command.rawValue)
                    #expect(reason == "rejected-by-test")
                default:
                    Issue.record("Expected rejected error, got \(error)")
                }
            } catch {
                Issue.record("Expected SendAckError.rejected, got \(error)")
            }
        }
    }

    @MainActor
    @Test func sendAckTimeoutForPromptSteerAndFollowUp() async {
        for command in AckCommand.allCases {
            let conn = ServerConnection()
            conn._setActiveSessionIdForTesting("s1")
            conn._sendAckTimeoutForTesting = .milliseconds(120)

            // Simulate successful socket write with no rpc_result ack arriving.
            conn._sendMessageForTesting = { _ in }

            do {
                try await command.send(using: conn, text: "hello")
                Issue.record("Expected \(command.rawValue) timeout")
            } catch let error as SendAckError {
                switch error {
                case .timeout(let timedOutCommand):
                    #expect(timedOutCommand == command.rawValue)
                default:
                    Issue.record("Expected timeout error, got \(error)")
                }
            } catch {
                Issue.record("Expected SendAckError.timeout, got \(error)")
            }
        }
    }

    // MARK: - requestState

    @MainActor
    @Test func requestStateUsesDispatchSendHook() async throws {
        let conn = ServerConnection()
        var sawGetState = false

        conn._sendMessageForTesting = { message in
            if case .getState = message {
                sawGetState = true
            }
        }

        try await conn.requestState()
        #expect(sawGetState)
    }

    // MARK: - isConnected

    @MainActor
    @Test func isConnectedDefaultFalse() {
        let conn = ServerConnection()
        #expect(!conn.isConnected)
    }
}

private enum AckCommand: CaseIterable {
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

private func extractAckRequest(from message: ClientMessage) -> (command: String, requestId: String?, clientTurnId: String?)? {
    switch message {
    case .prompt(_, _, _, let requestId, let clientTurnId):
        return ("prompt", requestId, clientTurnId)
    case .steer(_, _, let requestId, let clientTurnId):
        return ("steer", requestId, clientTurnId)
    case .followUp(_, _, let requestId, let clientTurnId):
        return ("follow_up", requestId, clientTurnId)
    default:
        return nil
    }
}

private func makeGetCommandsPayload(
    _ commands: [(name: String, description: String, source: String)]
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

private func waitForCondition(
    timeoutMs: Int = 1_000,
    pollMs: Int = 20,
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    let attempts = max(1, timeoutMs / max(1, pollMs))
    for _ in 0..<attempts {
        if await predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(pollMs))
    }
    return await predicate()
}
