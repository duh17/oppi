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
/// point size instead, it read as a small blot next to them
/// (`SymbolSizedLogo`).
///
/// A menu draws a plain image at its own size but resizes its symbols; an
/// unconfigured symbol there measures as body text at the small symbol scale
/// (folder 19 pt and list 17 pt wide on iPhone), so the menu's logo is
/// `diamond.fill` at that configuration. What's New draws it at `.title3`.
@MainActor
enum GitLogoImage {
    static func image(textStyle: UIFont.TextStyle?) -> UIImage? {
        SymbolSizedLogo.image(
            named: "git-logo",
            reference: "diamond.fill",
            configuration: textStyle.map { UIImage.SymbolConfiguration(textStyle: $0) }
                ?? UIImage.SymbolConfiguration(textStyle: .body, scale: .small),
            fallbackSide: UIFont.preferredFont(forTextStyle: textStyle ?? .body).pointSize
        )
    }
}

/// Which top bar buttons a chat shows, and in what order (`BarLayout`).
typealias ChatTopBarLayout = BarLayout<ChatTopBarAction>

extension ChatTopBarAction: BarLayoutAction {
    /// The bar without a saved choice: Context (the ring) alone, with Files,
    /// Git, Outline, and Terminal in the menu (Terminal where the workspace has
    /// a folder a shell can start in). The order is still every action, so a
    /// button someone pins lands in a sensible place. An action added after a
    /// layout was saved (Git) is appended to its order and offered in the menu.
    static let defaultShown: Set<ChatTopBarAction> = [.context]
}
