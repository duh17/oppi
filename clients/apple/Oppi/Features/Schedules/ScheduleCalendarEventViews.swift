import UIKit

/// How the Schedules calendar draws this device's calendar events beside runs. Events are
/// context, never an outcome: a neutral wash, a calendar glyph, and a faint solid rail,
/// where a run has an outcome colour and an occurrence still to come a dashed rail. No
/// calendar colours, because red and orange already mean failed and needs you here.
@MainActor
enum ScheduleCalendarEventViews {
    /// The wash behind an event row or block.
    static func fill(_ palette: ThemePalette) -> UIColor {
        palette.ui.fg.withAlphaComponent(ScheduleCalendarOutcomeStyle.isDark(palette) ? 0.07 : 0.045)
    }

    static func glyph(_ palette: ThemePalette, textStyle: UIFont.TextStyle) -> UIImageView {
        let view = UIImageView(image: UIImage.scaledSymbol("calendar", style: textStyle))
        view.tintColor = palette.ui.fgDim
        view.contentMode = .center
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }

    /// A timed event in the Day agenda: its start in the time column, then the title and
    /// "10:00 – 10:45 AM · Zoom". Stacked at accessibility sizes, where the title wraps.
    static func row(_ event: ScheduleCalendarEvent, at time: Date, context: ScheduleCalendarRowContext) -> UIView {
        let palette = context.palette
        let detail = [event.timeRange(calendar: context.calendar), event.location].compactMap { $0 }.joined(separator: " · ")
        let title = ControlRowViews.label(
            event.title, style: .body, color: palette.ui.fg, lines: context.isAccessibilitySize ? 0 : 1
        )
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let second = ControlRowViews.label(
            detail, style: .subheadline, color: palette.ui.fgDim, lines: context.isAccessibilitySize ? 0 : 1
        )
        second.lineBreakMode = .byTruncatingTail
        second.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = ControlRowViews.stack([glyph(palette, textStyle: .subheadline), title], axis: .horizontal, spacing: 6, alignment: .firstBaseline)
        let body = ControlRowViews.stack([head, second], spacing: 2)
        if context.isAccessibilitySize {
            return ControlRowViews.stack([rail(palette), body], axis: .horizontal, spacing: 12, alignment: .fill)
        }
        return ControlRowViews.stack([
            ScheduleCalendarRowViews.timeColumn(time, context: context), rail(palette), body,
        ], axis: .horizontal, spacing: 10, alignment: .fill)
    }

    /// An all-day event: one quiet line, "all-day" where a time would be.
    static func allDay(_ event: ScheduleCalendarEvent, context: ScheduleCalendarRowContext) -> UIView {
        let palette = context.palette
        let title = ControlRowViews.label(
            event.title, style: .subheadline, color: palette.ui.fg, lines: context.isAccessibilitySize ? 0 : 1
        )
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let label = ControlRowViews.label(String(localized: "all-day"), style: .caption2, color: palette.ui.fgDim, lines: 1)
        label.textAlignment = .right
        var parts: [UIView] = []
        if !context.isAccessibilitySize {
            label.widthAnchor.constraint(equalToConstant: ScheduleCalendarRowViews.timeColumnWidth).isActive = true
            parts.append(label)
        }
        parts += [rail(palette), glyph(palette, textStyle: .subheadline), title]
        return ControlRowViews.stack(parts, axis: .horizontal, spacing: 8, alignment: .center)
    }

    /// The same 4 pt as a run's rail, solid and faint.
    private static func rail(_ palette: ThemePalette) -> UIView {
        let rail = UIView()
        rail.backgroundColor = palette.ui.comment.withAlphaComponent(0.5)
        rail.layer.cornerRadius = 2
        rail.isUserInteractionEnabled = false
        rail.widthAnchor.constraint(equalToConstant: 4).isActive = true
        return rail
    }

    /// "Design review, calendar event, 10:00 – 10:45 AM, Zoom".
    static func spoken(_ event: ScheduleCalendarEvent, calendar: Calendar) -> String {
        [event.title, String(localized: "calendar event"), event.timeRange(calendar: calendar), event.location]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The long-press preview: title, the day and time, where, which calendar, and the
    /// start of its notes.
    static func preview(_ event: ScheduleCalendarEvent, calendar: Calendar, palette: ThemePalette, width: CGFloat) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = palette.ui.bgDark
        let title = ControlRowViews.label(event.title, style: .headline, color: palette.ui.fg, lines: 2)
        let day = event.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        var lines: [UIView] = [
            ControlRowViews.stack([glyph(palette, textStyle: .headline), title], axis: .horizontal, spacing: 6, alignment: .firstBaseline),
        ]
        let details = ["\(day) · \(event.timeRange(calendar: calendar))", event.location, event.calendarTitle.isEmpty ? nil : event.calendarTitle]
        for detail in details.compactMap({ $0 }) {
            let label = ControlRowViews.label(detail, style: .subheadline, color: palette.ui.fgDim, lines: 1)
            label.lineBreakMode = .byTruncatingTail
            lines.append(label)
        }
        if let notes = event.notes {
            let label = ControlRowViews.label(notes, style: .footnote, color: palette.ui.fgDim, lines: 3)
            label.lineBreakMode = .byTruncatingTail
            lines.append(label)
        }
        let stack = ControlRowViews.stack(lines, spacing: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -14),
        ])
        // As the run preview: narrow enough to sit beside its menu on an iPad mini.
        let width = min(width - 32, 340)
        let height = controller.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        controller.preferredContentSize = CGSize(width: width, height: height)
        return controller
    }
}

/// An event in the Week grid: a timed one behind the runs across its real duration, or an
/// all-day one in the strip under the day headers. The neutral wash, a faint border, the
/// title, and on a tall enough block its time. A tap or a long press offers Schedule Agent….
@MainActor
final class ScheduleCalendarWeekEventView: UIControl {
    private(set) var event: ScheduleCalendarEvent?
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        clipsToBounds = true
        stack.axis = .vertical
        stack.spacing = 0
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Schedules an agent for this event")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    func configure(_ block: ScheduleCalendarWeekLayout.EventBlock, calendar: Calendar, palette: ThemePalette, isTall: Bool) {
        apply(block.event, title: block.event.title, calendar: calendar, palette: palette)
        // The time fits on a wide column's block that is two lines tall.
        if isTall, block.frame.height >= 36 {
            let time = ControlRowViews.label(block.event.timeRange(calendar: calendar), style: .caption2, color: palette.ui.comment, lines: 1)
            time.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(time)
        }
    }

    /// An all-day chip: `title` is the day's first all-day event, "+2" for the others.
    func configureAllDay(_ event: ScheduleCalendarEvent, title: String, calendar: Calendar, palette: ThemePalette) {
        apply(event, title: title, calendar: calendar, palette: palette)
    }

    private func apply(_ event: ScheduleCalendarEvent, title text: String, calendar: Calendar, palette: ThemePalette) {
        self.event = event
        backgroundColor = ScheduleCalendarEventViews.fill(palette)
        layer.borderColor = palette.ui.comment.withAlphaComponent(0.35).cgColor
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = ControlRowViews.label(text, style: .caption1, color: palette.ui.fgDim, lines: 1)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(ControlRowViews.stack(
            [ScheduleCalendarEventViews.glyph(palette, textStyle: .caption2), title],
            axis: .horizontal, spacing: 3, alignment: .center
        ))
        accessibilityLabel = ScheduleCalendarEventViews.spoken(event, calendar: calendar)
        accessibilityIdentifier = "schedules.calendar.event.\(event.id)"
    }
}
