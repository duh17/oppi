import UIKit

// MARK: - Preview subject

/// What the editor previews: one root row and, for a launch tree, its Thread
/// strip. Built once when the editor opens and frozen while it is open. It
/// is built from data already in memory, never fetched or persisted.
struct SessionRowPreviewSubject {
    struct Thread {
        let rollup: SessionThreadRollup
        /// Status of each member, fixed when the subject is built.
        let statuses: [String: SessionStatusKind]
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
        // Nothing in a sample has been seen, so the root's result reads Done.
        let statuses = Dictionary(uniqueKeysWithValues: rollup.members.map {
            ($0.id, SessionStatusKind.resolve(session: $0, seenAt: nil))
        })
        return Self(
            presentation: SessionRowPresentationBuilder.make(
                session: root,
                workspaceContext: root.workspaceName
            ),
            thread: Thread(rollup: rollup, statuses: statuses)
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
        let statuses = Dictionary(uniqueKeysWithValues: rollup.members.map {
            ($0.id, SessionStatusKind.resolve(
                session: $0,
                pendingAskCount: askCount($0.id),
                seenAt: store.seenAt(for: $0.id)
            ))
        })
        return Self(
            presentation: presentation,
            thread: rollup.descendants.isEmpty ? nil : Thread(rollup: rollup, statuses: statuses)
        )
    }
}

// MARK: - Editor

/// Session Rows settings page: an inert preview drawn by the production row
/// and Thread strip, pinned above the controls. Changes apply immediately, so
/// the preview and every session list repaint as you toggle.
final class SessionRowDisplayEditorViewController: UIViewController {
    private enum Section: Hashable {
        case density
        case details
        case thread
        case restore
    }

    private enum Item: Hashable {
        case density
        case toggle(Toggle)
        case restore
    }

    private enum Toggle: String, CaseIterable {
        case model, time, context, cost, files, compactions, agentSummary, laneGraph

        var title: String {
            switch self {
            case .model: "Model"
            case .time: "Time"
            case .context: "Context Usage"
            case .cost: "Cost"
            case .files: "Files Touched"
            case .compactions: "Compactions"
            case .agentSummary: "Agent Summary"
            case .laneGraph: "Lane Graph"
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
            case .laneGraph: \.showsThreadLaneGraph
            }
        }
    }

    private let root: AppRootEnvironment
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?

    private let previewPane = UIStackView()
    private let previewLabel = UILabel()
    private let previewBox = UIStackView()
    private let previewRow = SessionRowView(combinesAccessibility: false)
    private let previewStrip = SessionThreadStripView()
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
    private var appliedThreadsEnabled: Bool?
    private var switches: [Toggle: UISwitch] = [:]

    private var subject: SessionRowPreviewSubject {
        usesLoaded ? (loaded ?? sample) : sample
    }

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Session Rows")
        navigationItem.largeTitleDisplayMode = .never
        // The editor reads the loaded thread once, when it opens.
        loaded = SessionRowPreviewSubject.loaded(from: root.coordinator.activeConnection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildPreviewPane()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true, footers: true),
            animated: false
        )
        collectionView.accessibilityIdentifier = "sessionRows.form"
        // The first section sits a SwiftUI section gap below the preview.
        collectionView.contentInset.top = 14
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        let maxWidth = collectionView.widthAnchor.constraint(lessThanOrEqualToConstant: IPadReadableContentWidth.form)
        let fillWidth = collectionView.widthAnchor.constraint(equalTo: view.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            previewPane.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            previewPane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewPane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: previewPane.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            maxWidth,
            fillWidth,
        ])
        installDataSource()
    }

    override func updateProperties() {
        super.updateProperties()
        let themeStore = root.themeStore
        ControlScreenList.applyTheme(themeStore, to: self, collectionView: collectionView)
        let themeID = themeStore.activeThemeID
        let colors = SessionRowStyle.for(themeID).colors
        previewPane.backgroundColor = themeStore.backgroundColor
        previewLabel.textColor = colors.comment
        previewNote.textColor = colors.comment
        previewDivider.backgroundColor = .separator

        let threadsEnabled = root.navigation.sessionThreadsEnabled
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
        if threadsEnabled, let thread = subject.thread {
            previewStrip.isHidden = false
            previewStrip.apply(
                SessionThreadStripView.Content(rollup: thread.rollup, statuses: thread.statuses),
                display: draft,
                style: SessionRowStyle.for(themeID),
                iconAssetCache: root.coordinator.activeConnection.iconAssetCache
            )
        } else {
            previewStrip.isHidden = true
        }
        if threadsEnabled, usesLoaded, subject.thread == nil {
            previewNote.text = String(localized: "This session has no child sessions, so thread options do not show here.")
        } else if !usesLoaded {
            previewNote.text = String(localized: "Not your sessions. Nothing is fetched or opened for this preview.")
        } else {
            previewNote.text = String(localized: "Already loaded on this device. Nothing is fetched or opened for this preview.")
        }
        previewData.isHidden = loaded == nil
        previewData.selectedSegmentIndex = usesLoaded ? 1 : 0

        applySnapshot(threadsEnabled: threadsEnabled)
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
        previewBox.addArrangedSubview(previewStrip)
        previewStrip.translatesAutoresizingMaskIntoConstraints = false
        previewRow.widthAnchor.constraint(equalTo: previewBox.widthAnchor).isActive = true
        previewStrip.widthAnchor.constraint(
            equalTo: previewBox.widthAnchor,
            constant: -SessionThreadStripView.rowInset
        ).isActive = true
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

        previewDivider.translatesAutoresizingMaskIntoConstraints = false
        previewPane.addSubview(previewDivider)
        NSLayoutConstraint.activate([
            previewDivider.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            previewDivider.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            previewDivider.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
            previewDivider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
        ])
    }

    // MARK: Controls

    private func installDataSource() {
        let toggleCell = UICollectionView.CellRegistration<UICollectionViewListCell, Toggle> { [weak self] cell, _, toggle in
            self?.configure(cell, toggle: toggle)
        }
        let densityCell = UICollectionView.CellRegistration<SessionRowsDensityCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(selected: draft.density) { [weak self] density in self?.draft.density = density }
        }
        let restoreCell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            let enabled = draft != .standard
            ControlScreenList.buttonRow(
                cell,
                identifier: "sessionRows.restore",
                label: String(localized: "Restore Defaults"),
                enabled: enabled
            ) { [weak self] in self?.draft = .standard }
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Restore Defaults")
            content.textProperties.color = enabled ? UIColor(root.themeStore.activeThemeID.palette.blue) : .tertiaryLabel
            cell.contentConfiguration = content
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .density:
                collectionView.dequeueConfiguredReusableCell(using: densityCell, for: indexPath, item: item)
            case .toggle(let toggle):
                collectionView.dequeueConfiguredReusableCell(using: toggleCell, for: indexPath, item: toggle)
            case .restore:
                collectionView.dequeueConfiguredReusableCell(using: restoreCell, for: indexPath, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource?.sectionIdentifier(for: indexPath.section).flatMap(Self.headerText)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = self.dataSource?.sectionIdentifier(for: indexPath.section).flatMap(footerText)
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        self.dataSource = dataSource
    }

    private func applySnapshot(threadsEnabled: Bool) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.density, .details])
        snapshot.appendItems([.density], toSection: .density)
        snapshot.appendItems([.model, .time, .context, .cost, .files, .compactions].map(Item.toggle), toSection: .details)
        if threadsEnabled {
            snapshot.appendSections([.thread])
            snapshot.appendItems([.agentSummary, .laneGraph].map(Item.toggle), toSection: .thread)
        }
        snapshot.appendSections([.restore])
        snapshot.appendItems([.restore], toSection: .restore)
        // Every control and the density footer follow the draft.
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: appliedThreadsEnabled != nil && appliedThreadsEnabled != threadsEnabled)
        appliedThreadsEnabled = threadsEnabled
        refreshFooters()
    }

    /// Reconfiguring items leaves supplementary views as they were.
    private func refreshFooters() {
        let kind = UICollectionView.elementKindSectionFooter
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let footer = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell,
                  let section = dataSource?.sectionIdentifier(for: indexPath.section) else { continue }
            var content = UIListContentConfiguration.footer()
            content.text = footerText(section)
            footer.contentConfiguration = content
        }
    }

    private static func headerText(_ section: Section) -> String? {
        switch section {
        case .details: String(localized: "Details")
        case .thread: String(localized: "Thread Rows")
        case .density, .restore: nil
        }
    }

    private func footerText(_ section: Section) -> String? {
        switch section {
        case .density:
            draft.density == .compact
                ? String(localized: "Compact tightens spacing and joins details on one line only when they all fit. It never hides or shortens a detail you turned on.")
                : String(localized: "Standard stacks details in two rows with roomier spacing.")
        case .details:
            String(localized: "Details keep this order. Title, status, questions, Incognito, workspace, and search matches always show.")
        case .thread:
            String(localized: "The Thread control, a child's question, and who is working always show. Cost in the Thread row follows Cost above.")
        case .restore:
            nil
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

    private func configure(_ cell: UICollectionViewListCell, toggle: Toggle) {
        var content = UIListContentConfiguration.cell()
        content.text = toggle.title
        content.textProperties.color = UIColor(root.themeStore.activeThemeID.palette.fg)
        cell.contentConfiguration = content
        let control = toggleSwitch(toggle)
        // The app tint SwiftUI toggles drew in, following the theme.
        control.onTintColor = UIColor(root.themeStore.activeThemeID.palette.blue)
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
