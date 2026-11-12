import UIKit

/// The app's hardware-keyboard commands. One owner for the key, the menu title
/// and the action: the main menu (`AppDelegate.buildMenu`) shows them in the
/// iPadOS menu bar and the Command-hold overlay, and every one runs the owner
/// action its touch control runs (`LiveKeyboardCommandSurface`), never a copy of it.
///
/// Find is not here: the system's Edit > Find sends `find(_:)` down the
/// responder chain, and the app delegate answers it for a visible search bar.
/// The composer's Cmd-Return and Option-Return, Esc in Quick Session, the
/// timeline chords (`KeybindingCatalog`), the terminal and the editor keep
/// their own key commands.
enum KeyboardCommand: Hashable, Sendable {
    case newSession
    case settings
    case close
    case toggleSidebar
    /// The File Browser's folder tree beside the open file (regular width).
    case toggleFileTree
    /// Files, Git, Outline or Context: the chat's top-bar action of that name.
    case pane(ChatTopBarAction)
    case stop
    case focusComposer
    case nextSession
    case previousSession

    /// Every command, in menu order.
    static let all: [Self] = [
        .newSession, .settings, .close, .toggleSidebar, .toggleFileTree,
        .pane(.files), .pane(.git), .pane(.outline), .pane(.context),
        .stop, .focusComposer, .nextSession, .previousSession,
    ]

    /// The chat panes the Option-Command digits open, in digit order.
    static let panes: [ChatTopBarAction] = [.files, .git, .outline, .context]

    /// Stable key for the menu item's property list and for tests.
    var id: String {
        switch self {
        case .newSession: "newSession"
        case .settings: "settings"
        case .close: "close"
        case .toggleSidebar: "toggleSidebar"
        case .toggleFileTree: "toggleFileTree"
        case .pane(let action): "pane.\(action.rawValue)"
        case .stop: "stop"
        case .focusComposer: "focusComposer"
        case .nextSession: "nextSession"
        case .previousSession: "previousSession"
        }
    }

    init?(id: String) {
        guard let command = Self.all.first(where: { $0.id == id }) else { return nil }
        self = command
    }

    /// The title the menu is built with. A toggle's title follows its state
    /// (`Resolved.title`), as Apple's Show/Hide Sidebar and Show/Hide Toolbar do.
    var title: String {
        switch self {
        case .newSession: String(localized: "New Session")
        case .settings: String(localized: "Settings\u{2026}")
        case .close: String(localized: "Close")
        case .toggleSidebar: String(localized: "Show Sidebar")
        case .toggleFileTree: String(localized: "Show File Tree")
        case .pane(let action): String(localized: "Show \(action.label)")
        case .stop: String(localized: "Stop Response")
        case .focusComposer: String(localized: "Focus Composer")
        case .nextSession: String(localized: "Next Session")
        case .previousSession: String(localized: "Previous Session")
        }
    }

    /// The key and its modifiers, as `UIKeyCommand` takes them.
    var key: (input: String, modifiers: UIKeyModifierFlags) {
        switch self {
        case .newSession: ("n", .command)
        case .settings: (",", .command)
        case .close: ("w", .command)
        case .toggleSidebar: ("s", [.control, .command])
        case .toggleFileTree: ("l", [.command, .shift])
        case .pane(let action):
            ("\((Self.panes.firstIndex(of: action) ?? 0) + 1)", [.alternate, .command])
        case .stop: (".", .command)
        case .focusComposer: ("l", .command)
        case .nextSession: ("]", [.command, .shift])
        case .previousSession: ("[", [.command, .shift])
        }
    }

    /// The menu item. All commands share one selector; `propertyList` says which.
    @MainActor
    func makeKeyCommand(action: Selector) -> UIKeyCommand {
        UIKeyCommand(
            title: title,
            action: action,
            input: key.input,
            modifierFlags: key.modifiers,
            propertyList: id
        )
    }

    /// A command that is available now: the title for the state it would
    /// change, and the owner's action.
    struct Resolved {
        var title: String
        var run: @MainActor () -> Void
    }
}
