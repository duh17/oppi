import UIKit

/// The Schedules calendar's Day agenda, on every width: the month and week strip, the
/// day's one-line summary, the overnight band (clean runs folded into one row), each
/// run by start time with its outcome, the now line, and countdowns to what runs next.
///
/// Tapping a past or running run opens its session; tapping an occurrence still to come
/// opens its schedule. A run that launched subagents has their strip under it, which opens
/// the run's thread in All Sessions. A long press offers Run Now, Pause Schedule, Show Schedule, and
/// Last Run's Session, and VoiceOver offers the same as custom actions (`ScheduleCalendarActions`).
/// A horizontal swipe across the day pages to the next or previous day, and the week strip
/// follows.
///
/// With the Calendar Events experiment on, the day's events from this device's calendar sit
/// between the runs by time (all-day ones first), drawn as neutral context
/// (`ScheduleCalendarEventViews`); a tap or a long press offers Schedule Agent…. When the
/// experiment is on but calendar access was refused, one row says so and opens Settings.
///
/// Month embeds it with `showsWeekStrip` false: the selected day's title, summary, and runs.
///
/// The container (`SchedulesViewController`) owns the model, the composer, and the bar.
@MainActor
final class ScheduleCalendarDayViewController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    enum Section: Hashable { case summary, calendarAccess, allDay, night, day, more }

    enum ID: Hashable {
        /// The day's summary, a row only at accessibility sizes (else it sits in the header).
        case summary
        case band
        case cluster(String)
        case entry(String)
        /// The subagents strip under the entry with this id.
        case subagents(String)
        case now
        /// "More runs not shown": the server listed only part of a dense schedule's runs.
        case truncated
        /// A calendar event, by its id.
        case event(String)
        case allDayEvent(String)
        /// Calendar Events is on but the calendar cannot be read.
        case calendarAccess
    }

    /// What a row draws, keyed so that only a changed row redraws.
    private enum RowData {
        case summary(ScheduleCalendarAgenda.Summary)
        case band
        case cluster(ScheduleCalendarAgenda.Cluster)
        case entry(ScheduleCalendarAgenda.Item, showsTime: Bool, isNext: Bool)
        case subagents(ScheduleCalendarAgenda.Item, SessionThreadStripSummary)
        case now(Date)
        case truncated([String])
        case event(ScheduleCalendarEvent, at: Date)
        case allDayEvent(ScheduleCalendarEvent)
        case calendarAccess
    }

    let model: ScheduleCalendarModel
    private let root: AppRootEnvironment
    private let connection: ServerConnection
    private let actions: ScheduleCalendarActions
    private let agents: ScheduleAgentDirectory
    /// Tapping the header's title: the Day's month title opens Month; Month's day title
    /// opens the Day. Nil leaves the title plain.
    var onTitleTap: (() -> Void)? {
        get { header.onTitleTap }
        set { header.onTitleTap = newValue; setNeedsUpdateProperties() }
    }

    private let header: ScheduleCalendarHeaderView
    /// The horizontal swipe that pages days.
    private let dayPan = UIPanGestureRecognizer()
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()
    private let stateView = UIContentUnavailableView(loadState: .loading(nil))
    private var rows: [ID: RowData] = [:]
    private var rowInputs: [ID: AnyHashable] = [:]
    private var summaryKey: AnyHashable?
    private var agenda: ScheduleCalendarAgenda?
    private var badges = ScheduleRowBadges(workspaces: [], agents: [])
    private let ticker = ScheduleCalendarMinuteTicker()
    /// The day the list last scrolled to on its own, so a redraw never moves it again.
    private var scrolledDay: String?

    init(
        root: AppRootEnvironment,
        connection: ServerConnection,
        model: ScheduleCalendarModel,
        actions: ScheduleCalendarActions,
        agents: ScheduleAgentDirectory,
        showsWeekStrip: Bool = true
    ) {
        self.root = root
        self.connection = connection
        self.model = model
        self.actions = actions
        self.agents = agents
        header = ScheduleCalendarHeaderView(showsWeekStrip: showsWeekStrip)
        header.titleHint = showsWeekStrip ? String(localized: "Shows the month") : String(localized: "Shows the day with its week")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var calendar: Calendar { model.calendar }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = header.showsWeekStrip ? "schedules.calendar" : "schedules.calendar.monthAgenda"
        actions.presenter = self
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onSelect = { [weak self] day in self?.model.select(day) }
        header.onStep = { [weak self] days in self?.model.step(days: days) }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "schedules.calendar.list"
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            // The spinner stays until the answer lands or fails.
            Task { @MainActor in
                await self?.model.refresh()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
        dayPan.addTarget(self, action: #selector(handleDayPan(_:)))
        dayPan.delegate = self
        collectionView.addGestureRecognizer(dayPan)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.accessibilityIdentifier = "schedules.calendar.state"
        // It fills the list's region; it never sizes the header above it.
        stateView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
        stateView.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        view.addSubview(collectionView)
        view.addSubview(stateView)
        view.addSubview(header)
        NSLayoutConstraint.activate(
            [
                header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                collectionView.topAnchor.constraint(equalTo: header.bottomAnchor),
                collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                stateView.topAnchor.constraint(equalTo: collectionView.topAnchor),
                stateView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
                stateView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
                stateView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            ] + ReadableContentWidth.constrain(header, to: view)
        )
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        model.appear()
        ticker.start(model)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        alignHeaderToRows()
    }

    /// The header's text starts and ends on the rows' edges at every width. The header is
    /// the readable column, centered in the safe area; the rows are inset by the list's
    /// layout, which beside an iPad's sidebar is not the same origin. Measured from a row
    /// as it is laid out; a day with no rows keeps the last measure.
    private func alignHeaderToRows() {
        guard let indexPath = collectionView.indexPathsForVisibleItems.first,
              let row = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let frame = collectionView.convert(row.frame, to: view)
        let insets = (left: max(0, frame.minX - header.frame.minX), right: max(0, header.frame.maxX - frame.maxX))
        if abs(header.edgeInsets.left - insets.left) > 0.5 || abs(header.edgeInsets.right - insets.right) > 0.5 {
            header.edgeInsets = insets
        }
    }

    /// The rows' inset from the list's sides: 16 pt, or what centers the readable column.
    private static func rowInset(width: CGFloat) -> CGFloat {
        max(16, (width - ReadableContentWidth.column) / 2)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ticker.stop()
    }

    // MARK: - Drawing

    override func updateProperties() {
        super.updateProperties()
        // Every observed value is read before any return (the pass tracks only what it reads).
        let palette = palette
        let response = model.response
        let now = model.now
        let selected = model.selectedDay
        let expanded = model.expandedClusters
        let failure = model.failure
        let isLoaded = response != nil && model.isSelectedDayLoaded
        let isAccessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let live = Self.liveSessions(for: response, sessionStore: connection.sessionStore)
        badges = ScheduleRowBadges(workspaces: connection.workspaceStore.workspaces, agents: agents.agents)
        _ = EntityIcon.loadGeneration
        let events = events(on: selected)
        let calendarDenied = root.deviceCalendar.isDenied(settings: root.settings)

        view.backgroundColor = palette.ui.bg
        let agenda = model.agenda(live: live)
        self.agenda = agenda
        header.apply(
            .init(
                week: model.week,
                selected: selected,
                today: now,
                health: model.week.map { agenda?.health(on: $0, calendar: calendar) ?? .init() },
                isAccessibilitySize: isAccessibilitySize
            ),
            calendar: calendar,
            palette: palette
        )
        // A day the answer does not cover (another week on its way) draws nothing of the
        // old answer's.
        let shown = isLoaded ? agenda : nil
        applySummary(agenda: shown, day: selected, now: now, isAccessibilitySize: isAccessibilitySize)
        let isEmpty = applyRows(
            agenda: shown, day: selected, now: now, expanded: expanded, isAccessibilitySize: isAccessibilitySize,
            events: isLoaded ? events : ([], []), calendarDenied: calendarDenied
        )
        applyState(isLoaded: isLoaded, hasSchedules: response?.schedules.isEmpty == false, isEmpty: isEmpty, failure: failure)
    }

    /// `day`'s events from this device's calendar; none while the experiment is off.
    private func events(on day: Date) -> (allDay: [ScheduleCalendarEvent], timed: [ScheduleCalendarEvent]) {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let events = root.deviceCalendar.events(in: DateInterval(start: start, end: end), settings: root.settings)
        return ScheduleCalendarEvent.on(day, in: events, calendar: calendar)
    }

    /// The app's live copy of the sessions the answer names: running and blocked changes
    /// reach it through the app event stream before the next fetch.
    static func liveSessions(for response: ScheduleCalendarResponse?, sessionStore: SessionStore) -> [String: Session] {
        let followed = Set(response?.entries.flatMap { entry -> [String] in
            guard let session = entry.run?.session else { return [] }
            return [session.id] + session.descendants.map(\.id)
        } ?? [])
        guard !followed.isEmpty else { return [:] }
        var live: [String: Session] = [:]
        for session in sessionStore.listProjectionSessions where followed.contains(session.id) {
            live[session.id] = session
        }
        return live
    }

    /// "Today ✓5 ▦1 ⚠1 ?1 … $10.84 so far", redrawn only when it changes.
    private func applySummary(agenda: ScheduleCalendarAgenda?, day: Date, now: Date, isAccessibilitySize: Bool) {
        let summary = agenda.map { $0.summary(on: day, calendar: calendar) }
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let key = AnyHashable([AnyHashable(summary), AnyHashable(isToday), AnyHashable(isAccessibilitySize), AnyHashable(palette.ui.bg)])
        guard key != summaryKey else { return }
        summaryKey = key
        // At accessibility sizes the summary is the list's first row, so it scrolls away.
        guard let summary, !summary.isEmpty, !isAccessibilitySize else {
            header.setSummary(nil, label: nil)
            return
        }
        let title = isToday ? String(localized: "Today") : day.formatted(.dateTime.weekday(.wide))
        header.setSummary(
            ScheduleCalendarRowViews.summary(summary, dayTitle: title, isToday: isToday, context: context(for: nil)),
            label: Self.spokenSummary(summary, dayTitle: title, isToday: isToday)
        )
    }

    /// Draws `day`'s rows; true when it has none.
    private func applyRows(
        agenda: ScheduleCalendarAgenda?,
        day: Date,
        now: Date,
        expanded: Set<String>,
        isAccessibilitySize: Bool,
        events: (allDay: [ScheduleCalendarEvent], timed: [ScheduleCalendarEvent]),
        calendarDenied: Bool
    ) -> Bool {
        var snapshot = NSDiffableDataSourceSnapshot<Section, ID>()
        let sessionStore = connection.sessionStore
        // The list's own classification of a subagent, pending asks included, as its thread strip reads it.
        let classify: (Session) -> SessionListClassification = { session in
            SessionListPresentation.classify(
                session, attention: SessionListAttentionCounts(askCount: sessionStore.listPendingAskCount(for: session.id))
            )
        }
        var rows: [ID: RowData] = [:]
        var inputs: [ID: AnyHashable] = [:]
        let palette = palette
        func add(_ id: ID, _ data: RowData, to section: Section, key: AnyHashable) {
            snapshot.appendItems([id], toSection: section)
            rows[id] = data
            inputs[id] = AnyHashable([
                key, AnyHashable(palette.ui.bg), AnyHashable(isAccessibilitySize),
                AnyHashable(AdaptiveWidth.isWide(traitCollection)), AnyHashable(EntityIcon.loadGeneration),
            ])
        }

        if calendarDenied {
            snapshot.appendSections([.calendarAccess])
            add(.calendarAccess, .calendarAccess, to: .calendarAccess, key: AnyHashable(0))
        }
        if agenda != nil, !events.allDay.isEmpty {
            snapshot.appendSections([.allDay])
            for event in events.allDay {
                add(.allDayEvent(event.id), .allDayEvent(event), to: .allDay, key: AnyHashable(event))
            }
        }
        if let agenda, !agenda.items(on: day, calendar: calendar).isEmpty || !events.timed.isEmpty {
            let (night, later) = agenda.rows(on: day, now: now, calendar: calendar, expandedClusters: expanded, events: events.timed)
            let nextTime = agenda.nextUpcomingTime(after: now)
            if isAccessibilitySize {
                let summary = agenda.summary(on: day, calendar: calendar)
                snapshot.appendSections([.summary])
                add(.summary, .summary(summary), to: .summary, key: AnyHashable([
                    AnyHashable(summary), AnyHashable(calendar.isDate(day, inSameDayAs: now)),
                ]))
            }
            var previousTime: Date?
            func addRows(_ list: [ScheduleCalendarAgenda.Row], to section: Section) {
                for row in list {
                    switch row {
                    case .entry(let item):
                        let showsTime = isAccessibilitySize || previousTime.map {
                            !calendar.isDate($0, equalTo: item.at, toGranularity: .minute)
                        } ?? true
                        previousTime = item.at
                        // A row that counts time redraws each minute; others only when they change.
                        let ticking = item.outcome == .upcoming || item.outcome.isActive
                        // Runs due at the same next minute are all next.
                        let isNext = item.outcome == .upcoming && item.at == nextTime
                        add(.entry(item.id), .entry(item, showsTime: showsTime, isNext: isNext), to: section, key: AnyHashable([
                            AnyHashable(item), AnyHashable(showsTime), AnyHashable(isNext),
                            AnyHashable(ticking ? now : .distantPast),
                        ]))
                        if item.sessionId != nil, !item.subagents.isEmpty {
                            let summary = SessionThreadStripSummary(descendants: item.subagents.sessions, classify: classify)
                            add(.subagents(item.id), .subagents(item, summary), to: section, key: AnyHashable([
                                AnyHashable(item.subagents), AnyHashable(summary.dots), AnyHashable(summary.text),
                            ]))
                        }
                    case .cluster(let cluster):
                        previousTime = cluster.items.first?.at
                        add(.cluster(cluster.id), .cluster(cluster), to: section, key: AnyHashable(cluster))
                    case .event(let event, let at):
                        previousTime = at
                        add(.event(event.id), .event(event, at: at), to: section, key: AnyHashable([AnyHashable(event), AnyHashable(at)]))
                    case .now(let date):
                        add(.now, .now(date), to: section, key: AnyHashable(date))
                    }
                }
            }
            if !night.isEmpty {
                snapshot.appendSections([.night])
                add(.band, .band, to: .night, key: AnyHashable(0))
                addRows(night, to: .night)
            }
            if !later.isEmpty {
                snapshot.appendSections([.day])
                addRows(later, to: .day)
            }
        }
        let truncated = agenda?.truncatedSchedules(on: day, now: now, calendar: calendar) ?? []
        if !truncated.isEmpty {
            snapshot.appendSections([.more])
            add(.truncated, .truncated(truncated), to: .more, key: AnyHashable(truncated))
        }

        let changed = inputs.compactMap { id, key in rowInputs[id].flatMap { $0 != key ? id : nil } }
        snapshot.reconfigureItems(changed.filter { snapshot.indexOfItem($0) != nil })
        self.rows = rows
        rowInputs = inputs
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.scrollToNowIfNeeded(day: day, now: now)
            self?.alignHeaderToRows()
        }
        return rows.isEmpty
    }

    /// On opening a day: today puts the now line about a third of the way down, so the
    /// night and the next runs both show; another day starts at its top.
    private func scrollToNowIfNeeded(day: Date, now: Date) {
        let key = ScheduleCalendarAgenda.dayKey(day, calendar: calendar)
        guard scrolledDay != key, !rows.isEmpty else { return }
        scrolledDay = key
        collectionView.layoutIfNeeded()
        guard calendar.isDate(day, inSameDayAs: now),
              let indexPath = dataSource.indexPath(for: .now),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
            return
        }
        let visible = collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom
        let maxOffset = max(-collectionView.adjustedContentInset.top, collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
        let top = collectionView.adjustedContentInset.top
        var target = min(maxOffset, max(-top, attributes.frame.minY - visible / 3))
        // Rest on a row's top edge: a row cut by the header shows only the tip of its rail.
        if let cut = collectionView.indexPathForItem(at: CGPoint(x: collectionView.bounds.midX, y: target + top)),
           let row = collectionView.layoutAttributesForItem(at: cut) {
            target = max(-top, row.frame.minY - top - 4)
        }
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    /// Loading, failed with one Retry, or empty, over the list. A refresh that fails with
    /// runs on screen keeps them. A day the answer does not cover is loading or failed,
    /// never empty: nothing is known about it yet.
    private func applyState(isLoaded: Bool, hasSchedules: Bool, isEmpty: Bool, failure: String?) {
        let state: LoadState?
        if !isLoaded {
            if let failure {
                state = .failed(
                    title: String(localized: "Couldn't Load the Calendar"),
                    message: failure,
                    retry: RetryAction { [weak self] in self?.model.reload() }
                )
            } else {
                state = .loading(String(localized: "Loading calendar…"))
            }
        } else if isEmpty {
            let isToday = model.isShowingToday
            state = .empty(
                title: String(localized: "No Runs This Day"),
                systemImage: "calendar",
                message: !hasSchedules && isToday
                    ? String(localized: "Describe what should happen and when below.")
                    : nil
            )
        } else {
            state = nil
        }
        stateView.isHidden = state == nil
        if let state {
            stateView.configuration = UIContentUnavailableConfiguration.loadState(state, palette: palette, background: palette.ui.bg)
            stateView.accessibilityValue = switch state {
            case .failed: "failed"
            case .loading: "loading"
            default: "empty"
            }
        }
    }

    // MARK: - List

    private func makeLayout() -> UICollectionViewLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            let width = environment.container.effectiveContentSize.width
            let side = Self.rowInset(width: width)
            section.interGroupSpacing = 4
            let kind = self.flatMap { $0.dataSource.sectionIdentifier(for: index) }
            switch kind {
            case .night:
                section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: side, bottom: 10, trailing: side)
                let band = NSCollectionLayoutDecorationItem.background(elementKind: ScheduleCalendarBandBackground.kind)
                band.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: side, bottom: 0, trailing: side)
                section.decorationItems = [band]
            default:
                section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: side, bottom: 24, trailing: side)
            }
            return section
        }
        layout.register(ScheduleCalendarBandBackground.self, forDecorationViewOfKind: ScheduleCalendarBandBackground.kind)
        return layout
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, ID> {
        let registration = UICollectionView.CellRegistration<ScheduleCalendarCell, ID> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        return UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    private func context(for item: ScheduleCalendarAgenda.Item?, showsTime: Bool = true, isNext: Bool = false) -> ScheduleCalendarRowContext {
        ScheduleCalendarRowContext(
            palette: palette,
            now: model.now,
            calendar: calendar,
            badge: item.flatMap { badges.badge(workspaceId: $0.workspaceId, agentId: $0.agentId) },
            assetCache: connection.iconAssetCache,
            isAccessibilitySize: traitCollection.preferredContentSizeCategory.isAccessibilityCategory,
            showsTime: showsTime,
            isNext: isNext,
            isWide: AdaptiveWidth.isWide(traitCollection)
        )
    }

    private func configure(_ cell: ScheduleCalendarCell, id: ID) {
        guard let data = rows[id] else { return }
        let palette = palette
        cell.reset()
        switch data {
        case .summary(let summary):
            let isToday = model.isShowingToday
            let title = isToday ? String(localized: "Today") : model.selectedDay.formatted(.dateTime.weekday(.wide))
            let context = context(for: nil)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                ScheduleCalendarRowViews.summary(summary, dayTitle: title, isToday: isToday, context: context)
            }
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = Self.spokenSummary(summary, dayTitle: title, isToday: isToday)
            cell.accessibilityIdentifier = "schedules.calendar.summary"
        case .band:
            let context = context(for: nil)
            let range = Self.bandRange(calendar: calendar)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 0, trailing: 0)) {
                ScheduleCalendarRowViews.bandHeader(context: context, range: range)
            }
            cell.isAccessibilityElement = true
            cell.accessibilityTraits = .header
            cell.accessibilityLabel = String(localized: "Overnight, \(range)")
        case .cluster(let cluster):
            let context = context(for: nil)
            let icons = Self.unique(cluster.items.compactMap { badges.badge(workspaceId: $0.workspaceId, agentId: $0.agentId) })
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 8, leading: 0, bottom: 8, trailing: 0)) {
                ScheduleCalendarRowViews.cluster(cluster, badges: icons, context: context)
            }
            cell.isAccessibilityElement = true
            cell.accessibilityTraits = .button
            cell.accessibilityLabel = Self.spokenCluster(cluster)
            cell.accessibilityValue = cluster.isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
            cell.accessibilityHint = cluster.isExpanded ? String(localized: "Folds the runs") : String(localized: "Shows each run")
            cell.accessibilityIdentifier = "schedules.calendar.\(cluster.id)"
        case .entry(let item, let showsTime, let isNext):
            let context = context(for: item, showsTime: showsTime, isNext: isNext)
            let style = ScheduleCalendarOutcomeStyle(item.outcome, palette: palette)
            let quiet = item.outcome.isClean && !context.isAccessibilitySize
            cell.contentConfiguration = ControlViewContent(insets: .init(top: quiet ? 6 : 10, leading: 0, bottom: quiet ? 6 : 10, trailing: 0)) {
                ScheduleCalendarRowViews.entry(item, context: context)
            }
            if style.fillsRow {
                cell.fill = ScheduleCalendarOutcomeStyle.fill(style.color, palette: palette)
            }
            cell.isAccessibilityElement = true
            cell.accessibilityTraits = .button
            cell.accessibilityLabel = spokenEntry(item, context: context)
            cell.accessibilityHint = item.sessionId != nil
                ? String(localized: "Opens the session")
                : String(localized: "Opens the schedule")
            cell.accessibilityIdentifier = "schedules.calendar.entry.\(item.id)"
            // Built when VoiceOver asks, from the row as it is then: a schedule paused since
            // the row was drawn offers no Pause.
            cell.accessibilityCustomActionsBlock = { [weak self] in
                guard let self, case .entry(let item, _, _) = rows[id] else { return [] }
                return actions.accessibilityActions(for: item, agenda: agenda)
            }
        case .subagents(let item, let summary):
            let context = context(for: item)
            let style = SessionRowStyle.for(root.themeStore.activeThemeID)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 0, leading: 0, bottom: 6, trailing: 0)) {
                ScheduleCalendarRowViews.subagents(item.subagents, summary: summary, style: style, context: context)
            }
            cell.isAccessibilityElement = true
            cell.accessibilityTraits = .button
            cell.accessibilityLabel = Self.spokenSubagents(item.subagents, summary: summary)
            cell.accessibilityHint = String(localized: "Shows the run's sessions")
            cell.accessibilityIdentifier = "schedules.calendar.subagents.\(item.id)"
        case .now(let date):
            let calendar = calendar
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 2, leading: 0, bottom: 2, trailing: 0), followsLayoutMargins: false) {
                ScheduleCalendarRowViews.nowLine(date, calendar: calendar, palette: palette)
            }
            cell.isAccessibilityElement = false
            cell.accessibilityElementsHidden = true
        case .truncated(let names):
            let text = names.count == 1
                ? String(localized: "More runs of \(names[0]) are not shown.")
                : String(localized: "More runs of \(names.count) schedules are not shown.")
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                ControlRowViews.label(text, style: .footnote, color: palette.ui.fgDim)
            }
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = text
            cell.accessibilityIdentifier = "schedules.calendar.truncated"
        case .event(let event, let at):
            let context = context(for: nil)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 8, leading: 0, bottom: 8, trailing: 0)) {
                ScheduleCalendarEventViews.row(event, at: at, context: context)
            }
            configureEvent(cell, event)
        case .allDayEvent(let event):
            let context = context(for: nil)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 6, leading: 0, bottom: 6, trailing: 0)) {
                ScheduleCalendarEventViews.allDay(event, context: context)
            }
            configureEvent(cell, event)
        case .calendarAccess:
            let text = String(localized: "Calendar Events is on, but Oppi can't read your calendar. Allow access in Settings.")
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                ControlRowViews.label(text, style: .footnote, color: palette.ui.fgDim)
            }
            cell.isAccessibilityElement = true
            cell.accessibilityTraits = .button
            cell.accessibilityLabel = text
            cell.accessibilityHint = String(localized: "Opens Oppi in Settings")
            cell.accessibilityIdentifier = "schedules.calendar.calendarAccess"
        }
    }

    /// An event row: the neutral wash, one element, and Schedule Agent… for VoiceOver.
    private func configureEvent(_ cell: ScheduleCalendarCell, _ event: ScheduleCalendarEvent) {
        cell.fill = ScheduleCalendarEventViews.fill(palette)
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .button
        cell.accessibilityLabel = ScheduleCalendarEventViews.spoken(event, calendar: calendar)
        cell.accessibilityHint = String(localized: "Schedules an agent for this event")
        cell.accessibilityIdentifier = "schedules.calendar.event.\(event.id)"
        cell.accessibilityCustomActionsBlock = { [weak self] in
            self?.actions.eventAccessibilityActions(for: event) ?? []
        }
    }

    // MARK: - Words

    private func spokenEntry(_ item: ScheduleCalendarAgenda.Item, context: ScheduleCalendarRowContext) -> String {
        var parts = [item.name, item.at.formatted(date: .omitted, time: .shortened)]
        switch item.outcome {
        case .upcoming:
            parts.append(ScheduleCalendarText.spokenCountdown(to: item.at, now: context.now, calendar: calendar))
            parts.append(ScheduleCalendarRowViews.upcomingDescription(item))
        case .running, .starting:
            if let duration = item.duration(now: context.now) {
                parts.append(String(localized: "\(item.outcome.label) for \(ScheduleCalendarText.spokenDuration(duration, calendar: calendar))"))
            } else {
                parts.append(item.outcome.label)
            }
            if let cost = item.cost { parts.append(String(localized: "\(SessionFormatting.costString(cost)) so far")) }
        default:
            parts.append(item.outcome.spokenLabel)
            if let duration = item.duration(now: context.now) {
                parts.append(ScheduleCalendarText.spokenDuration(duration, calendar: calendar))
            }
            if let cost = item.cost { parts.append(SessionFormatting.costString(cost)) }
            if let reason = ScheduleCalendarRowViews.failureReason(item) { parts.append(reason) }
            if item.outcome.isNeedsYou, let question = item.sessionMessage { parts.append(question) }
        }
        if let badge = context.badge { parts.append(badge.spoken) }
        if let model = item.model { parts.append(ScheduleCalendarRowViews.modelName(model)) }
        return parts.joined(separator: ", ")
    }

    /// "26 subagents, 2 working · 24 stopped, $37.57".
    private static func spokenSubagents(_ subagents: ScheduleCalendarAgenda.Subagents, summary: SessionThreadStripSummary) -> String {
        var parts = [ScheduleCalendarRowViews.subagentCount(subagents.sessions.count), summary.text]
        if subagents.cost > 0 { parts.append(SessionFormatting.costString(subagents.cost)) }
        return parts.joined(separator: ", ")
    }

    private static func spokenCluster(_ cluster: ScheduleCalendarAgenda.Cluster) -> String {
        let names = cluster.items.map(\.name).formatted(.list(type: .and))
        if cluster.isUpcoming {
            return String(localized: "Overnight, \(cluster.items.count) runs: \(names)")
        }
        return String(localized: "Overnight, \(cluster.items.count) runs, all done, \(SessionFormatting.costString(cluster.totalCost)): \(names)")
    }

    private static func spokenSummary(_ summary: ScheduleCalendarAgenda.Summary, dayTitle: String, isToday: Bool) -> String {
        var parts = [dayTitle]
        if summary.done > 0 { parts.append(String(localized: "\(summary.done) done")) }
        if summary.running > 0 { parts.append(String(localized: "\(summary.running) running")) }
        if summary.failed > 0 { parts.append(String(localized: "\(summary.failed) failed")) }
        if summary.needsYou > 0 { parts.append(String(localized: "\(summary.needsYou) need you")) }
        if summary.upcoming > 0 { parts.append(String(localized: "\(summary.upcoming) upcoming")) }
        // A day with nothing run yet has no cost to say.
        if summary.hasRuns {
            let cost = SessionFormatting.costString(summary.cost)
            parts.append(isToday ? String(localized: "\(cost) so far") : cost)
        }
        return parts.joined(separator: ", ")
    }

    private static func bandRange(calendar: Calendar) -> String {
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(bySettingHour: ScheduleCalendarAgenda.nightBandEndHour, minute: 0, second: 0, of: start) ?? start
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateTemplate = "h a"
        return formatter.string(from: start, to: end)
    }

    private static func unique(_ badges: [ScheduleRowBadge]) -> [ScheduleRowBadge] {
        var seen = Set<ScheduleRowBadge>()
        return badges.filter { seen.insert($0).inserted }
    }

    // MARK: - Actions

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        activate(id)
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .entry, .cluster, .subagents, .event, .allDayEvent, .calendarAccess: true
        default: false
        }
    }

    /// What a tap does, resolved from the row's identifier when it runs.
    private func activate(_ id: ID) {
        switch rows[id] {
        case .cluster(let cluster):
            if model.expandedClusters.contains(cluster.id) {
                model.expandedClusters.remove(cluster.id)
            } else {
                model.expandedClusters.insert(cluster.id)
            }
        case .entry(let item, _, _):
            actions.open(item)
        case .subagents(let item, _):
            actions.openThread(of: item)
        case .event(let event, _), .allDayEvent(let event):
            actions.scheduleAgent(for: event)
        case .calendarAccess:
            DeviceCalendar.openSystemSettings(root.opener)
        default:
            break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let id = dataSource.itemIdentifier(for: indexPaths[0]) else { return nil }
        switch rows[id] {
        case .event(let event, _), .allDayEvent(let event):
            return actions.eventMenu(for: event, width: view.bounds.width)
        default:
            break
        }
        guard case .entry(let item, _, _) = rows[id] else { return nil }
        return actions.contextMenu(
            for: item,
            agenda: { [weak self] in self?.agenda },
            badge: badges.badge(workspaceId: item.workspaceId, agentId: item.agentId),
            width: view.bounds.width
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        // Tapping the preview does what tapping the row does.
        guard let id = configuration.identifier as? String else { return }
        let row: ID = rows[.event(id)] != nil ? .event(id) : rows[.allDayEvent(id)] != nil ? .allDayEvent(id) : .entry(id)
        animator.addCompletion { [weak self] in self?.activate(row) }
    }

    // MARK: - Day paging

    /// A horizontal drag only, from anywhere but the leading edge, where the drawer opens:
    /// a vertical one scrolls the day.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === dayPan else { return true }
        let x = touch.location(in: view).x
        return x > Self.edgeExclusion && x < view.bounds.width - Self.edgeExclusion
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dayPan else { return true }
        let velocity = dayPan.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y) * 1.5
    }

    /// The drawer's edge drag (`WorkspaceShellController`) and the back swipe keep their
    /// edges.
    private static let edgeExclusion: CGFloat = 32

    /// The day follows the finger; let go past a third of the width (or with a flick) and it
    /// slides off while the next or previous day slides in, and the week strip follows. The
    /// day can be any day: a new week loads like a tap on the strip's next week does.
    @objc private func handleDayPan(_ pan: UIPanGestureRecognizer) {
        let width = max(1, view.bounds.width)
        let translation = pan.translation(in: view).x
        switch pan.state {
        case .changed:
            setPageOffset(translation)
        case .ended:
            let velocity = pan.velocity(in: view).x
            let flicked = abs(velocity) > 600 && velocity.sign == translation.sign
            guard abs(translation) > width / 3 || flicked else {
                settlePage(animated: true)
                return
            }
            pageDay(by: translation < 0 ? 1 : -1)
        case .cancelled, .failed:
            settlePage(animated: true)
        default:
            break
        }
    }

    private func setPageOffset(_ x: CGFloat) {
        let transform = CGAffineTransform(translationX: x, y: 0)
        collectionView.transform = transform
        stateView.transform = transform
    }

    private func settlePage(animated: Bool) {
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            setPageOffset(0)
            return
        }
        UIView.animate(springDuration: 0.3, bounce: 0.1) { self.setPageOffset(0) }
    }

    /// Slides the shown day off toward the drag, selects the next one, and slides it in from
    /// the other side. Reduce Motion swaps the day in place.
    private func pageDay(by days: Int) {
        let width = view.bounds.width
        guard !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            setPageOffset(0)
            model.step(days: days)
            return
        }
        let out = days > 0 ? -width : width
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.setPageOffset(out)
        } completion: { _ in
            self.model.step(days: days)
            // The new day's rows are drawn before it slides in.
            self.updatePropertiesIfNeeded()
            self.collectionView.layoutIfNeeded()
            self.setPageOffset(-out)
            UIView.animate(springDuration: 0.32, bounce: 0.08) { self.setPageOffset(0) }
        }
    }
}

/// A calendar row: one accessibility element, its outcome's fill when it is loud.
@MainActor
final class ScheduleCalendarCell: UICollectionViewListCell {
    var fill: UIColor?

    func reset() {
        fill = nil
        isAccessibilityElement = false
        accessibilityElementsHidden = false
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityIdentifier = nil
        accessibilityTraits = .none
        accessibilityCustomActionsBlock = nil
        setNeedsUpdateConfiguration()
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.clear()
        let palette = ThemeRuntimeState.currentUIKitPalette()
        if state.isHighlighted || state.isSelected {
            // A pressed tinted row deepens its own colour; a plain one greys.
            background.backgroundColor = fill.map { $0.withAlphaComponent($0.cgColor.alpha * 1.8) }
                ?? palette.fg.withAlphaComponent(0.08)
        } else {
            background.backgroundColor = fill ?? .clear
        }
        background.cornerRadius = 14
        backgroundConfiguration = background
    }
}

/// The night band behind the overnight section: `bgDark`, rounded.
final class ScheduleCalendarBandBackground: UICollectionReusableView {
    static let kind = "schedules.calendar.night-band"

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        backgroundColor = ThemeRuntimeState.currentUIKitPalette().bgDark
    }
}
