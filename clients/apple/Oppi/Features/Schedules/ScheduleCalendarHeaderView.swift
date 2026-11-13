import UIKit

/// The Day agenda's header: the month title, then the week strip (seven days with one
/// health mark each; swipe to page weeks) or, at accessibility text sizes, a
/// `‹ Wed 11 Today ›` day stepper. Under Month (`showsWeekStrip` false) the title is the
/// selected day's date and there is no strip: the month above picks the day.
///
/// The title is a button when `onTitleTap` is set: the Day's month title opens Month, and
/// Month's day title opens the Day.
@MainActor
final class ScheduleCalendarHeaderView: UIView {
    struct Content: Equatable {
        var week: [Date]
        var selected: Date
        var today: Date
        var health: [ScheduleCalendarAgenda.DayHealth]
        var isAccessibilitySize: Bool
    }

    var onSelect: ((Date) -> Void)?
    /// Moves the selection by this many days: ±7 pages a week, ±1 steps a day.
    var onStep: ((Int) -> Void)?
    /// Tapping the title: nil leaves it plain text.
    var onTitleTap: (() -> Void)? {
        didSet { titleLabel.onActivate = onTitleTap }
    }
    /// What the title's button does, spoken as its hint.
    var titleHint: String?
    let showsWeekStrip: Bool
    /// How far the header's content sits in from its sides, so it starts and ends on the
    /// rows' edges.
    var edgeInsets: (left: CGFloat, right: CGFloat) = (16, 16) {
        didSet {
            leftInset?.constant = edgeInsets.left
            rightInset?.constant = -edgeInsets.right
        }
    }

    private var leftInset: NSLayoutConstraint?
    private var rightInset: NSLayoutConstraint?

    private let titleLabel = TitleLabel()
    private let strip = UIStackView()
    private let days = (0..<7).map { _ in DayButton() }
    private let stepper = UIStackView()
    private let previousDay = UIButton(type: .system)
    private let nextDay = UIButton(type: .system)
    private let stepperTitle = UILabel()
    private let stepperSubtitle = UILabel()
    private let divider = UIView()
    /// The day's one-line summary, under the strip so it stays in view while the day scrolls.
    private let summary = UIView()

    init(showsWeekStrip: Bool = true) {
        self.showsWeekStrip = showsWeekStrip
        super.init(frame: .zero)
        titleLabel.accessibilityIdentifier = showsWeekStrip ? "schedules.calendar.monthTitle" : "schedules.calendar.dayTitle"
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header

        strip.axis = .horizontal
        strip.distribution = .fillEqually
        strip.alignment = .top
        for day in days {
            day.addAction(UIAction { [weak self, weak day] _ in
                guard let date = day?.date else { return }
                self?.onSelect?(date)
            }, for: .touchUpInside)
            strip.addArrangedSubview(day)
        }
        for (direction, step) in [(UISwipeGestureRecognizer.Direction.left, 7), (.right, -7)] {
            let swipe = UISwipeGestureRecognizer(target: nil, action: nil)
            swipe.direction = direction
            swipe.addTarget(self, action: step > 0 ? #selector(nextWeek) : #selector(previousWeek))
            strip.addGestureRecognizer(swipe)
        }

        configureStepButton(previousDay, symbol: "chevron.backward", label: String(localized: "Previous Day"), identifier: "schedules.calendar.previousDay", step: -1)
        configureStepButton(nextDay, symbol: "chevron.forward", label: String(localized: "Next Day"), identifier: "schedules.calendar.nextDay", step: 1)
        stepperTitle.font = UIFont.scaled(.title2, .bold)
        stepperTitle.adjustsFontForContentSizeCategory = true
        stepperTitle.textAlignment = .center
        stepperTitle.numberOfLines = 0
        stepperSubtitle.font = UIFont.scaled(.body, .semibold)
        stepperSubtitle.adjustsFontForContentSizeCategory = true
        stepperSubtitle.textAlignment = .center
        let center = ControlRowViews.stack([stepperTitle, stepperSubtitle], spacing: 0, alignment: .center)
        center.isAccessibilityElement = true
        center.accessibilityIdentifier = "schedules.calendar.stepper"
        stepper.axis = .horizontal
        stepper.alignment = .center
        stepper.spacing = 12
        stepper.addArrangedSubview(previousDay)
        stepper.addArrangedSubview(center)
        stepper.addArrangedSubview(nextDay)
        center.setContentHuggingPriority(.defaultLow, for: .horizontal)

        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        summary.isAccessibilityElement = true
        summary.accessibilityIdentifier = "schedules.calendar.summary"
        let stack = ControlRowViews.stack([titleLabel, strip, stepper, divider, summary], spacing: 10)
        stack.setCustomSpacing(4, after: titleLabel)
        // The header is as tall as its content; the list below takes the rest.
        // Above any view's hugging below it, under its labels' compression resistance.
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = UILayoutPriority(UILayoutPriority.defaultHigh.rawValue - 1)
        hug.isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let left = stack.leftAnchor.constraint(equalTo: leftAnchor, constant: edgeInsets.left)
        let right = stack.rightAnchor.constraint(equalTo: rightAnchor, constant: -edgeInsets.right)
        leftInset = left
        rightInset = right
        NSLayoutConstraint.activate([
            left,
            right,
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configureStepButton(_ button: UIButton, symbol: String, label: String, identifier: String, step: Int) {
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage.scaledSymbol(symbol, style: .title2, weight: .semibold)
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        button.configuration = configuration
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in self?.onStep?(step) }, for: .primaryActionTriggered)
    }

    /// The day's summary: `view` draws it, `label` speaks it. Nil hides it (a day with no runs).
    func setSummary(_ view: UIView?, label: String?) {
        summary.subviews.forEach { $0.removeFromSuperview() }
        summary.isHidden = view == nil
        summary.accessibilityLabel = label
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        summary.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            view.topAnchor.constraint(equalTo: summary.topAnchor),
            view.bottomAnchor.constraint(equalTo: summary.bottomAnchor, constant: -4),
        ])
    }

    @objc private func nextWeek() { onStep?(7) }
    @objc private func previousWeek() { onStep?(-7) }

    func apply(_ content: Content, calendar: Calendar, palette: ThemePalette) {
        let isToday = calendar.isDate(content.selected, inSameDayAs: content.today)
        let title: NSMutableAttributedString
        if showsWeekStrip {
            let month = content.selected.formatted(.dateTime.month(.wide))
            let year = content.selected.formatted(.dateTime.year())
            title = NSMutableAttributedString(string: month, attributes: [
                .font: UIFont.scaled(.largeTitle, .bold), .foregroundColor: palette.ui.fg,
            ])
            if !content.isAccessibilitySize {
                title.append(NSAttributedString(string: " \(year)", attributes: [
                    .font: UIFont.scaled(.title2), .foregroundColor: palette.ui.fgDim,
                ]))
            }
            titleLabel.accessibilityLabel = "\(month) \(year)"
        } else {
            let date = content.selected.formatted(.dateTime.weekday(.wide).month(.wide).day())
            title = NSMutableAttributedString(string: date, attributes: [
                .font: UIFont.scaled(.title2, .bold), .foregroundColor: palette.ui.fg,
            ])
            if isToday {
                title.append(NSAttributedString(string: "  \(String(localized: "Today"))", attributes: [
                    .font: UIFont.scaled(.subheadline, .semibold), .foregroundColor: palette.ui.blue,
                ]))
            }
            titleLabel.accessibilityLabel = [date, isToday ? String(localized: "Today") : nil].compactMap { $0 }.joined(separator: ", ")
        }
        if onTitleTap != nil, let font = title.attribute(.font, at: 0, effectiveRange: nil) as? UIFont,
           let chevron = UIImage(
               systemName: showsWeekStrip ? "chevron.down" : "chevron.forward",
               withConfiguration: UIImage.SymbolConfiguration(font: font.withSize(font.pointSize * 0.5)).applying(UIImage.SymbolConfiguration(weight: .bold))
           )?.withTintColor(palette.ui.blue, renderingMode: .alwaysOriginal) {
            title.append(NSAttributedString(string: " ", attributes: [.font: font]))
            title.append(NSAttributedString(attachment: NSTextAttachment(image: chevron)))
        }
        titleLabel.attributedText = title
        titleLabel.accessibilityTraits = onTitleTap == nil ? .header : [.header, .button]
        titleLabel.accessibilityHint = onTitleTap == nil ? nil : titleHint
        titleLabel.isUserInteractionEnabled = onTitleTap != nil

        // Accessibility sizes keep only the stepper, which names the month itself, so the
        // day's runs keep the screen.
        titleLabel.isHidden = content.isAccessibilitySize
        strip.isHidden = content.isAccessibilitySize || !showsWeekStrip
        stepper.isHidden = !content.isAccessibilitySize
        divider.backgroundColor = palette.ui.comment.withAlphaComponent(0.35)

        for (index, day) in days.enumerated() {
            guard index < content.week.count else { day.isHidden = true; continue }
            day.isHidden = false
            let date = content.week[index]
            day.apply(
                date: date,
                isSelected: calendar.isDate(date, inSameDayAs: content.selected),
                isToday: calendar.isDate(date, inSameDayAs: content.today),
                isPast: calendar.startOfDay(for: date) < calendar.startOfDay(for: content.today),
                health: index < content.health.count ? content.health[index] : .init(),
                calendar: calendar,
                palette: palette
            )
            day.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "Previous Week")) { [weak self] _ in self?.onStep?(-7); return true },
                UIAccessibilityCustomAction(name: String(localized: "Next Week")) { [weak self] _ in self?.onStep?(7); return true },
            ]
        }

        stepperTitle.text = content.selected.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        stepperTitle.textColor = palette.ui.fg
        stepperSubtitle.text = isToday ? String(localized: "Today") : content.selected.formatted(.dateTime.month(.abbreviated))
        stepperSubtitle.textColor = isToday ? palette.ui.blue : palette.ui.fgDim
        stepperTitle.superview?.accessibilityLabel = [
            content.selected.formatted(date: .complete, time: .omitted),
            isToday ? String(localized: "Today") : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        for button in [previousDay, nextDay] {
            button.configuration?.baseForegroundColor = palette.ui.fg
            button.configuration?.baseBackgroundColor = palette.ui.fg.withAlphaComponent(0.07)
        }
    }
}

/// The header's title: a button when it has somewhere to go, for touch and VoiceOver alike.
@MainActor
private final class TitleLabel: UILabel {
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func tapped() { onActivate?() }

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}

/// One day in the week strip: the weekday's initial, the date (a filled circle when
/// selected), and the day's health mark.
@MainActor
private final class DayButton: UIControl {
    private(set) var date: Date?
    private let weekday = UILabel()
    private let number = UILabel()
    private let circle = UIView()
    private let marks = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        weekday.font = UIFont.scaled(.footnote, .semibold)
        weekday.adjustsFontForContentSizeCategory = true
        weekday.textAlignment = .center
        number.font = UIFont.scaled(.title3, .medium, monospacedDigits: true)
        number.adjustsFontForContentSizeCategory = true
        number.textAlignment = .center
        circle.isUserInteractionEnabled = false
        number.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(number)
        let side = UIFontMetrics(forTextStyle: .title3).scaledValue(for: 40)
        circle.layer.cornerRadius = side / 2
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: side),
            circle.heightAnchor.constraint(equalToConstant: side),
            number.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            number.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])
        marks.axis = .horizontal
        marks.spacing = 3
        marks.heightAnchor.constraint(equalToConstant: 7).isActive = true
        let stack = ControlRowViews.stack([weekday, circle, marks], spacing: 4, alignment: .center)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
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

    func apply(
        date: Date,
        isSelected: Bool,
        isToday: Bool,
        isPast: Bool,
        health: ScheduleCalendarAgenda.DayHealth,
        calendar: Calendar,
        palette: ThemePalette
    ) {
        self.date = date
        weekday.text = date.formatted(.dateTime.weekday(.narrow))
        weekday.textColor = isToday ? palette.ui.blue : palette.ui.fgDim
        number.text = date.formatted(.dateTime.day())
        number.textColor = isSelected ? (isToday ? palette.ui.onBlue : palette.ui.bg) : (isToday ? palette.ui.blue : palette.ui.fg)
        number.font = UIFont.scaled(.title3, isSelected || isToday ? .bold : .medium, monospacedDigits: true)
        circle.backgroundColor = isSelected ? (isToday ? palette.ui.blue : palette.ui.fg) : .clear

        marks.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var spoken: [String] = []
        if health.hasFailure {
            marks.addArrangedSubview(Self.dot(palette.ui.red, hollow: false))
            spoken.append(String(localized: "a run failed"))
        }
        if health.needsYou {
            marks.addArrangedSubview(Self.dot(palette.ui.orange, hollow: false))
            spoken.append(String(localized: "a run needs you"))
        }
        if !health.hasFailure, !health.needsYou {
            if health.ran, isPast || isToday {
                marks.addArrangedSubview(Self.dot(palette.ui.fgDim, hollow: false))
                spoken.append(String(localized: "all clean"))
            } else if health.hasUpcoming {
                marks.addArrangedSubview(Self.dot(palette.ui.comment, hollow: true))
                spoken.append(String(localized: "runs scheduled"))
            }
        }

        let key = ScheduleCalendarAgenda.dayKey(date, calendar: calendar)
        accessibilityIdentifier = "schedules.calendar.day.\(key)"
        accessibilityLabel = ([date.formatted(date: .complete, time: .omitted)] + (isToday ? [String(localized: "Today")] : []) + spoken)
            .joined(separator: ", ")
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }

    private static func dot(_ color: UIColor, hollow: Bool) -> UIView {
        let dot = UIView()
        dot.layer.cornerRadius = 3.5
        if hollow {
            dot.layer.borderColor = color.cgColor
            dot.layer.borderWidth = 1.2
        } else {
            dot.backgroundColor = color
        }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        return dot
    }
}
