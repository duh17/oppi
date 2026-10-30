import UIKit

// MARK: - Inbox thread strip

/// Thread control under a thread root row: who is working, a dot for each
/// active member, the Agent summary, and the status counts with the cost. The
/// list makes it the tap target that folds the thread's child rows open or
/// closed; the root row above it opens the root chat. The chevron turns down
/// while the thread is open.
///
/// The strip describes the children only: the working line, the dots, the
/// status counts, the Agent summary, and the VoiceOver child count all cover
/// the thread's other sessions, so they add up. The root row above already
/// shows its own status.
///
/// Display choices only hide the Agent summary and the cost total. The
/// chevron, a blocked child, who is working, the dots, and the status counts
/// always stay. The headline line and the dot line keep their height whether
/// or not any member is active, so a member changing state never moves the
/// rows below.
final class SessionThreadStripView: UIControl {
    struct Content: Equatable {
        let rollup: SessionThreadRollup
        /// This device's status for each member: its seen state and pending asks applied.
        let statuses: [String: SessionStatusKind]
        /// Locked root: names and counts only, no dots, Agents, or cost.
        var hidesDetails = false
        /// A locked member: its cost stays out of the total.
        var hidesCost = false
        /// The thread's child rows are listed under the root.
        var isExpanded = false

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
    private let statusRow = SessionThreadStatusRow()
    private var dots: SessionThreadStatusDotsView { statusRow.dots }
    private var agents: SessionThreadAgentClusterView { statusRow.agents }
    private let footer = UIStackView()
    private let summaryLabel = SessionThreadSummaryLabel()
    private let chevron = UIImageView()
    private var verticalPadding: [NSLayoutConstraint] = []
    private lazy var headlineHeight = headline.heightAnchor.constraint(equalToConstant: Self.headlineLineHeight())
    private var summary = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous

        headline.adjustsFontForContentSizeCategory = true
        headline.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = UIFont.scaled(.caption1)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = UIImage.scaledSymbol("chevron.right", style: .caption1, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        agents.setContentCompressionResistancePriority(.required, for: .horizontal)
        footer.axis = .horizontal
        footer.alignment = .center
        footer.spacing = 8
        [summaryLabel, SessionRowSpacer(minWidth: 4), chevron].forEach(footer.addArrangedSubview)

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
            headlineHeight,
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.headlineHeight.constant = Self.headlineLineHeight()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The headline line's height. It is always laid out at this height, empty or not, whether it names a
    /// blocked child (symbol and text) or the working ones (text), so a member changing state never moves
    /// the rows below the strip.
    private static func headlineLineHeight() -> CGFloat {
        let blocked = SessionRowText.symbolAndText(
            SessionStatusKind.question.badgeSymbol, "Ag", style: .footnote,
            symbolWeight: .semibold, textWeight: .semibold, spacing: 5, color: .label
        )
        let working = NSAttributedString(string: "Ag", attributes: [.font: UIFont.scaled(.footnote, .medium)])
        let unbounded = CGSize(width: 1_000, height: CGFloat.greatestFiniteMagnitude)
        return [blocked, working]
            .map { ceil($0.boundingRect(with: unbounded, options: .usesLineFragmentOrigin, context: nil).height) }
            .max() ?? 0
    }

    func apply(_ content: Content, display: SessionRowDisplay, style: SessionRowStyle, iconAssetCache: IconAssetCache?) {
        let colors = style.colors
        let rollup = content.rollup
        backgroundColor = colors.bgHighlight.withAlphaComponent(0.45)
        stack.spacing = display.isCompact ? 2 : 4
        for constraint in verticalPadding { constraint.constant = display.isCompact ? 4 : 6 }

        let working = rollup.descendants.filter(SessionThreadGrouping.isWorking)
        if let blocked = content.blockedMember {
            let status = content.status(blocked)
            headline.attributedText = SessionRowText.symbolAndText(
                status.badgeSymbol, "\(status.label) · \(blocked.displayTitle)", style: .footnote,
                symbolWeight: .semibold, textWeight: .semibold, spacing: 5, color: style.tint(status)
            )
            headline.lineBreakMode = .byTruncatingTail
        } else if !working.isEmpty {
            headline.attributedText = NSAttributedString(
                string: working.map(\.displayTitle).joined(separator: " · ") + " working",
                attributes: [.font: UIFont.scaled(.footnote, .medium), .foregroundColor: colors.blue]
            )
            headline.lineBreakMode = .byTruncatingTail
        } else {
            headline.attributedText = nil
        }

        let statusSummary = SessionThreadStripSummary(rollup: rollup, status: content.status)
        // The dots stay laid out, empty, when no member is active: the line keeps its height.
        statusRow.setHiddenIfChanged(content.hidesDetails)
        dots.apply(statusSummary.dots, hiddenCount: statusSummary.hiddenDotCount, style: style)

        let showsAgents = display.showsThreadAgentSummary && !content.hidesDetails
        agents.setHiddenIfChanged(!showsAgents)
        if showsAgents {
            agents.apply(SessionThreadAgentGroup.groups(Array(rollup.descendants)), maxGroups: 3, colors: colors, iconAssetCache: iconAssetCache)
        }

        let statusRollup = rollup.statusRollup(status: content.status)
        var parts: [String] = [statusSummary.text]
        // Same rule as a row: unknown or zero cost is absent, never "$0.00".
        if display.showsCost, !content.hidesDetails, !content.hidesCost, rollup.totalCost > 0 {
            parts.append(String(format: "$%.2f", rollup.totalCost))
        }
        if rollup.workspaceCount > 1 {
            parts.append("\(rollup.workspaceCount) workspaces")
        }
        summary = parts.joined(separator: " · ")
        summaryLabel.setParts(parts)
        summaryLabel.textColor = colors.comment
        chevron.tintColor = colors.comment
        let chevronTransform = CGAffineTransform(rotationAngle: content.isExpanded ? .pi / 2 : 0)
        if chevron.transform != chevronTransform {
            let animates = window != nil && !UIAccessibility.isReduceMotionEnabled
            UIView.animate(withDuration: animates ? 0.2 : 0) { self.chevron.transform = chevronTransform }
        }

        let blocked = content.blockedMember.map { "\(content.status($0).label) from \($0.displayTitle). " } ?? ""
        let headlineStatus = statusRollup.headline.map { "\($0.label). " } ?? ""
        let children = rollup.descendants.count
        accessibilityLabel = blocked + headlineStatus
            + "Thread with \(children) child \(children == 1 ? "session" : "sessions"), \(summary)"
        accessibilityValue = content.isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        accessibilityHint = content.isExpanded
            ? String(localized: "Hides the thread's sessions")
            : String(localized: "Shows the thread's sessions")
    }
}

// MARK: - Status row

/// The strip's dots on the left and Agents on the right. The dots keep their width; the Agents take what
/// is left and drop trailing groups to fit, so the row never overflows.
final class SessionThreadStatusRow: UIStackView {
    /// The least room the row keeps between the dots and the Agents. `layoutSubviews` fits the Agents in
    /// what is left after it, so the spacer and the fit read the same number.
    private static let spacerMinWidth: CGFloat = 4

    let dots = SessionThreadStatusDotsView()
    let agents = SessionThreadAgentClusterView()

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 8
        [dots, SessionRowSpacer(minWidth: Self.spacerMinWidth), agents].forEach(addArrangedSubview)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not supported") }

    override func layoutSubviews() {
        // Fit before `super`: `apply` unhides the Agent groups, and the row is wider than the strip until the
        // trailing groups fold into "+N". Fitting first hides them in this same pass, so the row never lays
        // out over-wide against its required width.
        if !agents.isHidden {
            agents.fit(maxWidth: bounds.width - dots.intrinsicContentSize.width - spacing * 2 - Self.spacerMinWidth)
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

// MARK: - Status dots

/// One dot per active thread member (working, needs you, error) in its status
/// tint, then "+N" for the members past the cap. Working dots pulse, until
/// Reduce Motion is turned on. The view is always as tall as `height` or the
/// "+N" line, with or without dots, so the strip never changes height as members
/// start and stop. Dot layers are reused across `apply`s.
final class SessionThreadStatusDotsView: UIView {
    static let dotSize: CGFloat = 7
    static let dotSpacing: CGFloat = 4
    static let height: CGFloat = 14
    private static let overflowGap: CGFloat = 4
    private static let pulseKey = "pulse"

    private var dotLayers: [CALayer] = []
    private var shownCount = 0
    private let overflow = UILabel()
    private var applied: (buckets: [SessionThreadStripSummary.Bucket], hiddenCount: Int, style: SessionRowStyle)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        overflow.font = UIFont.scaled(.caption2, monospacedDigits: true)
        overflow.adjustsFontForContentSizeCategory = true
        overflow.isHidden = true
        addSubview(overflow)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        // A change of text size resizes "+N" and the line; Reduce Motion stops or starts the pulse.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func motionPreferenceChanged() {
        guard let applied else { return }
        apply(applied.buckets, hiddenCount: applied.hiddenCount, style: applied.style)
    }

    func apply(_ buckets: [SessionThreadStripSummary.Bucket], hiddenCount: Int, style: SessionRowStyle) {
        applied = (buckets, hiddenCount, style)
        shownCount = buckets.count
        while dotLayers.count < buckets.count {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
            dot.cornerRadius = Self.dotSize / 2
            layer.addSublayer(dot)
            dotLayers.append(dot)
        }
        let pulses = !UIAccessibility.isReduceMotionEnabled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dotLayers.enumerated() {
            guard index < buckets.count else {
                dot.isHidden = true
                dot.removeAnimation(forKey: Self.pulseKey)
                continue
            }
            dot.isHidden = false
            dot.backgroundColor = style.tint(buckets[index].kind).cgColor
            if pulses, buckets[index] == .working {
                if dot.animation(forKey: Self.pulseKey) == nil {
                    let pulse = CABasicAnimation(keyPath: "opacity")
                    pulse.fromValue = 1.0
                    pulse.toValue = 0.35
                    pulse.duration = 0.6
                    pulse.autoreverses = true
                    pulse.repeatCount = .infinity
                    pulse.isRemovedOnCompletion = false
                    dot.add(pulse, forKey: Self.pulseKey)
                }
            } else {
                dot.removeAnimation(forKey: Self.pulseKey)
            }
        }
        CATransaction.commit()
        overflow.isHidden = hiddenCount == 0
        overflow.text = "+\(hiddenCount)"
        overflow.textColor = style.colors.comment
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private var dotsWidth: CGFloat {
        shownCount == 0 ? 0 : CGFloat(shownCount) * Self.dotSize + CGFloat(shownCount - 1) * Self.dotSpacing
    }

    override var intrinsicContentSize: CGSize {
        let overflowWidth = overflow.isHidden ? 0 : Self.overflowGap + overflow.intrinsicContentSize.width
        return CGSize(width: dotsWidth + overflowWidth, height: max(Self.height, ceil(overflow.font.lineHeight)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<shownCount {
            dotLayers[index].position = CGPoint(
                x: CGFloat(index) * (Self.dotSize + Self.dotSpacing) + Self.dotSize / 2,
                y: bounds.midY
            )
        }
        CATransaction.commit()
        let size = overflow.intrinsicContentSize
        overflow.frame = CGRect(
            x: dotsWidth + (shownCount == 0 ? 0 : Self.overflowGap),
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - Summary line

/// The strip's one-line summary: the status counts first, then the cost and
/// the cross-workspace note, each kept only while the whole of it fits. The
/// counts are never dropped; past the width they truncate like any label.
final class SessionThreadSummaryLabel: UILabel {
    private var parts: [String] = []

    func setParts(_ parts: [String]) {
        self.parts = parts
        fit()
        invalidateIntrinsicContentSize()
    }

    /// The full line, so the label asks for what it would like; layout decides what fits.
    override var intrinsicContentSize: CGSize {
        let size = Self.width(of: parts.joined(separator: Self.separator), font: font)
        return CGSize(width: size, height: super.intrinsicContentSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fit()
    }

    private static let separator = " \u{00B7} "

    private static func width(of text: String, font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func fit() {
        guard let first = parts.first else {
            if text != nil { text = nil }
            return
        }
        var shown = first
        if bounds.width > 0 {
            for part in parts.dropFirst() {
                let candidate = shown + Self.separator + part
                guard Self.width(of: candidate, font: font) <= bounds.width else { break }
                shown = candidate
            }
        } else {
            shown = parts.joined(separator: Self.separator)
        }
        if text != shown { text = shown }
    }
}
