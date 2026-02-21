import Testing
import Foundation
@testable import Oppi

@Suite("Permission approval policy")
struct PermissionApprovalPolicyTests {
    private func makeRequest(id: String = "p1", tool: String) -> PermissionRequest {
        PermissionRequest(
            id: id,
            sessionId: "s1",
            tool: tool,
            input: [:],
            displaySummary: tool,
            reason: "reason",
            timeoutAt: Date().addingTimeInterval(120)
        )
    }

    @Test func policyToolsAreAlwaysOneShot() {
        let choice = PermissionResponseChoice(action: .allow, scope: .global, expiresInMs: 60_000)
        let normalized = PermissionApprovalPolicy.normalizedChoice(tool: "policy.update", choice: choice)

        #expect(normalized.action == .allow)
        #expect(normalized.scope == .once)
        #expect(normalized.expiresInMs == nil)
    }

    @Test func denySessionDowngradesToOneShot() {
        let choice = PermissionResponseChoice(action: .deny, scope: .session, expiresInMs: 60_000)
        let normalized = PermissionApprovalPolicy.normalizedChoice(tool: "bash", choice: choice)

        #expect(normalized.action == .deny)
        #expect(normalized.scope == .once)
        #expect(normalized.expiresInMs == nil)
    }

    @Test func nonPolicyOptionsExposePersistentChoices() {
        let options = PermissionApprovalPolicy.options(for: makeRequest(tool: "bash"))

        #expect(options.map(\.id) == ["allow-session", "allow-global", "deny-global"])
    }

    @Test func policyToolsExposeNoExtraOptions() {
        let options = PermissionApprovalPolicy.options(for: makeRequest(tool: "policy.update"))
        #expect(options.isEmpty)
    }

    @MainActor
    @Test func serverConnectionNormalizesPolicyResponsesBeforeSend() async throws {
        let connection = ServerConnection()
        _ = connection.configure(credentials: ServerCredentials(
            host: "localhost",
            port: 7749,
            token: "sk_test",
            name: "Test"
        ))
        connection._setActiveSessionIdForTesting("s1")

        connection.permissionStore.add(makeRequest(id: "perm-policy", tool: "policy.update"))

        var sentMessage: ClientMessage?
        connection._sendMessageForTesting = { message in
            sentMessage = message
        }

        try await connection.respondToPermission(
            id: "perm-policy",
            action: .allow,
            scope: .global,
            expiresInMs: 120_000
        )

        guard case .permissionResponse(_, let action, let scope, let expiresInMs, _) = sentMessage else {
            Issue.record("Expected permission_response to be sent")
            return
        }

        #expect(action == .allow)
        #expect(scope == nil)
        #expect(expiresInMs == nil)
    }
}
