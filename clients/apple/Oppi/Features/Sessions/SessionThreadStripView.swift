import UIKit

// MARK: - Inbox thread strip

/// Thread control under a thread root row: a blocked child by name, a dot for each
/// member that needs you or is in error, the working mark, the Agent summary, and
/// the status counts with the cost. The list makes it the tap target that folds the thread's child rows open or
/// closed; the root row above it opens the root chat. The chevron turns down
/// while the thread is open.
///
/// The strip describes the children only: the status marks, the status counts, the
/// Agent summary, and the VoiceOver child count all cover the thread's other sessions,
/// so they add up. The root row above already shows its own status. Both the marks
/// and the counts read the list's own classification of a member, without this
/// device's seen state, so the stopped count is the count of the thread's stopped
/// fold and opening a member never changes the strip.
///
/// The strip starts a line only for what the thread needs. It names a blocked
/// child, so the person knows where to answer, and never lists the working ones,
/// which the counts already name. Display choices only hide the Agent summary and
/// the cost total. The chevron, a blocked child, the marks, and the status counts
/// always stay.
///
/// A thread with nothing active, working, or in error draws one line: the counts,
/// the Agents, and the chevron. While a member is active the strip adds its status
/// line, and a blocked child adds its line above it, so no state holds an empty
/// line. The row changes height only when a child becomes blocked, or when the
/// thread's first member wakes or its last one settles, never as a member moves
/// between working, idle, and stopped otherwise.
final class SessionThreadStripView: UIControl {
    struct Content: Equatable {
        let rollup: SessionThreadRollup
        /// Pending asks per member. With the rollup they give the list's own classification of each
        /// member, without this device's seen state, so the strip says the same thing whether or not the
        /// person has opened a member.
        var askCounts: [String: Int] = [:]
        /// Locked root: names and counts only, no dots, Agents, or cost.
        var hidesDetails = false
        /// A locked member: its cost stays out of the total.
        var hidesCost = false
        /// The thread's child rows are listed under the root.
        var isExpanded = false

        func classification(_ session: Session) -> SessionListClassification {
            SessionListPresentation.classify(
                session,
                attention: SessionListAttentionCounts(askCount: askCounts[session.id] ?? 0)
            )
        }

        /// A blocked child, shown so the user knows where to answer: a live one, as the list counts it.
        var blockedMember: Session? {
            rollup.descendants.first { classification($0).isBlocked }
        }
    }

    private let stack = UIStackView()
    private let headline = UILabel()
    private let statusRow = SessionThreadStatusRow()
    private var marks: SessionThreadStatusMarksView { statusRow.marks }
    private var agents: SessionThreadAgentClusterView { statusRow.agents }
    private let footer = SessionThreadCountsLine()
    private var summaryLabel: SessionThreadSummaryLabel { footer.summary }
    private var chevron: UIImageView { footer.chevron }
    private var verticalPadding: [NSLayoutConstraint] = []
    /// The counts line holds the Agents while the thread is settled; the status line holds them while active.
    private var agentsAreSettled: Bool?
    private var isSettled = false
    private var summary = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous

        headline.adjustsFontForContentSizeCategory = true
        headline.translatesAutoresizingMaskIntoConstraints = false
        agents.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.axis = .vertical
        stack.alignment = .leading
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        [headline, statusRow, footer].forEach(stack.addArrangedSubview)
        addSubview(stack)
        let top = stack.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        let bottom = bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 6)
        verticalPadding = [top, bottom]
        NSLayoutConstraint.activate([
            top, bottom,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headline.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ content: Content, display: SessionRowDisplay, style: SessionRowStyle, iconAssetCache: IconAssetCache?) {
        let colors = style.colors
        let rollup = content.rollup
        backgroundColor = colors.bgHighlight.withAlphaComponent(0.45)
        stack.spacing = display.isCompact ? 2 : 4
        for constraint in verticalPadding { constraint.constant = display.isCompact ? 4 : 6 }

        let statusSummary = SessionThreadStripSummary(rollup: rollup, classify: content.classification)
        // The strip draws a line only while that line has something to say: the blocked child's line, the
        // status line of an active thread, and always the counts.
        isSettled = !statusSummary.isActive
        placeAgents(settled: isSettled)
        let blockedMember = content.blockedMember
        headline.setHiddenIfChanged(blockedMember == nil)
        statusRow.setHiddenIfChanged(isSettled || content.hidesDetails)

        if let blocked = blockedMember {
            let status = content.classification(blocked).status
            headline.attributedText = SessionRowText.symbolAndText(
                status.badgeSymbol, "\(status.label) · \(blocked.displayTitle)", style: .footnote,
                symbolWeight: .semibold, textWeight: .semibold, spacing: 5, color: style.tint(status)
            )
            headline.lineBreakMode = .byTruncatingTail
        } else if headline.attributedText != nil {
            headline.attributedText = nil
        }

        marks.apply(
            statusSummary.dots, hiddenCount: statusSummary.hiddenDotCount, working: statusSummary.workingCount, style: style
        )

        let showsAgents = display.showsThreadAgentSummary && !content.hidesDetails
        agents.setHiddenIfChanged(!showsAgents)
        if showsAgents {
            agents.apply(SessionThreadAgentGroup.groups(Array(rollup.descendants)), maxGroups: 3, colors: colors, iconAssetCache: iconAssetCache)
        }

        var parts: [String] = [statusSummary.text]
        let workspacesNote = rollup.workspaceCount > 1 ? "\(rollup.workspaceCount) workspaces" : nil
        if let workspacesNote { parts.append(workspacesNote) }
        // Same rule as a row: unknown or zero cost is absent, never "$0.00". It comes last, where the line
        // draws it, beside the chevron.
        let cost = display.showsCost && !content.hidesDetails && !content.hidesCost && rollup.totalCost > 0
            ? String(format: "$%.2f", rollup.totalCost)
            : nil
        if let cost { parts.append(cost) }
        summary = parts.joined(separator: " · ")
        // The line draws the counts, then the cost, then the spacer, the Agents, and the chevron. The counts
        // hold only what the marks do not already draw (the summary's quiet counts), so an active thread names
        // its idle and stopped members here and leaves working, needs you, and error to the marks. The cost
        // keeps its own room beside them, the cross-workspace note goes first, and only then does the tail
        // truncate. VoiceOver (above) always hears every bucket.
        summaryLabel.setCounts(
            statusSummary.quietText,
            note: workspacesNote
        )
        summaryLabel.textColor = colors.comment
        footer.cost.text = cost
        footer.cost.setHiddenIfChanged(cost == nil)
        footer.cost.textColor = colors.comment
        chevron.tintColor = colors.comment
        let chevronTransform = CGAffineTransform(rotationAngle: content.isExpanded ? .pi / 2 : 0)
        if chevron.transform != chevronTransform {
            let animates = window != nil && !UIAccessibility.isReduceMotionEnabled
            UIView.animate(withDuration: animates ? 0.2 : 0) { self.chevron.transform = chevronTransform }
        }

        // The thread's own headline in the strip's words, with each member's real state: a child waiting on a
        // question says Question, not the "needs you" the counts use for every blocked kind. A stopped member
        // reads Stopped and a settled outcome reads Idle, since the strip has no Done.
        let statusRollup = rollup.statusRollup { content.classification($0).settledKind }
        let blocked = content.blockedMember.map { "\(content.classification($0).status.label) from \($0.displayTitle). " } ?? ""
        let headlineStatus = statusRollup.headline.map { "\($0.label). " } ?? ""
        let children = rollup.descendants.count
        accessibilityLabel = blocked + headlineStatus
            + "Thread with \(children) child \(children == 1 ? "session" : "sessions"), \(summary)"
        accessibilityValue = content.isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        accessibilityHint = content.isExpanded
            ? String(localized: "Hides the thread's sessions")
            : String(localized: "Shows the thread's sessions")
    }

    /// The Agents sit on the status line while a member is active, where the marks leave them the whole width,
    /// and join the counts line once the thread settles, so a settled strip stays one line. They move only
    /// when the thread wakes or settles, never as a member changes state.
    private func placeAgents(settled: Bool) {
        guard agentsAreSettled != settled else { return }
        agentsAreSettled = settled
        agents.removeFromSuperview()
        if settled {
            footer.insertArrangedSubview(agents, at: footer.arrangedSubviews.count - 1)
        } else {
            statusRow.addArrangedSubview(agents)
        }
    }
}

// MARK: - Status row

/// The strip's status marks on the left and, while a member is active, the Agents on the right. The marks
/// keep their width; the Agents take what is left and drop trailing groups to fit, so the row never overflows.
final class SessionThreadStatusRow: UIStackView {
    /// The least room the row keeps between the marks and the Agents. `layoutSubviews` fits the Agents in
    /// what is left after it, so the spacer and the fit read the same number.
    private static let spacerMinWidth: CGFloat = 4

    let marks = SessionThreadStatusMarksView()
    let agents = SessionThreadAgentClusterView()

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 8
        [marks, SessionRowSpacer(minWidth: Self.spacerMinWidth), agents].forEach(addArrangedSubview)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not supported") }

    override func layoutSubviews() {
        // Fit before `super`: `apply` unhides the Agent groups, and the row is wider than the strip until the
        // trailing groups fold into "+N". Fitting first hides them in this same pass, so the row never lays
        // out over-wide against its required width. A settled thread hosts the Agents on its counts line.
        if agents.superview === self, !agents.isHidden {
            agents.fit(maxWidth: bounds.width - marks.intrinsicContentSize.width - spacing * 2 - Self.spacerMinWidth)
        }
        super.layoutSubviews()
    }
}

// MARK: - Counts line

/// The strip's counts line: the counts the marks leave out, the thread's cost, the chevron, and, while the
/// thread is settled, the Agents. The cost keeps its room and the Agents fold into what the counts leave, so
/// the line never overflows and never loses the cost.
final class SessionThreadCountsLine: UIStackView {
    /// The least room kept between the counts and what follows, as the status line keeps.
    private static let spacerMinWidth: CGFloat = 4

    let summary = SessionThreadSummaryLabel()
    /// The cost is its own label so the counts can truncate beside it: the line drops the cross-workspace
    /// note, then truncates the counts, never the cost.
    let cost = UILabel()
    let chevron = UIImageView()

    init() {
        super.init(frame: .zero)
        summary.font = UIFont.scaled(.caption1)
        summary.adjustsFontForContentSizeCategory = true
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cost.font = UIFont.scaled(.caption1, monospacedDigits: true)
        cost.adjustsFontForContentSizeCategory = true
        cost.setContentHuggingPriority(.required, for: .horizontal)
        cost.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.image = UIImage.scaledSymbol("chevron.right", style: .caption1, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        axis = .horizontal
        alignment = .center
        spacing = 8
        [summary, cost, SessionRowSpacer(minWidth: Self.spacerMinWidth), chevron].forEach(addArrangedSubview)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not supported") }

    override func layoutSubviews() {
        // Fit before `super`, for the reason the status line does it: a settled strip draws the Agents here.
        if let agents = arrangedSubviews.compactMap({ $0 as? SessionThreadAgentClusterView }).first,
           !agents.isHidden {
            // Gaps between the pieces still on the line: a hidden cost leaves no gap behind it.
            let shown = arrangedSubviews.filter { !$0.isHidden }
            let gaps = CGFloat(max(0, shown.count - 1))
            let reserved = summary.minimumWidth + (cost.isHidden ? 0 : cost.intrinsicContentSize.width)
                + chevron.intrinsicContentSize.width + spacing * gaps + Self.spacerMinWidth
            agents.fit(maxWidth: bounds.width - reserved)
        }
        super.layoutSubviews()
    }
}

// MARK: - Agent cluster

/// Agents present in a group of sessions, largest first: 🛠️×15 🔬×12 +2.
/// Item views are reused by position across reconfigures. `fit` drops trailing
/// groups, folding them into "+N", until the cluster fits the width it is given.
final class SessionThreadAgentClusterView: UIStackView {
    private var items: [(stack: UIStackView, icon: SessionGridBadgeView, count: UILabel)] = []
    private let overflow = UILabel()
    private var groupTotal = 0
    private var appliedGroups = 0

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 6
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        Self.styleCount(overflow)
        addArrangedSubview(overflow)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not supported") }

    func apply(
        _ groups: [SessionThreadAgentGroup],
        maxGroups: Int,
        colors: ComposerThemeColors,
        iconAssetCache: IconAssetCache?
    ) {
        let shown = Array(groups.prefix(maxGroups))
        groupTotal = groups.count
        appliedGroups = shown.count
        while items.count < shown.count {
            let icon = SessionGridBadgeView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),
            ])
            let count = UILabel()
            Self.styleCount(count)
            let stack = UIStackView(arrangedSubviews: [icon, count])
            stack.alignment = .center
            stack.spacing = 2
            insertArrangedSubview(stack, at: items.count)
            items.append((stack, icon, count))
        }
        for (index, item) in items.enumerated() {
            item.stack.setHiddenIfChanged(index >= shown.count)
            guard index < shown.count else { continue }
            let group = shown[index]
            item.icon.configure(
                sessionId: group.sampleSessionId,
                agentId: group.agentId,
                agentIcon: group.agentIcon,
                iconAssetCache: iconAssetCache
            )
            item.count.setHiddenIfChanged(group.count <= 1)
            item.count.text = "×\(group.count)"
            item.count.textColor = colors.comment
        }
        overflow.setHiddenIfChanged(groups.count <= maxGroups)
        overflow.text = "+\(groups.count - maxGroups)"
        overflow.textColor = colors.comment
    }

    /// Shows as many of the applied groups as fit in `maxWidth`, then "+N" for the rest of the Agents.
    /// With no room for even one group the cluster is empty.
    func fit(maxWidth: CGFloat) {
        guard maxWidth > 0, appliedGroups > 0 else { return }
        let widths = items.prefix(appliedGroups).map {
            $0.stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        }
        var shown = 0
        var showsOverflow = false
        for count in stride(from: appliedGroups, through: 1, by: -1) {
            let hidden = groupTotal - count
            let views = count + (hidden > 0 ? 1 : 0)
            let width = widths.prefix(count).reduce(0, +) + (hidden > 0 ? overflowWidth(hidden) : 0)
                + spacing * CGFloat(views - 1)
            if width <= maxWidth {
                shown = count
                showsOverflow = hidden > 0
                break
            }
        }
        for (index, item) in items.enumerated() { item.stack.setHiddenIfChanged(index >= shown) }
        let text = "+\(groupTotal - shown)"
        if overflow.text != text { overflow.text = text }
        overflow.setHiddenIfChanged(!showsOverflow)
    }

    /// The width "+N" takes for `hidden`, measured as text so sizing a candidate never changes what the
    /// label shows.
    private func overflowWidth(_ hidden: Int) -> CGFloat {
        let font = overflow.font ?? Self.countFont()
        return ceil(("+\(hidden)" as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func countFont() -> UIFont {
        .scaled(.caption2, monospacedDigits: true)
    }

    private static func styleCount(_ label: UILabel) {
        label.font = countFont()
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
}

// MARK: - Status marks

/// The strip's status line: one dot per member that needs the person or is in error, in its status tint,
/// "+N" for those past the cap, then one working mark for every working member with "×N" beside it when
/// more than one works. The view is always as tall as the tallest of a dot, the "+N" line, and the working mark,
/// shown or not, so the strip never changes height as members start and stop. Dot layers are reused across
/// `apply`s. VoiceOver hears the strip's own label, so nothing here is an element.
final class SessionThreadStatusMarksView: UIView {
    static let dotSize: CGFloat = 7
    static let dotSpacing: CGFloat = 4
    static let height: CGFloat = 14
    private static let gap: CGFloat = 4
    private static let countGap: CGFloat = 2

    private var dotLayers: [CALayer] = []
    private var shownCount = 0
    private let overflow = UILabel()
    let workingMark = WorkingMarkView(textStyle: .caption1)
    private let workingCount = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        for label in [overflow, workingCount] {
            label.font = UIFont.scaled(.caption2, monospacedDigits: true)
            label.adjustsFontForContentSizeCategory = true
            label.isHidden = true
            addSubview(label)
        }
        workingMark.isHidden = true
        addSubview(workingMark)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        // A change of text size resizes "+N", "×N", the working mark, and the line.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `dots` are the needs-you and error members (`SessionThreadStripSummary.dots`); `working` counts the
    /// working ones, drawn as the workingMark.
    func apply(_ dots: [SessionThreadStripSummary.Bucket], hiddenCount: Int, working: Int, style: SessionRowStyle) {
        shownCount = dots.count
        while dotLayers.count < dots.count {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
            dot.cornerRadius = Self.dotSize / 2
            layer.addSublayer(dot)
            dotLayers.append(dot)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dotLayers.enumerated() {
            dot.isHidden = index >= dots.count
            if index < dots.count { dot.backgroundColor = style.tint(dots[index].kind).cgColor }
        }
        CATransaction.commit()
        overflow.isHidden = hiddenCount == 0
        overflow.text = "+\(hiddenCount)"
        overflow.textColor = style.colors.comment

        workingMark.isHidden = working == 0
        if working > 0 { workingMark.apply(palette: style.themeID.palette) }
        workingCount.isHidden = working < 2
        workingCount.text = "×\(working)"
        workingCount.textColor = style.colors.comment
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The pieces shown, left to right, each with its width.
    private var pieces: [(view: AnyObject, width: CGFloat)] {
        var result: [(AnyObject, CGFloat)] = []
        if shownCount > 0 {
            result.append((layer, CGFloat(shownCount) * Self.dotSize + CGFloat(shownCount - 1) * Self.dotSpacing))
        }
        if !overflow.isHidden { result.append((overflow, overflow.intrinsicContentSize.width)) }
        if !workingMark.isHidden { result.append((workingMark, workingMark.side)) }
        if !workingCount.isHidden { result.append((workingCount, workingCount.intrinsicContentSize.width)) }
        return result
    }

    private func spacing(before view: AnyObject) -> CGFloat {
        view === workingCount ? Self.countGap : Self.gap
    }

    override var intrinsicContentSize: CGSize {
        let pieces = pieces
        let width = pieces.reduce(0) { $0 + $1.width }
            + pieces.dropFirst().reduce(0) { $0 + spacing(before: $1.view) }
        let height = max(Self.height, ceil(overflow.font.lineHeight), workingMark.side)
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            if index > 0 { x += spacing(before: piece.view) }
            if piece.view === layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for dot in 0..<shownCount {
                    dotLayers[dot].position = CGPoint(
                        x: x + CGFloat(dot) * (Self.dotSize + Self.dotSpacing) + Self.dotSize / 2,
                        y: bounds.midY
                    )
                }
                CATransaction.commit()
            } else if let view = piece.view as? UIView {
                let height = view === workingMark ? workingMark.side : view.intrinsicContentSize.height
                view.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: piece.width, height: height)
            }
            x += piece.width
        }
    }
}

// MARK: - Summary line

/// The strip's counts label: the counts the marks leave out, then the cross-workspace note, each kept only
/// while the whole of it fits. The note goes first and the counts truncate at the tail beside the cost's own
/// room on the same line. Every step measures with the label's own font at the width the line gave it, so a
/// width or text-size change refits the line instead of ellipsizing it.
final class SessionThreadSummaryLabel: UILabel {
    /// The counts, which a thread of only active members draws as nothing at all, and the note past them.
    private var counts = ""
    private var note: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // A text-size change rewrites the font, and so every candidate's width, with it.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (label: Self, _) in
            label.invalidateIntrinsicContentSize()
            label.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setCounts(_ counts: String, note: String?) {
        self.counts = counts
        self.note = note
        fit()
        invalidateIntrinsicContentSize()
    }

    /// The whole line, so the label asks for what it would like; the width it is given decides what fits.
    override var intrinsicContentSize: CGSize {
        let size = Self.width(of: fullLine, font: font)
        return CGSize(width: size, height: super.intrinsicContentSize.height)
    }

    /// What the counts alone need. They are never dropped, so this is the room they keep when the Agents
    /// share their line.
    var minimumWidth: CGFloat {
        Self.width(of: counts, font: font)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fit()
    }

    private static let separator = " \u{00B7} "

    private static func width(of text: String, font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private var fullLine: String {
        note.map { counts + Self.separator + $0 } ?? counts
    }

    /// The fit order: the counts with the note, then the counts alone, and past those the tail truncates.
    /// Before the line has a width, it asks for the whole of it.
    private func fit() {
        guard !counts.isEmpty else {
            if text != nil { text = nil }
            return
        }
        guard bounds.width > 0 else {
            if text != fullLine { text = fullLine }
            return
        }
        let showsNote = note != nil && Self.width(of: fullLine, font: font) <= bounds.width
        let shown = showsNote ? fullLine : counts
        if text != shown { text = shown }
    }
}
