import GhosttyVt
import UIKit
import UniformTypeIdentifiers

/// The terminal keyboard's accessory bar: two rows that scroll sideways
/// together beside a pinned dock at the trailing edge, tinted so it reads apart
/// from the keys that scroll. Esc, the Ctrl/Alt latches, Tab, and arrows are on
/// top, then Paste and program actions. The dock holds hide, so a phone-width
/// bar can always reach it.
///
/// While it carries the bottom bar (`SSHTerminalKeyboardBar.carriesBar`) it
/// also draws the bar: the screen's buttons as a right-aligned group at the end
/// of the second row, which the program keys scroll under, … in the dock above
/// ⌄, and Back in a leading dock on regular width. The screen hands it what to
/// draw (`BarContent`) and the buttons (`SSHTerminalBarButtons`); the strip only
/// lays them out and forwards Back.
final class SSHTerminalKeyStripView: UIView {
    /// The bar this strip carries now; empty while the pill carries it.
    struct BarContent {
        var slots: [SSHTerminalBarSlot] = []
        /// The Rex control and the status symbol, after the slots, when room is left.
        var extras: [UIView] = []
        /// … in the dock. False while the pill carries the bar.
        var showsMore = false
        /// Back in the leading dock (regular width only).
        var showsBack = false
        /// The orange dot: on Back when it shows, else on ….
        var attentionPending = false
        var attentionColor: UIColor = .systemOrange
    }

    struct Handlers {
        var sendStrokes: ([SSHTerminalKeyStroke]) -> Void = { _ in }
        var sendKey: (GhosttyKey) -> Void = { _ in }
        var sendArrow: (GhosttyKey) -> Bool = { _ in false }
        var toggleModifier: (GhosttyMods) -> Void = { _ in }
        var modifierArmed: (GhosttyMods) -> Bool = { _ in false }
        var pasteTarget: UIPasteConfigurationSupporting?
        var hideKeyboard: () -> Void = {}
        var fillPassword: () -> Void = {}
        var goBack: () -> Void = {}
    }

    var handlers: Handlers

    private var programActions: [SSHTerminalKeyAction] = []
    private var foreground = UIColor.label
    private var barBackground = UIColor.systemBackground
    private var colors = ComposerThemeColors.placeholder

    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let fill = UIView()
    /// Holds the scroller; its mask cuts out the bar group's corner, so the
    /// program keys scroll under the group instead of showing through it.
    private let scrollClip = UIView()
    private let scrollClipMask = CAShapeLayer()
    private let scroll = SSHTerminalKeyScrollView()
    private let rows = UIStackView()
    private let keys = UIStackView()
    /// The accessory's second row: Paste and program actions.
    private let programRow = UIStackView()
    private let trailing = UIStackView()
    private let dock = UIView()
    /// The bar's buttons, right-aligned at the end of the second row.
    private let group = SSHTerminalKeyBarGroup()
    /// The end of the program row, as wide as the group, so its last key can
    /// scroll clear of it.
    private let programTail = UIView()
    /// … above ⌄, in a cell as tall as a key.
    private let moreCell = SSHTerminalKeyBarGroup()
    private let moreDot = SSHTerminalAttentionDot()
    private let leadingDock = UIView()
    private let back = SSHTerminalKeyButton()
    private let backDot = SSHTerminalAttentionDot()
    private var scrollAfterBack: NSLayoutConstraint?
    private var scrollAtEdge: NSLayoutConstraint?
    private var programTailWidth: NSLayoutConstraint?
    private weak var barButtons: SSHTerminalBarButtons?
    private(set) var barContent = BarContent()
    private var modifierButtons: [(button: UIButton, modifier: GhosttyMods, label: String)] = []
    private var arrowButtons: [SSHTerminalArrowButton] = []
    private var pasteControl: UIPasteControl?
    /// Lock and "Secure Input" while the keyboard's secure entry is on.
    private var secureCue: UIView?
    private var showsSecureInput = false
    /// Fill Password, hidden until offered.
    private var fillKey: SSHTerminalKeyButton?
    /// The label's host (`alex@mac-studio`) while Fill Password is offered, else nil.
    private var passwordFillHost: String?
    private var appliedSignature = ""

    /// Two 46pt rows; each key keeps its 44pt target.
    private static let accessoryHeight: CGFloat = 92

    init(handlers: Handlers) {
        self.handlers = handlers
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.accessoryHeight))
        autoresizingMask = [.flexibleWidth]
        build()
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.accessoryHeight)
    }

    func apply(
        actions: [SSHTerminalKeyAction] = [],
        colors: ComposerThemeColors,
        foreground: UIColor,
        background: UIColor
    ) {
        let signature = "\(actions.map(\.id).joined(separator: ","))|\(foreground)|\(background)"
        self.programActions = actions
        self.colors = colors
        self.foreground = foreground
        self.barBackground = background
        tintColor = foreground
        fill.backgroundColor = background.withAlphaComponent(0.55)
        backgroundColor = .clear
        dock.backgroundColor = colors.fg.withAlphaComponent(0.1)
        leadingDock.backgroundColor = dock.backgroundColor
        back.apply(title: nil, systemImage: "chevron.backward", colors: colors)
        guard signature != appliedSignature else {
            showModifiers()
            return
        }
        appliedSignature = signature
        rebuild()
        showModifiers()
    }

    /// Draws the bar `content` with `buttons` (the screen's keyboard-bar set),
    /// or nothing but the keys for an empty content. Buttons are kept by the
    /// set between passes, so this only moves views when the slots change.
    func showBar(_ content: BarContent, buttons: SSHTerminalBarButtons) {
        if barButtons !== buttons {
            barButtons = buttons
            buttons.more.removeFromSuperview()
            moreCell.addSubview(buttons.more)
            NSLayoutConstraint.activate([
                buttons.more.centerXAnchor.constraint(equalTo: moreCell.centerXAnchor),
                buttons.more.centerYAnchor.constraint(equalTo: moreCell.centerYAnchor),
            ])
            moreDot.pin(to: buttons.more)
        }
        let views = content.slots.map(buttons.view(for:)) + content.extras
        buttons.keepOnly(content.slots)
        if group.arrangedSubviews.count != views.count || !zip(group.arrangedSubviews, views).allSatisfy({ $0 === $1 }) {
            group.arrangedSubviews.forEach { $0.removeFromSuperview() }
            views.forEach(group.addArrangedSubview)
        }
        buttons.refresh()
        barContent = content
        group.isHidden = views.isEmpty
        moreCell.isHidden = !content.showsMore
        leadingDock.isHidden = !content.showsBack
        scrollAtEdge?.isActive = !content.showsBack
        scrollAfterBack?.isActive = content.showsBack
        for dot in [backDot, moreDot] { dot.apply(color: content.attentionColor, border: barBackground) }
        backDot.isHidden = !(content.showsBack && content.attentionPending)
        back.accessibilityValue = content.attentionPending ? "Attention pending" : nil
        let dotOnMore = content.showsMore && !content.showsBack && content.attentionPending
        moreDot.isHidden = !dotOnMore
        buttons.more.accessibilityValue = dotOnMore ? "Attention pending" : nil
        setNeedsLayout()
    }

    /// VoiceOver: Back, the keys row by row, the bar group, then … and ⌄.
    /// Only what shows: a listed hidden view would still be read.
    override var accessibilityElements: [Any]? {
        get { [leadingDock, scrollClip, group, trailing].filter { !$0.isHidden } }
        set { _ = newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Cut the group's corner out of the scroller, with the row's gap.
        let path = UIBezierPath(rect: scrollClip.bounds)
        if !group.isHidden, group.bounds.width > 0 {
            let frame = group.convert(group.bounds, to: scrollClip)
            path.append(UIBezierPath(rect: CGRect(
                x: frame.minX - 4, y: frame.minY, width: scrollClip.bounds.maxX - frame.minX + 4, height: frame.height
            )))
        }
        scrollClipMask.frame = scrollClip.bounds
        scrollClipMask.path = path.cgPath
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

    /// Shows Fill Password for `host` (`alex@mac-studio`) while a password prompt
    /// is up and the host has a password to fill; nil hides it.
    func setPasswordFill(host: String?) {
        guard host != passwordFillHost else { return }
        passwordFillHost = host
        applyPasswordFill()
    }

    private func applyPasswordFill() {
        let offered = passwordFillHost != nil
        fillKey?.isHidden = !offered
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
        glass.isUserInteractionEnabled = false
        fill.isUserInteractionEnabled = false
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
        rows.addArrangedSubview(programRow)
        trailing.axis = .vertical
        trailing.alignment = .center
        trailing.distribution = .fillEqually
        trailing.spacing = 0
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.isLayoutMarginsRelativeArrangement = true
        trailing.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2)
        dock.isUserInteractionEnabled = false
        dock.layer.cornerRadius = 20
        dock.layer.cornerCurve = .continuous
        leadingDock.layer.cornerRadius = 20
        leadingDock.layer.cornerCurve = .continuous
        scrollClipMask.fillRule = .evenOdd
        scrollClip.layer.mask = scrollClipMask
        group.axis = .horizontal
        group.alignment = .center
        group.spacing = 0
        group.isHidden = true
        group.setContentHuggingPriority(.required, for: .horizontal)
        moreCell.isHidden = true
        leadingDock.isHidden = true
        back.apply(title: nil, systemImage: "chevron.backward", colors: colors)
        back.accessibilityIdentifier = "sshTerminal.back"
        back.accessibilityLabel = "Back"
        back.addAction(UIAction { [weak self] _ in self?.handlers.goBack() }, for: .touchUpInside)
        backDot.pin(to: back)

        for view in [glass, fill, scrollClip, scroll, dock, trailing, group, programTail, leadingDock, back, moreCell] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        addSubview(fill)
        addSubview(scrollClip)
        scrollClip.addSubview(scroll)
        scroll.addSubview(rows)
        addSubview(dock)
        addSubview(trailing)
        addSubview(group)
        addSubview(leadingDock)
        leadingDock.addSubview(back)
        let atEdge = scrollClip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        scrollAtEdge = atEdge
        scrollAfterBack = scrollClip.leadingAnchor.constraint(equalTo: leadingDock.trailingAnchor, constant: 4)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            atEdge,
            scrollClip.topAnchor.constraint(equalTo: topAnchor),
            scrollClip.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: scrollClip.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: scrollClip.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: scrollClip.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: scrollClip.bottomAnchor),
            trailing.leadingAnchor.constraint(equalTo: scrollClip.trailingAnchor, constant: 4),
            leadingDock.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            leadingDock.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            leadingDock.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            leadingDock.widthAnchor.constraint(equalToConstant: SSHTerminalKeyboardBar.dockWidth - 4),
            back.centerXAnchor.constraint(equalTo: leadingDock.centerXAnchor),
            back.centerYAnchor.constraint(equalTo: leadingDock.centerYAnchor),
            group.trailingAnchor.constraint(equalTo: scrollClip.trailingAnchor),
            group.bottomAnchor.constraint(equalTo: bottomAnchor),
            group.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5),
            moreCell.widthAnchor.constraint(equalToConstant: SSHTerminalGlassPill.itemWidth),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
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
            heightAnchor.constraint(equalToConstant: Self.accessoryHeight),
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
        rebuildKeys()
        showModifiers()
    }

    private func rebuildKeys() {
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
        // The tail is made again with the row, so its width follows the group anew.
        programRow.addArrangedSubview(programTail)
        programTailWidth = programTail.widthAnchor.constraint(equalTo: group.widthAnchor)
        programTailWidth?.isActive = true
        trailing.addArrangedSubview(moreCell)
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

    /// "Fill Password", the key a password prompt offers. Created with the
    /// strip and shown by `setPasswordFill`, so it keeps one identity.
    private func addFillPasswordKey(to row: UIStackView) {
        let key = addKey(
            title: "Fill Password",
            systemImage: "key.fill",
            id: "sshTerminal.key.fillPassword",
            accessibilityLabel: "Fill password",
            hint: "Asks for Face ID, Touch ID, or your passcode, then types the saved password without pressing Return",
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

/// The keyboard bar's button group and the dock's … cell. Their buttons are
/// the pill's 44 × 36 pt glyphs; the cell is a 46 pt row, and a touch anywhere
/// in it goes to the nearest button's column, so every target is 44 pt.
final class SSHTerminalKeyBarGroup: UIStackView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, bounds.contains(point) else { return nil }
        if let hit = super.hitTest(point, with: event), hit !== self { return hit }
        let buttons = (arrangedSubviews.isEmpty ? subviews : arrangedSubviews).filter { !$0.isHidden && $0.isUserInteractionEnabled }
        return buttons.min {
            abs(convert($0.center, from: $0.superview).x - point.x) < abs(convert($1.center, from: $1.superview).x - point.x)
        }
    }
}

/// The orange attention dot on the keyboard bar's Back or ….
final class SSHTerminalAttentionDot: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        layer.cornerRadius = 5
        layer.borderWidth = 1.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func pin(to button: UIView) {
        removeFromSuperview()
        button.addSubview(self)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 10),
            heightAnchor.constraint(equalToConstant: 10),
            centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: 11),
            centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: -11),
        ])
    }

    func apply(color: UIColor, border: UIColor) {
        backgroundColor = color
        layer.borderColor = border.cgColor
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

/// Compact terminal key with a 44pt hit target and press fade. Plain chrome:
/// the accessory bar supplies the glass.
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
