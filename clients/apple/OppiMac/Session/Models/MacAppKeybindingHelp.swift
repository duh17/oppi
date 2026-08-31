import Foundation

struct MacAppKeybindingHelpEntry: Equatable, Sendable, Identifiable {
    var id: String { "\(action)|\(shortcut)" }
    let action: String
    let shortcut: String
}

/// Mac-app keyboard help. Pane actions stay here, not in the shared iOS catalog.
enum MacAppKeybindingHelp {
    static let entries: [MacAppKeybindingHelpEntry] = paneEntries + sessionEntries + timelineEntries

    static let paneEntries: [MacAppKeybindingHelpEntry] = [
        .init(action: "Split Right", shortcut: "⌘D"),
        .init(action: "Split Down", shortcut: "⌘⇧D"),
        .init(action: "Focus Left", shortcut: "⌘⌥←"),
        .init(action: "Focus Right", shortcut: "⌘⌥→"),
        .init(action: "Focus Up", shortcut: "⌘⌥↑"),
        .init(action: "Focus Down", shortcut: "⌘⌥↓"),
        .init(action: "Close Pane", shortcut: "⌘⇧W"),
        .init(action: "Close Window", shortcut: "⌘W"),
    ]

    static let sessionEntries: [MacAppKeybindingHelpEntry] = [
        .init(action: "Send", shortcut: "⌘↩"),
        .init(action: "Keyboard Shortcuts", shortcut: "⇧?"),
        .init(action: "Close Document", shortcut: "Esc"),
    ]

    static let timelineEntries: [MacAppKeybindingHelpEntry] = [
        .init(action: "Previous Tool Row", shortcut: "↑"),
        .init(action: "Next Tool Row", shortcut: "↓"),
        .init(action: "Collapse Tool Row", shortcut: "←"),
        .init(action: "Expand Tool Row", shortcut: "→"),
        .init(action: "Open Document", shortcut: "↩"),
        .init(action: "Vim Next Tool Row", shortcut: "j"),
        .init(action: "Vim Previous Tool Row", shortcut: "k"),
        .init(action: "Vim Collapse Tool Row", shortcut: "h"),
        .init(action: "Vim Expand Tool Row", shortcut: "l"),
        .init(action: "Vim Toggle Expanded", shortcut: "e"),
        .init(action: "Vim Move to Top", shortcut: "g"),
        .init(action: "Vim Move to Bottom", shortcut: "G"),
        .init(action: "Vim Focus Composer", shortcut: "Tab / i"),
    ]

    static func allowsCheatSheetShortcut(composerIsFirstResponder: Bool) -> Bool {
        !composerIsFirstResponder
    }
}
