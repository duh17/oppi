import UIKit
import UniformTypeIdentifiers

/// The bar's buttons for one surface: the floating pill and the keyboard
/// bar each own one set, made the same way, so a slot looks, speaks, and acts
/// the same on both and carries the same identifier
/// (`SSHTerminalBarSlot.accessibilityIdentifier`). Only one surface is on
/// screen and in the accessibility tree at a time.
///
/// Every button runs `perform`, so a tap, VoiceOver activation, and the …
/// menu item for the same slot do the same thing. Attach, the switcher, and …
/// show their menus as the primary action; the screen installs those menus.
/// Paste is the system paste control, whose items go to `pasteTarget`.
@MainActor
final class SSHTerminalBarButtons {
    var perform: (SSHTerminalBarSlot) -> Void = { _ in }
    /// The paste control's target (`UIPasteControl.target`).
    weak var pasteTarget: UIPasteConfigurationSupporting?

    /// Opens Herdr's overview sheet; orange while an agent needs you.
    let herdr = SSHTerminalPillButton(
        image: SSHTerminalBarAction.herdr.image(configuration: SSHTerminalPillButton.symbolConfiguration),
        label: SSHTerminalBarAction.herdr.accessibilityLabel,
        identifier: SSHTerminalBarAction.herdr.accessibilityIdentifier
    )
    /// Opens a menu of every open terminal.
    let switcher = SSHTerminalPillButton(
        systemName: SSHTerminalBarAction.switcher.symbol,
        label: SSHTerminalBarAction.switcher.accessibilityLabel,
        identifier: SSHTerminalBarAction.switcher.accessibilityIdentifier
    )
    /// Opens the attachment menu: Photo Library, Camera, Choose File, Canvas.
    let attach = SSHTerminalPillButton(
        systemName: SSHTerminalBarAction.attach.symbol,
        label: SSHTerminalBarAction.attach.accessibilityLabel,
        identifier: SSHTerminalBarAction.attach.accessibilityIdentifier
    )
    /// The mic, which turns into the dictation orb while it listens.
    let dictate = SSHTerminalDictateButton()
    let more = SSHTerminalPillButton(systemName: "ellipsis", label: "More", identifier: "sshTerminal.more")

    private var made: [String: (slot: SSHTerminalBarSlot, view: UIView)] = [:]
    private var tint: UIColor = .label
    /// The chat composer's colors, for keys drawn as Send or Stop.
    private var composerColors = ComposerThemeColors(palette: ThemeRuntimeState.currentPalette())
    private var pasteBackground: UIColor = .black
    private var keysEnabled = true

    init() {
        more.showsMenuAsPrimaryAction = true
        switcher.showsMenuAsPrimaryAction = true
        attach.showsMenuAsPrimaryAction = true
        herdr.addAction(UIAction { [weak self] _ in
            self?.perform(SSHTerminalBarSlot(content: .action(.herdr)))
        }, for: .touchUpInside)
        dictate.onTap = { [weak self] in self?.perform(SSHTerminalBarSlot(content: .action(.dictate))) }
    }

    /// The buttons kept for the life of the set, whether drawn or not.
    var persistent: [UIView] {
        [switcher, attach, dictate, more, herdr]
    }

    func isPersistent(_ view: UIView) -> Bool {
        persistent.contains { $0 === view }
    }

    func button(for action: SSHTerminalBarAction) -> SSHTerminalPillButton? {
        switch action {
        case .switcher: switcher
        case .attach: attach
        case .herdr: herdr
        default: nil
        }
    }

    /// The view a bar slot draws, made once and kept while the slot stays
    /// the same. A slot whose content changed (a custom key renamed, a
    /// shortcut rebound) is a new button, so its semantics start fresh. A key
    /// that only became Send or Stop, or went back, keeps its button and is
    /// restyled in place, so the pill does not swap it out.
    func view(for slot: SSHTerminalBarSlot) -> UIView {
        if case .action(let action) = slot.content {
            if action == .dictate { return dictate }
            if let persistent = button(for: action) { return persistent }
        }
        if let existing = made[slot.id], existing.slot.content == slot.content {
            if existing.slot.agentRole != slot.agentRole, let button = existing.view as? SSHTerminalPillButton {
                made[slot.id] = (slot, button)
                style(button, for: slot)
            }
            return existing.view
        }
        let view = makeView(for: slot)
        made[slot.id] = (slot, view)
        return view
    }

    /// Forgets what is no longer drawn; a slot that returns is made again.
    func keepOnly(_ slots: [SSHTerminalBarSlot]) {
        let keep = Set(slots.map(\.id))
        made = made.filter { keep.contains($0.key) }
    }

    private func makeView(for slot: SSHTerminalBarSlot) -> UIView {
        if case .action(.paste) = slot.content { return makePasteControl() }
        let button = SSHTerminalPillButton(
            image: nil,
            label: slot.accessibilityLabel,
            identifier: slot.accessibilityIdentifier
        )
        style(button, for: slot)
        // Read when tapped: the key's bytes never change, its role may have.
        let id = slot.id
        button.addAction(UIAction { [weak self] _ in
            guard let self, let current = self.made[id]?.slot else { return }
            self.perform(current)
        }, for: .touchUpInside)
        return button
    }

    /// What the button shows and says for `slot`: Send or Stop in the chat
    /// composer's look, else the key cap or the action's symbol in the tint.
    private func style(_ button: SSHTerminalPillButton, for slot: SSHTerminalBarSlot) {
        button.accessibilityLabel = slot.accessibilityLabel
        button.accessibilityValue = slot.accessibilityValue
        button.accessibilityIdentifier = slot.accessibilityIdentifier
        button.largeContentTitle = slot.accessibilityLabel
        if let look = look(for: slot) {
            button.showAgentKey(look)
            return
        }
        if let cap = slot.keyCap {
            button.showKeyCap(cap)
        } else if case .action(let action) = slot.content {
            button.showSymbol(action.image(configuration: SSHTerminalPillButton.symbolConfiguration))
        }
        if case .shortcut(let shortcut) = slot.content {
            // The cap is the key; Large Content Viewer names the job too.
            button.largeContentTitle = "\(shortcut.title) \(shortcut.keyLabel)"
        }
        button.apply(tint: tint)
    }

    private func look(for slot: SSHTerminalBarSlot) -> ComposerPrimaryActionLook? {
        switch slot.agentRole {
        case .send: .send(busy: false, colors: composerColors)
        case .stop: .stop(stopping: false, colors: composerColors)
        case nil: nil
        }
    }

    /// `herdrWaiting` is Herdr's count of agents that need you, nil while
    /// Herdr has not answered. Keys dim while there is no
    /// connection to send them on. `background` is the terminal's: the paste
    /// control draws its capsule in it, since iOS will not draw a secure
    /// control on a clear background.
    func apply(
        themeID: ThemeID,
        herdrWaiting: Int?,
        openTerminals: Int,
        tint: UIColor,
        background: UIColor,
        keysEnabled: Bool,
        traits: UITraitCollection
    ) {
        // Compared resolved: a theme color is a new dynamic UIColor every pass.
        func same(_ one: UIColor, _ two: UIColor) -> Bool {
            one.resolvedColor(with: traits) == two.resolvedColor(with: traits)
        }
        if !same(tint, self.tint) || !same(background, pasteBackground) {
            // The paste control takes its colors only when it is made: the
            // next `view(for:)` makes it again.
            made["action.paste"] = nil
        }
        self.tint = tint
        composerColors = ComposerThemeColors(palette: themeID.palette)
        pasteBackground = background
        self.keysEnabled = keysEnabled
        switcher.accessibilityValue = "\(openTerminals) open"
        switcher.apply(tint: tint)
        let waitingCount = herdrWaiting ?? 0
        herdr.apply(tint: waitingCount > 0 ? themeID.palette.ui.orange : tint)
        herdr.accessibilityValue = herdrWaiting.map { "\($0) need you" } ?? ""
        let label = SSHTerminalBarAction.herdr.accessibilityLabel
        herdr.largeContentTitle = waitingCount > 0 ? "\(label) (\(waitingCount))" : label
        more.apply(tint: tint)
        attach.apply(tint: tint)
        dictate.apply(tint: tint)
        refresh()
    }

    /// The state every made button carries.
    func refresh() {
        for (_, entry) in made {
            guard let button = entry.view as? SSHTerminalPillButton else { continue }
            if let look = look(for: entry.slot) { button.showAgentKey(look) } else { button.apply(tint: tint) }
            if entry.slot.sendsKeys { button.isEnabled = keysEnabled }
        }
    }

    private func makePasteControl() -> UIPasteControl {
        let style = UIPasteControl.Configuration()
        style.displayMode = .iconOnly
        style.cornerStyle = .capsule
        style.baseForegroundColor = tint
        style.baseBackgroundColor = pasteBackground
        let paste = UIPasteControl(configuration: style)
        paste.translatesAutoresizingMaskIntoConstraints = false
        paste.target = pasteTarget
        paste.accessibilityIdentifier = SSHTerminalBarAction.paste.accessibilityIdentifier
        let width = paste.widthAnchor.constraint(equalToConstant: SSHTerminalGlassPill.itemWidth)
        width.priority = .required - 1
        NSLayoutConstraint.activate([
            width,
            paste.heightAnchor.constraint(equalToConstant: SSHTerminalGlassPill.height),
        ])
        return paste
    }
}

/// The bottom bar's one centred glass pill: the program-status symbol (while a
/// program has reported), the buttons the layout draws (`SSHTerminalBarPlacement.bar`:
/// Type in Terminal, Dictate, Attach, keys, Paste, Browse Files Here,
/// Herdr's overview, the switcher, Program Shortcuts, and custom keys),
/// in the layout's order, then
/// the … menu, which is always last. It sits centred between Back and the Rex
/// pane switcher's pill, so a button added or taken away grows or shrinks it the
/// same distance each way. Its buttons are a `SSHTerminalBarButtons` set.
///
/// Paste's target is this pill, not the grid: with the grid as its target, a
/// tap made the grid first responder, which raised the keyboard (and resized
/// the shell) for a paste that needs none, and an image did not arrive. The
/// pill cannot become first responder, so the items arrive here with the
/// keyboard down and go on to the grid through `deliverPaste`.
///
/// Buttons are kept between passes and shown or hidden inside one animation
/// block, so the stack grows or shrinks smoothly instead of rebuilding.
final class SSHTerminalBarPill: SSHTerminalGlassPill {
    static let changeDuration: TimeInterval = 0.25

    /// What the paste control's items are handed to: the grid's paste.
    var deliverPaste: ([NSItemProvider]) -> Void = { _ in }

    let status: SSHTerminalStatusGlyphButton
    let buttons = SSHTerminalBarButtons()
    var more: SSHTerminalPillButton { buttons.more }

    /// The buttons the pill draws now, in order.
    private(set) var slots: [SSHTerminalBarSlot] = []

    init(status: SSHTerminalStatusGlyphButton) {
        self.status = status
        super.init(frame: .zero)
        // What the grid takes: text, or an image it saves on the host.
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.plainText.identifier, UTType.image.identifier,
        ])
        buttons.pasteTarget = self
        for view in [status] + buttons.persistent {
            view.isHidden = view !== more
            stack.addArrangedSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func paste(itemProviders: [NSItemProvider]) {
        deliverPaste(itemProviders)
    }

    func button(for action: SSHTerminalBarAction) -> SSHTerminalPillButton? {
        buttons.button(for: action)
    }

    /// The button a bar slot draws (`SSHTerminalBarButtons.view(for:)`).
    func button(for slot: SSHTerminalBarSlot) -> UIButton? {
        buttons.view(for: slot) as? UIButton
    }

    /// Draws `next` between the status symbol (when `showsStatus`) and …. A
    /// change is one animation block: buttons that come grow in and the pill
    /// widens from its centre, buttons that go shrink out; `animated` false
    /// (Reduce Motion, or no window yet) makes the same change at once.
    func show(_ next: [SSHTerminalBarSlot], showsStatus: Bool, animated: Bool) {
        slots = next
        let wanted: [UIView] = (showsStatus ? [status] : []) + next.map(buttons.view(for:)) + [more]
        let wantedIDs = Set(wanted.map(ObjectIdentifier.init))
        let incoming = wanted.filter { $0.isHidden || $0.superview !== stack }
        let outgoing = stack.arrangedSubviews.filter { !$0.isHidden && !wantedIDs.contains(ObjectIdentifier($0)) }
        buttons.keepOnly(next)
        // Order the stack before the animation, so only appearing and
        // disappearing animate. Views leaving are hidden, so their place does
        // not matter; the incoming start hidden, so they have no size yet.
        for view in incoming {
            view.alpha = 0
            view.isHidden = true
        }
        // Nothing to move when the views on show are already these, in order:
        // this runs on every pass, and re-adding them would rebuild the stack.
        let onShow = stack.arrangedSubviews.filter { !$0.isHidden }
        if incoming.isEmpty, outgoing.isEmpty, onShow.count == wanted.count, zip(onShow, wanted).allSatisfy({ $0 === $1 }) {
            buttons.refresh()
            return
        }
        for view in wanted { stack.addArrangedSubview(view) }
        let change = {
            for view in incoming {
                view.isHidden = false
                view.alpha = 1
            }
            for view in outgoing {
                view.isHidden = true
                view.alpha = 0
            }
            self.superview?.layoutIfNeeded()
        }
        let settle = {
            // Only what is still unwanted: a later pass may have brought one back.
            for view in outgoing where view.isHidden && view !== self.status && !self.buttons.isPersistent(view) {
                view.removeFromSuperview()
            }
        }
        if animated, !incoming.isEmpty || !outgoing.isEmpty, window != nil {
            UIView.animate(
                withDuration: Self.changeDuration, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut],
                animations: change, completion: { _ in settle() }
            )
        } else {
            change()
            settle()
        }
        buttons.refresh()
    }

    /// The pill's colors and button state (`SSHTerminalBarButtons.apply`).
    func apply(
        themeID: ThemeID,
        herdrWaiting: Int?,
        openTerminals: Int,
        tint: UIColor,
        background: UIColor,
        keysEnabled: Bool
    ) {
        buttons.apply(
            themeID: themeID, herdrWaiting: herdrWaiting, openTerminals: openTerminals, tint: tint,
            background: background, keysEnabled: keysEnabled, traits: traitCollection
        )
    }
}

/// The Rex session's one control, bottom trailing: a pill of its own, kept
/// apart from the bar's buttons, for every terminal that is a Rex pane. Its icon
/// is the pane on screen with that program's status on it; a tap opens the Rex
/// panel, touch and hold the panes menu.
final class SSHTerminalRexPanesPill: SSHTerminalGlassPill {
    let button = SSHTerminalRexPanesButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.addArrangedSubview(button)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Draws the shown pane and its status (`SSHTerminalRexPanesButton.apply`);
    /// the pill is there only while the button is.
    func apply(
        state: RexSessionState?, tint: UIColor, status: SSHTerminalRexPillStatus, themeID: ThemeID, reduceMotion: Bool
    ) {
        button.apply(state: state, tint: tint, status: status, themeID: themeID, reduceMotion: reduceMotion)
        isHidden = button.isHidden
    }
}
