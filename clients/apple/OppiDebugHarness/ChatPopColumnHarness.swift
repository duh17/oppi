#if DEBUG
import UIKit

/// Reproduces popping a chat while its trailing column (Git, Files, Outline,
/// Context) is open: a session-list stand-in sits under the chat in one
/// navigation stack (`SCREENSHOT_SCREEN=chat-pop-column`), so a back-button
/// tap, an interactive edge-swipe pop, and a cancelled edge swipe can all be
/// driven against the production `ChatViewController` and
/// `TrailingColumnController`. Reuses the chat-routes fixtures (Git status,
/// timeline, bar layout) so the Git panel opens the same way
/// `ChatRoutesUITests` already proves it does.
final class ChatPopColumnPreviewController: PreviewRootController {
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

        let sessionList = ChatPopColumnSessionListPlaceholder()
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
/// area. A leftover trailing inset from a popped chat's trailing column
/// narrows this instead of letting it fill the window, which is the
/// regression this harness exists to show.
private final class ChatPopColumnSessionListPlaceholder: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sessions"
        view.accessibilityIdentifier = "chatPopColumn.sessionList"
        view.backgroundColor = .systemBackground
        let content = UIView()
        content.backgroundColor = .secondarySystemBackground
        content.accessibilityIdentifier = "chatPopColumn.sessionList.content"
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
