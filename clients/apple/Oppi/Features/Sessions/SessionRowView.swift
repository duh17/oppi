import UIKit

// MARK: - Session Row

/// Unified session row used in every session list and the Session Rows preview.
///
/// Three-line layout:
/// ```
/// ◉ Title                                      [time]
/// model summary [compactions] [worktree] question prompt
/// ▬ 25% · $27.45 · [doc] 4  [status pill]
/// ```
///
/// A list row is one accessibility element whose label joins the visible
/// facts (`combinesAccessibility`); the preview keeps each fact its own
/// element so its checks can find them.
final class SessionRowView: UIView {
    struct Content: Equatable {
        let presentation: SessionRowPresentation
        var lockBadge: ScopedLockState = .none
        /// A locked session shows its name, time, and status only: no question
        /// text, search snippet, model, cost, context, or file counts.
        var hidesDetails = false
        /// Durable Sessions experiment: marks a durable-engine session, as the chat title does.
        var isDurable = false
    }

    /// Accessibility activation of a list row: the same open as a tap on the cell.
    var onActivate: (() -> Void)?
    /// Where the title and details start, past the identity icon.
    var textLeadingAnchor: NSLayoutXAxisAnchor { column.leadingAnchor }

    private let combinesAccessibility: Bool
    private var content: Content?
    private var display = SessionRowDisplay.standard
    private var style = SessionRowStyle.for(ThemeRuntimeState.currentThemeID())

    private let iconContainer = UIView()
    private let icon = SessionGridBadgeView()
    private let attentionDot = UIView()
    private let column = UIStackView()

    private let titleRow = UIStackView()
    private let titleLabel = UILabel()
    private let lockLabel = UILabel()
    private let durableLabel = UILabel()
    private let timeLabel = UILabel()
    private let snippetLabel = UILabel()

    /// Standard: context over metrics. Compact joins them in `firstRow` when they all fit.
    private let firstRow = UIStackView()
    private let secondRow = UIStackView()
    private let firstSpacer = SessionRowSpacer()
    private let secondSpacer = SessionRowSpacer()

    private let contextCluster = UIStackView()
    private let workspaceLabel = SessionRowWorkspaceView()
    private let modelStack = UIStackView()
    private let providerIcon = UIImageView()
    private let modelLabel = UILabel()
    private let compactionLabel = UILabel()
    private let worktreeIcon = UIImageView()
    private let attentionLabel = UILabel()
    private let mirrorIndicator = TerminalMirrorIndicatorUIView()

    private let metricsCluster = UIStackView()
    private let gauge = SessionContextGaugeView()
    private let incognitoBadge = InsetLabel(insets: UIEdgeInsets(top: 1, left: 6, bottom: 1, right: 6), capsule: true)
    private let costLabel = UILabel()
    private let filesLabel = UILabel()

    private let statusCluster = UIStackView()
    private let blockedBadge = UIImageView()
    private let statusLabel = UILabel()

    private var topPadding: NSLayoutConstraint?
    private var bottomPadding: NSLayoutConstraint?
    private var iconTop: NSLayoutConstraint?
    private var lastApplied: (display: SessionRowDisplay, themeID: ThemeID, iconAssetCache: IconAssetCache?)?
    private var joinsDetailRows = false
    private var clock: Timer?

    init(combinesAccessibility: Bool) {
        self.combinesAccessibility = combinesAccessibility
        super.init(frame: .zero)
        isAccessibilityElement = combinesAccessibility
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Apply

    func apply(_ content: Content, display: SessionRowDisplay, themeID: ThemeID, iconAssetCache: IconAssetCache?) {
        style = SessionRowStyle.for(themeID)
        self.content = content
        self.display = display
        let presentation = content.presentation
        let session = presentation.session
        let status = presentation.statusKind
        let colors = style.colors

        icon.configure(
            sessionId: session.id,
            agentId: session.launch?.agentId,
            agentIcon: session.launch?.agentIcon,
            iconAssetCache: iconAssetCache
        )
        attentionDot.isHidden = !status.needsAttention
        attentionDot.backgroundColor = style.tint(status)

        lastApplied = (display, themeID, iconAssetCache)
        column.spacing = display.isCompact ? 1 : 3
        let padding: CGFloat = display.isCompact ? 0 : 2
        topPadding?.constant = padding
        bottomPadding?.constant = padding
        // The icon sits 1 pt below the text's top.
        iconTop?.constant = padding + 1

        titleLabel.text = session.displayTitle
        titleLabel.textColor = colors.fg
        SessionRowText.setLockBadge(content.lockBadge, on: lockLabel, color: colors.comment)
        durableLabel.isHidden = !content.isDurable
        durableLabel.attributedText = SessionRowText.symbol("infinity", style: .caption2, weight: .semibold, color: colors.comment)
        durableLabel.accessibilityIdentifier = "session.durableMarker.\(session.id)"
        timeLabel.isHidden = !display.showsTime
        timeLabel.textColor = colors.comment
        updateTime()

        if content.hidesDetails {
            applyLocked(status: status, isIncognito: session.ephemeral == true)
        } else {
            applyDetails(presentation, status: status)
        }
        // Settle the arrangement for the width this row is drawn at before the
        // cell measures it. Compact joins its details only while they fit, and
        // that answer must not carry over from a wider or shorter row: an
        // arrangement left behind by the previous content does not match the
        // height the cell was measured with.
        _ = prepareLayout(width: bounds.width)
        setNeedsLayout()
        if window != nil { startClock() }
    }

    private func applyLocked(status: SessionStatusKind, isIncognito: Bool) {
        snippetLabel.isHidden = true
        contextCluster.isHidden = true
        mirrorIndicator.isHidden = true
        gauge.isHidden = true
        costLabel.isHidden = true
        filesLabel.isHidden = true
        incognitoBadge.isHidden = !isIncognito
        applyIncognito()
        metricsCluster.isHidden = !isIncognito
        applyStatus(status)
    }

    private func applyDetails(_ presentation: SessionRowPresentation, status: SessionStatusKind) {
        let session = presentation.session
        let colors = style.colors

        if let snippet = presentation.searchSnippet {
            snippetLabel.isHidden = false
            snippetLabel.attributedText = SessionRowText.snippet(snippet, color: colors.fgDim, highlight: colors.yellow)
        } else {
            snippetLabel.isHidden = true
        }

        // Context: workspace, model, compactions, worktree, the ask prompt.
        if let workspace = presentation.workspaceContext, !workspace.isEmpty {
            workspaceLabel.isHidden = false
            workspaceLabel.apply(workspace, color: colors.fgDim)
        } else {
            workspaceLabel.isHidden = true
        }

        let model = display.showsModel ? presentation.visibleModelSummaries.first : nil
        modelStack.isHidden = model == nil
        if let model {
            providerIcon.isHidden = model.provider.isEmpty
            if !model.provider.isEmpty {
                providerIcon.image = style.providerIcon(model.provider)
                providerIcon.accessibilityLabel = ProviderIcon.logoAssetName(for: model.provider) == nil
                    ? ProviderIcon.mark(for: model.provider)
                    : nil
            }
            modelLabel.text = model.label
            modelLabel.textColor = colors.fgDim
        }

        let compactions = display.showsCompactions ? (session.changeStats?.compactionCount ?? 0) : 0
        compactionLabel.isHidden = compactions == 0
        if compactions > 0 {
            compactionLabel.attributedText = SessionRowText.symbolAndText(
                "arrow.triangle.2.circlepath", "\(compactions)", style: .caption2, symbolWeight: .semibold,
                textWeight: .regular, monospacedDigits: true, color: colors.comment
            )
            compactionLabel.accessibilityLabel = SessionRowMetricsFormatting.compactionAccessibilityLabel(compactions)
        }

        let worktree = SessionWorktreeIndicatorPresentation(session: session)
        worktreeIcon.isHidden = worktree == nil
        if let worktree {
            worktreeIcon.image = UIImage.scaledSymbol("arrow.triangle.branch", style: .caption2, weight: .semibold)
            worktreeIcon.tintColor = colors.purple
            worktreeIcon.accessibilityLabel = worktree.accessibilityLabel
            worktreeIcon.accessibilityValue = worktree.worktreeId
        }

        if let attention = presentation.attentionText, !attention.isEmpty {
            attentionLabel.isHidden = false
            attentionLabel.text = attention
            attentionLabel.textColor = colors.fgDim
            attentionLabel.accessibilityIdentifier = "session.attentionPreview.\(session.id)"
        } else {
            attentionLabel.isHidden = true
        }
        contextCluster.isHidden = contextCluster.arrangedSubviews.allSatisfy(\.isHidden)

        let mirror = TerminalMirrorIndicatorPresentation(session: session)
        mirrorIndicator.isHidden = mirror == nil
        if let mirror { mirrorIndicator.apply(mirror) }

        // Metrics: context usage, Incognito, cost, files touched.
        let percent = display.showsContextUsage ? contextPercent(session) : nil
        gauge.isHidden = percent == nil
        if let percent { gauge.apply(percent: percent, colors: colors) }

        incognitoBadge.isHidden = session.ephemeral != true
        applyIncognito()

        let showsCost = display.showsCost && session.cost > 0
        costLabel.isHidden = !showsCost
        if showsCost {
            costLabel.text = SessionFormatting.costString(session.cost)
            costLabel.textColor = colors.fgDim
        }

        let files = display.showsFilesTouched ? (session.changeStats?.filesChanged ?? 0) : 0
        filesLabel.isHidden = files == 0
        if files > 0 {
            filesLabel.attributedText = SessionRowText.symbolAndText(
                "doc", "\(files)", style: .caption2, textStyle: .caption1, symbolWeight: .semibold,
                textWeight: .regular, monospacedDigits: true, color: Self.changeColor(files, colors: colors)
            )
            filesLabel.accessibilityLabel = SessionRowMetricsFormatting.filesTouchedAccessibilityLabel(files)
        }
        metricsCluster.isHidden = metricsCluster.arrangedSubviews.allSatisfy(\.isHidden)

        applyStatus(status)
    }

    private func applyStatus(_ status: SessionStatusKind) {
        let tint = style.tint(status)
        blockedBadge.isHidden = !status.isBlocked
        if status.isBlocked {
            blockedBadge.image = UIImage.scaledSymbol(status.badgeSymbol, style: .caption1, weight: .regular)
            blockedBadge.tintColor = tint
            blockedBadge.accessibilityIdentifier = content.map { "session.attentionBadge.\($0.presentation.session.id)" }
        }
        statusLabel.text = status.label
        statusLabel.font = UIFont.scaled(.caption2, status.needsAttention ? .semibold : .medium)
        statusLabel.textColor = tint
    }

    /// "Incognito" with its eye glyph on a purple capsule.
    private func applyIncognito() {
        guard !incognitoBadge.isHidden else { return }
        let purple = style.colors.purple
        incognitoBadge.attributedText = SessionRowText.symbolAndText(
            "eye.slash.fill", "Incognito", style: .caption2, symbolWeight: .medium, textWeight: .medium,
            spacing: 4, color: purple
        )
        incognitoBadge.backgroundColor = purple.withAlphaComponent(0.14)
        incognitoBadge.accessibilityLabel = "Incognito session"
    }

    private func contextPercent(_ session: Session) -> Double? {
        guard let used = session.contextTokens,
              let window = session.contextWindow ?? inferContextWindow(from: session.model ?? ""),
              window > 0 else { return nil }
        return min(max(Double(used) / Double(window), 0), 1)
    }

    private static func changeColor(_ filesChanged: Int, colors: ComposerThemeColors) -> UIColor {
        if filesChanged >= 25 { return colors.red }
        if filesChanged >= 10 { return colors.orange }
        return colors.green
    }

    // MARK: Compact rows

    /// Compact tries one line first and otherwise falls back to the same two
    /// rows as Standard, so density never hides or truncates a fact Standard
    /// would show. Called with the row's width before sizing and layout;
    /// returns whether the arrangement changed, and with it the row's height.
    @discardableResult
    func prepareLayout(width: CGFloat) -> Bool {
        // An unknown width cannot prove the facts fit on one line.
        guard let content, display.isCompact, !content.hidesDetails, width > 0 else {
            return arrangeDetailRows(joined: false)
        }
        let available = width - Self.iconWidth - Self.iconSpacing - Self.trailingInset
        return arrangeDetailRows(joined: joinedRowWidth() <= available)
    }

    private func joinedRowWidth() -> CGFloat {
        let fitting = UIView.layoutFittingCompressedSize
        var widths: [CGFloat] = []
        for view in [contextCluster, metricsCluster] where !view.isHidden {
            widths.append(view.systemLayoutSizeFitting(fitting).width)
        }
        widths.append(SessionRowSpacer.minWidth)
        if !mirrorIndicator.isHidden { widths.append(TerminalMirrorIndicatorUIView.size.width) }
        widths.append(statusCluster.systemLayoutSizeFitting(fitting).width)
        return widths.reduce(0, +) + CGFloat(widths.count - 1) * Self.detailSpacing
    }

    @discardableResult
    private func arrangeDetailRows(joined: Bool) -> Bool {
        let first: [UIView]
        let second: [UIView]
        if joined {
            first = [contextCluster, metricsCluster, firstSpacer, mirrorIndicator, statusCluster]
            second = []
        } else {
            first = [contextCluster, firstSpacer, mirrorIndicator]
            second = [metricsCluster, secondSpacer, statusCluster]
        }
        let firstHidden = content?.hidesDetails == true && !joined
            || !first.contains { $0 !== firstSpacer && !$0.isHidden }
        let secondHidden = second.isEmpty
        let rearranged = joined != joinsDetailRows
            || firstRow.arrangedSubviews != first
            || firstRow.isHidden != firstHidden
            || secondRow.isHidden != secondHidden
        if joined != joinsDetailRows || firstRow.arrangedSubviews != first {
            for view in firstRow.arrangedSubviews + secondRow.arrangedSubviews { view.removeFromSuperview() }
            first.forEach(firstRow.addArrangedSubview)
            second.forEach(secondRow.addArrangedSubview)
            joinsDetailRows = joined
        }
        firstRow.isHidden = firstHidden
        secondRow.isHidden = secondHidden
        return rearranged
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        prepareLayout(width: targetSize.width)
        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }

    override func layoutSubviews() {
        let rearranged = prepareLayout(width: bounds.width)
        super.layoutSubviews()
        // The details moved to another line, so the height the list measured
        // for this cell is stale. The list resizes a cell whose constraints
        // change (`selfSizingInvalidation`); the row must say so here, because
        // the new arrangement is made during layout, after the measure pass.
        if rearranged { invalidateIntrinsicContentSize() }
    }

    // MARK: Time

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            clock?.invalidate()
            clock = nil
        } else {
            updateTime()
            startClock()
        }
    }

    /// Running turns tick every second; finished ones every minute.
    private func startClock() {
        let interval: TimeInterval? = display.showsTime && content != nil
            ? (currentTurnStartedAt == nil ? 60 : 1)
            : nil
        // A reconfigure with the same cadence keeps the running clock.
        if let clock, clock.isValid, clock.timeInterval == interval { return }
        clock?.invalidate()
        clock = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private var currentTurnStartedAt: Date? {
        guard let session = content?.presentation.session else { return nil }
        switch session.status {
        case .starting, .busy, .stopping: return session.currentTurnStartedAt
        case .ready, .stopped, .error: return nil
        }
    }

    private func updateTime() {
        guard let session = content?.presentation.session else { return }
        let now = Date()
        let font: UIFont
        let text: String
        if let started = currentTurnStartedAt {
            font = UIFont.scaled(.caption2, monospacedDigits: true)
            text = SessionFormatting.durationString(since: started, now: now)
        } else {
            font = UIFont.scaled(.caption2)
            text = (session.lastAgentReplyAt ?? session.lastActivity).relativeString(relativeTo: now)
        }
        // Skip sets that change nothing.
        if timeLabel.font != font { timeLabel.font = font }
        if timeLabel.text != text { timeLabel.text = text }
    }

    // MARK: Accessibility

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    /// The facts a list row shows, in reading order.
    private var facts: [UIView] {
        [
            icon, titleLabel, lockLabel, durableLabel, timeLabel, snippetLabel,
            workspaceLabel, providerIcon, modelLabel, compactionLabel, worktreeIcon, attentionLabel, mirrorIndicator,
            gauge.valueLabel, incognitoBadge, costLabel, filesLabel, statusLabel,
        ].filter(\.isShownForAutomation)
    }

    /// UI tests also see each visible fact, as they saw the SwiftUI row's
    /// texts; VoiceOver reads the one combined element.
    override var automationElements: [Any]? {
        get { combinesAccessibility ? facts : super.automationElements }
        set { super.automationElements = newValue }
    }

    /// The visible facts joined, as SwiftUI's combined row spoke them. A
    /// provider without a logo speaks its monogram, as `ProviderIcon` did.
    override var accessibilityLabel: String? {
        get {
            guard combinesAccessibility else { return super.accessibilityLabel }
            return facts.compactMap(\.accessibilityLabel).filter { !$0.isEmpty }.joined(separator: ", ")
        }
        set { super.accessibilityLabel = newValue }
    }

    // MARK: Hierarchy

    private static let iconWidth: CGFloat = 24
    private static let iconSpacing: CGFloat = 8
    private static let trailingInset: CGFloat = 4
    private static let detailSpacing: CGFloat = 6

    private func buildHierarchy() {
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        attentionDot.translatesAutoresizingMaskIntoConstraints = false
        attentionDot.layer.cornerRadius = 4.5
        attentionDot.isAccessibilityElement = false
        iconContainer.addSubview(icon)
        iconContainer.addSubview(attentionDot)
        addSubview(iconContainer)

        titleLabel.font = UIFont.scaled(.body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        for label in [lockLabel, durableLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        durableLabel.accessibilityLabel = "Durable session"
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        let titleSpacer = SessionRowSpacer(minWidth: 4)
        titleRow.axis = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        [titleLabel, lockLabel, durableLabel, titleSpacer, timeLabel].forEach(titleRow.addArrangedSubview)

        snippetLabel.numberOfLines = 2
        snippetLabel.adjustsFontForContentSizeCategory = true

        // Context cluster.
        providerIcon.contentMode = .scaleAspectFit
        providerIcon.translatesAutoresizingMaskIntoConstraints = false
        modelLabel.font = UIFont.scaled(.caption2)
        modelLabel.adjustsFontForContentSizeCategory = true
        modelLabel.lineBreakMode = .byTruncatingMiddle
        modelLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        modelStack.axis = .horizontal
        modelStack.alignment = .center
        modelStack.spacing = 4
        modelStack.addArrangedSubview(providerIcon)
        modelStack.addArrangedSubview(modelLabel)
        compactionLabel.isAccessibilityElement = true
        compactionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        worktreeIcon.contentMode = .center
        worktreeIcon.isAccessibilityElement = true
        worktreeIcon.translatesAutoresizingMaskIntoConstraints = false
        attentionLabel.font = UIFont.scaled(.caption2)
        attentionLabel.adjustsFontForContentSizeCategory = true
        attentionLabel.lineBreakMode = .byTruncatingMiddle
        attentionLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        contextCluster.axis = .horizontal
        contextCluster.alignment = .center
        contextCluster.spacing = Self.detailSpacing
        [workspaceLabel, modelStack, compactionLabel, worktreeIcon, attentionLabel].forEach(contextCluster.addArrangedSubview)

        // Metrics cluster: caption, dimmed, one line.
        costLabel.font = UIFont.scaled(.caption1, monospacedDigits: true)
        costLabel.adjustsFontForContentSizeCategory = true
        filesLabel.isAccessibilityElement = true
        metricsCluster.axis = .horizontal
        metricsCluster.alignment = .center
        metricsCluster.spacing = Self.detailSpacing
        [gauge, incognitoBadge, costLabel, filesLabel].forEach(metricsCluster.addArrangedSubview)

        // Status cluster: a blocked session's badge, then the status word.
        blockedBadge.isAccessibilityElement = false
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .natural
        statusCluster.axis = .horizontal
        statusCluster.alignment = .center
        statusCluster.spacing = Self.detailSpacing
        statusCluster.addArrangedSubview(blockedBadge)
        statusCluster.addArrangedSubview(statusLabel)

        for view in [contextCluster, metricsCluster, statusCluster, mirrorIndicator] as [UIView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        metricsCluster.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusCluster.setContentCompressionResistancePriority(.required, for: .horizontal)
        for row in [firstRow, secondRow] {
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = Self.detailSpacing
        }

        column.axis = .vertical
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        [titleRow, snippetLabel, firstRow, secondRow].forEach(column.addArrangedSubview)
        addSubview(column)

        let top = column.topAnchor.constraint(equalTo: topAnchor, constant: 2)
        let bottom = bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: 2)
        let iconTop = iconContainer.topAnchor.constraint(equalTo: topAnchor, constant: 3)
        topPadding = top
        bottomPadding = bottom
        self.iconTop = iconTop
        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconTop,
            iconContainer.widthAnchor.constraint(equalToConstant: Self.iconWidth),
            iconContainer.heightAnchor.constraint(equalToConstant: Self.iconWidth),
            bottomAnchor.constraint(greaterThanOrEqualTo: iconContainer.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            attentionDot.widthAnchor.constraint(equalToConstant: 9),
            attentionDot.heightAnchor.constraint(equalToConstant: 9),
            attentionDot.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 3),
            attentionDot.topAnchor.constraint(equalTo: iconContainer.topAnchor, constant: -3),
            column.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: Self.iconSpacing),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            top,
            bottom,
            providerIcon.widthAnchor.constraint(equalToConstant: 11),
            providerIcon.heightAnchor.constraint(equalToConstant: 11),
            worktreeIcon.widthAnchor.constraint(equalToConstant: 16),
            worktreeIcon.heightAnchor.constraint(equalToConstant: 16),
        ])
        arrangeDetailRows(joined: false)
        // Glyphs and spacing are drawn at the text size they were applied with.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (row: SessionRowView, _) in
            guard let content = row.content, let applied = row.lastApplied else { return }
            row.apply(content, display: applied.display, themeID: applied.themeID, iconAssetCache: applied.iconAssetCache)
        }
    }
}

// MARK: - Pieces

/// The folder glyph and the workspace name, spoken as "Workspace <name>".
/// UI tests also see the name on its own, as they saw the SwiftUI row's text.
final class SessionRowWorkspaceView: UIStackView {
    private let glyph = UIImageView()
    private let nameLabel = UILabel()

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 3
        isAccessibilityElement = true
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(glyph)
        addArrangedSubview(nameLabel)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not supported") }

    func apply(_ workspace: String, color: UIColor) {
        glyph.image = UIImage.scaledSymbol("folder", style: .caption2, weight: .semibold)
        glyph.tintColor = color
        nameLabel.text = workspace
        nameLabel.font = UIFont.scaled(.caption2, .medium)
        nameLabel.textColor = color
        accessibilityLabel = "Workspace \(workspace)"
    }

    override var automationElements: [Any]? {
        get { [nameLabel] }
        set { super.automationElements = newValue }
    }
}

extension UIView {
    /// On screen: in the window with no hidden ancestor. A reused or removed
    /// cell keeps its labels, and UI tests must not find them.
    var isShownForAutomation: Bool {
        guard window != nil else { return false }
        var current: UIView? = self
        while let view = current {
            if view.isHidden || view.alpha == 0 { return false }
            current = view.superview
        }
        return true
    }
}

/// A flexible gap in a row with a minimum width, like SwiftUI's `Spacer(minLength:)`.
final class SessionRowSpacer: UIView {
    static let minWidth: CGFloat = 8

    init(minWidth: CGFloat = SessionRowSpacer.minWidth) {
        super.init(frame: .zero)
        isAccessibilityElement = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        // No height of its own, so it never sets a row's height.
        heightAnchor.constraint(equalToConstant: 0).isActive = true
        setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// Compact context usage indicator: a 24 × 4 capsule track and the percentage.
final class SessionContextGaugeView: UIStackView {
    private let track = UIView()
    private let fill = UIView()
    private let fillWidth: NSLayoutConstraint
    let valueLabel = UILabel()

    init() {
        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 4
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.layer.cornerRadius = 2
        fill.layer.cornerRadius = 2
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.widthAnchor.constraint(equalToConstant: 24),
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])
        valueLabel.font = UIFont.scaled(.caption1, monospacedDigits: true)
        valueLabel.adjustsFontForContentSizeCategory = true
        addArrangedSubview(track)
        addArrangedSubview(valueLabel)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not supported") }

    func apply(percent: Double, colors: ComposerThemeColors) {
        let clamped = min(max(percent, 0), 1)
        track.backgroundColor = colors.bgHighlight
        fill.backgroundColor = clamped > 0.9 ? colors.red : clamped > 0.7 ? colors.orange : colors.green
        fillWidth.constant = 24 * clamped
        valueLabel.text = "\(Int((clamped * 100).rounded()))%"
        valueLabel.textColor = colors.comment
    }
}

// MARK: - Style

/// The rows' colors, status tints, and provider marks for one theme, resolved
/// once per theme and shared by every row.
@MainActor
final class SessionRowStyle {
    let themeID: ThemeID
    let colors: ComposerThemeColors
    private let theme: AppTheme
    private var tints: [SessionStatusKind: UIColor] = [:]
    private var providerIcons: [String: UIImage] = [:]

    private static var current: SessionRowStyle?

    /// The shared style for `themeID`.
    static func `for`(_ themeID: ThemeID) -> SessionRowStyle {
        if let current, current.themeID == themeID { return current }
        let style = SessionRowStyle(themeID: themeID)
        current = style
        return style
    }

    private init(themeID: ThemeID) {
        self.themeID = themeID
        colors = ComposerThemeColors(palette: themeID.palette)
        theme = themeID.appTheme
    }

    func tint(_ status: SessionStatusKind) -> UIColor {
        if let tint = tints[status] { return tint }
        let tint = UIColor(status.tint(theme))
        tints[status] = tint
        return tint
    }

    /// The provider's 11 pt mark (`ProviderIcon`).
    func providerIcon(_ provider: String) -> UIImage {
        if let icon = providerIcons[provider] { return icon }
        let icon = ComposerProviderIconRenderer.image(provider: provider, size: 11, colors: colors)
        providerIcons[provider] = icon
        return icon
    }
}

/// Glyphs and attributed text for session rows, their Thread strip, and the
/// workspace sidebar.
@MainActor
enum SessionRowText {
    /// Rows configure while the list scrolls, so tinted glyphs are built once
    /// per text size and reused.
    private static var glyphs: [String: NSAttributedString] = [:]
    private static var glyphsCategory: UIContentSizeCategory?

    /// A glyph at the text style's size and weight, in `color`, on the text's line.
    static func symbol(
        _ name: String,
        style: UIFont.TextStyle,
        weight: UIFont.Weight,
        scale: UIImage.SymbolScale = .default,
        color: UIColor
    ) -> NSAttributedString {
        let category = UIApplication.shared.preferredContentSizeCategory
        if category != glyphsCategory {
            glyphsCategory = category
            glyphs.removeAll()
        }
        let key = "\(name)|\(style.rawValue)|\(weight.rawValue)|\(scale.rawValue)|\(color)"
        if let cached = glyphs[key] { return cached }
        let font = UIFont.scaled(style, weight)
        guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(font: font, scale: scale))?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return NSAttributedString() }
        let glyph = NSMutableAttributedString(attachment: NSTextAttachment(image: image))
        // The glyph's line takes the text style's height, not the label's default font.
        glyph.addAttribute(.font, value: font, range: NSRange(location: 0, length: glyph.length))
        glyphs[key] = glyph
        return glyph
    }

    /// A blank `width` points wide; kerning after an attachment does not move the next character.
    /// `font` keeps the line at the text's height.
    static func gap(_ width: CGFloat, font: UIFont) -> NSAttributedString {
        let spacer = NSTextAttachment()
        spacer.bounds = CGRect(x: 0, y: 0, width: width, height: 0)
        let gap = NSMutableAttributedString(attachment: spacer)
        gap.addAttribute(.font, value: font, range: NSRange(location: 0, length: gap.length))
        return gap
    }

    /// A glyph, `spacing` points, then text, on one baseline.
    static func symbolAndText(
        _ symbolName: String,
        _ text: String,
        style: UIFont.TextStyle,
        textStyle: UIFont.TextStyle? = nil,
        symbolWeight: UIFont.Weight,
        textWeight: UIFont.Weight,
        symbolScale: UIImage.SymbolScale = .default,
        monospacedDigits: Bool = false,
        spacing: CGFloat = 3,
        color: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            attributedString: symbol(symbolName, style: style, weight: symbolWeight, scale: symbolScale, color: color)
        )
        result.append(gap(spacing, font: .scaled(style, symbolWeight)))
        result.append(NSAttributedString(string: text, attributes: [
            .font: UIFont.scaled(textStyle ?? style, textWeight, monospacedDigits: monospacedDigits),
            .foregroundColor: color,
        ]))
        return result
    }

    /// `lock.fill` while locked, `lock.open.fill` while unlocked for now (`LockBadge`).
    static func setLockBadge(_ state: ScopedLockState, on label: UILabel, color: UIColor) {
        switch state {
        case .none:
            label.isHidden = true
            label.accessibilityIdentifier = nil
        case .locked, .unlocked:
            label.isHidden = false
            let locked = state == .locked
            label.attributedText = symbol(locked ? "lock.fill" : "lock.open.fill", style: .caption2, weight: .semibold, color: color)
            label.accessibilityLabel = locked ? "Locked" : "Unlocked"
            label.accessibilityIdentifier = locked ? "lockBadge.locked" : "lockBadge.unlocked"
        }
    }

    /// A search snippet with its matched runs bold in the theme's yellow.
    static func snippet(_ snippet: AttributedString, color: UIColor, highlight: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let regular = UIFont.scaled(.caption1)
        let bold = UIFont.scaled(.caption1, .bold)
        for run in snippet.runs {
            let matched = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            result.append(NSAttributedString(string: String(snippet[run.range].characters), attributes: [
                .font: matched ? bold : regular,
                .foregroundColor: matched ? highlight : color,
            ]))
        }
        return result
    }
}
