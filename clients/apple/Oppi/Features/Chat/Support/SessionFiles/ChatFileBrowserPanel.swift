import UIKit

/// Top-level tab for the chat-attached file browser.
///
/// Stored per session so review work keeps returning to the user's last mode.
enum ChatFileBrowserPanelTab: String, CaseIterable, Identifiable, Sendable {
    case changed
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changed: return "Changed"
        case .all: return "All"
        }
    }
}

/// UserDefaults-backed selected-tab store for chat file panels.
struct ChatFileBrowserPanelTabStore {
    static var shared: Self { Self() }

    private let defaults: UserDefaults
    private let key = "\(AppIdentifiers.subsystem).chatFileBrowser.selectedTabsBySession"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func tab(for sessionId: String) -> ChatFileBrowserPanelTab {
        guard let sessionId = normalizedSessionId(sessionId) else { return .changed }
        let rawValue = storedTabs()[sessionId]
        return rawValue.flatMap(ChatFileBrowserPanelTab.init(rawValue:)) ?? .changed
    }

    func setTab(_ tab: ChatFileBrowserPanelTab, for sessionId: String) {
        guard let sessionId = normalizedSessionId(sessionId) else { return }
        var tabs = storedTabs()
        tabs[sessionId] = tab.rawValue
        defaults.set(tabs, forKey: key)
    }

    private func storedTabs() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private func normalizedSessionId(_ sessionId: String) -> String? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What the Files panel shows and reads, taken from its chat each update.
@MainActor
struct ChatFilePanelInputs {
    let sessionId: String
    let workspaceId: String?
    let changedFiles: [String]
    let serverId: String?
    /// The session's checkout. Every reader and editor opened here uses it.
    let worktreeId: String?
    /// Where a selected-text comment from a file opened here goes.
    let reviewCommentSelectionScope: ReviewCommentSelectionScope?
    let connection: ServerConnection
    let apiClient: APIClient?
    let fileIndexStore: FileIndexStore
    let gitStatusStore: GitStatusStore
    let navigation: AppNavigation
    /// Closes the panel through chat's state, before a changed file's review
    /// comment goes to the composer.
    let closePanel: () -> Void

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

/// Chat's Files panel: Changed (the files the session touched) and All (the
/// workspace's folders), a segmented control apart. Chat shows it at the root
/// of a router navigation controller: its trailing column in regular width, a
/// sheet in compact width. Files push above it through its navigator.
///
/// The panel reads its chat's values and tab in `updateProperties()`. Each
/// tab is a child built when the tab shows, so All starts at the workspace
/// root every time, as the SwiftUI panel's did; All is built again when the
/// session's workspace, checkout, or server changes. Both tabs search in the
/// panel's bar; Changed keeps its query across tab switches.
@MainActor
final class ChatFilePanelViewController: UIViewController {
    private let root: AppRootEnvironment
    private let readInputs: () -> ChatFilePanelInputs?
    private let readTab: () -> ChatFileBrowserPanelTab
    private let writeTab: (ChatFileBrowserPanelTab) -> Void
    private let onClose: () -> Void
    private lazy var navigator = ScreenNavigator.forUIKitScreen(self, root: root)

    private let segments = UISegmentedControl(items: ChatFileBrowserPanelTab.allCases.map(\.title))
    private let divider = UIView()
    private let content = UIView()
    private let noWorkspace = UIContentUnavailableView(configuration: .empty())
    private let search = ScreenSearchController(prompt: String(localized: "Search changed files"))
    private var searchInstalled = false
    private var hasAppeared = false

    private var shownTab: ChatFileBrowserPanelTab?
    /// What the shown All tab lists.
    private var shownAllScope: AllScope?
    private var changedList: SessionFilesListViewController?
    private var allBrowser: FileBrowserViewController?
    private var changedSearchText = ""
    private var allSearchText = ""
    private var allChrome = FileBrowserEmbeddedChrome(title: String(localized: "Files"), showsInlineBack: false)
    private var lastThemeID: ThemeID?
    private var barKey: BarKey?

    init(
        root: AppRootEnvironment,
        inputs: @escaping () -> ChatFilePanelInputs?,
        tab: @escaping () -> ChatFileBrowserPanelTab,
        setTab: @escaping (ChatFileBrowserPanelTab) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.root = root
        readInputs = inputs
        readTab = tab
        writeTab = setTab
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
        segments.accessibilityLabel = String(localized: "File browser mode")
        segments.addAction(UIAction { [weak self] _ in self?.segmentChanged() }, for: .valueChanged)
        noWorkspace.isHidden = true
        for subview in [segments, divider, content] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        noWorkspace.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(noWorkspace)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            segments.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            segments.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 14),
            segments.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -14),
            divider.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            content.topAnchor.constraint(equalTo: divider.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            noWorkspace.topAnchor.constraint(equalTo: content.topAnchor),
            noWorkspace.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            noWorkspace.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            noWorkspace.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        search.onTextChange = { [weak self] text in self?.searchTextChanged(text) }
        search.searchController.hidesNavigationBarDuringPresentation = UIDevice.current.userInterfaceIdiom != .pad
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        setNeedsUpdateProperties()
        updatePropertiesIfNeeded()
        log("Chat file panel appeared", extra: readInputs().map { ["changedFileCount": String($0.changedFiles.count)] } ?? [:])
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
        let tab = readTab()
        if tab != shownTab || (tab == .all && AllScope(inputs) != shownAllScope) {
            show(tab, inputs: inputs)
        }
        switch tab {
        case .changed:
            changedList?.update(inputs: inputs, searchText: changedSearchText)
        case .all:
            allBrowser?.updateEmbedding(services: inputs.browserServices, searchText: allSearchText)
        }
        syncBar(tab: tab, inputs: inputs)
    }

    private func applyTheme(_ palette: ThemePalette) {
        view.backgroundColor = UIColor(palette.bg)
        content.backgroundColor = UIColor(palette.bg)
        divider.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.18)
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "folder.badge.questionmark")
        configuration.text = String(localized: "No Workspace")
        configuration.secondaryText = String(localized: "This session is not attached to a workspace.")
        configuration.background.backgroundColor = UIColor(palette.bg)
        noWorkspace.configuration = configuration
        barKey = nil
    }

    // MARK: Tabs

    private func segmentChanged() {
        let index = segments.selectedSegmentIndex
        guard ChatFileBrowserPanelTab.allCases.indices.contains(index) else { return }
        let tab = ChatFileBrowserPanelTab.allCases[index]
        guard tab != shownTab else { return }
        writeTab(tab)
        setNeedsUpdateProperties()
    }

    /// The tab's child, built fresh; the other tab's goes.
    private func show(_ tab: ChatFileBrowserPanelTab, inputs: ChatFilePanelInputs) {
        let previous = shownTab
        shownTab = tab
        shownAllScope = tab == .all ? AllScope(inputs) : nil
        segments.selectedSegmentIndex = ChatFileBrowserPanelTab.allCases.firstIndex(of: tab) ?? 0
        removeChild(changedList)
        removeChild(allBrowser)
        changedList = nil
        allBrowser = nil
        noWorkspace.isHidden = true
        switch tab {
        case .changed:
            let list = SessionFilesListViewController(root: root, navigator: navigator)
            embed(list)
            changedList = list
        case .all:
            allSearchText = ""
            allChrome = FileBrowserEmbeddedChrome(title: String(localized: "Files"), showsInlineBack: false)
            if let workspaceId = inputs.workspaceId {
                let browser = Self.makeAllFilesBrowser(
                    root: root,
                    inputs: inputs,
                    workspaceId: workspaceId,
                    navigator: navigator
                )
                browser.onEmbeddedChromeChange = { [weak self] chrome in
                    self?.allChrome = chrome
                    self?.setNeedsUpdateProperties()
                }
                embed(browser)
                allBrowser = browser
            } else {
                noWorkspace.isHidden = false
            }
        }
        if let previous, previous != tab {
            log("Chat file panel tab changed")
        }
    }

    /// The All tab's browser: compact only, on the panel's server stores and
    /// review scope, and the session's checkout.
    static func makeAllFilesBrowser(
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

    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: content.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        child.didMove(toParent: self)
    }

    private func removeChild(_ child: UIViewController?) {
        guard let child else { return }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }

    // MARK: Bar and search

    private func searchTextChanged(_ text: String) {
        switch shownTab {
        case .changed:
            guard changedSearchText != text else { return }
            changedSearchText = text
        case .all:
            guard allSearchText != text else { return }
            allSearchText = text
        case nil:
            return
        }
        setNeedsUpdateProperties()
    }

    /// "Files" over the panel, or the All tab's folder; Done, and the All
    /// tab's Back to the parent folder; each tab's search in the bar.
    private func syncBar(tab: ChatFileBrowserPanelTab, inputs: ChatFilePanelInputs) {
        let browsesFolders = tab == .all && inputs.workspaceId != nil
        let key = BarKey(
            title: browsesFolders ? allChrome.title : String(localized: "Files"),
            showsInlineBack: browsesFolders && allChrome.showsInlineBack,
            themeID: root.themeStore.activeThemeID
        )
        if key != barKey {
            barKey = key
            navigationItem.title = key.title
            let done = UIBarButtonItem(
                title: String(localized: "Done"),
                primaryAction: UIAction { [weak self] _ in self?.onClose() }
            )
            var leading = [done]
            if key.showsInlineBack {
                let back = UIBarButtonItem(
                    title: String(localized: "Back"),
                    image: UIImage(systemName: "chevron.left"),
                    primaryAction: UIAction { [weak self] _ in self?.allBrowser?.showParentDirectory() }
                )
                back.accessibilityIdentifier = "fileBrowser.inlineBack"
                leading.append(back)
            }
            navigationItem.leftBarButtonItems = leading
        }

        // Changed and a workspace's All search; All without a workspace has
        // nothing to search.
        if tab == .changed || browsesFolders {
            if !searchInstalled {
                searchInstalled = true
                search.install(on: self, alwaysVisible: true)
                if hasAppeared { search.hostDidAppear(self) }
            }
            search.searchController.searchBar.placeholder = tab == .changed
                ? String(localized: "Search changed files")
                : String(localized: "Search files")
            search.setText(tab == .changed ? changedSearchText : allSearchText)
        } else if searchInstalled {
            searchInstalled = false
            search.uninstall(from: self)
        }
    }

    private func log(_ message: String, extra: [String: String] = [:]) {
        let inputs = readInputs()
        var metadata = [
            "sessionId": inputs?.sessionId ?? "",
            "workspaceId": inputs?.workspaceId ?? "none",
            "selectedTab": readTab().rawValue,
        ]
        metadata.merge(extra) { current, _ in current }
        ClientLog.info("FileBrowser", message, metadata: metadata)
    }

    private struct BarKey: Equatable {
        let title: String
        let showsInlineBack: Bool
        let themeID: ThemeID
    }

    /// The session's workspace, checkout, and server: the All tab's folders.
    private struct AllScope: Equatable {
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

#if DEBUG
extension ChatFilePanelViewController {
    /// The All tab's browser as the panel builds it, on `inputs`.
    static func debugAllFilesBrowserForTesting(
        root: AppRootEnvironment,
        inputs: ChatFilePanelInputs,
        workspaceId: String
    ) -> FileBrowserViewController {
        makeAllFilesBrowser(root: root, inputs: inputs, workspaceId: workspaceId, navigator: .unattached)
    }
}
#endif
