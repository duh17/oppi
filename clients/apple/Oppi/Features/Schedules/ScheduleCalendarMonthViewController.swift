import UIKit

/// The Schedules calendar's Month: the month's name, a weekday row, and a full-width grid of
/// its days marking only the exceptions (a past day's health and rounded spend, a future
/// day's hollow ring when something that does not run most days falls on it), with the
/// selected day's agenda under it, or beside it on a wide landscape screen.
///
/// The bar's `Today ‹ ›` and a horizontal swipe on the grid page months; the grid has no
/// navigation of its own. A grid of plain controls rather than `UICalendarView`, which caps
/// its width and always draws its own month header and arrows.
///
/// The agenda is the Day agenda without its week strip (`ScheduleCalendarDayViewController`
/// with `showsWeekStrip` false), on the same model: selecting a date selects the model's day,
/// and paging the month selects today in it, or its first day.
@MainActor
final class ScheduleCalendarMonthViewController: UIViewController {
    let model: ScheduleCalendarModel
    let agenda: ScheduleCalendarDayViewController
    private let root: AppRootEnvironment
    private let connection: ServerConnection

    private let card = UIView()
    private let titleLabel = UILabel()
    private let weekdays = UIStackView()
    private let grid = UIStackView()
    /// Six weeks of seven days, the most a month spans; a month's unused last row hides.
    private let rows = (0..<6).map { _ in MonthWeekRow() }
    private var rowHeights: [NSLayoutConstraint] = []
    /// The month drawn, by its first day's `dayKey`, so paging cross-fades only on a change.
    private var shownMonth: String?

    init(
        root: AppRootEnvironment,
        connection: ServerConnection,
        model: ScheduleCalendarModel,
        agenda: ScheduleCalendarDayViewController
    ) {
        self.root = root
        self.connection = connection
        self.model = model
        self.agenda = agenda
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var calendar: Calendar { model.calendar }
    var collectionView: UICollectionView { agenda.collectionView }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "schedules.calendar.month"
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "schedules.calendar.monthName"
        weekdays.axis = .horizontal
        weekdays.distribution = .fillEqually
        for _ in 0..<7 {
            let label = UILabel()
            label.font = UIFont.scaled(.caption1, .semibold)
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.isAccessibilityElement = false
            weekdays.addArrangedSubview(label)
        }
        grid.axis = .vertical
        grid.accessibilityIdentifier = "schedules.calendar.monthGrid"
        for row in rows {
            for cell in row.cells {
                cell.addAction(UIAction { [weak self, weak cell] _ in
                    guard let date = cell?.date else { return }
                    self?.pick(date)
                }, for: .touchUpInside)
            }
            let height = row.heightAnchor.constraint(equalToConstant: Self.rowHeight(columnWidth: 0, traits: traitCollection))
            rowHeights.append(height)
            grid.addArrangedSubview(row)
        }
        NSLayoutConstraint.activate(rowHeights)
        for (direction, months) in [(UISwipeGestureRecognizer.Direction.left, 1), (.right, -1)] {
            let swipe = UISwipeGestureRecognizer(target: self, action: months > 0 ? #selector(nextMonth) : #selector(previousMonth))
            swipe.direction = direction
            grid.addGestureRecognizer(swipe)
        }

        let stack = ControlRowViews.stack([titleLabel, weekdays, grid], spacing: 8)
        stack.setCustomSpacing(12, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.cardPadding),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.cardPadding),
        ])

        addChild(agenda)
        card.translatesAutoresizingMaskIntoConstraints = false
        agenda.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(agenda.view)
        view.addSubview(card)
        agenda.didMove(toParent: self)
        let safe = view.safeAreaLayoutGuide
        let leading = card.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16)
        let trailing = card.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16)
        cardInsets = (leading, trailing)
        NSLayoutConstraint.activate([
            leading,
            card.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            agenda.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            agenda.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        stacked = [
            trailing,
            agenda.view.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 4),
            agenda.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ]
        beside = [
            card.widthAnchor.constraint(equalTo: safe.widthAnchor, multiplier: Self.besideFraction),
            agenda.view.topAnchor.constraint(equalTo: view.topAnchor),
            agenda.view.leadingAnchor.constraint(equalTo: card.trailingAnchor),
        ]
    }

    private var cardInsets: (leading: NSLayoutConstraint, trailing: NSLayoutConstraint)?
    private var stacked: [NSLayoutConstraint] = []
    private var beside: [NSLayoutConstraint] = []
    private static let cardPadding: CGFloat = 12
    private static let besideFraction: CGFloat = 0.46

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        arrange()
    }

    /// A compact width has no room for the agenda under the month: the month alone, and a
    /// date opens its day (`onPickDay`), the way Calendar's month does on iPhone.
    var showsAgenda: Bool { AdaptiveWidth.isWide(traitCollection) }

    /// A date was chosen where the agenda is not shown: the container shows it in the Day.
    var onPickDay: (() -> Void)?

    /// The agenda beside the month on a wide screen wider than tall; otherwise the month
    /// above it, on the rows' margins (16 pt, or the readable column's).
    private func arrange() {
        agenda.view.isHidden = !showsAgenda
        let width = view.safeAreaLayoutGuide.layoutFrame.width
        let side = AdaptiveWidth.isWide(traitCollection) && view.bounds.width > view.bounds.height
        let inset = side ? 16 : max(16, (width - ReadableContentWidth.column) / 2)
        cardInsets?.leading.constant = inset
        cardInsets?.trailing.constant = -inset
        if side, beside.first?.isActive != true {
            NSLayoutConstraint.deactivate(stacked)
            NSLayoutConstraint.activate(beside)
        } else if !side, stacked.first?.isActive != true {
            NSLayoutConstraint.deactivate(beside)
            NSLayoutConstraint.activate(stacked)
        }
        let cardWidth = side ? width * Self.besideFraction - inset : width - 2 * inset
        let rowHeight = Self.rowHeight(columnWidth: (cardWidth - 2 * Self.cardPadding) / 7, traits: traitCollection)
        for height in rowHeights where height.constant != rowHeight { height.constant = rowHeight }
    }

    /// A week's height follows its columns' width: a little shorter than square, never
    /// shorter than a date over its mark, never taller than an iPad needs.
    static func rowHeight(columnWidth: CGFloat, traits: UITraitCollection) -> CGFloat {
        let metrics = UIFontMetrics(forTextStyle: .title3)
        let low = metrics.scaledValue(for: 58, compatibleWith: traits)
        let high = max(low, metrics.scaledValue(for: 80, compatibleWith: traits))
        return min(high, max(low, (columnWidth * 0.78).rounded()))
    }

    @objc private func nextMonth() { model.step(months: 1) }
    @objc private func previousMonth() { model.step(months: -1) }

    private func pick(_ date: Date) {
        model.select(date)
        if !showsAgenda { onPickDay?() }
    }

    override func updateProperties() {
        super.updateProperties()
        let palette = root.themeStore.activeThemeID.palette
        let response = model.response
        let selected = model.selectedDay
        let now = model.now
        let live = ScheduleCalendarDayViewController.liveSessions(for: response, sessionStore: connection.sessionStore)
        let agenda = model.agenda(live: live)
        // Compact, nothing stays selected: each tap on a date opens it, the same one again too.
        let showsSelection = showsAgenda

        view.backgroundColor = palette.ui.bg
        card.backgroundColor = SettingsStyle(palette: palette, isDark: ScheduleCalendarOutcomeStyle.isDark(palette)).card
        guard let month = calendar.dateInterval(of: .month, for: selected) else { return }

        let monthName = month.start.formatted(.dateTime.month(.wide))
        let year = month.start.formatted(.dateTime.year())
        let title = NSMutableAttributedString(string: monthName, attributes: [
            .font: UIFont.scaled(.title2, .bold), .foregroundColor: palette.ui.fg,
        ])
        title.append(NSAttributedString(string: " \(year)", attributes: [
            .font: UIFont.scaled(.title3), .foregroundColor: palette.ui.fgDim,
        ]))
        titleLabel.attributedText = title
        titleLabel.accessibilityLabel = "\(monthName) \(year)"

        let symbols = calendar.shortStandaloneWeekdaySymbols
        for (index, label) in weekdays.arrangedSubviews.enumerated() {
            guard let label = label as? UILabel else { continue }
            label.text = symbols[(calendar.firstWeekday - 1 + index) % 7].uppercased()
            label.textColor = palette.ui.fgDim
        }

        let monthKey = ScheduleCalendarAgenda.dayKey(month.start, calendar: calendar)
        if shownMonth != nil, shownMonth != monthKey, view.window != nil {
            UIView.transition(with: grid, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction], animations: nil)
        }
        shownMonth = monthKey

        let lead = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: month.start)?.count ?? 0
        let weeks = (lead + days + 6) / 7
        let separator = palette.ui.comment.withAlphaComponent(0.25)
        let previousMonth = String(localized: "Previous Month")
        let nextMonth = String(localized: "Next Month")
        let paging = [
            UIAccessibilityCustomAction(name: previousMonth) { [weak self] _ in self?.previousMonth(); return true },
            UIAccessibilityCustomAction(name: nextMonth) { [weak self] _ in self?.nextMonth(); return true },
        ]
        for (week, row) in rows.enumerated() {
            row.isHidden = week >= weeks
            row.separator.backgroundColor = separator
            for (weekday, cell) in row.cells.enumerated() {
                let offset = week * 7 + weekday - lead
                guard offset >= 0, offset < days,
                      let date = calendar.date(byAdding: .day, value: offset, to: month.start) else {
                    cell.clear()
                    continue
                }
                cell.apply(
                    date: date,
                    mark: agenda?.monthMark(on: date, calendar: calendar),
                    isSelected: showsSelection && calendar.isDate(date, inSameDayAs: selected),
                    isToday: calendar.isDate(date, inSameDayAs: now),
                    calendar: calendar,
                    palette: palette
                )
                cell.accessibilityCustomActions = paging
            }
        }
    }

    /// "$32", "<$1", "$0" for a day that cost nothing.
    static func roundedCost(_ cost: Double) -> String {
        if cost > 0, cost < 1 { return "<$1" }
        return "$\(Int(cost.rounded()))"
    }
}

/// One week of the month: a hairline over seven equal days.
@MainActor
private final class MonthWeekRow: UIView {
    let cells = (0..<7).map { _ in MonthDayCell() }
    let separator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: cells)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(stack)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// One date in the month: its number (a filled circle when selected, blue when today) over
/// its mark, "● $32": a health dot and the rounded spend, red on a failure day; two dots when
/// a run failed and another waits on you. A future day's occasion is a hollow ring.
@MainActor
private final class MonthDayCell: UIControl {
    private(set) var date: Date?
    private let number = UILabel()
    private let circle = UIView()
    private let mark = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        number.adjustsFontForContentSizeCategory = true
        number.textAlignment = .center
        number.translatesAutoresizingMaskIntoConstraints = false
        circle.isUserInteractionEnabled = false
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(number)
        let side = UIFontMetrics(forTextStyle: .title3).scaledValue(for: 34)
        circle.layer.cornerRadius = side / 2
        mark.adjustsFontForContentSizeCategory = true
        mark.textAlignment = .center
        mark.adjustsFontSizeToFitWidth = true
        mark.minimumScaleFactor = 0.75
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(circle)
        addSubview(mark)
        NSLayoutConstraint.activate([
            circle.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            circle.centerXAnchor.constraint(equalTo: centerXAnchor),
            circle.widthAnchor.constraint(equalToConstant: side),
            circle.heightAnchor.constraint(equalToConstant: side),
            number.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            number.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            mark.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: 2),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
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

    /// A blank square before the month's first day or after its last. Emptied, not hidden:
    /// a hidden cell would leave its week's equal columns.
    func clear() {
        date = nil
        number.text = nil
        mark.attributedText = nil
        circle.backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityIdentifier = nil
        accessibilityCustomActions = nil
    }

    func apply(
        date: Date,
        mark: ScheduleCalendarAgenda.MonthMark?,
        isSelected: Bool,
        isToday: Bool,
        calendar: Calendar,
        palette: ThemePalette
    ) {
        self.date = date
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        number.text = date.formatted(.dateTime.day())
        number.font = UIFont.scaled(.title3, isSelected || isToday ? .bold : .regular, monospacedDigits: true)
        number.textColor = isSelected ? (isToday ? palette.ui.onBlue : palette.ui.bg) : (isToday ? palette.ui.blue : palette.ui.fg)
        circle.backgroundColor = isSelected ? (isToday ? palette.ui.blue : palette.ui.fg) : .clear

        let font = UIFont.scaled(.caption1, .medium, monospacedDigits: true)
        let dotFont = UIFont.systemFont(ofSize: font.pointSize * 0.75)
        let text = NSMutableAttributedString()
        var spoken = [date.formatted(date: .complete, time: .omitted)]
        if isToday { spoken.append(String(localized: "Today")) }
        func dot(_ color: UIColor, _ glyph: String = "●") {
            text.append(NSAttributedString(string: glyph, attributes: [.font: dotFont, .foregroundColor: color, .baselineOffset: 1]))
        }
        switch mark {
        case nil:
            break
        case .occasion:
            dot(palette.ui.comment, "○")
            spoken.append(String(localized: "runs scheduled"))
        case .ran(let hasFailure, let needsYou, let cost):
            if hasFailure { dot(palette.ui.red); spoken.append(String(localized: "a run failed")) }
            if needsYou { dot(palette.ui.orange); spoken.append(String(localized: "a run needs you")) }
            if !hasFailure, !needsYou { dot(palette.ui.green); spoken.append(String(localized: "all clean")) }
            let rounded = ScheduleCalendarMonthViewController.roundedCost(cost)
            text.append(NSAttributedString(string: "\u{2009}\(rounded)", attributes: [
                .font: font, .foregroundColor: hasFailure ? palette.ui.red : palette.ui.fgDim,
            ]))
            spoken.append(rounded)
        }
        self.mark.attributedText = text

        accessibilityIdentifier = "schedules.calendar.monthDay.\(ScheduleCalendarAgenda.dayKey(date, calendar: calendar))"
        accessibilityLabel = spoken.joined(separator: ", ")
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }
}
