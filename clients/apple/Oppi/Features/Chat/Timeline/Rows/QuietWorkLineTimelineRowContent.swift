import UIKit

struct QuietWorkLineTimelineRowConfiguration: UIContentConfiguration {
    let workLine: QuietTimelineWorkLine
    let style: AppPreferences.ChatDisplay.WorkStripStyle
    let onTap: () -> Void
    let isHighlighted: Bool
    let isSelected: Bool

    init(
        workLine: QuietTimelineWorkLine,
        style: AppPreferences.ChatDisplay.WorkStripStyle? = nil,
        onTap: @escaping () -> Void = {},
        isHighlighted: Bool = false,
        isSelected: Bool = false
    ) {
        self.workLine = workLine
        self.style = style ?? workLine.displayStyle
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
            style: style,
            onTap: onTap,
            isHighlighted: cellState.isHighlighted,
            isSelected: cellState.isSelected
        )
    }
}

/// Full-width compact-work strip. The whole row is the control; expanded vs
/// collapsed is fill, not a chevron. The configured density shows either
/// bucket icons with counts or a stable words summary.
final class QuietWorkLineTimelineRowContentView: UIView, UIContentView {
    private static let thinkingBlinkAnimationKey = "oppi.quietWork.thinkingBlink"

    private let chipView = UIView()
    private let button = UIButton(type: .system)
    private let summaryLabel = UILabel()
    private let durationLabel = UILabel()
    private var currentConfiguration: QuietWorkLineTimelineRowConfiguration
    nonisolated(unsafe) private var durationTimer: Timer?
    private var durationStartedAt: Date?

    init(configuration: QuietWorkLineTimelineRowConfiguration) {
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
        updateThinkingAnimation()
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
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        chipView.isUserInteractionEnabled = false
        chipView.layer.cornerRadius = 10
        chipView.layer.cornerCurve = .continuous
        summaryLabel.isUserInteractionEnabled = false
        summaryLabel.numberOfLines = 1
        summaryLabel.textAlignment = .left
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.adjustsFontSizeToFitWidth = true
        summaryLabel.minimumScaleFactor = 0.75
        let baseSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        summaryLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: baseSize, weight: .semibold)
        )
        summaryLabel.lineBreakMode = .byTruncatingTail
        durationLabel.isUserInteractionEnabled = false
        durationLabel.numberOfLines = 1
        durationLabel.textAlignment = .right
        durationLabel.adjustsFontForContentSizeCategory = true
        durationLabel.font = summaryLabel.font
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )

        button.addAction(UIAction { [weak self] _ in
            self?.currentConfiguration.onTap()
        }, for: .primaryActionTriggered)

        addSubview(chipView)
        addSubview(button)
        addSubview(summaryLabel)
        addSubview(durationLabel)
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
            summaryLabel.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: 14),
            summaryLabel.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
            durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: 8),
            durationLabel.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -14),
            durationLabel.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
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
        durationLabel.textColor = colors.foreground
        durationLabel.font = summaryLabel.font
        refreshDurationText()
        button.accessibilityValue = configuration.workLine.isLive
            ? "Working, \(configuration.workLine.accessibilityValue)"
            : configuration.workLine.accessibilityValue
        button.accessibilityHint = "Shows or hides work for this turn"
        button.accessibilityTraits = configuration.workLine.isExpanded ? [.button, .selected] : [.button]
        button.accessibilityIdentifier = configuration.workLine.id
        button.isAccessibilityElement = true
        isAccessibilityElement = false
        updateDurationTimer()
        updateThinkingAnimation()
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
        let foreground = workLine.isLive ? accent : UIColor(palette.fgDim)
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

    static func symbolName(forActivityKind kind: String) -> String {
        switch ToolCallFormatting.normalized(kind) {
        case "read": return QuietWorkBucketKind.read.symbolName
        case "write": return QuietWorkBucketKind.write.symbolName
        case "edit": return QuietWorkBucketKind.edit.symbolName
        default: return QuietWorkBucketKind.tooling.symbolName
        }
    }

    static func accessibilitySummary(for workLine: QuietTimelineWorkLine, now: Date = Date()) -> String {
        workLine.wordsSummary(now: now)
    }

    private func refreshDurationText(now: Date = Date()) {
        let workLine = currentConfiguration.workLine
        let work = workLine.workSummary
        if workLine.isThinkingOnly {
            if summaryLabel.attributedText != nil || summaryLabel.text != work {
                summaryLabel.attributedText = nil
                summaryLabel.text = work
            }
        } else {
            switch currentConfiguration.style {
            case .icons:
                summaryLabel.attributedText = Self.iconSummary(
                    for: workLine,
                    foreground: summaryLabel.textColor,
                    font: summaryLabel.font
                )
            case .words:
                summaryLabel.text = nil
                summaryLabel.attributedText = Self.wordsSummary(
                    for: workLine,
                    foreground: summaryLabel.textColor,
                    font: summaryLabel.font
                )
            }
        }
        durationLabel.text = workLine.durationString(now: now)
        durationLabel.isHidden = durationLabel.text == nil
        button.accessibilityLabel = Self.accessibilitySummary(for: workLine, now: now)
    }

    static func thinkingBlinkAnimation(reduceMotion: Bool) -> CAAnimation? {
        guard !reduceMotion else { return nil }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.35
        animation.duration = 0.7
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    @objc private func reduceMotionStatusDidChange() {
        updateThinkingAnimation()
    }

    private func updateThinkingAnimation() {
        let shouldBlink = window != nil
            && currentConfiguration.workLine.isLive
            && currentConfiguration.workLine.isThinkingOnly
            && !UIAccessibility.isReduceMotionEnabled
        if shouldBlink {
            // Keep a running blink. Rewriting the label or removing this
            // animation every duration tick is what made Thinking… go still.
            if summaryLabel.layer.animation(forKey: Self.thinkingBlinkAnimationKey) == nil,
               let animation = Self.thinkingBlinkAnimation(reduceMotion: false) {
                summaryLabel.layer.add(animation, forKey: Self.thinkingBlinkAnimationKey)
            }
            return
        }
        summaryLabel.layer.removeAnimation(forKey: Self.thinkingBlinkAnimationKey)
        summaryLabel.layer.opacity = 1
    }

    private static func iconSummary(
        for workLine: QuietTimelineWorkLine,
        foreground: UIColor,
        font: UIFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, bucket) in workLine.buckets.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "   ", attributes: [.font: font]))
            }
            let attachment = NSTextAttachment()
            attachment.image = UIImage(
                systemName: bucket.kind.symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            )?.withTintColor(foreground, renderingMode: .alwaysOriginal)
            attachment.bounds = CGRect(x: 0, y: -2, width: 15, height: 15)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(
                string: " ",
                attributes: [.font: font, .foregroundColor: foreground]
            ))

            if bucket.kind == .edit, let stats = bucket.editStats {
                Self.appendEditStats(stats, to: result, font: font)
            } else {
                result.append(NSAttributedString(
                    string: "\(bucket.count)",
                    attributes: [.font: font, .foregroundColor: foreground]
                ))
            }
        }
        return result
    }

    static func wordsSummary(
        for workLine: QuietTimelineWorkLine,
        foreground: UIColor,
        font: UIFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, bucket) in workLine.buckets.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "  ",
                    attributes: [.font: font, .foregroundColor: foreground]
                ))
            }
            if bucket.kind == .edit, let stats = bucket.editStats {
                result.append(NSAttributedString(
                    string: "edit ",
                    attributes: [.font: font, .foregroundColor: foreground]
                ))
                Self.appendEditStats(stats, to: result, font: font)
            } else {
                result.append(NSAttributedString(
                    string: bucket.words,
                    attributes: [.font: font, .foregroundColor: foreground]
                ))
            }
        }
        return result
    }

    private static func appendEditStats(
        _ stats: QuietWorkBucket.EditStats,
        to result: NSMutableAttributedString,
        font: UIFont
    ) {
        let palette = ThemeRuntimeState.currentPalette()
        result.append(NSAttributedString(
            string: "+\(stats.added)",
            attributes: [.font: font, .foregroundColor: UIColor(palette.green)]
        ))
        result.append(NSAttributedString(
            string: " −\(stats.removed)",
            attributes: [.font: font, .foregroundColor: UIColor(palette.red)]
        ))
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
