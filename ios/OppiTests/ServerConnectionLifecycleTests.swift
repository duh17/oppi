import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Lifecycle")
struct ServerConnectionLifecycleTests {

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

    @MainActor
    @Test func disconnectSessionClearsActiveId() {
        let conn = makeTestConnection(sessionId: "s1")

        conn.disconnectSession()

        // After disconnect, messages should be ignored (no active session)
        let session = makeTestSession(status: .busy)
        conn.handleServerMessage(.connected(session: session), sessionId: "s1")
        #expect(conn.sessionStore.sessions.isEmpty)
    }

    @MainActor
    @Test func flushAndSuspendDelivers() {
        let conn = makeTestConnection()

        conn.handleServerMessage(.agentStart, sessionId: "s1")
        conn.handleServerMessage(.textDelta(delta: "buffered"), sessionId: "s1")
        conn.flushAndSuspend()

        let has = conn.reducer.items.contains {
            if case .assistantMessage = $0 { return true }
            return false
        }
        #expect(has)
    }

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

    @MainActor
    @Test func isConnectedDefaultFalse() {
        let conn = ServerConnection()
        #expect(!conn.isConnected)
    }

    @MainActor
    @Test func switchServerConfiguresNewServer() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_studio",
            name: "studio", serverFingerprint: "sha256:studio-fp"
        )
        guard let server = PairedServer(from: creds) else {
            Issue.record("Expected PairedServer to be created from credentials")
            return
        }

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
        guard let server = PairedServer(from: creds) else {
            Issue.record("Expected PairedServer to be created from credentials")
            return
        }

        _ = conn.switchServer(to: server)
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
        guard let server1 = PairedServer(from: creds1),
              let server2 = PairedServer(from: creds2)
        else {
            Issue.record("Expected PairedServer values to be created from credentials")
            return
        }

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
