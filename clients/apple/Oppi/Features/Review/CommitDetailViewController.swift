import UIKit

struct CommitDetailActionMenuState: Equatable {
    let menuDisabled: Bool
    let promptTemplatesDisabled: Bool

    static func make(
        workspaceId: String,
        detail: GitCommitDetail?,
        launchActionInFlightTitle: String?
    ) -> Self {
        Self(
            menuDisabled: launchActionInFlightTitle != nil || workspaceId.isEmpty,
            promptTemplatesDisabled: launchActionInFlightTitle != nil || (detail?.files.isEmpty ?? true)
        )
    }
}

/// A commit: its message, author, and line counts, and a tappable list of the
/// files it changed. A file opens its diff beside the list in regular width
/// (a trailing column) and in a sheet in compact width; a width change moves
/// the open diff between the two. New Session and the prompt templates in the
/// overflow menu start a session about the commit and push its chat onto
/// this screen's stack.
@MainActor
final class CommitDetailViewController: UIViewController {
    struct Configuration {
        let workspaceId: String
        let commit: GitCommitSummary
        var reviewCommentSelectionScope: ReviewCommentSelectionScope?
        /// The close control's identifier, for a commit that is a modal's root.
        var closeAccessibilityIdentifier: String?
        /// Unit tests open this chat as soon as the viewer appears.
        var testingQuickActionDestination: QuickActionSessionNavDestination?
    }

    let configuration: Configuration
    /// The modal's close control, for a commit at the root of a modal.
    var onClose: (() -> Void)? {
        didSet { setNeedsUpdateProperties() }
    }

    private let connection: ServerConnection
    private let apiClient: APIClient?
    private let appNavigation: AppNavigation

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
    private var didOpenTestingQuickAction = false
    private var detailTask: Task<Void, Never>?
    private var quickActionTask: Task<Void, Never>?

    private let pageView = UIView()
    private var mountedPhase: MountedPhase?
    private var loadedContent: CommitDetailContentView?
    private let progressPanel = ReviewLaunchProgressPanel()
    private lazy var column = TrailingColumnController(screen: self)
    private let diffSheet = RouterModalPresenter()

    private enum MountedPhase: Equatable {
        case loading
        case unavailable(String)
        case loaded(GitCommitDetail)
    }

    private lazy var closeItem: UIBarButtonItem = {
        let mode = FullScreenViewerNavigationChrome.DismissMode.modal
        let item = UIBarButtonItem(
            title: mode.accessibilityLabel,
            image: UIImage(systemName: mode.systemImageName),
            primaryAction: UIAction { [weak self] _ in self?.onClose?() }
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
        navigation: AppNavigation
    ) {
        self.configuration = configuration
        self.connection = connection
        self.apiClient = apiClient
        self.appNavigation = navigation
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Commit")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.additionalOverflowItems = actionMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var actionMenuState: CommitDetailActionMenuState {
        CommitDetailActionMenuState.make(
            workspaceId: configuration.workspaceId,
            detail: detail,
            launchActionInFlightTitle: launchActionInFlightTitle
        )
    }

    private var usesTrailingColumn: Bool {
        TrailingSidePanelPolicy.usesTrailingColumn(horizontalSizeClass: traitCollection.horizontalSizeClass)
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
        addChild(column)
        view.addSubview(column.view)
        column.view.frame = .zero
        column.didMove(toParent: self)
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
        if let destination = configuration.testingQuickActionDestination, !didOpenTestingQuickAction {
            didOpenTestingQuickAction = true
            openQuickActionSession(destination)
        }
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
        let root = HostFactory.root(near: self)
        let themeID = root?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        view.backgroundColor = UIColor(palette.bgDark)
        reconcileContent()
        loadedContent?.apply(themeID: themeID)
        progressPanel.apply(palette)
        progressPanel.text = launchActionInFlightTitle
        progressPanel.isHidden = launchActionInFlightTitle == nil
        view.bringSubviewToFront(progressPanel)
        // Hosted SwiftUI bars tint their items with the root's `.themeBlue`.
        closeItem.tintColor = UIColor(palette.blue)
        let leading = onClose == nil ? nil : closeItem
        if navigationItem.leftBarButtonItem !== leading {
            navigationItem.leftBarButtonItem = leading
        }
        if let root {
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
                self?.selectedFile = file
            }
            embed(content)
            loadedContent = content
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

    /// The open diff follows the selection: the column in regular width, a
    /// sheet in compact. A width change moves it between the two; the open
    /// file survives. Swipe-down clears it like the close button.
    private func updateDiffPanel(root: AppRootEnvironment) {
        let file = selectedFile
        let inColumn = usesTrailingColumn
        column.show(
            inColumn ? file.map { file in
                TrailingColumnController.Panel(
                    id: AnyHashable(file.id),
                    minWidth: 320,
                    idealWidth: 440,
                    screen: diffScreen(file)
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
                return diffScreen(file)
            }
        )
    }

    /// The diff of `file` in this commit, with this viewer's server and
    /// review scope.
    private func diffScreen(_ file: GitCommitFileInfo) -> RouterScreen {
        let configuration = CommitFileDiffViewController.Configuration(
            workspaceId: configuration.workspaceId,
            sha: self.configuration.commit.sha,
            file: file,
            reviewCommentSelectionScope: self.configuration.reviewCommentSelectionScope
        )
        let apiClient = apiClient
        return .controller({ [weak self] in
            let diff = CommitFileDiffViewController(configuration: configuration, apiClient: apiClient)
            diff.onClose = { self?.selectedFile = nil }
            return diff
        })
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
    /// The commit viewer opened from a chat keeps an `AppNavigation` of its own
    /// (`ChatTimelineDestinationPresenter`), so its chat leaves the app's alone.
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
        if let root = HostFactory.root(near: self), chat.traitOverrides.appRootEnvironment == nil {
            chat.traitOverrides.appRootEnvironment = root
        }
        Router.push(chat, from: self)
    }

    private func startEmptySession() async {
        guard launchActionInFlightTitle == nil else { return }
        guard !configuration.workspaceId.isEmpty else {
            WorkspaceQuickActionMenu.presentLaunchError("Workspace is unavailable.", from: self)
            return
        }
        guard let api = apiClient else {
            WorkspaceQuickActionMenu.presentLaunchError("Server is offline.", from: self)
            return
        }

        launchActionInFlightTitle = String(localized: "Starting new session…")
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.createWorkspaceSession(workspaceId: configuration.workspaceId)
            connection.sessionStore.upsert(response.session)
            openQuickActionSession(QuickActionSessionNavDestination.attachingCommit(
                sessionId: response.session.id,
                sha: detail?.sha ?? configuration.commit.sha,
                message: detail?.message ?? configuration.commit.message
            ))
        } catch {
            WorkspaceQuickActionMenu.presentLaunchError(error.localizedDescription, from: self)
        }
    }

    private func createQuickActionSession(option: WorkspaceQuickActionOption) async {
        guard launchActionInFlightTitle == nil else { return }
        guard !configuration.workspaceId.isEmpty else {
            WorkspaceQuickActionMenu.presentLaunchError("Workspace is unavailable.", from: self)
            return
        }
        guard let detail else { return }
        let paths = detail.files.map(\.path)
        guard !paths.isEmpty else {
            WorkspaceQuickActionMenu.presentLaunchError("Commit has no changed files.", from: self)
            return
        }
        guard let api = apiClient else {
            WorkspaceQuickActionMenu.presentLaunchError("Server is offline.", from: self)
            return
        }

        launchActionInFlightTitle = option.progressTitle
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.createWorkspaceQuickActionSession(
                workspaceId: configuration.workspaceId,
                paths: paths,
                commitSha: detail.sha,
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
            WorkspaceQuickActionMenu.presentLaunchError(error.localizedDescription, from: self)
        }
    }

    // MARK: Loading

    private func loadDetail() async {
        guard let api = apiClient else {
            error = "Server is offline."
            return
        }
        do {
            let loaded = try await api.getCommitDetail(workspaceId: configuration.workspaceId, sha: configuration.commit.sha)
            guard !Task.isCancelled else { return }
            detail = loaded
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadQuickActionsIfNeeded() async {
        guard !configuration.workspaceId.isEmpty, !isLoadingQuickActions, let api = apiClient else { return }
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
    private var rows: [CommitFileRowControl] = []
    private var appliedThemeID: ThemeID?

    init(detail: GitCommitDetail, onSelect: @escaping (GitCommitFileInfo) -> Void) {
        self.detail = detail
        super.init(frame: .zero)
        alwaysBounceVertical = true

        shaLabel.text = detail.sha
        shaLabel.font = AskUIFont.monospaced(.caption1, weight: .semibold)
        messageLabel.text = detail.message
        messageLabel.font = AskUIFont.preferred(.subheadline, weight: .medium)
        messageLabel.numberOfLines = 0
        authorLabel.text = detail.author
        authorLabel.font = .preferredFont(forTextStyle: .caption2)
        authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dateLabel.text = Self.relativeDate(from: detail.date)
        dateLabel.font = AskUIFont.monospaced(.caption2, weight: .regular)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addedLabel.text = "+\(detail.addedLines)"
        addedLabel.isHidden = detail.addedLines <= 0
        removedLabel.text = "-\(detail.removedLines)"
        removedLabel.isHidden = detail.removedLines <= 0
        for label in [addedLabel, removedLabel] {
            label.font = AskUIFont.monospaced(.caption2, weight: .bold)
        }
        filesHeaderLabel.font = AskUIFont.monospaced(.caption2, weight: .semibold)
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

        rows = detail.files.map { file in
            let row = CommitFileRowControl(file: file)
            row.addAction(UIAction { _ in onSelect(file) }, for: .primaryActionTriggered)
            return row
        }
        let fileList = UIStackView(arrangedSubviews: rows)
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
        shaLabel.textColor = UIColor(palette.comment)
        messageLabel.textColor = UIColor(palette.fg)
        authorLabel.textColor = UIColor(palette.fgDim)
        dateLabel.textColor = UIColor(palette.comment)
        addedLabel.textColor = UIColor(palette.toolDiffAdded)
        removedLabel.textColor = UIColor(palette.toolDiffRemoved)
        let count = detail.files.count
        filesHeaderLabel.attributedText = NSAttributedString(
            string: "\(count) file\(count == 1 ? "" : "s") changed",
            attributes: [.kern: 0.4, .foregroundColor: UIColor(palette.comment)]
        )
        dividers[0].backgroundColor = UIColor(palette.comment).withAlphaComponent(0.2)
        dividers[1].backgroundColor = UIColor(palette.comment).withAlphaComponent(0.15)
        for row in rows {
            row.apply(palette: palette)
        }
    }

    private static func relativeDate(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return SessionFormatting.durationString(since: date) + " ago"
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: isoString) else { return isoString }
        return SessionFormatting.durationString(since: date) + " ago"
    }
}

/// One changed file: icon, path, line counts, status badge, chevron.
@MainActor
private final class CommitFileRowControl: UIButton {
    private let file: GitCommitFileInfo
    private let icon: FileIcon
    private let iconView = UIImageView()
    private let pathLabel = UILabel()
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private let statusLabel = UILabel()
    private let statusBadge = UIView()
    private let chevron = UIImageView()
    private let stack = UIStackView()

    init(file: GitCommitFileInfo) {
        self.file = file
        icon = FileIcon.forPath(file.path)
        super.init(frame: .zero)
        iconView.image = icon.uiImage(pointSize: 10, weight: .semibold)
        iconView.contentMode = icon.isAssetImage ? .scaleAspectFit : .center
        pathLabel.text = file.path.shortenedPath
        pathLabel.font = AskUIFont.monospaced(.caption2, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let added = file.addedLines ?? 0
        let removed = file.removedLines ?? 0
        addedLabel.text = "+\(added)"
        addedLabel.isHidden = added <= 0
        removedLabel.text = "-\(removed)"
        removedLabel.isHidden = removed <= 0
        for label in [addedLabel, removedLabel] {
            label.font = AskUIFont.monospaced(.caption2, weight: .bold)
        }
        statusLabel.text = file.status
        statusLabel.font = AskUIFont.preferred(.caption2, weight: .medium)
        for label in [pathLabel, addedLabel, removedLabel, statusLabel] {
            label.adjustsFontForContentSizeCategory = true
            let trailing = label !== pathLabel
            label.setContentCompressionResistancePriority(trailing ? .required : .defaultLow, for: .horizontal)
            label.setContentHuggingPriority(trailing ? .required : .defaultLow, for: .horizontal)
        }
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        statusBadge.layer.cornerRadius = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.addSubview(statusLabel)
        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        )
        chevron.contentMode = .center

        for subview in [iconView, pathLabel, addedLabel, removedLabel, statusBadge, chevron] {
            stack.addArrangedSubview(subview)
        }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        // Spacer(minLength: 4) between the path and the trailing items.
        stack.setCustomSpacing(16, after: pathLabel)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            statusLabel.topAnchor.constraint(equalTo: statusBadge.topAnchor, constant: 1),
            statusLabel.bottomAnchor.constraint(equalTo: statusBadge.bottomAnchor, constant: -1),
            statusLabel.leadingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: statusBadge.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "commit-detail.file"
        accessibilityLabel = [
            pathLabel.text,
            addedLabel.isHidden ? nil : addedLabel.text,
            removedLabel.isHidden ? nil : removedLabel.text,
            statusLabel.text,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { stack.alpha = isHighlighted ? 0.6 : 1 }
    }

    /// The row's content sizes it; an empty button's own minimum size would pad it.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    func apply(palette: ThemePalette) {
        iconView.tintColor = UIColor(icon.tint.snapshotColor)
        pathLabel.textColor = UIColor(palette.fg)
        addedLabel.textColor = UIColor(palette.toolDiffAdded)
        removedLabel.textColor = UIColor(palette.toolDiffRemoved)
        let statusColor = Self.statusColor(file.status, palette: palette)
        statusLabel.textColor = statusColor
        statusBadge.backgroundColor = statusColor.withAlphaComponent(0.12)
        chevron.tintColor = UIColor(palette.comment).withAlphaComponent(0.5)
    }

    private static func statusColor(_ status: String, palette: ThemePalette) -> UIColor {
        switch status {
        case "M": UIColor(palette.orange)
        case "A": UIColor(palette.toolDiffAdded)
        case "D": UIColor(palette.toolDiffRemoved)
        case "R", "C": UIColor(palette.cyan)
        default: UIColor(palette.comment)
        }
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
    var onClose: (() -> Void)?

    private let apiClient: APIClient?
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
    private let stashButton = ReviewCommentStashFloatingButton()

    init(configuration: Configuration, apiClient: APIClient?) {
        self.configuration = configuration
        self.apiClient = apiClient
        super.init(nibName: nil, bundle: nil)
        title = configuration.file.path.lastPathComponentForDisplay
        navigationItem.largeTitleDisplayMode = .never
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
        let themeID = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        view.backgroundColor = UIColor(palette.bgDark)
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
        divider.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.2)
        navigationItem.leftBarButtonItem?.tintColor = UIColor(palette.blue)
        reconcileBody()
        stashButton.update(
            on: view,
            presenter: self,
            scope: configuration.reviewCommentSelectionScope,
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
        let content: UIView
        switch phase {
        case .loading:
            ReviewPagePlaceholder.showLoading(String(localized: "Loading diff…"), on: bodyView)
            return
        case .unavailable(let message):
            content = ReviewPagePlaceholder.unavailable(title: String(localized: "Diff Unavailable"), message: message)
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
