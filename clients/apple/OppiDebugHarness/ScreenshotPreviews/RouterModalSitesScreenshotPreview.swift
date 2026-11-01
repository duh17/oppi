#if DEBUG
import UIKit

/// Real presenters whose modals the router owns, over fixture services and an
/// in-process stub server (`SCREENSHOT_SCREEN=router-modal-sites`).
/// `SCREENSHOT_MODAL_SITE` picks the presenter: `root` (the app root's
/// extension dialog, notice, and What's New, with trigger buttons and what the
/// dialog sent), `inbox-now-playing` and `workspace-now-playing` (the
/// full-screen player over active playback), `inbox-threads` (the session list
/// over a launch tree that spans two workspaces; tap `thread.nav.thread-root`
/// to open it), and `quick-session` (its pickers, model sheet, and expanded
/// composer). The presenters and their modals share one app root over the
/// fixture server, in the dark theme. Quick Session starts on plain Pi: an
/// Agent an earlier run remembered would load its default from the stub server,
/// which fails.
final class RouterModalSitesPreviewController: PreviewRootController {
    init() {
        let environment = ProcessInfo.processInfo.environment
        ScreenshotVolatileDefaults.applyDarkTheme(true)
        // The dark default holds unless the capture names a theme.
        ScreenshotVolatileDefaults.applyThemeScheme(environment["SCREENSHOT_COLOR_SCHEME"])
        // Quick Session starts on plain Pi: a remembered Agent would load its
        // default from the stub server, which fails.
        UserDefaults.standard.removeObject(forKey: "\(AppIdentifiers.subsystem).quickSession.lastAgentId")
        let site = environment["SCREENSHOT_MODAL_SITE"] ?? "quick-session"
        let navigation = AppNavigation()
        // A thread link's handoff, as the opener leaves it: the list opens this
        // thread root in place.
        if let rootId = environment["SCREENSHOT_THREAD_FOCUS"] {
            navigation.pendingThreadFocus = AppNavigation.ThreadFocus(
                serverId: RouterModalSitesFixtures.serverId, rootId: rootId
            )
        }
        let root = AppRootEnvironment(
            coordinator: RouterModalSitesFixtures.makeCoordinator(
                playing: site.hasSuffix("now-playing"),
                threads: site == "inbox-threads"
            ),
            navigation: navigation,
            themeStore: ThemeStore(),
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        )
        super.init(root: root, themeStore: root.themeStore, content: Self.page(site: site, root: root))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The presenter the site names, at the root of a router stack the way the
    /// router hosts a screen; Quick Session is the window root itself, the way
    /// the app mounts it, and handles the safe area and the keyboard itself.
    private static func page(site: String, root: AppRootEnvironment) -> UIViewController {
        switch site {
        case "root":
            return RouterModalSitesRootViewController(root: root)
        case "inbox-now-playing", "inbox-threads":
            return PreviewHost.screenStack(root: root) { SessionInboxViewController(root: root) }
        case "workspace-now-playing":
            return PreviewHost.screenStack(root: root) {
                WorkspaceDetailViewController(
                    root: root,
                    target: WorkspaceNavTarget(
                        serverId: RouterModalSitesFixtures.serverId,
                        workspace: RouterModalSitesFixtures.workspaces[0]
                    )
                )
            }
        default:
            return QuickSessionViewController(root: root, onDismiss: {})
        }
    }
}

/// The window root's app-wide modals (`AppRootModals`, which `AppRootViewController`
/// owns) over the fixture server's active connection. The dialog's responses go
/// to the connection's send hook, and the page shows the last one.
@MainActor
private final class RouterModalSitesRootViewController: UIViewController {
    private let root: AppRootEnvironment
    private let response = RouterModalSitesResponse()
    private lazy var modals = AppRootModals(root: root, anchor: self)
    private let lastResponseLabel = UILabel()
    private let noticeStateLabel = UILabel()
    private let whatsNewStateLabel = UILabel()
    private var connection: ServerConnection { root.coordinator.activeConnection }

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let connection = connection
        _ = connection.focusedSessionStore.focus(sessionId: "router-modal-sites-session")
        let response = response
        connection._sendMessageForTesting = { @MainActor message in
            guard case .extensionUIResponse(_, _, _, let cancelled, _) = message, cancelled == true else { return }
            response.summary = "cancelled"
        }

        let buttons = [
            button("Extension Dialog", id: "routerModalSites.dialog") { [weak self] in
                self?.showDialog(method: "custom", title: "Pick a Plan")
            },
            button("Notice", id: "routerModalSites.notice") { [weak self] in
                self?.connection.extensionToast = "Extension finished.\nDocs https://example.com/docs"
            },
            button("What's New", id: "routerModalSites.whatsNew") { [weak self] in
                self?.root.navigation.showWhatsNew = true
            },
        ]
        for (label, id) in [
            (lastResponseLabel, "routerModalSites.lastResponse"),
            (noticeStateLabel, "routerModalSites.noticeState"),
            (whatsNewStateLabel, "routerModalSites.whatsNewState"),
        ] {
            label.accessibilityIdentifier = id
            label.font = .preferredFont(forTextStyle: .body)
        }
        let stack = UIStackView(arrangedSubviews: buttons + [lastResponseLabel, noticeStateLabel, whatsNewStateLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 80),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        modals.anchorDidAppear()
    }

    override func updateProperties() {
        super.updateProperties()
        let themeStore = root.themeStore
        view.backgroundColor = themeStore.backgroundColor
        view.overrideUserInterfaceStyle = themeStore.userInterfaceStyle
        let palette = themeStore.activeThemeID.palette
        for label in [lastResponseLabel, noticeStateLabel, whatsNewStateLabel] {
            label.textColor = palette.ui.fg
        }
        lastResponseLabel.text = response.summary
        noticeStateLabel.text = connection.extensionToast == nil ? "Notice cleared" : "Notice shown"
        whatsNewStateLabel.text = root.navigation.showWhatsNew ? "What's New shown" : "What's New cleared"
        modals.update()
    }

    private func button(_ title: String, id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: .plain(), primaryAction: UIAction { _ in action() })
        button.configuration?.title = title
        button.accessibilityIdentifier = id
        return button
    }

    private func showDialog(method: String, title: String) {
        connection.activeExtensionDialog = ExtensionUIRequest(
            id: "router-modal-sites-\(method)",
            sessionId: "router-modal-sites-session",
            method: method,
            title: title,
            message: "The extension is waiting for an answer."
        )
    }
}

/// "cancelled" once the connection's send hook sees the dialog's Cancel.
@MainActor @Observable
private final class RouterModalSitesResponse {
    var summary = "none"
}

/// A fixture server whose stub answers models, worktrees, and Agents.
/// `playing` starts fixture playback, so the Now Playing pill shows.
@MainActor
private enum RouterModalSitesFixtures {
    static let workspaces = [workspace(id: "oppi", icon: "iphone"), workspace(id: "kypu", icon: "figure.run")]
    static let serverId = "sha256:router-modal-sites"

    static func makeCoordinator(playing: Bool, threads: Bool = false) -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        guard let server = PairedServer(from: ServerCredentials(
            host: "router-modal-sites.invalid",
            port: 7749,
            token: "sk_preview",
            name: "modal-sites",
            scheme: .https,
            serverFingerprint: serverId,
            tlsCertFingerprint: "sha256:router-modal-sites-leaf"
        )) else { return coordinator }
        coordinator.serverStore.replaceServersForPreview([server])
        guard coordinator.switchToServer(server),
              let connection = coordinator.connection(for: server.id) else { return coordinator }
        connection.setAPIClientForTesting(api)
        for workspace in workspaces {
            connection.workspaceStore.upsert(workspace, serverId: server.id)
        }
        connection.sessionStore.switchServer(to: server.id)
        if threads { connection.sessionStore.sessions = threadSessions }
        if playing {
            connection.audioPlayer._setPlaybackStateForTesting(playing: "router-modal-sites-audio", loading: nil)
            connection.audioPlayer._setNowPlayingItemTitleForTesting("Fixture narration")
        }
        return coordinator
    }

    /// One launch tree across two workspaces: an idle root with a working child, a finished
    /// child with its own child, and a child that runs in kypu, plus a plain session.
    /// `SCREENSHOT_THREAD_STOPPED_COUNT` adds that many day-old stopped workers to the tree, the
    /// shape of a big thread whose live members sit among stopped ones. `SCREENSHOT_LIST_FILLER`
    /// adds that many plain idle sessions, which list above the thread.
    /// `SCREENSHOT_THREAD_FOCUS=<root id>` (the inbox site) opens that thread as a thread link does.
    private static var threadSessions: [Session] {
        let now = Date()
        func session(
            _ id: String, _ name: String, workspace: String = "oppi", parent: String? = nil,
            status: SessionStatus, minutesAgo: Double, cost: Double
        ) -> Session {
            Session(
                id: id,
                workspaceId: workspace,
                workspaceName: workspace,
                name: name,
                status: status,
                createdAt: now.addingTimeInterval(-minutesAgo * 60),
                lastActivity: now.addingTimeInterval(-minutesAgo * 30),
                currentTurnStartedAt: status == .busy ? now.addingTimeInterval(-90) : nil,
                model: "anthropic/claude-opus-5-5",
                messageCount: 6,
                tokens: TokenUsage(input: 12_000, output: 2_400),
                cost: cost,
                parentSessionId: parent
            )
        }
        let extraStopped = (Int(ProcessInfo.processInfo.environment["SCREENSHOT_THREAD_STOPPED_COUNT"] ?? "") ?? 0)
        let oldWorkers = (0..<extraStopped).map { index in
            session(
                "old-worker-\(index)", "Stopped worker \(index + 1)", parent: "thread-root",
                status: .stopped, minutesAgo: 1_600 + Double(index), cost: 0.05
            )
        }
        let fillerCount = Int(ProcessInfo.processInfo.environment["SCREENSHOT_LIST_FILLER"] ?? "") ?? 0
        let filler = (0..<fillerCount).map { index in
            session("filler-\(index)", "Filler session \(index + 1)", status: .ready, minutesAgo: 5 + Double(index), cost: 0.01)
        }
        return filler + oldWorkers + [
            session("thread-root", "Plan the router migration", status: .ready, minutesAgo: 60, cost: 1.42),
            session(
                "child-working", "Migrate the chat routes", parent: "thread-root",
                status: .busy, minutesAgo: 40, cost: 0.61
            ),
            session("child-done", "Audit the old routes", parent: "thread-root", status: .stopped, minutesAgo: 35, cost: 0.33),
            session("grandchild", "Write the route table", parent: "child-done", status: .stopped, minutesAgo: 30, cost: 0.12),
            session("child-kypu", "Check the kypu client", workspace: "kypu", parent: "thread-root", status: .ready, minutesAgo: 25, cost: 0.2),
            session("plain", "Fix the flaky upload test", status: .ready, minutesAgo: 10, cost: 0.18),
        ]
    }

    private static let api: APIClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterModalSitesURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://router-modal-sites.oppi") ?? URL(fileURLWithPath: "/"),
            token: "preview-token",
            configuration: config
        )
    }()

    private static func workspace(id: String, icon: String) -> Workspace {
        Workspace(
            id: id,
            name: id,
            description: nil,
            icon: .symbol(icon),
            systemPrompt: nil,
            hostMount: "~/workspace/\(id)",
            gitStatusEnabled: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

/// Answers models, worktrees, and Agents; everything else is a 404.
private final class RouterModalSitesURLProtocol: URLProtocol {
    private struct Models: Encodable { let models: [ModelInfo] }
    private struct Worktrees: Encodable { let worktrees: [WorkspaceWorktree] }
    private struct Agents: Encodable { let agents: [AgentDefinitionSummary] }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "router-modal-sites.oppi"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let encoder = JSONEncoder()
        let response: Data? = switch (request.httpMethod, request.url?.path ?? "") {
        case ("GET", "/models"):
            try? encoder.encode(Models(models: [
                ModelInfo(id: "fixture-swift", name: "Fixture Swift", provider: "fixture", contextWindow: 200_000),
                ModelInfo(id: "fixture-steady", name: "Fixture Steady", provider: "fixture", contextWindow: 200_000),
            ]))
        case ("GET", "/workspaces/oppi/worktrees"):
            try? encoder.encode(Worktrees(worktrees: [
                WorkspaceWorktree(id: WorkspaceWorktree.mainId, name: "oppi", path: "~/workspace/oppi", branch: "main", headSha: nil, isMain: true, isGitRepo: true, sessionCount: nil),
                WorkspaceWorktree(id: "router-fix", name: "router-fix", path: "~/workspace/oppi-router-fix", branch: "router-fix", headSha: nil, isMain: false, isGitRepo: true, sessionCount: nil),
            ]))
        case ("GET", "/workspaces/oppi/git/status"):
            try? encoder.encode(GitStatus(
                isGitRepo: true, branch: "main", headSha: "7b42c0d", ahead: 3, behind: 0,
                dirtyCount: 3, untrackedCount: 0, stagedCount: 0,
                files: [
                    GitFileStatus(status: " M", path: "clients/apple/Oppi/App/Router.swift", addedLines: 96, removedLines: 4),
                    GitFileStatus(status: " M", path: "server/src/routes/workspaces.ts", addedLines: 12, removedLines: 3),
                    GitFileStatus(status: " M", path: "docs/usage.md", addedLines: 5, removedLines: 1),
                ],
                totalFiles: 3, addedLines: 113, removedLines: 8, stashCount: 0,
                lastCommitMessage: "Route fixture", lastCommitDate: nil, recentCommits: []
            ))
        case ("GET", "/agents"):
            try? encoder.encode(Agents(agents: [
                AgentDefinitionSummary(
                    id: "reviewer", name: "Reviewer", icon: .defaultValue, description: nil,
                    status: .active, version: 1,
                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), archivedAt: nil
                ),
            ]))
        default:
            nil
        }
        guard let url = request.url,
              let http = HTTPURLResponse(
                  url: url,
                  statusCode: response == nil ? 404 : 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response ?? Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
