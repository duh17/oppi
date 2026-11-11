import UIKit

/// How one outcome looks: its colour token, its glyph, and whether its row is tinted.
/// Every state has its own glyph shape as well as a word, so meaning never rests on
/// colour (HIG Color).
@MainActor
struct ScheduleCalendarOutcomeStyle {
    let color: UIColor
    /// nil draws the working spinner (running, starting).
    let symbol: String?
    /// Loud for attention: failed, needs you, and running rows are filled with their colour.
    let fillsRow: Bool

    init(_ outcome: ScheduleCalendarOutcome, palette: ThemePalette) {
        switch outcome {
        case .upcoming:
            self.init(color: palette.ui.comment, symbol: "circle.dashed", fillsRow: false)
        case .starting:
            self.init(color: palette.ui.blue, symbol: nil, fillsRow: false)
        case .running:
            self.init(color: palette.ui.blue, symbol: nil, fillsRow: true)
        case .didNotStart, .failed:
            self.init(color: palette.ui.red, symbol: "exclamationmark.triangle.fill", fillsRow: true)
        case .needsYou:
            self.init(color: palette.ui.orange, symbol: "questionmark.bubble.fill", fillsRow: true)
        case .done, .sent:
            self.init(color: palette.ui.green, symbol: "checkmark.circle.fill", fillsRow: false)
        case .other:
            self.init(color: palette.ui.comment, symbol: "minus.circle", fillsRow: false)
        }
    }

    private init(color: UIColor, symbol: String?, fillsRow: Bool) {
        self.color = color
        self.symbol = symbol
        self.fillsRow = fillsRow
    }

    /// The outcome's colour over the page: 12 % on a light page, 18 % on a dark one; the
    /// text on it stays `fg`.
    static func fill(_ color: UIColor, palette: ThemePalette) -> UIColor {
        color.withAlphaComponent(isDark(palette) ? 0.18 : 0.12)
    }

    static func isDark(_ palette: ThemePalette) -> Bool {
        var white: CGFloat = 0
        palette.ui.bg.getWhite(&white, alpha: nil)
        return white < 0.5
    }
}

/// The workspace a row's chip names.
struct ScheduleCalendarWorkspaceBadge: Hashable {
    let name: String
    let icon: IconChoice?
    let sandbox: Bool
}

/// What a row draws besides its item: the context only the screen knows.
@MainActor
struct ScheduleCalendarRowContext {
    let palette: ThemePalette
    let now: Date
    let calendar: Calendar
    let workspace: ScheduleCalendarWorkspaceBadge?
    let assetCache: IconAssetCache?
    /// Accessibility text sizes stack the row.
    let isAccessibilitySize: Bool
    /// The first row at this time shows it; the rows after it at the same minute leave it out.
    let showsTime: Bool
    /// The next occurrence's countdown is bold.
    let isNext: Bool
    /// Regular width names the workspace in a row's chip; compact width shows only its icon.
    let isWide: Bool
}

/// Builders for the Day agenda's rows. Each builds the row's whole content; the cell
/// redraws only when the row's inputs change.
@MainActor
enum ScheduleCalendarRowViews {
    // MARK: - Entry

    static func entry(_ item: ScheduleCalendarAgenda.Item, context: ScheduleCalendarRowContext) -> UIView {
        if context.isAccessibilitySize { return stackedEntry(item, context: context) }
        if item.outcome.isClean { return quietEntry(item, context: context) }
        let palette = context.palette
        let style = ScheduleCalendarOutcomeStyle(item.outcome, palette: palette)

        let title = ControlRowViews.label(item.name, style: .body, weight: .semibold, color: palette.ui.fg, lines: 1)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var firstLine: [UIView] = [title, ControlRowViews.spacer()]
        if let trailing = trailing(item, context: context) { firstLine.append(trailing) }

        let status = statusLine(item, context: context)
        status.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        var secondLine: [UIView] = [status, ControlRowViews.spacer()]
        if let chip = chip(item, context: context, includesName: context.isWide, includesModel: true) {
            secondLine.append(chip)
        }

        // One order for every row: the title, what the run says, then its status.
        var lines: [UIView] = [ControlRowViews.stack(firstLine, axis: .horizontal, spacing: 8, alignment: .firstBaseline)]
        if let said = said(item, context: context) { lines.append(said) }
        lines.append(ControlRowViews.stack(secondLine, axis: .horizontal, spacing: 8, alignment: .center))
        return timed(ControlRowViews.stack(lines, spacing: 4), item: item, style: style, context: context)
    }

    /// What the run says, directly under its title: what a needs-you run asks, or why a
    /// failed one failed. One line; VoiceOver reads all of it.
    private static func said(_ item: ScheduleCalendarAgenda.Item, context: ScheduleCalendarRowContext) -> UILabel? {
        guard let text = item.outcome.isNeedsYou ? item.sessionMessage : failureReason(item) else { return nil }
        return secondaryLine(text, context: context)
    }

    /// Why a failed run failed: the session's error, or why the run never started.

    static func failureReason(_ item: ScheduleCalendarAgenda.Item) -> String? {
        switch item.outcome {
        case .failed: item.sessionMessage
        case .didNotStart: SchedulePresentation.runErrorSummary(item.runError)
        default: nil
        }
    }

    /// One secondary line, truncated; two at accessibility sizes, where words are fewer.
    private static func secondaryLine(_ text: String, context: ScheduleCalendarRowContext) -> UILabel {
        let label = ControlRowViews.label(
            text, style: .subheadline, color: context.palette.ui.fgDim, lines: context.isAccessibilitySize ? 2 : 1
        )
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// "Loud for attention, quiet for done": a settled clean run is one line.
    private static func quietEntry(_ item: ScheduleCalendarAgenda.Item, context: ScheduleCalendarRowContext) -> UIView {
        let palette = context.palette
        let style = ScheduleCalendarOutcomeStyle(item.outcome, palette: palette)
        var line: [UIView] = []
        if let workspace = context.workspace {
            let icon = IconChoiceUIView(size: 15, frameSize: 20)
            icon.apply(.choice(workspace.icon, purpose: .workspace, sandbox: workspace.sandbox), assetCache: context.assetCache)
            line.append(icon)
        }
        let title = ControlRowViews.label(item.name, style: .body, color: palette.ui.fgDim, lines: 1)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line += [title, ControlRowViews.spacer()]
        if let duration = item.duration(now: context.now) {
            line.append(hugging(ControlRowViews.label(
                ScheduleCalendarText.duration(duration), style: .subheadline, color: palette.ui.comment, lines: 1
            )))
        }
        if let cost = item.cost {
            line.append(hugging(ControlRowViews.label(
                SessionFormatting.costString(cost), style: .subheadline, color: palette.ui.comment, lines: 1
            )))
        }
        line.append(glyph(style, palette: palette, textStyle: .body))
        let row = ControlRowViews.stack(line, axis: .horizontal, spacing: 8, alignment: .center)
        return timed(row, item: item, style: style, context: context)
    }

    /// Accessibility sizes: time, title (wrapping), status and cost, then the chip.
    private static func stackedEntry(_ item: ScheduleCalendarAgenda.Item, context: ScheduleCalendarRowContext) -> UIView {
        let palette = context.palette
        let style = ScheduleCalendarOutcomeStyle(item.outcome, palette: palette)
        let time = ControlRowViews.label(
            item.at.formatted(date: .omitted, time: .shortened), style: .subheadline, weight: .medium,
            color: palette.ui.fgDim
        )
        let title = ControlRowViews.label(item.name, style: .body, weight: .semibold, color: palette.ui.fg)
        var lines: [UIView] = [time, title]
        if let said = said(item, context: context) { lines.append(said) }
        lines.append(statusLine(item, context: context, wraps: true))
        if let trailing = trailing(item, context: context) {
            lines.append(ControlRowViews.stack([trailing, ControlRowViews.spacer()], axis: .horizontal, spacing: 0, alignment: .center))
        }
        // The model leaves the chip at these sizes; the row still says it.
        if let chip = chip(item, context: context, includesName: true, includesModel: false) {
            lines.append(ControlRowViews.stack([chip, ControlRowViews.spacer()], axis: .horizontal, spacing: 0, alignment: .center))
        }
        let body = ControlRowViews.stack(lines, spacing: 6)
        let rail = Self.rail(style, upcoming: item.outcome == .upcoming)
        return ControlRowViews.stack([rail, body], axis: .horizontal, spacing: 12, alignment: .fill)
    }

    /// The time column, the outcome rail, then the row's body.
    private static func timed(
        _ body: UIView,
        item: ScheduleCalendarAgenda.Item,
        style: ScheduleCalendarOutcomeStyle,
        context: ScheduleCalendarRowContext
    ) -> UIView {
        ControlRowViews.stack([
            timeColumn(item.at, context: context),
            rail(style, upcoming: item.outcome == .upcoming),
            body,
        ], axis: .horizontal, spacing: 10, alignment: .fill)
    }

    static func timeColumn(_ date: Date, context: ScheduleCalendarRowContext) -> UIView {
        let palette = context.palette
        let parts = ScheduleCalendarText.timeParts(date, calendar: context.calendar)
        let time = ControlRowViews.label(parts.time, style: .subheadline, weight: .medium, color: palette.ui.fg, lines: 1)
        time.textAlignment = .right
        // `fgDim`, not `comment`: at caption size the fainter token washes out on a tinted row.
        let period = ControlRowViews.label(parts.period, style: .caption2, color: palette.ui.fgDim, lines: 1)
        period.textAlignment = .right
        // The row stretches the column to its height; the filler takes the slack, so the
        // time and its period stay together at the top of a tall row.
        let filler = UIView()
        filler.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
        filler.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        for label in [time, period] { label.setContentHuggingPriority(.required, for: .vertical) }
        let column = ControlRowViews.stack([time, period, filler], spacing: 0, alignment: .trailing)
        time.alpha = context.showsTime ? 1 : 0
        period.alpha = context.showsTime ? 1 : 0
        let width = ("12:00" as NSString).size(withAttributes: [.font: UIFont.scaled(.subheadline, .medium)]).width.rounded(.up) + 2
        column.widthAnchor.constraint(equalToConstant: width).isActive = true
        return column
    }

    /// The 4 pt outcome rail: solid for a run, dashed for an occurrence still to come.
    static func rail(_ style: ScheduleCalendarOutcomeStyle, upcoming: Bool) -> UIView {
        let rail = OutcomeRailView(color: style.color, dashed: upcoming)
        rail.widthAnchor.constraint(equalToConstant: 4).isActive = true
        return rail
    }

    /// Duration, a running time, a countdown, or Answer.
    private static func trailing(_ item: ScheduleCalendarAgenda.Item, context: ScheduleCalendarRowContext) -> UIView? {
        let palette = context.palette
        switch item.outcome {
        case .upcoming:
            let label = ControlRowViews.label(
                ScheduleCalendarText.countdown(to: item.at, now: context.now, calendar: context.calendar),
                style: .subheadline, weight: context.isNext ? .bold : .regular, color: palette.ui.blue, lines: 1
            )
            return hugging(label)
        case .needsYou:
            let answer = InsetLabel(insets: UIEdgeInsets(top: 3, left: 12, bottom: 3, right: 12), capsule: true)
            answer.text = String(localized: "Answer")
            answer.font = UIFont.scaled(.subheadline, .semibold)
            answer.textColor = palette.ui.bg
            answer.backgroundColor = palette.ui.orange
            return answer
        case .running, .starting:
            guard let duration = item.duration(now: context.now) else { return nil }
            return hugging(ControlRowViews.label(
                ScheduleCalendarText.duration(duration), style: .subheadline, weight: .semibold,
                color: palette.ui.blue, lines: 1
            ))
        case .failed, .done, .sent:
            guard let duration = item.duration(now: context.now) else { return nil }
            return hugging(ControlRowViews.label(
                ScheduleCalendarText.duration(duration), style: .subheadline, color: palette.ui.comment, lines: 1
            ))
        case .didNotStart, .other:
            return nil
        }
    }

    /// Glyph and word, then cost ("Running · $4.88 so far"); an upcoming occurrence says
    /// what kind of run it is.
    private static func statusLine(
        _ item: ScheduleCalendarAgenda.Item,
        context: ScheduleCalendarRowContext,
        wraps: Bool = false
    ) -> UIView {
        let palette = context.palette
        let style = ScheduleCalendarOutcomeStyle(item.outcome, palette: palette)
        let text = NSMutableAttributedString()
        func append(_ string: String, color: UIColor, weight: UIFont.Weight = .regular) {
            text.append(NSAttributedString(string: string, attributes: [
                .font: UIFont.scaled(.subheadline, weight), .foregroundColor: color,
            ]))
        }
        if item.outcome == .upcoming {
            append(upcomingDescription(item), color: palette.ui.comment)
        } else {
            append(item.outcome.label, color: style.color, weight: .semibold)
            if let cost = item.cost {
                append(" · \(SessionFormatting.costString(cost))", color: palette.ui.comment)
                if item.outcome.isActive { append(String(localized: " so far"), color: palette.ui.comment) }
            }
        }
        let label = UILabel()
        label.attributedText = text
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = wraps ? 0 : 1
        label.lineBreakMode = .byTruncatingTail
        guard item.outcome != .upcoming else { return label }
        let lead = glyph(style, palette: palette, textStyle: .subheadline)
        return ControlRowViews.stack([lead, label], axis: .horizontal, spacing: 4, alignment: .center)
    }

    static func upcomingDescription(_ item: ScheduleCalendarAgenda.Item) -> String {
        let cadence: String = switch item.trigger {
        case .at: String(localized: "One time")
        case .every(let intervalMs, _): String(localized: "Every \(AgentScheduleTrigger.intervalSummary(intervalMs))")
        case .cron: item.trigger.scheduleScreenCadence.capitalized
        }
        return item.sendsIntoExistingSession
            ? String(localized: "\(cadence) · into an existing session")
            : cadence
    }

    /// One capsule: the workspace's icon and (when `includesName`) name, then the model.
    /// The workspace name truncates before the model. VoiceOver says both either way.
    private static func chip(
        _ item: ScheduleCalendarAgenda.Item,
        context: ScheduleCalendarRowContext,
        includesName: Bool,
        includesModel: Bool
    ) -> UIView? {
        let palette = context.palette
        var parts: [UIView] = []
        if let workspace = context.workspace {
            let icon = IconChoiceUIView(size: 12, frameSize: 15)
            icon.apply(.choice(workspace.icon, purpose: .workspace, sandbox: workspace.sandbox), assetCache: context.assetCache)
            parts.append(icon)
            if includesName {
                let name = ControlRowViews.label(workspace.name, style: .caption1, color: palette.ui.fgDim, lines: 1)
                name.lineBreakMode = .byTruncatingTail
                name.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
                parts.append(name)
            }
        }
        if includesModel, let model = item.model {
            if !parts.isEmpty {
                parts.append(hugging(ControlRowViews.label("·", style: .caption1, color: palette.ui.comment, lines: 1)))
            }
            let side = UIFont.scaled(.caption1).pointSize
            let mark = UIImageView(image: EntityIcon.image(.model(model), size: side))
            mark.contentMode = .scaleAspectFit
            mark.widthAnchor.constraint(equalToConstant: side).isActive = true
            mark.heightAnchor.constraint(equalToConstant: side).isActive = true
            parts += [mark, hugging(ControlRowViews.label(modelName(model), style: .caption1, color: palette.ui.fgDim, lines: 1))]
        }
        guard !parts.isEmpty else { return nil }
        let content = ControlRowViews.stack(parts, axis: .horizontal, spacing: 3, alignment: .center)
        let capsule = UIView()
        capsule.backgroundColor = palette.ui.fg.withAlphaComponent(0.07)
        capsule.layer.cornerRadius = 8
        capsule.layer.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 7),
            content.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -7),
            content.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 3),
            content.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -3),
        ])
        capsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return capsule
    }

    // MARK: - Cluster, band, now, summary

    /// "3 runs done 🫏📓📓 · $2.54 ⌄" with the runs' names under it.
    static func cluster(
        _ cluster: ScheduleCalendarAgenda.Cluster,
        workspaces: [ScheduleCalendarWorkspaceBadge],
        context: ScheduleCalendarRowContext
    ) -> UIView {
        let palette = context.palette
        let outcome: ScheduleCalendarOutcome = cluster.isUpcoming ? .upcoming : .done
        let style = ScheduleCalendarOutcomeStyle(outcome, palette: palette)
        let count = cluster.items.count
        let title = ControlRowViews.label(
            cluster.isUpcoming ? String(localized: "\(count) runs") : String(localized: "\(count) runs done"),
            style: .body, weight: .semibold, color: palette.ui.fg, lines: context.isAccessibilitySize ? 0 : 1
        )
        var head: [UIView] = [glyph(style, palette: palette, textStyle: .body), title]
        if !context.isAccessibilitySize {
            for workspace in workspaces.prefix(4) {
                let icon = IconChoiceUIView(size: 14, frameSize: 18)
                icon.apply(.choice(workspace.icon, purpose: .workspace, sandbox: workspace.sandbox), assetCache: context.assetCache)
                head.append(icon)
            }
        }
        head.append(ControlRowViews.spacer())
        if !cluster.isUpcoming {
            head.append(hugging(ControlRowViews.label(
                SessionFormatting.costString(cluster.totalCost), style: .subheadline, color: palette.ui.fgDim, lines: 1
            )))
        }
        let chevron = UIImageView(image: UIImage.scaledSymbol(
            cluster.isExpanded ? "chevron.up" : "chevron.down", style: .footnote, weight: .semibold
        ))
        chevron.tintColor = palette.ui.fgDim
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        head.append(chevron)
        let names = ControlRowViews.label(
            cluster.items.map(\.name).formatted(.list(type: .and, width: .narrow)),
            style: .subheadline, color: palette.ui.fgDim, lines: context.isAccessibilitySize ? 0 : 1
        )
        let body = ControlRowViews.stack([
            ControlRowViews.stack(head, axis: .horizontal, spacing: 6, alignment: .center),
            names,
        ], spacing: 2)
        guard !context.isAccessibilitySize, let first = cluster.items.first else { return body }
        return ControlRowViews.stack([
            timeColumn(first.at, context: context),
            rail(style, upcoming: cluster.isUpcoming),
            body,
        ], axis: .horizontal, spacing: 10, alignment: .fill)
    }

    /// "☾ OVERNIGHT · 12 – 6 AM".
    static func bandHeader(context: ScheduleCalendarRowContext, range: String) -> UIView {
        let palette = context.palette
        let moon = UIImageView(image: UIImage.scaledSymbol("moon.fill", style: .footnote, weight: .semibold))
        moon.tintColor = palette.ui.fgDim
        moon.setContentHuggingPriority(.required, for: .horizontal)
        let title = UILabel()
        title.attributedText = NSAttributedString(string: String(localized: "OVERNIGHT"), attributes: [
            .kern: 0.8, .font: UIFont.scaled(.footnote, .semibold), .foregroundColor: palette.ui.fgDim,
        ])
        title.adjustsFontForContentSizeCategory = true
        let hours = ControlRowViews.label(range, style: .footnote, color: palette.ui.fgDim, lines: 1)
        hours.setContentHuggingPriority(.required, for: .horizontal)
        return ControlRowViews.stack([moon, title, ControlRowViews.spacer(), hours], axis: .horizontal, spacing: 6, alignment: .center)
    }

    /// The blue now line with its time pill.
    static func nowLine(_ now: Date, calendar: Calendar, palette: ThemePalette) -> UIView {
        let pill = InsetLabel(insets: UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7), capsule: true)
        pill.text = ScheduleCalendarText.timeParts(now, calendar: calendar).time
        pill.font = UIFont.scaled(.caption1, .bold, monospacedDigits: true)
        pill.textColor = palette.ui.onBlue
        pill.backgroundColor = palette.ui.blue
        let line = UIView()
        line.backgroundColor = palette.ui.blue
        line.heightAnchor.constraint(equalToConstant: 2).isActive = true
        let row = ControlRowViews.stack([pill, line], axis: .horizontal, spacing: 0, alignment: .center)
        row.isAccessibilityElement = false
        row.accessibilityElementsHidden = true
        return row
    }

    /// "Today ✓5 ▦1 ⚠1 ?1 … $10.84 so far"; at accessibility sizes the counts say their words
    /// and wrap. A day with nothing run yet says "3 upcoming" and no cost.
    static func summary(
        _ summary: ScheduleCalendarAgenda.Summary,
        dayTitle: String,
        isToday: Bool,
        context: ScheduleCalendarRowContext
    ) -> UIView {
        let palette = context.palette
        let words = context.isAccessibilitySize
        let text = NSMutableAttributedString()
        let font = UIFont.scaled(.subheadline)
        func attachment(_ symbol: String, _ color: UIColor) {
            guard let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))?
                .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
        }
        func count(_ value: Int, _ symbol: String, _ color: UIColor, _ word: String, spelled: Bool = false) {
            guard value > 0 else { return }
            if text.length > 0 { text.append(NSAttributedString(string: words ? "   " : " ", attributes: [.font: font])) }
            attachment(symbol, color)
            // No-break spaces keep a glyph, its number, and its word on one line.
            let group = words || spelled
                ? "\u{00A0}\(value)\u{00A0}\(word.replacingOccurrences(of: " ", with: "\u{00A0}"))"
                : "\u{00A0}\(value)"
            text.append(NSAttributedString(string: group, attributes: [.font: font, .foregroundColor: palette.ui.fg]))
        }
        if !words {
            text.append(NSAttributedString(string: dayTitle, attributes: [.font: UIFont.scaled(.subheadline, .bold), .foregroundColor: palette.ui.fg]))
            text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        count(summary.done, "checkmark.circle.fill", palette.ui.green, String(localized: "done"))
        count(summary.running, "circle.grid.3x3.fill", palette.ui.blue, String(localized: "running"))
        count(summary.failed, "exclamationmark.triangle.fill", palette.ui.red, String(localized: "failed"))
        count(summary.needsYou, "questionmark.bubble.fill", palette.ui.orange, String(localized: "needs you"))
        if !summary.hasRuns {
            count(summary.upcoming, "circle.dashed", palette.ui.comment, String(localized: "upcoming"), spelled: true)
        }

        let label = UILabel()
        label.attributedText = text
        label.adjustsFontForContentSizeCategory = true
        // One line beside the cost; at accessibility sizes the groups wrap whole.
        label.numberOfLines = words ? 0 : 1
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        guard summary.hasRuns else { return label }
        let costText = NSMutableAttributedString(
            string: SessionFormatting.costString(summary.cost),
            attributes: [.font: UIFont.scaled(.subheadline, .bold), .foregroundColor: palette.ui.fg]
        )
        if isToday {
            costText.append(NSAttributedString(string: String(localized: " so far"), attributes: [.font: font, .foregroundColor: palette.ui.fgDim]))
        }
        let cost = UILabel()
        cost.attributedText = costText
        cost.adjustsFontForContentSizeCategory = true
        cost.numberOfLines = 0
        cost.setContentHuggingPriority(.required, for: .horizontal)
        cost.setContentCompressionResistancePriority(.required, for: .horizontal)
        if words {
            return ControlRowViews.stack([label, cost], spacing: 4)
        }
        return ControlRowViews.stack([label, ControlRowViews.spacer(), cost], axis: .horizontal, spacing: 8, alignment: .center)
    }

    // MARK: - Pieces

    static func glyph(_ style: ScheduleCalendarOutcomeStyle, palette: ThemePalette, textStyle: UIFont.TextStyle) -> UIView {
        guard let symbol = style.symbol else { return spinner(palette) }
        let view = UIImageView(image: UIImage.scaledSymbol(symbol, style: textStyle))
        view.tintColor = style.color
        view.contentMode = .center
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }

    /// The working indicator in the style chosen in Settings; still under Reduce Motion.
    static func spinner(_ palette: ThemePalette) -> UIView {
        let side = UIFont.scaled(.subheadline).pointSize
        let spinner = WorkingSpinnerUIView(side: side)
        spinner.apply(tint: palette.ui.blue, palette: palette)
        spinner.isAnimating = true
        spinner.widthAnchor.constraint(equalToConstant: side).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: side).isActive = true
        return spinner
    }

    /// A chip's short model name: the family when the rest is a version ("Opus" for
    /// `claude-opus-5-5`), otherwise the shortened id ("gpt-5-mini").
    static func modelName(_ model: String) -> String {
        let short = displayModelName(model)
        let parts = short.split(separator: "-")
        guard let family = parts.first, parts.count > 1,
              family.allSatisfy(\.isLetter),
              parts.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return short }
        return family.prefix(1).uppercased() + family.dropFirst()
    }

    private static func hugging(_ view: UIView) -> UIView {
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }
}

/// A 4 pt rounded rail, dashed for an occurrence still to come.
private final class OutcomeRailView: UIView {
    private let color: UIColor
    private let dashed: Bool
    private let dashLayer = CAShapeLayer()

    init(color: UIColor, dashed: Bool) {
        self.color = color
        self.dashed = dashed
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        if dashed {
            dashLayer.strokeColor = color.cgColor
            dashLayer.lineWidth = 1.5
            dashLayer.lineDashPattern = [3, 3]
            dashLayer.fillColor = nil
            layer.addSublayer(dashLayer)
        } else {
            backgroundColor = color
            layer.cornerRadius = 2
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard dashed else { return }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: bounds.midX, y: 2))
        path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY - 2))
        dashLayer.frame = bounds
        dashLayer.path = path.cgPath
    }
}
