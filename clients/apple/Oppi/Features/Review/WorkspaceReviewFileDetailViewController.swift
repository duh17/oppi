import UIKit

enum WorkspaceReviewFileRenderer: Equatable {
    case review
    case workspaceFile
}

enum WorkspaceReviewFileRenderingPolicy {
    static func renderer(for path: String, status: String? = nil) -> WorkspaceReviewFileRenderer {
        if status?.trimmingCharacters(in: .whitespacesAndNewlines) == "D" {
            return .review
        }
        return FileType.detect(from: path).previewCategory == .text ? .review : .workspaceFile
    }
}

enum WorkspaceReviewFileNavigationPolicy {
    static func navigationFiles(_ files: [WorkspaceReviewFile]) -> [WorkspaceReviewFile] {
        var seen: Set<String> = []
        return files.filter { file in
            seen.insert(file.path).inserted
        }
    }

    static func adjacentFile(
        in files: [WorkspaceReviewFile],
        currentPath: String,
        direction: FileBrowserNavigationDirection
    ) -> WorkspaceReviewFile? {
        let files = navigationFiles(files)
        guard let currentIndex = files.firstIndex(where: { $0.path == currentPath }) else { return nil }
        let targetIndex: Int
        switch direction {
        case .previous:
            targetIndex = currentIndex - 1
        case .next:
            targetIndex = currentIndex + 1
        }
        guard files.indices.contains(targetIndex) else { return nil }
        return files[targetIndex]
    }
}

enum WorkspaceReviewFileDetailPhase: Equatable {
    case loading
    case unavailable(String)
    case loaded(WorkspaceReviewDiffResponse)

    static func resolve(
        diff: WorkspaceReviewDiffResponse?,
        error: String?
    ) -> Self {
        if let diff {
            return .loaded(diff)
        }
        if let error {
            return .unavailable(error)
        }
        return .loading
    }
}

/// One changed file of a workspace: its header, Changes (the diff) and File
/// (the current bytes in this checkout, editable) tabs, previous/next across
/// the review's files, a file list column in regular width, sharing, and
/// prompt templates that start a session about the file.
///
/// A new file shows its current bytes; a deleted one only its diff and is
/// never recreated. While the File tab's editor is open it owns the bar, the
/// tabs and file navigation hide, and Done reloads the diff once the save lands.
@MainActor
final class WorkspaceReviewFileDetailViewController: UIViewController {
    struct Configuration {
        let workspaceId: String
        let selectedSessionId: String?
        let file: WorkspaceReviewFile
        var worktreeId: String? = nil
        var serverId: String? = nil
        var reviewCommentSelectionScope: ReviewCommentSelectionScope? = nil
        var navigationFiles: [WorkspaceReviewFile] = []
        var allowsHorizontalBackSwipe = true
        /// Session-file pushes already sit in chat's Files panel. The list
        /// stays on the adjacent-file controls there. Sheets and the
        /// screenshot host keep the column.
        var showsFileListInspector = true
    }

    private enum DetailTab: Int, CaseIterable {
        case diff
        case current

        var title: String {
            switch self {
            case .diff: String(localized: "Changes")
            case .current: String(localized: "File")
            }
        }
    }

    /// What the page shows; a new key replaces the mounted content.
    private struct MountKey: Equatable {
        enum Body: Equatable {
            case loading
            case unavailable(String)
            case currentFile
            case deletedDiff
            case tabs(DetailTab)
        }

        let path: String
        let body: Body
    }

    let configuration: Configuration
    /// The sheet's close control, for a review presented as a sheet.
    var onClose: (() -> Void)? {
        didSet { setNeedsUpdateProperties() }
    }

    private let connection: ServerConnection
    private let apiClient: APIClient?
    private let appNavigation: AppNavigation

    private var activeFile: WorkspaceReviewFile? {
        didSet { setNeedsUpdateProperties() }
    }
    private var selectedTab: DetailTab = .diff {
        didSet { setNeedsUpdateProperties() }
    }
    private var diff: WorkspaceReviewDiffResponse? {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var launchActionInFlightTitle: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var quickActionOptions: [WorkspaceQuickActionOption] = []
    private var isLoadingQuickActions = false
    /// The current-bytes reader has its text editor open.
    private var isEditingCurrentFile = false {
        didSet { setNeedsUpdateProperties() }
    }
    /// Bumped when an edit ends so Changes reloads once the save lands.
    private var diffRevision = 0 {
        didSet { if diffRevision != oldValue { restartDiffLoad() } }
    }
    /// Survives a fold. Compact hides the column; regular shows it again.
    private var showsFileListColumn = true {
        didSet { setNeedsUpdateProperties() }
    }
    private var isOnScreen = false
    private var diffTask: Task<Void, Never>?
    private var quickActionTask: Task<Void, Never>?

    // Views.
    private let transitionView = UIView()
    private let pageView = UIView()
    private var mountedKey: MountKey?
    private var mountedViews: [UIView] = []
    private var mountedChildren: [UIViewController] = []
    private var tabs: UISegmentedControl?
    private var divider: UIView?
    private var diffReader: DiffReaderView?
    private var summary: ReviewFileSummaryBarView?
    private(set) var currentFileViewer: FileViewerViewController?
    private var backSwipe: HorizontalBackSwipeGestureInstaller?
#if DEBUG
    private var motionMarker: FileMotionDebugMarker?
#endif
    /// "Starting new session…" or a template's progress over the review.
    private let progressPanel = FloatingProgressPanel(borderWidth: 1)
    private lazy var adjacentButtons = AdjacentFileNavigatorButtons { [weak self] direction in
        self?.navigateToAdjacentReviewFile(direction)
    }
    private let stashButton = ReviewCommentStashFloatingButton()
    private lazy var column = TrailingColumnController(screen: self)
    private weak var fileList: ReviewFileListViewController?
    private lazy var navigator: ScreenNavigator? = HostFactory.root(near: self)
        .map { ScreenNavigator.forUIKitScreen(self, root: $0) }

    // Bar items, kept while their inputs hold.
    private lazy var closeItem: UIBarButtonItem = {
        let mode = FullScreenViewerNavigationChrome.DismissMode.modal
        let item = UIBarButtonItem(
            image: UIImage(systemName: mode.systemImageName),
            primaryAction: UIAction { [weak self] _ in self?.onClose?() }
        )
        item.accessibilityLabel = mode.accessibilityLabel
        return item
    }()
    private lazy var showFilesItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: String(localized: "Files"),
            image: UIImage(systemName: "list.bullet"),
            primaryAction: UIAction { [weak self] _ in self?.showsFileListColumn = true }
        )
        item.accessibilityIdentifier = "review-file.list.show"
        return item
    }()
    private var shareItem: UIBarButtonItem?
    private var shareItemKey: ShareKey?

    /// What the share item shares: the shown tab of this file's diff.
    private struct ShareKey: Equatable {
        let path: String
        let tab: DetailTab
        let diff: WorkspaceReviewDiffResponse
    }

    init(
        configuration: Configuration,
        connection: ServerConnection,
        apiClient: APIClient?,
        navigation: AppNavigation
    ) {
        self.configuration = configuration
        self.connection = connection
        self.apiClient = apiClient
        self.appNavigation = navigation
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Derived state

    var currentFile: WorkspaceReviewFile {
        activeFile ?? configuration.file
    }

    private var reviewCommentSelectionContext: ReviewCommentSelectionContext? {
        configuration.reviewCommentSelectionScope?.makeContext(
            sessionId: configuration.selectedSessionId,
            sourceLabel: currentFile.path.lastPathComponentForDisplay,
            filePath: currentFile.path
        )
    }

    private var currentRenderer: WorkspaceReviewFileRenderer {
        WorkspaceReviewFileRenderingPolicy.renderer(for: currentFile.path, status: currentFile.status)
    }

    /// Whether the file is brand-new (added or untracked): no prior content to diff against.
    private var isNewFile: Bool {
        let status = currentFile.status.trimmingCharacters(in: .whitespaces)
        return status == "A" || status == "??"
    }

    /// Whether the file was deleted: no current content to display.
    private var isDeletedFile: Bool {
        currentFile.status.trimmingCharacters(in: .whitespaces) == "D"
    }

    private var parentOwnsBackSwipe: Bool {
        guard currentRenderer == .review else { return false }
        guard let diff else { return true }
        if isDeletedFile { return diff.hunks.isEmpty }
        // The current-bytes reader owns its own back swipe.
        if isNewFile { return false }
        switch selectedTab {
        case .diff:
            return diff.hunks.isEmpty
        case .current:
            return false
        }
    }

    private var horizontalBackSwipeAction: (@MainActor @Sendable () -> Void)? {
        guard configuration.allowsHorizontalBackSwipe, !isEditingCurrentFile else { return nil }
        return { [weak self] in self?.navigateBack() }
    }

    private var usesReviewFileColumn: Bool {
        configuration.showsFileListInspector
            && TrailingSidePanelPolicy.usesTrailingColumn(horizontalSizeClass: traitCollection.horizontalSizeClass)
            && WorkspaceReviewFileNavigationPolicy.navigationFiles(configuration.navigationFiles).count > 1
    }

    private var showsReviewFileList: Bool {
        usesReviewFileColumn && showsFileListColumn && !isEditingCurrentFile
    }

    private func adjacentReviewFile(_ direction: FileBrowserNavigationDirection) -> WorkspaceReviewFile? {
        WorkspaceReviewFileNavigationPolicy.adjacentFile(
            in: configuration.navigationFiles,
            currentPath: currentFile.path,
            direction: direction
        )
    }

    private var leadingAccessoryCount: Int {
        AdjacentFileNavigatorLayout.leadingAccessoryCount(
            canGoPrevious: adjacentReviewFile(.previous) != nil,
            canGoNext: adjacentReviewFile(.next) != nil
        )
    }

    /// The next-file button sits in the trailing corner; Viewing Options stacks above it.
    private var trailingAccessoryCount: Int {
        AdjacentFileNavigatorLayout.trailingAccessoryCount(
            canGoPrevious: adjacentReviewFile(.previous) != nil,
            canGoNext: adjacentReviewFile(.next) != nil
        )
    }

    private var diffTaskID: String {
        [
            configuration.workspaceId,
            configuration.selectedSessionId ?? "",
            configuration.worktreeId ?? "",
            currentFile.path,
            String(diffRevision),
        ].joined(separator: "|")
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        let root: UIView = view
        transitionView.clipsToBounds = true
        for (subview, parent) in [(transitionView, root), (pageView, transitionView)] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: parent.topAnchor),
                subview.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            ])
        }
        progressPanel.isHidden = true
        progressPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressPanel)
        NSLayoutConstraint.activate([
            progressPanel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            progressPanel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            progressPanel.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32),
        ])
        addChild(column)
        view.addSubview(column.view)
        column.view.frame = .zero
        column.didMove(toParent: self)
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        // Like the hosted screen's `.task(id:)`s: each appearance loads again.
        restartDiffLoad()
        quickActionTask?.cancel()
        quickActionTask = Task { [weak self] in await self?.loadQuickActionsIfNeeded() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        diffTask?.cancel()
        diffTask = nil
        quickActionTask?.cancel()
        quickActionTask = nil
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        view.backgroundColor = UIColor(palette.bgDark)
        reconcileContent()
        updateMountedContent(themeID: themeID)
        adjacentButtons.update(
            on: view,
            canGoPrevious: !isEditingCurrentFile && adjacentReviewFile(.previous) != nil,
            canGoNext: !isEditingCurrentFile && adjacentReviewFile(.next) != nil,
            themeID: themeID
        )
        stashButton.update(
            on: view,
            presenter: self,
            scope: configuration.reviewCommentSelectionScope,
            leadingAccessoryCount: leadingAccessoryCount,
            palette: palette
        )
        progressPanel.apply(palette)
        progressPanel.text = launchActionInFlightTitle
        progressPanel.isHidden = launchActionInFlightTitle == nil
        view.bringSubviewToFront(progressPanel)
        updateFileListColumn()
        updateBar()
    }

    // MARK: Content

    private var wantedKey: MountKey {
        let body: MountKey.Body
        if currentRenderer == .workspaceFile {
            body = .currentFile
        } else {
            switch WorkspaceReviewFileDetailPhase.resolve(diff: diff, error: error) {
            case .loading:
                body = .loading
            case .unavailable(let message):
                body = .unavailable(message)
            case .loaded:
                if isNewFile {
                    body = .currentFile
                } else if isDeletedFile {
                    body = .deletedDiff
                } else {
                    body = .tabs(selectedTab)
                }
            }
        }
        return MountKey(path: currentFile.path, body: body)
    }

    private func reconcileContent() {
        let key = wantedKey
        guard key != mountedKey else { return }
        unmountContent()
        mountedKey = key
        let page = UIView()
        add(page, to: pageView)
        switch key.body {
        case .loading:
            ReviewPagePlaceholder.showLoading(String(localized: "Loading file review…"), on: page)
        case .unavailable(let message):
            add(ReviewPagePlaceholder.unavailable(title: String(localized: "Review Unavailable"), message: message), to: page)
        case .currentFile, .deletedDiff, .tabs:
            mountReview(key.body, on: page)
        }
        if configuration.allowsHorizontalBackSwipe {
            let installer = HorizontalBackSwipeGestureInstaller { [weak self] in
                guard let self, !self.isEditingCurrentFile, self.parentOwnsBackSwipe else { return }
                self.navigateBack()
            }
            installer.install(on: page)
            backSwipe = installer
        }
#if DEBUG
        if FileMotionDebugMarker.isEnabled {
            let marker = FileMotionDebugMarker(path: currentFile.path)
            marker.translatesAutoresizingMaskIntoConstraints = false
            pageView.addSubview(marker)
            NSLayoutConstraint.activate([
                marker.topAnchor.constraint(equalTo: pageView.safeAreaLayoutGuide.topAnchor),
                marker.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
                marker.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
            ])
            motionMarker = marker
        }
#endif
    }

    /// Header, then the current bytes, the diff, or the tabs.
    private func mountReview(_ body: MountKey.Body, on page: UIView) {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        let safe = page.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: safe.topAnchor),
            stack.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        let summary = ReviewFileSummaryBarView()
        stack.addArrangedSubview(summary)
        self.summary = summary

        if case .tabs(let tab) = body {
            let tabs = UISegmentedControl(items: DetailTab.allCases.map(\.title))
            tabs.selectedSegmentIndex = tab.rawValue
            tabs.addAction(UIAction { [weak self, weak tabs] _ in
                guard let self, let tabs, let tab = DetailTab(rawValue: tabs.selectedSegmentIndex) else { return }
                self.selectedTab = tab
            }, for: .valueChanged)
            tabs.accessibilityLabel = String(localized: "View")
            let tabsSlot = UIView()
            tabs.translatesAutoresizingMaskIntoConstraints = false
            tabsSlot.addSubview(tabs)
            NSLayoutConstraint.activate([
                tabs.topAnchor.constraint(equalTo: tabsSlot.topAnchor, constant: 10),
                tabs.bottomAnchor.constraint(equalTo: tabsSlot.bottomAnchor, constant: -10),
                tabs.leadingAnchor.constraint(equalTo: tabsSlot.leadingAnchor, constant: 16),
                tabs.trailingAnchor.constraint(equalTo: tabsSlot.trailingAnchor, constant: -16),
            ])
            stack.addArrangedSubview(tabsSlot)
            self.tabs = tabs
        }

        let divider = UIView()
        divider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
        stack.addArrangedSubview(divider)
        self.divider = divider

        let content: UIView
        switch body {
        case .currentFile, .tabs(.current):
            content = mountCurrentFile()
        default:
            content = mountDiffReader()
        }
        stack.addArrangedSubview(content)
    }

    /// Current bytes of the file in this checkout, read through the workspace
    /// origin, so an eligible text file offers Edit. Deleted files never get
    /// here: they stay diff-only and are never recreated.
    /// The current-bytes reader under the header: this checkout's workspace
    /// file, in a pane whose Edit joins this screen's bar. The review keeps
    /// the one staged-comment button.
    var currentFileViewerConfiguration: FileViewerViewController.Configuration {
        FileViewerViewController.Configuration(
            workspaceId: configuration.workspaceId,
            worktreeId: configuration.worktreeId,
            serverId: configuration.serverId,
            filePath: currentFile.path,
            fileName: currentFile.path.lastPathComponentForDisplay,
            sessionId: configuration.selectedSessionId,
            chromeMode: .treePane,
            allowsHorizontalBackSwipe: configuration.allowsHorizontalBackSwipe,
            showsReviewCommentStash: false,
            reviewCommentSelectionScope: configuration.reviewCommentSelectionScope
        )
    }

    private func mountCurrentFile() -> UIView {
        let viewer = FileViewerViewController(
            configuration: currentFileViewerConfiguration,
            services: .init(
                apiClient: apiClient,
                audioPlayer: connection.audioPlayer,
                sessionStore: connection.sessionStore
            )
        )
        viewer.onBackNavigation = { [weak self] in self?.navigateBack() }
        viewer.onEditingChange = { [weak self] editing in
            guard let self else { return }
            isEditingCurrentFile = editing
            if !editing { diffRevision += 1 }
        }
        let container = UIView()
        addChild(viewer)
        add(viewer.view, to: container)
        viewer.didMove(toParent: self)
        mountedChildren.append(viewer)
        currentFileViewer = viewer
        return container
    }

    private func mountDiffReader() -> UIView {
        let reader = DiffReaderView()
        diffReader = reader
        return reader
    }

    private func unmountContent() {
        for child in mountedChildren {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        mountedChildren = []
        for view in pageView.subviews {
            view.removeFromSuperview()
        }
        summary = nil
        tabs = nil
        divider = nil
        diffReader = nil
        currentFileViewer = nil
        backSwipe = nil
#if DEBUG
        motionMarker = nil
#endif
    }

    private func add(_ subview: UIView, to container: UIView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.insertSubview(subview, at: 0)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: container.topAnchor),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// Updates what stays mounted: the header's counts, the tabs, the
    /// divider's theme color, the diff.
    private func updateMountedContent(themeID: ThemeID) {
        let palette = themeID.palette
        updateSummary(themeID: themeID)
        divider?.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.2)
        tabs?.superview?.isHidden = isEditingCurrentFile
        if let tabs, tabs.selectedSegmentIndex != selectedTab.rawValue {
            tabs.selectedSegmentIndex = selectedTab.rawValue
        }
        if let diffReader, let diff {
            let selection = reviewCommentSelectionContext ?? configuration.reviewCommentSelectionScope?.makeContext()
            diffReader.reviewCommentSelectionContext = selection
            diffReader.sourceContext = selection?.sourceContext(surface: .fullScreenDiff, filePath: currentFile.path)
            diffReader.installBackSwipe(action: horizontalBackSwipeAction)
            diffReader.trailingAccessoryCount = trailingAccessoryCount
            diffReader.setDiff(
                hunks: diff.hunks,
                filePath: currentFile.path,
                emptyDescription: "This file has no textual diff to show."
            )
        }
    }

    private func updateSummary(themeID: ThemeID) {
        guard let summary else { return }
        let file = currentFile
        summary.apply(
            ReviewFileSummaryBarView.Values(
                path: file.path,
                status: file.status,
                statusLabel: file.statusLabel,
                addedLines: currentRenderer == .workspaceFile ? file.addedLines : diff?.addedLines,
                removedLines: currentRenderer == .workspaceFile ? file.removedLines : diff?.removedLines
            ),
            themeID: themeID
        )
    }

    // MARK: File list column

    private struct FileListPanel: Identifiable {
        var id: Int { 0 }
    }

    private func updateFileListColumn() {
        guard showsReviewFileList, let root = HostFactory.root(near: self) else {
            column.show(nil, root: nil)
            return
        }
        let files = WorkspaceReviewFileNavigationPolicy.navigationFiles(configuration.navigationFiles)
        fileList?.update(files: files, currentPath: currentFile.path)
        column.show(
            TrailingColumnController.Panel(
                id: AnyHashable(FileListPanel().id),
                minWidth: 240,
                idealWidth: 300,
                screen: .controller({ [weak self] in
                    let list = ReviewFileListViewController(
                        files: files,
                        currentPath: self?.currentFile.path,
                        onSelect: { file in self?.selectReviewFile(file) },
                        onHide: { self?.showsFileListColumn = false }
                    )
                    self?.fileList = list
                    return list
                })
            ),
            root: root
        )
    }

    // MARK: Bar

    private func updateBar() {
        navigationItem.title = currentFile.path.lastPathComponentForDisplay
        var leading: [UIBarButtonItem] = []
        if onClose != nil { leading.append(closeItem) }
        let viewerBar = currentFileViewer?.bar
        if viewerBar?.isEditing == true, let viewerBar {
            // The editor owns the bar while typing: status, Preview, Done.
            setItems(leading: leading, trailing: viewerBar.trailingItems)
            navigationItem.additionalOverflowItems = nil
            return
        }
        if usesReviewFileColumn, !showsFileListColumn {
            leading.append(showFilesItem)
        }
        var trailing: [UIBarButtonItem] = []
        if let share = shareBarItem() {
            trailing.append(share)
        }
        // The viewer's Edit, left of Share.
        trailing.append(contentsOf: viewerBar?.trailingItems ?? [])
        setItems(leading: leading, trailing: trailing)
        if navigationItem.additionalOverflowItems !== actionMenu {
            navigationItem.additionalOverflowItems = actionMenu
        }
    }

    /// New Session and the prompt templates in the system overflow (vertical
    /// rail aware), built each time it opens; disabled while a launch runs.
    private lazy var actionMenu = UIDeferredMenuElement.uncached { [weak self] completion in
        completion(self?.actionMenuElements() ?? [])
    }

    private func setItems(leading: [UIBarButtonItem], trailing: [UIBarButtonItem]) {
        if !(navigationItem.leftBarButtonItems ?? []).elementsEqual(leading, by: ===) {
            navigationItem.leftBarButtonItems = leading
        }
        if !(navigationItem.rightBarButtonItems ?? []).elementsEqual(trailing, by: ===) {
            navigationItem.rightBarButtonItems = trailing
        }
    }

    private func shareBarItem() -> UIBarButtonItem? {
        guard let diff, let content = toolbarShareableContent else {
            shareItem = nil
            shareItemKey = nil
            return nil
        }
        let key = ShareKey(path: currentFile.path, tab: selectedTab, diff: diff)
        if let shareItem, shareItemKey == key { return shareItem }
        let item = FileSharePresenter.makeShareBarButtonItem(for: content)
        item.title = String(localized: "Share")
        shareItem = item
        shareItemKey = key
        return item
    }

    private var toolbarShareableContent: FileShareService.ShareableContent? {
        guard currentRenderer == .review, let diff else { return nil }
        return shareableContentForReview(diff: diff)
    }

    /// Diff tab: the rendered diff with colored backgrounds and gutter bars.
    /// Current tab (or new/deleted files): the full file content.
    private func shareableContentForReview(
        diff: WorkspaceReviewDiffResponse
    ) -> FileShareService.ShareableContent? {
        let showingDiff = selectedTab == .diff && !isNewFile && !isDeletedFile
            || isDeletedFile  // deleted files always show diff

        if showingDiff, !diff.hunks.isEmpty {
            return .diff(diff.hunks, filePath: currentFile.path)
        }

        guard !diff.currentText.isEmpty else { return nil }
        return .fromText(diff.currentText, filePath: currentFile.path)
    }

    private func actionMenuElements() -> [UIMenuElement] {
        let busy = launchActionInFlightTitle != nil
        return WorkspaceQuickActionMenu.elements(
            options: quickActionOptions,
            isLoading: isLoadingQuickActions,
            newSessionDisabled: busy,
            templatesDisabled: busy,
            onNewSession: { [weak self] in await self?.startEmptySession() },
            onTemplate: { [weak self] option in await self?.createQuickActionSession(option: option) }
        )
    }

    // MARK: Sessions

    private func startEmptySession() async {
        guard launchActionInFlightTitle == nil else { return }
        guard let api = apiClient else {
            presentLaunchError("Server is offline.")
            return
        }

        launchActionInFlightTitle = String(localized: "Starting new session…")
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.createWorkspaceSession(
                workspaceId: configuration.workspaceId,
                worktreeId: configuration.worktreeId
            )
            connection.sessionStore.upsert(response.session)
            openQuickActionSession(QuickActionSessionNavDestination.attaching(
                sessionId: response.session.id,
                filePath: currentFile.path
            ))
        } catch {
            presentLaunchError(error.localizedDescription)
        }
    }

    private func createQuickActionSession(option: WorkspaceQuickActionOption) async {
        guard launchActionInFlightTitle == nil else { return }
        guard let api = apiClient else {
            presentLaunchError("Server is offline.")
            return
        }

        launchActionInFlightTitle = option.progressTitle
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.createWorkspaceQuickActionSession(
                workspaceId: configuration.workspaceId,
                paths: [currentFile.path],
                selectedSessionId: configuration.selectedSessionId,
                worktreeId: configuration.worktreeId,
                promptTemplateName: option.promptTemplateName
            )
            connection.sessionStore.upsert(response.session)
            openQuickActionSession(QuickActionSessionNavDestination(
                id: response.session.id,
                inputText: response.visiblePrompt,
                filePaths: response.filePaths,
                fileDisplayPrefix: option.title
            ))
        } catch {
            presentLaunchError(error.localizedDescription)
        }
    }

    /// Pushes the new session's chat with this review's server and navigation.
    private func openQuickActionSession(_ destination: QuickActionSessionNavDestination) {
        let chat = ChatViewController(
            sessionId: destination.id,
            connection: connection,
            navigation: appNavigation,
            apiClient: apiClient,
            workspaceIdHint: configuration.workspaceId,
            initialInputText: destination.inputText,
            initialPendingFiles: destination.pendingFileReferences
        )
        if let navigator {
            navigator.push(chat)
        } else {
            Router.push(chat, from: self)
        }
    }

    private func presentLaunchError(_ message: String) {
        WorkspaceQuickActionMenu.presentLaunchError(message, from: self)
    }

    private func loadQuickActionsIfNeeded() async {
        guard !isLoadingQuickActions, let api = apiClient else { return }

        isLoadingQuickActions = true
        defer { isLoadingQuickActions = false }

        do {
            quickActionOptions = try await api.getWorkspaceQuickActions(
                workspaceId: configuration.workspaceId,
                selectedSessionId: configuration.selectedSessionId,
                worktreeId: configuration.worktreeId
            ).actions
        } catch {
            quickActionOptions = []
        }
    }

    // MARK: Diff

    private func restartDiffLoad() {
        guard isOnScreen else { return }
        diffTask?.cancel()
        let file = currentFile
        diffTask = Task { [weak self] in await self?.loadDiff(for: file) }
    }

    private func isCurrentReviewFile(_ requestedFile: WorkspaceReviewFile) -> Bool {
        !Task.isCancelled && currentFile.path == requestedFile.path
    }

    /// File changes clear `diff` before this runs. A reload of the same file
    /// after an edit keeps the shown diff (and the mounted File tab) until the
    /// new one arrives.
    private func loadDiff(for requestedFile: WorkspaceReviewFile) async {
        guard WorkspaceReviewFileRenderingPolicy.renderer(
            for: requestedFile.path,
            status: requestedFile.status
        ) == .review else { return }
        guard let api = apiClient else {
            error = "Server is offline."
            return
        }
        await waitForSaveInFlight(path: requestedFile.path)
        guard isCurrentReviewFile(requestedFile) else { return }

        do {
            let loadedDiff = try await loadBestAvailableDiff(api: api, file: requestedFile)
            guard isCurrentReviewFile(requestedFile) else { return }
            diff = loadedDiff
            error = nil
        } catch {
            guard isCurrentReviewFile(requestedFile) else { return }
            self.error = error.localizedDescription
        }
    }

    /// Done starts the save without waiting; the diff must show the saved bytes.
    private func waitForSaveInFlight(path: String) async {
        guard let serverId = configuration.serverId, !serverId.isEmpty else { return }
        let identity = WorkspaceFileEditIdentity(
            serverId: serverId,
            workspaceId: configuration.workspaceId,
            worktreeId: configuration.worktreeId,
            path: path
        )
        await WorkspaceFileEditSessionRegistry.shared.session(for: identity)?.waitForInFlightWrite()
    }

    private func loadBestAvailableDiff(api: APIClient, file: WorkspaceReviewFile) async throws -> WorkspaceReviewDiffResponse {
        if let selectedSessionId = configuration.selectedSessionId {
            do {
                let sessionDiff = try await api.getSessionDiff(
                    workspaceId: configuration.workspaceId,
                    sessionId: selectedSessionId,
                    path: file.path
                )
                if !Self.shouldFallbackToWorkspaceDiff(sessionDiff: sessionDiff, file: file) {
                    return sessionDiff
                }
            } catch {
                // Older sessions may lack trace mutations for this path; fall back to the
                // Git work-tree diff so the review surface still opens.
            }
        }

        return try await api.getWorkspaceReviewDiff(
            workspaceId: configuration.workspaceId,
            path: file.path,
            selectedSessionId: configuration.selectedSessionId,
            worktreeId: configuration.worktreeId
        )
    }

    nonisolated static func shouldFallbackToWorkspaceDiff(
        sessionDiff: WorkspaceReviewDiffResponse,
        file: WorkspaceReviewFile
    ) -> Bool {
        let visibleGitLineChanges = (file.addedLines ?? 0) + (file.removedLines ?? 0)
        guard visibleGitLineChanges > 0 else { return false }
        return sessionDiff.hunks.isEmpty
            && sessionDiff.addedLines == 0
            && sessionDiff.removedLines == 0
    }

    // MARK: Navigation

    private func navigateToAdjacentReviewFile(_ direction: FileBrowserNavigationDirection) {
        guard let nextFile = adjacentReviewFile(direction) else { return }
        show(nextFile, direction: direction)
    }

    private func selectReviewFile(_ file: WorkspaceReviewFile) {
        guard file.path != currentFile.path else { return }
        let files = WorkspaceReviewFileNavigationPolicy.navigationFiles(configuration.navigationFiles)
        let currentIndex = files.firstIndex(where: { $0.path == currentFile.path }) ?? 0
        let nextIndex = files.firstIndex(where: { $0.path == file.path }) ?? currentIndex
        show(file, direction: nextIndex >= currentIndex ? .next : .previous)
    }

    /// Shows `file`, sliding the page in from `direction`'s edge.
    private func show(_ file: WorkspaceReviewFile, direction: FileBrowserNavigationDirection) {
        let spec = FileBrowserPushTransitionPolicy.directionalSpec(
            for: direction,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
        let outgoing = spec == nil ? nil : pageView.snapshotView(afterScreenUpdates: false)
        activeFile = file
        diff = nil
        error = nil
        restartDiffLoad()
        updatePropertiesIfNeeded()
        guard let spec, let outgoing else { return }
        outgoing.frame = pageView.frame
        transitionView.addSubview(outgoing)
        let width = transitionView.bounds.width
        let flip: CGFloat = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        func offset(_ edge: FileBrowserPushTransitionEdge) -> CGAffineTransform {
            CGAffineTransform(translationX: (edge == .trailing ? width : -width) * flip, y: 0)
        }
        pageView.transform = offset(spec.insertion)
        pageView.alpha = 0
        UIView.animate(
            withDuration: FileBrowserPushTransitionPolicy.duration,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction]
        ) { [pageView] in
            pageView.transform = .identity
            pageView.alpha = 1
            outgoing.transform = offset(spec.removal)
            outgoing.alpha = 0
        } completion: { _ in
            outgoing.removeFromSuperview()
        }
    }

    /// Pops the review, or closes the modal it is the root of.
    private func navigateBack() {
        Router.finish(self)
    }
}

/// The review's files in its trailing column; the current one is checked.
@MainActor
final class ReviewFileListViewController: UICollectionViewController {
    private var files: [WorkspaceReviewFile]
    private var currentPath: String?
    private let onSelect: (WorkspaceReviewFile) -> Void
    private let onHide: () -> Void
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?

    init(
        files: [WorkspaceReviewFile],
        currentPath: String?,
        onSelect: @escaping (WorkspaceReviewFile) -> Void,
        onHide: @escaping () -> Void
    ) {
        self.files = files
        self.currentPath = currentPath
        self.onSelect = onSelect
        self.onHide = onHide
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(
            using: UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        ))
        title = String(localized: "Files")
        let hide = UIBarButtonItem(
            title: String(localized: "Hide Files"),
            image: UIImage(systemName: "sidebar.trailing"),
            primaryAction: UIAction { [weak self] _ in self?.onHide() }
        )
        hide.accessibilityIdentifier = "review-file.list.hide"
        navigationItem.leftBarButtonItem = hide
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(files: [WorkspaceReviewFile], currentPath: String) {
        guard files != self.files || currentPath != self.currentPath else { return }
        let reconfigure = Set([self.currentPath, currentPath].compactMap { $0 })
        self.files = files
        self.currentPath = currentPath
        applySnapshot(reconfiguring: reconfigure)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.accessibilityIdentifier = "review-file.list"
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, path in
            var content = UIListContentConfiguration.cell()
            content.text = path.lastPathComponentForDisplay
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingMiddle
            cell.contentConfiguration = content
            let isCurrent = path == self?.currentPath
            cell.accessories = isCurrent ? [.checkmark()] : []
            cell.accessibilityIdentifier = "review-file.list.row"
            cell.accessibilityTraits = isCurrent ? [.button, .selected] : .button
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, path in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: path)
        }
        applySnapshot(reconfiguring: [])
    }

    private func applySnapshot(reconfiguring paths: Set<String>) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(files.map(\.path))
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(paths.contains))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let path = dataSource?.itemIdentifier(for: indexPath),
              let file = files.first(where: { $0.path == path }) else { return }
        onSelect(file)
    }
}

/// New Session and the prompt templates that start a session about a file
/// or commit, as review screens list them in their overflow menu.
@MainActor
enum WorkspaceQuickActionMenu {
    /// Project templates first, then by command name.
    static func sorted(_ options: [WorkspaceQuickActionOption]) -> [WorkspaceQuickActionOption] {
        options.sorted { left, right in
            if left.sourceScope != right.sourceScope {
                if left.sourceScope == "project" { return true }
                if right.sourceScope == "project" { return false }
            }
            return left.commandName.localizedCaseInsensitiveCompare(right.commandName) == .orderedAscending
        }
    }

    static func elements(
        options: [WorkspaceQuickActionOption],
        isLoading: Bool,
        newSessionDisabled: Bool,
        templatesDisabled: Bool,
        onNewSession: @escaping @MainActor () async -> Void,
        onTemplate: @escaping @MainActor (WorkspaceQuickActionOption) async -> Void
    ) -> [UIMenuElement] {
        let newSession = UIAction(
            title: String(localized: "New Session"),
            image: UIImage(systemName: "square.and.pencil"),
            attributes: newSessionDisabled ? .disabled : []
        ) { _ in
            Task { await onNewSession() }
        }
        let sortedOptions = sorted(options)
        let templates: [UIMenuElement]
        if isLoading && options.isEmpty {
            templates = [UIAction(title: String(localized: "Loading templates…"), attributes: .disabled) { _ in }]
        } else if sortedOptions.isEmpty {
            templates = [UIAction(title: String(localized: "No prompt templates"), attributes: .disabled) { _ in }]
        } else {
            templates = sortedOptions.map { option in
                UIAction(
                    title: "/\(option.commandName)",
                    image: UIImage(systemName: SlashCommand.Source.prompt.iconName),
                    attributes: templatesDisabled ? .disabled : []
                ) { _ in
                    Task { await onTemplate(option) }
                }
            }
        }
        return [
            newSession,
            UIMenu(title: String(localized: "Prompt Templates"), options: .displayInline, children: templates),
        ]
    }

    static func presentLaunchError(_ message: String, from presenter: UIViewController?) {
        guard let presenter else { return }
        let alert = UIAlertController(
            title: String(localized: "Unable to start action"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        presenter.present(alert, animated: true)
    }
}

/// A review page while it loads, or when it cannot show its content.
@MainActor
enum ReviewPagePlaceholder {
    /// A spinner over `text`, centered in `page`'s safe area.
    static func showLoading(_ text: String, on page: UIView) {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: page.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: page.safeAreaLayoutGuide.centerYAnchor),
        ])
    }

    static func unavailable(title: String, systemImage: String = "exclamationmark.triangle", message: String) -> UIView {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: systemImage)
        configuration.text = title
        configuration.secondaryText = message
        return UIContentUnavailableView(configuration: configuration)
    }
}
