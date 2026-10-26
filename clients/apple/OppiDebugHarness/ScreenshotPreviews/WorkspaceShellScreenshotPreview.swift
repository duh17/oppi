#if DEBUG
import SwiftUI

/// Production All Sessions chrome in the real workspace shell, with in-memory
/// sessions so the rail can be captured without a paired server
/// (`SCREENSHOT_SCREEN=workspace-shell`; the router's navigation smoke test
/// drives it). `SCREENSHOT_ORIENTATION` poses the Duo.
struct WorkspaceShellScreenshotPreview: View {
    @State private var root: AppRootEnvironment = .preview(coordinator: Self.makeCoordinator())

    var body: some View {
        WorkspaceShellPreview(root: root)
            .ignoresSafeArea()
            .preferredColorScheme(root.themeStore.preferredColorScheme)
            .onAppear { ScreenshotPreviewOrientation.applyRequested() }
    }

    private static let server = pairedServer()
    private static let workspace = Workspace(
        id: "oppi",
        name: "oppi",
        description: "Preview workspace",
        icon: .symbol("iphone.and.arrow.forward"),
        systemPrompt: nil,
        hostMount: "~/workspace/oppi",
        gitStatusEnabled: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    private static func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview([server])
        guard coordinator.switchToServer(server),
              let connection = coordinator.connection(for: server.id) else { return coordinator }
        connection.workspaceStore.upsert(workspace, serverId: server.id)
        // Sampling on, so the host pill offers Server Metrics (its route smoke).
        connection.serverMetricsEnabled = true
        connection.sessionStore.switchServer(to: server.id)
        connection.sessionStore.sessions = [
            session(id: "rail-1", name: "Fill the Duo side rail", status: .busy, minutesAgo: 2),
            session(id: "rail-2", name: "Keep Message on the phone bar", status: .ready, minutesAgo: 18),
        ]
        return coordinator
    }

    private static func pairedServer() -> PairedServer {
        guard let server = PairedServer(from: ServerCredentials(
            host: "mac-studio.local",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            scheme: .https,
            serverFingerprint: "sha256:rail-inbox-preview",
            tlsCertFingerprint: "sha256:rail-inbox-preview-leaf"
        )) else {
            preconditionFailure("rail inbox preview server")
        }
        return server
    }

    private static func session(
        id: String,
        name: String,
        status: SessionStatus,
        minutesAgo: Double
    ) -> Session {
        let lastActivity = Date().addingTimeInterval(-minutesAgo * 60)
        return Session(
            id: id,
            workspaceId: workspace.id,
            workspaceName: workspace.name,
            name: name,
            status: status,
            createdAt: lastActivity.addingTimeInterval(-600),
            lastActivity: lastActivity,
            model: "anthropic/claude-opus-5-5",
            messageCount: 4,
            tokens: TokenUsage(input: 8_000, output: 1_200),
            cost: 0.18
        )
    }
}
#endif
