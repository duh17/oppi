import UIKit

/// A session list that starts Quick Session from its bar, with the list's own
/// context (the workspace's) and its own front-of-stack guard.
@MainActor
protocol QuickSessionStarting: UIViewController {
    func startQuickSession(dictate: Bool)
}

extension SessionInboxViewController: QuickSessionStarting {}
extension WorkspaceDetailViewController: QuickSessionStarting {}

/// One window's owners behind the keyboard commands (`KeyboardCommand`) and the
/// system Find; the window (`AppWindow`) asks for the commands typed in it. Each finds the owner a touch control runs and returns its
/// action while it is available; none keeps logic of its own beyond asking
/// where the owner is.
///
/// Every command is unavailable while the app is locked, launching, in
/// onboarding, or while Quick Session covers the content (which has its own
/// keys). Chat commands also need the chat to be in front: a sheet or popover
/// over it is the front screen then, and Close closes that. A search the user
/// started is not a modal here: it neither blocks the commands nor counts as
/// the sheet Close would dismiss.
@MainActor
final class LiveKeyboardCommandSurface {
    private let root: AppRootEnvironment
    private let window: UIWindow
    private var navigation: SceneNavigation { root.navigation }

    init(root: AppRootEnvironment, window: UIWindow) {
        self.root = root
        self.window = window
    }

    private var isInteractive: Bool {
        navigation.app.launchPhase == .ready
            && !navigation.app.showOnboarding
            && !navigation.showQuickSession
            && !AppLockService.shared.isLocked
    }

    private var rootController: UIViewController? { window.rootViewController }

    /// The chat in front, when nothing is presented over it.
    private var frontChat: ChatViewController? {
        guard isInteractive else { return nil }
        return FrontScreens.screens(in: window).lazy.compactMap { ($0 as? ChatRouteViewController)?.chat }.first
    }

    /// The topmost modal the window presents. An active `UISearchController`
    /// is presented by UIKit too, but it is the search, not a sheet.
    private var topPresented: UIViewController? {
        var top = rootController
        var presented: UIViewController?
        while let next = top?.presentedViewController {
            if !(next is UISearchController) { presented = next }
            top = next
        }
        return presented
    }

    private func descendant<Screen: UIViewController>(of screen: UIViewController?, as _: Screen.Type) -> Screen? {
        guard let screen else { return nil }
        if let match = screen as? Screen { return match }
        for child in screen.children {
            if let match = descendant(of: child, as: Screen.self) { return match }
        }
        return nil
    }

    private func firstResponder(in view: UIView?) -> UIView? {
        guard let view else { return nil }
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }

    // MARK: Find

    /// The front screen's search: the one that is active, else the first.
    private var frontSearch: (search: UISearchController, screen: UIViewController)? {
        guard isInteractive else { return nil }
        // The window's panes come first, as they hold the focus: the focused leaf's
        // screen, then the other leaf's (a Files panel beside a chat that has no
        // search of its own, which `FrontScreens` does not reach: the panel's
        // browser is a child it descends into). A drawer's or split view's sidebar
        // search answers only when no pane has one.
        var screens = FrontScreens.screens(in: window)
        if topPresented == nil {
            screens.insert(contentsOf: Router.paneScreens(in: window), at: 0)
            if let focused = Router.focusedScreen(in: window) { screens.insert(focused, at: 0) }
        }
        let searches = screens.compactMap { screen in
            ScreenSearchController.search(on: screen).map { (search: $0, screen: screen) }
        }
        return searches.first { $0.search.isActive } ?? searches.first
    }

    /// The system Find, for a search bar in front. A bar scrolled out of sight
    /// is brought back and focused, so Find is available whenever a screen has one.
    func find() -> (@MainActor () -> Void)? {
        guard let (search, screen) = frontSearch else { return nil }
        return { ScreenSearchController.begin(search, on: screen) }
    }

    // MARK: Commands

    func resolve(_ command: KeyboardCommand) -> KeyboardCommand.Resolved? {
        let run: (@MainActor () -> Void)?
        var title = command.title
        switch command {
        case .newSession: run = newSession()
        case .settings: run = openSettings()
        case .close: run = close()
        case .toggleSidebar:
            let (action, isShown) = toggleSidebar()
            run = action
            title = isShown ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        case .toggleFileTree:
            let browser = frontFileBrowser
            run = browser.map { browser -> @MainActor () -> Void in { [weak browser] in browser?.toggleTree() } }
            if browser?.treeToggleState.hidden == false { title = String(localized: "Hide File Tree") }
        case .pane(let pane):
            run = togglePane(pane)
            if frontChat?.isPaneOpen(pane) == true { title = String(localized: "Hide \(pane.label)") }
        case .stop: run = stop()
        case .focusComposer: run = focusComposer()
        case .nextSession: run = openAdjacentSession(offset: 1)
        case .previousSession: run = openAdjacentSession(offset: -1)
        }
        return run.map { KeyboardCommand.Resolved(title: title, run: $0) }
    }

    /// A session list in front starts it from its bar, with its own context
    /// and guard; with a chat or another screen in front the window presents it
    /// as an App Intent does.
    private func newSession() -> (@MainActor () -> Void)? {
        guard isInteractive, topPresented == nil else { return nil }
        if let starter = FrontScreens.screens(in: window).lazy.compactMap({ $0 as? any QuickSessionStarting }).first {
            guard starter.isFrontOfNavigationStack else { return nil }
            return { starter.startQuickSession(dictate: false) }
        }
        return { [navigation] in
            navigation.presentQuickSession(QuickSessionStart(), from: .keyboard)
        }
    }

    private func openSettings() -> (@MainActor () -> Void)? {
        guard isInteractive, topPresented == nil else { return nil }
        guard navigation.workspaceStackRouteElements.last != .utility(.appSettings) else { return nil }
        return { [navigation, weak self] in
            navigation.openWorkspaceUtility(.appSettings)
            // The compact drawer covers the screen the command opened.
            self?.descendant(of: self?.rootController, as: WorkspaceDrawerController.self)?.closeSidebar()
        }
    }

    /// Cancels an active search first, then closes the topmost sheet or
    /// popover, then the chat's attached leaf. A modal that refuses swipe-down
    /// (`isModalInPresentation`: an unsaved form) gets the attempt swipe-down
    /// makes, so it asks as it does there; an alert is not closed from the keyboard.
    private func close() -> (@MainActor () -> Void)? {
        guard isInteractive else { return nil }
        if let (search, _) = frontSearch, search.isActive {
            return { Router.endSearch(search) }
        }
        if let presented = topPresented {
            guard !(presented is UIAlertController) else { return nil }
            guard presented.isModalInPresentation else { return { Router.dismiss(presented) } }
            guard let controller = presented.presentationController,
                  let delegate = controller.delegate,
                  delegate.responds(to: #selector(UIAdaptivePresentationControllerDelegate.presentationControllerDidAttemptToDismiss(_:)))
            else { return nil }
            return { delegate.presentationControllerDidAttemptToDismiss?(controller) }
        }
        guard let chat = frontChat, chat.hasPanelBeside else { return nil }
        return { [weak chat] in chat?.showPanel(nil) }
    }

    /// Whether the sidebar shows now, with the action that toggles it.
    private func toggleSidebar() -> (action: (@MainActor () -> Void)?, isShown: Bool) {
        guard isInteractive, topPresented == nil else { return (nil, false) }
        switch navigation.workspaceNavigationPresentation {
        case .split:
            return ({ [navigation] in navigation.toggleSplitSidebar() }, navigation.splitColumnVisibility != .detailOnly)
        case .stack:
            guard let drawer = descendant(of: rootController, as: WorkspaceDrawerController.self),
                  drawer.canToggleSidebar else { return (nil, false) }
            return ({ [weak drawer] in drawer?.toggleSidebar() }, drawer.isSidebarOpen)
        }
    }

    /// The File Browser in front that offers its tree toggle (a file open in
    /// regular width). Its open file is a child, so the front screen is the
    /// file's and the browser is found above it.
    private var frontFileBrowser: FileBrowserViewController? {
        guard isInteractive, topPresented == nil else { return nil }
        let browser = FrontScreens.screens(in: window).lazy.compactMap { screen in
            sequence(first: screen, next: \.parent).lazy.compactMap { $0 as? FileBrowserViewController }.first
        }.first
        guard let browser, browser.treeToggleState.available else { return nil }
        return browser
    }

    private func togglePane(_ action: ChatTopBarAction) -> (@MainActor () -> Void)? {
        guard let chat = frontChat, chat.canRunTopBarAction(action) else { return nil }
        return { [weak chat] in chat?.runTopBarAction(action) }
    }

    private func stop() -> (@MainActor () -> Void)? {
        guard let chat = frontChat, chat.canStopTurn else { return nil }
        return { [weak chat] in chat?.stopTurn() }
    }

    /// The code editor's own Cmd-L (Go to Line) wins while the editor has
    /// focus: its key command sits on the responder chain ahead of the menu.
    /// Offering Focus Composer then would show a second Cmd-L that cannot fire.
    private func focusComposer() -> (@MainActor () -> Void)? {
        guard let chat = frontChat, chat.canFocusComposer,
              !(firstResponder(in: window) is CodeEditorTextView) else { return nil }
        return { [weak chat] in chat?.composer.requestFocus() }
    }

    private func openAdjacentSession(offset: Int) -> (@MainActor () -> Void)? {
        guard let chat = frontChat,
              let inbox = descendant(of: rootController, as: SessionInboxViewController.self) else { return nil }
        return inbox.openerForAdjacentSession(to: chat.sessionId, offset: offset)
    }
}
