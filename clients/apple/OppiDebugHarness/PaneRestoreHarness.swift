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
/// `PANE_RESTORE_SEED=splits` saves the workspace's sessions with a Files and
/// a Git pane split beside them, the tree a wide window leaves behind, so a
/// compact window (the iPhone) shows it one pane at a time with the chip.
/// `PANE_RESTORE_SEED=godot` saves the sessions with Tide Runner's Godot pane
/// beside them, which a relaunch restores waiting for Play.
/// `PANE_RESTORE_SEED=files-below` saves the sessions over the home folder's
/// `notebook` (Org files) in a pane below them, the window a pinned folder
/// opened from a portrait iPad leaves.
/// `PANE_RESTORE_SEED=chat-over-pdf` saves the chat over a PDF from the home
/// folder in a pane below it, the window a divider is dragged to the top of.
/// `PANE_RESTORE_SEED=git-below` saves the sessions over the workspace's Git
/// in a pane below them, the window a pinned Git opened from a portrait iPad
/// leaves.
/// `PANE_RESTORE_SEED=sessions-below` saves the home folder's `notebook` in a
/// pane above the sessions, so a chat opened there and its Git panel sit in
/// the lower pane.
/// `PANE_RESTORE_SEED=cross-server` saves the offline `mac-mini`'s chat in the
/// main pane and this server's workspace list beside it: two chats on two
/// servers can show at once (Stage 4a), and the list's rows open their chats
/// in its own pane or, from their menu, in a new one.
/// `PANE_RESTORE_SEED=chat-beside-list` saves this workspace's session list in
/// the main pane and its first chat in a pane beside it, the window Open in
/// New Pane leaves: a row for the chat already on screen focuses that pane, and
/// a second chat of one server opens in the main pane.
/// `PANE_RESTORE_PINS=1` makes the server keep pins: the sidebar offers
/// Pinned, which lists the fixture chat, a folder, and a PDF.
/// `PANE_RESTORE_REX=1` saves one SSH host whose Rex is a fake one in process
/// (`SSHTerminalRexListPreviewController.makeList`), so the launcher's Rex pane
/// lists its sessions and opens one in the pane.
/// `PANE_RESTORE_TERMINAL=1` opens a live terminal, over a channel with no host
/// to dial, at the root of a pane beside the main pane once the shell is up,
/// as the chat's Terminal button opens a connected one (`openBeside`).
final class PaneRestorePreviewController: PreviewRootController {
    static let serverId = "sha256:pane-restore"
    static let offlineServerId = "sha256:pane-restore-mini"
    /// The chat the offline server shows in the cross-server seed.
    static let miniSessionId = "pane-restore-mini-chat"
    /// A second session of this server, so a menu open can ask for a chat of a
    /// server that already shows one (one chat per server, Stage 4b).
    static let otherSessionId = "chat-routes-other"
    static let miniWorkspaceId = "pane-restore-mini-ws"

    private let root: AppRootEnvironment
    private var connected = false

    init() {
        // `SCREENSHOT_COLOR_SCHEME` pins the theme, before the preview's ThemeStore reads it.
        ScreenshotVolatileDefaults.applyThemeScheme(ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"])
        let topBar = ChatTopBarLayout(order: ChatTopBarAction.allCases, shown: [.files, .git, .outline, .context])
        ScreenshotVolatileDefaults.apply([
            AppPreferences.ChatTopBar.orderKey: topBar.storedOrder,
            AppPreferences.ChatTopBar.shownKey: topBar.storedShown,
        ])
        if ProcessInfo.processInfo.environment["CHAT_ROUTES_GODOT"] != nil {
            ServerConnection._godotPlayerLinkForTesting = ChatRoutesGodot.playerLink
        }
        if ProcessInfo.processInfo.environment["PANE_RESTORE_REX"] == "1" {
            PaneSplitScreens._rexListForTesting = {
                SSHTerminalRexListPreviewController.makeList(
                    hosts: [SSHTerminalProfile(
                        id: SSHTerminalRexListPreviewController.rexHostID,
                        host: "mac-studio.invalid", username: "alex", opensRexSessions: true
                    )]
                )
            }
        }
        let root = AppRootEnvironment.preview(coordinator: Self.makeCoordinator())
        root.navigation.app.revealPairedServerShell()
        // The fixture server answers HTTP in process but has no live transport
        // to switch to: a tapped file or folder link opens on it as on a
        // connected server.
        root.opener._serverReadyForTesting = { serverId in
            root.coordinator.serverStore.server(for: serverId) != nil && serverId != Self.offlineServerId
        }
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
        // The window the scene delegate hands the app: an open with no screen
        // of its own (a web link) presents in it.
        root.navigation.window = view.window
        let panes = root.navigation.panes
        switch ProcessInfo.processInfo.environment["PANE_RESTORE_SEED"] {
        case "missing": PaneTreeStore().save(Self.missingTree(), scene: scene)
        case "splits": PaneTreeStore().save(Self.splitsTree(), scene: scene)
        case "godot": PaneTreeStore().save(Self.godotTree(), scene: scene)
        case "files-below": PaneTreeStore().save(Self.filesBelowTree(), scene: scene)
        case "chat-over-pdf": PaneTreeStore().save(Self.chatOverPDFTree(), scene: scene)
        case "git-below": PaneTreeStore().save(Self.gitBelowTree(), scene: scene)
        case "sessions-below": PaneTreeStore().save(Self.sessionsBelowTree(), scene: scene)
        case "cross-server": PaneTreeStore().save(Self.crossServerTree(), scene: scene)
        case "chat-beside-list": PaneTreeStore().save(Self.chatBesideListTree(), scene: scene)
        default: break
        }
        panes.connect(scene: scene)
        panes.restore(navigation: root.navigation, coordinator: root.coordinator)
        // The app's launch tells its opener the scene is in front and launch
        // is over (`OppiApp`); without that every open but a web link parks.
        root.opener.sceneDidBecomeActive()
        root.opener.launchDidFinish()
        keepChatsSeeded()
        if ProcessInfo.processInfo.environment["PANE_RESTORE_TERMINAL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.openTerminalBesideTheMainPane() }
            }
        }
    }

    private func openTerminalBesideTheMainPane() {
        guard let host = Self.paneHost(in: self), let channel = try? SSHTerminalChannel() else { return }
        let terminal = TerminalNavTarget {
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {}, hostLabel: "alex@mac-studio")
        }
        let content = PaneOpenContent(terminal: terminal, serverId: Self.serverId)
        root.navigation.open(
            content.mainPaneDestination(coordinator: root.coordinator),
            from: .row(host.panes.mainLeafID),
            beside: .terminal
        )
    }

    private static func paneHost(in controller: UIViewController) -> PaneHostController? {
        if let host = controller as? PaneHostController { return host }
        return controller.children.lazy.compactMap { paneHost(in: $0) }.first
    }

    /// The shell builds its own chats; each gets the fixture timeline, which
    /// the connect loop would otherwise clear (no server answers it). It runs
    /// for the first seconds only: a loop that keeps publishing would leave the
    /// app busy for a test's whole run (a context menu open never settles).
    private func keepChatsSeeded(rounds: Int = 20) {
        for chat in Self.chats(in: self) {
            ChatRoutesFixture.seedTimelineIfNeeded(into: chat.reducer)
        }
        guard rounds > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.keepChatsSeeded(rounds: rounds - 1) }
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
            id: ScenePanes().mainLeafID, name: nil,
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

    private static func splitsTree() -> PaneLayoutArchive? {
        let workspace = ChatRoutesFixture.workspace.id
        func leaf(_ id: String, _ route: PaneRoute) -> PaneNode {
            guard let id = PaneID(id) else { preconditionFailure("\(id) is not a pane id") }
            return .leaf(PaneLeaf(id: id, name: nil, stack: [PaneStackEntry(serverId: serverId, route: route)],
                                  attachedTo: nil, origin: .split))
        }
        let routed = ScenePanes().mainLeafID
        return PaneLayoutArchive(restorable: PaneLayout(
            root: .split(axis: .row, children: [
                leaf(routed.raw, .sessions(workspace: workspace)),
                leaf("leaf-2", .files(workspace: workspace, path: nil)),
                leaf("leaf-3", .git(workspace: workspace, worktree: nil)),
            ], weights: [0.4, 0.3, 0.3]),
            focus: routed
        ))
    }

    private static func filesBelowTree() -> PaneLayoutArchive? {
        let workspace = ChatRoutesFixture.workspace.id
        let routed = ScenePanes().mainLeafID
        guard let files = PaneID("leaf-notebook") else { return nil }
        return PaneLayoutArchive(restorable: PaneLayout(
            root: .split(axis: .column, children: [
                .leaf(PaneLeaf(id: routed, name: nil, stack: [PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspace))],
                               attachedTo: nil, origin: .split)),
                .leaf(PaneLeaf(id: files, name: nil, stack: [PaneStackEntry(serverId: serverId, route: .hostFiles(path: "~/notebook"))],
                               attachedTo: nil, origin: .split)),
            ], weights: [0.45, 0.55]),
            focus: files
        ))
    }

    private static func chatOverPDFTree() -> PaneLayoutArchive? {
        let workspace = ChatRoutesFixture.workspace.id
        let routed = ScenePanes().mainLeafID
        guard let pdf = PaneID("leaf-pdf") else { return nil }
        let chat = [
            PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspace)),
            PaneStackEntry(serverId: serverId, route: .session(ChatRoutesFixture.sessionId)),
        ]
        let file = PaneRoute.file(.host, path: "~/\(ChatRoutesFixture.pdfName)", line: nil)
        return PaneLayoutArchive(restorable: PaneLayout(
            root: .split(axis: .column, children: [
                .leaf(PaneLeaf(id: routed, name: nil, stack: chat, attachedTo: nil, origin: .split)),
                .leaf(PaneLeaf(id: pdf, name: nil, stack: [PaneStackEntry(serverId: serverId, route: file)],
                               attachedTo: nil, origin: .split)),
            ], weights: [0.5, 0.5]),
            focus: pdf
        ))
    }

    private static func sessionsBelowTree() -> PaneLayoutArchive? {
        let workspace = ChatRoutesFixture.workspace.id
        let routed = ScenePanes().mainLeafID
        guard let files = PaneID("leaf-notebook") else { return nil }
        return PaneLayoutArchive(restorable: PaneLayout(
            root: .split(axis: .column, children: [
                .leaf(PaneLeaf(id: files, name: nil, stack: [PaneStackEntry(serverId: serverId, route: .hostFiles(path: "~/notebook"))],
                               attachedTo: nil, origin: .split)),
                .leaf(PaneLeaf(id: routed, name: nil, stack: [PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspace))],
                               attachedTo: nil, origin: .split)),
            ], weights: [0.3, 0.7]),
            focus: routed
        ))
    }

    /// The offline mini's chat in the main pane, over All Sessions, and this
    /// server's workspace list beside it: two chats on two servers can show at
    /// once, each stream on its own connection (Stage 4a).
    private static func crossServerTree() -> PaneLayoutArchive? {
        let workspace = ChatRoutesFixture.workspace.id
        let routed = ScenePanes().mainLeafID
        guard let sessions = PaneID("leaf-sessions") else { return nil }
        return PaneLayoutArchive(restorable: PaneLayout(
            root: .split(axis: .row, children: [
                .leaf(PaneLeaf(id: routed, name: nil, stack: [
                    PaneStackEntry(serverId: serverId, route: .sessions(workspace: nil)),
                    PaneStackEntry(serverId: offlineServerId, route: .session(miniSessionId)),
                ], attachedTo: nil, origin: .split)),
                .leaf(PaneLeaf(id: sessions, name: nil, stack: [
                    PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspace)),
                ], attachedTo: nil, origin: .split)),
            ], weights: [0.55, 0.45]),
            focus: routed
        ))
    }

    /// This workspace's session list in the main pane, its first chat beside
    /// it: the window Open in New Pane leaves, where a row for the chat already
    /// on screen focuses that pane (D7).
    private static func chatBesideListTree() -> PaneLayoutArchive? {
        let workspace = ChatRoutesFixture.workspace.id
        let routed = ScenePanes().mainLeafID
        guard let chat = PaneID("leaf-chat") else { return nil }
        return PaneLayoutArchive(restorable: PaneLayout(
            root: .split(axis: .row, children: [
                .leaf(PaneLeaf(id: routed, name: nil, stack: [
                    PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspace)),
                ], attachedTo: nil, origin: .split)),
                .leaf(PaneLeaf(id: chat, name: nil, stack: [
                    PaneStackEntry(serverId: serverId, route: .session(ChatRoutesFixture.sessionId)),
                ], attachedTo: nil, origin: .split)),
            ], weights: [0.5, 0.5]),
            focus: routed
        ))
    }

    private static func gitBelowTree() -> PaneLayoutArchive? {
        let workspace = ChatRoutesFixture.workspace.id
        let routed = ScenePanes().mainLeafID
        guard let git = PaneID("leaf-git") else { return nil }
        return PaneLayoutArchive(restorable: PaneLayout(
            root: .split(axis: .column, children: [
                .leaf(PaneLeaf(id: routed, name: nil, stack: [PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspace))],
                               attachedTo: nil, origin: .split)),
                .leaf(PaneLeaf(id: git, name: nil, stack: [PaneStackEntry(serverId: serverId, route: .git(workspace: workspace, worktree: nil))],
                               attachedTo: nil, origin: .split)),
            ], weights: [0.3, 0.7]),
            focus: git
        ))
    }

    private static func godotTree() -> PaneLayoutArchive? {
        let workspace = ChatRoutesFixture.workspace.id
        let routed = ScenePanes().mainLeafID
        guard let godot = PaneID("leaf-godot") else { return nil }
        return PaneLayoutArchive(restorable: PaneLayout(
            root: .split(axis: .row, children: [
                .leaf(PaneLeaf(id: routed, name: nil, stack: [PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspace))],
                               attachedTo: nil, origin: .split)),
                .leaf(PaneLeaf(id: godot, name: nil, stack: [PaneStackEntry(serverId: serverId, route: .godot(project: "tide-runner-3fa9c2b1"))],
                               attachedTo: nil, origin: .split)),
            ], weights: [0.5, 0.5]),
            focus: routed
        ))
    }

    private static func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        let server = pairedServer(name: "mac-studio", host: "chat-routes.oppi", fingerprint: serverId)
        let mini = pairedServer(name: "mac-mini", host: "mac-mini.invalid", fingerprint: offlineServerId)
        coordinator.serverStore.replaceServersForPreview([server, mini])
        let connection = coordinator.activatePreviewServer(server, apiClient: ChatRoutesFixture.api)
        connection.workspaceStore.upsert(ChatRoutesFixture.workspace, serverId: serverId)
        connection.sessionStore.switchServer(to: serverId)
        // `CHAT_ROUTES_STATUS=busy` makes the chat busy, as on `chat-routes`.
        let busy = ProcessInfo.processInfo.environment["CHAT_ROUTES_STATUS"] == "busy"
        connection.sessionStore.sessions = [
            ChatRoutesFixture.session(id: ChatRoutesFixture.sessionId, status: busy ? .busy : .ready),
            ChatRoutesFixture.session(id: otherSessionId, status: .ready),
        ]
        // The cross-server seed shows the offline mini's chat in a pane while
        // this server is the window's, so the mini needs a connection of its
        // own — and only that seed: its connection inherits this server's
        // in-process API client, and a mini that answers would no longer be the
        // offline server the `missing` seed's leaf state is about.
        if ProcessInfo.processInfo.environment["PANE_RESTORE_SEED"] == "cross-server",
           let mini = coordinator.serverStore.server(for: offlineServerId) {
            let offline = coordinator.activatePreviewServer(mini)
            offline.workspaceStore.upsert(Self.miniWorkspace, serverId: offlineServerId)
            offline.sessionStore.switchServer(to: offlineServerId)
            var chat = ChatRoutesFixture.session(id: miniSessionId, status: .ready)
            chat.name = "Mini routes"
            chat.workspaceId = miniWorkspaceId
            chat.workspaceName = Self.miniWorkspace.name
            offline.sessionStore.sessions = [chat]
            // The window's server is this one, whatever the mini's connection
            // did on its way in.
            _ = coordinator.activatePreviewServer(server, apiClient: ChatRoutesFixture.api)
        }
        return coordinator
    }

    private static let miniWorkspace = Workspace(
        id: miniWorkspaceId,
        name: "Mini workspace",
        description: nil,
        icon: .symbol("desktopcomputer"),
        systemPrompt: nil,
        hostMount: "/tmp/oppi-pane-restore-mini",
        tools: nil,
        gitStatusEnabled: false,
        runtime: .host,
        sandboxConfig: nil,
        createdAt: Date(timeIntervalSince1970: 1_770_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )

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
