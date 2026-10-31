import Foundation

/// One place in the Bottom Bar list: a built-in button, the detected
/// program's shortcuts as a group, or a key the person made. The list is one
/// `BarLayout` of these, so the bar and the settings page share its order,
/// shown set, and menu rules with Chat's top bar.
///
/// The raw value is what the layout stores. A built-in button keeps its own
/// raw value, so a layout saved when the bar had a middle and a right side
/// reads as it was saved (`BarLayout.migrating(legacyOrder:legacyShown:)`).
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
    static var allCases: [SSHTerminalBarItem] {
        var items = SSHTerminalBarAction.allCases.map(SSHTerminalBarItem.action)
        items.insert(.programShortcuts, at: items.firstIndex(of: .action(.paste)) ?? items.endIndex)
        return items
    }

    /// Today's bar plus the two input buttons: Type in Terminal and Chat Bar,
    /// then Herdr, Rex, and the switcher (each only where the screen can offer
    /// it). Keys, Paste, Browse Files Here, and Program Shortcuts start off.
    static let defaultShown: Set<SSHTerminalBarItem> = [
        .action(.keyboard), .action(.chatBar), .action(.herdr), .action(.rex), .action(.switcher),
    ]

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

extension BarLayout where Action == SSHTerminalBarItem {
    /// The layout this bar had when it was a middle pill and a trailing pill.
    /// Its one stored order held both, with Herdr, Rex, and the switcher
    /// kept to their own side; the new bar draws one pill, and the buttons
    /// that were beside … come after the middle's, which is where they were
    /// on screen. The shown set is kept as it was.
    static func migrating(legacyOrder: [String], legacyShown: [String]) -> Self {
        let trailing: Set<String> = [
            SSHTerminalBarAction.herdr.rawValue, SSHTerminalBarAction.rex.rawValue, SSHTerminalBarAction.switcher.rawValue,
        ]
        return Self(
            storedOrder: legacyOrder.filter { !trailing.contains($0) } + legacyOrder.filter(trailing.contains),
            storedShown: legacyShown
        )
    }
}

/// Which multiplexer a terminal belongs to, and so which of the two overview
/// buttons it can offer: a terminal in Rex is only Rex's, one in Herdr only
/// Herdr's, and a plain shell, where each is a launcher, keeps both. The one
/// owner of that rule: the bar, the … menu, and Customize Bar opened from the
/// terminal all hide `hidden` and nothing else, so the saved layout is never
/// edited to say it and a plain shell shows the user's choice again.
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

    /// The actions this terminal's multiplexer rules out.
    var hidden: Set<SSHTerminalBarAction> {
        switch self {
        case .plain: []
        case .rex: [.herdr]
        case .herdr: [.rex]
        }
    }

    /// Whether the terminal reads this multiplexer's overview in the
    /// background. Hiding a button is presentation only, and Rex's read is also
    /// how Oppi learns Rex is on the host (`SSHTerminalRexHostStore`, which the
    /// Terminal tab follows), so a Herdr terminal still reads Rex though it
    /// shows no Rex button. Herdr's read feeds nothing else, so a Rex pane does
    /// not poll the host's Herdr.
    func polls(_ action: SSHTerminalBarAction) -> Bool {
        !hidden.contains(action) || action == .rex
    }
}

/// One button the bar can draw or the … menu can offer: a list item, or one
/// of the several buttons an item stands for (each of the program's shortcuts).
struct SSHTerminalBarSlot: Equatable, Identifiable {
    enum Content: Equatable {
        case action(SSHTerminalBarAction)
        case customKey(SSHTerminalCustomKey)
        case shortcut(SSHTerminalKeyAction)
    }

    let content: Content

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
        switch content {
        case .action(let action): action.menuTitle
        case .customKey(let key): key.displayName
        case .shortcut(let shortcut): shortcut.title
        }
    }

    var accessibilityLabel: String {
        switch content {
        case .action(let action): action.accessibilityLabel
        case .customKey(let key): key.displayName
        case .shortcut(let shortcut): shortcut.title
        }
    }

    /// The key's own name, spoken after the label where the label is the job.
    var accessibilityValue: String? {
        switch content {
        case .action: nil
        case .customKey(let key): key.chord
        case .shortcut(let shortcut): shortcut.keyLabel
        }
    }

    var accessibilityIdentifier: String {
        switch content {
        case .action(let action): action.accessibilityIdentifier
        case .customKey(let key): "sshTerminal.bar.custom.\(key.id.uuidString)"
        case .shortcut(let shortcut): "sshTerminal.bar.shortcut.\(shortcut.id.replacingOccurrences(of: ":", with: "."))"
        }
    }

    var menuIdentifier: String {
        switch content {
        case .action(let action): action.menuIdentifier
        case .customKey(let key): "sshTerminal.menu.custom.\(key.id.uuidString)"
        case .shortcut(let shortcut): "sshTerminal.menu.shortcut.\(shortcut.id.replacingOccurrences(of: ":", with: "."))"
        }
    }

    /// The text the bar draws as a key cap instead of a symbol.
    var keyCap: String? {
        switch content {
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
struct SSHTerminalBarPlacement: Equatable {
    var slots: [SSHTerminalBarSlot]
    var menu: [SSHTerminalBarSlot]
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

    /// `overviews` are the multiplexers whose overview can open here. `program`
    /// is `SSHTerminalAgentDetection.keymapProgram`: the OSC 7501 root agent,
    /// else `shell`. `shortcuts` is what `SSHTerminalKeymap.actions(for:userFile:)`
    /// reports for it.
    init(
        context: SSHTerminalBarContext,
        overviews: Set<SSHTerminalBarAction>,
        openTerminals: Int,
        canBrowseFiles: Bool,
        program: String,
        customKeys: [SSHTerminalCustomKey],
        shortcuts: [SSHTerminalKeyAction]
    ) {
        var actions = Set(SSHTerminalBarAction.allCases).subtracting(context.hidden)
        for action in SSHTerminalBarAction.overviews where !overviews.contains(action) {
            actions.remove(action)
        }
        if openTerminals < 2 { actions.remove(.switcher) }
        if !canBrowseFiles { actions.remove(.browseFiles) }
        self.actions = actions
        self.customKeys = Dictionary(
            customKeys.filter { $0.showFor.matches(program: program) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.shortcuts = shortcuts
    }

    /// The list items this terminal can offer: what `BarLayout` filters by.
    var items: Set<SSHTerminalBarItem> {
        var items = Set(actions.map(SSHTerminalBarItem.action))
        items.formUnion(customKeys.keys.map(SSHTerminalBarItem.customKey))
        if !shortcuts.isEmpty { items.insert(.programShortcuts) }
        return items
    }

    func slots(for item: SSHTerminalBarItem) -> [SSHTerminalBarSlot] {
        switch item {
        case .action(let action): actions.contains(action) ? [.init(content: .action(action))] : []
        case .programShortcuts: shortcuts.map { .init(content: .shortcut($0)) }
        case .customKey(let id): customKeys[id].map { [.init(content: .customKey($0))] } ?? []
        }
    }

    /// The buttons the shown items stand for that fit (`capacity`, in order),
    /// and the … menu's: everything that overflowed, and every turned-off
    /// button that has no other home. A button the terminal cannot offer is
    /// in neither.
    func placement(layout: SSHTerminalBarLayout, capacity: Int) -> SSHTerminalBarPlacement {
        let items = items
        let drawn = layout.bar(available: items).flatMap(slots(for:))
        let fits = Array(drawn.prefix(max(0, capacity)))
        let overflow = Set(drawn.dropFirst(fits.count).map(\.id))
        let turnedOff = Set(layout.menu(available: items))
        let menu = layout.order.flatMap(slots(for:)).filter { slot in
            if overflow.contains(slot.id) { return slot.menuWhenCrowdedOut }
            return turnedOff.contains(slot.item) && slot.menuWhenTurnedOff
        }
        return SSHTerminalBarPlacement(slots: fits, menu: menu)
    }
}
