import UIKit
import UniformTypeIdentifiers

/// The bottom bar's one centred glass pill: the program-status symbol (while a
/// program has reported), the buttons the layout draws (`SSHTerminalBarPlacement.slots`:
/// input, keys, Paste, Browse Files Here, the multiplexers' overviews, the
/// switcher, Program Shortcuts, and custom keys), in the layout's order, then
/// the … menu, which is always last. It sits centred between Back and the Rex
/// pane switcher's pill, so a button added or taken away grows or shrinks it the
/// same distance each way.
///
/// Every button runs `perform`, so a tap, VoiceOver activation, and the …
/// menu item for the same slot do the same thing. Paste is the system paste
/// control, which reads the clipboard without the Allow Paste alert. Its
/// target is this pill, not the grid: with the grid as its target, a tap made
/// the grid first responder, which raised the keyboard (and resized the
/// shell) for a paste that needs none, and an image did not arrive. The pill
/// cannot become first responder, so the items arrive here with the keyboard
/// down and go on to the grid through `deliverPaste`.
///
/// Buttons are kept between passes and shown or hidden inside one animation
/// block, so the stack grows or shrinks smoothly instead of rebuilding.
final class SSHTerminalBarPill: SSHTerminalGlassPill {
    static let changeDuration: TimeInterval = 0.25

    var perform: (SSHTerminalBarSlot) -> Void = { _ in }
    /// What the paste control's items are handed to: the grid's paste.
    var deliverPaste: ([NSItemProvider]) -> Void = { _ in }

    let status: SSHTerminalStatusGlyphButton
    /// One button per multiplexer overview (`SSHTerminalBarAction.overviews`).
    let overviews: [SSHTerminalBarAction: SSHTerminalPillButton]
    /// Opens a menu of every open terminal.
    let switcher = SSHTerminalPillButton(
        systemName: SSHTerminalBarAction.switcher.symbol(),
        label: SSHTerminalBarAction.switcher.accessibilityLabel,
        identifier: SSHTerminalBarAction.switcher.accessibilityIdentifier
    )
    let more = SSHTerminalPillButton(systemName: "ellipsis", label: "More", identifier: "sshTerminal.more")

    /// The buttons the pill draws now, in order.
    private(set) var slots: [SSHTerminalBarSlot] = []
    private var made: [String: (slot: SSHTerminalBarSlot, view: UIView)] = [:]
    private var tint: UIColor = .label
    private var pasteBackground: UIColor = .black
    private var selected: SSHTerminalBarAction?
    private var keysEnabled = true

    init(status: SSHTerminalStatusGlyphButton) {
        self.status = status
        overviews = Dictionary(uniqueKeysWithValues: SSHTerminalBarAction.overviews.map { action in
            (action, SSHTerminalPillButton(
                image: action.image(configuration: SSHTerminalPillButton.symbolConfiguration),
                label: action.accessibilityLabel,
                identifier: action.accessibilityIdentifier
            ))
        })
        super.init(frame: .zero)
        // What the grid takes: text, or an image it saves on the host.
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.plainText.identifier, UTType.image.identifier,
        ])
        more.showsMenuAsPrimaryAction = true
        switcher.showsMenuAsPrimaryAction = true
        for action in SSHTerminalBarAction.overviews {
            overviews[action]?.addAction(UIAction { [weak self] _ in
                self?.perform(SSHTerminalBarSlot(content: .action(action)))
            }, for: .touchUpInside)
        }
        let fixed: [UIView] = [status, switcher, more] + SSHTerminalBarAction.overviews.compactMap { overviews[$0] }
        for view in fixed {
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
        action == .switcher ? switcher : overviews[action]
    }

    /// The button a bar slot draws, made once and kept while the slot stays
    /// the same. A slot whose content changed (a custom key renamed, a
    /// shortcut rebound) is a new button.
    func button(for slot: SSHTerminalBarSlot) -> UIButton? {
        view(for: slot) as? UIButton
    }

    private func view(for slot: SSHTerminalBarSlot) -> UIView {
        if case .action(let action) = slot.content, let persistent = button(for: action) { return persistent }
        if let existing = made[slot.id], existing.slot == slot { return existing.view }
        let view = makeView(for: slot)
        made[slot.id] = (slot, view)
        return view
    }

    private func makeView(for slot: SSHTerminalBarSlot) -> UIView {
        if case .action(.paste) = slot.content { return makePasteControl() }
        let image: UIImage? = if case .action(let action) = slot.content {
            action.image(configuration: SSHTerminalPillButton.symbolConfiguration)
        } else {
            nil
        }
        let button = SSHTerminalPillButton(
            image: image,
            label: slot.accessibilityLabel,
            identifier: slot.accessibilityIdentifier
        )
        if let cap = slot.keyCap { button.showKeyCap(cap) }
        button.accessibilityValue = slot.accessibilityValue
        if case .shortcut(let shortcut) = slot.content {
            // The cap is the key; Large Content Viewer names the job too.
            button.largeContentTitle = "\(shortcut.title) \(shortcut.keyLabel)"
        }
        button.addAction(UIAction { [weak self] _ in self?.perform(slot) }, for: .touchUpInside)
        button.apply(tint: tint)
        return button
    }

    /// Draws `next` between the status symbol (when `showsStatus`) and …. A
    /// change is one animation block: buttons that come grow in and the pill
    /// widens from its centre, buttons that go shrink out; `animated` false
    /// (Reduce Motion, or no window yet) makes the same change at once.
    func show(_ next: [SSHTerminalBarSlot], showsStatus: Bool, animated: Bool) {
        slots = next
        let wanted: [UIView] = (showsStatus ? [status] : []) + next.map(view(for:)) + [more]
        let wantedIDs = Set(wanted.map(ObjectIdentifier.init))
        let incoming = wanted.filter { $0.isHidden || $0.superview !== stack }
        let outgoing = stack.arrangedSubviews.filter { !$0.isHidden && !wantedIDs.contains(ObjectIdentifier($0)) }
        // Forget what is no longer drawn; a slot that returns is made again.
        let keep = Set(next.map(\.id))
        made = made.filter { keep.contains($0.key) }
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
            refreshButtons()
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
            for view in outgoing where view.isHidden && !self.isPersistent(view) {
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
        refreshButtons()
    }

    private func isPersistent(_ view: UIView) -> Bool {
        view === status || view === more || view === switcher || overviews.values.contains { $0 === view }
    }

    /// `waiting` holds each available multiplexer's count of panes that need
    /// you; one it does not name has not answered. `selected` is the input
    /// that typing goes to now (`.keyboard` or `.chatBar`): its button draws
    /// filled and carries the selected trait. Keys dim while there is no
    /// connection to send them on. `background` is the terminal's: the paste
    /// control draws its capsule in it, since iOS will not draw a secure
    /// control on a clear background.
    func apply(
        themeID: ThemeID,
        waiting: [SSHTerminalBarAction: Int],
        openTerminals: Int,
        tint: UIColor,
        background: UIColor,
        selected: SSHTerminalBarAction?,
        keysEnabled: Bool
    ) {
        // Compared resolved: a theme color is a new dynamic UIColor every pass.
        func same(_ one: UIColor, _ two: UIColor) -> Bool {
            one.resolvedColor(with: traitCollection) == two.resolvedColor(with: traitCollection)
        }
        if !same(tint, self.tint) || !same(background, pasteBackground) {
            // The paste control takes its colors only when it is made: the
            // next `show` makes it again.
            made["action.paste"] = nil
        }
        self.tint = tint
        pasteBackground = background
        self.selected = selected
        self.keysEnabled = keysEnabled
        switcher.accessibilityValue = "\(openTerminals) open"
        switcher.apply(tint: tint)
        for action in SSHTerminalBarAction.overviews {
            guard let button = overviews[action] else { continue }
            let count = waiting[action]
            let waitingCount = count ?? 0
            button.apply(tint: waitingCount > 0 ? themeID.palette.ui.orange : tint)
            button.accessibilityValue = count.map { "\($0) need you" } ?? ""
            button.largeContentTitle = waitingCount > 0
                ? "\(action.accessibilityLabel) (\(waitingCount))" : action.accessibilityLabel
        }
        more.apply(tint: tint)
        refreshButtons()
    }

    /// The state every button carries, for the buttons there are now.
    private func refreshButtons() {
        for (_, entry) in made {
            guard let button = entry.view as? SSHTerminalPillButton else { continue }
            button.apply(tint: tint)
            if case .action(let action) = entry.slot.content, action == .keyboard || action == .chatBar {
                let isSelected = action == selected
                button.setSymbol(action.symbol(selected: isSelected))
                button.accessibilityTraits = isSelected ? [.button, .selected] : .button
            }
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
        paste.target = self
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
