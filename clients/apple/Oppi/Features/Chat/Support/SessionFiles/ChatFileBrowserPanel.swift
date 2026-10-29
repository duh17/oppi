import UIKit

/// What the Files panel shows and reads, taken from its chat each update.
@MainActor
struct ChatFilePanelInputs {
    let sessionId: String
    let workspaceId: String?
    let serverId: String?
    /// The session's checkout. Every reader and editor opened here uses it.
    let worktreeId: String?
    /// Where a selected-text comment from a file opened here goes.
    let reviewCommentSelectionScope: ReviewCommentSelectionScope?
    let connection: ServerConnection
    let apiClient: APIClient?
    let fileIndexStore: FileIndexStore
    let navigation: AppNavigation

    var browserServices: FileBrowserServices {
        FileBrowserServices(
            connection: connection,
            apiClient: apiClient,
            fileIndexStore: fileIndexStore,
            navigation: navigation,
            reviewCommentSelectionScope: reviewCommentSelectionScope
        )
    }
}

/// Chat's Files panel: the session checkout's file browser
/// (`FileBrowserViewController`, the same browser as the workspace Files
/// screen). What the session changed is the Git panel's to show; here a
/// changed file carries Git's mark as it is browsed. Chat shows the panel at
/// the root of a router navigation controller: its trailing column in
/// regular width, a sheet in compact width. Files push above it through its
/// navigator.
///
/// The panel reads its chat's values in `updateProperties()`. The browser
/// starts at the checkout's root and is built again when the session's
/// workspace, checkout, or server changes.
@MainActor
final class ChatFilePanelViewController: UIViewController {
    private let root: AppRootEnvironment
    private let readInputs: () -> ChatFilePanelInputs?
    private let onClose: () -> Void
    private lazy var navigator = ScreenNavigator.forUIKitScreen(self, root: root)

    private let noWorkspace = UIContentUnavailableView(configuration: .empty())
    private let search = ScreenSearchController(prompt: String(localized: "Search files"))
    private var searchInstalled = false
    private var hasAppeared = false

    /// What the shown browser lists.
    private var shownScope: BrowserScope?
    private var browser: FileBrowserViewController?
    private var searchText = ""
    private var searchScope = FileBrowserSearchScope.everywhere
    private var chrome = FileBrowserEmbeddedChrome.root
    private var lastThemeID: ThemeID?
    private var barKey: BarKey?
    private lazy var backItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: String(localized: "Back"),
            image: UIImage(systemName: "chevron.left"),
            primaryAction: UIAction { [weak self] _ in self?.browser?.showParentDirectory() }
        )
        item.accessibilityIdentifier = "fileBrowser.inlineBack"
        return item
    }()
    private lazy var forwardItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: String(localized: "Forward"),
            image: UIImage(systemName: "chevron.right"),
            primaryAction: UIAction { [weak self] _ in self?.browser?.showForwardDirectory() }
        )
        item.accessibilityIdentifier = "fileBrowser.inlineForward"
        return item
    }()
    private lazy var viewOptionsItem = FileBrowserViewController.makeViewOptionsItem()

    init(
        root: AppRootEnvironment,
        inputs: @escaping () -> ChatFilePanelInputs?,
        onClose: @escaping () -> Void
    ) {
        self.root = root
        readInputs = inputs
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = String(localized: "Files")
        // The search stays in the bar under the title, as the hosted panel's
        // did; in the toolbar it covered the list's last rows.
        navigationItem.searchBarPlacementAllowsToolbarIntegration = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        noWorkspace.isHidden = true
        noWorkspace.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noWorkspace)
        NSLayoutConstraint.activate([
            noWorkspace.topAnchor.constraint(equalTo: view.topAnchor),
            noWorkspace.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            noWorkspace.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            noWorkspace.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        search.onTextChange = { [weak self] text in
            guard let self, searchText != text else { return }
            searchText = text
            setNeedsUpdateProperties()
        }
        search.onScopeChange = { [weak self] index in
            guard let self else { return }
            searchScope = FileBrowserSearchScope(rawValue: index) ?? .everywhere
            setNeedsUpdateProperties()
        }
        search.searchController.hidesNavigationBarDuringPresentation = UIDevice.current.userInterfaceIdiom != .pad
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        setNeedsUpdateProperties()
        updatePropertiesIfNeeded()
        log("Chat file panel appeared")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if searchInstalled {
            search.hostDidAppear(self)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hasAppeared = false
        log("Chat file panel disappeared")
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = root.themeStore.activeThemeID
        if themeID != lastThemeID {
            lastThemeID = themeID
            applyTheme(themeID.palette)
        }
        guard let inputs = readInputs() else { return }
        let scope = BrowserScope(inputs)
        if scope != shownScope {
            showBrowser(for: inputs, scope: scope)
        }
        browser?.updateEmbedding(services: inputs.browserServices, searchText: searchText, searchScope: searchScope)
        syncBar(browses: browser != nil)
    }

    private func applyTheme(_ palette: ThemePalette) {
        view.backgroundColor = UIColor(palette.bg)
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "folder.badge.questionmark")
        configuration.text = String(localized: "No Workspace")
        configuration.secondaryText = String(localized: "This session is not attached to a workspace.")
        configuration.background.backgroundColor = UIColor(palette.bg)
        noWorkspace.configuration = configuration
        barKey = nil
    }

    // MARK: Browser

    /// The checkout's browser, built fresh at its root; none without a
    /// workspace.
    private func showBrowser(for inputs: ChatFilePanelInputs, scope: BrowserScope) {
        shownScope = scope
        if let browser {
            browser.willMove(toParent: nil)
            browser.view.removeFromSuperview()
            browser.removeFromParent()
            self.browser = nil
        }
        searchText = ""
        searchScope = .everywhere
        chrome = .root
        guard let workspaceId = inputs.workspaceId else {
            noWorkspace.isHidden = false
            return
        }
        noWorkspace.isHidden = true
        let browser = Self.makeBrowser(root: root, inputs: inputs, workspaceId: workspaceId, navigator: navigator)
        browser.onEmbeddedChromeChange = { [weak self] chrome in
            self?.chrome = chrome
            self?.setNeedsUpdateProperties()
        }
        addChild(browser)
        browser.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(browser.view, belowSubview: noWorkspace)
        NSLayoutConstraint.activate([
            browser.view.topAnchor.constraint(equalTo: view.topAnchor),
            browser.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            browser.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        browser.didMove(toParent: self)
        self.browser = browser
    }

    /// The panel's browser: compact only, on the panel's server stores and
    /// review scope, and the session's checkout.
    static func makeBrowser(
        root: AppRootEnvironment,
        inputs: ChatFilePanelInputs,
        workspaceId: String,
        navigator: ScreenNavigator
    ) -> FileBrowserViewController {
        FileBrowserViewController(
            root: root,
            services: inputs.browserServices,
            navigator: navigator,
            serverId: inputs.serverId,
            scope: .workspace(workspaceId: workspaceId, worktreeId: inputs.worktreeId)
        )
    }

    // MARK: Bar and search

    /// The browser's folder over the panel; Done leading; View Options,
    /// Forward, and Back trailing, always there while it browses so the bar
    /// holds still, Back and Forward disabled when there is nowhere to go;
    /// the search in the bar, with Everywhere / this folder below the root.
    private func syncBar(browses: Bool) {
        let key = BarKey(
            title: browses ? chrome.title : String(localized: "Files"),
            browses: browses,
            themeID: root.themeStore.activeThemeID
        )
        if key != barKey {
            barKey = key
            navigationItem.title = key.title
            navigationItem.leftBarButtonItems = [UIBarButtonItem(
                title: String(localized: "Done"),
                primaryAction: UIAction { [weak self] _ in self?.onClose() }
            )]
            // Rightmost first: Back sits left of Forward, View Options rightmost.
            navigationItem.rightBarButtonItems = browses ? [viewOptionsItem, forwardItem, backItem] : nil
        }
        backItem.isEnabled = browses && chrome.canGoBack
        forwardItem.isEnabled = browses && chrome.canGoForward

        if browses {
            if !searchInstalled {
                searchInstalled = true
                search.install(on: self, alwaysVisible: true)
                if hasAppeared { search.hostDidAppear(self) }
            }
            search.setText(searchText)
            search.setScopes(chrome.searchScopeTitles, selected: chrome.searchScope.rawValue)
        } else if searchInstalled {
            searchInstalled = false
            search.uninstall(from: self)
        }
    }

    private func log(_ message: String) {
        let inputs = readInputs()
        ClientLog.info("FileBrowser", message, metadata: [
            "sessionId": inputs?.sessionId ?? "",
            "workspaceId": inputs?.workspaceId ?? "none",
        ])
    }

    private struct BarKey: Equatable {
        let title: String
        let browses: Bool
        let themeID: ThemeID
    }

    /// The session's workspace, checkout, and server: what the browser lists.
    private struct BrowserScope: Equatable {
        let workspaceId: String?
        let worktreeId: String?
        let serverId: String?

        init(_ inputs: ChatFilePanelInputs) {
            workspaceId = inputs.workspaceId
            worktreeId = inputs.worktreeId
            serverId = inputs.serverId
        }
    }
}

private extension FileBrowserEmbeddedChrome {
    /// The panel before its browser reports: the checkout's root.
    static var root: Self {
        Self(
            title: String(localized: "Files"),
            canGoBack: false,
            canGoForward: false,
            searchScopeTitles: nil,
            searchScope: .everywhere
        )
    }
}

#if DEBUG
extension ChatFilePanelViewController {
    /// The panel's browser as the panel builds it, on `inputs`.
    static func debugBrowserForTesting(
        root: AppRootEnvironment,
        inputs: ChatFilePanelInputs,
        workspaceId: String
    ) -> FileBrowserViewController {
        makeBrowser(root: root, inputs: inputs, workspaceId: workspaceId, navigator: .unattached)
    }
}
#endif
