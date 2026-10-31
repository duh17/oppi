#if DEBUG
import UIKit

/// Production All Sessions chrome in the real workspace shell, with in-memory
/// sessions so the rail can be captured without a paired server
/// (`SCREENSHOT_SCREEN=workspace-shell`; the router's navigation smoke test
/// drives it). `SCREENSHOT_ORIENTATION` poses the Duo.
final class WorkspaceShellPreviewController: PreviewRootController {
    init() {
        let root = AppRootEnvironment.preview(coordinator: Self.makeCoordinator())
        super.init(root: root, themeStore: root.themeStore, content: WorkspaceShellController(root: root))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The SwiftUI preview posed the scene in `.onAppear`.
        ScreenshotPreviewOrientation.applyRequested()
    }

    private static let server = pairedServer()
    /// A second paired server, never connected: the switcher menu shows each
    /// server's own badge beside the one it is on.
    private static let otherServer = pairedServer(
        name: "mac-mini",
        host: "mac-mini.local",
        fingerprint: "sha256:rail-inbox-preview-mini",
        badge: .macMini
    )
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
        coordinator.serverStore.replaceServersForPreview([server, otherServer])
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

    private static func pairedServer(
        name: String = "mac-studio",
        host: String = "mac-studio.local",
        fingerprint: String = "sha256:rail-inbox-preview",
        badge: ServerBadgeIcon? = nil
    ) -> PairedServer {
        let leaf = "\(fingerprint)-leaf"
        guard var server = PairedServer(from: ServerCredentials(
            host: host,
            port: 7749,
            token: "sk_preview",
            name: name,
            scheme: .https,
            serverFingerprint: fingerprint,
            tlsCertFingerprint: leaf
        )) else {
            preconditionFailure("rail inbox preview server")
        }
        server.badgeIcon = badge
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
