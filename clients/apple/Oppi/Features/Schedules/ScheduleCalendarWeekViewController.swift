import UIKit

/// The Schedules calendar's Week grid, on wide widths only: hours down, a column per day,
/// the night compressed, a header per day with its spend and problems (or, ahead, how many
/// runs it holds), today tinted, and the now line. `ScheduleCalendarWeekLayout` places the
/// blocks; this draws them.
///
/// A tap on a run opens its session (or, still to come, its schedule); on a folded night or
/// merged runs it opens a popover listing them; a long press offers the Day agenda's menu
/// (`ScheduleCalendarActions`). A day's header opens that day in the Day agenda.
///
/// A scroll view of plain views rather than a collection view: there is no horizontal
/// scrolling, so the day headers sit above the scroll view instead of pinning inside it, and
/// a week is under a hundred blocks, kept by id so a redraw never pulls a block out from
/// under an open menu.
@MainActor
final class ScheduleCalendarWeekViewController: UIViewController, UIContextMenuInteractionDelegate, UIPopoverPresentationControllerDelegate {
    let model: ScheduleCalendarModel
    private let root: AppRootEnvironment
    private let connection: ServerConnection
    private let actions: ScheduleCalendarActions
    private let agents: ScheduleAgentDirectory
    /// A day's header: the container shows that day in the Day agenda.
    private let openDay: (Date) -> Void

    private let titleLabel = UILabel()
    private let summary = UIView()
    private let dayHeaders = UIView()
    let scrollView = UIScrollView()
    private let grid = UIView()
    private let ticker = ScheduleCalendarMinuteTicker()
    private let stateView = UIContentUnavailableView(loadState: .loading(nil))

    private var agenda: ScheduleCalendarAgenda?
    private var badges = ScheduleRowBadges(workspaces: [], agents: [])
    private var blockViews: [String: (key: AnyHashable, view: WeekBlockView)] = [:]
    private var columns: [UIView] = []
    private var drawnFrame: AnyHashable?
    private var scrolledWeek: String?
    private var summaryKey: AnyHashable?

    /// The hour labels' gutter, and the space after the last column.
    private static let gutter: CGFloat = 52
    private static let trailing: CGFloat = 8

    init(
        root: AppRootEnvironment,
        connection: ServerConnection,
        model: ScheduleCalendarModel,
        actions: ScheduleCalendarActions,
        agents: ScheduleAgentDirectory,
        openDay: @escaping (Date) -> Void
    ) {
        self.root = root
        self.connection = connection
        self.model = model
        self.actions = actions
        self.agents = agents
        self.openDay = openDay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var calendar: Calendar { model.calendar }
    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "schedules.calendar.week"
        actions.presenter = self
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "schedules.calendar.weekTitle"
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        summary.isAccessibilityElement = true
        summary.accessibilityIdentifier = "schedules.calendar.weekSummary"
        let top = ControlRowViews.stack([titleLabel, ControlRowViews.spacer(), summary], axis: .horizontal, spacing: 12, alignment: .firstBaseline)
        top.translatesAutoresizingMaskIntoConstraints = false
        // The title row is as tall as its text; the grid below takes the rest. Above the
        // grid's own hugging, under its labels' compression resistance.
        let hug = top.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = UILayoutPriority(UILayoutPriority.defaultHigh.rawValue - 1)
        hug.isActive = true
        dayHeaders.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.accessibilityIdentifier = "schedules.calendar.weekGrid"
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(grid)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.accessibilityIdentifier = "schedules.calendar.state"
        // It fills the grid's region; it never sizes the rows above it.
        stateView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
        stateView.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        view.addSubview(scrollView)
        view.addSubview(stateView)
        view.addSubview(dayHeaders)
        view.addSubview(top)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            top.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            top.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            dayHeaders.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            dayHeaders.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dayHeaders.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dayHeaders.heightAnchor.constraint(equalToConstant: UIFontMetrics(forTextStyle: .title3).scaledValue(for: 64)),
            scrollView.topAnchor.constraint(equalTo: dayHeaders.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.topAnchor.constraint(equalTo: dayHeaders.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        model.appear()
        ticker.start(model)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ticker.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A new width redraws the grid: columns, and whether same-minute runs fit side by side.
        let frame = view.safeAreaLayoutGuide.layoutFrame
        if frame != laidOutFrame {
            laidOutFrame = frame
            setNeedsUpdateProperties()
        }
    }

    private var laidOutFrame: CGRect = .zero

    // MARK: - Drawing

    private var metrics: ScheduleCalendarWeekLayout.Metrics {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let width = max(0, (safe.width - Self.gutter - Self.trailing) / 7)
        var metrics = ScheduleCalendarWeekLayout.Metrics(columnWidth: width.rounded(.down))
        metrics.compactBlockHeight = UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 26).rounded()
        metrics.tallBlockHeight = UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 38).rounded()
        return metrics
    }

    private var gridOrigin: CGFloat { view.safeAreaLayoutGuide.layoutFrame.minX + Self.gutter }

    override func updateProperties() {
        super.updateProperties()
        // Every observed value is read before any return.
        let palette = palette
        let response = model.response
        let now = model.now
        let week = model.week
        let failure = model.failure
        let isLoaded = response != nil && model.isSelectedDayLoaded
        let live = ScheduleCalendarDayViewController.liveSessions(for: response, sessionStore: connection.sessionStore)
        badges = ScheduleRowBadges(workspaces: connection.workspaceStore.workspaces, agents: agents.agents)
        _ = EntityIcon.loadGeneration
        let agenda = isLoaded ? model.agenda(live: live) : nil
        self.agenda = agenda

        view.backgroundColor = palette.ui.bg
        applyTitle(week: week, agenda: agenda, now: now)
        guard view.bounds.width > 0, let first = week.first else { return }
        let metrics = metrics
        let layout = ScheduleCalendarWeekLayout(agenda: agenda, week: week, now: now, calendar: calendar, metrics: metrics)
        let todayIndex = week.firstIndex { calendar.isDate($0, inSameDayAs: now) }

        let frameKey = AnyHashable([
            AnyHashable(view.bounds.width), AnyHashable(gridOrigin), AnyHashable(palette.ui.bg), AnyHashable(palette.ui.blue),
            AnyHashable(ScheduleCalendarAgenda.dayKey(first, calendar: calendar)), AnyHashable(layout.contentHeight),
            AnyHashable(traitCollection.preferredContentSizeCategory),
        ])
        if frameKey != drawnFrame {
            drawnFrame = frameKey
            drawGrid(metrics: metrics, week: week, todayIndex: todayIndex, contentHeight: layout.contentHeight)
            blockViews.values.forEach { $0.view.removeFromSuperview() }
            blockViews = [:]
        }
        drawDayHeaders(week: week, agenda: agenda, now: now, metrics: metrics)
        drawBlocks(layout, now: now)
        drawNowLine(now: now, todayIndex: todayIndex, metrics: metrics)
        applyState(isLoaded: isLoaded, failure: failure)
        scrollIfNeeded(week: week, todayIndex: todayIndex, now: now, metrics: metrics)
    }

    /// "November 8 – 14 2026" and the week's "✓34 ▦1 ⚠2 ?1 $75.94".
    private func applyTitle(week: [Date], agenda: ScheduleCalendarAgenda?, now: Date) {
        guard let first = week.first, let last = week.last else { return }
        let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
        let range = sameMonth
            ? "\(first.formatted(.dateTime.month(.wide))) \(first.formatted(.dateTime.day())) – \(last.formatted(.dateTime.day()))"
            : "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
        let year = last.formatted(.dateTime.year())
        let title = NSMutableAttributedString(string: range, attributes: [
            .font: UIFont.scaled(.title1, .bold), .foregroundColor: palette.ui.fg,
        ])
        title.append(NSAttributedString(string: " \(year)", attributes: [
            .font: UIFont.scaled(.title3), .foregroundColor: palette.ui.fgDim,
        ]))
        titleLabel.attributedText = title
        titleLabel.accessibilityLabel = "\(range) \(year)"

        var total = ScheduleCalendarAgenda.Summary()
        for day in week {
            guard let day = agenda?.summary(on: day, calendar: calendar) else { continue }
            total.done += day.done
            total.running += day.running
            total.failed += day.failed
            total.needsYou += day.needsYou
            total.upcoming += day.upcoming
            total.cost += day.cost
        }
        let isThisWeek = week.contains { calendar.isDate($0, inSameDayAs: now) }
        let key = AnyHashable([AnyHashable(total), AnyHashable(isThisWeek), AnyHashable(palette.ui.bg)])
        guard key != summaryKey else { return }
        summaryKey = key
        summary.subviews.forEach { $0.removeFromSuperview() }
        guard !total.isEmpty else {
            summary.accessibilityLabel = nil
            return
        }
        let context = ScheduleCalendarRowContext(
            palette: palette, now: now, calendar: calendar, badge: nil, assetCache: nil,
            isAccessibilitySize: false, showsTime: false, isNext: false, isWide: true
        )
        let line = ScheduleCalendarRowViews.summary(
            total, dayTitle: isThisWeek ? String(localized: "This week") : String(localized: "Week"),
            isToday: isThisWeek, context: context
        )
        line.translatesAutoresizingMaskIntoConstraints = false
        summary.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            line.topAnchor.constraint(equalTo: summary.topAnchor),
            line.bottomAnchor.constraint(equalTo: summary.bottomAnchor),
        ])
        var spoken: [String] = [isThisWeek ? String(localized: "This week") : String(localized: "Week")]
        if total.done > 0 { spoken.append(String(localized: "\(total.done) done")) }
        if total.running > 0 { spoken.append(String(localized: "\(total.running) running")) }
        if total.failed > 0 { spoken.append(String(localized: "\(total.failed) failed")) }
        if total.needsYou > 0 { spoken.append(String(localized: "\(total.needsYou) need you")) }
        if total.hasRuns { spoken.append(SessionFormatting.costString(total.cost)) }
        summary.accessibilityLabel = spoken.joined(separator: ", ")
    }

    /// The hour lines and labels, the night band, today's tint, and the day columns.
    private func drawGrid(metrics: ScheduleCalendarWeekLayout.Metrics, week: [Date], todayIndex: Int?, contentHeight: CGFloat) {
        grid.subviews.forEach { $0.removeFromSuperview() }
        columns = []
        let width = view.bounds.width
        let origin = gridOrigin
        let gridWidth = metrics.columnWidth * 7
        grid.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight + 12)
        scrollView.contentSize = grid.frame.size
        let palette = palette

        let band = UIView(frame: CGRect(x: 0, y: 0, width: width, height: metrics.nightHeight))
        band.backgroundColor = palette.ui.bgDark
        grid.addSubview(band)
        if let todayIndex {
            let tint = UIView(frame: CGRect(
                x: origin + CGFloat(todayIndex) * metrics.columnWidth, y: 0,
                width: metrics.columnWidth, height: contentHeight + 12
            ))
            tint.backgroundColor = palette.ui.blue.withAlphaComponent(0.06)
            grid.addSubview(tint)
        }
        let hairline = 1 / max(1, traitCollection.displayScale)
        for column in 0...7 {
            let line = UIView(frame: CGRect(x: origin + CGFloat(column) * metrics.columnWidth, y: 0, width: hairline, height: contentHeight + 12))
            line.backgroundColor = palette.ui.comment.withAlphaComponent(0.2)
            grid.addSubview(line)
        }
        for hour in ScheduleCalendarAgenda.nightBandEndHour...23 {
            let y = ScheduleCalendarWeekLayout.y(hour: hour, metrics: metrics)
            let line = UIView(frame: CGRect(x: origin, y: y, width: gridWidth, height: hairline))
            line.backgroundColor = palette.ui.comment.withAlphaComponent(0.25)
            grid.addSubview(line)
            let label = Self.gutterLabel(Self.hourText(hour, calendar: calendar), palette: palette)
            label.frame = CGRect(x: origin - Self.gutter, y: y - 8, width: Self.gutter - 6, height: 16)
            grid.addSubview(label)
        }
        let night = Self.gutterLabel(String(localized: "Night"), palette: palette)
        night.numberOfLines = 0
        night.text = "\(String(localized: "NIGHT"))\n\(Self.hourText(0, calendar: calendar, short: true))–\(Self.hourText(ScheduleCalendarAgenda.nightBandEndHour, calendar: calendar))"
        night.frame = CGRect(x: origin - Self.gutter, y: 4, width: Self.gutter - 6, height: metrics.nightHeight - 12)
        night.accessibilityLabel = String(localized: "Overnight")
        grid.addSubview(night)

        for (index, day) in week.enumerated() {
            let column = UIView(frame: CGRect(x: origin + CGFloat(index) * metrics.columnWidth, y: 0, width: metrics.columnWidth, height: contentHeight + 12))
            column.accessibilityContainerType = .semanticGroup
            column.accessibilityIdentifier = "schedules.calendar.column.\(ScheduleCalendarAgenda.dayKey(day, calendar: calendar))"
            grid.addSubview(column)
            columns.append(column)
        }
    }

    private static func gutterLabel(_ text: String, palette: ThemePalette) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.scaled(.caption2, .medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = palette.ui.fgDim
        label.textAlignment = .right
        label.isAccessibilityElement = false
        return label
    }

    /// "6 AM", or "18" in a 24-hour locale.
    private static func hourText(_ hour: Int, calendar: Calendar, short: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("j")
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour)) ?? Date()
        let text = formatter.string(from: date)
        guard short, let am = formatter.amSymbol else { return text }
        return text.replacingOccurrences(of: am, with: "").trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\u{202F}")))
    }

    /// Seven headers over the columns: the weekday and date (today in a blue circle), then the
    /// day's spend with its problems, or how many runs a day ahead holds.
    private func drawDayHeaders(week: [Date], agenda: ScheduleCalendarAgenda?, now: Date, metrics: ScheduleCalendarWeekLayout.Metrics) {
        let palette = palette
        while dayHeaders.subviews.count < week.count {
            let header = WeekDayHeaderView()
            header.addAction(UIAction { [weak self, weak header] _ in
                guard let day = header?.date else { return }
                self?.openDay(day)
            }, for: .touchUpInside)
            dayHeaders.addSubview(header)
        }
        let origin = gridOrigin
        dayHeaders.backgroundColor = palette.ui.bg
        for (index, day) in week.enumerated() {
            guard let header = dayHeaders.subviews[index] as? WeekDayHeaderView else { continue }
            header.frame = CGRect(x: origin + CGFloat(index) * metrics.columnWidth, y: 0, width: metrics.columnWidth, height: dayHeaders.bounds.height)
            let summary = agenda?.summary(on: day, calendar: calendar) ?? .init()
            let isToday = calendar.isDate(day, inSameDayAs: now)
            header.apply(date: day, summary: summary, isToday: isToday, isFuture: calendar.startOfDay(for: day) > now, palette: palette)
            if index < columns.count {
                columns[index].accessibilityLabel = header.accessibilityLabel
            }
        }
    }

    /// Each block by id: an unchanged one only moves; a changed one is drawn again.
    private func drawBlocks(_ layout: ScheduleCalendarWeekLayout, now: Date) {
        let palette = palette
        var seen = Set<String>()
        for block in layout.blocks {
            guard block.day < columns.count else { continue }
            seen.insert(block.id)
            let ticking = block.content.items.contains { $0.outcome == .upcoming || $0.outcome.isActive }
            let badgeList = block.content.items.compactMap { badges.badge(workspaceId: $0.workspaceId, agentId: $0.agentId) }
            let key = AnyHashable([
                AnyHashable(block.content), AnyHashable(block.frame.size.width), AnyHashable(block.frame.size.height),
                AnyHashable(ticking ? now : .distantPast), AnyHashable(badgeList), AnyHashable(palette.ui.bg),
            ])
            let view: WeekBlockView
            if let existing = blockViews[block.id], existing.key == key {
                view = existing.view
            } else {
                blockViews[block.id]?.view.removeFromSuperview()
                view = WeekBlockView()
                view.configure(block, badges: badgeList, now: now, calendar: calendar, palette: palette, assetCache: connection.iconAssetCache, isTall: layout.metrics.isWideColumn)
                view.addAction(UIAction { [weak self] _ in self?.activate(block.id) }, for: .touchUpInside)
                if case .entry = block.content {
                    view.addInteraction(UIContextMenuInteraction(delegate: self))
                    view.accessibilityCustomActionsBlock = { [weak self] in
                        guard let self, let item = item(block.id) else { return [] }
                        return actions.accessibilityActions(for: item, agenda: agenda)
                    }
                }
                blockViews[block.id] = (key, view)
            }
            if view.superview !== columns[block.day] { columns[block.day].addSubview(view) }
            view.frame = block.frame.insetBy(dx: 1.5, dy: 0)
        }
        for (id, entry) in blockViews where !seen.contains(id) {
            entry.view.removeFromSuperview()
            blockViews[id] = nil
        }
        // The bar under the blocks over it.
        for block in layout.blocks.reversed() where block.isRunningBar {
            if let bar = blockViews[block.id]?.view { bar.superview?.sendSubviewToBack(bar) }
        }
    }

    /// The now line: bold across today's column, a hairline across the others, its time in
    /// the gutter. Not an accessibility element.
    private func drawNowLine(now: Date, todayIndex: Int?, metrics: ScheduleCalendarWeekLayout.Metrics) {
        grid.viewWithTag(Self.nowTag)?.removeFromSuperview()
        guard let todayIndex else { return }
        let y = ScheduleCalendarWeekLayout.y(for: now, calendar: calendar, metrics: metrics)
        let container = UIView(frame: CGRect(x: 0, y: y - 10, width: view.bounds.width, height: 20))
        container.tag = Self.nowTag
        container.isUserInteractionEnabled = false
        container.isAccessibilityElement = false
        container.accessibilityElementsHidden = true
        let origin = gridOrigin
        let hair = UIView(frame: CGRect(x: origin, y: 9.5, width: metrics.columnWidth * 7, height: 1))
        hair.backgroundColor = palette.ui.blue.withAlphaComponent(0.6)
        container.addSubview(hair)
        let bold = UIView(frame: CGRect(x: origin + CGFloat(todayIndex) * metrics.columnWidth, y: 9, width: metrics.columnWidth, height: 2))
        bold.backgroundColor = palette.ui.blue
        container.addSubview(bold)
        let pill = InsetLabel(insets: UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5), capsule: true)
        pill.text = ScheduleCalendarText.timeParts(now, calendar: calendar).time
        pill.font = UIFont.scaled(.caption2, .bold, monospacedDigits: true)
        pill.textColor = palette.ui.onBlue
        pill.backgroundColor = palette.ui.blue
        let size = pill.intrinsicContentSize
        pill.frame = CGRect(x: origin - size.width - 4, y: 10 - size.height / 2, width: size.width, height: size.height)
        container.addSubview(pill)
        grid.addSubview(container)
    }

    private static let nowTag = 0x5C4ED

    /// Loading, or failed with one Retry, until the week is in; an empty week is its empty grid.
    private func applyState(isLoaded: Bool, failure: String?) {
        let state: LoadState?
        if !isLoaded {
            state = failure.map {
                .failed(title: String(localized: "Couldn't Load the Calendar"), message: $0, retry: RetryAction { [weak self] in self?.model.reload() })
            } ?? .loading(String(localized: "Loading calendar…"))
        } else {
            state = nil
        }
        stateView.isHidden = state == nil
        scrollView.isHidden = state != nil
        if let state {
            stateView.configuration = UIContentUnavailableConfiguration.loadState(state, palette: palette, background: palette.ui.bg)
        }
    }

    /// On opening a week: this week puts the now line a third of the way down; another
    /// starts at 6 AM, under the night.
    private func scrollIfNeeded(week: [Date], todayIndex: Int?, now: Date, metrics: ScheduleCalendarWeekLayout.Metrics) {
        guard let first = week.first, agenda != nil else { return }
        let key = ScheduleCalendarAgenda.dayKey(first, calendar: calendar)
        guard scrolledWeek != key, scrollView.bounds.height > 0 else { return }
        scrolledWeek = key
        let visible = scrollView.bounds.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom
        let target = todayIndex != nil
            ? ScheduleCalendarWeekLayout.y(for: now, calendar: calendar, metrics: metrics) - visible / 3
            : 0
        let maxOffset = max(0, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        scrollView.setContentOffset(CGPoint(x: 0, y: min(maxOffset, max(-scrollView.adjustedContentInset.top, target))), animated: false)
    }

    // MARK: - Actions

    private func item(_ id: String) -> ScheduleCalendarAgenda.Item? {
        agenda?.items.first { $0.id == id }
    }

    /// A run opens; a folded night or merged runs list themselves in a popover.
    private func activate(_ id: String) {
        guard let entry = blockViews[id], let block = entry.view.block else { return }
        switch block.content {
        case .entry(let item):
            actions.open(item)
        case .cluster(let cluster):
            showList(cluster.items, from: entry.view)
        case .merged(let items):
            showList(items, from: entry.view)
        }
    }

    private func showList(_ items: [ScheduleCalendarAgenda.Item], from source: UIView) {
        let list = WeekRunListController(
            items: items, now: model.now, calendar: calendar, palette: palette,
            badges: items.map { badges.badge(workspaceId: $0.workspaceId, agentId: $0.agentId) },
            assetCache: connection.iconAssetCache
        ) { [weak self] item in
            self?.dismiss(animated: true) { self?.actions.open(item) }
        }
        list.modalPresentationStyle = .popover
        list.popoverPresentationController?.sourceView = source
        list.popoverPresentationController?.sourceRect = source.bounds
        // Under the block, so it never covers the day headers above the grid.
        list.popoverPresentationController?.permittedArrowDirections = .up
        list.popoverPresentationController?.delegate = self
        present(list, animated: true)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let block = (interaction.view as? WeekBlockView)?.block, case .entry(let item) = block.content else { return nil }
        return actions.contextMenu(
            for: item,
            agenda: { [weak self] in self?.agenda },
            badge: badges.badge(workspaceId: item.workspaceId, agentId: item.agentId),
            width: view.bounds.width
        )
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let id = configuration.identifier as? String else { return }
        animator.addCompletion { [weak self] in self?.activate(id) }
    }
}

/// One block in the grid: an outcome-tinted rounded rect with a glyph and title, and on a
/// wide column a second line (cost and duration, why it failed, or when it runs).
@MainActor
private final class WeekBlockView: UIControl {
    private(set) var block: ScheduleCalendarWeekLayout.Block?
    private let content = UIStackView()
    private let rail = UIView()
    private let dash = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        clipsToBounds = true
        content.axis = .vertical
        content.spacing = 0
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rail)
        addSubview(content)
        layer.addSublayer(dash)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    /// VoiceOver's activation does what a tap does.
    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rail.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
        dash.frame = bounds
        dash.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 6).cgPath
    }

    func configure(
        _ block: ScheduleCalendarWeekLayout.Block,
        badges: [ScheduleRowBadge],
        now: Date,
        calendar: Calendar,
        palette: ThemePalette,
        assetCache: IconAssetCache?,
        isTall: Bool
    ) {
        self.block = block
        let outcome = block.content.outcome
        let style = ScheduleCalendarOutcomeStyle(outcome, palette: palette)
        let upcoming = outcome == .upcoming
        backgroundColor = style.fillsRow
            ? ScheduleCalendarOutcomeStyle.fill(style.color, palette: palette)
            : (upcoming ? .clear : palette.ui.fg.withAlphaComponent(0.06))
        rail.backgroundColor = upcoming ? .clear : style.color
        dash.isHidden = !upcoming
        dash.strokeColor = palette.ui.comment.withAlphaComponent(0.8).cgColor
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [3, 2]

        let items = block.content.items
        var title: String
        var detail: String?
        var spoken: String
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        switch block.content {
        case .entry(let item):
            title = item.name
            detail = Self.detail(item, now: now, calendar: calendar)
            spoken = [item.name, time(item.at), item.outcome.spokenLabel, detail].compactMap { $0 }.joined(separator: ", ")
            accessibilityIdentifier = "schedules.calendar.entry.\(item.id)"
            accessibilityHint = item.sessionId != nil ? String(localized: "Opens the session") : String(localized: "Opens the schedule")
        case .cluster(let cluster):
            title = cluster.isUpcoming ? String(localized: "\(items.count) runs") : String(localized: "\(items.count) done")
            if cluster.isUpcoming, let first = items.first, let last = items.last {
                detail = "\(time(first.at)) – \(time(last.at))"
            } else {
                detail = SessionFormatting.costString(cluster.totalCost)
            }
            spoken = cluster.isUpcoming
                ? String(localized: "Overnight, \(items.count) runs: \(items.map(\.name).formatted(.list(type: .and)))")
                : String(localized: "Overnight, \(items.count) runs, all done, \(SessionFormatting.costString(cluster.totalCost))")
            accessibilityIdentifier = "schedules.calendar.\(cluster.id)"
            accessibilityHint = String(localized: "Lists the runs")
        case .merged(let merged):
            title = String(localized: "\(merged.count) runs")
            detail = merged.first.map { time($0.at) }
            spoken = String(localized: "\(merged.count) runs at \(detail ?? ""): \(merged.map(\.name).formatted(.list(type: .and)))")
            accessibilityIdentifier = "schedules.calendar.merged.\(merged.first?.id ?? "")"
            accessibilityHint = String(localized: "Lists the runs")
        }
        if block.isRunningBar, case .entry(let item) = block.content, let duration = item.duration(now: now) {
            detail = String(localized: "Running \(ScheduleCalendarText.duration(duration))")
        }
        accessibilityLabel = spoken

        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var head: [UIView] = []
        if !upcoming {
            head.append(ScheduleCalendarRowViews.glyph(style, palette: palette, textStyle: .caption2))
        }
        let titleLabel = ControlRowViews.label(title, style: .caption1, weight: .semibold, color: palette.ui.fg, lines: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        head.append(titleLabel)
        if case .entry = block.content {} else {
            // A narrow column keeps the count whole: one icon at most.
            for badge in Self.unique(badges).prefix(isTall ? 4 : 1) {
                let icon = badge.iconView(size: 10, frameSize: 13, assetCache: assetCache)
                icon.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
                head.append(icon)
            }
        }
        content.addArrangedSubview(ControlRowViews.stack(head, axis: .horizontal, spacing: 3, alignment: .center))
        if isTall || block.isRunningBar, let detail {
            let color = style.fillsRow || block.isRunningBar ? style.color : palette.ui.fgDim
            let label = ControlRowViews.label(detail, style: .caption2, color: color, lines: 1)
            label.lineBreakMode = .byTruncatingTail
            content.addArrangedSubview(label)
        }
    }

    /// The second line: "$1.18 · 2m", "Failed · $1.65", "Needs you", "in 18m", or "9:00 AM".
    private static func detail(_ item: ScheduleCalendarAgenda.Item, now: Date, calendar: Calendar) -> String? {
        switch item.outcome {
        case .upcoming:
            let interval = item.at.timeIntervalSince(now)
            return interval > 0 && interval < 3_600
                ? ScheduleCalendarText.countdown(to: item.at, now: now, calendar: calendar)
                : item.at.formatted(date: .omitted, time: .shortened)
        case .done, .sent:
            return [item.cost.map(SessionFormatting.costString), item.duration(now: now).map(ScheduleCalendarText.duration)]
                .compactMap { $0 }.joined(separator: " · ")
        case .failed, .didNotStart, .needsYou, .running, .starting, .other:
            return ([item.outcome.label] + [item.cost.map(SessionFormatting.costString)].compactMap { $0 }).joined(separator: " · ")
        }
    }

    private static func unique(_ badges: [ScheduleRowBadge]) -> [ScheduleRowBadge] {
        var seen = Set<ScheduleRowBadge>()
        return badges.filter { seen.insert($0).inserted }
    }
}

/// A day's header over its column; it opens that day in the Day agenda.
@MainActor
private final class WeekDayHeaderView: UIControl {
    private(set) var date: Date?
    private let weekday = UILabel()
    private let number = InsetLabel(insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6), capsule: true)
    private let detail = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Shows the day")
        weekday.font = UIFont.scaled(.caption1, .semibold)
        weekday.adjustsFontForContentSizeCategory = true
        number.font = UIFont.scaled(.title3, .semibold, monospacedDigits: true)
        number.textAlignment = .center
        detail.font = UIFont.scaled(.caption1, monospacedDigits: true)
        detail.adjustsFontForContentSizeCategory = true
        detail.textAlignment = .center
        detail.lineBreakMode = .byTruncatingTail
        let top = ControlRowViews.stack([weekday, number], axis: .horizontal, spacing: 4, alignment: .center)
        let stack = ControlRowViews.stack([top, detail], spacing: 4, alignment: .center)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    func apply(date: Date, summary: ScheduleCalendarAgenda.Summary, isToday: Bool, isFuture: Bool, palette: ThemePalette) {
        self.date = date
        weekday.text = date.formatted(.dateTime.weekday(.abbreviated)).uppercased()
        weekday.textColor = isToday ? palette.ui.blue : palette.ui.fgDim
        number.text = date.formatted(.dateTime.day())
        number.textColor = isToday ? palette.ui.onBlue : palette.ui.fg
        number.backgroundColor = isToday ? palette.ui.blue : .clear

        let text = NSMutableAttributedString()
        let font = UIFont.scaled(.caption1, monospacedDigits: true)
        func glyph(_ symbol: String, _ color: UIColor) {
            guard let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))?
                .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
            text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
        }
        var spoken = [date.formatted(date: .complete, time: .omitted)]
        if isToday { spoken.append(String(localized: "Today")) }
        if summary.hasRuns {
            text.append(NSAttributedString(string: SessionFormatting.costString(summary.cost), attributes: [.font: font, .foregroundColor: palette.ui.fgDim]))
            if summary.failed > 0 { glyph("exclamationmark.triangle.fill", palette.ui.red) }
            if summary.needsYou > 0 { glyph("questionmark.bubble.fill", palette.ui.orange) }
            let runs = summary.done + summary.running + summary.failed + summary.needsYou
            spoken.append(runs == 1 ? String(localized: "1 run") : String(localized: "\(runs) runs"))
            if summary.failed > 0 { spoken.append(String(localized: "\(summary.failed) failed")) }
            if summary.needsYou > 0 { spoken.append(String(localized: "\(summary.needsYou) need you")) }
            spoken.append(SessionFormatting.costString(summary.cost))
        } else if summary.upcoming > 0, isFuture || isToday {
            let runs = summary.upcoming == 1 ? String(localized: "1 run") : String(localized: "\(summary.upcoming) runs")
            text.append(NSAttributedString(string: runs, attributes: [.font: font, .foregroundColor: palette.ui.comment]))
            spoken.append(String(localized: "\(runs) scheduled"))
        }
        detail.attributedText = text
        accessibilityLabel = spoken.joined(separator: ", ")
        accessibilityIdentifier = "schedules.calendar.weekDay.\(ScheduleCalendarAgenda.dayKey(date, calendar: Calendar.autoupdatingCurrent))"
    }
}

/// A folded night's or merged runs' popover: one row per run, each opening it.
@MainActor
private final class WeekRunListController: UIViewController {
    init(
        items: [ScheduleCalendarAgenda.Item],
        now: Date,
        calendar: Calendar,
        palette: ThemePalette,
        badges: [ScheduleRowBadge?],
        assetCache: IconAssetCache?,
        open: @escaping (ScheduleCalendarAgenda.Item) -> Void
    ) {
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = palette.ui.bgDark
        var rows: [UIView] = []
        for (index, item) in items.enumerated() {
            let style = ScheduleCalendarOutcomeStyle(item.outcome, palette: palette)
            let time = ControlRowViews.label(item.at.formatted(date: .omitted, time: .shortened), style: .subheadline, weight: .medium, color: palette.ui.fgDim, lines: 1)
            time.setContentHuggingPriority(.required, for: .horizontal)
            let name = ControlRowViews.label(item.name, style: .body, color: palette.ui.fg, lines: 1)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var parts: [UIView] = [time]
            if let badge = badges[index] { parts.append(badge.iconView(size: 15, frameSize: 20, assetCache: assetCache)) }
            parts += [name, ControlRowViews.spacer()]
            if let cost = item.cost {
                let label = ControlRowViews.label(SessionFormatting.costString(cost), style: .subheadline, color: palette.ui.comment, lines: 1)
                label.setContentHuggingPriority(.required, for: .horizontal)
                parts.append(label)
            }
            if item.outcome != .upcoming {
                parts.append(ScheduleCalendarRowViews.glyph(style, palette: palette, textStyle: .body))
            }
            let row = ControlRowViews.stack(parts, axis: .horizontal, spacing: 8, alignment: .center)
            row.isUserInteractionEnabled = false
            let button = UIButton(type: .system)
            button.accessibilityLabel = [item.name, item.at.formatted(date: .omitted, time: .shortened), item.outcome.spokenLabel, item.cost.map(SessionFormatting.costString)]
                .compactMap { $0 }.joined(separator: ", ")
            button.accessibilityIdentifier = "schedules.calendar.popover.\(item.id)"
            button.addAction(UIAction { _ in open(item) }, for: .primaryActionTriggered)
            row.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                row.topAnchor.constraint(equalTo: button.topAnchor, constant: 10),
                row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -10),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
            rows.append(button)
        }
        let stack = ControlRowViews.stack(rows, spacing: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
        ])
        let width: CGFloat = 340
        let height = stack.systemLayoutSizeFitting(
            CGSize(width: width - 32, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        preferredContentSize = CGSize(width: width, height: height + 12)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
