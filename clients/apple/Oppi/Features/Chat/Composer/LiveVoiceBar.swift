import UIKit

/// Compact live-call chrome that replaces the text composer.
///
/// Mute / one center state / End. Mute stops Live Voice capture.
@MainActor
final class LiveVoiceBarView: UIView {
    static let muteIdentifier = "chat.liveVoice.mute"
    static let endIdentifier = "chat.liveVoice.end"
    static let stateIdentifier = "chat.liveVoice.state"

    static func statusText(approvalSummary: String?) -> String {
        let summary = approvalSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? "Listening" : summary
    }

    var onMute: (() -> Void)?
    var onEnd: (() -> Void)?

    private let glassView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let muteButton = UIButton(type: .system)
    private let endButton = UIButton(type: .system)
    private let stateLabel = UILabel()
    private let waveform = UIStackView()
    private let stateStack = UIStackView()
    private var isMuted = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        applyTheme()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .oppiThemeDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(statusText: String, isMuted: Bool) {
        stateLabel.text = statusText
        stateStack.accessibilityLabel = statusText
        self.isMuted = isMuted
        muteButton.setImage(UIImage(systemName: isMuted ? "mic.slash.fill" : "mic.fill"), for: .normal)
        muteButton.accessibilityLabel = isMuted ? "Unmute" : "Mute"
    }

    private func build() {
        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.layer.cornerRadius = 20
        glassView.layer.cornerCurve = .continuous
        glassView.clipsToBounds = true
        addSubview(glassView)

        configureRoundButton(muteButton, symbol: "mic.fill")
        muteButton.accessibilityIdentifier = Self.muteIdentifier
        muteButton.accessibilityLabel = "Mute"
        muteButton.addAction(UIAction { [weak self] _ in self?.onMute?() }, for: .touchUpInside)

        configureRoundButton(endButton, symbol: "phone.down.fill")
        endButton.accessibilityIdentifier = Self.endIdentifier
        endButton.accessibilityLabel = "End"
        endButton.addAction(UIAction { [weak self] _ in self?.onEnd?() }, for: .touchUpInside)

        waveform.axis = .horizontal
        waveform.alignment = .center
        waveform.spacing = 3
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        for index in 0..<7 {
            let bar = UIView()
            bar.layer.cornerRadius = 1.5
            bar.alpha = reduceMotion ? 0.7 : 0.45 + CGFloat(index % 3) * 0.15
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 3),
                bar.heightAnchor.constraint(equalToConstant: reduceMotion ? 10 : CGFloat(8 + (index % 4) * 4)),
            ])
            waveform.addArrangedSubview(bar)
        }
        waveform.isAccessibilityElement = false

        stateLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .medium))
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.numberOfLines = 2
        stateLabel.textAlignment = .center
        stateLabel.text = "Listening"

        stateStack.axis = .vertical
        stateStack.alignment = .center
        stateStack.spacing = 6
        stateStack.addArrangedSubview(waveform)
        stateStack.addArrangedSubview(stateLabel)
        // One element for VoiceOver: the call state, read as its text.
        stateStack.isAccessibilityElement = true
        stateStack.accessibilityIdentifier = Self.stateIdentifier
        stateStack.accessibilityLabel = "Listening"

        let row = UIStackView(arrangedSubviews: [muteButton, stateStack, endButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: glassView.contentView.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: glassView.contentView.bottomAnchor, constant: -14),
        ])
    }

    private func configureRoundButton(_ button: UIButton, symbol: String) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(textStyle: .body, scale: .large), forImageIn: .normal)
        button.layer.cornerRadius = 22
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func applyTheme() {
        let palette = ThemeRuntimeState.currentPalette()
        muteButton.tintColor = UIColor(palette.fg)
        muteButton.backgroundColor = UIColor(palette.bgHighlight)
        endButton.backgroundColor = UIColor(palette.red)
        endButton.tintColor = UIColor(ThemeColorContrast.foreground(for: palette.red))
        stateLabel.textColor = UIColor(palette.fg)
        for bar in waveform.arrangedSubviews {
            bar.backgroundColor = UIColor(palette.blue)
        }
    }

    @objc private func themeDidChange() {
        applyTheme()
    }
}
