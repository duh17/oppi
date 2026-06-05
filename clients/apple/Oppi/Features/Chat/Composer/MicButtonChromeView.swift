import SwiftUI
import UIKit

/// UIKit companion to `MicButtonLabel`.
///
/// Owns only the shared mic button chrome: idle mic, recording language/cloud
/// indicator with audio-reactive ring, and processing spinner. Callers own the
/// recording route and action wiring.
@MainActor
final class MicButtonChromeView: UIControl {
    private let fillView = UIView()
    private let ringLayer = CAShapeLayer()
    private let imageView = UIImageView()
    private let textLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var diameter: CGFloat = 44
    private var isRecording = false
    private var isProcessing = false
    private var audioLevel: Float = 0
    private var languageLabel: String?
    private var accentColor = UIColor(ThemeRuntimeState.currentPalette().blue)
    private var engineBadge: MicButtonLabel.EngineBadge = .auto

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.82 : (isEnabled ? 1 : 0.45)
        }
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.45
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: diameter, height: diameter)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fillView.frame = bounds
        fillView.layer.cornerRadius = min(bounds.width, bounds.height) / 2
        ringLayer.frame = bounds
        ringLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: ringLayer.lineWidth / 2, dy: ringLayer.lineWidth / 2)).cgPath
    }

    func apply(
        presentation: ComposerShared.MicButtonPresentation,
        accentColor: UIColor,
        diameter: CGFloat = 44,
        animated: Bool = true
    ) {
        apply(
            isRecording: presentation.isRecording,
            isProcessing: presentation.isBusy,
            audioLevel: presentation.audioLevel,
            languageLabel: presentation.languageLabel,
            accentColor: accentColor,
            engineBadge: presentation.engineBadge,
            diameter: diameter,
            animated: animated
        )
    }

    func apply(
        isRecording: Bool,
        isProcessing: Bool,
        audioLevel: Float,
        languageLabel: String?,
        accentColor: UIColor,
        engineBadge: MicButtonLabel.EngineBadge,
        diameter: CGFloat = 44,
        animated: Bool = true
    ) {
        self.isRecording = isRecording
        self.isProcessing = isProcessing
        self.audioLevel = audioLevel
        self.languageLabel = languageLabel
        self.accentColor = accentColor
        self.engineBadge = engineBadge
        if self.diameter != diameter {
            self.diameter = diameter
            invalidateIntrinsicContentSize()
        }
        updateAppearance(animated: animated)
    }

    private func setup() {
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)

        fillView.isUserInteractionEnabled = false
        addSubview(fillView)
        layer.addSublayer(ringLayer)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        textLabel.textAlignment = .center
        textLabel.adjustsFontSizeToFitWidth = true
        textLabel.minimumScaleFactor = 0.5
        textLabel.isUserInteractionEnabled = false
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        activityIndicator.hidesWhenStopped = true
        activityIndicator.isUserInteractionEnabled = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5),
            imageView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5),

            textLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.72),
            textLabel.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.62),

            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        let palette = ThemeRuntimeState.currentPalette()
        let indicator = indicatorColor(palette: palette)
        let clampedLevel = CGFloat(min(max(audioLevel, 0), 1))
        let lineWidth = isRecording ? 1.5 + clampedLevel * 2.0 : 1

        fillView.backgroundColor = UIColor(palette.bgHighlight)
        ringLayer.strokeColor = (isRecording
            ? indicator
            : indicator.withAlphaComponent(engineBadge == .auto ? 0.35 : 0.6)
        ).cgColor
        ringLayer.fillColor = UIColor.clear.cgColor

        if animated {
            let animation = CABasicAnimation(keyPath: "lineWidth")
            animation.fromValue = ringLayer.presentation()?.lineWidth ?? ringLayer.lineWidth
            animation.toValue = lineWidth
            animation.duration = 0.1
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ringLayer.add(animation, forKey: "lineWidth")
        }
        ringLayer.lineWidth = lineWidth
        setNeedsLayout()

        if isProcessing {
            imageView.isHidden = true
            textLabel.isHidden = true
            activityIndicator.startAnimating()
            activityIndicator.color = indicator
            return
        }

        activityIndicator.stopAnimating()

        if isRecording {
            if engineBadge == .remote {
                imageView.isHidden = false
                imageView.image = UIImage(systemName: "cloud")
                imageView.tintColor = indicator
                textLabel.isHidden = true
            } else {
                imageView.isHidden = true
                textLabel.isHidden = false
                textLabel.text = languageLabel ?? "??"
                textLabel.font = UIFont.systemFont(ofSize: diameter * 0.4, weight: .bold)
                textLabel.textColor = indicator
            }
        } else {
            imageView.isHidden = false
            imageView.image = UIImage(systemName: "mic")
            imageView.tintColor = indicator.withAlphaComponent(engineBadge == .auto ? 0.75 : 1)
            textLabel.isHidden = true
        }
    }

    private func indicatorColor(palette: ThemePalette) -> UIColor {
        if !isRecording && !isProcessing {
            return UIColor(palette.comment)
        }

        switch engineBadge {
        case .auto:
            return UIColor(palette.comment)
        case .onDevice:
            return accentColor
        case .remote:
            return UIColor(palette.cyan)
        }
    }
}
