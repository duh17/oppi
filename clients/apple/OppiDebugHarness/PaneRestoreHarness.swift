#if DEBUG
import Observation
import UIKit

/// The production workspace shell over the chat-routes fixtures, with the
/// window's pane tree saved and restored exactly as the app does it
/// (`SCREENSHOT_SCREEN=pane-restore`): `ScenePanes` connects to this scene's
/// `persistentIdentifier`, restores what an earlier launch wrote, and writes
/// each settle. A UI test opens a chat and its Git panel, terminates the app,
/// and relaunches it with the same reset token to see them come back.
///
/// `PANE_RESTORE_SEED=missing` saves, before restoring, a tree whose stack
/// holds what cannot open: a session this server no longer has, a file it no
/// longer has, a session on a server that is unpaired, and one on a paired
/// server that is offline (`mac-mini`). Close Pane steps down through them.
final class PaneRestorePreviewController: PreviewRootController {
    static let serverId = "sha256:pane-restore"
    static let offlineServerId = "sha256:pane-restore-mini"

    private let root: AppRootEnvironment
    private var connected = false

    init() {
        let topBar = ChatTopBarLayout(order: ChatTopBarAction.allCases, shown: [.files, .git, .outline, .context])
        ScreenshotVolatileDefaults.apply([
            AppPreferences.ChatTopBar.orderKey: topBar.storedOrder,
            AppPreferences.ChatTopBar.shownKey: topBar.storedShown,
        ])
        let root = AppRootEnvironment.preview(coordinator: Self.makeCoordinator())
        root.navigation.app.revealPairedServerShell()
        self.root = root
        super.init(root: root, themeStore: root.themeStore, content: WorkspaceShellController(root: root))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ScreenshotPreviewOrientation.applyRequested()
        guard !connected, let scene = view.window?.windowScene?.session.persistentIdentifier else { return }
        connected = true
        let panes = root.navigation.panes
        if ProcessInfo.processInfo.environment["PANE_RESTORE_SEED"] == "missing" {
            PaneTreeStore().save(Self.missingTree(), scene: scene)
        }
        panes.connect(scene: scene)
        panes.restore(navigation: root.navigation, coordinator: root.coordinator)
        keepChatsSeeded()
    }

    /// The shell builds its own chats; each gets the fixture timeline, which
    /// the connect loop would otherwise clear (no server answers it).
    private func keepChatsSeeded() {
        for chat in Self.chats(in: self) {
            ChatRoutesFixture.seedTimelineIfNeeded(into: chat.reducer)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.keepChatsSeeded() }
        }
    }

    private static func chats(in controller: UIViewController) -> [ChatViewController] {
        let own = (controller as? ChatViewController).map { [$0] } ?? []
        let shown = controller.children + (controller.presentedViewController.map { [$0] } ?? [])
        return own + shown.flatMap { chats(in: $0) }
    }

    private static func missingTree() -> PaneLayoutArchive? {
        func entry(_ server: String, _ route: PaneRoute) -> PaneStackEntry {
            PaneStackEntry(serverId: server, route: route)
        }
        let workspace = ChatRoutesFixture.workspace.id
        return PaneLayoutArchive(restorable: PaneLayout(single: PaneLeaf(
            id: ScenePanes().routedLeafID, name: nil,
            stack: [
                entry(serverId, .sessions(workspace: workspace)),
                entry(serverId, .file(.workspace(id: workspace, worktree: nil), path: "Sources/\(ChatRoutesFixture.removedFileName)", line: nil)),
                entry(serverId, .session("pane-restore-deleted")),
                entry("sha256:pane-restore-unpaired", .session("pane-restore-elsewhere")),
                entry(offlineServerId, .session("pane-restore-offline")),
            ],
            attachedTo: nil, origin: .split
        )))
    }

    private static func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        let server = pairedServer(name: "mac-studio", host: "chat-routes.oppi", fingerprint: serverId)
        let mini = pairedServer(name: "mac-mini", host: "mac-mini.invalid", fingerprint: offlineServerId)
        coordinator.serverStore.replaceServersForPreview([server, mini])
        let connection = coordinator.activatePreviewServer(server, apiClient: ChatRoutesFixture.api)
        connection.workspaceStore.upsert(ChatRoutesFixture.workspace, serverId: serverId)
        connection.sessionStore.switchServer(to: serverId)
        connection.sessionStore.sessions = [
            ChatRoutesFixture.session(id: ChatRoutesFixture.sessionId, status: .ready),
        ]
        return coordinator
    }

    private static func pairedServer(name: String, host: String, fingerprint: String) -> PairedServer {
        guard let server = PairedServer(from: ServerCredentials(
            host: host,
            port: 7749,
            token: "sk_preview",
            name: name,
            scheme: .https,
            serverFingerprint: fingerprint,
            tlsCertFingerprint: "\(fingerprint)-leaf"
        )) else {
            preconditionFailure("pane restore preview server")
        }
        return server
    }
}
#endif
