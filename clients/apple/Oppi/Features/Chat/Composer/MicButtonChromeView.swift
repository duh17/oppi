import UIKit

/// UIKit companion to `MicButtonLabel`.
///
/// Owns only the shared mic button chrome: idle or muted mic, recording
/// language/cloud indicator with audio-reactive ring or orb, and processing
/// spinner. Callers own the recording route and action wiring.
@MainActor
final class MicButtonChromeView: UIControl {
    private let fillView = UIView()
    private let ringLayer = CAShapeLayer()
    private let orbView = OrbMetalView(style: .composing, sizeClass: .dictationStandard)
    private let imageView = UIImageView()
    private let textLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var diameter: CGFloat = 44
    /// Touch side for a mic drawn smaller than a comfortable target: touches
    /// land across this band around the bounds, which the superviews must
    /// not clip. Zero keeps the drawn bounds.
    var minimumHitSide: CGFloat = 0
    private var isRecording = false
    private var isPreparing = false
    private var isProcessing = false
    private var isMuted = false
    /// Shown inside the ring while listening, in place of the language (a Live Voice call).
    private var listeningSymbol: String?
    /// Shown at rest in place of the mic (the slot as the Live Voice entry).
    private var idleSymbol: String?
    private var showsOrb = false
    private var voiceSpectrum: VoiceSpectrumFrame = .zero
    /// Levels read once per frame instead of pushed through `apply` (a Live Voice call).
    private var liveSpectrum: (@MainActor () -> VoiceSpectrumFrame)?
    nonisolated(unsafe) private var liveLink: CADisplayLink?
    private var languageLabel: String?
    private var accentColor = UIColor(ThemeRuntimeState.currentPalette().blue)
    /// The disc's colors; nil is the app theme's palette. Takes effect on the next `apply`.
    var colors: ComposerThemeColors?
    private var engineBadge: MicButtonLabel.EngineBadge = .auto
    private var dictationStyle: DictationIndicatorStyle = .current
    nonisolated(unsafe) private var dictationStyleObserver: NSObjectProtocol?

    /// Long-press menu, shown while `isContextMenuInteractionEnabled` is on. Tap still sends `.touchUpInside`.
    var menuProvider: (() -> UIMenu?)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = menuProvider?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
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

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        ComposerHitTarget.contains(point, in: bounds, minimumSide: minimumHitSide)
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
        isPreparing: Bool = false,
        isMuted: Bool = false,
        listeningSymbol: String? = nil,
        idleSymbol: String? = nil
    ) {
        self.isRecording = isRecording
        self.isPreparing = isPreparing
        self.isProcessing = isProcessing
        self.isMuted = isMuted
        self.listeningSymbol = listeningSymbol
        self.idleSymbol = idleSymbol
        if liveSpectrum == nil {
            self.voiceSpectrum = voiceSpectrum
        }
        self.languageLabel = languageLabel
        self.accentColor = accentColor
        self.engineBadge = engineBadge
        self.dictationStyle = DictationIndicatorStyle.current
        if self.diameter != diameter {
            self.diameter = diameter
            invalidateIntrinsicContentSize()
        }
        updateAppearance(animated: animated)
        updateLiveLink()
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

        // Glyphs are drawn at their symbol point size, as `MicButtonLabel` does,
        // and never size the button.
        imageView.contentMode = .center
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
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

        dictationStyleObserver = NotificationCenter.default.addObserver(
            forName: AppPreferenceStore.Appearance.dictationIndicatorDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyDictationStyleFromPreferences()
            }
        }
        updateAppearance(animated: false)
    }

    deinit {
        liveLink?.invalidate()
        if let dictationStyleObserver {
            NotificationCenter.default.removeObserver(dictationStyleObserver)
        }
    }

    /// Drives the ring or orb from `source` while recording, read at up to 30 fps while the
    /// button is on screen. Off screen, hidden, or in the background nothing reads it.
    func setLiveSpectrumSource(_ source: (@MainActor () -> VoiceSpectrumFrame)?) {
        liveSpectrum = source
        if source == nil, liveLink != nil {
            voiceSpectrum = .zero
            applyVoiceLevel(animated: false)
        }
        updateLiveLink()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLiveLink()
    }

    override var isHidden: Bool {
        didSet { updateLiveLink() }
    }

    private func updateLiveLink() {
        let wantsLink = liveSpectrum != nil && isRecording && window != nil && !isHidden
        if !wantsLink {
            liveLink?.invalidate()
            liveLink = nil
            return
        }
        guard liveLink == nil else { return }
        let link = CADisplayLink(target: LiveLinkTarget(owner: self), selector: #selector(LiveLinkTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        liveLink = link
    }

    fileprivate func readLiveSpectrum() {
        guard let liveSpectrum else { return }
        voiceSpectrum = liveSpectrum()
        applyVoiceLevel(animated: true)
    }

    /// The display link retains its target; this one does not retain the button.
    @MainActor
    private final class LiveLinkTarget: NSObject {
        weak var owner: MicButtonChromeView?

        init(owner: MicButtonChromeView) {
            self.owner = owner
        }

        @objc func tick() {
            owner?.readLiveSpectrum()
        }
    }

    private func applyDictationStyleFromPreferences() {
        dictationStyle = DictationIndicatorStyle.current
        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        let palette = colors ?? ComposerThemeColors(palette: ThemeRuntimeState.currentPalette())
        let indicator = indicatorColor(palette: palette)
        let listeningChrome = isRecording || isPreparing
        var bgR: CGFloat = 0, bgG: CGFloat = 0, bgB: CGFloat = 0, bgA: CGFloat = 0
        palette.bg.getRed(&bgR, green: &bgG, blue: &bgB, alpha: &bgA)

        showsOrb = listeningChrome && !isProcessing && dictationStyle.orbStyle != nil
        fillView.isHidden = showsOrb
        fillView.backgroundColor = showsOrb ? .clear : palette.bgHighlight
        ringLayer.isHidden = showsOrb
        orbView.isHidden = !showsOrb
        orbView.isAnimationEnabled = showsOrb
        if let orbStyle = dictationStyle.orbStyle {
            orbView.style = orbStyle
            orbView.sizeClass = .dictation(side: Double(diameter))
            orbView.accentUIColors = [palette.blue, palette.cyan, palette.purple, palette.orange]
            if !orbView.tintUIColor.isEqual(indicator) {
                orbView.tintUIColor = indicator
            }
            orbView.isDarkBackground = OrbTint.isDarkBackground(red: bgR, green: bgG, blue: bgB)
        }
        ringLayer.strokeColor = (isRecording
            ? indicator
            : indicator.withAlphaComponent(engineBadge == .auto ? 0.35 : 0.6)
        ).cgColor
        ringLayer.fillColor = UIColor.clear.cgColor
        applyVoiceLevel(animated: animated)

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
            if let listeningSymbol {
                imageView.isHidden = false
                imageView.image = UIImage(
                    systemName: listeningSymbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: diameter * 0.4, weight: .bold)
                )
                imageView.tintColor = indicator
                textLabel.isHidden = true
            } else if engineBadge == .remote {
                imageView.isHidden = false
                imageView.image = UIImage(
                    systemName: "cloud",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: diameter * 0.38, weight: .bold)
                )
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
            imageView.image = UIImage(
                systemName: idleSymbol ?? (isMuted ? "mic.slash" : "mic"),
                withConfiguration: UIImage.SymbolConfiguration(pointSize: diameter * 0.47, weight: .bold)
            )
            imageView.tintColor = isMuted
                ? palette.fg
                : indicator.withAlphaComponent(engineBadge == .auto ? 0.75 : 1)
            textLabel.isHidden = true
        }
    }

    /// The parts that move with the voice: the orb's spectrum or the ring's width.
    private func applyVoiceLevel(animated: Bool) {
        let spectrum = isRecording ? voiceSpectrum : .zero
        if dictationStyle.orbStyle != nil {
            orbView.voiceSpectrum = spectrum
        }
        let clampedLevel = CGFloat(min(max(spectrum.level, 0), 1))
        let lineWidth = isRecording ? 1.5 + clampedLevel * 2.0 : 1
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
    }

    private func indicatorColor(palette: ComposerThemeColors) -> UIColor {
        if !isRecording && !isPreparing && !isProcessing {
            return palette.comment
        }

        switch engineBadge {
        case .auto:
            return palette.comment
        case .onDevice:
            return accentColor
        case .remote:
            return palette.cyan
        }
    }
}
