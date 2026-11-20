import Foundation

/// One place in the Bottom Bar list: a built-in button, the detected
/// program's shortcuts as a group, or a key the person made. The list is one
/// `BarLayout` of these, so the bar and the settings page share its order,
/// shown set, and menu rules with Chat's top bar.
///
/// The raw value is what the layout stores; a built-in button's is its
/// action's.
enum SSHTerminalBarItem: BarLayoutAction, Identifiable {
    case action(SSHTerminalBarAction)
    /// The detected program's shortcuts (`SSHTerminalKeymap.actions(for:userFile:)`),
    /// one key cap each, in the program's own order.
    case programShortcuts
    case customKey(UUID)

    private static let programShortcutsRawValue = "programShortcuts"
    private static let customKeyPrefix = "key."

    /// The default order: the built-in buttons as they were, Program Shortcuts
    /// after the keys and before Paste. Custom keys are not cases; a layout
    /// appends each as it is made.
    static var allCases: [Self] {
        var items = SSHTerminalBarAction.allCases.map(Self.action)
        items.insert(.programShortcuts, at: items.firstIndex(of: .action(.paste)) ?? items.endIndex)
        return items
    }

    /// Type in Terminal, Dictate, and Attach, then Herdr and the switcher
    /// (each only where the screen can offer it). Keys, Paste, Browse Files
    /// Here, and Program Shortcuts start off.
    static let defaultShown: Set<SSHTerminalBarItem> = [
        .action(.keyboard), .action(.dictate), .action(.attach), .action(.herdr), .action(.switcher),
    ]

    /// A built-in button a later version adds waits at the end, hidden. A new
    /// custom key is not this: the store appends it shown (`SSHTerminalBarStore.layout`).
    static let unseen = BarLayoutUnseenRule.appendHidden

    var id: String { rawValue }

    /// The settings row's title and the Bottom Bar summary's word for it.
    func title(customKeys: [SSHTerminalCustomKey]) -> String {
        switch self {
        case .action(let action): action.label
        case .programShortcuts: String(localized: "Program Shortcuts")
        case .customKey(let id): customKeys.first { $0.id == id }?.displayName ?? ""
        }
    }

    var rawValue: String {
        switch self {
        case .action(let action): action.rawValue
        case .programShortcuts: Self.programShortcutsRawValue
        case .customKey(let id): Self.customKeyPrefix + id.uuidString
        }
    }

    init?(rawValue: String) {
        if rawValue == Self.programShortcutsRawValue {
            self = .programShortcuts
        } else if rawValue.hasPrefix(Self.customKeyPrefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(Self.customKeyPrefix.count))) {
            self = .customKey(id)
        } else if let action = SSHTerminalBarAction(rawValue: rawValue) {
            self = .action(action)
        } else {
            return nil
        }
    }
}

typealias SSHTerminalBarLayout = BarLayout<SSHTerminalBarItem>

/// Which multiplexer a terminal belongs to, and so whether it offers Herdr's
/// overview button: a terminal in Rex does not, a plain shell and a Herdr
/// terminal do, while Herdr's experiment is on. The one owner of that rule:
/// the bar, the … menu, the terminal's Herdr read, Customize Bar, and the
/// Settings summary (as `.plain`) all hide `hidden` and nothing else, so the
/// saved layout is never edited to say it and a plain shell shows the user's
/// choice again.
enum SSHTerminalBarContext: Equatable, Sendable {
    case plain
    /// A pane of a Rex session (`SSHTerminalChannel.rex`).
    case rex
    /// A terminal whose own program is Herdr: the host's Run on Connect command
    /// starts it (`SSHTerminalChannel.command`), so it ends with Herdr. A
    /// `herdr` typed into a shell is not this, and nothing in the terminal's
    /// bytes says so reliably.
    case herdr

    init(isRexPane: Bool, command: String?) {
        if isRexPane {
            self = .rex
        } else if SSHTerminalMultiplexerKind.detected(in: command) == .herdr {
            self = .herdr
        } else {
            self = .plain
        }
    }

    /// The actions this terminal leaves out everywhere: Herdr in a Rex pane; the
    /// saved layout keeps its place. A hidden overview is not read either
    /// (`SSHTerminalViewController.overview`). Rex is not a bar overview: the
    /// terminal reads it on its own (`SSHTerminalViewController.updatePolling`).
    var hidden: Set<SSHTerminalBarAction> { self == .rex ? [.herdr] : [] }

    /// Whether the program-status symbol has a place in the bar's pill. A Rex
    /// pane draws the status on the pane switcher's icon instead.
    var showsProgramStatus: Bool { self != .rex }
}

/// One button the bar can draw or the … menu can offer: a list item, or one
/// of the several buttons an item stands for (each of the program's shortcuts).
struct SSHTerminalBarSlot: BarSlot, Equatable, Identifiable {
    enum Content: Equatable {
        case action(SSHTerminalBarAction)
        case customKey(SSHTerminalCustomKey)
        case shortcut(SSHTerminalKeyAction)
    }

    let content: Content
    /// Send or Stop while a coding agent is in front (`SSHTerminalAgentKeys`):
    /// the look, label, and identifier change, the keys sent do not. The
    /// slot keeps its `id`, so the bar restyles its button in place.
    var agentRole: SSHTerminalAgentKeyRole? = nil

    var id: String {
        switch content {
        case .action(let action): "action.\(action.rawValue)"
        case .customKey(let key): "key.\(key.id.uuidString)"
        case .shortcut(let shortcut): "shortcut.\(shortcut.id)"
        }
    }

    /// The list item this slot belongs to.
    var item: SSHTerminalBarItem {
        switch content {
        case .action(let action): .action(action)
        case .customKey(let key): .customKey(key.id)
        case .shortcut: .programShortcuts
        }
    }

    /// Sends keys to the program, so it dims while there is no connection.
    var sendsKeys: Bool {
        switch content {
        case .action(let action): action.isKey
        case .customKey, .shortcut: true
        }
    }

    /// Whether turning the button off moves it into the … menu. The keyboard
    /// bars have every built-in key and the program's shortcuts, and Paste
    /// cannot read the clipboard from a menu item without iOS's Allow Paste
    /// alert (holding the grid offers it); a custom key has no other home.
    var menuWhenTurnedOff: Bool {
        switch content {
        case .action(let action): !action.isKey && action != .paste
        case .customKey: true
        case .shortcut: false
        }
    }

    /// Paste is never in the menu, even when the bar has no room.
    var menuWhenCrowdedOut: Bool {
        if case .action(.paste) = content { return false }
        return true
    }

    /// What VoiceOver says for the bar button, and the menu item's title.
    var title: String {
        switch agentRole {
        case .send: return String(localized: "Send")
        case .stop: return String(localized: "Stop")
        case nil: break
        }
        return switch content {
        case .action(let action): action.menuTitle
        case .customKey(let key): key.displayName
        case .shortcut(let shortcut): shortcut.title
        }
    }

    /// Send and Stop speak as the chat composer's do.
    var accessibilityLabel: String {
        switch agentRole {
        case .send: return String(localized: "Send")
        case .stop: return String(localized: "Stop response")
        case nil: break
        }
        return switch content {
        case .action(let action): action.accessibilityLabel
        case .customKey(let key): key.displayName
        case .shortcut(let shortcut): shortcut.title
        }
    }

    /// The key's own name, spoken after the label where the label is the job.
    var accessibilityValue: String? {
        switch content {
        case .action(let action): agentRole == nil ? nil : action.keyCap ?? action.label
        case .customKey(let key): key.chord
        case .shortcut(let shortcut): shortcut.keyLabel
        }
    }

    /// The key's own identifier; as Send or Stop it ends in `.send` or
    /// `.stop`, the way the chat composer's are `chat.send` and `chat.stop`.
    var accessibilityIdentifier: String {
        let key = switch content {
        case .action(let action): action.accessibilityIdentifier
        case .customKey(let key): "sshTerminal.bar.custom.\(key.id.uuidString)"
        case .shortcut(let shortcut): "sshTerminal.bar.shortcut.\(shortcut.id.replacingOccurrences(of: ":", with: "."))"
        }
        return switch agentRole {
        case .send: key + ".send"
        case .stop: key + ".stop"
        case nil: key
        }
    }

    var menuIdentifier: String {
        switch content {
        case .action(let action): action.menuIdentifier
        case .customKey(let key): "sshTerminal.menu.custom.\(key.id.uuidString)"
        case .shortcut(let shortcut): "sshTerminal.menu.shortcut.\(shortcut.id.replacingOccurrences(of: ":", with: "."))"
        }
    }

    /// The text the bar draws as a key cap instead of a symbol. Send and Stop
    /// draw the composer's symbol instead.
    var keyCap: String? {
        guard agentRole == nil else { return nil }
        return switch content {
        case .action(let action): action.keyCap
        case .customKey(let key): key.cap
        case .shortcut(let shortcut): shortcut.keyLabel
        }
    }

    var strokes: [SSHTerminalKeyStroke] {
        switch content {
        case .action(let action): action.strokes
        case .customKey(let key): key.strokes
        case .shortcut(let shortcut): shortcut.strokes
        }
    }
}

/// What the bottom bar draws, in one pill, and what the … menu offers.
typealias SSHTerminalBarPlacement = BarPlacement<SSHTerminalBarSlot>

/// Where the bar's buttons are drawn: the floating pill over the grid, or the
/// terminal keyboard's accessory while a docked keyboard is up
/// (`SSHTerminalKeyboardBar.carriesBar`). One layout, one order, one shown
/// set; only what the surface already has is left out.
enum SSHTerminalBarSurface: Equatable {
    case bottomBar
    case keyboardBar

    /// What the keyboard bar's fixed keys (Esc, Tab, ↑, ↓, Paste, the
    /// program's keys, ⌄) and the keyboard itself (Return) already have.
    /// They are neither drawn nor offered in its … menu.
    static let repeatedOnKeyboard: Set<SSHTerminalBarItem> = [
        .action(.keyboard), .action(.escape), .action(.tab), .action(.up), .action(.down), .action(.enter),
        .action(.paste), .programShortcuts,
    ]
}

/// What the bar offers this terminal now, and the one place that decides it:
/// the built-in buttons this screen can use (its multiplexer, the hosts it
/// reaches, how many terminals are open), the custom keys that show for the
/// program in front, and that program's shortcuts. `placement` then lays the
/// user's list over it. The bar, the … menu, and VoiceOver all read the same
/// answer, so a button that could only fail is neither drawn nor offered.
struct SSHTerminalBarOffer: Equatable {
    private(set) var actions: Set<SSHTerminalBarAction>
    private(set) var customKeys: [UUID: SSHTerminalCustomKey]
    private(set) var shortcuts: [SSHTerminalKeyAction]
    private(set) var agentKeys: SSHTerminalAgentKeys

    /// `herdrAvailable`: Herdr's overview can open here. `program`
    /// is `SSHTerminalAgentDetection.keymapProgram`: the OSC 7501 root agent,
    /// else `shell`. `shortcuts` is what `SSHTerminalKeymap.actions(for:userFile:)`
    /// reports for it. `canDictate` is a paired server and a free microphone
    /// (no Live Voice call); `canAttach` is a host that takes uploads.
    /// `agentKeys` turns the keys placed on the bar into Send and Stop.
    init(
        context: SSHTerminalBarContext,
        herdrAvailable: Bool,
        openTerminals: Int,
        canBrowseFiles: Bool,
        canDictate: Bool,
        canAttach: Bool,
        program: String,
        customKeys: [SSHTerminalCustomKey],
        shortcuts: [SSHTerminalKeyAction],
        agentKeys: SSHTerminalAgentKeys = .none
    ) {
        var actions = Set(SSHTerminalBarAction.allCases).subtracting(context.hidden)
        if !herdrAvailable { actions.remove(.herdr) }
        if openTerminals < 2 { actions.remove(.switcher) }
        if !canBrowseFiles { actions.remove(.browseFiles) }
        if !canDictate { actions.remove(.dictate) }
        if !canAttach { actions.remove(.attach) }
        self.actions = actions
        self.customKeys = Dictionary(
            customKeys.filter { $0.showFor.matches(program: program) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.shortcuts = shortcuts
        self.agentKeys = agentKeys
    }

    /// Whether Dictate is offered: a paired server and a free microphone
    /// (`available`), and not while a password prompt has secure entry on, so
    /// dictation never hears a password. A take already running keeps its
    /// button, so it can always be stopped.
    static func canDictate(available: Bool, secureInput: Bool, dictating: Bool) -> Bool {
        dictating || (available && !secureInput)
    }

    /// The list items this terminal can offer: what `BarLayout` filters by.
    var items: Set<SSHTerminalBarItem> {
        var items = Set(actions.map(SSHTerminalBarItem.action))
        items.formUnion(customKeys.keys.map(SSHTerminalBarItem.customKey))
        if !shortcuts.isEmpty { items.insert(.programShortcuts) }
        return items
    }

    func slots(for item: SSHTerminalBarItem) -> [SSHTerminalBarSlot] {
        let contents: [SSHTerminalBarSlot.Content] = switch item {
        case .action(let action): actions.contains(action) ? [.action(action)] : []
        case .programShortcuts: shortcuts.map { .shortcut($0) }
        case .customKey(let id): customKeys[id].map { [.customKey($0)] } ?? []
        }
        return contents.map { content in
            var slot = SSHTerminalBarSlot(content: content)
            if slot.sendsKeys { slot.agentRole = agentKeys.role(for: slot.strokes) }
            return slot
        }
    }

    /// The buttons the shown items stand for that fit (`capacity`, in order),
    /// and the … menu's: everything that overflowed, and every turned-off
    /// button that has no other home (`BarLayout.placement`). A button the
    /// terminal cannot offer is in neither.
    ///
    /// The keyboard bar leaves out what the keyboard already has
    /// (`SSHTerminalBarSurface.repeatedOnKeyboard`). A running take
    /// (`dictating`) is drawn first, even with no room for anything, so the
    /// take always has a visible stop; the rest keep their order after it.
    func placement(
        layout: SSHTerminalBarLayout,
        capacity: Int,
        surface: SSHTerminalBarSurface = .bottomBar,
        dictating: Bool = false
    ) -> SSHTerminalBarPlacement {
        var available = items
        if surface == .keyboardBar { available.subtract(SSHTerminalBarSurface.repeatedOnKeyboard) }
        let dictate = SSHTerminalBarItem.action(.dictate)
        guard dictating, available.contains(dictate) else {
            return layout.placement(available: available, capacity: capacity, slots: slots(for:))
        }
        let pinned = SSHTerminalBarLayout(order: [dictate] + layout.order, shown: layout.shown.union([dictate]))
        return pinned.placement(available: available, capacity: max(capacity, 1), slots: slots(for:))
    }
}
