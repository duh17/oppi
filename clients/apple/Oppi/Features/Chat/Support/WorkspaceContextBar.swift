import TipKit
import UIKit

// MARK: - Scoping logic (testable)

/// Pure-function extraction of the context bar's session-scoping rules.
/// When `sessionId` is set, all display properties scope exclusively to
/// that session's changed files — workspace-level data never leaks through.
enum ContextBarScoping {

    static func hasContent(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?,
        showCleanWorkspace: Bool = false
    ) -> Bool {
        guard let gitStatus, gitStatus.isGitRepo else { return false }
        if sessionId != nil { return sessionScope != nil }
        if showCleanWorkspace { return true }
        return !gitStatus.isClean
    }

    static func displayFileCount(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?
    ) -> Int {
        if sessionId != nil { return sessionScope?.sessionFileCount ?? 0 }
        return gitStatus?.uncommittedCount ?? 0
    }

    static func displayAddedLines(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?
    ) -> Int {
        if sessionId != nil { return sessionScope?.sessionAddedLines ?? 0 }
        return gitStatus?.addedLines ?? 0
    }

    static func displayRemovedLines(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?
    ) -> Int {
        if sessionId != nil { return sessionScope?.sessionRemovedLines ?? 0 }
        return gitStatus?.removedLines ?? 0
    }

    static func displayFiles(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?
    ) -> [GitFileStatus] {
        if sessionId != nil { return sessionScope?.sessionFiles ?? [] }
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

enum ContextBarCrossSessionEdits {
    static func sharedFilePaths(
        displayFiles: [GitFileStatus],
        currentSessionId: String?,
        workspaceId: String?,
        sessions: [Session]
    ) -> Set<String> {
        guard let currentSessionId, !displayFiles.isEmpty else { return [] }
        var originalPathByNormalizedPath: [String: String] = [:]
        originalPathByNormalizedPath.reserveCapacity(displayFiles.count)
        for file in displayFiles {
            originalPathByNormalizedPath[normalizedPath(file.path)] = file.path
        }

        let displayedPathSet = Set(originalPathByNormalizedPath.keys)
        guard !displayedPathSet.isEmpty else { return [] }

        var remainingPaths = displayedPathSet
        var sharedPaths: Set<String> = []

        for session in sessions where session.id != currentSessionId {
            if let workspaceId, let sessionWorkspaceId = session.workspaceId, sessionWorkspaceId != workspaceId {
                continue
            }
            guard let changedFiles = session.changeStats?.changedFiles, !changedFiles.isEmpty else { continue }

            for changedFile in changedFiles {
                let matches = matchingDisplayedPaths(for: changedFile, remainingDisplayedPaths: remainingPaths)
                guard !matches.isEmpty else { continue }

                for path in matches {
                    sharedPaths.insert(originalPathByNormalizedPath[path] ?? path)
                    remainingPaths.remove(path)
                }

                if remainingPaths.isEmpty {
                    return sharedPaths
                }
            }
        }

        return sharedPaths
    }

    private static func normalizedPath(_ path: String) -> String {
        path.replacing("\\", with: "/")
    }

    private static func matchingDisplayedPaths(
        for sessionPath: String,
        remainingDisplayedPaths: Set<String>
    ) -> [String] {
        guard !remainingDisplayedPaths.isEmpty else { return [] }

        let normalizedSessionPath = normalizedPath(sessionPath)
        let components = normalizedSessionPath.split(separator: "/", omittingEmptySubsequences: true)
        var matches: [String] = []

        func appendIfDisplayed(_ candidate: String) {
            guard remainingDisplayedPaths.contains(candidate), !matches.contains(candidate) else { return }
            matches.append(candidate)
        }

        appendIfDisplayed(normalizedSessionPath)

        guard components.count > 1 else { return matches }
        for index in components.indices {
            appendIfDisplayed(components[index...].joined(separator: "/"))
        }

        return matches
    }
}

// MARK: - Bar

/// Expandable bar showing workspace git status, over the top of the chat's
/// timeline and of a workspace's sessions.
///
/// Collapsed shows branch + dirty count + repo-wide +/-. Expanded shows a
/// tappable file list with file-type icons, per-file line stats, recent
/// commits, and select-for-review controls. A file opens its review and a
/// commit its detail, each in a sheet presented from `presenter`. The sheet
/// belongs to the presenter, not to this bar, so a transient loss of Git
/// content (the bar empties) leaves an open review alone.
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
        /// timeline, the scrim, or the composer).
        var collapseToken = 0
    }

    /// What stays fixed for the bar's life.
    struct Options {
        var appliesOuterHorizontalPadding = true
        /// A workspace with no changes still shows its branch and commits.
        var showCleanWorkspace = false
        var initiallyExpanded = false
        var onReviewInCurrentSession: ((String, [PendingFileReference]) -> Void)?
        var fileDetailReviewCommentScope: ReviewCommentSelectionScope?
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

    // Derived on each render.
    private var displayFiles: [GitFileStatus] = []
    private var sessionScope: SessionScopedGitStatus?

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
        isExpanded = options.initiallyExpanded
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
        ContextBarScoping.hasContent(
            gitStatus: context.gitStatus,
            sessionId: context.sessionId,
            sessionScope: sessionScope,
            showCleanWorkspace: options.showCleanWorkspace
        )
    }

    /// All commits: recent from git status + any additionally loaded ones.
    private var allCommits: [GitCommitSummary] {
        (context.gitStatus?.recentCommits ?? []) + additionalCommits
    }

    private var canLaunch: Bool {
        !selectedPaths.isEmpty && launchActionInFlightTitle == nil
    }

    /// Regular width (iPad, the iPhone Duo inner display) gets the larger git
    /// bar type. This chrome sits above the timeline, so a fold steps it one
    /// text style with the rest of the regular layout; reading text in the
    /// timeline keeps its size.
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
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        cardStack.axis = .vertical
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(cardStack)

        let leading = card.leadingAnchor.constraint(equalTo: leadingAnchor)
        let trailing = card.trailingAnchor.constraint(equalTo: trailingAnchor)
        let top = card.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        let bottom = card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
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
        cardStack.addArrangedSubview(tipHost)

        expandedStack.axis = .vertical
        scrollView.alwaysBounceVertical = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        panelStack.axis = .vertical
        panelStack.alignment = .fill
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(panelStack)
        let hug = scrollView.frameLayoutGuide.heightAnchor.constraint(equalTo: panelStack.heightAnchor)
        hug.priority = .defaultHigh
        // The panel hugs its rows up to 480 pt, then scrolls.
        let maxHeight = scrollView.frameLayoutGuide.heightAnchor.constraint(lessThanOrEqualToConstant: 480)
        NSLayoutConstraint.activate([
            panelStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            panelStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            panelStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            panelStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            hug,
            maxHeight,
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
        let sessions = connection.sessionStore.sessions

        sessionScope = Self.sessionScope(gitStatus: context.gitStatus, sessionId: context.sessionId, sessions: sessions)
        displayFiles = ContextBarScoping.displayFiles(
            gitStatus: context.gitStatus,
            sessionId: context.sessionId,
            sessionScope: sessionScope
        )
        let showsContent = !(context.isLoading && context.gitStatus == nil) && hasContent
        card.isHidden = !showsContent
        emptyHeight?.isActive = !showsContent
        let padding: CGFloat = options.appliesOuterHorizontalPadding ? 16 : 0
        cardLeading?.constant = padding
        cardTrailing?.constant = -padding
        updateTip(showsContent: showsContent)
        guard showsContent else { return }

        renderCollapsedRow(palette: palette)
        expandedStack.isHidden = !isExpanded
        guard isExpanded else { return }
        let sharedPaths = ContextBarCrossSessionEdits.sharedFilePaths(
            displayFiles: displayFiles,
            currentSessionId: context.sessionId,
            workspaceId: context.workspaceId,
            sessions: sessions
        )
        renderPanel(sharedPaths: sharedPaths, themeID: themeID)
        selectionBar.isHidden = !isSelecting
        if isSelecting {
            renderSelectionBar(themeID: themeID)
        }
    }

    private static func sessionScope(gitStatus: GitStatus?, sessionId: String?, sessions: [Session]) -> SessionScopedGitStatus? {
        guard let gitStatus, let sessionId else { return nil }
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return nil }
        guard let changedFiles = session.changeStats?.changedFiles, !changedFiles.isEmpty else { return nil }
        return SessionScopedGitStatus.filter(gitStatus: gitStatus, sessionChangedFiles: changedFiles)
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
        if showsContent, window != nil {
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
            sessionId: context.sessionId,
            sessionScope: sessionScope
        )
        let added = ContextBarScoping.displayAddedLines(gitStatus: gitStatus, sessionId: context.sessionId, sessionScope: sessionScope)
        let removed = ContextBarScoping.displayRemovedLines(gitStatus: gitStatus, sessionId: context.sessionId, sessionScope: sessionScope)

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
        let sharedPaths: Set<String>
        let isSelecting: Bool
        let commits: [GitCommitSummary]
        let hasMoreCommits: Bool
        let isLoadingMore: Bool
        let gitStatus: GitStatus?
        let sessionId: String?
        let canTap: Bool
        let regular: Bool
        let themeID: ThemeID
    }

    private func renderPanel(sharedPaths: Set<String>, themeID: ThemeID) {
        let key = PanelKey(
            files: displayFiles,
            sharedPaths: sharedPaths,
            isSelecting: isSelecting,
            commits: allCommits,
            hasMoreCommits: hasMoreCommits,
            isLoadingMore: isLoadingMore,
            gitStatus: context.gitStatus,
            sessionId: context.sessionId,
            canTap: context.workspaceId != nil,
            regular: usesRegularTypography,
            themeID: themeID
        )
        let palette = themeID.palette
        defer { applySelection(palette: palette) }
        guard key != panelKey else { return }
        panelKey = key
        panelStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fileRows = []
        fileList = nil
        selectAllButton = nil
        selectedCountLabel = nil

        let comment = UIColor(palette.comment)
        panelStack.addArrangedSubview(divider(comment.withAlphaComponent(0.2)))

        if isSelecting {
            panelStack.addArrangedSubview(selectionHeader(palette: palette))
            panelStack.addArrangedSubview(divider(comment.withAlphaComponent(0.15)))
        }

        if !displayFiles.isEmpty {
            panelStack.addArrangedSubview(fileListView(sharedPaths: sharedPaths, palette: palette))
        }

        if !allCommits.isEmpty {
            panelStack.addArrangedSubview(divider(comment.withAlphaComponent(0.15)))
            panelStack.addArrangedSubview(commitList(palette: palette))
        } else if let gitStatus = context.gitStatus, gitStatus.isGitRepo {
            panelStack.addArrangedSubview(divider(comment.withAlphaComponent(0.15)))
            panelStack.addArrangedSubview(headCommitRow(gitStatus, palette: palette))
        }
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

    private func fileListView(sharedPaths: Set<String>, palette: ThemePalette) -> UIView {
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 1
        list.isLayoutMarginsRelativeArrangement = true
        list.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)

        if !sharedPaths.isEmpty {
            let orange = UIColor(palette.orange)
            let icon = UIImageView(image: UIImage(systemName: "rectangle.on.rectangle"))
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font(.caption2, .caption1, .semibold))
            icon.tintColor = orange
            let count = sharedPaths.count
            let text = Self.label(
                "\(count) file\(count == 1 ? "" : "s") touched in another session",
                font: font(.caption2, .caption1, .medium),
                color: orange
            )
            let hint = Self.row(
                [icon, text, Self.spacer()],
                spacing: 5,
                insets: NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 3, trailing: 12)
            )
            hint.isAccessibilityElement = true
            hint.accessibilityLabel = text.text
            hint.accessibilityIdentifier = "context-bar-overlap-hint"
            list.addArrangedSubview(hint)
        }

        for file in displayFiles {
            let row = fileRow(file, isSharedEdit: sharedPaths.contains(file.path), palette: palette)
            list.addArrangedSubview(row.view)
            fileRows.append((file.path, row.view, row.mark))
        }

        if context.sessionId == nil, let gitStatus = context.gitStatus, gitStatus.totalFiles > gitStatus.files.count {
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
        isSharedEdit: Bool,
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
        var badges: [UIView] = []
        if isSharedEdit {
            let orange = UIColor(palette.orange)
            let badgeIcon = UIImageView(image: UIImage(systemName: "rectangle.on.rectangle"))
            badgeIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                font: font(fixed: 8, .semibold, regular: .caption2, .semibold)
            )
            badgeIcon.tintColor = orange
            let badge = CapsuleView()
            Self.pad(badgeIcon, in: badge, NSDirectionalEdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 5))
            badge.backgroundColor = orange.withAlphaComponent(0.12)
            badge.isAccessibilityElement = false
            badges.append(badge)
        }
        let content = ChangedFileRow.content(
            path: file.path,
            added: file.addedLines,
            removed: file.removedLines,
            leading: mark.map { [$0] } ?? [],
            beforeCounts: badges,
            showsChevron: !isSelecting && canTap,
            fonts: .init(
                path: font(.caption2, .caption1, mono: true),
                count: font(.caption2, .caption1, .bold, mono: true),
                chevron: font(fixed: 8, .semibold, regular: .caption2, .semibold)
            ),
            verticalInset: usesRegularTypography ? 5 : 4,
            palette: palette
        )
        var labelParts = content.labelParts
        if isSharedEdit {
            labelParts.insert(String(localized: "Touched in another session"), at: 1)
        }
        let row = PlainRowButton(wrapping: content.stack) { [weak self] in
            guard let self else { return }
            if isSelecting {
                toggleSelection(file.path)
            } else if canTap {
                presentFileReview(file)
            }
        }
        row.accessibilityLabel = labelParts.joined(separator: ", ")
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
    /// launch finished).
    private func collapseBar() {
        animateLayout {
            self.isExpanded = false
            self.isSelecting = false
            self.selectedPaths.removeAll()
            self.dragSelect.reset()
        }
    }

    /// Applies `changes` and animates the bar and its host to the new layout.
    private func animateLayout(duration: TimeInterval = 0.2, _ changes: @escaping () -> Void) {
        changes()
        guard window != nil else { return }
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

    /// Pushes the new session's chat above the screen that shows this bar,
    /// with this bar's server and navigation.
    private func openQuickActionSession(_ destination: QuickActionSessionNavDestination) {
        guard let presenter else { return }
        let chat = ChatViewController(
            sessionId: destination.id,
            connection: connection,
            navigation: navigation,
            apiClient: apiClient,
            workspaceIdHint: context.workspaceId,
            initialInputText: destination.inputText,
            initialPendingFiles: destination.pendingFileReferences
        )
        if let root = HostFactory.root(near: self), chat.traitOverrides.appRootEnvironment == nil {
            chat.traitOverrides.appRootEnvironment = root
        }
        Router.push(chat, from: presenter)
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
        guard let workspaceId = context.workspaceId else { return }
        guard let api = apiClient else {
            WorkspaceQuickActionMenu.presentLaunchError("Server is offline.", from: presenter)
            return
        }
        guard launchActionInFlightTitle == nil else { return }

        launchActionInFlightTitle = String(localized: "Starting new session…")
        defer { launchActionInFlightTitle = nil }

        do {
            let paths = selectedPathsInListOrder
            let response = try await api.createWorkspaceSession(
                workspaceId: workspaceId,
                worktreeId: context.worktreeId
            )
            connection.sessionStore.upsert(response.session)
            selectedPaths.removeAll()
            isSelecting = false
            openQuickActionSession(QuickActionSessionNavDestination.attaching(
                sessionId: response.session.id,
                filePaths: paths
            ))
        } catch {
            WorkspaceQuickActionMenu.presentLaunchError(error.localizedDescription, from: presenter)
        }
    }

    private func launchSelection(option: WorkspaceQuickActionOption) async {
        guard let workspaceId = context.workspaceId, !selectedPaths.isEmpty else { return }
        guard let api = apiClient else {
            WorkspaceQuickActionMenu.presentLaunchError("Server is offline.", from: presenter)
            return
        }
        guard launchActionInFlightTitle == nil else { return }

        // Preserve file order from the list
        let paths = selectedPathsInListOrder
        guard !paths.isEmpty else { return }

        launchActionInFlightTitle = option.progressTitle
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.createWorkspaceQuickActionSession(
                workspaceId: workspaceId,
                paths: paths,
                selectedSessionId: context.sessionId,
                worktreeId: context.worktreeId,
                promptTemplateName: option.promptTemplateName
            )
            connection.sessionStore.upsert(response.session)
            selectedPaths.removeAll()
            isSelecting = false
            openQuickActionSession(QuickActionSessionNavDestination(
                id: response.session.id,
                inputText: response.visiblePrompt,
                filePaths: response.filePaths,
                fileDisplayPrefix: option.title
            ))
        } catch {
            WorkspaceQuickActionMenu.presentLaunchError(error.localizedDescription, from: presenter)
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

/// A badge whose ends stay round at every height.
private final class CapsuleView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerCurve = .continuous
        layer.cornerRadius = bounds.height / 2
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
