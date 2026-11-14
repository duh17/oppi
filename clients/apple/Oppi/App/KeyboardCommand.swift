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
    /// View ▸ Panes: the focused pane's split, zoom, and the tree's sizes.
    case splitRight
    case splitDown
    case zoomPane
    /// Esc while a pane is zoomed: the capsule's Restore. Hidden from the
    /// menu, where Zoom Pane already reads Restore Panes.
    case restorePanes
    case equaliseSizes
    /// The pane beside the focused one, physically (arrows do not mirror).
    case focusPane(PaneDirection)
    /// The pane at this place in tree order, 1 to 8 (the leaf cap).
    case focusPaneNumber(Int)
    case movePane(PaneDirection)
    /// The divider on the focused pane's edge, 32 pt a press; held, it repeats.
    case moveDivider(PaneDirection)
    /// Undo the newest Close Pane, Move Pane or Reset Panes. No key: ⌘Z and
    /// the three-finger swipe stay with text undo (build plan §1.7).
    case undoPanes

    /// View ▸ Panes, in menu order and sections: split and size, focus by
    /// direction, focus by number, move, and the divider.
    static let paneSections: [[Self]] = [
        [.undoPanes],
        [.splitRight, .splitDown, .zoomPane, .restorePanes, .equaliseSizes],
        PaneDirection.allCases.map(Self.focusPane),
        (1...PaneLayout.maximumLeaves).map(Self.focusPaneNumber),
        PaneDirection.allCases.map(Self.movePane),
        PaneDirection.allCases.map(Self.moveDivider),
    ]

    /// Every command, in menu order.
    static let all: [Self] = [
        .newSession, .settings, .close, .toggleSidebar, .toggleFileTree,
        .pane(.files), .pane(.git), .pane(.outline), .pane(.context),
        .stop, .focusComposer, .nextSession, .previousSession,
    ] + paneSections.flatMap { $0 }

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
        case .splitRight: "splitRight"
        case .splitDown: "splitDown"
        case .zoomPane: "zoomPane"
        case .restorePanes: "restorePanes"
        case .equaliseSizes: "equaliseSizes"
        case .focusPane(let direction): "focusPane.\(direction)"
        case .focusPaneNumber(let number): "focusPane.\(number)"
        case .movePane(let direction): "movePane.\(direction)"
        case .moveDivider(let direction): "moveDivider.\(direction)"
        case .undoPanes: "undoPanes"
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
        case .splitRight: String(localized: "Split Right")
        case .splitDown: String(localized: "Split Down")
        case .zoomPane: String(localized: "Zoom Pane")
        case .restorePanes: String(localized: "Restore Panes")
        case .equaliseSizes: String(localized: "Equalise Sizes")
        case .focusPane(let direction): String(localized: "Focus Pane \(direction.title)")
        case .focusPaneNumber(let number): String(localized: "Focus Pane \(number)")
        case .movePane(let direction): String(localized: "Move Pane \(direction.title)")
        case .moveDivider(let direction): String(localized: "Move Divider \(direction.title)")
        case .undoPanes: String(localized: "Undo")
        }
    }

    /// The key and its modifiers, as `UIKeyCommand` takes them; nil for a
    /// menu item with no key.
    var key: (input: String, modifiers: UIKeyModifierFlags)? {
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
        case .splitRight: ("d", .command)
        case .splitDown: ("d", [.command, .shift])
        case .zoomPane: ("\r", [.command, .shift])
        case .restorePanes: (UIKeyCommand.inputEscape, [])
        case .equaliseSizes: ("=", [.control, .command])
        case .focusPane(let direction): (direction.arrowInput, [.alternate, .command])
        case .focusPaneNumber(let number): ("\(number)", [.control, .command])
        case .movePane(let direction): (direction.arrowInput, [.alternate, .shift, .command])
        case .moveDivider(let direction): (direction.arrowInput, [.control, .command])
        case .undoPanes: nil
        }
    }

    /// A key with no menu item of its own: it works, but the menu bar and the
    /// Command-hold overlay leave it out.
    var isHidden: Bool { self == .restorePanes }

    /// The menu item. All commands share one selector; `propertyList` says which.
    @MainActor
    func makeMenuCommand(action: Selector) -> UICommand {
        guard let key else { return UICommand(title: title, action: action, propertyList: id) }
        let command = UIKeyCommand(
            title: title,
            action: action,
            input: key.input,
            modifierFlags: key.modifiers,
            propertyList: id
        )
        if isHidden { command.attributes = .hidden }
        if PaneDirection.allCases.contains(where: { $0.arrowInput == key.input }) {
            // Pane arrows act physically, and win over text input and the
            // focus system, which would otherwise take arrows first.
            command.allowsAutomaticMirroring = false
            command.wantsPriorityOverSystemBehavior = true
        }
        return command
    }

    /// A command that is available now: the title for the state it would
    /// change, and the owner's action.
    struct Resolved {
        var title: String
        var run: @MainActor () -> Void
    }
}
