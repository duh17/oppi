import Foundation
import Observation

/// Opens Model Providers for the same visible host Server Settings shows.
///
/// Active host wins (`ServerSelection.resolveVisible`); frozen id is fallback.
@MainActor
enum ServerDetailModelProvidersNavigation {
    static func visibleServer(
        activeServerId: String?,
        frozenServer: PairedServer,
        servers: [PairedServer]
    ) -> PairedServer {
        ServerSelection.resolveVisible(
            activeId: activeServerId,
            frozenId: frozenServer.id,
            from: servers
        ) ?? servers.first { $0.id == frozenServer.id } ?? frozenServer
    }

    static func open(
        navigation: AppNavigation,
        activeServerId: String?,
        frozenServer: PairedServer,
        servers: [PairedServer]
    ) {
        let visible = visibleServer(
            activeServerId: activeServerId,
            frozenServer: frozenServer,
            servers: servers
        )
        navigation.openModelProviders(ModelProvidersNavTarget(serverId: visible.id))
    }
}

/// Provider sign-in calls for one flow. `APIClient` conforms; tests use a fake.
protocol ProviderAuthFlowClient: Sendable {
    func getProviderAuthFlow(flowId: String) async throws -> ProviderAuthFlowSnapshot
    func submitProviderAuthPromptResponse(flowId: String, value: String) async throws -> ProviderAuthFlowSnapshot
    func submitProviderAuthManualCode(flowId: String, input: String) async throws -> ProviderAuthFlowSnapshot
    func cancelProviderAuthFlow(flowId: String, reason: String?) async throws -> ProviderAuthFlowSnapshot
}

extension APIClient: ProviderAuthFlowClient {}

enum ProviderAuthFlowPresentation {
    static func statusText(_ status: ProviderAuthFlowSnapshot.Status) -> String {
        switch status {
        case .pending: "Starting…"
        case .awaitingExternal: "Waiting for sign-in to finish"
        case .awaitingPrompt: "Needs your answer"
        case .awaitingManualCode: "Waiting for the authorization code"
        case .completed: "Signed in"
        case .failed: "Sign-in failed"
        case .cancelled: "Cancelled"
        case .expired: "Expired"
        }
    }

    /// Only https, or http on loopback, may be opened. Mirrors the server check.
    static func signInURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" { return url.host?.isEmpty == false ? url : nil }
        guard scheme == "http", let host = url.host?.lowercased() else { return nil }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) ? url : nil
    }
}

/// One provider sign-in attempt, bound to the server client that started it.
///
/// Every follow-up call (poll, prompt, manual code, cancel) uses `client`, so a
/// later active-server change cannot send a pasted code to a different server.
/// Dismissing the sheet only stops showing the attempt; only `cancel` ends it.
@MainActor @Observable
final class ProviderAuthFlowAttempt {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let pollInterval: Duration = .milliseconds(1200)
    static let maxRetryDelay: Duration = .seconds(15)

    let serverId: String
    let serverName: String
    let providerName: String
    private let client: any ProviderAuthFlowClient
    private let sleep: Sleep

    private(set) var flow: ProviderAuthFlowSnapshot
    /// The server no longer knows this flow (404); nothing is left to poll or cancel.
    private(set) var isGone = false
    private(set) var isCancelling = false
    private(set) var isSubmitting = false
    /// Last failed poll. Polling keeps retrying; cleared by the next good read.
    private(set) var refreshError: String?
    var input = ""
    var actionError: String?

    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0

    init(
        flow: ProviderAuthFlowSnapshot,
        client: any ProviderAuthFlowClient,
        serverId: String,
        serverName: String,
        providerName: String,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.flow = flow
        self.client = client
        self.serverId = serverId
        self.serverName = serverName
        self.providerName = providerName
        self.sleep = sleep
    }

    /// Terminal on the server, or gone from it.
    var isSettled: Bool { isGone || flow.status.isTerminal }
    var isPolling: Bool { pollTask != nil }

    static func retryDelay(afterFailures failures: Int) -> Duration {
        let scaled = pollInterval * (1 << min(max(failures, 0), 6))
        return min(scaled, maxRetryDelay)
    }

    /// Starts or restarts polling. Any earlier poll's late result is ignored.
    func startPolling() {
        stopPolling()
        guard !isSettled else { return }

        let generation = pollGeneration
        let flowId = flow.flowId
        let client = client
        let sleep = sleep
        pollTask = Task {
            var failures = 0
            while !Task.isCancelled {
                do {
                    let snapshot = try await client.getProviderAuthFlow(flowId: flowId)
                    guard generation == self.pollGeneration else { return }
                    failures = 0
                    self.refreshError = nil
                    self.apply(snapshot)
                } catch {
                    guard generation == self.pollGeneration else { return }
                    if Self.isNotFound(error) {
                        self.isGone = true
                    } else {
                        failures += 1
                        self.refreshError = "Could not refresh sign-in status: \(error.localizedDescription). Retrying…"
                    }
                }
                if self.isSettled { break }
                try? await sleep(failures == 0 ? Self.pollInterval : Self.retryDelay(afterFailures: failures))
            }
            // A newer poll may already own the handle; only clear our own.
            if generation == self.pollGeneration {
                self.pollTask = nil
            }
        }
    }

    func stopPolling() {
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
    }

    /// The sheet closed without Cancel Sign-In. Never cancels the server flow.
    /// Returns whether to keep the attempt reachable: true while it is still live.
    func sheetDismissed() -> Bool {
        guard isSettled else { return true }
        stopPolling()
        return false
    }

    func submitPromptResponse(_ value: String) async {
        guard flow.status == .awaitingPrompt, !isSubmitting, !isCancelling else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let snapshot = try await client.submitProviderAuthPromptResponse(flowId: flow.flowId, value: value)
            apply(snapshot)
            input = ""
            actionError = nil
        } catch {
            actionError = "Failed to submit response: \(error.localizedDescription)"
        }
    }

    func submitManualCode() async {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flow.status == .awaitingManualCode, !code.isEmpty, !isSubmitting, !isCancelling else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let snapshot = try await client.submitProviderAuthManualCode(flowId: flow.flowId, input: code)
            apply(snapshot)
            input = ""
            actionError = nil
        } catch {
            actionError = "Failed to submit code: \(error.localizedDescription)"
        }
    }

    /// Returns true once the server acknowledged the cancel, or no longer has the flow.
    /// On failure the attempt stays live and `actionError` explains why.
    func cancel(reason: String) async -> Bool {
        guard !isSettled else { return true }
        guard !isCancelling else { return false }
        isCancelling = true
        actionError = nil
        defer { isCancelling = false }
        do {
            let snapshot = try await client.cancelProviderAuthFlow(flowId: flow.flowId, reason: reason)
            stopPolling()
            // The cancel reply is the server's latest word (it may say `completed`).
            if snapshot.flowId == flow.flowId { flow = snapshot }
            return true
        } catch {
            if Self.isNotFound(error) {
                stopPolling()
                isGone = true
                return true
            }
            actionError = "Failed to cancel login: \(error.localizedDescription)"
            return false
        }
    }

    /// Applies a server snapshot for this flow unless it is older than what is shown
    /// or the flow already settled.
    private func apply(_ snapshot: ProviderAuthFlowSnapshot) {
        guard snapshot.flowId == flow.flowId,
              !flow.status.isTerminal,
              snapshot.updatedAt >= flow.updatedAt else { return }
        flow = snapshot
    }

    private static func isNotFound(_ error: Error) -> Bool {
        switch error as? APIError {
        case .server(let status, _), .codedServer(let status, _, _):
            status == 404
        default:
            false
        }
    }
}
