import Foundation

/// A button a customizable bar can show, or offer in its … menu when hidden.
/// `allCases` is the default order; `defaultShown` is what the bar draws before
/// anyone chooses.
protocol BarLayoutAction: RawRepresentable, CaseIterable, Hashable, Sendable where RawValue == String {
    static var defaultShown: Set<Self> { get }
}

/// Which buttons a customizable bar shows, and in what order (Chat's top bar,
/// the SSH terminal's bottom bar).
///
/// Every action is in `order`; the ones in `shown` are drawn in the bar in that
/// order, and the rest are offered in the … menu, also in that order. Showing
/// fewer than all of them, or none, is a valid choice: the … menu always stays.
/// The preference holds both lists, so a hidden action keeps its place for when
/// it comes back.
struct BarLayout<Action: BarLayoutAction>: Hashable, Sendable {
    /// Every action in the user's order.
    private(set) var order: [Action]
    /// The actions the bar draws. The rest are in the … menu.
    private(set) var shown: Set<Action>

    /// A saved layout is used exactly as saved; an action added after it was
    /// saved is appended to its order and, not being in its `shown`, offered
    /// in the menu.
    static var defaultValue: Self { Self(order: Array(Action.allCases), shown: Action.defaultShown) }

    /// The bar someone gets without choosing one.
    var isDefault: Bool { self == Self.defaultValue }

    /// A stored order missing an action, or naming one twice, still covers every
    /// action exactly once: the rest follow in `allCases` order.
    init(order: [Action], shown: Set<Action>) {
        var seen = Set<Action>()
        var normalized: [Action] = []
        for action in order where seen.insert(action).inserted {
            normalized.append(action)
        }
        for action in Action.allCases where seen.insert(action).inserted {
            normalized.append(action)
        }
        self.order = normalized
        self.shown = shown
    }

    /// The encoded form, so the preference holds raw values and an unknown one
    /// decodes as missing instead of failing.
    init(storedOrder: [String], storedShown: [String]) {
        self.init(
            order: storedOrder.compactMap(Action.init(rawValue:)),
            shown: Set(storedShown.compactMap(Action.init(rawValue:)))
        )
    }

    var storedOrder: [String] { order.map(\.rawValue) }
    var storedShown: [String] { order.filter(shown.contains).map(\.rawValue) }

    func isShown(_ action: Action) -> Bool { shown.contains(action) }

    /// Shows or hides one action. The order does not change, so a hidden action
    /// returns to the place it left.
    func setting(_ action: Action, shown isShown: Bool) -> Self {
        var next = shown
        if isShown { next.insert(action) } else { next.remove(action) }
        return Self(order: order, shown: next)
    }

    /// What the bar draws, in order: the shown actions this screen can offer.
    /// An action it cannot offer is not drawn and not offered in the menu
    /// either, because a button that could only fail is worse than no button.
    func bar(available: Set<Action>) -> [Action] {
        order.filter { shown.contains($0) && available.contains($0) }
    }

    /// What the … menu offers, in order: the actions the bar does not draw.
    func menu(available: Set<Action>) -> [Action] {
        order.filter { !shown.contains($0) && available.contains($0) }
    }
}

/// Where a bar layout is kept: two string arrays in UserDefaults, device-local.
/// Both keys missing (a fresh install, or one that never changed the setting)
/// is the default bar. Only `save` writes them, so a stored layout is always a
/// choice someone made; a hidden-everything choice stores an empty list.
struct BarLayoutPreference<Action: BarLayoutAction>: Sendable {
    let orderKey: String
    let shownKey: String
    let didChangeNotification: Notification.Name

    func layout(in defaults: UserDefaults) -> BarLayout<Action> {
        guard let order = defaults.stringArray(forKey: orderKey),
              let shown = defaults.stringArray(forKey: shownKey)
        else { return .defaultValue }
        return BarLayout(storedOrder: order, storedShown: shown)
    }

    func save(_ layout: BarLayout<Action>, in defaults: UserDefaults) {
        guard layout != self.layout(in: defaults) else { return }
        defaults.set(layout.storedOrder, forKey: orderKey)
        defaults.set(layout.storedShown, forKey: shownKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Forgets the saved layout, so the bar is back to the default.
    func reset(in defaults: UserDefaults) {
        guard defaults.stringArray(forKey: orderKey) != nil || defaults.stringArray(forKey: shownKey) != nil else {
            return
        }
        defaults.removeObject(forKey: orderKey)
        defaults.removeObject(forKey: shownKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
