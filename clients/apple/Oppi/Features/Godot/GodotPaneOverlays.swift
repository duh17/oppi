import UIKit

/// The Godot pane's notice row between its bar and the game: a device too
/// hot to play. It takes its own row,
/// so it never covers the game, on opaque material with the theme's text.
final class GodotNoticeBanner: UIView {
    private let label = UILabel()

    var text: String? {
        get { label.text }
        set {
            label.text = newValue
            accessibilityLabel = newValue
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "godot.notice"
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        icon.tintColor = .systemOrange
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.font = .scaled(.footnote, .semibold)
        label.textColor = .label
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        // Exactly as tall as its text (pinned straight to the label, no stack
        // view, which may grow): the game's view takes the rest.
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        let separator = UIView()
        separator.backgroundColor = .separator
        for view in [material, icon, label, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            icon.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            icon.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// Dims a paused game's last frame. The person's pause shows a Play button
/// that resumes; a pause that ends by itself shows its reason instead, as a
/// symbol alone when the notice row already says it in words (heat).
final class GodotPauseCover: UIView {
    enum Content: Equatable {
        case play
        /// `text` shows under the symbol; nil shows the symbol alone, which
        /// `label` names for VoiceOver.
        case reason(systemImage: String, label: String, text: String?)
    }

    var onPlay: (() -> Void)?

    private let play = UIButton(type: .system)
    private let reasonIcon = UIImageView()
    private let reasonLabel = UILabel()
    private var content: Content?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.5)
        accessibilityIdentifier = "godot.pauseCover"

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "play.circle.fill")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        config.baseForegroundColor = .white
        play.configuration = config
        play.accessibilityLabel = String(localized: "Play")
        play.accessibilityIdentifier = "godot.resume"
        play.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)

        reasonIcon.tintColor = .white
        reasonIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        reasonIcon.contentMode = .center
        reasonIcon.isAccessibilityElement = true
        reasonIcon.accessibilityIdentifier = "godot.pauseCover.reason"
        reasonLabel.font = .scaled(.headline)
        reasonLabel.textColor = .white
        reasonLabel.textAlignment = .center
        reasonLabel.numberOfLines = 0
        reasonLabel.adjustsFontForContentSizeCategory = true
        // The symbol carries the reason for VoiceOver; the words repeat it.
        reasonLabel.isAccessibilityElement = false

        let stack = UIStackView(arrangedSubviews: [play, reasonIcon, reasonLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ content: Content) {
        isHidden = false
        guard content != self.content else { return }
        self.content = content
        switch content {
        case .play:
            play.isHidden = false
            reasonIcon.isHidden = true
            reasonLabel.isHidden = true
        case .reason(let symbol, let label, let text):
            play.isHidden = true
            reasonIcon.image = UIImage(systemName: symbol)
            reasonIcon.accessibilityLabel = label
            reasonIcon.isHidden = false
            reasonLabel.text = text
            reasonLabel.isHidden = text == nil
        }
    }
}
