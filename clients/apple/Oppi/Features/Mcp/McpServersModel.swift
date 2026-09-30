import Foundation

/// State behind the MCP Servers list. The host's list stays readable during a sign-in and
/// reports the flow, so a fresh view can adopt it and never needs local memory of it.
@MainActor @Observable
final class McpServersModel {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// A cancelled flow's child is reaped within ~2s; keep asking for a live list this long.
    static let settlePollInterval: Duration = .milliseconds(700)
    static let settlePollLimit = 20

    /// The last good response. Only a different host, never a skipped or failed refresh, clears it.
    private(set) var snapshot: McpServersResponse?
    private(set) var error: String?
    private(set) var loading = false
    let signIn = McpSignInOwner()

    private var generation = 0
    private var snapshotHostId: String?
    private let sleep: Sleep

    init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func refresh(
        hostId: String,
        hostName: String,
        flowClient: any ProviderAuthFlowClient,
        list: () async throws -> McpServersResponse
    ) async {
        generation += 1
        let token = generation
        if snapshotHostId != hostId {
            snapshot = nil
            snapshotHostId = hostId
        }
        loading = true
        defer { if token == generation { loading = false } }
        for _ in 0...Self.settlePollLimit {
            do {
                let result = try await list()
                guard token == generation else { return }
                snapshot = result
                error = nil
                guard let flow = result.activeSignIn else { return }
                signIn.reconcile(flow, client: flowClient, serverId: hostId, serverName: hostName)
                // A live flow ends through the owner's own polling. A terminal flow whose
                // child is still being reaped only delays the next live probe.
                guard flow.status.isTerminal else { return }
                try await sleep(Self.settlePollInterval)
                guard token == generation else { return }
            } catch {
                guard token == generation else { return }
                self.error = error.localizedDescription
                return
            }
        }
    }
}
