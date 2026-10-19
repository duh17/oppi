import UIKit

/// The shell's `.session` route: the session's lock gate, its server's
/// connection, then the chat. While the session is locked it shows the lock
/// cover and no chat exists, so nothing of the session loads; unlocking builds
/// a new `ChatViewController`. "Connecting…" shows until the server is ready.
/// The chat writes its bar items to this screen's navigation item, and its
/// Back and `finish()` close this screen.
@MainActor
final class ChatRouteViewController: UIViewController {
    let target: WorkspaceSessionNavTarget
    /// The split detail root carries the sidebar toggle.
    var placement: ShellRoutePlacement {
        didSet {
            guard placement != oldValue else { return }
            setNeedsUpdateProperties()
        }
    }

    private enum Content: Equatable {
        case lockCover
        case connecting
        case chat
    }

    private let root: AppRootEnvironment
    private(set) var chat: ChatViewController?
    private var leaf: UIViewController?
    private var shown: Content?
    private var scopedConnection: ServerConnection?
    private var connectTask: Task<Void, Never>?
    private lazy var sidebarToggle = makeSidebarToggle()

    init(target: WorkspaceSessionNavTarget, placement: ShellRoutePlacement, root: AppRootEnvironment) {
        self.target = target
        self.placement = placement
        self.root = root
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        // As the SwiftUI route did on every appearance: make this session's
        // server the active one, then use its connection.
        connectTask?.cancel()
        let coordinator = root.coordinator
        let serverId = target.serverId
        connectTask = Task { [weak self] in
            guard await coordinator.switchToServerReady(serverId) else { return }
            guard !Task.isCancelled else { return }
            self?.scopedConnection = coordinator.connection(for: serverId)
            self?.setNeedsUpdateProperties()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        connectTask?.cancel()
        connectTask = nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Build the chat before the first layout, not one pass later.
        updateContent()
    }

    override func updateProperties() {
        super.updateProperties()
        updateContent()
    }

    private func updateContent() {
        view.backgroundColor = root.themeStore.backgroundColor
        let locks = ScopedLockService.shared
        let lockTarget = locks.sessionTarget(
            serverId: target.serverId,
            sessionId: target.sessionId,
            workspaceId: target.workspaceId
        )
        // A notification or deep-link open already awaited
        // `switchToServerReady`: reuse that connection at once so the chat
        // binds its session stream instead of sitting on "Connecting…".
        let connection = scopedConnection ?? root.coordinator.connection(for: target.serverId)
        if locks.isLocked(lockTarget) {
            show(.lockCover) {
                ShellRouteScreens.sessionLockCover(
                    target: lockTarget,
                    title: locks.sessionLookup(target.serverId, target.sessionId)?.displayTitle
                        ?? String(localized: "Session"),
                    root: root
                )
            }
        } else if let connection {
            showChat(connection: connection)
        } else {
            show(.connecting) { ShellRouteScreens.connecting(root: root) }
        }

        let prefix = placement == .splitDetailRoot ? [sidebarToggle] : []
        updateSidebarToggle()
        if let chat {
            if chat.barItems.leadingPrefix.elementsEqual(prefix, by: ===) == false {
                chat.barItems.leadingPrefix = prefix
                chat.setNeedsUpdateProperties()
            }
        } else {
            navigationItem.title = nil
            navigationItem.titleView = nil
            navigationItem.rightBarButtonItems = nil
            navigationItem.hidesBackButton = false
            navigationItem.leftBarButtonItems = prefix
        }
    }

    private func show(_ content: Content, make: () -> UIViewController) {
        guard shown != content else { return }
        removeCurrent()
        let controller = make()
        embed(controller)
        leaf = controller
        shown = content
    }

    private func showChat(connection: ServerConnection) {
        guard shown != .chat else { return }
        removeCurrent()
        let chat = ChatViewController(
            sessionId: target.sessionId,
            connection: connection,
            navigation: root.navigation,
            serverIdHint: target.serverId,
            workspaceIdHint: target.workspaceId,
            routeScope: target.routeScope
        )
        embed(chat)
        self.chat = chat
        shown = .chat
    }

    private func embed(_ controller: UIViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }

    /// Locking takes the chat away; its disappearance releases the session.
    private func removeCurrent() {
        let current = chat ?? leaf
        chat = nil
        leaf = nil
        guard let current else { return }
        current.willMove(toParent: nil)
        current.view.removeFromSuperview()
        current.removeFromParent()
    }

    private func makeSidebarToggle() -> UIBarButtonItem {
        let toggle = UIBarButtonItem(
            title: "Hide Sidebar",
            image: UIImage(systemName: "sidebar.leading"),
            primaryAction: UIAction { [weak self] _ in
                guard let navigation = self?.root.navigation else { return }
                navigation.splitColumnVisibility = navigation.splitColumnVisibility == .detailOnly ? .all : .detailOnly
            }
        )
        toggle.accessibilityIdentifier = "workspace.split.sidebarToggle"
        return toggle
    }

    private func updateSidebarToggle() {
        let visible = root.navigation.splitColumnVisibility != .detailOnly
        // Title plus symbol so the bar can show it on the Duo's vertical rail
        // and in overflow menus.
        sidebarToggle.title = visible ? "Hide Sidebar" : "Show Sidebar"
        sidebarToggle.tintColor = ComposerThemeColors(palette: root.themeStore.activeThemeID.palette).fg
    }
}
