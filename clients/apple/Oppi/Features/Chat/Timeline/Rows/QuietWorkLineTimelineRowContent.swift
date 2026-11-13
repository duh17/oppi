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
/// The pill's text never animates: while work runs, only its leading glyph
/// pulses, so the verb and the live counts read as one control.
final class QuietWorkLineTimelineRowContentView: UIView, UIContentView {
    private static let liveBlinkAnimationKey = "oppi.quietWork.liveBlink"

    private let chipView = TimelineChromeSurfaceView()
    private let button = UIButton(type: .system)
    /// The pill's terminal or thinking glyph, before its text.
    private let glyphView = UIImageView()
    private let summaryLabel = UILabel()
    private let durationLabel = UILabel()
    private let chevronView = UIImageView()
    private var standardConstraints: [NSLayoutConstraint] = []
    private var conversationConstraints: [NSLayoutConstraint] = []
    private var standardStackedConstraints: [NSLayoutConstraint] = []
    private var conversationStackedConstraints: [NSLayoutConstraint] = []
    private var stackedBottomWithDetail: NSLayoutConstraint?
    private var stackedBottomWithoutDetail: NSLayoutConstraint?
    /// Centres the glyph on the summary's first line; the constant follows the font.
    private var glyphCenterOnFirstLine: NSLayoutConstraint?
    /// The constraint set in force; `applyChromeLayout` swaps sets only when this changes.
    private var appliedLayout: ChromeLayout?
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
        summaryLabel.isUserInteractionEnabled = false
        summaryLabel.numberOfLines = 1
        summaryLabel.textAlignment = .left
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.adjustsFontSizeToFitWidth = true
        summaryLabel.minimumScaleFactor = 0.75
        summaryLabel.font = Self.font(weight: .semibold, compatibleWith: nil)
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

        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.isUserInteractionEnabled = false
        glyphView.contentMode = .center
        glyphView.setContentHuggingPriority(.required, for: .horizontal)
        glyphView.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(chipView)
        addSubview(button)
        addSubview(glyphView)
        addSubview(summaryLabel)
        addSubview(durationLabel)
        addSubview(chevronView)
        // The button spans the chip horizontally and the full row vertically,
        // so the inset conversation pill keeps a 44 pt touch target.
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: chipView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: chipView.trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            chevronView.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
        ])
        // The chip grows around its text, so a larger text size makes a taller
        // chip instead of text spilling out of a 44 pt one.
        let textInset = Self.textVerticalInset
        let contained = [
            summaryLabel.topAnchor.constraint(greaterThanOrEqualTo: chipView.topAnchor, constant: textInset),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: chipView.bottomAnchor, constant: -textInset),
            durationLabel.topAnchor.constraint(greaterThanOrEqualTo: chipView.topAnchor, constant: textInset),
            durationLabel.bottomAnchor.constraint(lessThanOrEqualTo: chipView.bottomAnchor, constant: -textInset),
        ]
        let centered = [
            summaryLabel.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
            durationLabel.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
        ]
        let strip = ChatTimelineChromeStyle.standard.workLine
        let stripEdges = [
            chipView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: strip.margins.leading),
            chipView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -strip.margins.trailing),
            chipView.topAnchor.constraint(equalTo: topAnchor, constant: strip.margins.top),
            chipView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -strip.margins.bottom),
        ]
        standardConstraints = stripEdges + contained + centered + [
            summaryLabel.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: strip.padding.leading),
            durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: 8),
            durationLabel.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -strip.padding.trailing),
        ]
        // The pill's glyph sits where its text used to start, and the text follows it.
        let glyphCenter = glyphView.centerYAnchor.constraint(equalTo: summaryLabel.firstBaselineAnchor)
        glyphCenterOnFirstLine = glyphCenter
        func glyphLeads(inset: CGFloat) -> [NSLayoutConstraint] {
            [
                glyphView.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: inset),
                summaryLabel.leadingAnchor.constraint(equalTo: glyphView.trailingAnchor, constant: Self.glyphTextGap),
                glyphCenter,
            ]
        }
        let pill = ChatTimelineChromeStyle.conversation.workLine
        let pillEdges = [
            chipView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pill.margins.leading),
            chipView.topAnchor.constraint(equalTo: topAnchor, constant: pill.margins.top),
            chipView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pill.margins.bottom),
        ]
        conversationConstraints = pillEdges + contained + centered + glyphLeads(inset: pill.padding.leading) + [
            chipView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pill.margins.trailing),
            durationLabel.leadingAnchor.constraint(equalTo: summaryLabel.trailingAnchor, constant: 5),
            chevronView.leadingAnchor.constraint(equalTo: durationLabel.trailingAnchor, constant: 6),
            chevronView.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -pill.padding.trailing),
        ]
        // Accessibility sizes: the summary wraps, the detail sits under it, and
        // the chip spans the row, since neither line fits beside the other.
        let stackedPadding = Self.stackedHorizontalPadding
        let stackedText = [
            summaryLabel.topAnchor.constraint(equalTo: chipView.topAnchor, constant: Self.stackedVerticalPadding),
            durationLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
            durationLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 2),
        ]
        // The chip ends under the detail line when there is one, else under the summary:
        // a hidden detail label leaves no gap. `syncStackedBottom` picks.
        stackedBottomWithDetail = durationLabel.bottomAnchor.constraint(equalTo: chipView.bottomAnchor, constant: -Self.stackedVerticalPadding)
        stackedBottomWithoutDetail = summaryLabel.bottomAnchor.constraint(equalTo: chipView.bottomAnchor, constant: -Self.stackedVerticalPadding)
        standardStackedConstraints = stripEdges + stackedText + [
            summaryLabel.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: stackedPadding),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: chipView.trailingAnchor, constant: -stackedPadding),
            durationLabel.trailingAnchor.constraint(lessThanOrEqualTo: chipView.trailingAnchor, constant: -stackedPadding),
        ]
        conversationStackedConstraints = pillEdges + stackedText + glyphLeads(inset: stackedPadding) + [
            chipView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pill.margins.trailing),
            chevronView.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -stackedPadding),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -6),
            durationLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -6),
        ]
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.apply(configuration: self.currentConfiguration)
        }
    }

    /// The subheadline at the standard text size (15 pt).
    private static let textBaseSize = UIFont.preferredFont(
        forTextStyle: .subheadline,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    ).pointSize

    private static let stackedCornerRadius: CGFloat = 18
    private static let glyphTextGap: CGFloat = 6
    private static let textVerticalInset: CGFloat = 6
    private static let stackedHorizontalPadding: CGFloat = 18
    private static let stackedVerticalPadding: CGFloat = 10

    private var isStacked: Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    private struct ChromeLayout: Equatable {
        let isConversation: Bool
        let isStacked: Bool

        @MainActor
        func constraints(in view: QuietWorkLineTimelineRowContentView) -> [NSLayoutConstraint] {
            switch (isConversation, isStacked) {
            case (false, false): view.standardConstraints
            case (true, false): view.conversationConstraints
            case (false, true): view.standardStackedConstraints
            case (true, true): view.conversationStackedConstraints
            }
        }
    }

    /// The row's text font: the subheadline's standard-size base, scaled once.
    /// `preferredFont(...).pointSize` is already scaled at an accessibility size,
    /// so the base comes from the standard size instead.
    private static func font(weight: UIFont.Weight, compatibleWith traits: UITraitCollection?) -> UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: textBaseSize, weight: weight),
            compatibleWith: traits
        )
    }

    private func applyChromeLayout(_ chromeStyle: ChatTimelineChromeStyle) {
        let isConversation = chromeStyle == .conversation
        // A highlight or stream update reapplies the same layout: touching constraints
        // there would force the timeline cell to size itself again.
        let layout = ChromeLayout(isConversation: isConversation, isStacked: isStacked)
        if layout != appliedLayout {
            if let appliedLayout { NSLayoutConstraint.deactivate(appliedLayout.constraints(in: self)) }
            NSLayoutConstraint.activate(layout.constraints(in: self))
            appliedLayout = layout
        }
        syncStackedBottom()
        chevronView.isHidden = !isConversation
        glyphView.isHidden = !isConversation
        // Standard strips truncate a long bucket summary; the pill's text is
        // short and must stay whole. At accessibility sizes both wrap instead.
        summaryLabel.adjustsFontSizeToFitWidth = !isConversation && !isStacked
        summaryLabel.numberOfLines = isStacked ? 0 : 1
        durationLabel.numberOfLines = isStacked ? 0 : 1
        durationLabel.textAlignment = isConversation || isStacked ? .left : .right
        let font = Self.font(weight: isConversation ? .regular : .semibold, compatibleWith: traitCollection)
        if summaryLabel.font != font {
            summaryLabel.font = font
            lastSummaryIdentity = nil
            glyphView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                font: .systemFont(ofSize: (font.pointSize * 0.8).rounded(), weight: .semibold)
            )
            glyphCenterOnFirstLine?.constant = -font.capHeight / 2
        }
    }

    /// Stacked, the chip's bottom edge follows the detail line while it shows.
    private func syncStackedBottom() {
        let stacked = appliedLayout?.isStacked == true
        let showsDetail = !durationLabel.isHidden
        stackedBottomWithDetail?.isActive = stacked && showsDetail
        stackedBottomWithoutDetail?.isActive = stacked && !showsDetail
    }

    private func apply(configuration: QuietWorkLineTimelineRowConfiguration) {
        currentConfiguration = configuration
        applyChromeLayout(configuration.chromeStyle)
        let colors = configuration.chromeStyle.workLineColors(
            for: configuration.workLine,
            isHighlighted: configuration.isHighlighted,
            palette: ThemeRuntimeState.currentPalette()
        )
        // A capsule is for one line; a wrapped, two-line pill is a rounded rectangle.
        chipView.shape = configuration.chromeStyle == .conversation && isStacked
            ? .roundedRect(radius: Self.stackedCornerRadius, curve: .continuous)
            : configuration.chromeStyle.workLine.shape
        chipView.backgroundColor = colors.fill
        switch configuration.chromeStyle {
        case .standard:
            // Hairline accent border keeps the strip in the tool-row family
            // (translucent accent fill) and clearly distinct from the opaque,
            // borderless user-message bubble.
            chipView.layer.borderWidth = 1 / max(1, traitCollection.displayScale)
            chipView.layer.borderColor = colors.border.cgColor
        case .conversation:
            chipView.layer.borderWidth = 0
            chipView.layer.borderColor = nil
            chevronView.image = UIImage(
                systemName: configuration.workLine.isExpanded ? "chevron.down" : "chevron.right"
            )
            chevronView.tintColor = colors.foreground
            let glyph = configuration.workLine.isThinkingOnly ? "brain" : "apple.terminal"
            if glyphView.image != UIImage(systemName: glyph) {
                glyphView.image = UIImage(systemName: glyph)
            }
            glyphView.tintColor = colors.foreground
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
        syncStackedBottom()
        button.accessibilityLabel = Self.accessibilitySummary(
            for: workLine,
            chromeStyle: currentConfiguration.chromeStyle,
            now: now
        )
    }

    /// Duration ticks must not rewrite the summary. Rebuilding attributed text
    /// or restarting the blink is what made live Thinking… go still.
    private func refreshSummaryIfNeeded() {
        let workLine = currentConfiguration.workLine
        let colors = currentConfiguration.chromeStyle.workLineColors(
            for: workLine,
            isHighlighted: currentConfiguration.isHighlighted,
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

    /// Live work's one activity cue. The strip blinks its summary; the pill
    /// pulses only its glyph, since blinking the verb beside the steady counts
    /// split the pill in two. Reduce Motion stills both.
    private func updateLiveBlinkAnimation() {
        let isLive = window != nil
            && currentConfiguration.workLine.isLive
            && !UIAccessibility.isReduceMotionEnabled
        let isPill = currentConfiguration.chromeStyle == .conversation
        if isLive, !isPill {
            if summaryLabel.layer.animation(forKey: Self.liveBlinkAnimationKey) == nil,
               let animation = Self.liveBlinkAnimation(reduceMotion: false) {
                summaryLabel.layer.add(animation, forKey: Self.liveBlinkAnimationKey)
            }
        } else {
            summaryLabel.layer.removeAnimation(forKey: Self.liveBlinkAnimationKey)
            summaryLabel.layer.opacity = 1
        }
        if isLive, isPill {
            if !isGlyphPulsing {
                glyphView.addSymbolEffect(.pulse, options: .repeat(.continuous))
                isGlyphPulsing = true
            }
        } else if isGlyphPulsing {
            glyphView.removeAllSymbolEffects(animated: false)
            isGlyphPulsing = false
        }
    }

    /// The glyph's pulse is running; `UIImageView` cannot say so itself.
    private var isGlyphPulsing = false

    #if DEBUG
        var isGlyphPulsingForTesting: Bool { isGlyphPulsing }
    #endif

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

    /// The pill verb. The glyph is `glyphView`, and the detail
    /// (`9s \u{00B7} 2 steps`) lives in the duration label so the live tick
    /// never rebuilds this.
    private static func conversationTitle(
        for workLine: QuietTimelineWorkLine,
        foreground: UIColor,
        font: UIFont
    ) -> NSAttributedString {
        NSAttributedString(
            string: workLine.conversationTitle,
            attributes: [.font: font, .foregroundColor: foreground]
        )
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
            attributes: [.font: font, .foregroundColor: palette.ui.green]
        ))
        result.append(NSAttributedString(
            string: " −\(stats.removed)",
            attributes: [.font: font, .foregroundColor: palette.ui.red]
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
