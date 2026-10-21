import Foundation

/// A chat screen action that can sit in the top bar: one of the two quick
/// action slots, or (when it is not chosen) the … menu.
///
/// The order here is the order a slot is refilled from when the chosen action
/// is unavailable (Terminal while the SSH Terminal experiment is off), so it
/// is also the reading order of the … menu.
enum ChatTopBarAction: String, CaseIterable, Identifiable, Hashable {
    case files
    case terminal
    case outline

    var id: String { rawValue }

    /// What the button and menu say. The terminal's label names the app.
    var label: String {
        switch self {
        case .files: String(localized: "Files")
        case .terminal: String(localized: "Terminal")
        case .outline: String(localized: "Outline")
        }
    }

    /// The spoken purpose of the bar button, which differs from the menu label:
    /// "Files" is the panel it opens, and VoiceOver says what that does.
    var accessibilityLabel: String {
        switch self {
        case .files: String(localized: "Open chat files")
        case .terminal: String(localized: "Open terminal here")
        case .outline: String(localized: "Open session outline")
        }
    }

    /// Stable identifier on the bar button, whichever slot holds it. Existing
    /// ids stay: `chat.toolbar.files` and `chat.toolbar.outline`.
    var accessibilityIdentifier: String {
        switch self {
        case .files: "chat.toolbar.files"
        case .terminal: "chat.toolbar.terminal"
        case .outline: "chat.toolbar.outline"
        }
    }

    var symbolName: String {
        switch self {
        case .files: "folder"
        case .terminal: "terminal"
        case .outline: "list.bullet"
        }
    }

    /// Filled symbol while the action's panel is open. Terminal has no panel.
    var openSymbolName: String? {
        switch self {
        case .files: "folder.fill"
        case .terminal: nil
        case .outline: "list.bullet"
        }
    }

    /// The … menu title for an action that did not get a slot.
    var menuTitle: String { label }

    /// Terminal can be chosen only while the SSH Terminal experiment is on.
    var isAvailable: Bool {
        switch self {
        case .terminal: AppPreferences.Experiments.sshTerminalEnabled
        case .files, .outline: true
        }
    }
}

/// The two chosen slot actions and the ones left in the … menu.
///
/// The stored choice is exactly two actions in slot order. A stored action that
/// is unavailable (Terminal with the experiment off) is skipped, and the slots
/// refill in `ChatTopBarAction` order from the actions that remain, so a bar
/// keeps two quick actions and the missing one reappears when it returns.
struct ChatTopBarSelection: Equatable {
    /// Stored slot order. Always two entries; see `normalized`.
    private(set) var actions: [ChatTopBarAction]

    /// Files and Outline: the bar people who never open the setting already have.
    private static let defaultActions: [ChatTopBarAction] = [.files, .outline]
    static let defaultValue = ChatTopBarSelection(stored: defaultActions)

    init(actions: [ChatTopBarAction]) {
        self.actions = Self.normalized(actions)
    }

    private init(stored: [ChatTopBarAction]) {
        actions = stored
    }

    /// Encoded form, so the preference holds raw values and an unknown one
    /// decodes as the default instead of failing.
    init(rawValues: [String]) {
        self.init(actions: rawValues.compactMap(ChatTopBarAction.init(rawValue:)))
    }

    var rawValues: [String] { actions.map(\.rawValue) }

    /// Two distinct known actions, or the default pair when the input cannot
    /// supply two (a missing, duplicated, or unrecognized store).
    static func normalized(_ actions: [ChatTopBarAction]) -> [ChatTopBarAction] {
        var seen = Set<ChatTopBarAction>()
        var result: [ChatTopBarAction] = []
        for action in actions where seen.insert(action).inserted {
            result.append(action)
            if result.count == 2 { return result }
        }
        return defaultActions
    }

    /// The two bar slots, in stored order, with actions the screen cannot
    /// offer right now replaced by the next available one.
    ///
    /// `available` is what this screen can show; the chat passes its own set
    /// (Files and Terminal need a workspace, Outline needs a timeline).
    func slots(available: Set<ChatTopBarAction>) -> [ChatTopBarAction] {
        var slots = actions.filter { available.contains($0) }
        for action in ChatTopBarAction.allCases where available.contains(action) && !slots.contains(action) {
            if slots.count == 2 { break }
            slots.append(action)
        }
        return Array(slots.prefix(2))
    }

    /// What the bar keeps in the … menu: every available action without a slot,
    /// in reading order.
    func overflow(available: Set<ChatTopBarAction>) -> [ChatTopBarAction] {
        let slots = slots(available: available)
        return ChatTopBarAction.allCases.filter { available.contains($0) && !slots.contains($0) }
    }

    /// Choosing `action` for `slot`. Choosing the action already in the other
    /// slot swaps the two, so both slots always hold a different action.
    func choosing(_ action: ChatTopBarAction, forSlot slot: Int) -> ChatTopBarSelection {
        guard actions.indices.contains(slot), actions[slot] != action else { return self }
        var next = actions
        if let other = next.firstIndex(of: action) { next[other] = next[slot] }
        next[slot] = action
        return ChatTopBarSelection(actions: next)
    }
}
