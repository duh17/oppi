import UIKit

struct WorkingIndicatorTimelineRowConfiguration: UIContentConfiguration {
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        WorkingIndicatorTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class WorkingIndicatorTimelineRowContentView: UIView, UIContentView {
    private let rootStack = UIStackView()
    private let symbolLabel = UILabel()
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []

    private var isAnimatingDots = false
    private var currentConfiguration: WorkingIndicatorTimelineRowConfiguration

    init(configuration: WorkingIndicatorTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
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
            startDotAnimationsIfNeeded()
        } else {
            stopDotAnimations()
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .horizontal
        rootStack.alignment = .center
        rootStack.spacing = 8

        symbolLabel.translatesAutoresizingMaskIntoConstraints = false
        symbolLabel.text = "π"
        symbolLabel.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)

        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.axis = .horizontal
        dotsStack.alignment = .center
        dotsStack.spacing = 4

        for _ in 0..<3 {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = 3
            dot.alpha = 0.6

            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])

            dotViews.append(dot)
            dotsStack.addArrangedSubview(dot)
        }

        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        rootStack.addArrangedSubview(symbolLabel)
        rootStack.addArrangedSubview(dotsStack)
        rootStack.addArrangedSubview(spacer)

        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    private func apply(configuration: WorkingIndicatorTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        symbolLabel.textColor = UIColor(palette.purple)
        for dot in dotViews {
            dot.backgroundColor = UIColor(palette.comment)
        }

        if window != nil {
            startDotAnimationsIfNeeded()
        }
    }

    private func startDotAnimationsIfNeeded() {
        guard !isAnimatingDots else { return }
        isAnimatingDots = true

        for dot in dotViews {
            dot.alpha = 0.58
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            return
        }

        let baseTime = CACurrentMediaTime()
        for (index, dot) in dotViews.enumerated() {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.46
            animation.toValue = 0.72
            animation.duration = 1.6
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.beginTime = baseTime + Double(index) * 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer.add(animation, forKey: "pulse")
        }
    }

    private func stopDotAnimations() {
        guard isAnimatingDots else { return }
        isAnimatingDots = false

        for dot in dotViews {
            dot.layer.removeAnimation(forKey: "pulse")
            dot.alpha = 0.58
        }
    }
}
