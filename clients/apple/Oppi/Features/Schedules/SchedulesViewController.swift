import UIKit

/// The Schedules screen: a `List | Calendar` switch in the bar's title position over one
/// of two views of the same schedules, and the guided composer under both, so switching
/// keeps a draft.
///
/// Calendar is the default: the morning questions (did last night work, what needs me,
/// what runs next) matter more than the inventory, and the list is one tap away. The
/// choice holds for the rest of the app session. A server without
/// `capabilities.scheduleCalendar` shows only the list, with no switch.
///
/// The list keeps its status filter; the calendar shows every past run, paused and
/// archived schedules' included, so the filter leaves the bar and Today takes its place.
@MainActor
final class SchedulesViewController: UIViewController {
    enum Mode: Int {
        case list
        case calendar
    }

    /// The mode chosen this app session.
    private static var chosenMode = Mode.calendar

    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    private let root: AppRootEnvironment
    let list: ScheduleListViewController
    private let composer: GuidedControlComposerController
    private let modeControl = UISegmentedControl(items: [
        String(localized: "List"),
        String(localized: "Calendar"),
    ])
    private let todayItem = UIBarButtonItem()
    private var sidebarToggle: UIBarButtonItem?
    /// The calendar for the connection it was made for; replaced with the connection.
    private var calendar: (connection: ObjectIdentifier, day: ScheduleCalendarDayViewController)?
    private var listError: String?
    private var calendarError: String?

    init(root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        list = ScheduleListViewController(root: root)
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
            guard let self, let mode = Mode(rawValue: modeControl.selectedSegmentIndex) else { return }
            Self.chosenMode = mode
            setNeedsUpdateProperties()
        }, for: .valueChanged)
        todayItem.title = String(localized: "Today")
        todayItem.accessibilityIdentifier = "schedules.calendar.today"
        todayItem.primaryAction = UIAction(title: String(localized: "Today")) { [weak self] _ in
            self?.calendar?.day.model.showToday()
        }
        list.onActionErrorChange = { [weak self] message in
            self?.listError = message
            self?.setNeedsUpdateProperties()
        }
        list.openSchedule = { [weak self] scheduleId in self?.openSchedule(scheduleId) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var connection: ServerConnection { root.coordinator.activeConnection }

    /// The mode on screen: the chosen one where the server has a calendar.
    var mode: Mode { connection.scheduleCalendarAvailable ? Self.chosenMode : .list }

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
        if let scrollView = shownScrollView { composer.insetContent(of: scrollView) }
    }

    private var shownScrollView: UIScrollView? {
        switch mode {
        case .list: list.collectionView
        case .calendar: calendar?.day.collectionView
        }
    }

    override func updateProperties() {
        super.updateProperties()
        let mode = mode
        let available = connection.scheduleCalendarAvailable
        let palette = root.themeStore.activeThemeID.palette
        view.backgroundColor = palette.ui.bg
        let child: UIViewController = mode == .calendar ? calendarDay() : list
        show(child)
        if mode == .calendar {
            // A client installed after a first load failed for want of one loads again. A
            // load that failed for any other reason waits for Retry.
            calendar?.day.model.clientAvailable(connection.apiClient != nil)
        }
        modeControl.selectedSegmentIndex = mode.rawValue
        navigationItem.titleView = available ? modeControl : nil
        ListScreen.setBarItems(
            trailing: mode == .calendar ? [todayItem] : [list.filterItem],
            leading: sidebarItems(),
            on: navigationItem
        )
        composer.setScreenError(mode == .calendar ? calendarError : listError, identifier: "schedules.error")
        view.setNeedsLayout()
    }

    /// The Day agenda for the active connection, made again when the connection changes.
    private func calendarDay() -> ScheduleCalendarDayViewController {
        let connection = connection
        let id = ObjectIdentifier(connection)
        if let calendar, calendar.connection == id { return calendar.day }
        let model = ScheduleCalendarModel { from, to in
            guard let apiClient = connection.apiClient else {
                throw LoadFailure.noConnection(connection.availability)
            }
            return try await apiClient.scheduleCalendar(from: from, to: to)
        }
        let day = ScheduleCalendarDayViewController(
            root: root,
            connection: connection,
            model: model,
            reportError: { [weak self] message in
                self?.calendarError = message
                self?.setNeedsUpdateProperties()
            },
            openSchedule: { [weak self] scheduleId in self?.openSchedule(scheduleId) }
        )
        if let old = calendar?.day, old.parent != nil { remove(old) }
        calendar = (id, day)
        return day
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
            self?.calendar?.day.model.reload()
        }
        Router.push(detail, from: self)
    }
}
