import TipKit
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

    /// A Git repository with changes, or any Git repository when the host
    /// shows a clean one too. A session whose own files are none still has
    /// content: its branch, commits, and the switch to every change.
    static func hasContent(gitStatus: GitStatus?, showCleanWorkspace: Bool = false) -> Bool {
        guard let gitStatus, gitStatus.isGitRepo else { return false }
        return showCleanWorkspace || !gitStatus.isClean
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

/// Expandable bar showing workspace git status, over the top of a workspace's
/// sessions, and (always expanded) the whole of the chat's Git panel
/// (`Options.isPanel`).
///
/// Collapsed shows branch + dirty count + repo-wide +/-. Expanded shows a
/// tappable file list with file-type icons, per-file line stats, recent
/// commits (a panel: the commit graph of every local branch and worktree,
/// `CommitGraphView`), and select-for-review controls; a session in the main checkout
/// also gets a This session / All changes switch (`ContextBarScoping`). A
/// file opens its review and a commit its detail, each in a sheet presented
/// from `presenter`. The sheet belongs to the presenter, not to this bar, so a
/// transient loss of Git content (the bar empties) leaves an open review alone.
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
        /// Incremented by the host to collapse an expanded bar (a tap on the
        /// list or the scrim).
        var collapseToken = 0
    }

    /// What stays fixed for the bar's life.
    struct Options {
        var appliesOuterHorizontalPadding = true
        /// A workspace with no changes still shows its branch and commits.
        var showCleanWorkspace = false
        var initiallyExpanded = false
        /// The bar is a whole panel (the chat's Git panel): it stays expanded
        /// with no collapse chevron, so collapsing can never leave an empty
        /// sheet; it has no glass card, corners, or outer padding, so its
        /// content fills the panel; and its list scrolls in the height the panel gives it instead
        /// of stopping at the 480 pt an inline bar caps at. Pin its bottom with
        /// `lessThanOrEqualTo` so it hugs a short list.
        var isPanel = false
        var onReviewInCurrentSession: ((String, [PendingFileReference]) -> Void)?
        var fileDetailReviewCommentScope: ReviewCommentSelectionScope?
        /// Shows a chat this bar's New Session or prompt template started. Nil
        /// pushes it onto `presenter`'s stack, which suits a bar on its own
        /// screen; a panel passes its chat's push, so the new chat does not
        /// open inside the panel's sheet or column.
        var pushChat: ((ChatViewController) -> Void)?
    }

    var context: Context {
        didSet {
            guard context != oldValue else { return }
            contextDidChange(from: oldValue)
        }
    }
    /// Called when the bar expands or collapses. Hosts show a dismiss scrim.
    var onExpandedChanged: ((Bool) -> Void)?
    /// Called with the bar's height whenever it lays out at a new one.
    var onHeightChange: ((CGFloat) -> Void)?
    /// The screen that shows the bar: presents its reviews and alerts and
    /// pushes the chats it starts.
    weak var presenter: UIViewController?

    private let options: Options
    private let connection: ServerConnection
    private let apiClient: APIClient?
    private let navigation: AppNavigation

    private var isExpanded: Bool {
        didSet {
            guard isExpanded != oldValue else { return }
            setNeedsUpdateProperties()
            onExpandedChanged?(isExpanded)
        }
    }
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
    private var additionalCommits: [GitCommitSummary] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var hasMoreCommits = true {
        didSet { setNeedsUpdateProperties() }
    }
    private var isLoadingMore = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var dragSelect = DragSelectState()
    private weak var presentedReview: UIViewController?

    /// A panel's commit graph (`Options.isPanel`): HEAD and every local
    /// branch, with the worktrees that have them out. Nil until the first page
    /// arrives.
    private struct GraphState: Equatable {
        /// The `graphLoadKey` this graph was loaded for.
        let key: String
        let workspaceId: String
        let worktreeId: String?
        var commits: [CommitGraphCommit]
        var hasMore: Bool
        var worktrees: [WorkspaceWorktree]
    }
    private var graph: GraphState? {
        didSet { if graph != oldValue { setNeedsUpdateProperties() } }
    }
    /// The checkout and HEAD the graph shows; a new commit or another
    /// checkout reloads it.
    private var graphLoadKey: String?
    private var graphFailed = false {
        didSet { if graphFailed != oldValue { setNeedsUpdateProperties() } }
    }
    private var isLoadingMoreGraph = false {
        didSet { if isLoadingMoreGraph != oldValue { setNeedsUpdateProperties() } }
    }
    /// The graph's rows, kept across panel rebuilds (a Git status update, the
    /// scope switch, selection) until the graph itself changes.
    private var graphRows: (key: GraphRowsKey, view: UIView)?

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
    private let card = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let cardStack = UIStackView()
    /// Expands and collapses the bar: branch, counts, upstream, chevron.
    private lazy var toggleButton: PlainRowButton = {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        let button = PlainRowButton(wrapping: Self.row(
            [branchGroup, changedLabel, linesGroup, spacer, aheadGroup, chevron],
            spacing: 8,
            insets: NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        )) { [weak self] in self?.toggleExpanded() }
        button.accessibilityIdentifier = "workspace-context-bar.toggle"
        return button
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
    private let chevron = UIImageView()
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
            animateLayout(duration: 0.15) { self.fileScope = next }
        }, for: .valueChanged)
        return control
    }()
    private lazy var scopeSwitch = Self.padded(
        scopeControl,
        NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12)
    )
    private let tipHost = FeatureEducationTipHostView(
        tip: FeatureEducationTips.ChangedFilesBarTip(),
        descriptor: FeatureEducationTips.changedFilesBar,
        insets: NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    )
    private let expandedStack = UIStackView()
    private let scrollView = UIScrollView()
    private let panelStack = UIStackView()
    private let selectionBar = UIStackView()
    private var emptyHeight: NSLayoutConstraint?
    private var cardLeading: NSLayoutConstraint?
    private var cardTrailing: NSLayoutConstraint?
    private weak var fileList: UIStackView?
    private var fileRows: [(path: String, view: UIView, mark: UIImageView?)] = []
    private weak var selectAllButton: UIButton?
    private weak var selectedCountLabel: UILabel?
    private lazy var dragSelectGesture = UIPanGestureRecognizer(target: self, action: #selector(handleDragSelect(_:)))
    private var panelKey: PanelKey?
    private var selectionBarKey: SelectionBarKey?
    private var lastReportedHeight: CGFloat = -1
    private var tipStarted = false

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
        isExpanded = options.initiallyExpanded || options.isPanel
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

    private var hasContent: Bool {
        ContextBarScoping.hasContent(gitStatus: context.gitStatus, showCleanWorkspace: options.showCleanWorkspace)
    }

    private var offersFileScope: Bool {
        ContextBarScoping.offersFileScope(sessionId: context.sessionId, worktreeId: context.worktreeId)
    }

    /// All commits: recent from git status + any additionally loaded ones.
    private var allCommits: [GitCommitSummary] {
        (context.gitStatus?.recentCommits ?? []) + additionalCommits
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
        // A panel's content fills the panel like Outline and Context: glass
        // is for floating controls, not content, so the card has no chrome.
        if options.isPanel {
            card.effect = nil
        } else {
            card.layer.cornerRadius = 10
            card.layer.cornerCurve = .continuous
        }
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        cardStack.axis = .vertical
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(cardStack)

        let leading = card.leadingAnchor.constraint(equalTo: leadingAnchor)
        let trailing = card.trailingAnchor.constraint(equalTo: trailingAnchor)
        let top = card.topAnchor.constraint(equalTo: topAnchor, constant: options.isPanel ? 0 : 4)
        let bottom = card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: options.isPanel ? 0 : -2)
        // An empty bar is 0 tall; the card's padding gives way.
        top.priority = .required - 1
        bottom.priority = .required - 1
        let empty = heightAnchor.constraint(equalToConstant: 0)
        emptyHeight = empty
        cardLeading = leading
        cardTrailing = trailing
        NSLayoutConstraint.activate([
            leading, trailing, top, bottom,
            cardStack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
        ])

        setUpCollapsedRow()
        // The tip says to tap the bar open; a panel is open already.
        if !options.isPanel {
            cardStack.addArrangedSubview(tipHost)
        }

        expandedStack.axis = .vertical
        scrollView.alwaysBounceVertical = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        panelStack.axis = .vertical
        panelStack.alignment = .fill
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(panelStack)
        let hug = scrollView.frameLayoutGuide.heightAnchor.constraint(equalTo: panelStack.heightAnchor)
        hug.priority = .defaultHigh
        // An inline bar's panel hugs its rows up to 480 pt, then scrolls; a
        // whole panel scrolls in the height its host gives it.
        let maxHeight = scrollView.frameLayoutGuide.heightAnchor.constraint(lessThanOrEqualToConstant: 480)
        maxHeight.isActive = !options.isPanel
        NSLayoutConstraint.activate([
            panelStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            panelStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            panelStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            panelStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            hug,
        ])
        expandedStack.addArrangedSubview(scrollView)
        selectionBar.axis = .vertical
        expandedStack.addArrangedSubview(selectionBar)
        cardStack.addArrangedSubview(expandedStack)

        dragSelectGesture.isEnabled = false
        dragSelectGesture.delegate = self
    }

    private func setUpCollapsedRow() {
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
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)

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

        let row = UIStackView(arrangedSubviews: [toggleButton, selectionDividerSlot, selectButton])
        row.axis = .horizontal
        row.alignment = .fill
        cardStack.addArrangedSubview(row)
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
        let showsContent = !(context.isLoading && context.gitStatus == nil) && hasContent
        card.isHidden = !showsContent
        emptyHeight?.isActive = !showsContent
        let padding: CGFloat = options.appliesOuterHorizontalPadding && !options.isPanel ? 16 : 0
        cardLeading?.constant = padding
        cardTrailing?.constant = -padding
        updateTip(showsContent: showsContent)
        guard showsContent else { return }

        renderCollapsedRow(palette: palette)
        expandedStack.isHidden = !isExpanded
        guard isExpanded else { return }
        loadGraphIfNeeded()
        renderPanel(themeID: themeID)
        selectionBar.isHidden = !isSelecting
        if isSelecting {
            renderSelectionBar(themeID: themeID)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bounds.height
        guard abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onHeightChange?(height)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsUpdateProperties()
        if window == nil {
            stopTip()
        }
    }

    private func updateTip(showsContent: Bool) {
        if showsContent, window != nil, !options.isPanel {
            guard !tipStarted else { return }
            tipStarted = true
            tipHost.start()
        } else {
            stopTip()
        }
    }

    private func stopTip() {
        guard tipStarted else { return }
        tipStarted = false
        tipHost.stop()
    }

    private func renderCollapsedRow(palette: ThemePalette) {
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

        // A panel's summary row is its header: nothing to collapse.
        chevron.isHidden = options.isPanel
        toggleButton.isUserInteractionEnabled = !options.isPanel
        toggleButton.accessibilityTraits = options.isPanel ? .header : .button
        chevron.image = UIImage(systemName: isExpanded ? "chevron.up" : "chevron.down")
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: font(fixed: 9, .bold, regular: .caption2, .bold)
        )
        chevron.tintColor = UIColor(palette.comment)

        toggleButton.accessibilityLabel = [
            branchGroup.isHidden ? nil : branchLabel.text,
            changedLabel.isHidden ? nil : changedLabel.text,
            addedLabel.isHidden || linesGroup.isHidden ? nil : addedLabel.text,
            removedLabel.isHidden || linesGroup.isHidden ? nil : removedLabel.text,
            aheadGroup.isHidden || aheadLabel.isHidden ? nil : aheadLabel.text,
            aheadGroup.isHidden || behindLabel.isHidden ? nil : behindLabel.text,
        ].compactMap { $0 }.joined(separator: ", ")

        let showsSelect = isExpanded && context.workspaceId != nil
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

    // MARK: Expanded panel

    /// Everything the expanded panel draws but the selection. The panel is
    /// rebuilt only when this changes, not on every session-store update;
    /// the selection updates the rows in place, so a drag across them keeps
    /// its gesture.
    private struct PanelKey: Equatable {
        let files: [GitFileStatus]
        let isSelecting: Bool
        let commits: [GitCommitSummary]
        let hasMoreCommits: Bool
        let isLoadingMore: Bool
        let graph: GraphState?
        let graphFailed: Bool
        let isLoadingMoreGraph: Bool
        let gitStatus: GitStatus?
        let sessionId: String?
        /// The switch's choice; nil when the bar offers no switch.
        let fileScope: ContextBarScoping.FileScope?
        let canTap: Bool
        let regular: Bool
        let themeID: ThemeID
    }

    private func renderPanel(themeID: ThemeID) {
        let key = PanelKey(
            files: displayFiles,
            isSelecting: isSelecting,
            commits: options.isPanel ? [] : allCommits,
            hasMoreCommits: hasMoreCommits,
            isLoadingMore: isLoadingMore,
            graph: graph,
            graphFailed: graphFailed,
            isLoadingMoreGraph: isLoadingMoreGraph,
            gitStatus: context.gitStatus,
            sessionId: context.sessionId,
            fileScope: offersFileScope ? fileScope : nil,
            canTap: context.workspaceId != nil,
            regular: usesRegularTypography,
            themeID: themeID
        )
        let palette = themeID.palette
        defer { applySelection(palette: palette) }
        guard key != panelKey else { return }
        panelKey = key
        // The scope switch stays put, so a tap on it animates to the end.
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
                panelStack.addArrangedSubview(scopeSwitch)
            }
        } else {
            scopeSwitch.removeFromSuperview()
        }

        if isSelecting {
            panelStack.addArrangedSubview(selectionHeader(palette: palette))
            panelStack.addArrangedSubview(divider(comment.withAlphaComponent(0.15)))
        }

        if !displayFiles.isEmpty {
            panelStack.addArrangedSubview(fileListView(palette: palette))
        } else if filtersToSession {
            // The repo may still be dirty; the switch above lists it.
            let none = Self.label(
                String(localized: "No changes from this session"),
                font: font(.caption2, .caption1),
                color: UIColor(palette.comment)
            )
            panelStack.addArrangedSubview(
                Self.padded(none, NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            )
        }

        if canLoadGraph, graph?.commits.isEmpty != true {
            panelStack.addArrangedSubview(divider(comment.withAlphaComponent(0.15)))
            panelStack.addArrangedSubview(graphSection(themeID: themeID))
        } else if !options.isPanel, !allCommits.isEmpty {
            panelStack.addArrangedSubview(divider(comment.withAlphaComponent(0.15)))
            panelStack.addArrangedSubview(commitList(palette: palette))
        } else if let gitStatus = context.gitStatus, gitStatus.isGitRepo {
            panelStack.addArrangedSubview(divider(comment.withAlphaComponent(0.15)))
            panelStack.addArrangedSubview(headCommitRow(gitStatus, palette: palette))
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

    /// What the graph's rows draw; the rows are rebuilt only when it changes.
    private struct GraphRowsKey: Equatable {
        let commits: [CommitGraphCommit]
        let worktrees: [WorkspaceWorktree]
        let worktreeId: String?
        let regular: Bool
        let themeID: ThemeID
    }

    /// The graph, its Load more or retry, and the stash count.
    private func graphSection(themeID: ThemeID) -> UIView {
        let palette = themeID.palette
        let section = UIStackView()
        section.axis = .vertical
        section.isLayoutMarginsRelativeArrangement = true
        section.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)

        guard let graph else {
            section.addArrangedSubview(graphFailed ? graphRetryRow(palette: palette) : Self.centered(Self.smallSpinner()))
            return section
        }

        let key = GraphRowsKey(
            commits: graph.commits,
            worktrees: graph.worktrees,
            worktreeId: context.worktreeId,
            regular: usesRegularTypography,
            themeID: themeID
        )
        if graphRows?.key != key {
            let rows = CommitGraphView.make(
                layout: CommitGraphLayout(commits: graph.commits),
                worktrees: graph.worktrees,
                currentWorktreeId: context.worktreeId,
                style: CommitGraphView.Style(
                    sha: font(.caption2, .caption1, mono: true),
                    message: font(.caption2, .caption1),
                    chip: font(.caption2, .caption1, .medium),
                    chevron: font(fixed: 8, .semibold, regular: .caption2, .semibold),
                    palette: palette
                ),
                onSelect: { [weak self] commit in self?.presentCommit(commit.summary) }
            )
            graphRows = (key, rows)
        }
        if let rows = graphRows?.view {
            section.addArrangedSubview(rows)
        }

        if isLoadingMoreGraph {
            section.addArrangedSubview(Self.centered(Self.smallSpinner()))
        } else if graphFailed {
            section.addArrangedSubview(graphRetryRow(palette: palette))
        } else if graph.hasMore, graph.key == graphLoadKey {
            section.addArrangedSubview(Self.centered(linkButton(String(localized: "Load more"), palette: palette) { [weak self] in
                Task { await self?.loadMoreGraph() }
            }))
        }

        if let gitStatus = context.gitStatus, gitStatus.stashCount > 0 {
            section.addArrangedSubview(Self.padded(
                Self.label(
                    "\(gitStatus.stashCount) stash",
                    font: font(.caption2, .caption1, mono: true),
                    color: UIColor(palette.purple)
                ),
                NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 0, trailing: 12)
            ))
        }
        return section
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
                Task { await self.loadMoreGraph() }
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

    private func commitList(palette: ThemePalette) -> UIView {
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 2
        list.isLayoutMarginsRelativeArrangement = true
        list.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        for commit in allCommits {
            let sha = Self.label(commit.sha, font: font(.caption2, .caption1, mono: true), color: UIColor(palette.comment))
            sha.setContentCompressionResistancePriority(.required, for: .horizontal)
            let message = Self.label(commit.message, font: font(.caption2, .caption1), color: UIColor(palette.fgDim))
            message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            message.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let chevron = ChangedFileRow.chevron(font: font(fixed: 8, .semibold, regular: .caption2, .semibold), palette: palette)
            let content = Self.row([sha, message, chevron], spacing: 8, insets: .zero)
            content.setCustomSpacing(20, after: message)
            let row = PlainRowButton(wrapping: content) { [weak self] in self?.presentCommit(commit) }
            row.accessibilityLabel = "\(commit.sha), \(commit.message)"
            list.addArrangedSubview(row)
        }

        if hasMoreCommits {
            let loadMore: UIView
            if isLoadingMore {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                spinner.startAnimating()
                loadMore = spinner
            } else {
                var configuration = UIButton.Configuration.plain()
                configuration.attributedTitle = AttributedString(
                    String(localized: "Load more"),
                    attributes: AttributeContainer([
                        .font: font(.caption2, .caption1, .semibold),
                        .foregroundColor: UIColor(palette.purple),
                    ])
                )
                configuration.contentInsets = .zero
                let button = UIButton(configuration: configuration)
                button.addAction(UIAction { [weak self] _ in
                    Task { await self?.loadMoreCommitsIfPossible() }
                }, for: .primaryActionTriggered)
                loadMore = button
            }
            let centered = UIStackView(arrangedSubviews: [loadMore])
            centered.axis = .vertical
            centered.alignment = .center
            centered.isLayoutMarginsRelativeArrangement = true
            centered.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0)
            list.addArrangedSubview(centered)
        }

        if let gitStatus = context.gitStatus, gitStatus.stashCount > 0 {
            list.addArrangedSubview(Self.label(
                "\(gitStatus.stashCount) stash",
                font: font(.caption2, .caption1, mono: true),
                color: UIColor(palette.purple)
            ))
        }
        return list
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

    private func toggleExpanded() {
        guard !options.isPanel else { return }
        let wasExpanded = isExpanded
        animateLayout {
            self.isExpanded.toggle()
            if !self.isExpanded {
                self.isSelecting = false
                self.selectedPaths.removeAll()
            }
        }
        if !wasExpanded, isExpanded {
            FeatureEducationTips.markChangedFilesBarExpanded()
        }
    }

    private func toggleSelecting() {
        animateLayout(duration: 0.15) {
            self.isSelecting.toggle()
            if !self.isSelecting { self.selectedPaths.removeAll() }
        }
    }

    private func toggleSelection(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    /// Collapses an expanded bar (the host's collapse token changed, or a
    /// launch finished). A panel stays expanded and only leaves selection.
    private func collapseBar() {
        animateLayout {
            self.isExpanded = self.options.isPanel
            self.isSelecting = false
            self.selectedPaths.removeAll()
            self.dragSelect.reset()
        }
    }

    /// Applies `changes` and animates the bar and its host to the new layout.
    /// A panel fills its screen and has no size to animate; animating its
    /// rebuilt rows would grow each one from a zero frame, a flicker.
    private func animateLayout(duration: TimeInterval = 0.2, _ changes: @escaping () -> Void) {
        changes()
        guard window != nil, !options.isPanel else { return }
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.updatePropertiesIfNeeded()
            (self.superview ?? self).layoutIfNeeded()
        }
    }

    private func contextDidChange(from old: Context) {
        setNeedsUpdateProperties()
        if context.collapseToken != old.collapseToken, isExpanded {
            collapseBar()
        }
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
            selectedPaths.removeAll()
            isSelecting = false
            collapseBar()
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
        options.isPanel && context.workspaceId != nil && apiClient != nil
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
        // A reload keeps the pages already shown.
        let limit = min(200, max(50, graph?.commits.count ?? 0))
        Task { [weak self] in
            do {
                let page = try await api.getGitGraph(workspaceId: workspaceId, worktreeId: worktreeId, limit: limit)
                guard let self, graphLoadKey == key else { return }
                graph = GraphState(
                    key: key,
                    workspaceId: workspaceId,
                    worktreeId: worktreeId,
                    commits: page.commits,
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
    private func loadMoreGraph() async {
        guard let api = apiClient, let current = graph, current.key == graphLoadKey,
              !isLoadingMoreGraph else { return }
        isLoadingMoreGraph = true
        graphFailed = false
        defer { isLoadingMoreGraph = false }
        do {
            let page = try await api.getGitGraph(
                workspaceId: current.workspaceId,
                worktreeId: current.worktreeId,
                offset: current.commits.count
            )
            guard graph == current else { return }
            graph?.commits += page.commits
            graph?.hasMore = page.hasMore
        } catch {
            guard graph == current else { return }
            graphFailed = true
        }
    }

    // MARK: Load more commits

    private func loadMoreCommitsIfPossible() async {
        guard let workspaceId = context.workspaceId, let api = apiClient, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let currentCount = allCommits.count
        do {
            let response = try await api.getCommitLog(workspaceId: workspaceId, offset: currentCount)
            additionalCommits.append(contentsOf: response.commits)
            hasMoreCommits = response.hasMore
        } catch {
            // Silently fail — not critical
        }
    }
}

extension WorkspaceContextBarView: UIGestureRecognizerDelegate {
    /// While selecting, a drag over the file list selects (Mail-style) instead
    /// of scrolling the panel.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === dragSelectGesture && other === scrollView.panGestureRecognizer
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
