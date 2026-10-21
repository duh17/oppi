import Foundation

/// A button a chat can show in its top bar, or — when it is hidden — offer in
/// the … menu. The cases read in the default bar order.
enum ChatTopBarAction: String, CaseIterable, Identifiable, Hashable {
    case files
    case outline
    case context
    case terminal

    var id: String { rawValue }

    /// What the button and the settings row say. The terminal's label names the
    /// app; the ring's names the panel it opens.
    var label: String {
        switch self {
        case .files: String(localized: "Files")
        case .outline: String(localized: "Outline")
        case .context: String(localized: "Context")
        case .terminal: String(localized: "Terminal")
        }
    }

    /// The spoken purpose of the control, which differs from the label:
    /// "Files" is the panel it opens, and VoiceOver says what that does.
    var accessibilityLabel: String {
        switch self {
        case .files: String(localized: "Open chat files")
        case .outline: String(localized: "Open session outline")
        case .context: String(localized: "Open context inspector")
        case .terminal: String(localized: "Open terminal here")
        }
    }

    /// Stable identifier on the control, whichever position holds it. Files,
    /// Outline, Terminal, the … menu, and the context ring keep the ids they
    /// had before the bar became reorderable.
    var accessibilityIdentifier: String {
        switch self {
        case .files: "chat.toolbar.files"
        case .outline: "chat.toolbar.outline"
        case .context: "chat.toolbar.context"
        case .terminal: "chat.toolbar.terminal"
        }
    }

    /// Stable identifier on the … menu item for a hidden action.
    var menuIdentifier: String { "chat.toolbar.menu.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .files: "folder"
        case .outline: "list.bullet"
        case .context: "chart.pie"
        case .terminal: "terminal"
        }
    }

    /// The … menu title. Files names the state it would change; the rest name
    /// the panel they open.
    func menuTitle(filesOpen: Bool) -> String {
        switch self {
        case .files: filesOpen ? String(localized: "Close Files") : String(localized: "Open Files")
        case .outline, .context, .terminal: label
        }
    }
}

/// Which top bar buttons a chat shows, and in what order.
///
/// Every action is in `order`; the ones in `shown` are drawn in the bar in that
/// order, and the rest are offered in the … menu, also in that order. Showing
/// fewer than all of them, or none, is a valid choice: the … menu always stays.
/// The preference holds both lists, so a hidden action keeps its place for when
/// it comes back.
struct ChatTopBarLayout: Hashable {
    /// Every action in the user's order.
    private(set) var order: [ChatTopBarAction]
    /// The actions the bar draws. The rest are in the … menu.
    private(set) var shown: Set<ChatTopBarAction>

    /// Files, Outline, and Context: the bar people already had, with Terminal
    /// one … menu away because it needs the SSH Terminal experiment.
    static let defaultShown: Set<ChatTopBarAction> = [.files, .outline, .context]
    static let defaultValue = ChatTopBarLayout(order: ChatTopBarAction.allCases, shown: defaultShown)

    /// A stored order missing an action, or naming one twice, still covers every
    /// action exactly once: the rest follow in `ChatTopBarAction` order.
    init(order: [ChatTopBarAction], shown: Set<ChatTopBarAction>) {
        var seen = Set<ChatTopBarAction>()
        var normalized: [ChatTopBarAction] = []
        for action in order where seen.insert(action).inserted {
            normalized.append(action)
        }
        for action in ChatTopBarAction.allCases where seen.insert(action).inserted {
            normalized.append(action)
        }
        self.order = normalized
        self.shown = shown
    }

    /// The encoded form, so the preference holds raw values and an unknown one
    /// decodes as missing instead of failing.
    init(storedOrder: [String], storedShown: [String]) {
        self.init(
            order: storedOrder.compactMap(ChatTopBarAction.init(rawValue:)),
            shown: Set(storedShown.compactMap(ChatTopBarAction.init(rawValue:)))
        )
    }

    var storedOrder: [String] { order.map(\.rawValue) }
    var storedShown: [String] { order.filter(shown.contains).map(\.rawValue) }

    func isShown(_ action: ChatTopBarAction) -> Bool { shown.contains(action) }

    /// Shows or hides one action. The order does not change, so a hidden action
    /// returns to the place it left.
    func setting(_ action: ChatTopBarAction, shown isShown: Bool) -> ChatTopBarLayout {
        var next = shown
        if isShown { next.insert(action) } else { next.remove(action) }
        return ChatTopBarLayout(order: order, shown: next)
    }

    /// Applies a reordered run of actions, as a settings page that shows a
    /// subset of them hands it over. Actions the run does not name keep their
    /// positions, so a page that leaves Terminal out still reorders the rest.
    func reordering(_ reordered: [ChatTopBarAction]) -> ChatTopBarLayout {
        var next = reordered.makeIterator()
        let named = Set(reordered)
        return ChatTopBarLayout(
            order: order.map { named.contains($0) ? next.next() ?? $0 : $0 },
            shown: shown
        )
    }

    /// What the bar draws, in order: the shown actions this screen can offer.
    /// An action it cannot offer is not drawn and not offered in the menu
    /// either, because a button that could only fail is worse than no button.
    func bar(available: Set<ChatTopBarAction>) -> [ChatTopBarAction] {
        order.filter { shown.contains($0) && available.contains($0) }
    }

    /// What the … menu offers, in order: the actions the bar does not draw.
    func menu(available: Set<ChatTopBarAction>) -> [ChatTopBarAction] {
        order.filter { !shown.contains($0) && available.contains($0) }
    }
}
