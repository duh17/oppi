#if DEBUG
import UIKit

/// A chat over a session-list stand-in in one navigation stack, the pane
/// host's primary leaf (`SCREENSHOT_SCREEN=panes`), so a back-button tap, an
/// interactive edge-swipe pop, and a cancelled edge swipe can all be driven
/// against the production `ChatViewController`, its `AttachedLeafController`
/// and the `PaneHostController` around the stack. Reuses the chat-routes
/// fixtures (Git status, timeline, bar layout) so the Git panel opens the
/// same way `ChatRoutesUITests` already proves it does.
/// `CHAT_ROUTES_SESSION_TITLE` names the chat, for a long-title check.
final class PanePreviewController: PreviewRootController {
    private let reducer: TimelineReducer
    private let stack: RouterNavigationController
    private let chat: ChatViewController
    private var didPushChat = false

    init(root: AppRootEnvironment) {
        let topBar = ChatTopBarLayout(
            order: ChatTopBarAction.allCases, shown: [.files, .git, .outline, .context]
        )
        ScreenshotVolatileDefaults.apply([
            AppPreferences.ChatTopBar.orderKey: topBar.storedOrder,
            AppPreferences.ChatTopBar.shownKey: topBar.storedShown,
        ])
        let connection = ChatRoutesFixture.connection
        let chat = ChatViewController(
            sessionId: ChatRoutesFixture.sessionId,
            connection: connection,
            navigation: AppNavigation(),
            workspaceIdHint: ChatRoutesFixture.workspace.id
        )
        chat.traitOverrides.appRootEnvironment = root
        reducer = chat.reducer

        let sessionList = PaneSessionListPlaceholder()
        sessionList.traitOverrides.appRootEnvironment = root
        let stack = RouterNavigationController(rootViewController: sessionList)
        let themeStore = root.themeStore
        stack.interfaceStyle = { themeStore.userInterfaceStyle }
        self.stack = stack
        self.chat = chat

        super.init(root: root, themeStore: root.themeStore, content: stack)
        ChatRoutesFixture.seedTimelineIfNeeded(into: reducer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The list is on screen first, as it is in the app, before the chat opens
    /// above it.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPushChat else { return }
        didPushChat = true
        stack.pushViewController(chat, animated: false)
    }
}

/// Stands in for All Sessions: a full-width content view pinned to the safe
/// area. A leftover companion width from a popped chat's attached leaf
/// narrows this instead of letting it fill the window, which is the
/// regression this harness exists to show.
private final class PaneSessionListPlaceholder: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sessions"
        view.accessibilityIdentifier = "panes.sessionList"
        view.backgroundColor = .systemBackground
        let content = UIView()
        content.backgroundColor = .secondarySystemBackground
        content.accessibilityIdentifier = "panes.sessionList.content"
        content.isAccessibilityElement = true
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
    }
}
#endif
