import GhosttyVt
import UIKit

/// A button the SSH terminal's bottom bar can show. Settings > SSH Terminal >
/// Bottom Bar picks which and in what order (`SSHTerminalBarLayout`), and the
/// cases read in the default order.
///
/// Back and the … menu are fixed (the bar's leading and trailing ends) and the
/// program-status symbol is a readout, so none of them is here. A middle
/// action sits in the middle pill; Herdr and the switcher stay in the trailing
/// pill beside …, where they always were.
enum SSHTerminalBarAction: String, BarLayoutAction, Identifiable {
    case keyboard
    case chatBar
    case escape
    case interrupt
    case tab
    case up
    case down
    case enter
    case paste
    case browseFiles
    case herdr
    case switcher

    var id: String { rawValue }

    /// Today's bar plus the two input buttons: Type in Terminal and Chat Bar in
    /// the middle, Herdr and the switcher on the right (each only where the
    /// screen can offer it). Keys, Paste, and Browse Files Here start off.
    static let defaultShown: Set<SSHTerminalBarAction> = [.keyboard, .chatBar, .herdr, .switcher]

    enum Group: Hashable, Sendable {
        case middle
        case trailing
    }

    var group: Group {
        switch self {
        case .herdr, .switcher: .trailing
        default: .middle
        }
    }

    /// Sends keys to the program instead of opening something. A key turned off
    /// is not offered in the … menu (the keyboard bars have every key), but a
    /// key turned on that does not fit the bar is.
    var isKey: Bool {
        switch self {
        case .escape, .interrupt, .tab, .up, .down, .enter: true
        default: false
        }
    }

    /// The settings row's title.
    var label: String {
        switch self {
        case .keyboard: String(localized: "Type in Terminal")
        case .chatBar: String(localized: "Chat Bar")
        case .escape: String(localized: "Escape")
        case .interrupt: String(localized: "Control-C")
        case .tab: String(localized: "Tab")
        case .up: String(localized: "Up Arrow")
        case .down: String(localized: "Down Arrow")
        case .enter: String(localized: "Return")
        case .paste: String(localized: "Paste")
        case .browseFiles: String(localized: "Browse Files Here")
        case .herdr: String(localized: "Herdr Agents")
        case .switcher: String(localized: "Switch Terminal")
        }
    }

    /// The … menu item's title: the command, as the menu said before.
    var menuTitle: String {
        switch self {
        case .chatBar: String(localized: "Use Chat Bar")
        case .escape: String(localized: "Send Escape")
        case .interrupt: String(localized: "Send Control-C")
        case .tab: String(localized: "Send Tab")
        case .up: String(localized: "Send Up Arrow")
        case .down: String(localized: "Send Down Arrow")
        case .enter: String(localized: "Send Return")
        default: label
        }
    }

    /// What VoiceOver says for the bar button: the job, not the glyph.
    var accessibilityLabel: String {
        switch self {
        case .keyboard: String(localized: "Type in terminal")
        case .chatBar: String(localized: "Use chat bar")
        case .herdr: String(localized: "Herdr agents")
        case .switcher: String(localized: "Switch terminal")
        default: menuTitle
        }
    }

    /// A short key cap the bar draws as text, the way the keyboard bars label
    /// these keys. Nil draws `symbol`.
    var keyCap: String? {
        switch self {
        case .escape: "Esc"
        case .interrupt: "^C"
        case .tab: "Tab"
        default: nil
        }
    }

    /// The SF Symbol for the bar (unless `keyCap` is set), the menu, and the
    /// settings row. `selected` is the filled form an input button shows while
    /// typing goes there.
    func symbol(selected: Bool = false) -> String {
        switch self {
        case .keyboard: selected ? "keyboard.fill" : "keyboard"
        case .chatBar: selected ? "text.bubble.fill" : "text.bubble"
        case .escape: "escape"
        case .interrupt: "xmark.octagon"
        case .tab: "arrow.right.to.line"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .enter: "return"
        case .paste: "doc.on.clipboard"
        case .browseFiles: "folder"
        case .herdr: "square.grid.2x2"
        case .switcher: "rectangle.stack"
        }
    }

    /// Stable identifier on the bar button, whichever position holds it. Herdr
    /// and the switcher keep the ids they had before the bar was customizable.
    var accessibilityIdentifier: String {
        switch self {
        case .herdr: "sshTerminal.herdr"
        case .switcher: "sshTerminal.switcher"
        case .paste: "sshTerminal.bar.paste"
        default: "sshTerminal.bar.\(rawValue)"
        }
    }

    /// Stable identifier on the … menu item.
    var menuIdentifier: String { "sshTerminal.menu.\(rawValue)" }

    /// The keys a key action sends, as the keyboard bars send them.
    var strokes: [SSHTerminalKeyStroke] {
        let spec: String? = switch self {
        case .escape: "escape"
        case .interrupt: "ctrl+c"
        case .tab: "tab"
        case .up: "up"
        case .down: "down"
        case .enter: "enter"
        default: nil
        }
        return spec.flatMap { SSHTerminalKeymap.parse($0, syntax: .plus) } ?? []
    }
}

typealias SSHTerminalBarLayout = BarLayout<SSHTerminalBarAction>

/// What the bottom bar draws, split by pill, and what the … menu offers.
struct SSHTerminalBarPlacement: Equatable {
    var middle: [SSHTerminalBarAction]
    var trailing: [SSHTerminalBarAction]
    var menu: [SSHTerminalBarAction]
}

extension BarLayout where Action == SSHTerminalBarAction {
    /// The middle pill holds as many of its shown actions as fit
    /// (`middleCapacity`); the rest go to the … menu with the turned-off
    /// actions that are not keys. Paste never goes in the menu: a menu item
    /// cannot read the clipboard without iOS's Allow Paste alert, and holding
    /// the grid already offers Paste.
    func placement(available: Set<SSHTerminalBarAction>, middleCapacity: Int) -> SSHTerminalBarPlacement {
        let drawn = bar(available: available)
        let middleShown = drawn.filter { $0.group == .middle }
        let fits = Array(middleShown.prefix(max(0, middleCapacity)))
        let overflow = Array(middleShown.dropFirst(fits.count))
        let hidden = menu(available: available).filter { !$0.isKey }
        let menu = order.filter { action in
            action != .paste && (overflow.contains(action) || hidden.contains(action))
        }
        return SSHTerminalBarPlacement(
            middle: fits,
            trailing: drawn.filter { $0.group == .trailing },
            menu: menu
        )
    }
}

/// The bottom bar's middle pill: the shown middle actions that fit, in order.
/// Rebuilt only when that list changes. Every button runs `perform`, so a tap,
/// VoiceOver activation, and the … menu item for the same action do the same
/// thing. Paste is the system paste control, which reads the clipboard
/// without the Allow Paste alert and delivers to the grid.
final class SSHTerminalBarMiddlePill: SSHTerminalGlassPill {
    var perform: (SSHTerminalBarAction) -> Void = { _ in }
    /// Where the paste control delivers: the grid.
    weak var pasteTarget: UIPasteConfigurationSupporting? {
        didSet { pasteControl?.target = pasteTarget }
    }

    private(set) var actions: [SSHTerminalBarAction] = []
    private var buttons: [SSHTerminalBarAction: SSHTerminalPillButton] = [:]
    private var pasteControl: UIPasteControl?
    private var tint: UIColor = .label

    func show(_ next: [SSHTerminalBarAction]) {
        guard next != actions else { return }
        actions = next
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = [:]
        pasteControl = nil
        for action in next {
            if action == .paste {
                stack.addArrangedSubview(makePasteControl())
                continue
            }
            let button = SSHTerminalPillButton(
                systemName: action.symbol(),
                label: action.accessibilityLabel,
                identifier: action.accessibilityIdentifier
            )
            if let cap = action.keyCap { button.showKeyCap(cap) }
            button.addAction(UIAction { [weak self] _ in self?.perform(action) }, for: .touchUpInside)
            button.apply(tint: tint)
            buttons[action] = button
            stack.addArrangedSubview(button)
        }
        isHidden = next.isEmpty
    }

    /// `selected` is the input that typing goes to now (`.keyboard` or
    /// `.chatBar`): its button draws filled and carries the selected trait.
    /// Keys dim while there is no connection to send them on.
    func apply(tint: UIColor, selected: SSHTerminalBarAction?, keysEnabled: Bool) {
        // Compared resolved: a theme color is a new dynamic UIColor every pass.
        let changed = tint.resolvedColor(with: traitCollection) != self.tint.resolvedColor(with: traitCollection)
        if changed, pasteControl != nil {
            // The paste control takes its colors only when it is made.
            self.tint = tint
            let shown = actions
            actions = []
            show(shown)
        }
        self.tint = tint
        for (action, button) in buttons {
            button.apply(tint: tint)
            if action == .keyboard || action == .chatBar {
                let isSelected = action == selected
                button.setSymbol(action.symbol(selected: isSelected))
                button.accessibilityTraits = isSelected ? [.button, .selected] : .button
            }
            if action.isKey { button.isEnabled = keysEnabled }
        }
    }

    func button(for action: SSHTerminalBarAction) -> UIButton? { buttons[action] }

    private func makePasteControl() -> UIPasteControl {
        let style = UIPasteControl.Configuration()
        style.displayMode = .iconOnly
        style.cornerStyle = .capsule
        style.baseForegroundColor = tint
        style.baseBackgroundColor = .clear
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
        pasteControl = paste
        return paste
    }
}
