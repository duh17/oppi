import Foundation
import Observation

/// How hardware and key-bar keys drive the editor.
enum CodeEditorKeybindings: String, CaseIterable, Sendable {
    /// Standard text editing plus Mac-style editor shortcuts.
    case standard
    /// Modal Vim editing (`VimEngine`); the Mac shortcuts still work in Insert mode.
    case vim

    var label: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .vim: String(localized: "Vim")
        }
    }
}

/// One key the editor's keyboard bar can show.
enum CodeEditorBarKey: Hashable, Sendable {
    case escape
    case tab
    case outdent
    case left
    case down
    case up
    case right
    case undo
    case redo
    case comment
    case find
    case lineStart
    case lineEnd
    case symbol(String)

    static let actions: [CodeEditorBarKey] = [
        .escape, .tab, .outdent, .left, .down, .up, .right, .undo, .redo, .comment, .find, .lineStart, .lineEnd,
    ]

    static let symbols: [CodeEditorBarKey] = "{ } ( ) [ ] < > = \" ' ` ; : / \\ | - _ + * & ! ? # $ % ^ ~ @ , ."
        .split(separator: " ")
        .map { .symbol(String($0)) }

    static let catalog = actions + symbols

    static let defaults: [CodeEditorBarKey] = [.escape, .tab, .left, .down, .up, .right, .undo, .redo]
        + "{ } ( ) [ ] < > = \" ' ` ; : / | - _ * & ! # $".split(separator: " ").map { .symbol(String($0)) }

    var id: String {
        switch self {
        case .escape: "escape"
        case .tab: "tab"
        case .outdent: "outdent"
        case .left: "left"
        case .down: "down"
        case .up: "up"
        case .right: "right"
        case .undo: "undo"
        case .redo: "redo"
        case .comment: "comment"
        case .find: "find"
        case .lineStart: "lineStart"
        case .lineEnd: "lineEnd"
        case .symbol(let text): "symbol:" + text
        }
    }

    init?(id: String) {
        if id.hasPrefix("symbol:") {
            let text = String(id.dropFirst("symbol:".count))
            guard !text.isEmpty else { return nil }
            self = .symbol(text)
            return
        }
        guard let action = Self.actions.first(where: { $0.id == id }) else { return nil }
        self = action
    }

    /// Text on the key; nil when the key shows `systemImage`.
    var title: String? {
        switch self {
        case .escape: "esc"
        case .tab: "⇥"
        case .outdent: "⇤"
        case .symbol(let text): text
        default: nil
        }
    }

    var systemImage: String? {
        switch self {
        case .left: "arrow.left"
        case .down: "arrow.down"
        case .up: "arrow.up"
        case .right: "arrow.right"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .comment: "number"
        case .find: "magnifyingglass"
        case .lineStart: "arrow.left.to.line"
        case .lineEnd: "arrow.right.to.line"
        default: nil
        }
    }

    var label: String {
        switch self {
        case .escape: String(localized: "Escape")
        case .tab: String(localized: "Tab")
        case .outdent: String(localized: "Outdent")
        case .left: String(localized: "Left")
        case .down: String(localized: "Down")
        case .up: String(localized: "Up")
        case .right: String(localized: "Right")
        case .undo: String(localized: "Undo")
        case .redo: String(localized: "Redo")
        case .comment: String(localized: "Toggle Comment")
        case .find: String(localized: "Find")
        case .lineStart: String(localized: "Line Start")
        case .lineEnd: String(localized: "Line End")
        case .symbol(let text): text
        }
    }

    /// Arrow keys repeat while held.
    var repeats: Bool {
        switch self {
        case .left, .down, .up, .right: true
        default: false
        }
    }
}

/// What a file's wrap preference follows: prose wraps by default, code does not.
enum CodeEditorWrapKind: Sendable {
    /// Markdown and plain text.
    case text
    /// Every file with a code grammar.
    case code

    init(grammar: CodeEditorHighlightEngine.Grammar) {
        switch grammar {
        case .markdown, .plain: self = .text
        case .treeSitter, .scanner: self = .code
        }
    }
}

/// Device-local editor settings. The editor and Settings > Editor read and write
/// the same stored value: an editor that is open follows a write made in
/// Settings, and Settings > Editor shows what the editor's "…" menu wrote the
/// next time the page appears (the two are never on screen together).
@MainActor @Observable
final class CodeEditorPreferences {
    static let shared = CodeEditorPreferences()
    @ObservationIgnored private let defaults: UserDefaults

    var keybindings: CodeEditorKeybindings { didSet { defaults.set(keybindings.rawValue, forKey: Key.keybindings) } }
    var showsLineNumbers: Bool { didSet { defaults.set(showsLineNumbers, forKey: Key.lineNumbers) } }
    var highlightsCurrentLine: Bool { didSet { defaults.set(highlightsCurrentLine, forKey: Key.currentLine) } }
    /// Wrap Lines for Markdown and plain text (on unless the user chose).
    var wrapsText: Bool { didSet { defaults.set(wrapsText, forKey: Key.wrapText) } }
    /// Wrap Lines for code (off unless the user chose).
    var wrapsCode: Bool { didSet { defaults.set(wrapsCode, forKey: Key.wrapCode) } }
    var highlightsSyntax: Bool { didSet { defaults.set(highlightsSyntax, forKey: Key.syntax) } }
    var closesBrackets: Bool { didSet { defaults.set(closesBrackets, forKey: Key.brackets) } }
    /// Follow the open file's own tabs/spaces and width when it has indented lines.
    var detectsIndentation: Bool { didSet { defaults.set(detectsIndentation, forKey: Key.detectIndent) } }
    var indentsWithTabs: Bool { didSet { defaults.set(indentsWithTabs, forKey: Key.tabs) } }
    var tabWidth: Int { didSet { defaults.set(tabWidth, forKey: Key.tabWidth) } }
    var showsKeyBar: Bool { didSet { defaults.set(showsKeyBar, forKey: Key.keyBar) } }
    var keyBarKeys: [CodeEditorBarKey] { didSet { defaults.set(keyBarKeys.map(\.id), forKey: Key.keyBarKeys) } }

    /// Auto-Save: write the document as you type. Off (the default), the edit
    /// session writes nothing on its own and a person saves: Done asks, ⌘S and
    /// Vim's `:w` write. Read through `defaults` rather than held in memory, so
    /// Settings > Editor's declared row (`SettingsCatalog.autoSave`, kept on the
    /// same key) and this menu are one value whichever side wrote it.
    var autoSaves: Bool {
        get {
            access(keyPath: \.autoSaves)
            return defaults.object(forKey: Key.autoSave) == nil
                ? AppPreferenceStore.Editor.autoSaveDefault
                : defaults.bool(forKey: Key.autoSave)
        }
        set {
            withMutation(keyPath: \.autoSaves) { defaults.set(newValue, forKey: Key.autoSave) }
            // An editor that is already open is not redrawn by a stored write:
            // it hears this instead, from the menu and from Settings > Editor.
            NotificationCenter.default.post(name: .codeEditorAutoSaveDidChange, object: nil)
        }
    }

    static let tabWidths = [2, 4, 8]

    private enum Key {
        static let prefix = "\(AppIdentifiers.subsystem).editor."
        static let keybindings = prefix + "keybindings"
        static let lineNumbers = prefix + "lineNumbers"
        static let currentLine = prefix + "currentLine"
        /// One setting for every file until wrapping became per kind; read once
        /// as the user's choice for both kinds, never written again.
        static let legacyWrap = prefix + "wrapLines"
        static let wrapText = prefix + "wrapText"
        static let wrapCode = prefix + "wrapCode"
        static let syntax = prefix + "syntaxHighlighting"
        static let brackets = prefix + "closeBrackets"
        static let detectIndent = prefix + "detectIndentation"
        static let tabs = prefix + "indentWithTabs"
        static let tabWidth = prefix + "tabWidth"
        static let keyBar = prefix + "keyBar"
        static let keyBarKeys = prefix + "keyBarKeys"
        /// The declared setting's key; see `AppPreferenceStore.Editor`.
        static let autoSave = AppPreferenceStore.Editor.autoSaveKey
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        keybindings = defaults.string(forKey: Key.keybindings).flatMap(CodeEditorKeybindings.init(rawValue:)) ?? .standard
        showsLineNumbers = bool(Key.lineNumbers, true)
        highlightsCurrentLine = bool(Key.currentLine, true)
        let legacyWrap = defaults.object(forKey: Key.legacyWrap) == nil ? nil : defaults.bool(forKey: Key.legacyWrap)
        wrapsText = bool(Key.wrapText, legacyWrap ?? true)
        wrapsCode = bool(Key.wrapCode, legacyWrap ?? false)
        highlightsSyntax = bool(Key.syntax, true)
        closesBrackets = bool(Key.brackets, true)
        detectsIndentation = bool(Key.detectIndent, true)
        indentsWithTabs = bool(Key.tabs, false)
        let width = defaults.integer(forKey: Key.tabWidth)
        tabWidth = Self.tabWidths.contains(width) ? width : 4
        showsKeyBar = bool(Key.keyBar, true)
        keyBarKeys = (defaults.stringArray(forKey: Key.keyBarKeys)?.compactMap(CodeEditorBarKey.init(id:)))
            ?? CodeEditorBarKey.defaults
    }

    func wrapsLines(for kind: CodeEditorWrapKind) -> Bool {
        switch kind {
        case .text: wrapsText
        case .code: wrapsCode
        }
    }

    func setWrapsLines(_ wraps: Bool, for kind: CodeEditorWrapKind) {
        switch kind {
        case .text: wrapsText = wraps
        case .code: wrapsCode = wraps
        }
    }

    /// Indentation from settings, before the file's own style is detected.
    var indentation: CodeIndentation {
        CodeIndentation(usesTabs: indentsWithTabs, width: tabWidth)
    }

    func resetKeyBar() {
        keyBarKeys = CodeEditorBarKey.defaults
    }
}

extension Notification.Name {
    /// Auto-Save changed: from the editor's options menu, or from Settings >
    /// Editor (a device setting the store writes straight to the defaults). An
    /// open editor hears it and starts or stops the idle save it owes, which
    /// reading the value at the next write would be too late for.
    static let codeEditorAutoSaveDidChange = Notification.Name(
        "\(AppIdentifiers.subsystem).editor.autoSaveDidChange"
    )
}
