import UIKit

struct QuietWorkLineTimelineRowConfiguration: UIContentConfiguration {
    let workLine: QuietTimelineWorkLine
    let style: AppPreferences.ChatDisplay.WorkStripStyle
    let chromeStyle: ChatTimelineChromeStyle
    let onTap: () -> Void
    let isHighlighted: Bool
    let isSelected: Bool

    init(
        workLine: QuietTimelineWorkLine,
        style: AppPreferences.ChatDisplay.WorkStripStyle? = nil,
        chromeStyle: ChatTimelineChromeStyle = .standard,
        onTap: @escaping () -> Void = {},
        isHighlighted: Bool = false,
        isSelected: Bool = false
    ) {
        self.workLine = workLine
        self.style = style ?? workLine.displayStyle
        self.chromeStyle = chromeStyle
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
            chromeStyle: chromeStyle,
            onTap: onTap,
            isHighlighted: cellState.isHighlighted,
            isSelected: cellState.isSelected
        )
    }
}

/// Full-width compact-work strip. The whole row is the control; expanded vs
/// collapsed is fill, not a chevron. The configured density shows either
/// bucket icons with counts or a stable words summary.
///
/// Conversation chrome instead draws a leading pill that hugs
/// "Worked 9s \u{00B7} 2 steps \u{203A}"; the chevron turns down while expanded.
final class QuietWorkLineTimelineRowContentView: UIView, UIContentView {
    private static let liveBlinkAnimationKey = "oppi.quietWork.liveBlink"
    /// Conversation pill sits inside the 44 pt touch row.
    private static let conversationPillVerticalInset: CGFloat = 5

    private let chipView = UIView()
    private let button = UIButton(type: .system)
    private let summaryLabel = UILabel()
    private let durationLabel = UILabel()
    private let chevronView = UIImageView()
    private var standardConstraints: [NSLayoutConstraint] = []
    private var conversationConstraints: [NSLayoutConstraint] = []
    private var currentConfiguration: QuietWorkLineTimelineRowConfiguration
    nonisolated(unsafe) private var durationTimer: Timer?
    private var durationStartedAt: Date?
    private var lastSummaryIdentity: SummaryIdentity?

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
        updateLiveBlinkAnimation()
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

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.isUserInteractionEnabled = false
        chevronView.contentMode = .center
        chevronView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(chipView)
        addSubview(button)
        addSubview(summaryLabel)
        addSubview(durationLabel)
        addSubview(chevronView)
        // The button spans the chip horizontally and the full row vertically,
        // so the inset conversation pill keeps a 44 pt target.
        NSLayoutConstraint.activate([
            chipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.leadingAnchor.constraint(equalTo: chipView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: chipView.trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            summaryLabel.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
            durationLabel.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
            chevronView.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
        ])
        standardConstraints = [
            chipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chipView.topAnchor.constraint(equalTo: topAnchor),
            chipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            summaryLabel.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: 14),
            durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: 8),
            durationLabel.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -14),
        ]
        conversationConstraints = [
            chipView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            chipView.topAnchor.constraint(equalTo: topAnchor, constant: Self.conversationPillVerticalInset),
            chipView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.conversationPillVerticalInset),
            summaryLabel.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: 12),
            durationLabel.leadingAnchor.constraint(equalTo: summaryLabel.trailingAnchor, constant: 5),
            chevronView.leadingAnchor.constraint(equalTo: durationLabel.trailingAnchor, constant: 6),
            chevronView.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -12),
        ]
    }

    private func applyChromeLayout(_ chromeStyle: ChatTimelineChromeStyle) {
        let isConversation = chromeStyle == .conversation
        NSLayoutConstraint.deactivate(isConversation ? standardConstraints : conversationConstraints)
        NSLayoutConstraint.activate(isConversation ? conversationConstraints : standardConstraints)
        chevronView.isHidden = !isConversation
        // Standard strips truncate a long bucket summary; the pill's text is
        // short and must stay whole.
        summaryLabel.adjustsFontSizeToFitWidth = !isConversation
        durationLabel.textAlignment = isConversation ? .left : .right
        let baseSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: baseSize, weight: isConversation ? .regular : .semibold)
        )
        if summaryLabel.font != font {
            summaryLabel.font = font
            lastSummaryIdentity = nil
        }
    }

    private func apply(configuration: QuietWorkLineTimelineRowConfiguration) {
        currentConfiguration = configuration
        applyChromeLayout(configuration.chromeStyle)
        let palette = ThemeRuntimeState.currentPalette()
        let colors = Self.stripColors(
            workLine: configuration.workLine,
            isHighlighted: configuration.isHighlighted,
            chromeStyle: configuration.chromeStyle,
            palette: palette
        )
        chipView.backgroundColor = colors.fill
        switch configuration.chromeStyle {
        case .standard:
            // Hairline accent border keeps the strip in the tool-row family
            // (translucent accent fill) and clearly distinct from the opaque,
            // borderless user-message bubble.
            chipView.layer.cornerRadius = 10
            chipView.layer.borderWidth = 1 / max(1, traitCollection.displayScale)
            chipView.layer.borderColor = colors.border.cgColor
        case .conversation:
            chipView.layer.cornerRadius = 0
            chipView.layer.borderWidth = 0
            chipView.layer.borderColor = nil
            chevronView.image = UIImage(
                systemName: configuration.workLine.isExpanded ? "chevron.down" : "chevron.right"
            )
            chevronView.tintColor = colors.foreground
        }
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
        updateLiveBlinkAnimation()
    }

    /// Translucent accent fills keep the strip in the tool-row family;
    /// `userMessageBg` is opaque in shipped themes, so matching it made the
    /// strip read as a second user bubble.
    private static func stripColors(
        workLine: QuietTimelineWorkLine,
        isHighlighted: Bool,
        chromeStyle: ChatTimelineChromeStyle,
        palette: ThemePalette
    ) -> (fill: UIColor, foreground: UIColor, border: UIColor) {
        let accent = UIColor(palette.blue)
        if chromeStyle == .conversation {
            // Neutral pill beside the assistant card; only live work tints.
            let neutral = UIColor(palette.bgHighlight)
            let fill: UIColor
            if isHighlighted {
                fill = UIColor(palette.fgDim).withAlphaComponent(0.22)
            } else if workLine.isLive {
                fill = accent.withAlphaComponent(0.14)
            } else {
                fill = neutral
            }
            return (
                fill: fill,
                foreground: workLine.isLive ? accent : UIColor(palette.fgDim),
                border: .clear
            )
        }
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

    static func accessibilitySummary(
        for workLine: QuietTimelineWorkLine,
        chromeStyle: ChatTimelineChromeStyle = .standard,
        now: Date = Date()
    ) -> String {
        switch chromeStyle {
        case .standard: workLine.wordsSummary(now: now)
        case .conversation: workLine.conversationSummary(now: now)
        }
    }

    private func refreshDurationText(now: Date = Date()) {
        refreshSummaryIfNeeded()
        let workLine = currentConfiguration.workLine
        switch currentConfiguration.chromeStyle {
        case .standard: durationLabel.text = workLine.durationString(now: now)
        case .conversation: durationLabel.text = workLine.conversationDetail(now: now)
        }
        durationLabel.isHidden = durationLabel.text == nil
        button.accessibilityLabel = Self.accessibilitySummary(
            for: workLine,
            chromeStyle: currentConfiguration.chromeStyle,
            now: now
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if currentConfiguration.chromeStyle == .conversation {
            chipView.layer.cornerRadius = chipView.bounds.height / 2
        }
    }

    /// Duration ticks must not rewrite the summary. Rebuilding attributed text
    /// or restarting the blink is what made live Thinking… go still.
    private func refreshSummaryIfNeeded() {
        let workLine = currentConfiguration.workLine
        let colors = Self.stripColors(
            workLine: workLine,
            isHighlighted: currentConfiguration.isHighlighted,
            chromeStyle: currentConfiguration.chromeStyle,
            palette: ThemeRuntimeState.currentPalette()
        )
        let identity = SummaryIdentity(
            themeID: ThemeRuntimeState.currentThemeID(),
            style: currentConfiguration.style,
            chromeStyle: currentConfiguration.chromeStyle,
            isLive: workLine.isLive,
            isHighlighted: currentConfiguration.isHighlighted,
            isThinkingOnly: workLine.isThinkingOnly,
            work: workLine.workSummary,
            buckets: workLine.buckets
        )
        guard lastSummaryIdentity != identity else { return }
        lastSummaryIdentity = identity

        if currentConfiguration.chromeStyle == .conversation {
            summaryLabel.attributedText = Self.conversationTitle(
                for: workLine,
                foreground: colors.foreground,
                font: summaryLabel.font
            )
            return
        }

        if workLine.isThinkingOnly {
            summaryLabel.attributedText = nil
            summaryLabel.textColor = colors.foreground
            summaryLabel.text = workLine.workSummary
            return
        }
        // Do not assign summaryLabel.textColor here. UILabel would recolor the
        // whole attributed string and wipe the green/red edit counts.
        switch currentConfiguration.style {
        case .icons:
            summaryLabel.attributedText = Self.iconSummary(
                for: workLine,
                foreground: colors.foreground,
                font: summaryLabel.font
            )
        case .words:
            summaryLabel.text = nil
            summaryLabel.attributedText = Self.wordsSummary(
                for: workLine,
                foreground: colors.foreground,
                font: summaryLabel.font
            )
        }
    }

    static func liveBlinkAnimation(reduceMotion: Bool) -> CAAnimation? {
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
        updateLiveBlinkAnimation()
    }

    private func updateLiveBlinkAnimation() {
        let shouldBlink = window != nil
            && currentConfiguration.workLine.isLive
            && !UIAccessibility.isReduceMotionEnabled
        if shouldBlink {
            if summaryLabel.layer.animation(forKey: Self.liveBlinkAnimationKey) == nil,
               let animation = Self.liveBlinkAnimation(reduceMotion: false) {
                summaryLabel.layer.add(animation, forKey: Self.liveBlinkAnimationKey)
            }
            return
        }
        summaryLabel.layer.removeAnimation(forKey: Self.liveBlinkAnimationKey)
        summaryLabel.layer.opacity = 1
    }

    private struct SummaryIdentity: Equatable {
        let themeID: ThemeID
        let style: AppPreferences.ChatDisplay.WorkStripStyle
        let chromeStyle: ChatTimelineChromeStyle
        let isLive: Bool
        let isHighlighted: Bool
        let isThinkingOnly: Bool
        let work: String
        let buckets: [QuietWorkBucket]
    }

    /// Terminal glyph plus the pill verb. The detail (`9s \u{00B7} 2 steps`)
    /// lives in the duration label so the live tick never rebuilds this.
    private static func conversationTitle(
        for workLine: QuietTimelineWorkLine,
        foreground: UIColor,
        font: UIFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let symbol = workLine.isThinkingOnly ? "brain" : "apple.terminal"
        if let image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )?.withTintColor(foreground, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment(image: image)
            let height = image.size.height
            attachment.bounds = CGRect(
                x: 0,
                y: (font.capHeight - height) / 2,
                width: image.size.width,
                height: height
            )
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        }
        result.append(NSAttributedString(
            string: workLine.conversationTitle,
            attributes: [.font: font, .foregroundColor: foreground]
        ))
        return result
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
                    string: bucket.editStatsTitle + " ",
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
