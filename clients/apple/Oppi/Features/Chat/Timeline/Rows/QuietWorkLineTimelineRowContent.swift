import UIKit

struct QuietWorkLineTimelineRowConfiguration: UIContentConfiguration {
    let workLine: QuietTimelineWorkLine
    let onTap: () -> Void
    let isHighlighted: Bool
    let isSelected: Bool

    init(
        workLine: QuietTimelineWorkLine,
        onTap: @escaping () -> Void = {},
        isHighlighted: Bool = false,
        isSelected: Bool = false
    ) {
        self.workLine = workLine
        self.onTap = onTap
        self.isHighlighted = isHighlighted
        self.isSelected = isSelected
    }

    func makeContentView() -> any UIView & UIContentView {
        QuietWorkLineTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        guard let cellState = state as? UICellConfigurationState else { return self }
        return Self(
            workLine: workLine,
            onTap: onTap,
            isHighlighted: cellState.isHighlighted,
            isSelected: cellState.isSelected
        )
    }
}

/// Full-width compact-work strip. The whole row is the control; expanded vs
/// collapsed is fill, not a chevron. A leading icon mirrors the strip's most
/// recent activity (thinking sparkles, bash dollarsign, read magnifier, …)
/// so the strip reads as live agent work rather than a second user bubble.
final class QuietWorkLineTimelineRowContentView: UIView, UIContentView {
    private let chipView = UIView()
    private let button = UIButton(type: .system)
    private let iconView = UIImageView()
    private let summaryLabel = UILabel()
    private let iconTrailingToLabelLeading: NSLayoutConstraint
    /// Lower-priority fallback so the label pins to the chip edge whenever
    /// the icon chain is deactivated (strips with no sampled activities).
    private let labelFallbackLeadingConstraint: NSLayoutConstraint
    private var currentConfiguration: QuietWorkLineTimelineRowConfiguration
    private var appliedSymbolName: String?
    nonisolated(unsafe) private var durationTimer: Timer?
    private var durationStartedAt: Date?

    init(configuration: QuietWorkLineTimelineRowConfiguration) {
        // Icon hidden by default; the label-leading constraint flips to the
        // chip edge when the strip has no sampled activities.
        iconTrailingToLabelLeading = summaryLabel.leadingAnchor.constraint(
            equalTo: iconView.trailingAnchor, constant: 7
        )
        labelFallbackLeadingConstraint = summaryLabel.leadingAnchor.constraint(
            equalTo: chipView.leadingAnchor, constant: 14
        )
        labelFallbackLeadingConstraint.priority = UILayoutPriority(999)
        currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
        durationTimer?.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDurationTimer()
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let configuration = newValue as? QuietWorkLineTimelineRowConfiguration else { return }
            apply(configuration: configuration)
        }
    }

    private func setupViews() {
        backgroundColor = .clear
        chipView.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        chipView.isUserInteractionEnabled = false
        chipView.layer.cornerRadius = 10
        chipView.layer.cornerCurve = .continuous
        summaryLabel.isUserInteractionEnabled = false
        summaryLabel.numberOfLines = 1
        summaryLabel.textAlignment = .left
        summaryLabel.adjustsFontForContentSizeCategory = true
        let baseSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        summaryLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: baseSize, weight: .semibold)
        )
        summaryLabel.lineBreakMode = .byTruncatingTail

        iconView.isUserInteractionEnabled = false
        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 13, weight: .semibold
        )

        button.addAction(UIAction { [weak self] _ in
            self?.currentConfiguration.onTap()
        }, for: .primaryActionTriggered)

        addSubview(chipView)
        addSubview(button)
        addSubview(iconView)
        addSubview(summaryLabel)
        NSLayoutConstraint.activate([
            chipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chipView.topAnchor.constraint(equalTo: topAnchor),
            chipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: chipView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: chipView.trailingAnchor),
            button.topAnchor.constraint(equalTo: chipView.topAnchor),
            button.bottomAnchor.constraint(equalTo: chipView.bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            iconView.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconTrailingToLabelLeading,
            labelFallbackLeadingConstraint,
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: chipView.trailingAnchor, constant: -14),
            summaryLabel.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
        ])
    }

    private func apply(configuration: QuietWorkLineTimelineRowConfiguration) {
        currentConfiguration = configuration
        let palette = ThemeRuntimeState.currentPalette()
        let colors = Self.stripColors(
            workLine: configuration.workLine,
            isHighlighted: configuration.isHighlighted,
            palette: palette
        )
        chipView.backgroundColor = colors.fill
        // Hairline accent border keeps the strip in the tool-row family
        // (translucent accent fill) and clearly distinct from the opaque,
        // borderless user-message bubble.
        chipView.layer.borderWidth = 1 / max(1, traitCollection.displayScale)
        chipView.layer.borderColor = colors.border.cgColor
        summaryLabel.textColor = colors.foreground
        refreshDurationText()
        applyActivityIcon(workLine: configuration.workLine, foreground: colors.foreground)
        button.accessibilityValue = configuration.workLine.isLive
            ? "Working, \(configuration.workLine.accessibilityValue)"
            : configuration.workLine.accessibilityValue
        button.accessibilityHint = "Shows or hides work for this turn"
        button.accessibilityTraits = configuration.workLine.isExpanded ? [.button, .selected] : [.button]
        button.accessibilityIdentifier = configuration.workLine.id
        button.isAccessibilityElement = true
        isAccessibilityElement = false
        updateDurationTimer()
    }

    /// Translucent accent fills keep the strip in the tool-row family;
    /// `userMessageBg` is opaque in shipped themes, so matching it made the
    /// strip read as a second user bubble.
    private static func stripColors(
        workLine: QuietTimelineWorkLine,
        isHighlighted: Bool,
        palette: ThemePalette
    ) -> (fill: UIColor, foreground: UIColor, border: UIColor) {
        let accent = UIColor(palette.blue)
        let foreground = workLine.isLive ? accent : UIColor(palette.fg)
        let fillAlpha: CGFloat
        if isHighlighted {
            fillAlpha = 0.30
        } else if workLine.isLive {
            fillAlpha = 0.16
        } else if workLine.isExpanded {
            fillAlpha = 0.13
        } else {
            fillAlpha = 0.11
        }
        return (
            fill: accent.withAlphaComponent(fillAlpha),
            foreground: foreground,
            border: accent.withAlphaComponent(workLine.isLive ? 0.45 : 0.25)
        )
    }

    /// SF Symbol for one activity kind. Thinking gets its own glyph; known
    /// tools reuse the canonical expanded-row symbols; unknown/extension
    /// tools fall back to the generic code symbol.
    static func symbolName(forActivityKind kind: String) -> String {
        if kind == "thinking" { return "sparkles" }
        return ToolCallFormatting.sfSymbolName(for: kind)
            ?? "chevron.left.forwardslash.chevron.right"
    }

    private func applyActivityIcon(workLine: QuietTimelineWorkLine, foreground: UIColor) {
        guard let latestKind = workLine.activities.last else {
            iconView.isHidden = true
            iconTrailingToLabelLeading.isActive = false
            appliedSymbolName = nil
            return
        }
        iconView.isHidden = false
        if !iconTrailingToLabelLeading.isActive {
            iconTrailingToLabelLeading.isActive = true
        }
        iconView.tintColor = foreground

        let symbolName = Self.symbolName(forActivityKind: latestKind)
        guard symbolName != appliedSymbolName else { return }
        let image = UIImage(systemName: symbolName)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if appliedSymbolName != nil, window != nil, !reduceMotion, let image {
            // Follow-the-active-tool crossfade; skipped for first population.
            UIView.transition(
                with: iconView,
                duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.iconView.image = image
            }
        } else {
            iconView.image = image
        }
        appliedSymbolName = symbolName
    }

    /// Spoken label adds the activity breakdown so counts alone don't hide
    /// which tools ran.
    static func accessibilitySummary(for workLine: QuietTimelineWorkLine) -> String {
        var order: [String] = []
        for kind in workLine.activities where !order.contains(kind) {
            order.append(kind)
        }
        for kind in workLine.activityCounts.keys.sorted() where !order.contains(kind) {
            order.append(kind)
        }
        let base = workLine.summary
        guard !order.isEmpty else { return base }
        let breakdown = order.compactMap { kind -> String? in
            guard let count = workLine.activityCounts[kind] else { return nil }
            return count == 1 ? kind : "\(kind) \(count)"
        }.joined(separator: ", ")
        return "\(base). Used \(breakdown)"
    }

    private func refreshDurationText() {
        let text = currentConfiguration.workLine.displaySummary(now: Date())
        summaryLabel.text = text
        button.accessibilityLabel = Self.accessibilitySummary(for: currentConfiguration.workLine)
    }

    private func updateDurationTimer() {
        let startedAt = currentConfiguration.workLine.isLive
            ? currentConfiguration.workLine.liveStartedAt
            : nil
        guard window != nil, let startedAt else {
            durationTimer?.invalidate()
            durationTimer = nil
            durationStartedAt = nil
            return
        }
        if durationTimer != nil, durationStartedAt == startedAt {
            return
        }
        durationTimer?.invalidate()
        durationStartedAt = startedAt
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDurationText()
            }
        }
    }

}
