import UIKit

/// Schedules: the server's schedules as cards, filtered by status, with a
/// swipe to pause, resume, or restore, and the guided composer to describe a
/// new one. A card opens the schedule's detail, which reports changes back.
///
/// A `ListScreenController`: the base owns the list, the theme, each row's
/// redraw key, the swipe actions, and the load on appearance and pull to
/// refresh, with its one state row (loading, failed with one Retry, or empty)
/// above the cards. This page keeps its cards, its status filter, its composer,
/// and the sidebar toggle.
@MainActor
final class ScheduleListViewController: ListScreenController<ScheduleListViewController.Section, ScheduleListViewController.Item> {
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    enum Section: Hashable, Sendable {
        /// The schedules the filter shows. The list's own state is this
        /// section's first row, where the schedules it already has stay under it.
        case schedules
    }

    enum Item: Hashable, Sendable {
        case schedule(String)
    }

    private let root: AppRootEnvironment
    private let composer: GuidedControlComposerController
    private var sidebarToggle: UIBarButtonItem?
    private let filterItem = UIBarButtonItem()

    private var schedules: [AgentScheduleSummary] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var selectedStatus: AgentScheduleStatus = .active {
        didSet { setNeedsUpdateProperties() }
    }
    /// Why the change the person asked for failed: the composer says it, and the
    /// list keeps the rows it shows.
    private(set) var actionError: String? {
        didSet { setNeedsUpdateProperties() }
    }

    /// The schedules the list shows now, in order: what a test checks stayed on
    /// screen through a failure.
    var shownScheduleIDs: [String] {
        shownItems.compactMap { item in
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
        super.init(
            title: "Schedules",
            listIdentifier: "schedules.list",
            dismissesKeyboardOnDrag: true
        )
        traitOverrides.appRootEnvironment = root
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
        composer.install(in: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        updateBarItems()
        composer.setScreenError(actionError, identifier: "schedules.error")
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

    // MARK: - Load

    /// Like the SwiftUI `.task` it replaces, a load each time it shows.
    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The active server's schedules: the base runs it on every appearance, on
    /// pull to refresh, after a Retry, and when the server or its client
    /// changes. Throws the reason the list's state row shows.
    override func load() async throws {
        guard let apiClient = root.coordinator.activeConnection.apiClient else {
            throw LoadFailure(String(localized: "Server is offline"))
        }
        let loaded = try await apiClient.listAgentSchedules()
        // A load the page cancelled (it left, or another one replaced it) never
        // replaces what this one shows.
        guard !Task.isCancelled else { return }
        schedules = loaded
        // The list was read again: what an action failed at is old news.
        actionError = nil
    }

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        // A diffable list traps on a repeated item; a repeated schedule id shows once.
        var seen = Set<String>()
        let items = visibleSchedules
            .filter { seen.insert($0.id).inserted }
            .map { Item.schedule($0.id) }
        return [ListSection(.schedules, items: items)]
    }

    /// The list's own state is the first row of the section the cards are in: a
    /// Retry, or a reload that failed, never hides the schedules it already has.
    override func stateSection() -> Section? { .schedules }

    /// Whether the filter's schedules are here. A status the filter leaves empty
    /// is not content: the state row says so in that status' own words.
    override func hasContent() -> Bool { !visibleSchedules.isEmpty }

    override func loadingCaption() -> String? { String(localized: "Loading schedules…") }

    override func failureTitle() -> String? { String(localized: "Couldn't Load Schedules") }

    override func emptyState() -> LoadState? {
        .empty(
            title: selectedStatus.emptyTitle,
            systemImage: selectedStatus.emptySystemImage,
            message: selectedStatus.emptyDescription
        )
    }

    /// The page's rows are the kit's theme cards, filled by
    /// `configureCard(_:item:)`.
    override var rowStyle: ListRowStyle { .card }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        guard case .schedule(let id) = item,
              let schedule = visibleSchedules.first(where: { $0.id == id }) else { return }
        let timing = schedule.trigger.scheduleScreenTiming()
        ListScreen.buttonRow(
            cell,
            identifier: "schedules.row.\(schedule.id)",
            label: "\(schedule.name), \(timing), \(schedule.status.rawValue)"
        ) { [weak self] in
            self?.openSchedule(schedule.id)
        }
        let palette = palette
        cell.contentConfiguration = ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0)) {
            ScheduleCardView.card(schedule, palette: palette)
        }
    }

    /// A card is keyed by what it draws: a swipe that pauses it, or a load that
    /// renamed it, redraws that row and leaves the others where they are.
    override func inputs(of item: Item) -> AnyHashable {
        guard case .schedule(let id) = item,
              let schedule = visibleSchedules.first(where: { $0.id == id }) else { return AnyHashable(0) }
        return AnyHashable([
            AnyHashable(schedule.name),
            AnyHashable(schedule.trigger.scheduleScreenCadence),
            AnyHashable(schedule.trigger.scheduleScreenTiming()),
            AnyHashable(schedule.status.rawValue),
        ])
    }

    override func trailingSwipeActions(for item: Item) -> UISwipeActionsConfiguration? {
        guard case .schedule(let id) = item,
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
            action.backgroundColor = palette.ui.orange
        case .paused:
            action = UIContextualAction(style: .normal, title: "Resume") { [weak self] _, _, done in
                self?.mutate(schedule, .resume)
                done(true)
            }
            action.image = UIImage(systemName: "play.fill")
            action.backgroundColor = palette.ui.green
        case .archived:
            action = UIContextualAction(style: .normal, title: "Restore") { [weak self] _, _, done in
                self?.mutate(schedule, .restore)
                done(true)
            }
            action.image = UIImage(systemName: "arrow.uturn.backward")
            action.backgroundColor = palette.ui.blue
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

/// A schedule's card in the list: cadence and status, name, and timing. The
/// kit's card row paints the surface, so this is only what the schedule says.
@MainActor
enum ScheduleCardView {
    static func card(_ schedule: AgentScheduleSummary, palette: ThemePalette) -> UIView {
        let cadence = ControlRowViews.label(nil, style: .caption1, weight: .semibold, color: palette.ui.blue, lines: 1)
        cadence.attributedText = NSAttributedString(
            string: schedule.trigger.scheduleScreenCadence,
            attributes: [.kern: 0.7, .font: UIFont.scaled(.caption1, .semibold), .foregroundColor: palette.ui.blue]
        )
        var top: [UIView] = [cadence, ControlRowViews.spacer()]
        if schedule.status != .active {
            let pill = ControlStatusPill()
            pill.apply(
                text: schedule.status.rawValue.capitalized,
                tone: schedule.status == .paused ? palette.orange : palette.comment,
                emphasis: .tinted,
                palette: palette
            )
            top.append(pill)
        }
        let header = ControlRowViews.stack(top, axis: .horizontal, spacing: 8, alignment: .center)
        let name = ControlRowViews.label(schedule.name, style: .title3, weight: .semibold, color: palette.ui.fg, lines: 3)
        let timing = ControlRowViews.symbolLabel(
            schedule.trigger.scheduleScreenTiming(),
            systemImage: "calendar",
            style: .subheadline,
            color: palette.ui.comment,
            lines: 2
        )
        return ControlRowViews.stack([header, name, ControlRowViews.divider(palette), timing], spacing: 14)
    }
}
