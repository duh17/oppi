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
    /// The host `snapshot` and `error` belong to.
    private(set) var snapshotHostId: String?
    private let sleep: Sleep

    init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// The last good response, only while it is `hostId`'s. A screen shows rows
    /// through this, so a host's servers never draw under another host.
    func snapshot(forHost hostId: String?) -> McpServersResponse? {
        hostId == snapshotHostId ? snapshot : nil
    }

    /// A different host is now the one shown: drop the old host's rows and
    /// error at once and ignore its probe still in flight. Call before waiting
    /// for the new host's client, so nothing of the old host shows meanwhile.
    func switchHost(to hostId: String) {
        guard snapshotHostId != hostId else { return }
        generation += 1
        snapshot = nil
        error = nil
        loading = false
        snapshotHostId = hostId
    }

    func refresh(
        hostId: String,
        hostName: String,
        flowClient: any ProviderAuthFlowClient,
        list: () async throws -> McpServersResponse
    ) async {
        switchHost(to: hostId)
        generation += 1
        let token = generation
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
                // A probe the page cancelled (it left the screen, or another
                // host became active) is control flow, not a failure: the list
                // keeps what it showed and offers no error row or Retry for it
                // when it comes back.
                guard !error.isLoadCancellation else { return }
                self.error = error.localizedDescription
                return
            }
        }
    }
}
