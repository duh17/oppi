import UIKit

struct WorkingIndicatorTimelineRowConfiguration: UIContentConfiguration {
    let modelId: String?
    /// The row observes the working text and indicator here itself, so an
    /// extension's per-second elapsed text never reaches the timeline.
    let surface: SessionExtensionSurface?
    /// The running turn's folded work, once there is some
    /// (`ChatTimelineApplyPlan.workingRowLine`); nil draws the indicator alone.
    var work: WorkingRowWork?
    /// When the turn's prompt arrived: the indicator alone shows the turn's time
    /// from it, where a row with work shows its work's time instead.
    var turnStartedAt: Date?

    func makeContentView() -> any UIView & UIContentView {
        WorkingIndicatorTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

/// The running turn's folded work, carried by the working row: its time and
/// steps sit at the trailing end, and a tap opens or closes its steps exactly as
/// the line's own pill or strip does. Once the turn ends, the line draws as that
/// pill or strip again.
struct WorkingRowWork {
    let workLine: QuietTimelineWorkLine
    let chromeStyle: ChatTimelineChromeStyle
    let onTap: () -> Void
}

/// Working indicator row: [20x20 spinner][6pt gap][working text][time · steps ›],
/// starting at the row's leading edge like every other row's content. The
/// spinner (Metal orbs, braille dots, or Game of Life via Settings, or an
/// extension's frames) is its only moving part. The text sits in its own
/// column so an extension's working detail can join it later.
final class WorkingIndicatorTimelineRowContentView: UIView, UIContentView {
    private static let defaultCustomInterval: TimeInterval = 0.08
    private static let minCustomInterval: TimeInterval = 0.08
    private static let maxCustomInterval: TimeInterval = 60
    private static let spinnerSide: CGFloat = 20

    private let stackView = UIStackView()
    private let indicatorContainer = UIView()
    private let spinner = WorkingSpinnerUIView(side: spinnerSide)
    private let customIndicatorLabel = UILabel()
    private let textColumn = UIStackView()
    private let workingLabel = UILabel()
    private let workDetailLabel = UILabel()
    private let chevronView = UIImageView()
    /// The whole row's tap and accessibility element while it carries work.
    private let workButton = UIButton(type: .custom)
    nonisolated(unsafe) private var workTimer: Timer?

    private var currentConfiguration: WorkingIndicatorTimelineRowConfiguration
    nonisolated(unsafe) private var customTimer: Timer?
    private var customFrames: [String] = []
    private var customFrameIndex = 0
    private var customInterval = defaultCustomInterval
    /// The indicator last rendered, so a text-only change keeps the custom
    /// animation running instead of restarting it every tick.
    private var renderedIndicator: RenderedIndicator?

    private struct RenderedIndicator: Equatable {
        let indicator: ExtensionUIWorkingIndicator?
        let modelId: String?
    }

    init(configuration: WorkingIndicatorTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        customTimer?.invalidate()
        workTimer?.invalidate()
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? WorkingIndicatorTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    /// UIKit tracks the surface reads here and reruns this when they change.
    override func updateProperties() {
        super.updateProperties()
        let working = currentConfiguration.surface?.layout.working
        let indicator = RenderedIndicator(
            indicator: working?.indicator,
            modelId: currentConfiguration.modelId
        )
        if indicator != renderedIndicator {
            renderedIndicator = indicator
            renderIndicator(indicator)
        }
        showWorkingText(currentConfiguration.surface?.workingMessage ?? "Working...")
        refreshWork()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startCustomAnimationIfNeeded()
        } else {
            stopCustomAnimation()
        }
        updateWorkTimer()
    }

    private func setupViews() {
        backgroundColor = .clear

        stackView.translatesAutoresizingMaskIntoConstraints = false
        indicatorContainer.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        customIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        workingLabel.translatesAutoresizingMaskIntoConstraints = false
        workButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stackView)
        addSubview(workButton)
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6
        textColumn.axis = .vertical
        textColumn.addArrangedSubview(workingLabel)
        stackView.addArrangedSubview(indicatorContainer)
        stackView.addArrangedSubview(textColumn)
        stackView.addArrangedSubview(workDetailLabel)
        stackView.addArrangedSubview(chevronView)
        stackView.setCustomSpacing(10, after: textColumn)
        stackView.setCustomSpacing(4, after: workDetailLabel)

        workDetailLabel.font = .preferredFont(forTextStyle: .callout)
        workDetailLabel.adjustsFontForContentSizeCategory = true
        workDetailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        workDetailLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.contentMode = .center
        chevronView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        // The text column takes the room between the spinner and the work, wrapping
        // a long message rather than pushing the work off the row; the spinner
        // keeps its own width at the leading edge.
        indicatorContainer.setContentHuggingPriority(.required, for: .horizontal)
        let indicatorSnug = indicatorContainer.widthAnchor.constraint(equalToConstant: Self.spinnerSide)
        indicatorSnug.priority = .defaultLow
        indicatorSnug.isActive = true
        textColumn.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workButton.addAction(UIAction { [weak self] _ in
            self?.currentConfiguration.work?.onTap()
        }, for: .primaryActionTriggered)
        isAccessibilityElement = false

        indicatorContainer.addSubview(spinner)
        indicatorContainer.addSubview(customIndicatorLabel)

        workingLabel.text = "Working..."
        workingLabel.accessibilityIdentifier = "chat.timeline.working.text"
        workingLabel.font = .preferredFont(forTextStyle: .callout)
        customIndicatorLabel.font = AppFont.monoLarge
        customIndicatorLabel.textAlignment = .center
        customIndicatorLabel.adjustsFontForContentSizeCategory = true
        workingLabel.adjustsFontForContentSizeCategory = true
        workingLabel.numberOfLines = 0

        // At least a 44 pt touch row, with or without work, so the row keeps its
        // height when the turn's first steps fold into it.
        let minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimumHeight.priority = .required - 1
        let spinnerConstraints: [NSLayoutConstraint] = [
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            minimumHeight,
            workButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            workButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            workButton.topAnchor.constraint(equalTo: topAnchor),
            workButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            indicatorContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.spinnerSide),
            indicatorContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.spinnerSide),

            spinner.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: Self.spinnerSide),
            spinner.heightAnchor.constraint(equalToConstant: Self.spinnerSide),

            customIndicatorLabel.leadingAnchor.constraint(equalTo: indicatorContainer.leadingAnchor),
            customIndicatorLabel.trailingAnchor.constraint(equalTo: indicatorContainer.trailingAnchor),
            customIndicatorLabel.topAnchor.constraint(equalTo: indicatorContainer.topAnchor),
            customIndicatorLabel.bottomAnchor.constraint(equalTo: indicatorContainer.bottomAnchor),
        ]

        NSLayoutConstraint.activate(spinnerConstraints)
    }

    private func apply(configuration: WorkingIndicatorTimelineRowConfiguration) {
        currentConfiguration = configuration
        renderedIndicator = nil
        setNeedsUpdateProperties()
        // A fresh or reused cell is measured right after this, so render now.
        updatePropertiesIfNeeded()
        updateWorkTimer()
    }

    /// The turn's time and steps after the text, and the row's tap and
    /// accessibility as the work line's own control: the same identifier,
    /// value, hint, and traits, with the working text leading the label.
    private func refreshWork(now: Date = Date()) {
        let work = currentConfiguration.work
        let palette = ThemeRuntimeState.currentPalette()
        chevronView.isHidden = work == nil
        workButton.isHidden = work == nil
        // With work, the row's control is its one accessibility element.
        stackView.accessibilityElementsHidden = work != nil
        guard let work else {
            workButton.accessibilityIdentifier = nil
            let turnTime = currentConfiguration.turnStartedAt.map {
                QuietTimelineWorkLine.liveDurationString(since: $0, now: now)
            }
            workDetailLabel.isHidden = turnTime == nil
            workDetailLabel.attributedText = turnTime.map {
                NSAttributedString(string: $0, attributes: [.font: workDetailLabel.font as Any, .foregroundColor: palette.ui.fgDim])
            }
            return
        }
        workDetailLabel.isHidden = false
        let line = work.workLine
        workDetailLabel.attributedText = Self.workDetail(
            for: work,
            foreground: palette.ui.fgDim,
            font: workDetailLabel.font,
            now: now
        )
        chevronView.image = UIImage(systemName: line.isExpanded ? "chevron.down" : "chevron.right")
        chevronView.tintColor = palette.ui.fgDim
        workButton.isAccessibilityElement = true
        workButton.accessibilityIdentifier = line.id
        let workWords = switch work.chromeStyle {
        case .conversation: line.conversationDetail(now: now)
        case .standard: line.wordsSummary(now: now)
        }
        workButton.accessibilityLabel = [workingLabel.text, workWords].compactMap(\.self).joined(separator: ", ")
        workButton.accessibilityValue = "Working, \(line.accessibilityValue)"
        workButton.accessibilityHint = "Shows or hides work for this turn"
        workButton.accessibilityTraits = line.isExpanded ? [.button, .selected] : [.button]
    }

    /// What the work line's pill or strip says after its verb, in the row's dim
    /// style: the time and steps (`11s · 2 steps`), or a strip's own summary
    /// (icons or words) and time.
    static func workDetail(
        for work: WorkingRowWork,
        foreground: UIColor,
        font: UIFont,
        now: Date
    ) -> NSAttributedString {
        let line = work.workLine
        let plain: (String) -> NSAttributedString = {
            NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: foreground])
        }
        switch work.chromeStyle {
        case .conversation:
            return plain(line.conversationDetail(now: now) ?? "")
        case .standard:
            let duration = line.durationString(now: now)
            guard !line.isThinkingOnly else { return plain(duration ?? "") }
            let result = NSMutableAttributedString(attributedString: line.displayStyle == .icons
                ? QuietWorkLineTimelineRowContentView.iconSummary(for: line, foreground: foreground, font: font)
                : QuietWorkLineTimelineRowContentView.wordsSummary(for: line, foreground: foreground, font: font))
            if let duration { result.append(plain(" · \(duration)")) }
            return result
        }
    }

    /// The time after the text ticks each second while the row is on screen.
    private func updateWorkTimer() {
        let start = currentConfiguration.work.map(\.workLine.liveStartedAt) ?? currentConfiguration.turnStartedAt
        guard window != nil, start != nil else {
            workTimer?.invalidate()
            workTimer = nil
            return
        }
        guard workTimer == nil else { return }
        workTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWork() }
        }
    }

    /// A text that wraps to another line count changes the row's height, which
    /// the timeline caches; only then ask it to measure the row again.
    private func showWorkingText(_ text: String) {
        guard workingLabel.text != text else { return }
        let width = workingLabel.bounds.width
        let heightBefore = width > 0 ? workingLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height : 0
        workingLabel.text = text
        accessibilityLabel = text
        guard width > 0 else { return }
        let heightAfter = workingLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        if heightAfter != heightBefore {
            ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(startingAt: self)
        }
    }

    private func renderIndicator(_ rendered: RenderedIndicator) {
        let indicator = rendered.indicator
        let palette = ThemeRuntimeState.currentPalette()
        let providerColor = ProviderColor.color(for: rendered.modelId, palette: palette)
        let rawCustomFrames = indicator?.frames
        let customFrames = Self.displayableCustomFrames(rawCustomFrames)
        let hidesIndicator = rawCustomFrames?.isEmpty == true
        let showsCustomIndicator = customFrames?.isEmpty == false

        // Every Settings style draws; only an extension's empty frames hide it.
        spinner.isAnimating = !hidesIndicator && !showsCustomIndicator
        spinner.apply(tint: providerColor, palette: palette)
        customIndicatorLabel.isHidden = !showsCustomIndicator
        indicatorContainer.isHidden = hidesIndicator
        customIndicatorLabel.textColor = providerColor
        // Secondary text at full strength: an extension's status line has to be
        // readable (4.5:1 on `bg`), not a faint hint.
        workingLabel.textColor = palette.ui.fgDim

        configureCustomIndicator(
            frames: showsCustomIndicator ? customFrames : nil,
            intervalMs: indicator?.intervalMs
        )
    }

    private func configureCustomIndicator(frames: [String]?, intervalMs: Int?) {
        stopCustomAnimation()
        customFrameIndex = 0

        guard let frames else {
            customFrames = []
            customIndicatorLabel.text = nil
            return
        }

        customFrames = frames
        customInterval = Self.interval(from: intervalMs)
        customIndicatorLabel.text = frames.first ?? ""
        startCustomAnimationIfNeeded()
    }

    private static func displayableCustomFrames(_ frames: [String]?) -> [String]? {
        guard let frames else { return nil }
        guard !frames.isEmpty else { return [] }
        if frames.allSatisfy(containsOnlyPrivateUseScalarsOrWhitespace) {
            return nil
        }
        return frames
    }

    private static func containsOnlyPrivateUseScalarsOrWhitespace(_ frame: String) -> Bool {
        let scalars = frame.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        guard !scalars.isEmpty else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar.value {
            case 0xE000...0xF8FF,
                 0xF0000...0xFFFFD,
                 0x100000...0x10FFFD:
                return true
            default:
                return false
            }
        }
    }

    @objc private func reduceMotionStatusDidChange() {
        apply(configuration: currentConfiguration)
    }

    private func startCustomAnimationIfNeeded() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        guard window != nil, customTimer == nil, customFrames.count > 1 else { return }
        customTimer = Timer.scheduledTimer(withTimeInterval: customInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.customFrameIndex = (self.customFrameIndex + 1) % self.customFrames.count
                self.customIndicatorLabel.text = self.customFrames[self.customFrameIndex]
            }
        }
    }

    private func stopCustomAnimation() {
        customTimer?.invalidate()
        customTimer = nil
    }

    private static func interval(from intervalMs: Int?) -> TimeInterval {
        guard let intervalMs, intervalMs > 0 else { return defaultCustomInterval }
        let seconds = TimeInterval(intervalMs) / 1_000
        return min(max(seconds, minCustomInterval), maxCustomInterval)
    }
}
