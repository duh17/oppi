import UIKit

/// Schedules' list: the server's schedules as cards, filtered by status, with a
/// swipe to pause, resume, or restore. A card opens the schedule's detail through
/// `openSchedule`. `SchedulesViewController` embeds it beside the calendar and owns
/// the bar (it places `filterItem`) and the composer.
///
/// Each card answers at a glance what the inventory is for: the schedule's timing in
/// words ("Weekdays · 8:30 AM"), when it runs next, how its latest run went and what it
/// cost (subagents included), who runs it (the saved Agent, else the workspace) and on
/// which model, with the calendar's own chip. Active schedules group by when they run
/// next (Today, Tomorrow, This Week, Later), each group by next run. Next and last runs
/// come from the calendar's answer for the weeks around now, so a server without the
/// calendar shows the definitions alone, in its own order.
///
/// A `ListScreenController`: the base owns the list, the theme, each row's
/// redraw key, the swipe actions, and the load on appearance and pull to
/// refresh, with its one state row (loading, failed with one Retry, or empty)
/// above the cards. This page keeps its cards and its status filter.
@MainActor
final class ScheduleListViewController: ListScreenController<ScheduleListViewController.Section, ScheduleListViewController.Item> {
    enum Section: Hashable, Sendable {
        /// The schedules the filter shows when they are not grouped, and the list's own
        /// state, where the schedules it already has stay under it.
        case schedules
        /// Active schedules that next run in this group.
        case group(ScheduleListOverview.Group)
    }

    enum Item: Hashable, Sendable {
        case schedule(String)
    }

    /// The days of runs the list reads around now: back far enough for a weekly
    /// schedule's last run, ahead far enough for a monthly one's next. Within the server's
    /// 62 days.
    private static let pastDays = 14
    private static let futureDays = 32

    private let root: AppRootEnvironment
    private let agents: ScheduleAgentDirectory
    /// The status filter, for the container's bar.
    let filterItem = UIBarButtonItem()
    /// The container's composer says an action's failure.
    var onActionErrorChange: ((String?) -> Void)?
    /// A card opens its schedule's detail; the container pushes it.
    var openSchedule: ((String) -> Void)?

    private var schedules: [AgentScheduleSummary] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    /// The calendar's answer around now: nil before it lands, on a server without it, or
    /// when reading it failed (the cards then show their definitions alone).
    private var runs: ScheduleCalendarResponse? {
        didSet { setNeedsUpdateProperties() }
    }
    private var selectedStatus: AgentScheduleStatus = .active {
        didSet { setNeedsUpdateProperties() }
    }
    /// The minute the cards count down from.
    private var now = ScheduleCalendarModel.systemClock() {
        didSet { setNeedsUpdateProperties() }
    }
    private var minuteTimer: Timer?
    /// Why the change the person asked for failed: the composer says it, and the
    /// list keeps the rows it shows.
    private(set) var actionError: String? {
        didSet { onActionErrorChange?(actionError) }
    }

    /// The schedules the list shows now, in order: what a test checks stayed on
    /// screen through a failure.
    var shownScheduleIDs: [String] {
        shownItems.compactMap { item in
            if case .schedule(let id) = item { return id }
            return nil
        }
    }

    init(root: AppRootEnvironment, agents: ScheduleAgentDirectory) {
        self.root = root
        self.agents = agents
        super.init(
            title: "Schedules",
            listIdentifier: "schedules.list",
            headers: true,
            dismissesKeyboardOnDrag: true
        )
        traitOverrides.appRootEnvironment = root
        filterItem.image = UIImage(systemName: "line.3.horizontal.decrease")
        filterItem.accessibilityIdentifier = "schedules.filter"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var calendar: Calendar { .autoupdatingCurrent }
    private var visibleSchedules: [AgentScheduleSummary] { schedules.filter { $0.status == selectedStatus } }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        now = ScheduleCalendarModel.systemClock()
        startMinuteTimer()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        minuteTimer?.invalidate()
        minuteTimer = nil
    }

    /// Countdowns move on each minute boundary.
    private func startMinuteTimer() {
        minuteTimer?.invalidate()
        let next = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60
        let timer = Timer(fire: Date().addingTimeInterval(next - now.timeIntervalSinceReferenceDate), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = ScheduleCalendarModel.systemClock() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    override func updateProperties() {
        super.updateProperties()
        filterItem.title = selectedStatus.filterTitle
        filterItem.menu = UIMenu(title: "Status", options: .singleSelection, children: AgentScheduleStatus.filterOrder.map { status in
            UIAction(title: status.filterTitle, state: status == selectedStatus ? .on : .off) { [weak self] _ in
                self?.selectedStatus = status
            }
        })
    }

    // MARK: - Load

    /// Like the SwiftUI `.task` it replaces, a load each time it shows.
    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The active server's connection: the base reloads the page by itself when it
    /// installs an API client again after a rebuild.
    override func loadConnection() -> ServerConnection? { root.windowConnectionOrStandIn }

    /// The active server's schedules, and the calendar's runs around now where the server
    /// has one: the base runs it on every appearance, on pull to refresh, after a Retry,
    /// and when the server or its client changes. Throws the reason the list's state row
    /// shows; a calendar that fails to load leaves the cards without their runs.
    override func load() async throws {
        let apiClient = try requireAPIClient()
        let hasCalendar = root.windowConnectionOrStandIn.scheduleCalendarAvailable
        async let calendarRuns = hasCalendar ? Self.runs(apiClient, around: ScheduleCalendarModel.systemClock()) : nil
        let loaded = try await apiClient.listAgentSchedules()
        let answer = await calendarRuns
        // A load the page cancelled (it left, or another one replaced it) never
        // replaces what this one shows.
        guard !Task.isCancelled else { return }
        schedules = loaded
        if hasCalendar { runs = answer ?? runs } else { runs = nil }
        // The list was read again: what an action failed at is old news.
        actionError = nil
    }

    private static func runs(_ apiClient: APIClient, around now: Date) async -> ScheduleCalendarResponse? {
        try? await apiClient.scheduleCalendar(
            from: now.addingTimeInterval(-Double(pastDays) * 86_400),
            to: now.addingTimeInterval(Double(futureDays) * 86_400)
        )
    }

    // MARK: - List

    /// This pass's facts, made in `sections()` for the cards drawn after it.
    private var overview: ScheduleListOverview?

    /// The runs' facts, with the app's live copy of their sessions: a run that is working
    /// or waiting changes here before the next load.
    private func makeOverview() -> ScheduleListOverview? {
        guard let runs else { return nil }
        let live = ScheduleCalendarDayViewController.liveSessions(for: runs, sessionStore: root.windowConnectionOrStandIn.sessionStore)
        return ScheduleListOverview(agenda: ScheduleCalendarAgenda(response: runs, live: live), now: now)
    }

    override func sections() -> [ListSection<Section, Item>] {
        overview = makeOverview()
        // A diffable list traps on a repeated item; a repeated schedule id shows once.
        var seen = Set<String>()
        let unique = visibleSchedules.filter { seen.insert($0.id).inserted }
        guard selectedStatus == .active, let overview else {
            let ordered = selectedStatus == .active
                ? unique
                : unique.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return [ListSection(.schedules, items: ordered.map { Item.schedule($0.id) })]
        }
        let groups = overview.grouped(unique.map { ($0.id, $0.name) }, now: now, calendar: calendar)
        // The state row's section first, empty but for the state when there is one.
        return [ListSection(.schedules, items: [])] + groups.map { group, ids in
            ListSection(.group(group), header: group.title, items: ids.map { Item.schedule($0) })
        }
    }

    override func showsHeader(for section: Section) -> Bool {
        if case .group = section { return true }
        return false
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

    /// What a card draws, from the schedule and its runs.
    private func card(for id: String) -> ScheduleCardView.Content? {
        guard let schedule = visibleSchedules.first(where: { $0.id == id }) else { return nil }
        let facts = overview?.facts[id]
        let badges = ScheduleRowBadges(workspaces: root.windowConnectionOrStandIn.workspaceStore.workspaces, agents: agents.agents)
        return ScheduleCardView.Content(
            id: schedule.id,
            name: schedule.name,
            status: schedule.status,
            trigger: schedule.trigger,
            next: schedule.status == .active ? facts?.next : nil,
            last: facts?.last,
            badge: badges.badge(workspaceId: schedule.action.workspaceId, agentId: schedule.action.agentId),
            model: facts?.model,
            hasRuns: runs != nil
        )
    }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        guard case .schedule(let id) = item, let content = card(for: id) else { return }
        let context = ScheduleCardView.Context(
            palette: palette, now: now, calendar: calendar,
            assetCache: root.windowConnectionOrStandIn.iconAssetCache,
            isAccessibilitySize: traitCollection.preferredContentSizeCategory.isAccessibilityCategory,
            isWide: AdaptiveWidth.isWide(traitCollection)
        )
        ListScreen.buttonRow(
            cell,
            identifier: "schedules.row.\(id)",
            label: ScheduleCardView.spoken(content, context: context),
            contextMenu: rowMenu(for: item)
        ) { [weak self] in
            self?.openSchedule?(id)
        }
        cell.contentConfiguration = ControlViewContent(insets: .init(top: 12, leading: 0, bottom: 12, trailing: 0)) {
            ScheduleCardView.card(content, context: context)
        }
    }

    /// A card is keyed by what it draws: a swipe that pauses it, a load that renamed it,
    /// a run that finished, or the minute its countdown shows redraws that row and leaves
    /// the others where they are.
    override func inputs(of item: Item) -> AnyHashable {
        guard case .schedule(let id) = item, let content = card(for: id) else { return AnyHashable(0) }
        let ticking = content.next != nil || content.last?.outcome.isActive == true
        return AnyHashable([
            AnyHashable(content), AnyHashable(ticking ? now : .distantPast),
            AnyHashable(traitCollection.preferredContentSizeCategory), AnyHashable(AdaptiveWidth.isWide(traitCollection)),
            AnyHashable(EntityIcon.loadGeneration),
        ])
    }

    override func rowActions(for item: Item) -> [ListRowAction] {
        guard case .schedule(let id) = item,
              let schedule = visibleSchedules.first(where: { $0.id == id }) else { return [] }
        let palette = palette
        let change: SummaryMutation = switch schedule.status {
        case .active: .pause
        case .paused: .resume
        case .archived: .restore
        }
        let (title, image, tint): (String, String, UIColor) = switch change {
        case .pause: ("Pause", "pause.fill", palette.ui.orange)
        case .resume: ("Resume", "play.fill", palette.ui.green)
        case .restore: ("Restore", "arrow.uturn.backward", palette.ui.blue)
        }
        return [ListRowAction(title: title, systemImage: image, tint: tint) { [weak self] done in
            self?.mutate(schedule, change)
            done(true)
        }]
    }

    // MARK: - Actions

    /// The pushed detail reports changes here; the list shows them when it is
    /// back on screen.
    func scheduleChanged(_ updated: AgentScheduleSummary) {
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
            guard let apiClient = self?.root.windowConnectionOrStandIn.apiClient else { return }
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
                // Its next run comes or goes with the server's answer.
                setNeedsLoad()
            } catch {
                self?.actionError = error.localizedDescription
            }
        }
    }
}

/// A schedule's card in the list. The kit's card row paints the surface, so this is only
/// what the schedule says: its name and when it runs next (or that it is paused), its
/// timing in words, then its latest run and the calendar's Agent-or-workspace and model
/// chip. Accessibility sizes stack every part.
@MainActor
enum ScheduleCardView {
    struct Content: Hashable {
        let id: String
        let name: String
        let status: AgentScheduleStatus
        let trigger: AgentScheduleTrigger
        let next: Date?
        let last: ScheduleCalendarAgenda.Item?
        let badge: ScheduleRowBadge?
        let model: String?
        /// The server answered with runs, so a schedule with none says it has none.
        let hasRuns: Bool
    }

    struct Context {
        let palette: ThemePalette
        let now: Date
        let calendar: Calendar
        let assetCache: IconAssetCache?
        let isAccessibilitySize: Bool
        let isWide: Bool
    }

    static func card(_ content: Content, context: Context) -> UIView {
        let palette = context.palette
        let stacked = context.isAccessibilitySize

        let name = ControlRowViews.label(content.name, style: .body, weight: .semibold, color: palette.ui.fg, lines: stacked ? 0 : 2)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailing = when(content, context: context)
        let timing = ControlRowViews.symbolLabel(
            content.trigger.scheduleScreenTiming(),
            systemImage: "calendar",
            style: .subheadline,
            color: palette.ui.fgDim,
            symbolColor: palette.ui.comment,
            lines: stacked ? 0 : 2
        )
        let last = lastRun(content, context: context)
        let chip = ScheduleCalendarRowViews.chip(
            badge: content.badge, model: content.model, palette: palette, assetCache: context.assetCache,
            // As the calendar's rows: a phone's chip names only the model.
            includesName: context.isWide || stacked, includesModel: true
        )

        if stacked {
            var lines: [UIView] = [name]
            if let trailing { lines.append(leading(trailing)) }
            lines.append(timing)
            if let last { lines.append(last) }
            if let chip { lines.append(leading(chip)) }
            return ControlRowViews.stack(lines, spacing: 6)
        }

        var head: [UIView] = [name, ControlRowViews.spacer()]
        if let trailing { head.append(trailing) }
        // The bottom line: the latest run, then who runs it; with no run yet, the chip alone.
        var foot: [UIView] = []
        if let last {
            last.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            foot.append(last)
        }
        foot.append(ControlRowViews.spacer())
        if let chip { foot.append(chip) }
        var lines: [UIView] = [
            ControlRowViews.stack(head, axis: .horizontal, spacing: 10, alignment: .firstBaseline),
            timing,
        ]
        if foot.count > 1 {
            lines.append(ControlRowViews.stack(foot, axis: .horizontal, spacing: 8, alignment: .center))
        }
        let stack = ControlRowViews.stack(lines, spacing: 4)
        if lines.count == 3 { stack.setCustomSpacing(8, after: timing) }
        return stack
    }

    /// "in 18m" (bold within the hour), "5:00 PM" (blue today), "Thu 7:00 AM", "Dec 1";
    /// nothing tomorrow; or the status pill of a paused or archived schedule.
    private static func when(_ content: Content, context: Context) -> UIView? {
        let palette = context.palette
        let status = content.status
        if status != .active {
            let pill = ControlStatusPill()
            pill.apply(
                text: status == .paused ? String(localized: "Paused") : String(localized: "Archived"),
                tone: status == .paused ? palette.orange : palette.comment,
                emphasis: .tinted,
                palette: palette
            )
            return hugging(pill)
        }
        guard let next = content.next else { return nil }
        let soon = next.timeIntervalSince(context.now) < 3_600
        let today = context.calendar.isDate(next, inSameDayAs: context.now)
        // Under Tomorrow the heading names the day and the timing line its time.
        if !today, let tomorrow = context.calendar.date(byAdding: .day, value: 1, to: context.now),
           context.calendar.isDate(next, inSameDayAs: tomorrow) { return nil }
        return hugging(ControlRowViews.label(
            ScheduleCalendarText.nextRun(next, now: context.now, calendar: context.calendar),
            style: .subheadline, weight: soon ? .bold : .medium,
            color: today ? palette.ui.blue : palette.ui.fgDim, lines: 1
        ))
    }

    /// "✓ Done · $0.22 · Yesterday", in the calendar's outcome words, glyphs, and colours;
    /// "No recent runs" for a schedule the last two weeks hold no run of.
    private static func lastRun(_ content: Content, context: Context) -> UIView? {
        let palette = context.palette
        guard let item = content.last else {
            guard content.hasRuns else { return nil }
            return ControlRowViews.label(String(localized: "No recent runs"), style: .subheadline, color: palette.ui.comment, lines: 1)
        }
        let style = ScheduleCalendarOutcomeStyle(item.outcome, palette: palette)
        let font = UIFont.scaled(.subheadline)
        let text = NSMutableAttributedString(string: item.outcome.label, attributes: [
            .font: UIFont.scaled(.subheadline, .semibold), .foregroundColor: style.color,
        ])
        var rest: [String] = []
        if let cost = item.cost {
            let amount = SessionFormatting.costString(cost)
            rest.append(item.outcome.isActive ? String(localized: "\(amount) so far") : amount)
        }
        rest.append(ScheduleCalendarText.past(item.at, now: context.now, calendar: context.calendar))
        text.append(NSAttributedString(string: " · " + rest.joined(separator: " · "), attributes: [
            .font: font, .foregroundColor: palette.ui.fgDim,
        ]))
        let label = UILabel()
        label.attributedText = text
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = context.isAccessibilitySize ? 0 : 1
        label.lineBreakMode = .byTruncatingTail
        let glyph = ScheduleCalendarRowViews.glyph(style, palette: palette, textStyle: .subheadline)
        return ControlRowViews.stack([glyph, label], axis: .horizontal, spacing: 5, alignment: .center)
    }

    /// One sentence for VoiceOver: name, timing, next run, latest run, who and which model.
    static func spoken(_ content: Content, context: Context) -> String {
        var parts = [content.name, content.trigger.scheduleScreenTiming()]
        switch content.status {
        case .paused: parts.append(String(localized: "Paused"))
        case .archived: parts.append(String(localized: "Archived"))
        case .active:
            if let next = content.next {
                parts.append(String(localized: "next \(ScheduleCalendarText.spokenCountdown(to: next, now: context.now, calendar: context.calendar))"))
            }
        }
        if let item = content.last {
            var last = [String(localized: "last run \(item.outcome.spokenLabel)")]
            if let cost = item.cost { last.append(SessionFormatting.costString(cost)) }
            last.append(ScheduleCalendarText.past(item.at, now: context.now, calendar: context.calendar))
            parts += last
        }
        if let badge = content.badge { parts.append(badge.spoken) }
        if let model = content.model { parts.append(ScheduleCalendarRowViews.modelName(model)) }
        return parts.joined(separator: ", ")
    }

    private static func leading(_ view: UIView) -> UIView {
        ControlRowViews.stack([view, ControlRowViews.spacer()], axis: .horizontal, spacing: 0, alignment: .center)
    }

    private static func hugging(_ view: UIView) -> UIView {
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }
}
