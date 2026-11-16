import UIKit

/// The Schedules screen: a switch in the bar's title position over the views of the same
/// schedules, and the guided composer under all of them, so switching keeps a draft.
///
/// Wide (`AdaptiveWidth.isWide`): `List | Day | Week | Month`, one control the way iPad
/// Calendar puts Day, Week, and Month in its toolbar. At accessibility text sizes Week leaves
/// it (a grid cannot hold that text) and `List | Day | Month` remains. Compact: `List |
/// Calendar`; the Calendar is the Day agenda, whose month title opens Month, and Month's day
/// title opens the Day again. iPhone has no Week: seven columns of about 50 pt hold no titles,
/// and the Day's week strip is the iOS Calendar answer at that width.
///
/// The Day is the default: the morning questions (did last night work, what needs me, what
/// runs next) matter more than the inventory, and the list is one tap away. The choice holds
/// for the rest of the app session. A server without `capabilities.scheduleCalendar` shows
/// only the list, with no switch.
///
/// The list keeps its status filter; the calendar shows every past run, paused and archived
/// schedules' included, so the filter leaves the bar and Today takes its place, with `‹ ›`
/// on wide layouts.
@MainActor
final class SchedulesViewController: UIViewController {
    enum Mode: Equatable {
        case list
        case day
        case week
        case month
    }

    /// The mode chosen this app session.
    private static var chosenMode = Mode.day

    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    private let root: AppRootEnvironment
    let list: ScheduleListViewController
    private let composer: GuidedControlComposerController
    private let agents = ScheduleAgentDirectory()
    private let modeControl = UISegmentedControl()
    /// The modes the switch offers now, by segment.
    private var segments: [Mode] = []
    private let todayItem = UIBarButtonItem()
    private let previousItem = UIBarButtonItem()
    private let nextItem = UIBarButtonItem()
    private var sidebarToggle: UIBarButtonItem?
    /// The calendar views for the connection they were made for; replaced with the connection.
    private var calendar: CalendarViews?
    private var listError: String?
    private var calendarError: String?
    private var hasAppeared = false

    /// One connection's calendar: one model shared by the Day, the Week, and the Month.
    private struct CalendarViews {
        let connection: ObjectIdentifier
        let model: ScheduleCalendarModel
        let day: ScheduleCalendarDayViewController
        let week: ScheduleCalendarWeekViewController
        let month: ScheduleCalendarMonthViewController
    }

    init(root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        list = ScheduleListViewController(root: root, agents: agents)
        composer = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .schedules,
                intent: .create,
                placeholder: "Describe what should happen and when…"
            ),
            root: root
        )
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Schedules")
        navigationItem.largeTitleDisplayMode = .never
        traitOverrides.appRootEnvironment = root
        modeControl.accessibilityIdentifier = "schedules.mode"
        modeControl.accessibilityLabel = String(localized: "Schedules view")
        modeControl.addAction(UIAction { [weak self] _ in
            guard let self, segments.indices.contains(modeControl.selectedSegmentIndex) else { return }
            choose(segments[modeControl.selectedSegmentIndex])
        }, for: .valueChanged)
        todayItem.title = String(localized: "Today")
        todayItem.accessibilityIdentifier = "schedules.calendar.today"
        todayItem.primaryAction = UIAction(title: String(localized: "Today")) { [weak self] _ in
            self?.calendar?.model.showToday()
        }
        previousItem.image = UIImage(systemName: "chevron.backward")
        previousItem.accessibilityIdentifier = "schedules.calendar.previous"
        previousItem.primaryAction = UIAction(image: UIImage(systemName: "chevron.backward")) { [weak self] _ in
            self?.step(-1)
        }
        nextItem.image = UIImage(systemName: "chevron.forward")
        nextItem.accessibilityIdentifier = "schedules.calendar.next"
        nextItem.primaryAction = UIAction(image: UIImage(systemName: "chevron.forward")) { [weak self] _ in
            self?.step(1)
        }
        list.onActionErrorChange = { [weak self] message in
            self?.listError = message
            self?.setNeedsUpdateProperties()
        }
        list.openSchedule = { [weak self] scheduleId in self?.openSchedule(scheduleId) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var connection: ServerConnection { root.windowConnectionOrStandIn }

    private var isAccessibilitySize: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    /// The mode on screen: the chosen one as this width and text size can show it, where the
    /// server has a calendar.
    var mode: Mode {
        guard connection.scheduleCalendarAvailable else { return .list }
        let chosen = Self.chosenMode
        if chosen == .week, !AdaptiveWidth.isWide(traitCollection) || isAccessibilitySize { return .day }
        return chosen
    }

    private func choose(_ mode: Mode) {
        Self.chosenMode = mode
        setNeedsUpdateProperties()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        composer.install(in: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        agents.load(connection.apiClient, refresh: true)
        // Back on screen (from a pushed detail, another tab), the list reads again. A switch
        // between the list and a calendar view is not an appearance of this screen, so it
        // shows what is loaded.
        if hasAppeared, mode == .list { list.setNeedsLoad() }
        hasAppeared = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let scrollView = shownScrollView { composer.insetContent(of: scrollView) }
    }

    private var shownScrollView: UIScrollView? {
        switch mode {
        case .list: list.collectionView
        case .day: calendar?.day.collectionView
        case .week: calendar?.week.scrollView
        case .month: calendar.flatMap { $0.month.showsAgenda ? $0.month.collectionView : nil }
        }
    }

    override func updateProperties() {
        super.updateProperties()
        let mode = mode
        let available = connection.scheduleCalendarAvailable
        let wide = AdaptiveWidth.isWide(traitCollection)
        let palette = root.themeStore.activeThemeID.palette
        view.backgroundColor = palette.ui.bg
        // The Agents rows name, once the connection has a client; appearing reads them again.
        if available { agents.load(connection.apiClient, refresh: false) }

        let child: UIViewController
        if mode == .list {
            child = list
        } else {
            let views = calendarViews()
            views.model.span = mode == .month ? .month : .week
            // A client installed after a first load failed for want of one loads again. A
            // load that failed for any other reason waits for Retry.
            views.model.clientAvailable(connection.apiClient != nil)
            child = switch mode {
            case .week: views.week
            case .month: views.month
            default: views.day
            }
        }
        show(child)

        applySegments(wide: wide, mode: mode)
        navigationItem.titleView = available ? modeControl : nil
        // Trailing items run right to left: "Today ‹ ›".
        let calendarItems = wide ? [nextItem, previousItem, todayItem] : [todayItem]
        ListScreen.setBarItems(
            trailing: mode == .list ? [list.filterItem] : calendarItems,
            leading: sidebarItems(),
            on: navigationItem
        )
        previousItem.accessibilityLabel = Self.stepLabel(mode, forward: false)
        nextItem.accessibilityLabel = Self.stepLabel(mode, forward: true)
        composer.setScreenError(mode == .list ? listError : calendarError, identifier: "schedules.error")
        view.setNeedsLayout()
    }

    /// `List | Day | Week | Month` wide (no Week at accessibility sizes), `List | Calendar`
    /// compact, rebuilt only when that set changes.
    private func applySegments(wide: Bool, mode: Mode) {
        let wanted: [Mode] = !wide ? [.list, .day] : isAccessibilitySize ? [.list, .day, .month] : [.list, .day, .week, .month]
        if wanted != segments {
            segments = wanted
            modeControl.removeAllSegments()
            for (index, segment) in wanted.enumerated() {
                let title = switch segment {
                case .list: String(localized: "List")
                case .day: wide ? Self.dayTitle : Self.calendarTitle
                case .week: String(localized: "Week")
                case .month: String(localized: "Month")
                }
                modeControl.insertSegment(withTitle: title, at: index, animated: false)
            }
        }
        // Compact, Month is the Calendar too.
        let shown: Mode = !wide && mode == .month ? .day : mode
        modeControl.selectedSegmentIndex = segments.firstIndex(of: shown) ?? 0
    }

    private static let dayTitle = String(localized: "Day")
    private static let calendarTitle = String(localized: "Calendar")

    private static func stepLabel(_ mode: Mode, forward: Bool) -> String {
        let (next, previous) = switch mode {
        case .week: (String(localized: "Next Week"), String(localized: "Previous Week"))
        case .month: (String(localized: "Next Month"), String(localized: "Previous Month"))
        default: (String(localized: "Next Day"), String(localized: "Previous Day"))
        }
        return forward ? next : previous
    }

    /// `‹ ›`: a day, a week, or a month, as the view shows.
    private func step(_ direction: Int) {
        guard let model = calendar?.model else { return }
        switch mode {
        case .week: model.step(days: 7 * direction)
        case .month: model.step(months: direction)
        default: model.step(days: direction)
        }
    }

    /// The calendar views for the active connection, made again when the connection changes.
    private func calendarViews() -> CalendarViews {
        let connection = connection
        let id = ObjectIdentifier(connection)
        if let calendar, calendar.connection == id { return calendar }
        let model = ScheduleCalendarModel(cache: connection.scheduleCalendarCache) { from, to in
            guard let apiClient = connection.apiClient else {
                throw LoadFailure.noConnection(connection.availability)
            }
            return try await apiClient.scheduleCalendar(from: from, to: to)
        }
        func actions() -> ScheduleCalendarActions {
            let actions = ScheduleCalendarActions(
                root: root,
                connection: connection,
                model: model,
                reportError: { [weak self] message in
                    self?.calendarError = message
                    self?.setNeedsUpdateProperties()
                },
                openSchedule: { [weak self] scheduleId in self?.openSchedule(scheduleId) }
            )
            // A schedule made for a calendar event joins the list too.
            actions.onScheduleCreated = { [weak self] in self?.list.setNeedsLoad() }
            return actions
        }
        let day = ScheduleCalendarDayViewController(root: root, connection: connection, model: model, actions: actions(), agents: agents)
        day.onTitleTap = { [weak self] in self?.choose(.month) }
        let week = ScheduleCalendarWeekViewController(
            root: root, connection: connection, model: model, actions: actions(), agents: agents
        ) { [weak self, weak model] date in
            model?.select(date)
            self?.choose(.day)
        }
        let monthAgenda = ScheduleCalendarDayViewController(
            root: root, connection: connection, model: model, actions: actions(), agents: agents, showsWeekStrip: false
        )
        monthAgenda.onTitleTap = { [weak self] in self?.choose(.day) }
        let month = ScheduleCalendarMonthViewController(root: root, connection: connection, model: model, agenda: monthAgenda)
        month.onPickDay = { [weak self] in self?.choose(.day) }
        if let old = calendar {
            for view in [old.day, old.week, old.month] as [UIViewController] where view.parent === self { remove(view) }
        }
        let views = CalendarViews(connection: id, model: model, day: day, week: week, month: month)
        calendar = views
        return views
    }

    /// Puts `child` under the composer, in place of the other view.
    private func show(_ child: UIViewController) {
        guard child.parent !== self else { return }
        for other in children where other !== composer { remove(other) }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(child.view, at: 0)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }

    private func remove(_ child: UIViewController) {
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }

    /// The sidebar toggle at the split detail root.
    private func sidebarItems() -> [UIBarButtonItem] {
        guard showsSidebarToggle else { return [] }
        let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
        sidebarToggle = toggle
        WorkspaceSplitSidebarToggle.sync(toggle, root: root)
        return [toggle]
    }

    /// The pushed detail reports changes back: the list takes the new summary and the
    /// calendar reads its range again.
    private func openSchedule(_ scheduleId: String) {
        let detail = ScheduleDetailViewController(root: root, scheduleId: scheduleId) { [weak self] updated in
            self?.list.scheduleChanged(updated)
            self?.calendar?.model.reload()
        }
        Router.push(detail, from: self)
    }
}
