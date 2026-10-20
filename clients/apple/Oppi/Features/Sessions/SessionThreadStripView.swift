import UIKit

// MARK: - Inbox thread strip

/// Thread control under a thread root row: who is working, optional lane
/// graph and Agent summary, and totals. The list makes it the tap target
/// that opens Thread detail; the root row above it opens the root chat.
///
/// Agent summary and totals count every member, root included, so they agree
/// with the lane graph. The status counts and the working line cover the
/// children only: the root row above already shows its own status.
///
/// Display choices only hide the lane graph, the Agent summary, and the cost
/// total. The chevron, a blocked child, who is working, and the status
/// counts always stay.
final class SessionThreadStripView: UIControl {
    struct Content: Equatable {
        let rollup: SessionThreadRollup
        /// This device's status for each member: its seen state and pending asks applied.
        let statuses: [String: SessionStatusKind]
        /// Locked root: names and counts only, no lane graph, Agents, or cost.
        var hidesDetails = false
        /// A locked member: its cost stays out of the total.
        var hidesCost = false

        func status(_ session: Session) -> SessionStatusKind {
            statuses[session.id] ?? SessionThreadStatus.withoutSeenState(session)
        }

        /// A blocked child, shown so the user knows where to answer.
        var blockedMember: Session? {
            rollup.descendants.first { status($0).isBlocked }
        }
    }

    /// Leading inset that lines the strip up under the root row's identity icon.
    static let rowInset: CGFloat = 18

    private let stack = UIStackView()
    private let headline = UILabel()
    private let graphRow = UIStackView()
    private let graph = SessionThreadLaneGraphUIView()
    private let hiddenLanesLabel = UILabel()
    private let footer = UIStackView()
    private let agents = SessionThreadAgentClusterView()
    private let summaryLabel = UILabel()
    private let chevron = UIImageView()
    private var verticalPadding: [NSLayoutConstraint] = []
    private var summary = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous

        headline.adjustsFontForContentSizeCategory = true
        hiddenLanesLabel.font = SessionRowText.font(.caption2, monospacedDigits: true)
        hiddenLanesLabel.setContentHuggingPriority(.required, for: .horizontal)
        graphRow.axis = .horizontal
        graphRow.alignment = .center
        graphRow.spacing = 4
        graphRow.addArrangedSubview(graph)
        graphRow.addArrangedSubview(hiddenLanesLabel)
        let graphWidth = graphRow.widthAnchor.constraint(lessThanOrEqualToConstant: 260)
        let graphFill = graphRow.widthAnchor.constraint(equalToConstant: 260)
        graphFill.priority = .defaultHigh

        summaryLabel.font = SessionRowText.font(.caption1)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = SessionRowText.symbolImage("chevron.right", style: .caption1, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        agents.setContentCompressionResistancePriority(.required, for: .horizontal)
        footer.axis = .horizontal
        footer.alignment = .center
        footer.spacing = 8
        [agents, summaryLabel, SessionRowSpacer(minWidth: 4), chevron].forEach(footer.addArrangedSubview)

        stack.axis = .vertical
        stack.alignment = .leading
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        [headline, graphRow, footer].forEach(stack.addArrangedSubview)
        addSubview(stack)
        let top = stack.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        let bottom = bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 6)
        verticalPadding = [top, bottom]
        NSLayoutConstraint.activate([
            top, bottom,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headline.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            graphWidth,
            graphFill,
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

        let working = rollup.descendants.filter(SessionThreadGrouping.isWorking)
        if let blocked = content.blockedMember {
            let status = content.status(blocked)
            headline.isHidden = false
            headline.attributedText = SessionRowText.symbolAndText(
                status.badgeSymbol, "\(status.label) · \(blocked.displayTitle)", style: .footnote,
                symbolWeight: .semibold, textWeight: .semibold, spacing: 5, color: style.tint(status)
            )
            headline.lineBreakMode = .byTruncatingTail
        } else if !working.isEmpty {
            headline.isHidden = false
            headline.attributedText = NSAttributedString(
                string: working.map(\.displayTitle).joined(separator: " · ") + " working",
                attributes: [.font: SessionRowText.font(.footnote, .medium), .foregroundColor: colors.blue]
            )
            headline.lineBreakMode = .byTruncatingTail
        } else {
            headline.isHidden = true
        }

        let showsGraph = display.showsThreadLaneGraph && !content.hidesDetails
        graphRow.isHidden = !showsGraph
        if showsGraph {
            let layout = SessionThreadLaneGraph.layout(
                members: rollup.members,
                rootId: rollup.root.id,
                now: Date(),
                status: content.status
            )
            graph.apply(layout, style: style)
            hiddenLanesLabel.isHidden = layout.hiddenLaneCount == 0
            hiddenLanesLabel.text = "+\(layout.hiddenLaneCount)"
            hiddenLanesLabel.textColor = colors.comment
        }

        let showsAgents = display.showsThreadAgentSummary && !content.hidesDetails
        agents.isHidden = !showsAgents
        if showsAgents {
            agents.apply(SessionThreadAgentGroup.groups(rollup.members), maxGroups: 3, colors: colors, iconAssetCache: iconAssetCache)
        }

        let statusRollup = rollup.statusRollup(status: content.status)
        var parts: [String] = []
        if !statusRollup.summaryText.isEmpty { parts.append(statusRollup.summaryText) }
        // Same rule as a row: unknown or zero cost is absent, never "$0.00".
        if display.showsCost, !content.hidesDetails, !content.hidesCost, rollup.totalCost > 0 {
            parts.append(String(format: "$%.2f", rollup.totalCost))
        }
        if rollup.workspaceCount > 1 {
            parts.append("\(rollup.workspaceCount) workspaces")
        }
        summary = parts.joined(separator: " · ")
        summaryLabel.text = summary
        summaryLabel.textColor = colors.comment
        chevron.tintColor = colors.comment

        let blocked = content.blockedMember.map { "\(content.status($0).label) from \($0.displayTitle). " } ?? ""
        let headlineStatus = statusRollup.headline.map { "\($0.label). " } ?? ""
        accessibilityLabel = blocked + headlineStatus + "Thread with \(rollup.members.count) sessions, \(summary)"
        accessibilityValue = content.blockedMember.map { content.status($0).label } ?? ""
    }
}

// MARK: - Agent cluster

/// Agents present in a group of sessions, largest first: 🛠️×15 🔬×12 +2.
final class SessionThreadAgentClusterView: UIStackView {
    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 6
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not supported") }

    func apply(
        _ groups: [SessionThreadAgentGroup],
        maxGroups: Int,
        colors: ComposerThemeColors,
        iconAssetCache: IconAssetCache?
    ) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let font = SessionRowText.font(.caption2, monospacedDigits: true)
        for group in groups.prefix(maxGroups) {
            let item = UIStackView()
            item.axis = .horizontal
            item.alignment = .center
            item.spacing = 2
            let icon = SessionGridBadgeView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),
            ])
            icon.configure(
                sessionId: group.sampleSessionId,
                agentId: group.agentId,
                agentIcon: group.agentIcon,
                iconAssetCache: iconAssetCache
            )
            item.addArrangedSubview(icon)
            if group.count > 1 {
                item.addArrangedSubview(Self.label("×\(group.count)", font: font, color: colors.comment))
            }
            addArrangedSubview(item)
        }
        if groups.count > maxGroups {
            addArrangedSubview(Self.label("+\(groups.count - maxGroups)", font: font, color: colors.comment))
        }
    }

    private static func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }
}

// MARK: - Horizontal lane graph

/// Git-graph style thread overview: event order runs left to right, each
/// session has a lane from its launch to its last recorded activity, and
/// children branch from their parent's lane and merge back there. This
/// summarizes the thread; it is not an exact execution span. Working sessions
/// end in a pulsing dot at the right edge.
final class SessionThreadLaneGraphUIView: UIView {
    static let laneSpacing: CGFloat = 6
    static let inset: CGFloat = 4

    private var layout = SessionThreadLaneGraph(laneCount: 0, hiddenLaneCount: 0, segments: [])
    private var style = SessionRowStyle.for(ThemeRuntimeState.currentThemeID())
    private var pulses: [CALayer] = []
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: Self.inset * 2)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = false
        contentMode = .redraw
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint.isActive = true
        setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ layout: SessionThreadLaneGraph, style: SessionRowStyle) {
        self.layout = layout
        self.style = style
        heightConstraint.constant = CGFloat(max(layout.laneCount, 1) - 1) * Self.laneSpacing + Self.inset * 2
        setNeedsDisplay()
        setNeedsLayout()
        updatePulses()
    }

    private func updatePulses() {
        pulses.forEach { $0.removeFromSuperlayer() }
        pulses = layout.segments.filter(\.isWorking).map { segment in
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            dot.cornerRadius = 2.5
            dot.backgroundColor = style.tint(segment.status).cgColor
            dot.setValue(segment.lane, forKey: "lane")
            if !UIAccessibility.isReduceMotionEnabled {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.35
                pulse.duration = 0.6
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.isRemovedOnCompletion = false
                dot.add(pulse, forKey: "pulse")
            }
            layer.addSublayer(dot)
            return dot
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for dot in pulses {
            let lane = dot.value(forKey: "lane") as? Int ?? 0
            dot.position = CGPoint(x: bounds.width - Self.inset, y: Self.inset + CGFloat(lane) * Self.laneSpacing)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let usable = max(bounds.width - Self.inset * 2, 1)
        func x(_ value: Double) -> CGFloat { Self.inset + CGFloat(value) * usable }
        func y(_ lane: Int) -> CGFloat { Self.inset + CGFloat(lane) * Self.laneSpacing }
        let bend: CGFloat = 5
        context.setLineWidth(1.6)
        context.setLineCap(.round)

        for segment in layout.segments {
            let color = style.tint(segment.status)
            let startX = x(segment.start)
            let endX = max(x(segment.end), startX + 2)
            let laneY = y(segment.lane)

            guard let parentLane = segment.parentLane else {
                // Root lane: solid while it works, dashed while it waits on children.
                let idleX = segment.idleFrom.map { max(x($0), startX) } ?? endX
                context.setStrokeColor(color.cgColor)
                context.setLineDash(phase: 0, lengths: [])
                context.strokeLineSegments(between: [CGPoint(x: startX, y: laneY), CGPoint(x: idleX, y: laneY)])
                if idleX < endX {
                    context.setLineDash(phase: 0, lengths: [1.5, 3])
                    context.strokeLineSegments(between: [CGPoint(x: idleX, y: laneY), CGPoint(x: endX, y: laneY)])
                    context.setLineDash(phase: 0, lengths: [])
                }
                continue
            }

            let parentY = y(parentLane)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: startX, y: parentY))
            if parentY != laneY {
                path.addQuadCurve(to: CGPoint(x: startX + bend, y: laneY), controlPoint: CGPoint(x: startX, y: laneY))
            }
            path.addLine(to: CGPoint(x: endX, y: laneY))
            if segment.isStopped, parentY != laneY {
                path.addQuadCurve(to: CGPoint(x: endX + bend, y: parentY), controlPoint: CGPoint(x: endX + bend, y: laneY))
            }
            context.setLineDash(phase: 0, lengths: [])
            context.setStrokeColor(color.withAlphaComponent(segment.isStopped ? 0.55 : 1).cgColor)
            context.addPath(path.cgPath)
            context.strokePath()
        }
    }
}
