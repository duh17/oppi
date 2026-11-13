import UIKit

/// The Schedules calendar's Month: a `UICalendarView` marking only the exceptions (a past
/// day's health and rounded spend, a future day's hollow ring when something that does not
/// run most days falls on it), and the selected day's agenda under it, or beside it on a
/// wide landscape screen.
///
/// The agenda is the Day agenda without its week strip (`ScheduleCalendarDayViewController`
/// with `showsWeekStrip` false), on the same model: selecting a date selects the model's day,
/// and paging the month selects today in it, or its first day.
@MainActor
final class ScheduleCalendarMonthViewController: UIViewController, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
    let model: ScheduleCalendarModel
    let agenda: ScheduleCalendarDayViewController
    private let root: AppRootEnvironment
    private let connection: ServerConnection

    private let card = UIView()
    private let calendarView = UICalendarView()
    private lazy var selection = UICalendarSelectionSingleDate(delegate: self)
    /// Each shown day's mark, by `dayKey`; the decorations read it.
    private var marks: [String: ScheduleCalendarAgenda.MonthMark] = [:]
    private var markPalette: ThemePalette?

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
        calendarView.calendar = calendar
        calendarView.locale = calendar.locale ?? .current
        calendarView.timeZone = calendar.timeZone
        calendarView.delegate = self
        calendarView.selectionBehavior = selection
        calendarView.wantsDateDecorations = true
        calendarView.backgroundColor = .clear
        calendarView.accessibilityIdentifier = "schedules.calendar.monthGrid"
        calendarView.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.addSubview(calendarView)
        NSLayoutConstraint.activate([
            calendarView.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            calendarView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            calendarView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
            calendarView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
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
            card.widthAnchor.constraint(equalTo: safe.widthAnchor, multiplier: 0.46),
            agenda.view.topAnchor.constraint(equalTo: view.topAnchor),
            agenda.view.leadingAnchor.constraint(equalTo: card.trailingAnchor),
        ]
    }

    private var cardInsets: (leading: NSLayoutConstraint, trailing: NSLayoutConstraint)?
    private var stacked: [NSLayoutConstraint] = []
    private var beside: [NSLayoutConstraint] = []

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
    }

    override func updateProperties() {
        super.updateProperties()
        let palette = root.themeStore.activeThemeID.palette
        let response = model.response
        let selected = model.selectedDay
        let now = model.now
        let live = ScheduleCalendarDayViewController.liveSessions(for: response, sessionStore: connection.sessionStore)
        let agenda = model.agenda(live: live)

        view.backgroundColor = palette.ui.bg
        card.backgroundColor = SettingsStyle(palette: palette, isDark: ScheduleCalendarOutcomeStyle.isDark(palette)).card
        calendarView.tintColor = palette.ui.blue

        let components = calendar.dateComponents([.calendar, .year, .month, .day], from: selected)
        // Compact, nothing stays selected: each tap on a date opens it, the same one again too.
        if !showsAgenda {
            if selection.selectedDate != nil { selection.setSelected(nil, animated: false) }
        } else if selection.selectedDate.flatMap({ calendar.date(from: $0) }).map({ !calendar.isDate($0, inSameDayAs: selected) }) ?? true {
            selection.setSelected(components, animated: false)
        }
        let visible = calendarView.visibleDateComponents
        if visible.year != components.year || visible.month != components.month {
            calendarView.setVisibleDateComponents(components, animated: view.window != nil)
        }
        applyMarks(agenda: agenda, now: now, palette: palette)
    }

    /// Redraws only the days whose mark changed (or every day when the theme did).
    private func applyMarks(agenda: ScheduleCalendarAgenda?, now: Date, palette: ThemePalette) {
        guard let month = calendar.dateInterval(of: .month, for: model.selectedDay) else { return }
        var next: [String: ScheduleCalendarAgenda.MonthMark] = [:]
        var days: [Date] = []
        var day = month.start
        while day < month.end {
            days.append(day)
            if let mark = agenda?.monthMark(on: day, calendar: calendar) {
                next[ScheduleCalendarAgenda.dayKey(day, calendar: calendar)] = mark
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? month.end
        }
        let themeChanged = markPalette.map { $0.ui.bg != palette.ui.bg || $0.ui.blue != palette.ui.blue } ?? true
        let changed = days.filter { day in
            let key = ScheduleCalendarAgenda.dayKey(day, calendar: calendar)
            return themeChanged || next[key] != marks[key]
        }
        marks = next
        markPalette = palette
        guard !changed.isEmpty else { return }
        calendarView.reloadDecorations(
            forDateComponents: changed.map { calendar.dateComponents([.calendar, .year, .month, .day], from: $0) },
            animated: false
        )
    }

    // MARK: - UICalendarViewDelegate

    func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
        guard let date = calendar.date(from: dateComponents),
              let mark = marks[ScheduleCalendarAgenda.dayKey(date, calendar: calendar)],
              let palette = markPalette else { return nil }
        return .customView { Self.decoration(mark, palette: palette) }
    }

    func calendarView(_ calendarView: UICalendarView, didChangeVisibleDateComponentsFrom previousDateComponents: DateComponents) {
        guard let shown = calendar.date(from: calendarView.visibleDateComponents),
              !calendar.isDate(shown, equalTo: model.selectedDay, toGranularity: .month) else { return }
        model.showMonth(containing: shown)
    }

    // MARK: - UICalendarSelectionSingleDateDelegate

    func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
        guard let dateComponents, let date = calendar.date(from: dateComponents) else { return }
        model.select(date)
        if !showsAgenda { onPickDay?() }
    }

    func dateSelection(_ selection: UICalendarSelectionSingleDate, canSelectDate dateComponents: DateComponents?) -> Bool {
        dateComponents != nil
    }

    /// "● $32": a health dot and the rounded spend, red on a failure day; two dots when a run
    /// failed and another waits on you. A future day's occasion is a hollow ring.
    ///
    /// One label, so the calendar sizes it from its text.
    private static func decoration(_ mark: ScheduleCalendarAgenda.MonthMark, palette: ThemePalette) -> UIView {
        let font = UIFont.scaled(.caption2, .medium, monospacedDigits: true)
        let dotFont = UIFont.systemFont(ofSize: font.pointSize * 0.8)
        let text = NSMutableAttributedString()
        func dot(_ color: UIColor, _ glyph: String = "●") {
            text.append(NSAttributedString(string: glyph, attributes: [.font: dotFont, .foregroundColor: color, .baselineOffset: 1]))
        }
        switch mark {
        case .occasion:
            dot(palette.ui.comment, "○")
        case .ran(let hasFailure, let needsYou, let cost):
            if hasFailure { dot(palette.ui.red) }
            if needsYou { dot(palette.ui.orange) }
            if !hasFailure, !needsYou { dot(palette.ui.green) }
            text.append(NSAttributedString(string: "\u{2009}\(roundedCost(cost))", attributes: [
                .font: font, .foregroundColor: hasFailure ? palette.ui.red : palette.ui.fgDim,
            ]))
        }
        let label = UILabel()
        label.attributedText = text
        label.adjustsFontForContentSizeCategory = true
        // The agenda says the day's outcomes and spend; the date cell speaks its date.
        label.isAccessibilityElement = false
        label.accessibilityElementsHidden = true
        return label
    }

    /// "$32", "<$1", "$0" for a day that cost nothing.
    static func roundedCost(_ cost: Double) -> String {
        if cost > 0, cost < 1 { return "<$1" }
        return "$\(Int(cost.rounded()))"
    }
}
