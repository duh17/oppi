import GhosttyVt
import UIKit
import UniformTypeIdentifiers

/// One key strip for the chat bar and the raw-keyboard accessory.
/// Composer pages stay paged (agent / move / exit); the accessory keeps Ctrl/Alt
/// latches, Paste, program actions, and the chat/hide controls. Buttons, arrows,
/// spacing, and press treatment are shared.
final class SSHTerminalKeyStripView: UIView {
    enum Role {
        case composer
        case accessory
    }

    struct Handlers {
        var sendStrokes: ([SSHTerminalKeyStroke]) -> Void = { _ in }
        var sendKey: (GhosttyKey) -> Void = { _ in }
        var sendArrow: (GhosttyKey) -> Bool = { _ in false }
        var toggleModifier: (GhosttyMods) -> Void = { _ in }
        var modifierArmed: (GhosttyMods) -> Bool = { _ in false }
        var pasteTarget: UIPasteConfigurationSupporting?
        var showRawKeyboard: () -> Void = {}
        var useChatBar: () -> Void = {}
        var hideKeyboard: () -> Void = {}
    }

    let role: Role
    var handlers: Handlers

    private var profile: SSHTerminalKeymap.Profile?
    private var userFile: String?
    private var programActions: [SSHTerminalKeyAction] = []
    private var keyPage = 0
    private var foreground = UIColor.label
    private var barBackground = UIColor.systemBackground
    private var colors = ComposerThemeColors.placeholder

    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let fill = UIView()
    private let scroll = UIScrollView()
    private let keys = UIStackView()
    private let trailing = UIStackView()
    private var modifierButtons: [(button: UIButton, modifier: GhosttyMods, label: String)] = []
    private var arrowButtons: [SSHTerminalArrowButton] = []
    private var pasteControl: UIPasteControl?
    private var pageButton: SSHTerminalKeyButton?
    private var appliedSignature = ""

    init(role: Role, handlers: Handlers) {
        self.role = role
        self.handlers = handlers
        let accessoryHeight: CGFloat = 48
        super.init(frame: role == .accessory ? CGRect(x: 0, y: 0, width: 400, height: accessoryHeight) : .zero)
        if role == .accessory {
            autoresizingMask = [.flexibleWidth]
        } else {
            translatesAutoresizingMaskIntoConstraints = false
        }
        build()
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: role == .accessory ? 48 : ComposerInputMetrics.controlDiameter
        )
    }

    func apply(
        profile: SSHTerminalKeymap.Profile?,
        userFile: String?,
        actions: [SSHTerminalKeyAction] = [],
        colors: ComposerThemeColors,
        foreground: UIColor,
        background: UIColor
    ) {
        let signature = "\(role)|\(userFile ?? "")|\(profile?.actions.map(\.id).joined(separator: ",") ?? "")|\(actions.map(\.id).joined(separator: ","))|\(foreground)|\(background)"
        self.profile = profile
        self.userFile = userFile
        self.programActions = actions
        self.colors = colors
        self.foreground = foreground
        self.barBackground = background
        tintColor = foreground
        fill.backgroundColor = role == .accessory ? background.withAlphaComponent(0.55) : .clear
        backgroundColor = .clear
        guard signature != appliedSignature else {
            showModifiers()
            return
        }
        appliedSignature = signature
        rebuild()
        showModifiers()
    }

    func setProgramActions(_ actions: [SSHTerminalKeyAction]) {
        guard actions != programActions else { return }
        programActions = actions
        rebuild()
    }

    func showModifiers() {
        for entry in modifierButtons {
            let armed = handlers.modifierArmed(entry.modifier)
            entry.button.isSelected = armed
            entry.button.accessibilityValue = armed ? "On" : "Off"
            if let key = entry.button as? SSHTerminalKeyButton {
                key.apply(title: entry.label, colors: colors, selected: armed)
            }
        }
    }

    func stopRepeating() {
        arrowButtons.forEach { $0.stopRepeating() }
    }

    // MARK: - Build

    private func build() {
        glass.isHidden = role != .accessory
        glass.isUserInteractionEnabled = false
        fill.isUserInteractionEnabled = false
        fill.isHidden = role != .accessory
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.keyboardDismissMode = .none
        scroll.delaysContentTouches = false
        keys.axis = .horizontal
        keys.alignment = .center
        keys.spacing = 4
        trailing.axis = .horizontal
        trailing.alignment = .center
        trailing.spacing = 4
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [glass, fill, scroll, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        keys.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        addSubview(fill)
        addSubview(scroll)
        scroll.addSubview(keys)
        addSubview(trailing)

        let stripHeight = role == .accessory ? 48 : ComposerInputMetrics.controlDiameter
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: role == .accessory ? 4 : 0),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailing.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 4),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailing.topAnchor.constraint(equalTo: topAnchor),
            trailing.bottomAnchor.constraint(equalTo: bottomAnchor),
            keys.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            keys.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: stripHeight),
        ])
        trailing.isHidden = role != .composer
        if role != .composer {
            trailing.widthAnchor.constraint(equalToConstant: 0).isActive = true
        }
    }

    private func rebuild() {
        stopRepeating()
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        trailing.arrangedSubviews.forEach { $0.removeFromSuperview() }
        modifierButtons = []
        arrowButtons = []
        pasteControl = nil
        pageButton = nil
        switch role {
        case .composer: rebuildComposer()
        case .accessory: rebuildAccessory()
        }
        showModifiers()
    }

    private func rebuildComposer() {
        let pages = SSHTerminalKeymap.composerPages(for: profile, userFile: userFile)
        guard !pages.isEmpty else { return }
        let index = min(max(keyPage, 0), pages.count - 1)
        keyPage = index
        let page = pages[index]
        let next = pages[(index + 1) % pages.count]
        for item in page.items {
            if item.kind == .arrow, let stroke = item.strokes.first {
                addArrow(label: item.label, key: stroke.key, id: "sshTerminal.composer.\(item.id)")
            } else {
                addKey(
                    title: item.label,
                    id: "sshTerminal.composer.\(item.id)",
                    accessibilityLabel: item.accessibilityLabel,
                    hint: "Sends \(item.hint)"
                ) { [weak self] in
                    self?.handlers.sendStrokes(item.strokes)
                }
            }
        }
        let pageButton = SSHTerminalKeyButton()
        pageButton.apply(title: "\(index + 1)/\(pages.count)", colors: colors, compactTitle: true)
        pageButton.accessibilityIdentifier = "sshTerminal.composer.page"
        pageButton.accessibilityLabel = "Key page \(index + 1) of \(pages.count), \(page.title)"
        pageButton.accessibilityHint = "Shows \(next.title)"
        pageButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.keyPage = (index + 1) % pages.count
            self.rebuild()
        }, for: .touchUpInside)
        trailing.addArrangedSubview(pageButton)
        self.pageButton = pageButton

        let keyboard = SSHTerminalKeyButton()
        keyboard.apply(title: nil, systemImage: "keyboard", colors: colors)
        keyboard.accessibilityIdentifier = "sshTerminal.composer.rawKeyboard"
        keyboard.accessibilityLabel = "Type directly into the terminal"
        keyboard.addAction(UIAction { [weak self] _ in
            self?.handlers.showRawKeyboard()
        }, for: .touchUpInside)
        trailing.addArrangedSubview(keyboard)
    }

    private func rebuildAccessory() {
        for fixed in SSHTerminalKeymap.fixed {
            if let modifier = fixed.modifier {
                let button = addKey(
                    title: fixed.label,
                    id: "sshTerminal.\(fixed.id)",
                    accessibilityLabel: "\(fixed.label) modifier",
                    hint: nil
                ) { [weak self] in
                    guard let self else { return }
                    self.handlers.toggleModifier(modifier)
                    self.showModifiers()
                }
                modifierButtons.append((button, modifier, fixed.label))
            } else if let stroke = fixed.stroke {
                if SSHTerminalArrowRepeat.isArrow(stroke.key) {
                    addArrow(label: fixed.label, key: stroke.key, id: "sshTerminal.\(fixed.id)")
                } else {
                    addKey(
                        title: fixed.label,
                        id: "sshTerminal.\(fixed.id)",
                        accessibilityLabel: fixed.label,
                        hint: nil
                    ) { [weak self] in
                        self?.handlers.sendKey(stroke.key)
                    }
                }
            }
        }
        installPasteControl()
        for action in programActions {
            addKey(
                title: action.title,
                id: "sshTerminal.action.\(action.id)",
                accessibilityLabel: action.title,
                hint: "Sends \(action.keyLabel)"
            ) { [weak self] in
                self?.handlers.sendStrokes(action.strokes)
            }
        }
        let chat = addKey(
            title: nil,
            systemImage: "text.bubble",
            id: "sshTerminal.useChatBar",
            accessibilityLabel: "Use chat bar",
            hint: nil
        ) { [weak self] in
            self?.handlers.useChatBar()
        }
        _ = chat
        addKey(
            title: "⌄",
            id: "sshTerminal.hideKeyboard",
            accessibilityLabel: "Hide keyboard",
            hint: nil
        ) { [weak self] in
            self?.handlers.hideKeyboard()
        }
    }

    @discardableResult
    private func addKey(
        title: String?,
        systemImage: String? = nil,
        id: String,
        accessibilityLabel: String?,
        hint: String?,
        action: @escaping () -> Void
    ) -> SSHTerminalKeyButton {
        let button = SSHTerminalKeyButton()
        button.apply(title: title, systemImage: systemImage, colors: colors)
        button.accessibilityIdentifier = id
        button.accessibilityLabel = accessibilityLabel ?? title ?? id
        if let hint {
            button.accessibilityHint = hint
        }
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        keys.addArrangedSubview(button)
        return button
    }

    private func addArrow(label: String, key: GhosttyKey, id: String) {
        let arrow = SSHTerminalArrowButton(label: label, key: key, id: id) { [weak self] arrowKey in
            self?.handlers.sendArrow(arrowKey) ?? false
        }
        arrow.tintColor = foreground
        arrow.applyChrome(title: label, color: foreground)
        arrow.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        arrow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        keys.addArrangedSubview(arrow)
        arrowButtons.append(arrow)
    }

    private func installPasteControl() {
        let style = UIPasteControl.Configuration()
        style.displayMode = .labelOnly
        style.cornerStyle = .capsule
        style.baseForegroundColor = foreground
        style.baseBackgroundColor = barBackground
        let paste = UIPasteControl(configuration: style)
        paste.target = handlers.pasteTarget
        paste.accessibilityIdentifier = "sshTerminal.paste"
        paste.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        paste.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        keys.addArrangedSubview(paste)
        pasteControl = paste
    }
}

/// Compact terminal key with a 44pt hit target and press fade. Plain chrome
/// inside the composer capsule (already glass); the accessory bar supplies glass.
final class SSHTerminalKeyButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        configurationUpdateHandler = { button in
            button.alpha = button.isEnabled ? (button.isHighlighted ? 0.82 : 1) : 0.45
        }
        widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(
            dx: min(0, (bounds.width - 44) / 2),
            dy: min(0, (bounds.height - 44) / 2)
        ).contains(point)
    }

    func apply(
        title: String?,
        systemImage: String? = nil,
        colors: ComposerThemeColors,
        selected: Bool = false,
        compactTitle: Bool = false
    ) {
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .capsule
        config.baseForegroundColor = colors.fg
        config.background.backgroundColor = selected
            ? colors.fg.withAlphaComponent(0.18)
            : .clear
        let horizontal: CGFloat = compactTitle ? 6 : 10
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: horizontal, bottom: 6, trailing: horizontal)
        config.titleLineBreakMode = compactTitle ? .byClipping : .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            return outgoing
        }
        config.title = title
        if let systemImage {
            config.image = UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            )
        }
        configuration = config
        if compactTitle {
            titleLabel?.numberOfLines = 1
            setContentCompressionResistancePriority(.required, for: .horizontal)
        }
    }
}
