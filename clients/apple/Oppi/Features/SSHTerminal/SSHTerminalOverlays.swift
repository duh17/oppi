import UIKit

/// Hits pass through empty space to the grid; cards and buttons keep theirs.
final class SSHTerminalPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Glass capsule for the terminal's bottom bar. The glass is 36 pt tall and
/// ends 4 pt above the keyboard layout guide, so with a keyboard down it sits
/// just above the home indicator. A touch up to 4 pt outside it still reaches
/// the nearest button. Items are 44 pt wide, and the 36 pt Back circle gets
/// the same 4 pt at its sides, so every button answers a 44 × 44 pt touch.
class SSHTerminalGlassPill: UIView {
    static let height: CGFloat = 36
    static let itemWidth: CGFloat = 44
    static let touchOutset = (44 - height) / 2

    let stack = UIStackView()
    private let glass = UIVisualEffectView(effect: {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        return effect
    }())

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = Self.height / 2
        glass.clipsToBounds = true
        addSubview(glass)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])
        addInteraction(UILargeContentViewerInteraction())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Self.touchOutset, dy: -Self.touchOutset).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled, self.point(inside: point, with: event) else {
            return nil
        }
        if bounds.contains(point), let hit = super.hitTest(point, with: event), hit !== self { return hit }
        // Around the glass: the nearest button's column.
        let buttons = stack.arrangedSubviews.filter { !$0.isHidden && $0.isUserInteractionEnabled }
        return buttons.min {
            abs(convert($0.center, from: stack).x - point.x) < abs(convert($1.center, from: stack).x - point.x)
        }
    }
}

/// One symbol in a glass pill. Large Content Viewer shows it at accessibility
/// text sizes, as bar buttons do.
final class SSHTerminalPillButton: UIButton {
    init(systemName: String, label: String, identifier: String, width: CGFloat = SSHTerminalGlassPill.itemWidth) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        config.contentInsets = .zero
        configuration = config
        accessibilityLabel = label
        accessibilityIdentifier = identifier
        showsLargeContentViewer = true
        largeContentTitle = label
        largeContentImage = UIImage(systemName: systemName)
        scalesLargeContentImage = true
        // Below required: a hidden item in the pill's stack collapses to zero.
        let fixedWidth = widthAnchor.constraint(equalToConstant: width)
        fixedWidth.priority = .required - 1
        NSLayoutConstraint.activate([
            fixedWidth,
            heightAnchor.constraint(equalToConstant: SSHTerminalGlassPill.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(tint: UIColor) {
        configuration?.baseForegroundColor = tint
    }
}

/// Back, bottom leading. It carries the attention dot while Herdr or a blocked
/// program wants you.
final class SSHTerminalBackPill: UIView {
    let pill = SSHTerminalGlassPill()
    /// A circle: the glass is as wide as it is tall.
    let button = SSHTerminalPillButton(
        systemName: "chevron.backward", label: "Back", identifier: "sshTerminal.back", width: SSHTerminalGlassPill.height
    )
    private let attentionDot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        pill.stack.addArrangedSubview(button)

        attentionDot.translatesAutoresizingMaskIntoConstraints = false
        attentionDot.isUserInteractionEnabled = false
        attentionDot.isAccessibilityElement = false
        attentionDot.isHidden = true
        attentionDot.layer.cornerRadius = 5
        attentionDot.layer.borderWidth = 1.5
        addSubview(attentionDot)

        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            attentionDot.widthAnchor.constraint(equalToConstant: 10),
            attentionDot.heightAnchor.constraint(equalToConstant: 10),
            attentionDot.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 1),
            attentionDot.topAnchor.constraint(equalTo: pill.topAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        pill.point(inside: convert(point, to: pill), with: event)
    }

    func apply(themeID: ThemeID, attentionPending: Bool) {
        button.apply(tint: UIColor(themeID.palette.fg))
        attentionDot.backgroundColor = UIColor(themeID.palette.orange)
        attentionDot.layer.borderColor = UIColor(themeID.palette.bg).cgColor
        attentionDot.isHidden = !attentionPending
        button.accessibilityValue = attentionPending ? "Attention pending" : nil
    }
}

/// Bottom trailing: the program-status symbol (while a program has reported),
/// Herdr (when the host has it), and the … menu. Leading to trailing in
/// that order, as the bar items were.
final class SSHTerminalMorePill: SSHTerminalGlassPill {
    let status: SSHTerminalStatusGlyphButton
    let herdr = SSHTerminalPillButton(systemName: "square.grid.2x2", label: "Herdr agents", identifier: "sshTerminal.herdr")
    let more = SSHTerminalPillButton(systemName: "ellipsis", label: "More", identifier: "sshTerminal.more")

    init(status: SSHTerminalStatusGlyphButton) {
        self.status = status
        super.init(frame: .zero)
        more.showsMenuAsPrimaryAction = true
        status.isHidden = true
        herdr.isHidden = true
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(herdr)
        stack.addArrangedSubview(more)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(themeID: ThemeID, herdrAvailable: Bool, herdrWaiting: Int?, showsStatus: Bool) {
        let fg = UIColor(themeID.palette.fg)
        status.isHidden = !showsStatus
        herdr.isHidden = !herdrAvailable
        let waiting = herdrWaiting ?? 0
        herdr.apply(tint: waiting > 0 ? UIColor(themeID.palette.orange) : fg)
        herdr.accessibilityValue = herdrWaiting.map { "\($0) need you" } ?? ""
        herdr.largeContentTitle = waiting > 0 ? "Herdr agents (\(waiting))" : "Herdr agents"
        more.apply(tint: fg)
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
