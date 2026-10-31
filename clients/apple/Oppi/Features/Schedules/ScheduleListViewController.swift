import UIKit

/// Schedules: the server's schedules as cards, filtered by status, with a
/// swipe to pause, resume, or restore, and the guided composer to describe a
/// new one. A card opens the schedule's detail, which reports changes back.
@MainActor
final class ScheduleListViewController: UIViewController, UICollectionViewDelegate {
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    private enum Item: Hashable {
        /// The list's own state: loading its schedules, or why it could not.
        case state
        case empty
        case schedule(String)
    }

    private let root: AppRootEnvironment
    private let collectionView = ListScreen.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>?
    private let refreshControl = UIRefreshControl()
    private let composer: GuidedControlComposerController
    private var sidebarToggle: UIBarButtonItem?
    private let filterItem = UIBarButtonItem()

    private var schedules: [AgentScheduleSummary] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var selectedStatus: AgentScheduleStatus = .active {
        didSet { setNeedsUpdateProperties() }
    }
    private var isLoading = false {
        didSet { setNeedsUpdateProperties() }
    }
    /// Why the list could not be read: one state row, over the schedules it has.
    private(set) var loadError: String? {
        didSet { setNeedsUpdateProperties() }
    }
    /// Why the change the person asked for failed: the composer says it, and the
    /// list keeps the rows it shows.
    private(set) var actionError: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var loadTask: Task<Void, Never>?

    /// The schedules the list shows now, in order: what a test checks stayed on
    /// screen through a failure.
    var shownScheduleIDs: [String] {
        guard let dataSource else { return [] }
        return dataSource.snapshot().itemIdentifiers.compactMap { item in
            if case .schedule(let id) = item { return id }
            return nil
        }
    }

    init(root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        composer = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .schedules,
                intent: .create,
                placeholder: "Describe what should happen and when…"
            ),
            root: root
        )
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = "Schedules"
        navigationItem.largeTitleDisplayMode = .never
        filterItem.image = UIImage(systemName: "line.3.horizontal.decrease")
        filterItem.accessibilityIdentifier = "schedules.filter"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var visibleSchedules: [AgentScheduleSummary] { schedules.filter { $0.status == selectedStatus } }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(ListScreen.layout(
            appearance: .plain,
            trailingSwipe: { [weak self] in self?.swipeActions(at: $0) }
        ), animated: false)
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "schedules.list"
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        // The readable form width, as every kit page holds its list on iPad.
        SettingsListStyle.pin(collectionView, in: view)
        installDataSource()
        composer.install(in: self)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Like the SwiftUI `.task` it replaces, a load each time it shows.
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadSchedules() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        ListScreen.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        updateBarItems()
        composer.setScreenError(actionError, identifier: "schedules.error")
        applySnapshot()
    }

    private func updateBarItems() {
        filterItem.title = selectedStatus.filterTitle
        filterItem.menu = UIMenu(title: "Status", options: .singleSelection, children: AgentScheduleStatus.filterOrder.map { status in
            UIAction(title: status.filterTitle, state: status == selectedStatus ? .on : .off) { [weak self] _ in
                self?.selectedStatus = status
            }
        })
        ListScreen.setBarItems(trailing: [filterItem], leading: sidebarItems(), on: navigationItem)
    }

    /// The sidebar toggle at the split detail root.
    private func sidebarItems() -> [UIBarButtonItem] {
        guard showsSidebarToggle else { return [] }
        let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
        sidebarToggle = toggle
        WorkspaceSplitSidebarToggle.sync(toggle, root: root)
        return [toggle]
    }

    // MARK: - List

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        let visible = visibleSchedules
        // The list's own state comes first, and the schedules it already has stay
        // under it: a Retry, or a reload that failed, never hides them.
        if loadError != nil || (isLoading && schedules.isEmpty) {
            snapshot.appendItems([.state])
        }
        if visible.isEmpty {
            if loadError == nil, !isLoading { snapshot.appendItems([.empty]) }
        } else {
            // A diffable list traps on a repeated item; a repeated schedule id shows once.
            var seen = Set<String>()
            snapshot.appendItems(visible.filter { seen.insert($0.id).inserted }.map { .schedule($0.id) })
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let stateCell = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            let palette = palette
            // The card a schedule row is, inset the way the list insets them.
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = UIColor(palette.bgHighlight)
            background.cornerRadius = 20
            background.backgroundInsets = Self.cardInsets
            cell.backgroundConfiguration = background
            if let loadError {
                cell.configure(
                    .failure(title: String(localized: "Couldn't Load Schedules"), reason: loadError) { [weak self] in
                        self?.refresh()
                    },
                    identifier: "schedules.state"
                )
            } else {
                cell.configure(.loading(String(localized: "Loading schedules…")), identifier: "schedules.state")
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            if case .state = item {
                return collectionView.dequeueConfiguredReusableCell(using: stateCell, for: indexPath, item: item)
            }
            return collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
    }

    /// The inset a schedule card keeps inside its row, which the state row shares.
    private static let cardInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ListScreen.background(cell, grouped: false, palette: palette)
        let cardInsets = Self.cardInsets
        switch item {
        case .state:
            // The list's own state is the kit's cell; `installDataSource()`
            // dequeues it for this row.
            break
        case .empty:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = UIContentUnavailableConfiguration.loadState(
                .empty(
                    title: selectedStatus.emptyTitle,
                    systemImage: selectedStatus.emptySystemImage,
                    message: selectedStatus.emptyDescription
                ),
                palette: palette
            )
        case .schedule(let id):
            guard let schedule = visibleSchedules.first(where: { $0.id == id }) else { return }
            let timing = schedule.trigger.scheduleScreenTiming()
            ListScreen.buttonRow(
                cell,
                identifier: "schedules.row.\(schedule.id)",
                label: "\(schedule.name), \(timing), \(schedule.status.rawValue)"
            ) { [weak self] in
                self?.openSchedule(schedule.id)
            }
            cell.contentConfiguration = ControlViewContent(insets: cardInsets, followsLayoutMargins: false) {
                ScheduleCardView.card(schedule, palette: palette)
            }
        }
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .schedule(let id) = dataSource?.itemIdentifier(for: indexPath),
              let schedule = visibleSchedules.first(where: { $0.id == id }) else { return nil }
        let palette = palette
        let action: UIContextualAction
        switch schedule.status {
        case .active:
            action = UIContextualAction(style: .normal, title: "Pause") { [weak self] _, _, done in
                self?.mutate(schedule, .pause)
                done(true)
            }
            action.image = UIImage(systemName: "pause.fill")
            action.backgroundColor = UIColor(palette.orange)
        case .paused:
            action = UIContextualAction(style: .normal, title: "Resume") { [weak self] _, _, done in
                self?.mutate(schedule, .resume)
                done(true)
            }
            action.image = UIImage(systemName: "play.fill")
            action.backgroundColor = UIColor(palette.green)
        case .archived:
            action = UIContextualAction(style: .normal, title: "Restore") { [weak self] _, _, done in
                self?.mutate(schedule, .restore)
                done(true)
            }
            action.image = UIImage(systemName: "arrow.uturn.backward")
            action.backgroundColor = UIColor(palette.blue)
        }
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    // MARK: - Actions

    /// The pushed detail reports changes here; the list shows them when it is
    /// back on screen.
    private func openSchedule(_ scheduleId: String) {
        let detail = ScheduleDetailViewController(root: root, scheduleId: scheduleId) { [weak self] updated in
            self?.scheduleChanged(updated)
        }
        Router.push(detail, from: self)
    }

    private func scheduleChanged(_ updated: AgentScheduleSummary) {
        schedules = schedules.map { $0.id == updated.id ? updated : $0 }
        if selectedStatus == .archived, updated.status == .active {
            selectedStatus = .active
        }
    }

    enum SummaryMutation {
        case pause, resume, restore
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadSchedules()
            self?.refreshControl.endRefreshing()
        }
    }

    private func loadSchedules() async {
        guard let apiClient = root.coordinator.activeConnection.apiClient else {
            loadError = String(localized: "Server is offline")
            return
        }
        isLoading = true
        // A replaced load leaves the flag to the load that replaced it.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let loaded = try await apiClient.listAgentSchedules()
            guard !Task.isCancelled else { return }
            schedules = loaded
            loadError = nil
            // The list was read again: what an action failed at is old news.
            actionError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    func mutate(_ schedule: AgentScheduleSummary, _ action: SummaryMutation) {
        Task { [weak self] in
            guard let apiClient = self?.root.coordinator.activeConnection.apiClient else { return }
            do {
                let updated = switch action {
                case .pause: try await apiClient.pauseAgentSchedule(schedule.id)
                case .resume: try await apiClient.resumeAgentSchedule(schedule.id)
                case .restore: try await apiClient.restoreAgentSchedule(schedule.id)
                }
                guard let self else { return }
                schedules = schedules.map { $0.id == updated.id ? updated : $0 }
                if action == .restore { selectedStatus = .active }
                actionError = nil
            } catch {
                self?.actionError = error.localizedDescription
            }
        }
    }
}

/// A schedule's card in the list: cadence and status, name, and timing.
@MainActor
enum ScheduleCardView {
    static func card(_ schedule: AgentScheduleSummary, palette: ThemePalette) -> UIView {
        let cadence = ControlRowViews.label(nil, style: .caption1, weight: .semibold, color: UIColor(palette.blue), lines: 1)
        cadence.attributedText = NSAttributedString(
            string: schedule.trigger.scheduleScreenCadence,
            attributes: [.kern: 0.7, .font: UIFont.scaled(.caption1, .semibold), .foregroundColor: UIColor(palette.blue)]
        )
        var top: [UIView] = [cadence, ControlRowViews.spacer()]
        if schedule.status != .active {
            let pill = ControlStatusPill()
            pill.apply(
                text: schedule.status.rawValue.capitalized,
                tone: UIColor(schedule.status == .paused ? palette.orange : palette.comment),
                emphasis: .tinted,
                palette: palette
            )
            top.append(pill)
        }
        let header = ControlRowViews.stack(top, axis: .horizontal, spacing: 8, alignment: .center)
        let name = ControlRowViews.label(schedule.name, style: .title3, weight: .semibold, color: UIColor(palette.fg), lines: 3)
        let timing = ControlRowViews.symbolLabel(
            schedule.trigger.scheduleScreenTiming(),
            systemImage: "calendar",
            style: .subheadline,
            color: UIColor(palette.comment),
            lines: 2
        )
        return surface(
            ControlRowViews.stack([header, name, ControlRowViews.divider(palette), timing], spacing: 14),
            palette: palette
        )
    }

    private static func surface(_ content: UIView, palette: ThemePalette) -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor(palette.bgHighlight)
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
        ])
        return card
    }
}
