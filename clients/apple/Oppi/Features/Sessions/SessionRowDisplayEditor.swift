import UIKit

// MARK: - Preview subject

/// What the editor previews: one root row and, for a launch tree, its Thread
/// strip. Built once when the editor opens and frozen while it is open. It
/// is built from data already in memory, never fetched or persisted.
struct SessionRowPreviewSubject {
    struct Thread {
        let rollup: SessionThreadRollup
        /// Pending asks of each member, fixed when the subject is built. The strip classifies from these,
        /// so the preview draws what a list row would.
        let askCounts: [String: Int]
    }

    let presentation: SessionRowPresentation
    let thread: Thread?

    /// Illustrative rows for a thread whose root is Done while children work,
    /// ask a question, and finish. Nothing here comes from the user's sessions.
    static func sample(now: Date = Date()) -> Self {
        func session(
            _ id: String,
            _ name: String,
            status: SessionStatus,
            parent: String? = nil,
            startedAgo: TimeInterval,
            activeAgo: TimeInterval,
            cost: Double,
            model: String = "anthropic/claude-sonnet-5",
            changeStats: SessionChangeStats? = nil,
            contextTokens: Int? = nil,
            programStatus: ProgramStatus? = nil
        ) -> Session {
            Session(
                id: "sample.\(id)",
                workspaceName: "shop-app",
                name: name,
                status: status,
                createdAt: now.addingTimeInterval(-startedAgo),
                lastActivity: now.addingTimeInterval(-activeAgo),
                currentTurnStartedAt: status == .busy ? now.addingTimeInterval(-95) : nil,
                programStatus: programStatus,
                model: model,
                messageCount: 24,
                tokens: TokenUsage(input: 0, output: 0),
                cost: cost,
                changeStats: changeStats,
                contextTokens: contextTokens,
                contextWindow: contextTokens == nil ? nil : 200_000,
                parentSessionId: parent.map { "sample.\($0)" }
            )
        }

        let root = session(
            "root", "Refactor checkout flow", status: .ready,
            startedAgo: 7_200, activeAgo: 180, cost: 3.14,
            changeStats: SessionChangeStats(
                mutatingToolCalls: 31, compactionCount: 2, filesChanged: 7,
                changedFiles: [], changedFilesOverflow: nil
            ),
            contextTokens: 96_000,
            programStatus: ProgramStatus(state: .done, since: now.addingTimeInterval(-180))
        )
        let working = session(
            "tests", "Write migration tests", status: .busy, parent: "root",
            startedAgo: 1_800, activeAgo: 20, cost: 0.84,
            programStatus: ProgramStatus(state: .working, since: now.addingTimeInterval(-95))
        )
        let question = session(
            "review", "Review API diff", status: .ready, parent: "root",
            startedAgo: 1_500, activeAgo: 240, cost: 0.51,
            programStatus: ProgramStatus(state: .blocked, kind: .question, since: now.addingTimeInterval(-240))
        )
        let finished = session(
            "notes", "Draft changelog", status: .stopped, parent: "root",
            startedAgo: 3_600, activeAgo: 2_400, cost: 0.19,
            programStatus: ProgramStatus(state: .done, since: now.addingTimeInterval(-2_400))
        )
        let rollup = SessionThreadGrouping.rollups(from: [root, working, question, finished])[0]
        return Self(
            presentation: SessionRowPresentationBuilder.make(
                session: root,
                workspaceContext: root.workspaceName
            ),
            // Nothing in a sample has a pending ask: its blocked child comes from its own record.
            thread: Thread(rollup: rollup, askCounts: [:])
        )
    }

    /// A snapshot of an already-loaded thread (or, when none has children, the
    /// first loaded session) from the cold list projection.
    @MainActor
    static func loaded(from connection: ServerConnection?) -> Self? {
        guard let connection else { return nil }
        let store = connection.sessionStore
        let rollups = SessionThreadGrouping.rollups(from: store.listProjectionSessions)
        guard let rollup = rollups.first(where: { !$0.descendants.isEmpty }) ?? rollups.first else {
            return nil
        }
        func askCount(_ sessionId: String) -> Int {
            SessionListAttentionMerger.askCount(
                listCount: store.listPendingAskCount(for: sessionId),
                hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
                hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
            )
        }
        let root = rollup.root
        let workspaceName = root.workspaceId.flatMap { id in
            connection.workspaceStore.workspaces.first { $0.id == id }?.name
        }
        let presentation = SessionRowPresentationBuilder.make(
            session: root,
            pendingAskCount: askCount(root.id),
            pendingAsk: connection.askRequestStore.pending(for: root.id),
            workspaceContext: SessionInboxSessionRouting.allSessionsContext(for: root, workspaceName: workspaceName),
            seenAt: store.seenAt(for: root.id),
            catalogModels: connection.chatState.cachedModels
        )
        let askCounts = Dictionary(uniqueKeysWithValues: rollup.members.map { ($0.id, askCount($0.id)) })
        return Self(
            presentation: presentation,
            thread: rollup.descendants.isEmpty ? nil : Thread(rollup: rollup, askCounts: askCounts)
        )
    }
}

// MARK: - Editor

/// Session Rows settings page: an inert preview drawn by the production row
/// and Thread strip, pinned above the controls. Changes apply immediately, so
/// the preview and every session list repaint as you toggle.
///
/// A page on `ListScreenController`: the preview is a pinned overlay at the
/// safe area's top edge and the kit's list scrolls under it, its first row
/// inset past the preview on every layout pass, so no row starts behind the
/// preview at any text size. The page keeps the Density picker's own cell and
/// the switches it holds across reconfigures.
final class SessionRowDisplayEditorViewController: ListScreenController<
    SessionRowDisplayEditorViewController.Section,
    SessionRowDisplayEditorViewController.Item
> {
    enum Section: Hashable, Sendable {
        case density
        case details
        case thread
        case restore
    }

    enum Item: Hashable, Sendable {
        case density
        case toggle(Toggle)
        case restore
    }

    enum Toggle: String, CaseIterable, Sendable {
        case model, time, context, cost, files, compactions, agentSummary

        var title: String {
            switch self {
            case .model: "Model"
            case .time: "Time"
            case .context: "Context Usage"
            case .cost: "Cost"
            case .files: "Files Touched"
            case .compactions: "Compactions"
            case .agentSummary: "Agent Summary"
            }
        }

        var keyPath: WritableKeyPath<SessionRowDisplay, Bool> {
            switch self {
            case .model: \.showsModel
            case .time: \.showsTime
            case .context: \.showsContextUsage
            case .cost: \.showsCost
            case .files: \.showsFilesTouched
            case .compactions: \.showsCompactions
            case .agentSummary: \.showsThreadAgentSummary
            }
        }
    }

    private let root: AppRootEnvironment
    /// The gap between the pinned preview and the list's first row.
    private static let previewGap: CGFloat = 14
    /// What the list is inset by now, so a pass that changed nothing leaves the
    /// scroll position alone.
    private var previewInset: CGFloat = 0

    private let previewPane = UIStackView()
    private let previewLabel = UILabel()
    private let previewBox = UIStackView()
    private let previewRow = SessionRowView(combinesAccessibility: false)
    private let previewStrip = SessionThreadStripView()
    /// The strip's slot: the preview hides the slot, so a hidden strip takes its spacing with it.
    private let previewSlot = UIView()
    private let previewNote = UILabel()
    private let previewData = UISegmentedControl(items: [String(localized: "Sample"), String(localized: "My session")])
    private let previewDivider = UIView()

    private var draft = AppPreferences.SessionRows.display {
        didSet {
            guard draft != oldValue else { return }
            AppPreferences.SessionRows.setDisplay(draft)
            setNeedsUpdateProperties()
        }
    }
    private let sample = SessionRowPreviewSubject.sample()
    private var loaded: SessionRowPreviewSubject?
    private var usesLoaded = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var switches: [Toggle: UISwitch] = [:]

    private var subject: SessionRowPreviewSubject {
        usesLoaded ? (loaded ?? sample) : sample
    }

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(
            title: String(localized: "Session Rows"),
            listIdentifier: "sessionRows.form",
            headers: true,
            footers: true,
            dismissesKeyboardOnDrag: true
        )
        navigationItem.largeTitleDisplayMode = .never
        // The editor reads the loaded thread once, when it opens.
        loaded = SessionRowPreviewSubject.loaded(from: root.coordinator.activeConnection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The preview pins over the kit's list, which scrolls under it.
        buildPreviewPane()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The list starts below the pinned preview, which grows with the text
        // size: the inset follows the pane's own height on every pass.
        let inset = previewPane.bounds.height + Self.previewGap
        guard inset != previewInset else { return }
        let wasAtTop = collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 0.5
        previewInset = inset
        collectionView.contentInset.top = inset
        collectionView.verticalScrollIndicatorInsets.top = inset
        if wasAtTop { collectionView.contentOffset.y = -collectionView.adjustedContentInset.top }
    }

    override func updateProperties() {
        super.updateProperties()
        let themeStore = root.themeStore
        let themeID = themeStore.activeThemeID
        let colors = SessionRowStyle.for(themeID).colors
        previewPane.backgroundColor = themeStore.backgroundColor
        previewLabel.textColor = colors.comment
        previewNote.textColor = colors.comment
        previewDivider.backgroundColor = .separator

        let subject = subject
        previewLabel.text = usesLoaded
            ? String(localized: "PREVIEW \u{00B7} SNAPSHOT OF A LOADED SESSION")
            : String(localized: "PREVIEW \u{00B7} SAMPLE DATA")
        previewRow.apply(
            SessionRowView.Content(presentation: subject.presentation),
            display: draft,
            themeID: themeID,
            iconAssetCache: root.coordinator.activeConnection.iconAssetCache
        )
        if let thread = subject.thread {
            previewSlot.isHidden = false
            previewStrip.apply(
                SessionThreadStripView.Content(rollup: thread.rollup, askCounts: thread.askCounts),
                display: draft,
                style: SessionRowStyle.for(themeID),
                iconAssetCache: root.coordinator.activeConnection.iconAssetCache
            )
        } else {
            previewSlot.isHidden = true
        }
        if usesLoaded, subject.thread == nil {
            previewNote.text = String(localized: "This session has no child sessions, so thread options do not show here.")
        } else if !usesLoaded {
            previewNote.text = String(localized: "Not your sessions. Nothing is fetched or opened for this preview.")
        } else {
            previewNote.text = String(localized: "Already loaded on this device. Nothing is fetched or opened for this preview.")
        }
        previewData.isHidden = loaded == nil
        previewData.selectedSegmentIndex = usesLoaded ? 1 : 0
    }

    // MARK: Preview

    private func buildPreviewPane() {
        previewLabel.font = UIFont.scaled(.caption1, .semibold)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.accessibilityIdentifier = "sessionRows.preview.label"

        // Inert: the production row and strip with no navigation, swipe, or
        // other actions attached, and no hit testing.
        previewStrip.accessibilityTraits = []
        previewBox.axis = .vertical
        previewBox.alignment = .trailing
        previewBox.spacing = 6
        previewBox.isUserInteractionEnabled = false
        previewBox.addArrangedSubview(previewRow)
        previewBox.addArrangedSubview(previewSlot)
        // The strip sits on the row's own grid, as it does in a list row: it starts on the row's title
        // column and ends on its trailing text column.
        previewSlot.addSubview(previewStrip)
        previewStrip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewRow.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
            previewSlot.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
            previewStrip.topAnchor.constraint(equalTo: previewSlot.topAnchor),
            previewSlot.bottomAnchor.constraint(equalTo: previewStrip.bottomAnchor),
            previewStrip.leadingAnchor.constraint(equalTo: previewRow.textLeadingAnchor),
            previewStrip.trailingAnchor.constraint(equalTo: previewRow.textTrailingAnchor),
        ])
        previewBox.accessibilityContainerType = .semanticGroup
        previewBox.accessibilityIdentifier = "sessionRows.preview"

        previewNote.font = UIFont.scaled(.footnote)
        previewNote.adjustsFontForContentSizeCategory = true
        previewNote.numberOfLines = 0

        previewData.accessibilityIdentifier = "sessionRows.previewData"
        previewData.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            usesLoaded = previewData.selectedSegmentIndex == 1
        }, for: .valueChanged)

        previewPane.axis = .vertical
        previewPane.alignment = .fill
        previewPane.spacing = 8
        previewPane.isLayoutMarginsRelativeArrangement = true
        previewPane.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        [previewLabel, previewBox, previewNote, previewData].forEach(previewPane.addArrangedSubview)
        previewPane.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewPane)
        // Pinned, not scrolled: the preview stays while the controls move under it.
        NSLayoutConstraint.activate([
            previewPane.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            previewPane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewPane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        previewDivider.translatesAutoresizingMaskIntoConstraints = false
        previewPane.addSubview(previewDivider)
        NSLayoutConstraint.activate([
            previewDivider.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            previewDivider.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            previewDivider.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
            previewDivider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
        ])
    }

    // MARK: - Rows

    /// The switches and Restore Defaults are the kit's theme cards; the Density
    /// picker is the page's own cell (`dequeue(_:at:)`).
    override var rowStyle: ListRowStyle { .card }

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(.density, footer: densityFooter, items: [.density]),
            ListSection(
                .details,
                header: String(localized: "Details"),
                footer: String(localized: "Details keep this order. Title, status, questions, Incognito, workspace, and search matches always show."),
                items: [.model, .time, .context, .cost, .files, .compactions].map(Item.toggle)
            ),
            ListSection(
                .thread,
                header: String(localized: "Thread Rows"),
                footer: String(localized: "The Thread control, a child's question, who is working, the status dots, and the status counts always show. Cost in the Thread row follows Cost above."),
                items: [.toggle(.agentSummary)]
            ),
            ListSection(.restore, items: [.restore]),
        ]
    }

    /// Only the two groups that carry a name show a heading.
    override func showsHeader(for section: Section) -> Bool {
        switch section {
        case .details, .thread: true
        case .density, .restore: false
        }
    }

    /// Each control is keyed by the choice it draws, so flipping one redraws its
    /// own row (and the density footer the kit redraws anyway), never the switch
    /// beside it.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .density: AnyHashable(draft.density)
        case .toggle(let toggle): AnyHashable(draft[keyPath: toggle.keyPath])
        case .restore: AnyHashable(draft != .standard)
        }
    }

    private var densityFooter: String {
        draft.density == .compact
            ? String(localized: "Compact tightens spacing and joins details on one line only when they all fit. It never hides or shortens a detail you turned on.")
            : String(localized: "Standard stacks details in two rows with roomier spacing.")
    }

    /// The Density picker is the page's own cell; every other row is the kit's
    /// theme card.
    private lazy var densityCell = UICollectionView.CellRegistration<SessionRowsDensityCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        SettingsListStyle.card(cell)
        cell.configure(selected: draft.density) { [weak self] density in self?.draft.density = density }
    }

    override func prepareRegistrations() {
        _ = densityCell
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .density:
            collectionView.dequeueConfiguredReusableCell(using: densityCell, for: indexPath, item: item)
        case .toggle, .restore:
            cardCell(for: item, at: indexPath)
        }
    }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        switch item {
        case .density:
            break
        case .toggle(let toggle):
            configureToggleRow(cell, toggle: toggle)
        case .restore:
            let enabled = draft != .standard
            ListScreen.buttonRow(
                cell,
                identifier: "sessionRows.restore",
                label: String(localized: "Restore Defaults"),
                enabled: enabled
            ) { [weak self] in self?.draft = .standard }
            var content = content(.plain)
            content.text = String(localized: "Restore Defaults")
            content.textProperties.color = enabled ? root.themeStore.activeThemeID.palette.ui.blue : .tertiaryLabel
            cell.contentConfiguration = content
        }
    }

    /// One switch per control, kept across reconfigures so a flip animates.
    private func toggleSwitch(_ toggle: Toggle) -> UISwitch {
        if let control = switches[toggle] { return control }
        let control = UISwitch()
        control.accessibilityIdentifier = "sessionRows.toggle.\(toggle.rawValue)"
        control.accessibilityLabel = toggle.title
        control.addAction(UIAction { [weak self, weak control] _ in
            guard let self, let control else { return }
            draft[keyPath: toggle.keyPath] = control.isOn
        }, for: .valueChanged)
        switches[toggle] = control
        return control
    }

    /// A switch row: the title, and the switch the page holds at its trailing
    /// edge. The switch is the row's one element and takes its own taps.
    private func configureToggleRow(_ cell: SidebarListCell, toggle: Toggle) {
        ListScreen.staticRow(cell)
        var content = content(.plain)
        content.text = toggle.title
        cell.contentConfiguration = content
        let control = toggleSwitch(toggle)
        // The app tint SwiftUI toggles drew in, following the theme.
        control.onTintColor = root.themeStore.activeThemeID.palette.ui.blue
        if control.isOn != draft[keyPath: toggle.keyPath] {
            control.setOn(draft[keyPath: toggle.keyPath], animated: control.window != nil)
        }
        cell.accessories = [.customView(configuration: .init(customView: control, placement: .trailing()))]
        cell.accessibilityElements = [control]
    }
}

/// The Density picker: a segmented control across the row.
final class SessionRowsDensityCell: UICollectionViewListCell {
    private let control = UISegmentedControl(items: SessionRowDisplay.Density.allCases.map(\.label))
    private var onChange: ((SessionRowDisplay.Density) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        control.accessibilityIdentifier = "sessionRows.density"
        control.accessibilityLabel = String(localized: "Density")
        control.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onChange?(SessionRowDisplay.Density.allCases[control.selectedSegmentIndex])
        }, for: .valueChanged)
        control.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(control)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            control.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            control.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
        accessibilityElements = [control]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(selected: SessionRowDisplay.Density, onChange: @escaping (SessionRowDisplay.Density) -> Void) {
        self.onChange = onChange
        control.selectedSegmentIndex = SessionRowDisplay.Density.allCases.firstIndex(of: selected) ?? 0
    }
}
