import UIKit

/// A button a chat can show in its top bar, or — when it is hidden — offer in
/// the … menu. The cases read in the default bar order.
enum ChatTopBarAction: String, CaseIterable, Identifiable, Hashable {
    case files
    case git
    case outline
    case context
    case terminal

    var id: String { rawValue }

    /// What the button and the settings row say. The terminal's label names the
    /// app; the ring's names the panel it opens.
    var label: String {
        switch self {
        case .files: String(localized: "Files")
        case .git: String(localized: "Git")
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
        case .git: String(localized: "Open Git")
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
        case .git: "chat.toolbar.git"
        case .outline: "chat.toolbar.outline"
        case .context: "chat.toolbar.context"
        case .terminal: "chat.toolbar.terminal"
        }
    }

    /// Stable identifier on the … menu item for a hidden action.
    var menuIdentifier: String { "chat.toolbar.menu.\(rawValue)" }

    /// The action's image for text at `textStyle`: the one owner for the bar
    /// button (`.subheadline`), the rail item and the Settings → Top Bar row
    /// (`.body`), and the … menu item (nil, below). `isActive` is the open state a
    /// control shows (Files draws filled while its panel is open). Git is the
    /// Git logo, not `arrow.triangle.branch`, which means a worktree elsewhere
    /// in the app; the rest are SF Symbols. Every image is a template, so it
    /// takes its control's tint.
    ///
    /// A nil `textStyle` is the overflow menu: an unconfigured symbol, which the
    /// menu sizes itself, and the logo at the size the menu draws its symbols.
    @MainActor
    func image(textStyle: UIFont.TextStyle?, isActive: Bool = false) -> UIImage? {
        let symbol: String
        switch self {
        case .files: symbol = isActive ? "folder.fill" : "folder"
        case .git: return GitLogoImage.image(textStyle: textStyle)
        case .outline: symbol = "list.bullet"
        case .context: symbol = "chart.pie"
        case .terminal: symbol = "terminal"
        }
        guard let textStyle else { return UIImage(systemName: symbol) }
        return UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: textStyle))
    }

    /// The … menu title. Files names the state it would change; the rest name
    /// the panel they open.
    func menuTitle(filesOpen: Bool) -> String {
        switch self {
        case .files: filesOpen ? String(localized: "Close Files") : String(localized: "Open Files")
        case .git, .outline, .context, .terminal: label
        }
    }
}

/// The Git logo (`git-logo` asset; credit in `Resources/GitLogo-LICENSE.txt`)
/// sized to sit beside SF Symbols at a text style. The mark is a solid diamond,
/// so it takes the size SF Symbols gives its own solid diamond (`diamond.fill`)
/// at that style: the size the symbol set balances against the folder, list,
/// and pie beside it (about 20 pt for `.subheadline`). Sized from the font's
/// point size instead, it read as a small blot next to them. A vector asset
/// does not take a symbol configuration, so each size is rendered once, as a
/// template.
///
/// A menu draws a plain image at its own size but resizes its symbols; an
/// unconfigured symbol there measures as body text at the small symbol scale
/// (folder 19 pt and list 17 pt wide on iPhone), so the menu's logo is
/// `diamond.fill` at that configuration. What's New draws it at `.title3`.
@MainActor
enum GitLogoImage {
    private static var cache: [CGFloat: UIImage] = [:]

    static func image(textStyle: UIFont.TextStyle?) -> UIImage? {
        let configuration = textStyle.map { UIImage.SymbolConfiguration(textStyle: $0) }
            ?? UIImage.SymbolConfiguration(textStyle: .body, scale: .small)
        let reference = UIImage(systemName: "diamond.fill", withConfiguration: configuration)
        let fallback = UIFont.preferredFont(forTextStyle: textStyle ?? .body).pointSize
        let side = (reference?.size.width ?? fallback).rounded()
        if let cached = cache[side] { return cached }
        guard let logo = UIImage(named: "git-logo") else { return nil }
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            logo.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysTemplate)
        cache[side] = image
        return image
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

    /// The bar without a saved choice: Context (the ring) alone, with Files,
    /// Git, Outline, and Terminal in the menu (Terminal where the workspace has
    /// a folder a shell can start in). The order is still every action, so a
    /// button someone pins lands in a sensible place. A saved layout is used
    /// exactly as saved; an action added after it was saved (Git) is appended
    /// to its order and, not being in its `shown`, offered in the menu.
    static let defaultShown: Set<ChatTopBarAction> = [.context]
    static let defaultValue = ChatTopBarLayout(order: ChatTopBarAction.allCases, shown: defaultShown)

    /// The bar someone gets without choosing one, so the one-time "Chat tools
    /// are in the menu" hint is for them and not for a bar they built.
    var isDefault: Bool { self == Self.defaultValue }

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
