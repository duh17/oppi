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
        // Set active session ID by streaming (returns AsyncStream we don't consume)
        _ = conn.streamSession(sessionId)
        return conn
    }

    private func makeSession(id: String = "s1", status: SessionStatus = .ready) -> Session {
        let json = """
        {
            "id": "\(id)", "userId": "u1", "status": "\(status.rawValue)",
            "createdAt": 1700000000000, "lastActivity": 1700000000000,
            "messageCount": 0, "tokens": {"input": 0, "output": 0}, "cost": 0
        }
        """
        return try! JSONDecoder().decode(Session.self, from: json.data(using: .utf8)!)
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
        conn.handleServerMessage(.toolStart(tool: "bash", args: ["command": "ls"]), sessionId: "s1")
        conn.flushAndSuspend()
        conn.handleServerMessage(.toolOutput(output: "file.txt", isError: false), sessionId: "s1")
        conn.flushAndSuspend()
        conn.handleServerMessage(.toolEnd(tool: "bash"), sessionId: "s1")
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

        conn.handleServerMessage(.error(message: "Something failed"), sessionId: "s1")
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

    // MARK: - isConnected

    @MainActor
    @Test func isConnectedDefaultFalse() {
        let conn = ServerConnection()
        #expect(!conn.isConnected)
    }
}
