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
    private let orbView = ThinkingOrbMetalView(style: .composing, sizeClass: .dictationStandard)
    private let imageView = UIImageView()
    private let textLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var diameter: CGFloat = 44
    private var isRecording = false
    private var isPreparing = false
    private var isProcessing = false
    private var voiceSpectrum: VoiceSpectrumFrame = .zero
    private var languageLabel: String?
    private var accentColor = UIColor(ThemeRuntimeState.currentPalette().blue)
    private var engineBadge: MicButtonLabel.EngineBadge = .auto
    private var dictationStyle: DictationIndicatorStyle = .current

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
        let radius = min(bounds.width, bounds.height) / 2
        layer.cornerRadius = radius
        fillView.frame = bounds
        fillView.layer.cornerRadius = radius
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
            isProcessing: presentation.isProcessing,
            voiceSpectrum: presentation.voiceSpectrum,
            languageLabel: presentation.languageLabel,
            accentColor: accentColor,
            engineBadge: presentation.engineBadge,
            diameter: diameter,
            animated: animated,
            isPreparing: presentation.isPreparing
        )
    }

    func apply(
        isRecording: Bool,
        isProcessing: Bool,
        voiceSpectrum: VoiceSpectrumFrame,
        languageLabel: String?,
        accentColor: UIColor,
        engineBadge: MicButtonLabel.EngineBadge,
        diameter: CGFloat = 44,
        animated: Bool = true,
        isPreparing: Bool = false
    ) {
        self.isRecording = isRecording
        self.isPreparing = isPreparing
        self.isProcessing = isProcessing
        self.voiceSpectrum = voiceSpectrum
        self.languageLabel = languageLabel
        self.accentColor = accentColor
        self.engineBadge = engineBadge
        self.dictationStyle = DictationIndicatorStyle.current
        if self.diameter != diameter {
            self.diameter = diameter
            invalidateIntrinsicContentSize()
        }
        updateAppearance(animated: animated)
    }

    private func setup() {
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)

        clipsToBounds = true
        fillView.isUserInteractionEnabled = false
        addSubview(fillView)
        layer.addSublayer(ringLayer)
        orbView.isUserInteractionEnabled = false
        orbView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(orbView)

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
            orbView.leadingAnchor.constraint(equalTo: leadingAnchor),
            orbView.trailingAnchor.constraint(equalTo: trailingAnchor),
            orbView.topAnchor.constraint(equalTo: topAnchor),
            orbView.bottomAnchor.constraint(equalTo: bottomAnchor),

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dictationStyleDidChange),
            name: AppPreferenceStore.Appearance.dictationIndicatorDidChangeNotification,
            object: nil
        )
        updateAppearance(animated: false)
    }

    @objc private func dictationStyleDidChange() {
        dictationStyle = DictationIndicatorStyle.current
        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        let palette = ThemeRuntimeState.currentPalette()
        let indicator = indicatorColor(palette: palette)
        let listeningChrome = isRecording || isPreparing
        let spectrum = isRecording ? voiceSpectrum : .zero
        let clampedLevel = CGFloat(min(max(spectrum.level, 0), 1))
        let lineWidth = isRecording ? 1.5 + clampedLevel * 2.0 : 1
        var bgR: CGFloat = 0, bgG: CGFloat = 0, bgB: CGFloat = 0, bgA: CGFloat = 0
        UIColor(palette.bg).getRed(&bgR, green: &bgG, blue: &bgB, alpha: &bgA)

        let showsOrb = listeningChrome && !isProcessing && dictationStyle.thinkingOrbStyle != nil
        fillView.isHidden = showsOrb
        fillView.backgroundColor = showsOrb ? .clear : UIColor(palette.bgHighlight)
        ringLayer.isHidden = showsOrb
        orbView.isHidden = !showsOrb
        orbView.isAnimationEnabled = showsOrb
        if let orbStyle = dictationStyle.thinkingOrbStyle {
            orbView.style = orbStyle
            orbView.sizeClass = .dictation(side: Double(diameter))
            orbView.accentUIColors = [palette.blue, palette.cyan, palette.purple, palette.orange].map { UIColor($0) }
            if !orbView.tintUIColor.isEqual(indicator) {
                orbView.tintUIColor = indicator
            }
            orbView.voiceSpectrum = spectrum
            orbView.isDarkBackground = ThinkingOrbTint.isDarkBackground(red: bgR, green: bgG, blue: bgB)
        }
        ringLayer.strokeColor = (isRecording
            ? indicator
            : indicator.withAlphaComponent(engineBadge == .auto ? 0.35 : 0.6)
        ).cgColor
        ringLayer.fillColor = UIColor.clear.cgColor

        if animated, !showsOrb {
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

        if showsOrb {
            imageView.isHidden = true
            textLabel.isHidden = true
            if let languageLabel, !languageLabel.isEmpty {
                let existing = accessibilityValue ?? ""
                if existing.contains(languageLabel) {
                    accessibilityValue = existing
                } else if existing.isEmpty {
                    accessibilityValue = languageLabel
                } else {
                    accessibilityValue = "\(existing), \(languageLabel)"
                }
            }
            return
        }

        if listeningChrome {
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
        if !isRecording && !isPreparing && !isProcessing {
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
