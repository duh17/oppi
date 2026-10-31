import GhosttyVt
import UIKit
import UniformTypeIdentifiers

/// A built-in button the SSH terminal's bottom bar can show. Settings > Terminal >
/// Bottom Bar picks which and in what order, as one list of
/// `SSHTerminalBarItem`s (these, Program Shortcuts, and the person's custom
/// keys), and the cases read in the default order.
///
/// Back and the … menu are fixed (the bar's leading end, and the end of the
/// one centred pill), the Rex pane switcher has a pill of its own at the
/// trailing end, and the program-status symbol is a readout, so none of them
/// is here.
enum SSHTerminalBarAction: String, CaseIterable, Identifiable {
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
    case rex
    case switcher

    var id: String { rawValue }

    /// The multiplexers whose overview sheet a button opens.
    static let overviews: [SSHTerminalBarAction] = [.herdr, .rex]

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
        case .rex: String(localized: "Rex Sessions")
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
        case .rex: String(localized: "Rex sessions")
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

    /// The multiplexer's own mark, drawn instead of `symbol` wherever the
    /// action shows an icon: a template vector asset, credited in
    /// `Resources/MultiplexerLogos-NOTICE.txt`.
    var logo: String? {
        switch self {
        case .herdr: "herdr-logo"
        case .rex: "rex-logo"
        default: nil
        }
    }

    /// The action's icon under `configuration` (nil: a menu's own symbol
    /// size): its logo sized like a symbol there, else `symbol(selected:)`.
    @MainActor
    func image(selected: Bool = false, configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        if let logo, let image = SymbolSizedLogo.image(
            named: logo,
            reference: "circle.fill",
            // A menu sizes an unconfigured symbol as body text at the small scale.
            configuration: configuration ?? UIImage.SymbolConfiguration(textStyle: .body, scale: .small),
            fallbackSide: 17
        ) {
            return image
        }
        return UIImage(systemName: symbol(selected: selected), withConfiguration: configuration)
    }

    /// The SF Symbol for the bar (unless `keyCap` is set), the menu, and the
    /// settings row, where the action has no `logo`. `selected` is the
    /// filled form an input button shows while typing goes there.
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
        case .rex: "rectangle.split.2x1"
        case .switcher: "rectangle.stack"
        }
    }

    /// Stable identifier on the bar button, whichever position holds it. Herdr
    /// and the switcher keep the ids they had before the bar was customizable.
    var accessibilityIdentifier: String {
        switch self {
        case .herdr: "sshTerminal.herdr"
        case .rex: "sshTerminal.rex"
        case .switcher: "sshTerminal.switcher"
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

