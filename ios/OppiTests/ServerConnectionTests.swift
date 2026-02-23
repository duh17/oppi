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
            firstMessage: nil,
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
            .commandResult(
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
    @Test func routeAgentStartSetsSessionBusyWithoutStateMessage() {
        let conn = makeConnection()
        conn.sessionStore.upsert(makeSession(status: .ready))

        conn.handleServerMessage(.agentStart, sessionId: "s1")

        #expect(conn.sessionStore.sessions.first?.status == .busy)
    }

    @MainActor
    @Test func routeAgentEndSetsSessionReadyWithoutStateMessage() {
        let conn = makeConnection()
        conn.sessionStore.upsert(makeSession(status: .busy))

        conn.handleServerMessage(.agentEnd, sessionId: "s1")

        #expect(conn.sessionStore.sessions.first?.status == .ready)
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
    @Test func routeMissingFullSubscriptionErrorTriggersAutoRecover() async {
        let conn = makeConnection()
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

        #expect(await waitForCondition(timeoutMs: 500) { await subscribeCounter.count() == 1 })

        conn.flushAndSuspend()
        let errors = conn.reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(errors.isEmpty)
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
                        .commandResult(
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
                        .commandResult(
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

            // Simulate successful socket write with no command_result ack arriving.
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
                    .commandResult(
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
                    .commandResult(
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
    @Test func forkFromTimelineEntryParsesForkMessageIdField() async throws {
        let conn = makeConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                conn.handleServerMessage(
                    .commandResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "id": .string("fork-entry-123"),
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
                    .commandResult(
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

        try await conn.forkFromTimelineEntry("fork-entry-123")

        #expect(sentTypes == ["get_fork_messages", "fork"])
        #expect(forkEntryId == "fork-entry-123")
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
                    .commandResult(
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
                    .commandResult(
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
                    .commandResult(
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

private actor MessageCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func count() -> Int {
        value
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
            firstMessage: nil,
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

// MARK: - Stream Lifecycle

@Suite("Stream Lifecycle")
struct StreamLifecycleTests {

    @MainActor
    private func makeConnection() -> ServerConnection {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "localhost", port: 7749, token: "sk_test", name: "Test"
        ))
        return conn
    }

    // MARK: - connectStream idempotency

    @MainActor
    @Test func connectStreamIsIdempotentWhileActive() {
        let conn = makeConnection()

        // Simulate an active consumption task by setting it directly
        let sentinel = Task<Void, Never> { }
        conn.streamConsumptionTask = sentinel
        conn.wsClient?._setStatusForTesting(.connected)

        conn.connectStream()

        // Should not replace the existing task (identity check via cancel state)
        #expect(!sentinel.isCancelled,
                "Should not cancel existing task when one is active and WS is connected")
    }

    @MainActor
    @Test func connectStreamRestartsWhenTaskExistsButWSDisconnected() {
        let conn = makeConnection()

        // Simulate a zombie consumption task (completed but non-nil)
        // with a disconnected WS
        conn.streamConsumptionTask = Task { }
        conn.wsClient?._setStatusForTesting(.disconnected)

        conn.connectStream()

        // Should have created a NEW task (the old zombie was replaced)
        #expect(conn.streamConsumptionTask != nil,
                "Should create new task when WS is disconnected")
    }

    @MainActor
    @Test func connectStreamCreatesTaskWhenNil() {
        let conn = makeConnection()

        #expect(conn.streamConsumptionTask == nil)

        conn.connectStream()

        #expect(conn.streamConsumptionTask != nil,
                "Should create task when none exists")
    }

    // MARK: - streamConsumptionTask self-cleanup

    @MainActor
    @Test func consumptionTaskNilsItselfWhenStreamEnds() async {
        let conn = makeConnection()

        // Create a stream that immediately ends
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

        // Wait for the task to complete and nil itself out
        let cleaned = await waitForCondition(timeoutMs: 500) {
            await MainActor.run { conn.streamConsumptionTask == nil }
        }

        #expect(cleaned, "streamConsumptionTask should nil itself after stream ends")
    }

    // MARK: - disconnectStream cleanup

    @MainActor
    @Test func disconnectStreamCleansUpEverything() {
        let conn = makeConnection()
        conn.streamConsumptionTask = Task { }

        // Add a session continuation
        let (_, continuation) = AsyncStream<ServerMessage>.makeStream()
        conn.sessionContinuations["s1"] = continuation

        conn.disconnectStream()

        #expect(conn.streamConsumptionTask == nil,
                "Should nil out consumption task")
        #expect(conn.sessionContinuations.isEmpty,
                "Should clear all session continuations")
    }

    // MARK: - handleStreamReconnected re-subscribes

    @MainActor
    @Test func streamConnectedMessageTriggersResubscribe() {
        let conn = makeConnection()
        conn._setActiveSessionIdForTesting("s1")

        // Track that routeStreamMessage correctly identifies stream_connected
        // and does not yield it to session continuations (it's handled at stream level)
        var yieldedToSession = false
        let stream = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }
        let consumeTask = Task {
            for await _ in stream {
                await MainActor.run { yieldedToSession = true }
            }
        }

        // stream_connected should NOT be yielded to session continuations
        let streamMsg = StreamMessage(
            sessionId: nil,
            streamSeq: nil,
            seq: nil,
            currentSeq: nil,
            message: .streamConnected(userName: "test")
        )
        conn.routeStreamMessage(streamMsg)

        // stream_connected returns early — should not reach session continuation
        #expect(!yieldedToSession,
                "stream_connected should be handled at stream level, not yielded to sessions")
        consumeTask.cancel()
    }

    // MARK: - routeStreamMessage routing

    @MainActor
    @Test func routeStreamMessageYieldsToSessionContinuation() async {
        let conn = makeConnection()
        conn._setActiveSessionIdForTesting("s1")

        var receivedMessages: [ServerMessage] = []
        let stream = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }

        // Start consuming
        let consumeTask = Task {
            for await msg in stream {
                await MainActor.run { receivedMessages.append(msg) }
            }
        }

        // Route a permission_request for the active session
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

        let received = await waitForCondition(timeoutMs: 500) {
            await MainActor.run { !receivedMessages.isEmpty }
        }

        consumeTask.cancel()

        #expect(received, "Message should be yielded to session continuation")
    }

    @MainActor
    @Test func routeStreamMessageHandlesCrossSessionPermission() {
        let conn = makeConnection()
        conn._setActiveSessionIdForTesting("s1")

        // Route a permission from a DIFFERENT session (cross-session)
        let permRequest = PermissionRequest(
            id: "p2", sessionId: "s2", tool: "bash",
            input: [:], displaySummary: "cross-session", reason: "",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        let streamMsg = StreamMessage(
            sessionId: "s2",
            streamSeq: 2,
            seq: nil,
            currentSeq: nil,
            message: .permissionRequest(permRequest)
        )
        conn.routeStreamMessage(streamMsg)

        // Cross-session permission should be added to the store
        #expect(conn.permissionStore.pending.count == 1,
                "Cross-session permission should be added to store")
        #expect(conn.permissionStore.pending.first?.id == "p2")
    }

    @MainActor
    @Test func respondToCrossSessionPermissionDoesNotPolluteActiveTimeline() async throws {
        let conn = makeConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }  // stub WS send

        // Add a permission belonging to a DIFFERENT session
        let crossPerm = PermissionRequest(
            id: "xp1", sessionId: "s2", tool: "bash",
            input: [:], displaySummary: "cross-session cmd", reason: "",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        conn.permissionStore.add(crossPerm)

        // Approve it while viewing session s1
        try await conn.respondToPermission(id: "xp1", action: .allow)

        // The "Allowed" marker must NOT appear in the active session's timeline
        let hasMarker = conn.reducer.items.contains {
            if case .permissionResolved(let id, _, _, _) = $0 { return id == "xp1" }
            return false
        }
        #expect(!hasMarker,
                "Cross-session permission approval should not inject marker into active session timeline")

        // Permission should still be removed from the store
        #expect(conn.permissionStore.pending.isEmpty,
                "Permission should be consumed from store after response")
    }

    @MainActor
    @Test func respondToSameSessionPermissionInjectsMarker() async throws {
        let conn = makeConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }

        // Add a permission for the ACTIVE session
        let perm = PermissionRequest(
            id: "sp1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "same-session cmd", reason: "",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        conn.permissionStore.add(perm)

        try await conn.respondToPermission(id: "sp1", action: .allow)

        // The marker SHOULD appear for the active session
        let hasMarker = conn.reducer.items.contains {
            if case .permissionResolved(let id, _, _, _) = $0 { return id == "sp1" }
            return false
        }
        #expect(hasMarker,
                "Same-session permission approval should inject marker into active timeline")
    }

    // MARK: - reconnectIfNeeded restarts dead stream

    @MainActor
    @Test func reconnectIfNeededRestartsDeadStream() async {
        let conn = makeConnection()

        // Simulate a dead WS (disconnected, no consumption task)
        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        // Track whether connectStream re-creates the task
        #expect(conn.streamConsumptionTask == nil)

        await conn.reconnectIfNeeded()

        // connectStream should have been called, creating a new task
        #expect(conn.streamConsumptionTask != nil,
                "reconnectIfNeeded should restart a dead stream")
    }

    @MainActor
    @Test func reconnectIfNeededSkipsAliveStream() async {
        let conn = makeConnection()

        // Simulate an active WS
        conn.wsClient?._setStatusForTesting(.connected)
        let sentinel = Task<Void, Never> { }
        conn.streamConsumptionTask = sentinel

        await conn.reconnectIfNeeded()

        // The existing task should not have been cancelled/replaced
        #expect(!sentinel.isCancelled,
                "Should not replace an active consumption task")
    }

    // MARK: - routeStreamMessage resolves subscribe waiter eagerly

    @MainActor
    @Test func routeStreamMessageResolvesSubscribeWaiterBeforePerSessionRouting() async {
        let conn = makeConnection()
        conn._setActiveSessionIdForTesting("s1")

        // Simulates the subscribe await in streamSession — the waiter is
        // pending but the per-session stream consumer hasn't started yet.
        let pending = PendingCommand(command: "subscribe", requestId: "req-1")
        conn.commands.registerCommand(pending)

        _ = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }

        // Route the subscribe command_result through the stream mux
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

        // The waiter should be resolved immediately — no need to consume the per-session stream
        let result = try? await pending.waiter.wait()
        #expect(result != nil, "Subscribe waiter should be resolved eagerly by routeStreamMessage")
    }

    @MainActor
    @Test func routeStreamMessageDoesNotEagerlyResolveNonSubscribeCommands() {
        let conn = makeConnection()
        conn._setActiveSessionIdForTesting("s1")

        // Non-subscribe commands resolve through the normal consumer path
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

        // Should still be pending — resolved later by handleCommandResult in the consumer
        #expect(conn.commands.pendingCommandsByRequestId["req-m"] != nil,
                "Non-subscribe commands should not be resolved by routeStreamMessage")
    }

    // MARK: - Pending unsubscribe cancelled on resubscribe

    @MainActor
    @Test func pendingUnsubscribeCancelledWhenReenteringSameSession() {
        let conn = makeConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }

        // Simulate disconnectSession which creates a pending unsubscribe
        conn.disconnectSession()

        // There should be a pending unsubscribe for s1
        #expect(conn.pendingUnsubscribeTasks["s1"] != nil,
                "disconnectSession should track pending unsubscribe")

        // Now cancel it as streamSession would
        if let pendingUnsub = conn.pendingUnsubscribeTasks.removeValue(forKey: "s1") {
            pendingUnsub.cancel()
        }

        #expect(conn.pendingUnsubscribeTasks["s1"] == nil,
                "Pending unsubscribe should be cancelled before resubscribe")
    }

    @MainActor
    @Test func disconnectStreamCancelsPendingUnsubscribes() {
        let conn = makeConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }

        conn.disconnectSession()
        #expect(!conn.pendingUnsubscribeTasks.isEmpty)

        conn.disconnectStream()
        #expect(conn.pendingUnsubscribeTasks.isEmpty,
                "disconnectStream should cancel all pending unsubscribes")
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
