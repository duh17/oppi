import SwiftUI

/// The sidebar's **Oppi Control** destination: asks the active server to find or
/// create its one durable control conversation (`POST /control-conversation`,
/// which also resumes a stopped one), then shows that row's chat on the control
/// route. Opening again finds the same conversation.
struct ControlConversationDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator

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
    }

    private func open() async {
        guard let serverId = coordinator.activeServerId else {
            phase = .failed(String(localized: "No server selected."))
            return
        }
        phase = .opening
        guard await coordinator.switchToServerReady(serverId),
              let connection = coordinator.connection(for: serverId),
              let api = connection.apiClient else {
            phase = .failed(String(localized: "Could not connect to this server."))
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
