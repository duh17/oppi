import GhosttyVt
import UIKit
import UniformTypeIdentifiers

/// One key strip for the chat bar and the raw-keyboard accessory. Each scrolls
/// its keys sideways beside a pinned dock at the trailing edge, tinted so it
/// reads apart from the keys that scroll. The composer row runs agent keys,
/// arrows, then exit chords, so exit stays off screen until you swipe to it;
/// its dock holds the raw-keyboard switch. The accessory is two rows that
/// scroll together: Esc, the Ctrl/Alt latches, Tab, and arrows on top, then
/// Paste and program actions. Its dock stacks chat over hide, so a
/// phone-width bar can always reach them. Buttons, arrows, spacing, and press
/// treatment are shared.
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
        var fillPassword: () -> Void = {}
    }

    let role: Role
    var handlers: Handlers

    private var profile: SSHTerminalKeymap.Profile?
    private var userFile: String?
    private var programActions: [SSHTerminalKeyAction] = []
    private var foreground = UIColor.label
    private var barBackground = UIColor.systemBackground
    private var colors = ComposerThemeColors.placeholder

    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let fill = UIView()
    private let scroll = SSHTerminalKeyScrollView()
    private let rows = UIStackView()
    private let keys = UIStackView()
    /// The accessory's second row: Paste and program actions.
    private let programRow = UIStackView()
    private let trailing = UIStackView()
    private let dock = UIView()
    private var modifierButtons: [(button: UIButton, modifier: GhosttyMods, label: String)] = []
    private var arrowButtons: [SSHTerminalArrowButton] = []
    private var pasteControl: UIPasteControl?
    /// Lock and "Secure Input" while the keyboard's secure entry is on.
    private var secureCue: UIView?
    private var showsSecureInput = false
    /// Fill Password, with what stands beside it, hidden until offered.
    private var fillKey: SSHTerminalKeyButton?
    private var fillDivider: UIView?
    /// The label's host (`duh@mac-studio`) while Fill Password is offered, else nil.
    private var passwordFillHost: String?
    private var appliedSignature = ""

    /// Two 46pt rows; each key keeps its 44pt target.
    private static let accessoryHeight: CGFloat = 92

    init(role: Role, handlers: Handlers) {
        self.role = role
        self.handlers = handlers
        super.init(frame: role == .accessory ? CGRect(x: 0, y: 0, width: 400, height: Self.accessoryHeight) : .zero)
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
            height: role == .accessory ? Self.accessoryHeight : ComposerInputMetrics.controlDiameter
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
        dock.backgroundColor = colors.fg.withAlphaComponent(0.1)
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

    /// A password prompt sets the grid's secure entry; this is its visible
    /// counterpart on the keyboard bar.
    func setSecureInput(_ on: Bool) {
        guard on != showsSecureInput else { return }
        showsSecureInput = on
        secureCue?.isHidden = !on
    }

    /// Shows Fill Password for `host` (`duh@mac-studio`) while a password prompt
    /// is up and the host has a password to fill; nil hides it.
    func setPasswordFill(host: String?) {
        guard host != passwordFillHost else { return }
        passwordFillHost = host
        applyPasswordFill()
    }

    private func applyPasswordFill() {
        let offered = passwordFillHost != nil
        fillKey?.isHidden = !offered
        fillDivider?.isHidden = !offered
        fillKey?.accessibilityLabel = passwordFillHost.map { "Fill password for \($0)" } ?? "Fill password"
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
        scroll.blocksScrolling = { [weak self] in
            self?.arrowButtons.contains(where: \.isHolding) ?? false
        }
        rows.axis = .vertical
        rows.alignment = .leading
        rows.distribution = .fillEqually
        for row in [keys, programRow] {
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 4
        }
        rows.addArrangedSubview(keys)
        if role == .accessory { rows.addArrangedSubview(programRow) }
        trailing.axis = role == .accessory ? .vertical : .horizontal
        trailing.alignment = .center
        trailing.distribution = role == .accessory ? .fillEqually : .fill
        trailing.spacing = role == .accessory ? 0 : 4
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.isLayoutMarginsRelativeArrangement = true
        trailing.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2)
        dock.isUserInteractionEnabled = false
        dock.layer.cornerRadius = 20
        dock.layer.cornerCurve = .continuous

        for view in [glass, fill, scroll, dock, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        addSubview(fill)
        addSubview(scroll)
        scroll.addSubview(rows)
        addSubview(dock)
        addSubview(trailing)

        let stripHeight = role == .accessory ? Self.accessoryHeight : ComposerInputMetrics.controlDiameter
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
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: role == .accessory ? -4 : 0),
            trailing.topAnchor.constraint(equalTo: topAnchor),
            trailing.bottomAnchor.constraint(equalTo: bottomAnchor),
            dock.leadingAnchor.constraint(equalTo: trailing.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            dock.topAnchor.constraint(equalTo: trailing.topAnchor, constant: 2),
            dock.bottomAnchor.constraint(equalTo: trailing.bottomAnchor, constant: -2),
            rows.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rows.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: stripHeight),
        ])
    }

    private func rebuild() {
        stopRepeating()
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        programRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        trailing.arrangedSubviews.forEach { $0.removeFromSuperview() }
        modifierButtons = []
        arrowButtons = []
        pasteControl = nil
        secureCue = nil
        fillKey = nil
        fillDivider = nil
        switch role {
        case .composer: rebuildComposer()
        case .accessory: rebuildAccessory()
        }
        showModifiers()
    }

    private func rebuildComposer() {
        addFillPasswordKey(to: keys)
        let divider = addGroupDivider()
        fillDivider = divider
        applyPasswordFill()
        let pages = SSHTerminalKeymap.composerPages(for: profile, userFile: userFile)
        for (index, page) in pages.enumerated() {
            if index > 0 { addGroupDivider() }
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
        }
        addKey(
            title: nil,
            systemImage: "keyboard",
            id: "sshTerminal.composer.rawKeyboard",
            accessibilityLabel: "Type directly into the terminal",
            hint: nil,
            in: trailing
        ) { [weak self] in
            self?.handlers.showRawKeyboard()
        }
        scroll.contentOffset = .zero
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
        addSecureCue(to: programRow)
        addFillPasswordKey(to: programRow)
        applyPasswordFill()
        installPasteControl(in: programRow)
        for action in programActions {
            addKey(
                title: action.title,
                id: "sshTerminal.action.\(action.id)",
                accessibilityLabel: action.title,
                hint: "Sends \(action.keyLabel)",
                in: programRow
            ) { [weak self] in
                self?.handlers.sendStrokes(action.strokes)
            }
        }
        addKey(
            title: nil,
            systemImage: "text.bubble",
            id: "sshTerminal.useChatBar",
            accessibilityLabel: "Use chat bar",
            hint: nil,
            in: trailing
        ) { [weak self] in
            self?.handlers.useChatBar()
        }
        addKey(
            title: "⌄",
            id: "sshTerminal.hideKeyboard",
            accessibilityLabel: "Hide keyboard",
            hint: nil,
            in: trailing
        ) { [weak self] in
            self?.handlers.hideKeyboard()
        }
        scroll.contentOffset = .zero
    }

    /// A hairline between the composer's agent, move, and exit groups.
    @discardableResult
    private func addGroupDivider() -> UIView {
        let divider = UIView()
        divider.isUserInteractionEnabled = false
        divider.isAccessibilityElement = false
        divider.backgroundColor = colors.fg.withAlphaComponent(0.2)
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            divider.heightAnchor.constraint(equalToConstant: 20),
        ])
        keys.addArrangedSubview(divider)
        return divider
    }

    /// "Fill Password", the key a password prompt offers. Created with the
    /// strip and shown by `setPasswordFill`, so it keeps one identity.
    private func addFillPasswordKey(to row: UIStackView) {
        let key = addKey(
            title: "Fill Password",
            systemImage: "key.fill",
            id: "sshTerminal.key.fillPassword",
            accessibilityLabel: "Fill password",
            hint: "Asks for Face ID, then types the saved password without pressing Return",
            in: row
        ) { [weak self] in
            self?.handlers.fillPassword()
        }
        key.configuration?.imagePadding = 6
        key.isHidden = true
        fillKey = key
    }

    @discardableResult
    private func addKey(
        title: String?,
        systemImage: String? = nil,
        id: String,
        accessibilityLabel: String?,
        hint: String?,
        in stack: UIStackView? = nil,
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
        (stack ?? keys).addArrangedSubview(button)
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

    /// First in the program row so it reads before the keys: a lock and
    /// "Secure Input", hidden until a password prompt turns secure entry on.
    private func addSecureCue(to row: UIStackView) {
        let lock = UIImageView(image: UIImage(
            systemName: "lock.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        ))
        lock.tintColor = foreground
        lock.contentMode = .scaleAspectFit
        lock.isAccessibilityElement = false
        let label = UILabel()
        label.text = "Secure Input"
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = foreground
        let cue = UIStackView(arrangedSubviews: [lock, label])
        cue.axis = .horizontal
        cue.alignment = .center
        cue.spacing = 4
        cue.isLayoutMarginsRelativeArrangement = true
        cue.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
        cue.isAccessibilityElement = true
        cue.accessibilityIdentifier = "sshTerminal.secureInput"
        cue.accessibilityLabel = "Secure Input"
        cue.accessibilityTraits = .staticText
        cue.isHidden = !showsSecureInput
        row.addArrangedSubview(cue)
        secureCue = cue
    }

    private func installPasteControl(in row: UIStackView) {
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
        row.addArrangedSubview(paste)
        pasteControl = paste
    }
}

/// The key row's scroller. Every key is a UIControl, and UIScrollView never
/// cancels a touch on a control by default, so a swipe that starts on a key
/// would press it instead of scrolling. Here a sideways swipe always wins,
/// except while an arrow's hold owns the drag.
final class SSHTerminalKeyScrollView: UIScrollView {
    var blocksScrolling: () -> Bool = { false }

    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, blocksScrolling() { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
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
