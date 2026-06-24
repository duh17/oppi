import UIKit

struct WorkingIndicatorTimelineRowConfiguration: UIContentConfiguration {
    let modelId: String?
    let workingState: ExtensionWorkingState?

    func makeContentView() -> any UIView & UIContentView {
        WorkingIndicatorTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

/// Working indicator row: [10pt leading][16x16 spinner][6pt gap]["Working..." label]
/// Supports braille dots and Game of Life spinner styles via Settings.
final class WorkingIndicatorTimelineRowContentView: UIView, UIContentView {
    private static let defaultCustomInterval: TimeInterval = 0.08
    private static let minCustomInterval: TimeInterval = 0.08
    private static let maxCustomInterval: TimeInterval = 60

    private let stackView = UIStackView()
    private let indicatorContainer = UIView()
    private let brailleView = BrailleSpinnerUIView()
    private let golView = GameOfLifeUIView(gridSize: 6)
    private let customIndicatorLabel = UILabel()
    private let workingLabel = UILabel()

    private var currentConfiguration: WorkingIndicatorTimelineRowConfiguration
    nonisolated(unsafe) private var customTimer: Timer?
    private var customFrames: [String] = []
    private var customFrameIndex = 0
    private var customInterval = defaultCustomInterval

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
        stopCustomAnimation()
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? WorkingIndicatorTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startCustomAnimationIfNeeded()
        } else {
            stopCustomAnimation()
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        stackView.translatesAutoresizingMaskIntoConstraints = false
        indicatorContainer.translatesAutoresizingMaskIntoConstraints = false
        brailleView.translatesAutoresizingMaskIntoConstraints = false
        golView.translatesAutoresizingMaskIntoConstraints = false
        customIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        workingLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stackView)
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6
        stackView.addArrangedSubview(indicatorContainer)
        stackView.addArrangedSubview(workingLabel)

        indicatorContainer.addSubview(brailleView)
        indicatorContainer.addSubview(golView)
        indicatorContainer.addSubview(customIndicatorLabel)

        workingLabel.text = "Working..."
        workingLabel.font = .preferredFont(forTextStyle: .callout)
        customIndicatorLabel.font = AppFont.monoLarge
        customIndicatorLabel.textAlignment = .center
        customIndicatorLabel.adjustsFontForContentSizeCategory = true
        workingLabel.adjustsFontForContentSizeCategory = true
        workingLabel.numberOfLines = 0

        let spinnerConstraints: [NSLayoutConstraint] = [
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            indicatorContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            indicatorContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),

            // Braille spinner
            brailleView.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            brailleView.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
            brailleView.widthAnchor.constraint(equalToConstant: 16),
            brailleView.heightAnchor.constraint(equalToConstant: 16),

            // GoL spinner (same position)
            golView.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            golView.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
            golView.widthAnchor.constraint(equalToConstant: 16),
            golView.heightAnchor.constraint(equalToConstant: 16),

            customIndicatorLabel.leadingAnchor.constraint(equalTo: indicatorContainer.leadingAnchor),
            customIndicatorLabel.trailingAnchor.constraint(equalTo: indicatorContainer.trailingAnchor),
            customIndicatorLabel.topAnchor.constraint(equalTo: indicatorContainer.topAnchor),
            customIndicatorLabel.bottomAnchor.constraint(equalTo: indicatorContainer.bottomAnchor),
        ]

        NSLayoutConstraint.activate(spinnerConstraints)
    }

    private func apply(configuration: WorkingIndicatorTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = ThemeRuntimeState.currentPalette()
        let providerColor = UIColor(ProviderColor.color(for: configuration.modelId, palette: palette))
        let rawCustomFrames = configuration.workingState?.indicator?.frames
        let customFrames = Self.displayableCustomFrames(rawCustomFrames)
        let hidesIndicator = rawCustomFrames?.isEmpty == true
        let showsCustomIndicator = customFrames?.isEmpty == false

        let style = SpinnerStyle.current
        brailleView.isHidden = hidesIndicator || showsCustomIndicator || style != .brailleDots
        golView.isHidden = hidesIndicator || showsCustomIndicator || style != .gameOfLife
        customIndicatorLabel.isHidden = !showsCustomIndicator
        indicatorContainer.isHidden = hidesIndicator
            || (!showsCustomIndicator && style != .brailleDots && style != .gameOfLife)

        brailleView.tintUIColor = providerColor
        golView.tintUIColor = providerColor
        customIndicatorLabel.textColor = providerColor
        workingLabel.textColor = UIColor(palette.comment).withAlphaComponent(0.6)
        workingLabel.text = configuration.workingState?.message ?? "Working..."
        accessibilityLabel = workingLabel.text

        configureCustomIndicator(
            frames: showsCustomIndicator ? customFrames : nil,
            intervalMs: configuration.workingState?.indicator?.intervalMs
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
            guard let self else { return }
            self.customFrameIndex = (self.customFrameIndex + 1) % self.customFrames.count
            self.customIndicatorLabel.text = self.customFrames[self.customFrameIndex]
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
