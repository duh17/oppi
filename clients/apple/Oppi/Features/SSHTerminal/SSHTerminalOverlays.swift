import UIKit

/// Hits pass through empty space to the grid; cards and buttons keep theirs.
final class SSHTerminalPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// The way back after Hide Bar. A tap shows the bar; a downward pull does too.
/// It is not a scroll catcher: a short or sideways drag leaves the bar hidden.
final class SSHTerminalTopBarHandleView: UIView {
    var onShow: () -> Void = {}

    private let glass = UIVisualEffectView(effect: {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        return effect
    }())
    private let chevron = UIImageView()
    private let button = UIButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 11
        glass.clipsToBounds = true
        addSubview(glass)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        )
        chevron.contentMode = .scaleAspectFit
        glass.contentView.addSubview(chevron)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { [weak self] _ in self?.onShow() }, for: .touchUpInside)
        button.accessibilityLabel = "Show terminal bar"
        button.accessibilityHint = "Shows the host name, Herdr, and terminal actions"
        button.accessibilityIdentifier = "sshTerminal.showBar"
        addSubview(button)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))
        pan.minimumNumberOfTouches = 1
        button.addGestureRecognizer(pan)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
            glass.centerXAnchor.constraint(equalTo: centerXAnchor),
            glass.centerYAnchor.constraint(equalTo: centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 52),
            glass.heightAnchor.constraint(equalToConstant: 22),
            chevron.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(themeID: ThemeID) {
        chevron.tintColor = UIColor(themeID.palette.fg)
    }

    @objc private func pulled(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: self)
        let size = CGSize(width: translation.x, height: translation.y)
        guard SSHTerminalTopBarGesture.action(translation: size) == .show else { return }
        onShow()
    }
}

/// Connecting, disconnected, and network-changed copy. Floats over the grid.
final class SSHTerminalConnectionBannerView: UIView {
    var onReconnect: (() -> Void)?

    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let icon = UIImageView()
    private let label = UILabel()
    private let reconnect = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "sshTerminal.status"

        material.translatesAutoresizingMaskIntoConstraints = false
        material.layer.cornerRadius = 12
        material.clipsToBounds = true
        addSubview(material)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: "xmark.circle")
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var config = UIButton.Configuration.plain()
        config.title = "Reconnect"
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
        reconnect.configuration = config
        reconnect.translatesAutoresizingMaskIntoConstraints = false
        reconnect.accessibilityIdentifier = "sshTerminal.reconnect"
        reconnect.addAction(UIAction { [weak self] _ in self?.onReconnect?() }, for: .touchUpInside)
        reconnect.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [spinner, icon, label, reconnect])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        material.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            material.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: material.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: material.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: material.contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: material.contentView.trailingAnchor),
            reconnect.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(text: String, showsProgress: Bool, showsReconnect: Bool, themeID: ThemeID) {
        label.text = text
        label.textColor = UIColor(themeID.palette.fg)
        icon.tintColor = UIColor(themeID.palette.red)
        spinner.color = UIColor(themeID.palette.fg)
        spinner.isHidden = !showsProgress
        if showsProgress { spinner.startAnimating() } else { spinner.stopAnimating() }
        icon.isHidden = showsProgress
        reconnect.isHidden = !showsReconnect
        reconnect.configuration?.baseForegroundColor = UIColor(themeID.palette.blue)
    }
}

final class SSHTerminalTextBannerView: UIView {
    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let label = UILabel()

    init(identifier: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = identifier
        isAccessibilityElement = true

        material.translatesAutoresizingMaskIntoConstraints = false
        material.layer.cornerRadius = 12
        material.clipsToBounds = true
        addSubview(material)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        material.contentView.addSubview(label)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            material.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: material.contentView.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: material.contentView.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: material.contentView.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: material.contentView.trailingAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(text: String, color: UIColor) {
        label.text = text
        label.textColor = color
        accessibilityLabel = text
    }
}

final class SSHTerminalCopyNoticeView: UIView {
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let label = UILabel()
    private let icon = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        accessibilityIdentifier = "sshTerminal.copyNotice"

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 16
        glass.clipsToBounds = true
        addSubview(glass)

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: "doc.on.clipboard")
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        glass.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(text: String, themeID: ThemeID) {
        label.text = text
        label.textColor = UIColor(themeID.palette.fg)
        icon.tintColor = UIColor(themeID.palette.fg)
        accessibilityLabel = text
    }
}

final class SSHTerminalBackToLiveButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.borderedProminent()
        config.image = UIImage(systemName: "arrow.down.to.line")
        config.title = "Back to Live"
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        configuration = config
        accessibilityIdentifier = "sshTerminal.backToLive"
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
