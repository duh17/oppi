import Testing
import Foundation
@testable import Oppi

// swiftlint:disable force_unwrapping large_tuple

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
            workspaceId: nil,
            workspaceName: nil,
            name: "Session",
            status: status,
            createdAt: now,
            lastActivity: now,
            model: nil,
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
    @Test func routeStopRequestedMarksStopping() {
        let conn = makeConnection()
        conn.sessionStore.upsert(makeSession(status: .busy))

        conn.handleServerMessage(
            .stopRequested(source: .user, reason: "Stopping current turn"),
            sessionId: "s1"
        )
        conn.flushAndSuspend()

        #expect(conn.sessionStore.sessions.first?.status == .stopping)

        let system = conn.reducer.items.filter {
            if case .systemEvent = $0 { return true }
            return false
        }
        #expect(system.count == 1)
    }

    @MainActor
    @Test func routeStopFailedRestoresBusyAndEmitsError() {
        let conn = makeConnection()
        conn.sessionStore.upsert(makeSession(status: .stopping))

        conn.handleServerMessage(
            .stopFailed(source: .timeout, reason: "Stop timed out after 8000ms"),
            sessionId: "s1"
        )
        conn.flushAndSuspend()

        #expect(conn.sessionStore.sessions.first?.status == .busy)

        let errors = conn.reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(errors.count == 1)
    }

    @MainActor
    @Test func routeStopConfirmedRestoresReady() {
        let conn = makeConnection()
        conn.sessionStore.upsert(makeSession(status: .stopping))

        conn.handleServerMessage(
            .stopConfirmed(source: .user, reason: nil),
            sessionId: "s1"
        )
        conn.flushAndSuspend()

        #expect(conn.sessionStore.sessions.first?.status == .ready)
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
            reason: "Destructive",
            timeoutAt: Date().addingTimeInterval(120)
        )

        conn.handleServerMessage(.permissionRequest(perm), sessionId: "s1")

        #expect(conn.permissionStore.count == 1)
        #expect(conn.permissionStore.pending[0].id == "p1")
    }

    @MainActor
    @Test func routePermissionRequestUsesActiveSessionForNotificationDecision() {
        let conn = makeConnection(sessionId: "stream-s1")
        conn.sessionStore.activeSessionId = "active-s1"

        let notificationService = PermissionNotificationService.shared
        let previousAppState = notificationService._applicationStateForTesting
        let previousDecisionHook = notificationService._onNotifyDecisionForTesting
        let previousSkipScheduling = notificationService._skipSchedulingForTesting

        notificationService._applicationStateForTesting = .active
        notificationService._skipSchedulingForTesting = true

        defer {
            notificationService._applicationStateForTesting = previousAppState
            notificationService._onNotifyDecisionForTesting = previousDecisionHook
            notificationService._skipSchedulingForTesting = previousSkipScheduling
        }

        var capturedRequestSessionId: String?
        var capturedActiveSessionId: String?
        var capturedShouldNotify: Bool?
        notificationService._onNotifyDecisionForTesting = { request, activeSessionId, shouldNotify in
            capturedRequestSessionId = request.sessionId
            capturedActiveSessionId = activeSessionId
            capturedShouldNotify = shouldNotify
        }

        let perm = PermissionRequest(
            id: "p2", sessionId: "other-s2", tool: "bash",
            input: ["command": .string("git push")],
            displaySummary: "bash: git push",
            reason: "Git push",
            timeoutAt: Date().addingTimeInterval(120)
        )

        conn.handleServerMessage(.permissionRequest(perm), sessionId: "stream-s1")

        if ReleaseFeatures.pushNotificationsEnabled {
            #expect(capturedRequestSessionId == "other-s2")
            #expect(capturedActiveSessionId == "active-s1")
            #expect(capturedShouldNotify == true)
        } else {
            #expect(capturedRequestSessionId == nil)
            #expect(capturedActiveSessionId == nil)
            #expect(capturedShouldNotify == nil)
        }
    }

    @MainActor
    @Test func routePermissionExpired() {
        let conn = makeConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: test",
            reason: "Test",
            timeoutAt: Date().addingTimeInterval(120)
        )
        conn.permissionStore.add(perm)

        conn.handleServerMessage(.permissionExpired(id: "p1", reason: "timeout"), sessionId: "s1")

        #expect(conn.permissionStore.pending.isEmpty)
    }

    @MainActor
    @Test func routePermissionCancelled() {
        let conn = makeConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: test",
            reason: "Test",
            timeoutAt: Date().addingTimeInterval(120)
        )
        conn.permissionStore.add(perm)

        conn.handleServerMessage(.permissionCancelled(id: "p1"), sessionId: "s1")

        #expect(conn.permissionStore.pending.isEmpty)
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
        conn.handleServerMessage(.toolStart(tool: "bash", args: ["command": "ls"], toolCallId: "tc-1", callSegments: nil), sessionId: "s1")
        conn.flushAndSuspend()
        conn.handleServerMessage(.toolOutput(output: "file.txt", isError: false, toolCallId: "tc-1"), sessionId: "s1")
        conn.flushAndSuspend()
        conn.handleServerMessage(.toolEnd(tool: "bash", toolCallId: "tc-1", details: nil, isError: false, resultSegments: nil), sessionId: "s1")
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
        conn.sessionStore.upsert(makeSession(status: .busy))

        conn.handleServerMessage(.sessionEnded(reason: "stopped"), sessionId: "s1")
        conn.flushAndSuspend()

        #expect(conn.sessionStore.sessions.first?.status == .stopped)

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
    @Test func sendAckStageCallbackReceivesProgressStages() async throws {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        let stageRecorder = AckStageRecorder()

        conn._sendMessageForTesting = { message in
            guard let sent = extractAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId,
                  let requestId = sent.requestId else {
                Issue.record("Expected turn command with requestId/clientTurnId")
                return
            }

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .accepted,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

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

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .started,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        try await conn.sendPrompt("hello", onAckStage: { stage in
            Task { await stageRecorder.record(stage) }
        })

        #expect(await waitForCondition(timeoutMs: 500) {
            await stageRecorder.snapshot() == [.accepted, .dispatched, .started]
        })
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
    @Test func sendPromptChurnAlwaysResolvesWithoutSilentDrop() async {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendAckTimeoutForTesting = .milliseconds(160)

        var requestOrder: [String: Int] = [:]
        var attemptsByRequest: [String: Int] = [:]
        var turnIdsByRequest: [String: Set<String>] = [:]
        var nextOrder = 0

        conn._sendMessageForTesting = { message in
            guard let sent = extractAckRequest(from: message),
                  let requestId = sent.requestId,
                  let clientTurnId = sent.clientTurnId else {
                Issue.record("Expected prompt/steer/follow_up with ids")
                return
            }

            if requestOrder[requestId] == nil {
                nextOrder += 1
                requestOrder[requestId] = nextOrder
            }

            attemptsByRequest[requestId, default: 0] += 1
            turnIdsByRequest[requestId, default: Set<String>()].insert(clientTurnId)

            let order = requestOrder[requestId] ?? 0
            let attempt = attemptsByRequest[requestId] ?? 0

            // Forced churn pattern:
            // - even-numbered logical sends always fail (both attempts)
            // - odd-numbered logical sends fail first, then succeed on retry
            if order.isMultiple(of: 2) {
                throw WebSocketError.notConnected
            }

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

        var delivered = 0
        var failed = 0

        for i in 0..<12 {
            do {
                try await conn.sendPrompt("msg-\(i)")
                delivered += 1
            } catch let error as WebSocketError {
                switch error {
                case .notConnected:
                    failed += 1
                default:
                    Issue.record("Unexpected WebSocket error: \(error)")
                }
            } catch let error as SendAckError {
                switch error {
                case .timeout:
                    failed += 1
                case .rejected:
                    Issue.record("Unexpected rejection during churn test: \(error)")
                }
            } catch {
                Issue.record("Unexpected churn send failure: \(error)")
            }
        }

        #expect(delivered + failed == 12)
        #expect(delivered == 6)
        #expect(failed == 6)
        #expect(requestOrder.count == 12)
        #expect(attemptsByRequest.values.allSatisfy { $0 == 2 })
        #expect(turnIdsByRequest.values.allSatisfy { $0.count == 1 })

        // Recovery check: after repeated churn/failures, a new send still resolves.
        do {
            try await conn.sendPrompt("recovery")
            delivered += 1
        } catch {
            Issue.record("Expected recovery prompt to succeed, got \(error)")
        }

        #expect(delivered == 7)
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

    // MARK: - Fork

    @MainActor
    @Test func forkFromTimelineEntryUsesGetForkMessagesThenFork() async throws {
        let conn = makeConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                conn.handleServerMessage(
                    .rpcResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "entryId": .string("entry-123"),
                                    "text": .string("Original user prompt"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork(let entryId, let requestId):
                sentTypes.append("fork")
                forkEntryId = entryId
                conn.handleServerMessage(
                    .rpcResult(
                        command: "fork",
                        requestId: requestId,
                        success: true,
                        data: .object([:]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        try await conn.forkFromTimelineEntry("entry-123")

        #expect(sentTypes == ["get_fork_messages", "fork"])
        #expect(forkEntryId == "entry-123")
    }

    @MainActor
    @Test func forkFromTimelineEntryParsesLegacyForkMessageIdField() async throws {
        let conn = makeConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                conn.handleServerMessage(
                    .rpcResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "id": .string("legacy-entry-123"),
                                    "text": .string("Original user prompt"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork(let entryId, let requestId):
                sentTypes.append("fork")
                forkEntryId = entryId
                conn.handleServerMessage(
                    .rpcResult(
                        command: "fork",
                        requestId: requestId,
                        success: true,
                        data: .object([:]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        try await conn.forkFromTimelineEntry("legacy-entry-123")

        #expect(sentTypes == ["get_fork_messages", "fork"])
        #expect(forkEntryId == "legacy-entry-123")
    }

    @MainActor
    @Test func forkFromTimelineEntryNormalizesTraceSyntheticIDs() async throws {
        let conn = makeConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                conn.handleServerMessage(
                    .rpcResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "entryId": .string("entry-123"),
                                    "text": .string("Original user prompt"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork(let entryId, let requestId):
                sentTypes.append("fork")
                forkEntryId = entryId
                conn.handleServerMessage(
                    .rpcResult(
                        command: "fork",
                        requestId: requestId,
                        success: true,
                        data: .object([:]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        try await conn.forkFromTimelineEntry("entry-123-text-0")

        #expect(sentTypes == ["get_fork_messages", "fork"])
        #expect(forkEntryId == "entry-123")
    }

    @MainActor
    @Test func forkFromTimelineEntryRejectsNonForkableEntry() async {
        let conn = makeConnection()
        var sentTypes: [String] = []

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                conn.handleServerMessage(
                    .rpcResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "entryId": .string("entry-allowed"),
                                    "text": .string("Allowed"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork:
                sentTypes.append("fork")

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        do {
            try await conn.forkFromTimelineEntry("entry-denied")
            Issue.record("Expected entryNotForkable error")
        } catch let error as ForkRequestError {
            #expect(error == .entryNotForkable)
        } catch {
            Issue.record("Expected ForkRequestError.entryNotForkable, got \(error)")
        }

        #expect(sentTypes == ["get_fork_messages"])
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

    // MARK: - switchServer

    @MainActor
    @Test func switchServerConfiguresNewServer() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_studio",
            name: "studio", serverFingerprint: "sha256:studio-fp"
        )
        let server = PairedServer(from: creds)!

        let result = conn.switchServer(to: server)
        #expect(result == true)
        #expect(conn.currentServerId == "sha256:studio-fp")
        #expect(conn.apiClient != nil)
    }

    @MainActor
    @Test func switchServerSkipsIfAlreadyTargeting() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_a",
            name: "studio", serverFingerprint: "sha256:same-fp"
        )
        let server = PairedServer(from: creds)!

        _ = conn.switchServer(to: server)
        // Switch to the same server again — should return true immediately
        let result = conn.switchServer(to: server)
        #expect(result == true)
        #expect(conn.currentServerId == "sha256:same-fp")
    }

    @MainActor
    @Test func switchServerChangesTarget() {
        let conn = ServerConnection()
        let creds1 = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_a",
            name: "studio", serverFingerprint: "sha256:fp-a"
        )
        let creds2 = ServerCredentials(
            host: "mini.ts.net", port: 7749, token: "sk_b",
            name: "mini", serverFingerprint: "sha256:fp-b"
        )
        let server1 = PairedServer(from: creds1)!
        let server2 = PairedServer(from: creds2)!

        _ = conn.switchServer(to: server1)
        #expect(conn.currentServerId == "sha256:fp-a")

        _ = conn.switchServer(to: server2)
        #expect(conn.currentServerId == "sha256:fp-b")
    }

    @MainActor
    @Test func currentServerIdNilByDefault() {
        let conn = ServerConnection()
        #expect(conn.currentServerId == nil)
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

private actor AckStageRecorder {
    private var stages: [TurnAckStage] = []

    func record(_ stage: TurnAckStage) {
        stages.append(stage)
    }

    func snapshot() -> [TurnAckStage] {
        stages
    }
}

// MARK: - Foreground Recovery

@Suite("Foreground Recovery")
struct ForegroundRecoveryTests {
    private func makeSession(id: String = "s1", workspaceId: String? = "w1") -> Session {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Session(
            id: id,
            workspaceId: workspaceId,
            workspaceName: nil,
            name: "Session",
            status: .ready,
            createdAt: now,
            lastActivity: now,
            model: nil,
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            contextTokens: nil,
            contextWindow: nil,
            lastMessage: nil,
            thinkingLevel: nil
        )
    }

    private func makeWorkspace(id: String = "w1") -> Workspace {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Workspace(
            id: id,
            name: "Workspace",
            description: nil,
            icon: nil,
            skills: [],
            systemPrompt: nil,
            hostMount: nil,
            memoryEnabled: nil,
            memoryNamespace: nil,
            extensions: nil,
            defaultModel: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    @MainActor
    @Test func reconnectIfNeededWithoutApiClientIsNoOp() async {
        let conn = ServerConnection()
        // No configure() call — apiClient is nil
        await conn.reconnectIfNeeded()
        // Should return immediately without crash
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @MainActor
    @Test func reconnectIfNeededReentrancyGuard() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        // Simulate the flag being set (as if another call is in progress)
        // by calling reconnectIfNeeded and checking the flag is reset after.
        await conn.reconnectIfNeeded()
        #expect(!conn.foregroundRecoveryInFlight, "Flag should be reset after completion")
    }

    @MainActor
    @Test func reconnectDoesNotTouchReducerTimeline() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))
        conn._setActiveSessionIdForTesting("s1")

        // Pre-populate reducer with items
        conn.reducer.process(.agentStart(sessionId: "s1"))
        conn.reducer.process(.textDelta(sessionId: "s1", delta: "hello world"))
        conn.reducer.process(.agentEnd(sessionId: "s1"))
        let countBefore = conn.reducer.items.count
        #expect(countBefore > 0)

        // reconnectIfNeeded should NOT call reducer.loadSession() which would
        // replace the timeline. API calls will fail (unreachable host) but the
        // reducer must remain untouched.
        await conn.reconnectIfNeeded()

        #expect(conn.reducer.items.count == countBefore,
                "Foreground recovery must not replace timeline — ChatSessionManager owns that")
    }

    @MainActor
    @Test func reconnectRefreshesWithoutActiveSession() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))
        // No activeSessionId set — should still attempt session list refresh
        // (API calls fail to unreachable host, but no crash)
        await conn.reconnectIfNeeded()
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @MainActor
    @Test func reconnectSkipsFullListRefreshWhenRecentSyncIsFresh() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeSession()])
        conn.sessionStore.markSyncSucceeded(at: now)
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)

        await conn.reconnectIfNeeded()

        // If full refresh ran, unreachable host would mark these as failed.
        #expect(conn.sessionStore.lastSyncFailed == false)
        #expect(conn.workspaceStore.lastSyncFailed == false)
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @MainActor
    @Test func reconnectPerformsFullListRefreshWhenCachedDataIsStale() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let stale = Date().addingTimeInterval(-600)
        conn.sessionStore.applyServerSnapshot([makeSession()])
        conn.sessionStore.markSyncSucceeded(at: stale)
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: stale)

        await conn.reconnectIfNeeded()

        #expect(conn.sessionStore.lastSyncFailed == true)
        #expect(conn.workspaceStore.lastSyncFailed == true)
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @MainActor
    @Test func refreshSessionListSkipsNetworkWhenFreshAndNotForced() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeSession()])
        conn.sessionStore.markSyncSucceeded(at: now)

        await conn.refreshSessionList(force: false)

        #expect(conn.sessionStore.lastSyncFailed == false)
    }

    @MainActor
    @Test func refreshSessionListSkipEmitsStructuredBreadcrumb() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeSession()])
        conn.sessionStore.markSyncSucceeded(at: now)

        var skipMetadata: [String: String] = [:]
        conn._onRefreshBreadcrumbForTesting = { message, metadata, _ in
            if message == "session_list.skip" {
                skipMetadata = metadata
            }
        }

        await conn.refreshSessionList(force: false)

        #expect(skipMetadata["force"] == "0")
        #expect(skipMetadata["cachedSessionCount"] == "1")
        #expect(skipMetadata["durationMs"] != nil)
    }

    @MainActor
    @Test func refreshSessionListForceRefreshesEvenWhenFresh() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeSession()])
        conn.sessionStore.markSyncSucceeded(at: now)

        await conn.refreshSessionList(force: true)

        #expect(conn.sessionStore.lastSyncFailed == true)
    }

    @MainActor
    @Test func refreshWorkspaceCatalogSkipsNetworkWhenFreshAndNotForced() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let now = Date()
        conn.workspaceStore.workspaces = [makeWorkspace()]
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)

        await conn.refreshWorkspaceCatalog(force: false)

        #expect(conn.workspaceStore.lastSyncFailed == false)
    }

    @MainActor
    @Test func refreshWorkspaceCatalogForceEmitsEndBreadcrumbWithCounts() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        var endMetadata: [String: String] = [:]
        var endLevel: ClientLogLevel?
        conn._onRefreshBreadcrumbForTesting = { message, metadata, level in
            if message == "workspace_catalog.end" {
                endMetadata = metadata
                endLevel = level
            }
        }

        await conn.refreshWorkspaceCatalog(force: true)

        #expect(endMetadata["force"] == "1")
        #expect(endMetadata["durationMs"] != nil)
        #expect(endMetadata["workspaceCount"] != nil)
        #expect(endMetadata["sessionCount"] != nil)
        #expect(endMetadata["skillCount"] != nil)
        #expect(endLevel != nil)
    }

    @MainActor
    @Test func flushAndSuspendDoesNotDisconnect() {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "localhost", port: 7749, token: "sk_test", name: "Test"
        ))
        conn._setActiveSessionIdForTesting("s1")

        conn.flushAndSuspend()

        // flushAndSuspend should NOT disconnect — iOS will suspend the stream,
        // and reconnectIfNeeded handles recovery on foreground.
        // The activeSessionId should remain set.
        #expect(conn.wsClient != nil, "WS client should not be nil after suspend")
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
