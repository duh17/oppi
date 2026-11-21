#if DEBUG
import UIKit

/// Production All Sessions chrome in the real workspace shell, with in-memory
/// sessions so the rail can be captured without a paired server
/// (`SCREENSHOT_SCREEN=workspace-shell`; the router's navigation smoke test
/// drives it). `SCREENSHOT_ORIENTATION` poses the Duo.
final class WorkspaceShellPreviewController: PreviewRootController {
    init() {
        let root = AppRootEnvironment.preview(coordinator: Self.makeCoordinator())
        // A paired shell, as the window shows it, so the keyboard commands and
        // Quick Session (which `AppRootViewController` hosts) work here.
        root.navigation.app.revealPairedServerShell()
        super.init(root: root, themeStore: root.themeStore, content: QuickSessionOverShellController(root: root))
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
        host: "mac-mini.invalid",
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
        let connection = coordinator.activatePreviewServer(server)
        connection.workspaceStore.upsert(workspace, serverId: server.id)
        // Sampling on, so the host pill offers Server Metrics (its route smoke).
        connection.serverMetricsEnabled = true
        connection.sessionStore.switchServer(to: server.id)
        connection.sessionStore.sessions = [
            session(id: "rail-1", name: "Fill the Duo side rail", status: .busy, minutesAgo: 2),
            session(id: "rail-2", name: "Keep Message on the phone bar", status: .ready, minutesAgo: 18),
            // A third section, Stopped · Today: the list's headers are the screen's own.
            session(id: "rail-3", name: "Wire the sidebar toggle", status: .stopped, minutesAgo: 25),
            // Your Turn: a saved Agent's session that ended unseen, so the row
            // draws its attention dot and its icon plays its burst as the list
            // appears, then rests on its first frame.
            session(
                id: "rail-4",
                name: "Ask before I ship the rail",
                status: .ready,
                minutesAgo: 1,
                agent: ("agent-rail-reviewer", .symbol("sparkles", effect: .bounce))
            ),
        ]
        return coordinator
    }

    private static func pairedServer(
        name: String = "mac-studio",
        host: String = "mac-studio.invalid",
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

    /// `agent` launches the session from a saved Agent with that icon, and the
    /// session ends unseen, as one does when the person has not opened it yet:
    /// the preview's seen ledger starts at launch, so the outcome dates from
    /// just after it.
    private static func session(
        id: String,
        name: String,
        status: SessionStatus,
        minutesAgo: Double,
        agent: (id: String, icon: IconChoice)? = nil
    ) -> Session {
        let lastActivity = Date().addingTimeInterval(-minutesAgo * 60)
        var session = Session(
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
        if let agent {
            session.launch = SessionLaunchMetadata(agentId: agent.id, agentIcon: agent.icon)
            session.programStatus = ProgramStatus(state: .done, since: Date(timeIntervalSinceNow: 1))
        }
        return session
    }
}
#endif
