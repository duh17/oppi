import UIKit

struct CommitDetailActionMenuState: Equatable {
    let menuDisabled: Bool
    let promptTemplatesDisabled: Bool

    static func make(
        detail: GitCommitDetail?,
        launchActionInFlightTitle: String?
    ) -> Self {
        Self(
            menuDisabled: launchActionInFlightTitle != nil,
            promptTemplatesDisabled: launchActionInFlightTitle != nil || (detail?.files.isEmpty ?? true)
        )
    }
}

/// A commit: its message, author, and line counts, and a tappable list of the
/// files it changed. A file opens its diff beside the list in regular width
/// (an attached leaf) and in a sheet in compact width; a width change moves
/// the open diff between the two. Hosted in an attached leaf's own panel
/// navigation (`hostedInPanel`, the Git panel's commit row), a file instead
/// pushes its diff there, with a back button to this screen, since the
/// leaf's width is already spoken for and its own trait reads compact.
/// New Session and the prompt templates in the overflow menu start a session
/// about the commit and push its chat onto this screen's stack, or, hosted in
/// a panel, hand it to `pushChat`, which closes the leaf and pushes the
/// chat beside it instead of squeezing a whole chat into the leaf.
@MainActor
final class CommitDetailViewController: UIViewController {
    struct Configuration {
        let workspaceId: String
        /// The commit's SHA, and its subject when the opener has it (the
        /// timeline's pill carries only the SHA).
        let sha: String
        var message = ""
        var reviewCommentSelectionScope: ReviewCommentSelectionScope?
        /// The close control's identifier, for a commit that is the root of a
        /// modal or of a side pane.
        var closeAccessibilityIdentifier: String?
    }

    let configuration: Configuration
    /// The close control, for a commit at the root of a modal (a chevron) or
    /// of a side pane (an X). Nil for a commit pushed in the Git panel: that
    /// navigation draws the back button.
    var onClose: (() -> Void)? {
        didSet { setNeedsUpdateProperties() }
    }
    /// This screen is in an attached leaf's panel navigation, pushed above
    /// the Git panel's commit row or as the pane's root (a timeline commit
    /// link at regular width): a selected file pushes its diff there too,
    /// instead of this screen's own leaf or sheet.
    private let hostedInPanel: Bool
    /// Where a started session's chat goes; nil pushes it onto this screen's
    /// own stack.
    private let pushChat: ((ChatViewController) -> Void)?

    private let connection: ServerConnection
    private let apiClient: APIClient?
    private let appNavigation: SceneNavigation

    private var detail: GitCommitDetail? {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    /// The file whose diff is open.
    private var selectedFile: GitCommitFileInfo? {
        didSet { setNeedsUpdateProperties() }
    }
    private var launchActionInFlightTitle: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var quickActionOptions: [WorkspaceQuickActionOption] = []
    private var isLoadingQuickActions = false
    private var detailTask: Task<Void, Never>?
    private var quickActionTask: Task<Void, Never>?

    private let pageView = UIView()
    private var mountedPhase: MountedPhase?
    private var loadedContent: CommitDetailContentView?
    private let progressPanel = FloatingProgressPanel(borderWidth: 1)
    private lazy var diffLeaf = AttachedLeafController(screen: self)
    private let diffSheet = RouterModalPresenter()

    private enum MountedPhase: Equatable {
        case loading
        case unavailable(String)
        case loaded(GitCommitDetail)
    }

    private lazy var closeItem: UIBarButtonItem = {
        let action = UIAction { [weak self] _ in self?.onClose?() }
        if hostedInPanel {
            // A pane closes with the X every other pane uses; the chevron is
            // the sheet's dismiss.
            let item = UIBarButtonItem(systemItem: .close, primaryAction: action)
            item.accessibilityIdentifier = configuration.closeAccessibilityIdentifier
            return item
        }
        let mode = FullScreenViewerNavigationChrome.DismissMode.modal
        let item = UIBarButtonItem(
            title: mode.accessibilityLabel,
            image: UIImage(systemName: mode.systemImageName),
            primaryAction: action
        )
        item.accessibilityLabel = mode.accessibilityLabel
        item.accessibilityIdentifier = configuration.closeAccessibilityIdentifier
        return item
    }()

    /// New Session and the prompt templates in the system overflow (vertical
    /// rail aware), built each time it opens.
    private lazy var actionMenu = UIDeferredMenuElement.uncached { [weak self] completion in
        completion(self?.actionMenuElements() ?? [])
    }

    init(
        configuration: Configuration,
        connection: ServerConnection,
        apiClient: APIClient?,
        navigation: SceneNavigation,
        hostedInPanel: Bool = false,
        pushChat: ((ChatViewController) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.connection = connection
        self.apiClient = apiClient
        self.appNavigation = navigation
        self.hostedInPanel = hostedInPanel
        self.pushChat = pushChat
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Commit")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.additionalOverflowItems = actionMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var actionMenuState: CommitDetailActionMenuState {
        CommitDetailActionMenuState.make(
            detail: detail,
            launchActionInFlightTitle: launchActionInFlightTitle
        )
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        pageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageView)
        progressPanel.isHidden = true
        progressPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressPanel)
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: view.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressPanel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            progressPanel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            progressPanel.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32),
        ])
        addChild(diffLeaf)
        view.addSubview(diffLeaf.view)
        diffLeaf.view.frame = .zero
        diffLeaf.didMove(toParent: self)
        diffSheet.anchor = self
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Each appearance loads again, as the hosted screen's `.task`s did.
        detailTask?.cancel()
        detailTask = Task { [weak self] in await self?.loadDetail() }
        quickActionTask?.cancel()
        quickActionTask = Task { [weak self] in await self?.loadQuickActionsIfNeeded() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        diffSheet.sync()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        detailTask?.cancel()
        detailTask = nil
        quickActionTask?.cancel()
        quickActionTask = nil
    }

    override func updateProperties() {
        super.updateProperties()
        let root = AppRootEnvironment.near(self)
        let themeID = root?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        view.backgroundColor = palette.ui.bgDark
        reconcileContent()
        loadedContent?.apply(themeID: themeID)
        progressPanel.apply(palette)
        progressPanel.text = launchActionInFlightTitle
        progressPanel.isHidden = launchActionInFlightTitle == nil
        view.bringSubviewToFront(progressPanel)
        // Hosted SwiftUI bars tint their items with the root's `.themeBlue`.
        closeItem.tintColor = palette.ui.blue
        let leading = onClose == nil ? nil : closeItem
        if navigationItem.leftBarButtonItem !== leading {
            navigationItem.leftBarButtonItem = leading
        }
        if !hostedInPanel, let root {
            updateDiffPanel(root: root)
        }
    }

    // MARK: Content

    private func reconcileContent() {
        let phase: MountedPhase = if let detail {
            .loaded(detail)
        } else if let error {
            .unavailable(error)
        } else {
            .loading
        }
        guard phase != mountedPhase else { return }
        mountedPhase = phase
        pageView.subviews.forEach { $0.removeFromSuperview() }
        loadedContent = nil
        switch phase {
        case .loading:
            ReviewPagePlaceholder.showLoading(String(localized: "Loading commit…"), on: pageView)
        case .unavailable(let message):
            embed(ReviewPagePlaceholder.unavailable(title: String(localized: "Unable to load commit"), message: message))
        case .loaded(let detail):
            let content = CommitDetailContentView(detail: detail) { [weak self] file in
                self?.selectFile(file)
            }
            embed(content)
            loadedContent = content
        }
    }

    /// Hosted in a panel, or wide with no pane host to open beside (a
    /// regular-width modal), the diff joins this screen's own navigation
    /// stack (a back button returns here) rather than a sheet over a sheet;
    /// otherwise `updateDiffPanel` follows `selectedFile` into the attached
    /// leaf or the sheet.
    private func selectFile(_ file: GitCommitFileInfo) {
        if pushesDiff {
            Router.push(diffController(file, pushed: true)(), from: self)
        } else {
            selectedFile = file
        }
    }

    private func embed(_ content: UIView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        pageView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: pageView.topAnchor),
            content.bottomAnchor.constraint(equalTo: pageView.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
        ])
    }

    // MARK: Diff panel

    /// The open diff follows the selection: the attached leaf in regular
    /// width, a sheet in compact. A width change moves it between the two;
    /// the open file survives. Swipe-down clears it like the close button.
    private func updateDiffPanel(root: AppRootEnvironment) {
        let file = selectedFile
        let inColumn = diffLeaf.opensBeside
        diffLeaf.onDismissRequested = { [weak self] in self?.selectedFile = nil }
        diffLeaf.show(
            inColumn ? file.map { file in
                AttachedLeafController.Panel(
                    id: AnyHashable(file.id),
                    pairing: PanePairing(.reader, beside: .commit),
                    makeScreen: diffController(file)
                )
            } : nil,
            root: root
        )
        diffSheet.update(
            id: inColumn ? nil : file.map { AnyHashable($0.id) },
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.selectedFile = nil },
            screen: {
                guard let file else { preconditionFailure("The diff sheet presents only with a selected file") }
                return .controller(diffController(file))
            }
        )
    }

    /// The diff of `file` in this commit, with this viewer's server and
    /// review scope.
    private var pushesDiff: Bool {
        hostedInPanel
            || (!diffLeaf.opensBeside && AdaptiveWidth.isWide(traitCollection) && navigationController != nil)
    }

    private func diffController(_ file: GitCommitFileInfo, pushed: Bool = false) -> () -> UIViewController {
        let configuration = CommitFileDiffViewController.Configuration(
            workspaceId: configuration.workspaceId,
            sha: self.configuration.sha,
            file: file,
            reviewCommentSelectionScope: self.configuration.reviewCommentSelectionScope
        )
        let apiClient = apiClient
        let audioPlayer = connection.audioPlayer
        return { [weak self] in
            let diff = CommitFileDiffViewController(
                configuration: configuration,
                apiClient: apiClient,
                audioPlayer: audioPlayer,
                hostedInPanel: pushed
            )
            // Pushed, the navigation controller's own back button leads back
            // to the commit; a leaf or sheet root needs this screen's own
            // close control instead.
            if !pushed {
                diff.onClose = { self?.selectedFile = nil }
            }
            return diff
        }
    }

    // MARK: Actions

    private func actionMenuElements() -> [UIMenuElement] {
        let state = actionMenuState
        return WorkspaceQuickActionMenu.elements(
            options: quickActionOptions,
            isLoading: isLoadingQuickActions,
            newSessionDisabled: state.menuDisabled,
            templatesDisabled: state.menuDisabled || state.promptTemplatesDisabled,
            onNewSession: { [weak self] in await self?.startEmptySession() },
            onTemplate: { [weak self] option in await self?.createQuickActionSession(option: option) }
        )
    }

    /// Pushes the new session's chat with this viewer's server and navigation.
    /// The commit viewer opened from a chat keeps an `SceneNavigation` of its own
    /// (`ChatTimelineDestinationPresenter`), so its chat leaves the app's alone.
    func openQuickActionSession(_ destination: QuickActionSessionNavDestination) {
        quickActionLauncher.showChat(destination)
    }

    private var quickActionLauncher: WorkspaceQuickActionLauncher {
        WorkspaceQuickActionLauncher(
            connection: connection,
            apiClient: apiClient,
            navigation: appNavigation,
            workspaceId: configuration.workspaceId,
            presenter: self,
            isLaunching: { [weak self] in self?.launchActionInFlightTitle != nil },
            setProgress: { [weak self] in self?.launchActionInFlightTitle = $0 },
            push: pushChat
        )
    }

    private func startEmptySession() async {
        let configuration = configuration
        await quickActionLauncher.startEmptySession { [weak self] session in
            let detail = self?.detail
            return .attachingCommit(
                sessionId: session.id,
                sha: detail?.sha ?? configuration.sha,
                message: detail?.message ?? configuration.message
            )
        }
    }

    private func createQuickActionSession(option: WorkspaceQuickActionOption) async {
        guard let detail else { return }
        let paths = detail.files.map(\.path)
        guard !paths.isEmpty else {
            WorkspaceQuickActionMenu.presentLaunchError("Commit has no changed files.", from: self)
            return
        }
        await quickActionLauncher.createSession(option: option, paths: paths, commitSha: detail.sha)
    }

    // MARK: Loading

    private func loadDetail() async {
        guard let api = apiClient else {
            error = "Server is offline."
            return
        }
        do {
            let loaded = try await api.getCommitDetail(workspaceId: configuration.workspaceId, sha: configuration.sha)
            guard !Task.isCancelled else { return }
            detail = loaded
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadQuickActionsIfNeeded() async {
        guard !isLoadingQuickActions, let api = apiClient else { return }
        isLoadingQuickActions = true
        defer { isLoadingQuickActions = false }
        do {
            quickActionOptions = try await api.getWorkspaceQuickActions(workspaceId: configuration.workspaceId).actions
        } catch {
            quickActionOptions = []
        }
    }
}

/// A loaded commit: header, "N files changed", then one row per file.
@MainActor
private final class CommitDetailContentView: UIScrollView {
    private let detail: GitCommitDetail
    private let shaLabel = UILabel()
    private let messageLabel = UILabel()
    private let authorLabel = UILabel()
    private let dateLabel = UILabel()
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private let filesHeaderLabel = UILabel()
    private let dividers = [UIView(), UIView()]
    private let fileList = UIStackView()
    private let onSelect: (GitCommitFileInfo) -> Void
    private var appliedThemeID: ThemeID?

    init(detail: GitCommitDetail, onSelect: @escaping (GitCommitFileInfo) -> Void) {
        self.detail = detail
        self.onSelect = onSelect
        super.init(frame: .zero)
        alwaysBounceVertical = true

        shaLabel.text = detail.sha
        shaLabel.font = UIFont.scaledMonospaced(.caption1, .semibold)
        messageLabel.text = detail.message
        messageLabel.font = UIFont.scaled(.subheadline, .medium)
        messageLabel.numberOfLines = 0
        authorLabel.text = detail.author
        authorLabel.font = .preferredFont(forTextStyle: .caption2)
        authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dateLabel.text = Self.relativeDate(from: detail.date)
        dateLabel.font = UIFont.scaledMonospaced(.caption2, .regular)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addedLabel.text = "+\(detail.addedLines)"
        addedLabel.isHidden = detail.addedLines <= 0
        removedLabel.text = "-\(detail.removedLines)"
        removedLabel.isHidden = detail.removedLines <= 0
        for label in [addedLabel, removedLabel] {
            label.font = UIFont.scaledMonospaced(.caption2, .bold)
        }
        filesHeaderLabel.font = UIFont.scaledMonospaced(.caption2, .semibold)
        for label in [shaLabel, messageLabel, authorLabel, dateLabel, addedLabel, removedLabel, filesHeaderLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        let authorSpacer = UIView()
        authorSpacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        authorLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let authorRow = UIStackView(arrangedSubviews: [authorLabel, authorSpacer, dateLabel])
        authorRow.axis = .horizontal
        authorRow.alignment = .firstBaseline
        authorRow.spacing = 8
        let statsSpacer = UIView()
        statsSpacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        for label in [addedLabel, removedLabel] {
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        let statsRow = UIStackView(arrangedSubviews: [addedLabel, removedLabel, statsSpacer])
        statsRow.axis = .horizontal
        statsRow.spacing = 8
        let header = UIStackView(arrangedSubviews: [shaLabel, messageLabel, authorRow, statsRow])
        header.axis = .vertical
        header.spacing = 8
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)

        let filesHeader = UIStackView(arrangedSubviews: [filesHeaderLabel])
        filesHeader.isLayoutMarginsRelativeArrangement = true
        filesHeader.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)

        fileList.axis = .vertical
        fileList.spacing = 1
        fileList.isLayoutMarginsRelativeArrangement = true
        fileList.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)

        for divider in dividers {
            divider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 2)).isActive = true
        }
        let content = UIStackView(arrangedSubviews: [header, dividers[0], filesHeader, dividers[1], fileList])
        content.axis = .vertical
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(themeID: ThemeID) {
        guard themeID != appliedThemeID else { return }
        appliedThemeID = themeID
        let palette = themeID.palette
        shaLabel.textColor = palette.ui.comment
        messageLabel.textColor = palette.ui.fg
        authorLabel.textColor = palette.ui.fgDim
        dateLabel.textColor = palette.ui.comment
        addedLabel.textColor = palette.ui.diffAdded
        removedLabel.textColor = palette.ui.diffRemoved
        let count = detail.files.count
        filesHeaderLabel.attributedText = NSAttributedString(
            string: "\(count) file\(count == 1 ? "" : "s") changed",
            attributes: [.kern: 0.4, .foregroundColor: palette.ui.comment]
        )
        dividers[0].backgroundColor = palette.ui.comment.withAlphaComponent(0.2)
        dividers[1].backgroundColor = palette.ui.comment.withAlphaComponent(0.15)
        // The rows draw in the palette they are built with.
        fileList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for file in detail.files {
            fileList.addArrangedSubview(fileRow(file, palette: palette))
        }
    }

    /// One changed file: icon, path, line counts, status badge, chevron.
    private func fileRow(_ file: GitCommitFileInfo, palette: ThemePalette) -> UIView {
        let statusColor = Self.statusColor(file.status, palette: palette)
        let status = UILabel()
        status.text = file.status
        status.font = UIFont.scaled(.caption2, .medium)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = statusColor
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        let badge = UIView()
        badge.backgroundColor = statusColor.withAlphaComponent(0.12)
        badge.layer.cornerRadius = 3
        status.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(status)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1),
            status.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -1),
            status.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 4),
            status.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -4),
        ])
        let row = ChangedFileRow.content(
            path: file.path,
            added: file.addedLines,
            removed: file.removedLines,
            afterCounts: [badge],
            showsChevron: true,
            fonts: .init(
                path: UIFont.scaledMonospaced(.caption2, .regular),
                count: UIFont.scaledMonospaced(.caption2, .bold),
                chevron: .systemFont(ofSize: 8, weight: .semibold)
            ),
            verticalInset: 4,
            palette: palette
        )
        let button = PlainRowButton(wrapping: row.stack) { [onSelect] in onSelect(file) }
        button.accessibilityIdentifier = "commit-detail.file"
        button.accessibilityLabel = (row.labelParts + [file.status]).joined(separator: ", ")
        return button
    }

    private static func statusColor(_ status: String, palette: ThemePalette) -> UIColor {
        switch status {
        case "M": palette.ui.orange
        case "A": palette.ui.diffAdded
        case "D": palette.ui.diffRemoved
        case "R", "C": palette.ui.cyan
        default: palette.ui.comment
        }
    }

    private static func relativeDate(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return date.relativeOrShortDateString()
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: isoString) else { return isoString }
        return date.relativeOrShortDateString()
    }
}

/// The diff of one file in a commit, under the shared file header.
@MainActor
final class CommitFileDiffViewController: UIViewController {
    struct Configuration {
        let workspaceId: String
        let sha: String
        let file: GitCommitFileInfo
        var reviewCommentSelectionScope: ReviewCommentSelectionScope?
    }

    let configuration: Configuration
    /// The sheet or leaf root's close control. Nil while `hostedInPanel`:
    /// the panel's navigation draws the back button instead.
    var onClose: (() -> Void)?
    /// Pushed in an attached leaf's panel navigation (the Git panel's
    /// commit, at regular width): draws no close control of its own, since
    /// that navigation's native back button leads back to the commit.
    private let hostedInPanel: Bool

    private let apiClient: APIClient?
    private let audioPlayer: AudioPlayerService?
    private var diff: WorkspaceReviewDiffResponse? {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var loadTask: Task<Void, Never>?
    private let summary = ReviewFileSummaryBarView()
    private let divider = UIView()
    private let bodyView = UIView()
    private var mountedPhase: WorkspaceReviewFileDetailPhase?
    private var diffReader: DiffReaderView?
    /// The file's own viewer, mounted instead of the diff reader for a file with no text diff.
    private var previewChild: NonTextDiffPreviewViewController?
    private let stashButton = ReviewCommentStashFloatingButton()

    init(
        configuration: Configuration,
        apiClient: APIClient?,
        audioPlayer: AudioPlayerService? = nil,
        hostedInPanel: Bool = false
    ) {
        self.configuration = configuration
        self.apiClient = apiClient
        self.audioPlayer = audioPlayer
        self.hostedInPanel = hostedInPanel
        super.init(nibName: nil, bundle: nil)
        title = configuration.file.path.lastPathComponentForDisplay
        navigationItem.largeTitleDisplayMode = .never
        guard !hostedInPanel else { return }
        let mode = FullScreenViewerNavigationChrome.DismissMode.modal
        let close = UIBarButtonItem(
            title: mode.accessibilityLabel,
            image: UIImage(systemName: mode.systemImageName),
            primaryAction: UIAction { [weak self] _ in self?.onClose?() }
        )
        close.accessibilityLabel = mode.accessibilityLabel
        close.accessibilityIdentifier = "commit-detail.diff.close"
        navigationItem.leftBarButtonItem = close
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        divider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
        let stack = UIStackView(arrangedSubviews: [summary, divider, bodyView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: safe.topAnchor),
            stack.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadDiff() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        view.backgroundColor = palette.ui.bgDark
        let file = configuration.file
        summary.apply(
            ReviewFileSummaryBarView.Values(
                path: file.path,
                status: file.status,
                addedLines: file.addedLines,
                removedLines: file.removedLines
            ),
            themeID: themeID
        )
        divider.backgroundColor = palette.ui.comment.withAlphaComponent(0.2)
        navigationItem.leftBarButtonItem?.tintColor = palette.ui.blue
        reconcileBody()
        // The diff's Viewing Options is this screen's one bar item.
        let trailing = diffReader.flatMap { $0.offersViewingOptions ? [$0.viewingOptionsItem] : nil } ?? []
        if !(navigationItem.rightBarButtonItems ?? []).elementsEqual(trailing, by: ===) {
            navigationItem.rightBarButtonItems = trailing
        }
        stashButton.update(
            on: view,
            presenter: self,
            stash: configuration.reviewCommentSelectionScope?.router.stash,
            leadingAccessoryCount: 0,
            palette: palette
        )
    }

    private func reconcileBody() {
        let phase = WorkspaceReviewFileDetailPhase.resolve(diff: diff, error: error)
        guard phase != mountedPhase else { return }
        mountedPhase = phase
        bodyView.subviews.forEach { $0.removeFromSuperview() }
        diffReader = nil
        if let previewChild {
            previewChild.willMove(toParent: nil)
            previewChild.removeFromParent()
            self.previewChild = nil
        }
        let content: UIView
        switch phase {
        case .loading:
            ReviewPagePlaceholder.showLoading(String(localized: "Loading diff…"), on: bodyView)
            return
        case .unavailable(let message):
            content = ReviewPagePlaceholder.unavailable(title: String(localized: "Diff Unavailable"), message: message)
        case .loaded(let diff) where diff.nonText != nil:
            let preview = makeNonTextPreview(diff)
            addChild(preview)
            previewChild = preview
            content = preview.view
        case .loaded(let diff):
            let reader = DiffReaderView()
            let selection = configuration.reviewCommentSelectionScope?.makeContext()
            reader.reviewCommentSelectionContext = selection
            reader.sourceContext = selection?.sourceContext(surface: .fullScreenDiff, filePath: configuration.file.path)
            reader.installBackSwipe(action: nil)
            reader.setDiff(
                hunks: diff.hunks,
                filePath: configuration.file.path,
                emptyDescription: "This file has no textual diff to show."
            )
            diffReader = reader
            content = reader
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        bodyView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: bodyView.topAnchor),
            content.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor),
        ])
        previewChild?.didMove(toParent: self)
    }

    /// The file at the commit and at its parent, from the blob each holds.
    private func makeNonTextPreview(_ diff: WorkspaceReviewDiffResponse) -> NonTextDiffPreviewViewController {
        let sha = configuration.sha
        return NonTextDiffPreviewViewController(
            configuration: .init(
                workspaceId: configuration.workspaceId,
                path: configuration.file.path,
                sides: diff.nonText.map {
                    NonTextDiffSides.resolve($0, beforeRevision: "\(sha)^", afterRevision: sha)
                } ?? [],
                reviewCommentSelectionScope: configuration.reviewCommentSelectionScope
            ),
            services: .init(apiClient: apiClient, audioPlayer: audioPlayer)
        )
    }

    private func loadDiff() async {
        guard let api = apiClient else {
            error = "Server is offline."
            return
        }
        do {
            let loaded = try await api.getCommitFileDiff(
                workspaceId: configuration.workspaceId,
                sha: configuration.sha,
                path: configuration.file.path
            )
            guard !Task.isCancelled else { return }
            diff = loaded
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
