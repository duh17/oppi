import SwiftUI

/// The sidebar's **Oppi Control** destination: asks the active server to find or
/// create its one durable control conversation (`POST /control-conversation`,
/// which also resumes a stopped one), then shows that row's chat on the control
/// route. Opening again finds the same conversation.
///
/// The route outlives the sidebar entry that opened it (lock-cover Switch Server,
/// unpairing the active server), so it re-checks the Durable Sessions gate for the
/// active server each time it opens and leaves the route when the gate is closed.
struct ControlConversationDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @AppStorage(AppPreferences.Experiments.durableSessionsKey) private var durableExperimentEnabled = false

    @State private var phase: Phase = .opening

    private enum Phase: Equatable {
        case opening
        case open(WorkspaceSessionNavTarget)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .opening:
                ProgressView("Opening Oppi Control…")
            case .open(let target):
                WorkspaceSessionScopedDestinationView(target: target)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Oppi Control Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await open() }
                    }
                    .accessibilityIdentifier("controlConversation.retry")
                }
            }
        }
        .task(id: coordinator.activeServerId) {
            await open()
        }
        .onChange(of: durableExperimentEnabled) { _, enabled in
            if !enabled { navigation.showAllWorkspaceSessions() }
        }
    }

    /// Durable must be on for this device and offered by the active server.
    private func isAvailable(on connection: ServerConnection) -> Bool {
        DurableSessions.isAvailable(
            experimentEnabled: durableExperimentEnabled,
            serverOffersDurable: connection.durableSessionsAvailable
        )
    }

    private func open() async {
        guard let serverId = coordinator.activeServerId else {
            // The active server was unpaired; there is nothing left to open.
            navigation.showAllWorkspaceSessions()
            return
        }
        phase = .opening
        guard await coordinator.switchToServerReady(serverId),
              let connection = coordinator.connection(for: serverId),
              let api = connection.apiClient else {
            phase = .failed(String(localized: "Could not connect to this server."))
            return
        }
        // Capabilities are known once the connection is ready. A server that does not
        // offer durable sessions has no control conversation to open.
        guard coordinator.activeServerId == serverId else { return }
        guard isAvailable(on: connection) else {
            navigation.showAllWorkspaceSessions()
            return
        }
        do {
            let session = try await api.openControlConversation()
            _ = connection.sessionStore.cacheSessionForNavigation(session)
            phase = .open(WorkspaceSessionNavTarget(
                serverId: serverId,
                sessionId: session.id,
                routeScope: .control
            ))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
