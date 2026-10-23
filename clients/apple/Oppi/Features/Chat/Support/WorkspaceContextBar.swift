import UIKit

// MARK: - Scoping logic (testable)

/// Pure-function extraction of the context bar's session-scoping rules.
///
/// A workspace's bar (no session) and a session in a worktree of its own list
/// the checkout's whole Git status: every change in the session's worktree is
/// the session's, including ones its shell commands made. A session in the
/// main checkout shares it with other work, so it lists only the files its
/// edit and write calls touched ("This session") until the panel's switch
/// asks for every change ("All changes").
enum ContextBarScoping {
    /// Which changes a main-checkout session's bar lists.
    enum FileScope: Hashable {
        case session
        case all
    }

    /// The session runs in a worktree of its own, not the main checkout.
    static func isOwnWorktree(_ worktreeId: String?) -> Bool {
        guard let worktreeId, !worktreeId.isEmpty else { return false }
        return worktreeId != WorkspaceWorktree.mainId
    }

    /// Only a session in the main checkout can narrow to its own files, so
    /// only its bar offers the This session / All changes switch.
    static func offersFileScope(sessionId: String?, worktreeId: String?) -> Bool {
        sessionId != nil && !isOwnWorktree(worktreeId)
    }

    /// Whether the bar lists the session's files instead of the Git status.
    static func filtersToSession(sessionId: String?, worktreeId: String?, fileScope: FileScope) -> Bool {
        offersFileScope(sessionId: sessionId, worktreeId: worktreeId) && fileScope == .session
    }

    /// The Git status narrowed to `changedFiles` (the session's
    /// `changeStats.changedFiles`); nil when the session touched nothing.
    static func sessionScope(gitStatus: GitStatus?, changedFiles: [String]?) -> SessionScopedGitStatus? {
        guard let gitStatus, let changedFiles, !changedFiles.isEmpty else { return nil }
        return SessionScopedGitStatus.filter(gitStatus: gitStatus, sessionChangedFiles: changedFiles)
    }

    static func displayFileCount(
        gitStatus: GitStatus?,
        filtersToSession: Bool,
        sessionScope: SessionScopedGitStatus?
    ) -> Int {
        if filtersToSession { return sessionScope?.sessionFileCount ?? 0 }
        return gitStatus?.uncommittedCount ?? 0
    }

    static func displayAddedLines(
        gitStatus: GitStatus?,
        filtersToSession: Bool,
        sessionScope: SessionScopedGitStatus?
    ) -> Int {
        if filtersToSession { return sessionScope?.sessionAddedLines ?? 0 }
        return gitStatus?.addedLines ?? 0
    }

    static func displayRemovedLines(
        gitStatus: GitStatus?,
        filtersToSession: Bool,
        sessionScope: SessionScopedGitStatus?
    ) -> Int {
        if filtersToSession { return sessionScope?.sessionRemovedLines ?? 0 }
        return gitStatus?.removedLines ?? 0
    }

    static func displayFiles(
        gitStatus: GitStatus?,
        filtersToSession: Bool,
        sessionScope: SessionScopedGitStatus?
    ) -> [GitFileStatus] {
        if filtersToSession { return sessionScope?.sessionFiles ?? [] }
        return gitStatus?.files ?? []
    }
}

enum ContextBarQuickActionRoute: Equatable {
    case currentSession
    case newSession
}

enum ContextBarQuickActionRouting {
    static func defaultTapRoute(sessionId: String?, canReviewInCurrentSession: Bool) -> ContextBarQuickActionRoute {
        if sessionId != nil && canReviewInCurrentSession {
            return .currentSession
        }
        return .newSession
    }
}

// MARK: - Bar

/// The Git panel's content (`GitPanelViewController`, from a chat or a
/// workspace): a summary header (branch, dirty count, +/-, ahead/behind) over
/// a table of the tappable file list with file-type icons and per-file line
/// stats, then the commit graph of every local branch and worktree
/// (`CommitGraphView`), with select-for-review controls; a session in the main
/// checkout also gets a This session / All changes switch
/// (`ContextBarScoping`). It fills the panel with no card or outer padding;
/// pin its bottom to the panel's below the required height of an empty bar
/// (0). A file opens its review and a commit its detail, each in a sheet
/// presented from `presenter`. The sheet belongs to the presenter, not to this
/// bar, so a transient loss of Git content (the bar empties) leaves an open
/// review alone.
///
/// Supports swipe-to-select: in select mode, dragging vertically across rows
/// selects or deselects them (Mail-style — first row touched determines direction).
@MainActor
final class WorkspaceContextBarView: UIView {
    /// What the host shows the bar; the bar redraws when it changes.
    struct Context: Equatable {
        var gitStatus: GitStatus?
        var isLoading = false
        var workspaceId: String?
        var sessionId: String?
        var worktreeId: String?
        var serverId: String?
    }

    /// What stays fixed for the bar's life.
    struct Options {
        var onReviewInCurrentSession: ((String, [PendingFileReference]) -> Void)?
        var fileDetailReviewCommentScope: ReviewCommentSelectionScope?
        /// Shows a chat this bar's New Session or prompt template started. Nil
        /// pushes it onto `presenter`'s stack; a panel passes its host's push,
        /// so the new chat does not open inside the panel's sheet or column.
        var pushChat: ((ChatViewController) -> Void)?
    }

    var context: Context {
        didSet {
            guard context != oldValue else { return }
            contextDidChange(from: oldValue)
        }
    }
    /// The screen that shows the bar: presents its reviews and alerts and
    /// pushes the chats it starts.
    weak var presenter: UIViewController?

    private let options: Options
    private let connection: ServerConnection
    private let apiClient: APIClient?
    private let navigation: AppNavigation

    private var isSelecting = false {
        didSet {
            guard isSelecting != oldValue else { return }
            setNeedsUpdateProperties()
            if isSelecting { Task { await loadQuickActionsIfNeeded() } }
        }
    }
    private var selectedPaths: Set<String> = [] {
        didSet { if selectedPaths != oldValue { setNeedsUpdateProperties() } }
    }
    private var launchActionInFlightTitle: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var quickActionOptions: [WorkspaceQuickActionOption] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var quickActionOptionsContextKey: String?
    private var isLoadingQuickActions = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var dragSelect = DragSelectState()
    private weak var presentedReview: UIViewController?

    /// The panel's commit graph: HEAD and every local
    /// branch, with the worktrees that have them out. Nil until the first page
    /// arrives.
    private struct GraphState: Equatable {
        /// The `graphLoadKey` this graph was loaded for.
        let key: String
        let workspaceId: String
        let worktreeId: String?
        var commits: [CommitGraphCommit]
        /// Commits the server has returned, the next page's offset.
        var fetched: Int
        var hasMore: Bool
        var worktrees: [WorkspaceWorktree]
    }
    private var graph: GraphState? {
        didSet {
            guard graph != oldValue else { return }
            graphVersion += 1
            setNeedsUpdateProperties()
        }
    }
    /// Counts changes to `graph`, so a render compares one number, not every
    /// commit, to learn whether the rows need laying out again.
    private var graphVersion = 0
    private var graphRowInputs: GraphRowInputs?
    /// The checkout and HEAD the graph shows; a new commit or another
    /// checkout reloads it.
    private var graphLoadKey: String?
    private var graphFailed = false {
        didSet { if graphFailed != oldValue { setNeedsUpdateProperties() } }
    }
    private var isLoadingMoreGraph = false {
        didSet { if isLoadingMoreGraph != oldValue { setNeedsUpdateProperties() } }
    }
    /// The graph's rows and footer live in the panel's table, outside the
    /// files rebuilt above them (a pushed Git status, the scope switch,
    /// selection): rebuilt with them, they cancelled a tap on a row or on Load
    /// more, and a status push arrives every few seconds while an agent edits.
    private let graphFooter: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0)
        return stack
    }()
    private var graphFooterKey: GraphFooterKey?

    /// This bar's This session / All changes choice; not saved.
    private var fileScope: ContextBarScoping.FileScope = .session {
        didSet {
            guard fileScope != oldValue else { return }
            selectedPaths.removeAll()
            setNeedsUpdateProperties()
        }
    }

    // Derived on each render.
    private var displayFiles: [GitFileStatus] = []
    private var sessionScope: SessionScopedGitStatus?
    private var filtersToSession = false

    // Views.
    /// The summary row over the table, then the selection bar. Hidden while
    /// there is no Git content, and the bar is 0 tall.
    private let contentStack = UIStackView()
    /// The panel's header: branch, counts, upstream.
    private lazy var summaryRow: UIStackView = {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        let row = Self.row(
            [branchGroup, changedLabel, linesGroup, spacer, aheadGroup],
            spacing: 8,
            insets: NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        )
        row.isAccessibilityElement = true
        row.accessibilityTraits = .header
        return row
    }()
    private let branchIcon = UIImageView()
    private let branchLabel = UILabel()
    private let branchGroup = UIStackView()
    private let changedLabel = UILabel()
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private let linesGroup = UIStackView()
    private let aheadLabel = UILabel()
    private let behindLabel = UILabel()
    private let aheadGroup = UIStackView()
    private let selectDivider = UIView()
    private let selectionDividerSlot = UIView()
    private lazy var selectButton: PlainRowButton = {
        let button = PlainRowButton(
            wrapping: Self.padded(selectLabel, NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        ) { [weak self] in self?.toggleSelecting() }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }()
    private let selectLabel = UILabel()
    /// This session / All changes. One control for the bar's life: rebuilt
    /// with the panel, it lost its selection animation mid-tap and flickered.
    private lazy var scopeControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [String(localized: "This session"), ""])
        control.accessibilityIdentifier = "workspace-context-bar.scope"
        control.addAction(UIAction { [weak self, weak control] _ in
            guard let self, let control else { return }
            let next: ContextBarScoping.FileScope = control.selectedSegmentIndex == 0 ? .session : .all
            self.fileScope = next
        }, for: .valueChanged)
        return control
    }()
    private lazy var scopeSwitch = Self.padded(
        scopeControl,
        NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12)
    )
    /// The panel's scroller: its files in the header, a cell per commit of
    /// the graph, then the graph's footer, so only the commits on screen have
    /// views.
    private let table = PanelTableView(frame: .zero, style: .plain)
    /// A panel table's header: everything above the graph (`panelStack`).
    /// Header and footer are plain views, not cells, so VoiceOver reads their
    /// rebuilt rows; a table caches the accessibility of a cell it never
    /// dequeued again.
    private let panelHeader = UIView()
    /// A panel table's footer: the graph's spinner, retry, or Load more, and
    /// the stash count (`graphFooter`).
    private let panelFooter = UIView()
    /// The header or footer content changed since it was last measured.
    private var panelChromeNeedsSizing = true
    /// The table width the header and footer were last measured at.
    private var panelChromeSizedWidth: CGFloat = 0
    /// The graph rows the table shows; changed only with a table update.
    private var graphRows: (layout: CommitGraphLayout, context: CommitGraphView.Context, key: GraphStyleKey)?
    private let panelStack = UIStackView()
    private let selectionBar = UIStackView()
    private var emptyHeight: NSLayoutConstraint?
    private weak var fileList: UIStackView?
    private var fileRows: [(path: String, view: UIView, mark: UIImageView?)] = []
    private weak var selectAllButton: UIButton?
    private weak var selectedCountLabel: UILabel?
    private lazy var dragSelectGesture = UIPanGestureRecognizer(target: self, action: #selector(handleDragSelect(_:)))
    private var panelKey: PanelKey?
    private var panelStatusKey: PanelStatusKey?
    private var selectionBarKey: SelectionBarKey?

    init(
        context: Context,
        options: Options = Options(),
        connection: ServerConnection,
        apiClient: APIClient?,
        navigation: AppNavigation
    ) {
        self.context = context
        self.options = options
        self.connection = connection
        self.apiClient = apiClient
        self.navigation = navigation
        super.init(frame: .zero)
        setUpViews()
        registerForTraitChanges(
            [UITraitHorizontalSizeClass.self, UITraitPreferredContentSizeCategory.self]
        ) { (bar: Self, _) in
            bar.panelKey = nil
            bar.selectionBarKey = nil
            bar.setNeedsUpdateProperties()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Review comment scope

    /// `parentScope` with a dispatch that closes the review first, so the
    /// comment reaches the composer under it.
    @MainActor
    static func makeFileDetailReviewCommentScope(
        parentScope: ReviewCommentSelectionScope?,
        dismissFileDetail: @escaping () -> Void
    ) -> ReviewCommentSelectionScope? {
        guard let parentScope else { return nil }
        switch parentScope {
        case .activeSession(let router):
            return .activeSession(router.retargetingDispatch { request in
                dismissFileDetail()
                router.dispatch(request)
            })
        }
    }

    // MARK: Derived state

    private var offersFileScope: Bool {
        ContextBarScoping.offersFileScope(sessionId: context.sessionId, worktreeId: context.worktreeId)
    }

    private var canLaunch: Bool {
        !selectedPaths.isEmpty && launchActionInFlightTitle == nil
    }

    /// Regular width (iPad, the iPhone Duo inner display) gets the larger git
    /// bar type. This is chrome, not reading text, so a fold steps it one
    /// text style with the rest of the regular layout.
    private var usesRegularTypography: Bool {
        traitCollection.horizontalSizeClass == .regular
    }

    private func font(
        _ compact: UIFont.TextStyle,
        _ regular: UIFont.TextStyle,
        _ weight: UIFont.Weight = .regular,
        mono: Bool = false
    ) -> UIFont {
        let style = usesRegularTypography ? regular : compact
        return mono ? UIFont.scaledMonospaced(style, weight) : UIFont.scaled(style, weight)
    }

    /// A fixed-size compact font (`Font.app*`) that steps to a text style in
    /// regular width.
    private func font(fixed size: CGFloat, _ weight: UIFont.Weight, regular: UIFont.TextStyle, _ regularWeight: UIFont.Weight) -> UIFont {
        usesRegularTypography
            ? UIFont.scaled(regular, regularWeight)
            : .systemFont(ofSize: size, weight: weight)
    }

    // MARK: Setup

    private func setUpViews() {
        // The content fills the panel like Outline and Context: no card.
        contentStack.axis = .vertical
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        let top = contentStack.topAnchor.constraint(equalTo: topAnchor)
        let bottom = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        // An empty bar is 0 tall; the hidden content gives way.
        top.priority = .required - 1
        bottom.priority = .required - 1
        emptyHeight = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            top, bottom,
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        setUpSummaryRow()

        table.alwaysBounceVertical = false
        table.translatesAutoresizingMaskIntoConstraints = false
        panelStack.axis = .vertical
        panelStack.alignment = .fill
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        setUpPanelTable(table)
        contentStack.addArrangedSubview(table)
        selectionBar.axis = .vertical
        contentStack.addArrangedSubview(selectionBar)

        dragSelectGesture.isEnabled = false
        dragSelectGesture.delegate = self
    }

    private func setUpSummaryRow() {
        for stack in [branchGroup, linesGroup, aheadGroup] {
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 4
            stack.setContentHuggingPriority(.required, for: .horizontal)
        }
        branchIcon.contentMode = .center
        branchIcon.image = UIImage(systemName: "arrow.branch")
        branchGroup.addArrangedSubview(branchIcon)
        branchGroup.addArrangedSubview(branchLabel)
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        changedLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        branchGroup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        linesGroup.addArrangedSubview(addedLabel)
        linesGroup.addArrangedSubview(removedLabel)
        aheadGroup.addArrangedSubview(aheadLabel)
        aheadGroup.addArrangedSubview(behindLabel)
        for label in [addedLabel, removedLabel, aheadLabel, behindLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        selectDivider.translatesAutoresizingMaskIntoConstraints = false
        selectionDividerSlot.addSubview(selectDivider)
        NSLayoutConstraint.activate([
            selectDivider.widthAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 2)),
            selectDivider.heightAnchor.constraint(equalToConstant: 18),
            selectDivider.centerYAnchor.constraint(equalTo: selectionDividerSlot.centerYAnchor),
            selectDivider.leadingAnchor.constraint(equalTo: selectionDividerSlot.leadingAnchor),
            selectDivider.trailingAnchor.constraint(equalTo: selectionDividerSlot.trailingAnchor, constant: -2),
        ])
        selectLabel.adjustsFontForContentSizeCategory = true

        let row = UIStackView(arrangedSubviews: [summaryRow, selectionDividerSlot, selectButton])
        row.axis = .horizontal
        row.alignment = .fill
        contentStack.addArrangedSubview(row)
    }

    // MARK: Render

    override func updateProperties() {
        super.updateProperties()
        let root = HostFactory.root(near: self)
        let themeID = root?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette

        filtersToSession = ContextBarScoping.filtersToSession(
            sessionId: context.sessionId,
            worktreeId: context.worktreeId,
            fileScope: fileScope
        )
        if filtersToSession, let sessionId = context.sessionId {
            let session = connection.sessionStore.sessions.first { $0.id == sessionId }
            sessionScope = ContextBarScoping.sessionScope(
                gitStatus: context.gitStatus,
                changedFiles: session?.changeStats?.changedFiles
            )
        } else {
            sessionScope = nil
        }
        displayFiles = ContextBarScoping.displayFiles(
            gitStatus: context.gitStatus,
            filtersToSession: filtersToSession,
            sessionScope: sessionScope
        )
        // A clean repository still shows its branch and commits.
        let showsContent = !(context.isLoading && context.gitStatus == nil) && context.gitStatus?.isGitRepo == true
        contentStack.isHidden = !showsContent
        emptyHeight?.isActive = !showsContent
        guard showsContent else { return }

        renderSummaryRow(palette: palette)
        loadGraphIfNeeded()
        renderPanel(themeID: themeID)
        selectionBar.isHidden = !isSelecting
        if isSelecting {
            renderSelectionBar(themeID: themeID)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsUpdateProperties()
    }

    private func renderSummaryRow(palette: ThemePalette) {
        let gitStatus = context.gitStatus
        let fileCount = ContextBarScoping.displayFileCount(
            gitStatus: gitStatus,
            filtersToSession: filtersToSession,
            sessionScope: sessionScope
        )
        let added = ContextBarScoping.displayAddedLines(
            gitStatus: gitStatus, filtersToSession: filtersToSession, sessionScope: sessionScope
        )
        let removed = ContextBarScoping.displayRemovedLines(
            gitStatus: gitStatus, filtersToSession: filtersToSession, sessionScope: sessionScope
        )

        let cyan = UIColor(palette.cyan)
        branchGroup.isHidden = gitStatus?.branch == nil
        branchLabel.text = gitStatus?.branch
        branchLabel.font = font(.caption1, .footnote, .medium, mono: true)
        branchLabel.textColor = cyan
        branchIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font(.caption2, .caption1, .semibold))
        branchIcon.tintColor = cyan

        changedLabel.isHidden = fileCount <= 0
        changedLabel.text = "\(SessionFormatting.compactCount(fileCount)) changed"
        changedLabel.font = font(.caption1, .footnote, .semibold, mono: true)
        changedLabel.textColor = Self.dirtyColor(fileCount: fileCount, palette: palette)

        linesGroup.isHidden = added <= 0 && removed <= 0
        let countFont = font(.caption2, .caption1, .bold, mono: true)
        addedLabel.isHidden = added <= 0
        addedLabel.text = "+\(SessionFormatting.compactCount(added))"
        addedLabel.font = countFont
        addedLabel.textColor = UIColor(palette.toolDiffAdded)
        removedLabel.isHidden = removed <= 0
        removedLabel.text = "-\(SessionFormatting.compactCount(removed))"
        removedLabel.font = countFont
        removedLabel.textColor = UIColor(palette.toolDiffRemoved)

        let ahead = gitStatus?.ahead ?? 0
        let behind = gitStatus?.behind ?? 0
        let tracksUpstream = gitStatus?.ahead != nil && gitStatus?.behind != nil
        aheadGroup.isHidden = !tracksUpstream || (ahead <= 0 && behind <= 0)
        let upstreamFont = font(.caption2, .caption1, mono: true)
        aheadLabel.isHidden = ahead <= 0
        aheadLabel.text = "\u{2191}\(SessionFormatting.compactCount(ahead))"
        aheadLabel.font = upstreamFont
        aheadLabel.textColor = UIColor(palette.toolDiffAdded)
        behindLabel.isHidden = behind <= 0
        behindLabel.text = "\u{2193}\(SessionFormatting.compactCount(behind))"
        behindLabel.font = upstreamFont
        behindLabel.textColor = UIColor(palette.orange)

        summaryRow.accessibilityLabel = [
            branchGroup.isHidden ? nil : branchLabel.text,
            changedLabel.isHidden ? nil : changedLabel.text,
            addedLabel.isHidden || linesGroup.isHidden ? nil : addedLabel.text,
            removedLabel.isHidden || linesGroup.isHidden ? nil : removedLabel.text,
            aheadGroup.isHidden || aheadLabel.isHidden ? nil : aheadLabel.text,
            aheadGroup.isHidden || behindLabel.isHidden ? nil : behindLabel.text,
        ].compactMap { $0 }.joined(separator: ", ")

        let showsSelect = context.workspaceId != nil
        selectionDividerSlot.isHidden = !showsSelect
        selectButton.isHidden = !showsSelect
        selectDivider.backgroundColor = .separator
        selectLabel.text = isSelecting ? String(localized: "Cancel") : String(localized: "Select")
        selectLabel.font = font(.caption2, .caption1, .semibold)
        selectLabel.textColor = UIColor(isSelecting ? palette.orange : palette.purple)
        selectButton.accessibilityLabel = selectLabel.text
    }

    private static func dirtyColor(fileCount: Int, palette: ThemePalette) -> UIColor {
        if fileCount == 0 { return UIColor(palette.toolDiffAdded) }
        if fileCount <= 5 { return UIColor(palette.fg) }
        if fileCount <= 15 { return UIColor(palette.orange) }
        return UIColor(palette.toolDiffRemoved)
    }

    // MARK: Panel

    /// Everything the panel draws above the graph but the selection.
    /// It is rebuilt only when this changes, not on every session-store update;
    /// the selection updates the rows in place, so a drag across them keeps
    /// its gesture. The graph has its own keys (`renderGraph`).
    private struct PanelKey: Equatable {
        let files: [GitFileStatus]
        let isSelecting: Bool
        /// The graph's section, or the HEAD row in its place.
        let showsGraph: Bool
        let sessionId: String?
        /// The switch's choice; nil when the bar offers no switch.
        let fileScope: ContextBarScoping.FileScope?
        let canTap: Bool
        let regular: Bool
        let themeID: ThemeID
    }

    private func renderPanel(themeID: ThemeID) {
        let showsGraph = canLoadGraph && graph?.commits.isEmpty != true
        let key = PanelKey(
            files: displayFiles,
            isSelecting: isSelecting,
            showsGraph: showsGraph,
            sessionId: context.sessionId,
            fileScope: offersFileScope ? fileScope : nil,
            canTap: context.workspaceId != nil,
            regular: usesRegularTypography,
            themeID: themeID
        )
        let palette = themeID.palette
        defer { applySelection(palette: palette) }
        renderGraph(themeID: themeID, showsGraph: showsGraph)
        // The file rows read the status's counts through `files` and its
        // totals below; its other fields change on every push.
        let panelStatus = context.gitStatus.map { PanelStatusKey($0) }
        guard key != panelKey || panelStatus != panelStatusKey else { return }
        panelKey = key
        panelStatusKey = panelStatus
        // The scope switch stays put, so a tap on it finishes.
        for view in panelStack.arrangedSubviews where view !== scopeSwitch {
            view.removeFromSuperview()
        }
        fileRows = []
        fileList = nil
        selectAllButton = nil
        selectedCountLabel = nil

        let comment = UIColor(palette.comment)
        panelStack.insertArrangedSubview(divider(comment.withAlphaComponent(0.2)), at: 0)

        if offersFileScope {
            updateScopeSwitch()
            if scopeSwitch.superview !== panelStack {
                panelStack.insertArrangedSubview(scopeSwitch, at: 1)
            }
        } else {
            scopeSwitch.removeFromSuperview()
        }

        let add: (UIView) -> Void = panelStack.addArrangedSubview

        if isSelecting {
            add(selectionHeader(palette: palette))
            add(divider(comment.withAlphaComponent(0.15)))
        }

        if !displayFiles.isEmpty {
            add(fileListView(palette: palette))
        } else if filtersToSession {
            // The repo may still be dirty; the switch above lists it.
            let none = Self.label(
                String(localized: "No changes from this session"),
                font: font(.caption2, .caption1),
                color: UIColor(palette.comment)
            )
            add(Self.padded(none, NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)))
        }

        if showsGraph {
            // The graph's rows follow in the table.
            add(divider(comment.withAlphaComponent(0.15)))
            add(Self.spacer(height: 6))
        } else if let gitStatus = context.gitStatus, gitStatus.isGitRepo {
            add(divider(comment.withAlphaComponent(0.15)))
            add(headCommitRow(gitStatus, palette: palette))
        }
        // The table resizes its header to the rebuilt files.
        panelChromeNeedsSizing = true
        table.setNeedsLayout()
    }

    /// The fields of a pushed Git status a panel draws outside its file rows
    /// and graph: the scope switch's count, the "and N more" line, and the
    /// HEAD row shown before the graph loads.
    private struct PanelStatusKey: Equatable {
        let uncommittedCount: Int
        let totalFiles: Int
        let listedFiles: Int
        let isGitRepo: Bool
        let headSha: String?
        let lastCommitMessage: String?
        let stashCount: Int

        init(_ status: GitStatus) {
            uncommittedCount = status.uncommittedCount
            totalFiles = status.totalFiles
            listedFiles = status.files.count
            isGitRepo = status.isGitRepo
            headSha = status.headSha
            lastCommitMessage = status.lastCommitMessage
            stashCount = status.stashCount
        }
    }

    /// This session / All changes, for a session in the main checkout. The
    /// count is every uncommitted change, so the other choice says what it adds.
    private func updateScopeSwitch() {
        let allCount = SessionFormatting.compactCount(context.gitStatus?.uncommittedCount ?? 0)
        let allTitle = String(localized: "All changes (\(allCount))")
        if scopeControl.titleForSegment(at: 1) != allTitle {
            scopeControl.setTitle(allTitle, forSegmentAt: 1)
        }
        scopeControl.selectedSegmentIndex = fileScope == .session ? 0 : 1
        scopeControl.setTitleTextAttributes([.font: font(.caption1, .footnote, .medium)], for: .normal)
    }

    // MARK: Commit graph

    /// What every graph row draws apart from its own commit; a change redraws
    /// all of them.
    private struct GraphStyleKey: Equatable {
        let worktrees: [WorkspaceWorktree]
        let worktreeId: String?
        let laneCount: Int
        let regular: Bool
        /// Row heights come from the fonts (`CommitGraphView.rowHeight`), so a
        /// Dynamic Type change rebuilds them.
        let contentSize: UIContentSizeCategory
        let themeID: ThemeID
    }

    private enum GraphFooterState: Equatable {
        case none
        case loading
        case failed
        case loadMore
    }

    private struct GraphFooterKey: Equatable {
        let state: GraphFooterState
        let stashCount: Int
        let regular: Bool
        let themeID: ThemeID
    }

    /// Brings the panel table's graph rows up to date (a later page inserts
    /// its rows below the shown ones; anything else reloads the table), then
    /// its footer: a spinner, a retry, or Load more, and the stash count.
    private func renderGraph(themeID: ThemeID, showsGraph: Bool) {
        // A Git status push re-renders the panel; the rows' layout is redone
        // only when the graph or how it is drawn changed.
        let inputs = GraphRowInputs(
            version: graphVersion,
            showsGraph: showsGraph,
            worktreeId: context.worktreeId,
            regular: usesRegularTypography,
            contentSize: traitCollection.preferredContentSizeCategory,
            themeID: themeID
        )
        if inputs != graphRowInputs {
            graphRowInputs = inputs
            updateGraphRows(themeID: themeID, showsGraph: showsGraph)
        }
        renderGraphFooter(themeID: themeID, showsGraph: showsGraph)
    }

    private struct GraphRowInputs: Equatable {
        let version: Int
        let showsGraph: Bool
        let worktreeId: String?
        let regular: Bool
        let contentSize: UIContentSizeCategory
        let themeID: ThemeID
    }

    /// Lays the graph out and brings the table's rows up to date: a later
    /// page inserts its rows below the shown ones; anything else reloads.
    private func updateGraphRows(themeID: ThemeID, showsGraph: Bool) {
        let palette = themeID.palette
        let old = graphRows
        var new: (layout: CommitGraphLayout, context: CommitGraphView.Context, key: GraphStyleKey)?
        if showsGraph, let graph {
            let layout = CommitGraphLayout(commits: graph.commits)
            let key = GraphStyleKey(
                worktrees: graph.worktrees,
                worktreeId: context.worktreeId,
                laneCount: layout.laneCount,
                regular: usesRegularTypography,
                contentSize: traitCollection.preferredContentSizeCategory,
                themeID: themeID
            )
            let context = old.flatMap { $0.key == key ? $0.context : nil } ?? CommitGraphView.Context(
                laneCount: layout.laneCount,
                worktrees: graph.worktrees,
                currentWorktreeId: self.context.worktreeId,
                style: CommitGraphView.Style(
                    sha: font(.caption2, .caption1, mono: true),
                    message: font(.caption2, .caption1),
                    chip: font(.caption2, .caption1, .medium),
                    chevron: font(fixed: 8, .semibold, regular: .caption2, .semibold),
                    palette: palette
                )
            )
            new = (layout, context, key)
        }
        // Rows are inserted only into a table on screen that has drawn the old
        // ones; otherwise the next reload counts them all.
        if table.window != nil, let old, let new, old.key == new.key,
           old.layout.rows.count <= new.layout.rows.count,
           new.layout.rows.starts(with: old.layout.rows) {
            if old.layout.rows.count < new.layout.rows.count {
                graphRows = new
                let added = (old.layout.rows.count..<new.layout.rows.count).map { IndexPath(row: $0, section: 0) }
                UIView.performWithoutAnimation { table.insertRows(at: added, with: .none) }
            }
        } else if old?.layout != new?.layout || old?.key != new?.key {
            graphRows = new
            table.reloadData()
        }
    }

    private func renderGraphFooter(themeID: ThemeID, showsGraph: Bool) {
        let palette = themeID.palette
        let state: GraphFooterState
        if !showsGraph {
            state = .none
        } else if graph == nil || isLoadingMoreGraph {
            state = graphFailed ? .failed : .loading
        } else if graphFailed {
            state = .failed
        } else if let graph, graph.hasMore, graph.key == graphLoadKey {
            state = .loadMore
        } else {
            state = .none
        }
        let footerKey = GraphFooterKey(
            state: state,
            // Without the graph, the HEAD row above shows the stash count.
            stashCount: showsGraph ? context.gitStatus?.stashCount ?? 0 : 0,
            regular: usesRegularTypography,
            themeID: themeID
        )
        guard footerKey != graphFooterKey else { return }
        graphFooterKey = footerKey
        graphFooter.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch state {
        case .none:
            break
        case .loading:
            graphFooter.addArrangedSubview(Self.centered(Self.smallSpinner()))
        case .failed:
            graphFooter.addArrangedSubview(graphRetryRow(palette: palette))
        case .loadMore:
            // Scrolling near the end loads the next page by itself; the button
            // is for a graph too short to scroll, and for VoiceOver.
            graphFooter.addArrangedSubview(Self.centered(linkButton(String(localized: "Load more"), palette: palette) { [weak self] in
                self?.loadMoreGraph()
            }))
        }
        if footerKey.stashCount > 0 {
            graphFooter.addArrangedSubview(Self.padded(
                Self.label(
                    "\(footerKey.stashCount) stash",
                    font: font(.caption2, .caption1, mono: true),
                    color: UIColor(palette.purple)
                ),
                NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 0, trailing: 12)
            ))
        }
        panelChromeNeedsSizing = true
        table.setNeedsLayout()
    }

    /// Sizes the panel table's header (`panelStack`) and footer
    /// (`graphFooter`) to their content at the table's width, from the table's
    /// own layout (`PanelTableView`), so the width is this pass's. A table
    /// header or footer keeps the frame it was given, so a changed one is set
    /// again.
    ///
    /// A table lays out on every scroll frame, so this measures only after the
    /// header or footer was rebuilt (`panelChromeNeedsSizing`) or the width
    /// changed.
    private func sizePanelHeaderAndFooter(_ table: UITableView) {
        let width = table.bounds.width
        guard width > 0, panelChromeNeedsSizing || width != panelChromeSizedWidth else { return }
        panelChromeNeedsSizing = false
        panelChromeSizedWidth = width
        for (container, content) in [(panelHeader, panelStack as UIView), (panelFooter, graphFooter as UIView)] {
            let height = content.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            guard container.frame != frame else { continue }
            container.frame = frame
            if container === panelHeader {
                table.tableHeaderView = container
            } else {
                table.tableFooterView = container
            }
        }
    }

    private func graphRetryRow(palette: ThemePalette) -> UIView {
        let message = Self.label(
            String(localized: "Couldn\u{2019}t load commits"),
            font: font(.caption2, .caption1),
            color: UIColor(palette.comment)
        )
        let retry = linkButton(String(localized: "Retry"), palette: palette) { [weak self] in
            guard let self else { return }
            if let graph, graph.key == graphLoadKey {
                loadMoreGraph()
            } else {
                // The first page, or a reload for a new HEAD, failed.
                graphLoadKey = nil
                setNeedsUpdateProperties()
            }
        }
        return Self.row(
            [message, retry, Self.spacer()],
            spacing: 8,
            insets: NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        )
    }

    private func linkButton(_ title: String, palette: ThemePalette, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([
                .font: font(.caption2, .caption1, .semibold),
                .foregroundColor: UIColor(palette.purple),
            ])
        )
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    private static func smallSpinner() -> UIView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        spinner.startAnimating()
        return spinner
    }

    private static func centered(_ view: UIView) -> UIView {
        let centered = UIStackView(arrangedSubviews: [view])
        centered.axis = .vertical
        centered.alignment = .center
        centered.isLayoutMarginsRelativeArrangement = true
        centered.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0)
        return centered
    }

    private var allFilesSelected: Bool {
        !displayFiles.isEmpty && displayFiles.allSatisfy { selectedPaths.contains($0.path) }
    }

    private func selectionHeader(palette: ThemePalette) -> UIView {
        let toggleAll = UIButton(configuration: .plain())
        toggleAll.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            selectedPaths = allFilesSelected ? [] : Set(displayFiles.map(\.path))
        }, for: .primaryActionTriggered)
        let count = Self.label("", font: font(.caption2, .caption1, mono: true), color: UIColor(palette.fg))
        selectAllButton = toggleAll
        selectedCountLabel = count
        return Self.row(
            [toggleAll, Self.spacer(), count],
            spacing: 8,
            insets: NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        )
    }

    /// The checkmarks, Select All / Deselect All, and the selected count.
    private func applySelection(palette: ThemePalette) {
        guard isSelecting else { return }
        if let selectAllButton {
            var configuration = UIButton.Configuration.plain()
            configuration.attributedTitle = AttributedString(
                allFilesSelected ? String(localized: "Deselect All") : String(localized: "Select All"),
                attributes: AttributeContainer([
                    .font: font(.caption2, .caption1, .semibold),
                    .foregroundColor: UIColor(palette.purple),
                ])
            )
            configuration.contentInsets = .zero
            selectAllButton.configuration = configuration
        }
        selectedCountLabel?.isHidden = selectedPaths.isEmpty
        selectedCountLabel?.text = "\(selectedPaths.count) selected"
        for row in fileRows {
            let selected = selectedPaths.contains(row.path)
            row.mark?.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
            row.mark?.tintColor = UIColor(selected ? palette.purple : palette.comment)
            row.view.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    private func fileListView(palette: ThemePalette) -> UIView {
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 1
        list.isLayoutMarginsRelativeArrangement = true
        list.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)

        for file in displayFiles {
            let row = fileRow(file, palette: palette)
            list.addArrangedSubview(row.view)
            fileRows.append((file.path, row.view, row.mark))
        }

        if !filtersToSession, let gitStatus = context.gitStatus, gitStatus.totalFiles > gitStatus.files.count {
            let more = Self.label(
                "... and \(gitStatus.totalFiles - gitStatus.files.count) more",
                font: font(.caption2, .caption1),
                color: UIColor(palette.comment)
            )
            list.addArrangedSubview(Self.padded(more, NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 0, trailing: 12)))
        }

        list.addGestureRecognizer(dragSelectGesture)
        dragSelectGesture.isEnabled = isSelecting
        fileList = list
        return list
    }

    /// A changed file's row, and its selection checkmark while selecting.
    private func fileRow(
        _ file: GitFileStatus,
        palette: ThemePalette
    ) -> (view: UIView, mark: UIImageView?) {
        let canTap = context.workspaceId != nil
        var mark: UIImageView?
        if isSelecting {
            let check = UIImageView()
            check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font(fixed: 12, .regular, regular: .caption1, .regular))
            check.contentMode = .center
            check.widthAnchor.constraint(equalToConstant: 16).isActive = true
            mark = check
        }
        let content = ChangedFileRow.content(
            path: file.path,
            added: file.addedLines,
            removed: file.removedLines,
            leading: mark.map { [$0] } ?? [],
            showsChevron: !isSelecting && canTap,
            fonts: .init(
                path: font(.caption2, .caption1, mono: true),
                count: font(.caption2, .caption1, .bold, mono: true),
                chevron: font(fixed: 8, .semibold, regular: .caption2, .semibold)
            ),
            verticalInset: usesRegularTypography ? 5 : 4,
            palette: palette
        )
        let row = PlainRowButton(wrapping: content.stack) { [weak self] in
            guard let self else { return }
            if isSelecting {
                toggleSelection(file.path)
            } else if canTap {
                presentFileReview(file)
            }
        }
        row.accessibilityLabel = content.labelParts.joined(separator: ", ")
        return (row, mark)
    }

    private func headCommitRow(_ gitStatus: GitStatus, palette: ThemePalette) -> UIView {
        var items: [UIView] = []
        if let sha = gitStatus.headSha {
            let label = Self.label(sha, font: font(.caption2, .caption1, mono: true), color: UIColor(palette.comment))
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            items.append(label)
        }
        if let message = gitStatus.lastCommitMessage {
            let label = Self.label(message, font: font(.caption2, .caption1), color: UIColor(palette.fgDim))
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            items.append(label)
        }
        if gitStatus.stashCount > 0 {
            items.append(Self.spacer())
            items.append(Self.label(
                "\(gitStatus.stashCount) stash",
                font: font(.caption2, .caption1, mono: true),
                color: UIColor(palette.purple)
            ))
        } else {
            items.append(Self.spacer())
        }
        return Self.row(items, spacing: 8, insets: NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }

    // MARK: Selection action bar

    private struct SelectionBarKey: Equatable {
        let selectedCount: Int
        let inFlightTitle: String?
        let options: [WorkspaceQuickActionOption]
        let isLoadingQuickActions: Bool
        let regular: Bool
        let themeID: ThemeID
    }

    private func renderSelectionBar(themeID: ThemeID) {
        let key = SelectionBarKey(
            selectedCount: selectedPaths.count,
            inFlightTitle: launchActionInFlightTitle,
            options: quickActionOptions,
            isLoadingQuickActions: isLoadingQuickActions,
            regular: usesRegularTypography,
            themeID: themeID
        )
        guard key != selectionBarKey else { return }
        selectionBarKey = key
        let palette = themeID.palette
        selectionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        selectionBar.addArrangedSubview(divider(UIColor(palette.comment).withAlphaComponent(0.2)))

        let insets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        if let launchActionInFlightTitle {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
            spinner.startAnimating()
            let title = Self.label(launchActionInFlightTitle, font: font(.caption2, .caption1), color: UIColor(palette.comment))
            selectionBar.addArrangedSubview(Self.row([spinner, title, Self.spacer()], spacing: 8, insets: insets))
            return
        }

        let count = selectedPaths.count
        let countLabel = Self.label(
            "\(count) file\(count == 1 ? "" : "s")",
            font: font(.caption2, .caption1, mono: true),
            color: UIColor(count == 0 ? palette.comment : palette.fg)
        )
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let actions = UIStackView()
        actions.axis = .horizontal
        actions.alignment = .center
        actions.spacing = 8
        actions.addArrangedSubview(newSessionButton(palette: palette))
        let options = WorkspaceQuickActionMenu.sorted(quickActionOptions)
        if options.isEmpty {
            actions.addArrangedSubview(Self.label(
                isLoadingQuickActions ? String(localized: "Loading templates…") : String(localized: "No prompt templates"),
                font: font(.caption2, .caption1),
                color: UIColor(palette.comment)
            ))
        } else {
            for option in options {
                let button = quickActionButton(option, palette: palette)
                button.isEnabled = canLaunch
                button.alpha = canLaunch ? 1 : 0.4
                actions.addArrangedSubview(button)
            }
        }
        let scroller = TrailingAlignedScrollView(content: actions)
        let width = scroller.widthAnchor.constraint(equalTo: actions.widthAnchor)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            width,
            scroller.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        selectionBar.addArrangedSubview(Self.row([countLabel, Self.spacer(), scroller], spacing: 8, insets: insets))
    }

    private func newSessionButton(palette: ThemePalette) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "square.and.pencil"))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font(.caption2, .caption1))
        icon.tintColor = UIColor(palette.purple)
        icon.contentMode = .center
        icon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        let title = Self.label(
            String(localized: "New Session"),
            font: font(.caption2, .caption1, .medium, mono: true),
            color: UIColor(palette.fg)
        )
        let button = capsuleButton([icon, title], palette: palette) { [weak self] in
            Task { await self?.launchEmptySession() }
        }
        button.isEnabled = launchActionInFlightTitle == nil
        button.accessibilityLabel = String(localized: "Start new session with selected files")
        return button
    }

    private func quickActionButton(_ option: WorkspaceQuickActionOption, palette: ThemePalette) -> UIButton {
        let route = ContextBarQuickActionRouting.defaultTapRoute(
            sessionId: context.sessionId,
            canReviewInCurrentSession: options.onReviewInCurrentSession != nil
        )
        let icon = UIImageView(image: UIImage(systemName: SlashCommand.Source.prompt.iconName))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font(.caption2, .caption1))
        icon.tintColor = Self.quickActionSourceColor(option.sourceScope, palette: palette)
        icon.contentMode = .center
        icon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        let name = Self.label(
            "/\(option.commandName)",
            font: font(.caption2, .caption1, .medium, mono: true),
            color: UIColor(palette.blue)
        )
        let source = Self.label(
            Self.quickActionSourceLabel(option.sourceScope),
            font: font(.caption2, .caption1, mono: true),
            color: UIColor(palette.comment)
        )
        let button = capsuleButton([icon, name, source], palette: palette) { [weak self] in
            switch route {
            case .currentSession:
                Task { await self?.useSelectionInCurrentSession(option: option) }
            case .newSession:
                Task { await self?.launchSelection(option: option) }
            }
        }
        button.accessibilityLabel = option.title
        switch route {
        case .currentSession:
            button.menu = UIMenu(children: [
                UIAction(title: String(localized: "Use in new session")) { [weak self] _ in
                    Task { await self?.launchSelection(option: option) }
                },
            ])
        case .newSession:
            if options.onReviewInCurrentSession != nil {
                button.menu = UIMenu(children: [
                    UIAction(title: String(localized: "Use in this session")) { [weak self] _ in
                        Task { await self?.useSelectionInCurrentSession(option: option) }
                    },
                ])
            }
        }
        return button
    }

    private func capsuleButton(_ items: [UIView], palette: ThemePalette, action: @escaping () -> Void) -> UIButton {
        let content = Self.row(items, spacing: 6, insets: NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9))
        let button = PlainRowButton(wrapping: content, action: action)
        let surface = ThemeSurfaceStyle.resolve(.opaqueCard, palette: palette)
        button.backgroundColor = UIColor(surface.fill)
        button.layer.borderColor = surface.stroke.map { UIColor($0).cgColor }
        button.layer.borderWidth = surface.stroke == nil ? 0 : surface.strokeLineWidth
        button.isCapsule = true
        return button
    }

    private static func quickActionSourceLabel(_ sourceScope: String?) -> String {
        switch sourceScope {
        case "project": return "Project"
        case "user": return "User"
        case "temporary": return "Custom"
        default: return "Prompt"
        }
    }

    private static func quickActionSourceColor(_ sourceScope: String?, palette: ThemePalette) -> UIColor {
        switch sourceScope {
        case "project": return UIColor(palette.orange)
        default: return UIColor(palette.green)
        }
    }

    // MARK: View helpers

    private static func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 1
        label.adjustsFontForContentSizeCategory = true
        // Only the labels that take a row's free width (paths, messages)
        // lower this.
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return label
    }

    private static func row(_ items: [UIView], spacing: CGFloat, insets: NSDirectionalEdgeInsets) -> UIStackView {
        let row = UIStackView(arrangedSubviews: items)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = spacing
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = insets
        return row
    }

    private static func spacer() -> UIView {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        return spacer
    }

    /// Vertical space in a stack.
    private static func spacer(height: CGFloat) -> UIView {
        let spacer = UIView()
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }

    private static func padded(_ view: UIView, _ insets: NSDirectionalEdgeInsets) -> UIView {
        let container = UIView()
        pad(view, in: container, insets)
        return container
    }

    private static func pad(_ view: UIView, in container: UIView, _ insets: NSDirectionalEdgeInsets) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.leading),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.trailing),
        ])
    }

    private func divider(_ color: UIColor) -> UIView {
        let divider = UIView()
        divider.backgroundColor = color
        divider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
        return divider
    }

    // MARK: Actions

    private func toggleSelecting() {
        isSelecting.toggle()
        if !isSelecting { selectedPaths.removeAll() }
    }

    private func toggleSelection(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    /// Leaves selection once a launch finished. Nothing animates: the panel
    /// fills its screen, and animating its rebuilt rows would grow each one
    /// from a zero frame, a flicker.
    private func endSelecting() {
        isSelecting = false
        selectedPaths.removeAll()
        dragSelect.reset()
    }

    private func contextDidChange(from old: Context) {
        setNeedsUpdateProperties()
        if context.workspaceId != old.workspaceId
            || context.sessionId != old.sessionId
            || context.worktreeId != old.worktreeId {
            resetQuickActionCache()
            if isSelecting { Task { await loadQuickActionsIfNeeded() } }
        }
    }

    @objc private func handleDragSelect(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            guard isSelecting, let fileList else { return }
            let location = gesture.location(in: fileList)
            var frames: [String: CGRect] = [:]
            for row in fileRows {
                frames[row.path] = row.view.frame
            }
            guard let path = DragSelectState.pathAtLocation(location, in: frames) else { return }
            var paths = selectedPaths
            if dragSelect.handleRow(path, selectedPaths: &paths) {
                selectedPaths = paths
            }
        default:
            dragSelect.reset()
        }
    }

    // MARK: Reviews

    private func presentFileReview(_ file: GitFileStatus) {
        guard let workspaceId = context.workspaceId else { return }
        let configuration = WorkspaceReviewFileDetailViewController.Configuration(
            workspaceId: workspaceId,
            selectedSessionId: context.sessionId,
            file: file.toReviewFile(),
            worktreeId: context.worktreeId,
            serverId: context.serverId,
            reviewCommentSelectionScope: reviewScopeClosingTheReview(),
            navigationFiles: displayFiles.map { $0.toReviewFile() },
            allowsHorizontalBackSwipe: false
        )
        let detail = WorkspaceReviewFileDetailViewController(
            configuration: configuration,
            connection: connection,
            apiClient: apiClient,
            navigation: navigation
        )
        detail.onClose = { [weak self] in self?.dismissReview() }
        presentReview(detail)
    }

    private func presentCommit(_ commit: GitCommitSummary) {
        let viewer = CommitDetailViewController(
            configuration: .init(
                workspaceId: context.workspaceId ?? "",
                commit: commit,
                reviewCommentSelectionScope: reviewScopeClosingTheReview()
            ),
            connection: connection,
            apiClient: apiClient,
            navigation: navigation
        )
        viewer.onClose = { [weak self] in self?.dismissReview() }
        presentReview(viewer)
    }

    /// A comment started in the review closes it first, so it reaches the
    /// composer under it.
    private func reviewScopeClosingTheReview() -> ReviewCommentSelectionScope? {
        Self.makeFileDetailReviewCommentScope(
            parentScope: options.fileDetailReviewCommentScope,
            dismissFileDetail: { [weak self] in self?.dismissReview() }
        )
    }

    /// A router sheet with its own navigation: a commit or file review pushes
    /// its new-session chat there, and that chat its forks.
    private func presentReview(_ screen: UIViewController) {
        guard presentedReview == nil, let presenter else { return }
        presentedReview = screen
        Router.present(
            screen,
            presentation: .sheet.inNavigation(),
            from: presenter,
            onDismiss: { [weak self] in self?.presentedReview = nil }
        )
    }

    private func dismissReview() {
        guard let presentedReview else { return }
        self.presentedReview = nil
        if (presentedReview.navigationController ?? presentedReview).presentingViewController != nil {
            Router.finish(presentedReview)
        }
    }

    /// Starts a session from a quick action and pushes its chat above the
    /// screen that shows this bar (or through `Options.pushChat`), with this
    /// bar's server and navigation.
    private var quickActionLauncher: WorkspaceQuickActionLauncher? {
        guard let presenter, let workspaceId = context.workspaceId else { return nil }
        return WorkspaceQuickActionLauncher(
            connection: connection,
            apiClient: apiClient,
            navigation: navigation,
            workspaceId: workspaceId,
            worktreeId: context.worktreeId,
            selectedSessionId: context.sessionId,
            presenter: presenter,
            isLaunching: { [weak self] in self?.launchActionInFlightTitle != nil },
            setProgress: { [weak self] in self?.launchActionInFlightTitle = $0 },
            push: options.pushChat
        )
    }

    // MARK: Quick actions

    private func resetQuickActionCache() {
        quickActionOptions = []
        quickActionOptionsContextKey = nil
        isLoadingQuickActions = false
    }

    private func loadQuickActionsIfNeeded() async {
        guard isSelecting else { return }
        guard let workspaceId = context.workspaceId, let api = apiClient else { return }
        let selectedSessionId = context.sessionId
        let selectedWorktreeId = context.worktreeId
        let cacheKey = "\(workspaceId)|\(selectedSessionId ?? "")|\(selectedWorktreeId ?? "")"
        guard quickActionOptionsContextKey != cacheKey else { return }
        guard !isLoadingQuickActions else { return }

        isLoadingQuickActions = true
        defer { isLoadingQuickActions = false }

        let stillCurrent = { [weak self] in
            self?.context.workspaceId == workspaceId
                && self?.context.sessionId == selectedSessionId
                && self?.context.worktreeId == selectedWorktreeId
        }
        do {
            let actions = try await api.getWorkspaceQuickActions(
                workspaceId: workspaceId,
                selectedSessionId: selectedSessionId,
                worktreeId: selectedWorktreeId
            ).actions
            guard stillCurrent() else { return }
            quickActionOptions = actions
            quickActionOptionsContextKey = cacheKey
        } catch {
            guard stillCurrent() else { return }
            quickActionOptions = []
        }
    }

    private var selectedPathsInListOrder: [String] {
        displayFiles.filter { selectedPaths.contains($0.path) }.map(\.path)
    }

    private func useSelectionInCurrentSession(option: WorkspaceQuickActionOption) async {
        guard let workspaceId = context.workspaceId, !selectedPaths.isEmpty else { return }
        guard let api = apiClient else {
            WorkspaceQuickActionMenu.presentLaunchError("Server is offline.", from: presenter)
            return
        }
        guard let onReviewInCurrentSession = options.onReviewInCurrentSession else { return }
        guard launchActionInFlightTitle == nil else { return }

        let paths = selectedPathsInListOrder
        guard !paths.isEmpty else { return }

        launchActionInFlightTitle = option.progressTitle
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.prepareWorkspaceQuickActionSelection(
                workspaceId: workspaceId,
                paths: paths,
                selectedSessionId: context.sessionId,
                worktreeId: context.worktreeId,
                promptTemplateName: option.promptTemplateName
            )
            endSelecting()
            onReviewInCurrentSession(
                response.visiblePrompt,
                response.filePaths.map {
                    PendingFileReference(path: $0, isDirectory: false, kind: .reviewFile, displayPrefix: option.title)
                }
            )
        } catch {
            WorkspaceQuickActionMenu.presentLaunchError(error.localizedDescription, from: presenter)
        }
    }

    private func launchEmptySession() async {
        guard let quickActionLauncher else { return }
        let paths = selectedPathsInListOrder
        guard await quickActionLauncher.startEmptySession({ session in
            .attaching(sessionId: session.id, filePaths: paths)
        }) else { return }
        selectedPaths.removeAll()
        isSelecting = false
    }

    private func launchSelection(option: WorkspaceQuickActionOption) async {
        guard let quickActionLauncher, !selectedPaths.isEmpty else { return }
        // Preserve file order from the list
        let paths = selectedPathsInListOrder
        guard !paths.isEmpty else { return }
        guard await quickActionLauncher.createSession(option: option, paths: paths) else { return }
        selectedPaths.removeAll()
        isSelecting = false
    }

    // MARK: Commit graph loading

    /// A panel with a workspace and a server loads a graph.
    private var canLoadGraph: Bool {
        context.workspaceId != nil && apiClient != nil
    }

    /// Loads a panel's graph when it has none for this checkout and HEAD: on
    /// open, and after a commit, a checkout, or a branch switch. A new HEAD
    /// keeps the graph on screen until its replacement arrives; another
    /// checkout's graph is dropped at once, so it never shows under this
    /// checkout's worktree marks.
    private func loadGraphIfNeeded() {
        guard canLoadGraph, let workspaceId = context.workspaceId, let api = apiClient else { return }
        guard let gitStatus = context.gitStatus, gitStatus.isGitRepo else { return }
        let worktreeId = context.worktreeId
        let checkout = [workspaceId, worktreeId ?? ""]
        let key = (checkout + [gitStatus.branch ?? "", gitStatus.headSha ?? ""]).joined(separator: "|")
        guard key != graphLoadKey else { return }
        graphLoadKey = key
        graphFailed = false
        if let graph, graph.workspaceId != workspaceId || graph.worktreeId != worktreeId {
            self.graph = nil
        }
        // A reload keeps the pages already shown (up to the server's 500), so a
        // commit while you are deep in the graph does not cut it short.
        let limit = min(500, max(50, graph?.fetched ?? 0))
        Task { [weak self] in
            do {
                let page = try await api.getGitGraph(workspaceId: workspaceId, worktreeId: worktreeId, limit: limit)
                guard let self, graphLoadKey == key else { return }
                graph = GraphState(
                    key: key,
                    workspaceId: workspaceId,
                    worktreeId: worktreeId,
                    commits: page.commits,
                    fetched: page.commits.count,
                    hasMore: page.hasMore,
                    worktrees: page.worktrees ?? []
                )
            } catch {
                guard let self, graphLoadKey == key else { return }
                graphFailed = true
            }
        }
    }

    /// The next page of the graph on screen, from the checkout it was loaded
    /// for. Nothing while a reload for a new HEAD is under way: its pages
    /// would not continue this graph.
    /// Starts it synchronously, so the many scroll callbacks near the end
    /// start one request.
    private func loadMoreGraph() {
        guard let api = apiClient, let current = graph, current.hasMore, current.key == graphLoadKey,
              !isLoadingMoreGraph else { return }
        isLoadingMoreGraph = true
        graphFailed = false
        Task { [weak self] in
            do {
                let page = try await api.getGitGraph(
                    workspaceId: current.workspaceId,
                    worktreeId: current.worktreeId,
                    offset: current.fetched
                )
                guard let self else { return }
                isLoadingMoreGraph = false
                guard graph == current else { return }
                // Pages are offsets into a log another worktree's commit can
                // shift, so a commit may come twice; draw it once.
                let shown = Set(current.commits.map(\.sha))
                graph?.commits += page.commits.filter { !shown.contains($0.sha) }
                graph?.fetched += page.commits.count
                graph?.hasMore = page.hasMore
            } catch {
                guard let self else { return }
                isLoadingMoreGraph = false
                guard graph == current else { return }
                graphFailed = true
            }
        }
    }

    /// Loads the next page once the panel scrolls within a screen of the end
    /// of the graph, the panel's last section.
    private func loadMoreGraphIfNearEnd() {
        guard graph?.hasMore == true, !graphFailed, !isLoadingMoreGraph else { return }
        let remaining = table.contentSize.height - table.contentOffset.y - table.bounds.height
        if remaining < table.bounds.height {
            loadMoreGraph()
        }
    }
}

// MARK: - Panel table

/// A whole panel's table: `panelHeader` (files and everything else above the
/// graph), a `CommitGraphView.Cell` per graph row, then `panelFooter`. Header
/// and footer are sized to their content in `layoutSubviews`; rows size
/// themselves.
extension WorkspaceContextBarView: UITableViewDataSource, UITableViewDelegate {
    func setUpPanelTable(_ table: UITableView) {
        table.dataSource = self
        table.delegate = self
        (table as? PanelTableView)?.beforeLayout = { [weak self] table in
            self?.sizePanelHeaderAndFooter(table)
        }
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.allowsSelection = false
        // Exact heights, no estimates (`CommitGraphView.rowHeight`).
        table.estimatedRowHeight = 0
        table.register(CommitGraphView.Cell.self, forCellReuseIdentifier: CommitGraphView.Cell.reuseIdentifier)
        for (container, content) in [(panelHeader, panelStack as UIView), (panelFooter, graphFooter as UIView)] {
            content.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(content)
            // No bottom pin: the container's height comes from the content's
            // (`sizePanelHeaderAndFooter`), never the other way round.
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: container.topAnchor),
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        table.tableHeaderView = panelHeader
        table.tableFooterView = panelFooter
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        graphRows?.layout.rows.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: CommitGraphView.Cell.reuseIdentifier, for: indexPath)
        if let cell = cell as? CommitGraphView.Cell, let graphRows {
            let row = graphRows.layout.rows[indexPath.row]
            cell.configure(row: row, context: graphRows.context) { [weak self] in
                self?.presentCommit(row.commit.summary)
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let graphRows else { return 0 }
        return CommitGraphView.rowHeight(for: graphRows.layout.rows[indexPath.row], context: graphRows.context)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        loadMoreGraphIfNearEnd()
    }
}

extension WorkspaceContextBarView: UIGestureRecognizerDelegate {
    /// While selecting, a drag over the file list selects (Mail-style) instead
    /// of scrolling the panel.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === dragSelectGesture && other === table.panGestureRecognizer
    }
}

/// A panel's table, which sizes its header and footer at the start of its
/// own layout: the bar's layout runs before the table has this pass's width.
@MainActor
private final class PanelTableView: UITableView {
    var beforeLayout: ((UITableView) -> Void)?

    override func layoutSubviews() {
        beforeLayout?(self)
        super.layoutSubviews()
    }
}

/// A horizontal scroller for the selection bar's actions: as wide as they
/// are, up to the 280 pt the bar allows it (pinned trailing), then it
/// scrolls, starting at the first action (`ScrollView(.horizontal)` in a
/// trailing-aligned frame).
@MainActor
private final class TrailingAlignedScrollView: UIScrollView {
    init(content: UIView) {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            frameLayoutGuide.heightAnchor.constraint(equalTo: content.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
