#if DEBUG
import SwiftUI

/// Durable Sessions experiment surfaces over an in-memory server that
/// advertises durable sessions: the Settings toggle, the sidebar's Durable
/// item under Terminal, and the Durable list. No network or Keychain writes.
struct DurableSessionsScreenshotPreview: View {
    enum Surface {
        case settings
        case sidebar
        case list
    }

    let surface: Surface
    @State private var coordinator: ConnectionCoordinator
    @State private var navigation = AppNavigation()

    init(surface: Surface) {
        self.surface = surface
        Self.applyPreviewDefaults()
        _coordinator = State(initialValue: Self.makeCoordinator())
    }

    var body: some View {
        content
            .environment(coordinator)
            .environment(coordinator.serverStore)
            .withServerScopedEnvironment(coordinator.activeConnection)
            .environment(navigation)
            .environment(ThemeStore())
            .preferredColorScheme(.dark)
            .accessibilityIdentifier("screenshot.ready")
    }

    @ViewBuilder
    private var content: some View {
        switch surface {
        case .settings:
            NavigationStack { SettingsView() }
        case .sidebar:
            WorkspaceSidebarView()
        case .list:
            NavigationStack { DurableSessionsView() }
        }
    }

    /// Volatile argument-domain values: the preview sees the experiments on and
    /// an SSH host configured, and nothing is written to the app's defaults.
    private static func applyPreviewDefaults() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[AppPreferences.Experiments.durableSessionsKey] = true
        arguments[AppPreferences.Experiments.sshTerminalKey] = true
        let profile = SSHTerminalProfile(host: "mac-studio.local", username: "chen")
        arguments[SSHTerminalProfileStore.storageKey] = try? JSONEncoder().encode(profile)
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    private static func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        guard let server = PairedServer(from: ServerCredentials(
            host: "mac-studio.local",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            scheme: .https,
            serverFingerprint: "sha256:durable-preview",
            tlsCertFingerprint: "sha256:durable-preview-leaf"
        )) else { return coordinator }
        coordinator.serverStore.replaceServersForPreview([server])
        guard coordinator.switchToServer(server),
              let connection = coordinator.connection(for: server.id) else { return coordinator }
        connection.setSplitStreamCapabilitiesForTesting(durableSessions: true)
        for workspace in workspaces {
            connection.workspaceStore.upsert(workspace, serverId: server.id)
        }
        connection.sessionStore.switchServer(to: server.id)
        connection.sessionStore.sessions = sessions
        return coordinator
    }

    private static let workspaces = [
        workspace(id: "oppi", name: "oppi", icon: "iphone.and.arrow.forward"),
        workspace(id: "kypu", name: "kypu", icon: "figure.run"),
    ]

    private static let sessions = [
        session(
            id: "durable-1", workspaceId: "oppi", name: "Spawn a scout for the flaky stop test",
            status: .busy, minutesAgo: 1, engine: .durable
        ),
        session(
            id: "durable-2", workspaceId: "kypu", name: "Backfill Garmin sleep scores",
            status: .ready, minutesAgo: 34, engine: .durable
        ),
        session(
            id: "durable-3", workspaceId: "oppi", name: "Fork from the queue edit and retry",
            status: .stopped, minutesAgo: 180, engine: .durable
        ),
        session(
            id: "classic-1", workspaceId: "oppi", name: "Classic session stays in All Sessions",
            status: .ready, minutesAgo: 5, engine: .classic
        ),
    ]

    private static func workspace(id: String, name: String, icon: String) -> Workspace {
        Workspace(
            id: id,
            name: name,
            description: nil,
            icon: .symbol(icon),
            systemPrompt: nil,
            hostMount: "~/workspace/\(id)",
            gitStatusEnabled: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func session(
        id: String,
        workspaceId: String,
        name: String,
        status: SessionStatus,
        minutesAgo: Double,
        engine: SessionEngine
    ) -> Session {
        let lastActivity = Date().addingTimeInterval(-minutesAgo * 60)
        return Session(
            id: id,
            workspaceId: workspaceId,
            workspaceName: workspaceId,
            name: name,
            status: status,
            createdAt: lastActivity.addingTimeInterval(-600),
            lastActivity: lastActivity,
            model: "anthropic/claude-opus-5-5",
            messageCount: 6,
            tokens: TokenUsage(input: 12_000, output: 2_400),
            cost: 0.42,
            engine: engine
        )
    }
}
#endif
