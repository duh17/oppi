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
        let conn = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .busy))

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
        let conn = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .stopping))

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
        let conn = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .stopping))

        conn.handleServerMessage(
            .stopConfirmed(source: .user, reason: nil),
            sessionId: "s1"
        )
        conn.flushAndSuspend()

        #expect(conn.sessionStore.sessions.first?.status == .ready)
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
    @Test func routeAgentStartAndTextAndEnd() {
        let conn = makeTestConnection()

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
        let conn = makeTestConnection()

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
        let conn = makeTestConnection()

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
        let conn = makeTestConnection()
        conn.sessionStore.upsert(makeTestSession(status: .busy))

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
        let conn = makeTestConnection()

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

// MARK: - Private helpers

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
