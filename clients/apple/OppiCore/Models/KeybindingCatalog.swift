import Foundation

/// Hardware-keyboard timeline preset.
///
/// `macDefault` (Mac Standard) is arrows / Return / Esc. It never consumes
/// unmodified letters, so a global or timeline monitor cannot steal composer
/// typing. `vim` adds letter bindings and `emacs` adds Control / Option
/// chords, both only while the timeline is focused.
enum KeybindingMode: String, CaseIterable, Sendable {
    case macDefault
    case vim
    case emacs

    /// Named UserDefaults key for the persisted catalog mode.
    static let preferenceKey = "oppi.keybinding.mode"

    /// Missing and unknown raw values fall back to `macDefault`.
    static func resolved(_ rawValue: String?) -> KeybindingMode {
        guard let rawValue, let mode = KeybindingMode(rawValue: rawValue) else {
            return .macDefault
        }
        return mode
    }

    var displayName: String {
        switch self {
        case .macDefault: "Mac Standard"
        case .vim: "Vim"
        case .emacs: "Emacs"
        }
    }
}

/// Which session surface currently owns the keyboard.
enum KeybindingFocus: String, CaseIterable, Sendable {
    case timeline
    case composer
    case viewer
}

/// UI-framework-free key identity. Adapters map UIKit / AppKit events here.
enum KeybindingKey: Equatable, Hashable, Sendable {
    case character(Character)
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case `return`
    case escape
    case tab
}

/// One key plus modifier flags. Extra modifiers never match a binding.
struct KeybindingChord: Equatable, Hashable, Sendable {
    var key: KeybindingKey
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    init(
        key: KeybindingKey,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) {
        // Fold ASCII letters so `G` and shift-g are the same chord.
        if case .character(let character) = key,
           character.isASCII,
           character.isLetter,
           let lowered = character.lowercased().first {
            self.key = .character(lowered)
            self.shift = shift || character.isUppercase
        } else {
            self.key = key
            self.shift = shift
        }
        self.command = command
        self.option = option
        self.control = control
    }

    static let upArrow = KeybindingChord(key: .upArrow)
    static let downArrow = KeybindingChord(key: .downArrow)
    static let leftArrow = KeybindingChord(key: .leftArrow)
    static let rightArrow = KeybindingChord(key: .rightArrow)
    static let `return` = KeybindingChord(key: .return)
    static let commandReturn = KeybindingChord(key: .return, command: true)
    static let escape = KeybindingChord(key: .escape)
    static let tab = KeybindingChord(key: .tab)

    static func letter(_ character: Character, shift: Bool = false, command: Bool = false) -> KeybindingChord {
        KeybindingChord(key: .character(character), command: command, shift: shift)
    }

    static func control(_ character: Character) -> KeybindingChord {
        KeybindingChord(key: .character(character), control: true)
    }

    var hasNoModifiers: Bool {
        !command && !shift && !option && !control
    }

    var hasOnlyShift: Bool {
        shift && !command && !option && !control
    }
}

/// Semantic catalog result. Enter / Cmd-Return on the timeline opens the
/// document column (`openViewer`), not a detached window.
enum KeybindingAction: Equatable, Sendable {
    case nextToolRow
    case previousToolRow
    case collapse
    case expand
    case toggleExpanded
    case openViewer
    case moveToTop
    case moveToBottom
    case focusComposer
    case closeViewer
    case send
}

/// One chord → action row. The catalog is data so help screens and
/// hardware adapters read the same table the matcher uses.
struct KeybindingBinding: Equatable, Sendable {
    let chord: KeybindingChord
    let action: KeybindingAction
}

/// Mode × focus lookup. Pure data; platform adapters decide how to paint.
enum KeybindingCatalog {
    static func action(
        for chord: KeybindingChord,
        mode: KeybindingMode,
        focus: KeybindingFocus
    ) -> KeybindingAction? {
        bindings(mode: mode, focus: focus).first { $0.chord == chord }?.action
    }

    /// Chords that currently produce an action for this mode×focus.
    /// Adapters register from this list; they do not keep a second table.
    static func boundChords(mode: KeybindingMode, focus: KeybindingFocus) -> [KeybindingChord] {
        bindings(mode: mode, focus: focus).map(\.chord)
    }

    /// Ordered rows for a mode×focus. Earlier rows win on duplicate chords.
    static func bindings(mode: KeybindingMode, focus: KeybindingFocus) -> [KeybindingBinding] {
        switch (mode, focus) {
        case (_, .composer):
            return composerBindings
        case (.macDefault, .timeline):
            return macStandardTimelineBindings
        case (.vim, .timeline):
            return macStandardTimelineBindings + vimTimelineBindings
        case (.emacs, .timeline):
            return macStandardTimelineBindings + emacsTimelineBindings
        case (.emacs, .viewer):
            return viewerBindings + [KeybindingBinding(chord: .control("g"), action: .closeViewer)]
        case (_, .viewer):
            return viewerBindings
        }
    }

    /// Composer keeps letter keys. Cmd-Return stays send, never a timeline
    /// `openViewer` consume.
    private static let composerBindings: [KeybindingBinding] = [
        KeybindingBinding(chord: .commandReturn, action: .send),
    ]

    /// Arrows + Return / Cmd-Return + Esc. Unmodified letters are not bound.
    private static let macStandardTimelineBindings: [KeybindingBinding] = [
        KeybindingBinding(chord: .upArrow, action: .previousToolRow),
        KeybindingBinding(chord: .downArrow, action: .nextToolRow),
        KeybindingBinding(chord: .leftArrow, action: .collapse),
        KeybindingBinding(chord: .rightArrow, action: .expand),
        KeybindingBinding(chord: .return, action: .openViewer),
        KeybindingBinding(chord: .commandReturn, action: .openViewer),
        KeybindingBinding(chord: .escape, action: .closeViewer),
        KeybindingBinding(chord: KeybindingChord(key: .upArrow, command: true), action: .moveToTop),
        KeybindingBinding(chord: KeybindingChord(key: .downArrow, command: true), action: .moveToBottom),
    ]

    /// j/k h/l e g/G Tab/i on top of Mac Standard.
    private static let vimTimelineBindings: [KeybindingBinding] = [
        KeybindingBinding(chord: .letter("j"), action: .nextToolRow),
        KeybindingBinding(chord: .letter("k"), action: .previousToolRow),
        KeybindingBinding(chord: .letter("h"), action: .collapse),
        KeybindingBinding(chord: .letter("l"), action: .expand),
        KeybindingBinding(chord: .letter("e"), action: .toggleExpanded),
        KeybindingBinding(chord: .letter("g"), action: .moveToTop),
        KeybindingBinding(chord: .letter("g", shift: true), action: .moveToBottom),
        KeybindingBinding(chord: .tab, action: .focusComposer),
        KeybindingBinding(chord: .letter("i"), action: .focusComposer),
    ]

    /// C-n/C-p C-f/C-b, Tab folds like org-mode, M-< / M->, C-g quits,
    /// C-o jumps to the composer.
    private static let emacsTimelineBindings: [KeybindingBinding] = [
        KeybindingBinding(chord: .control("n"), action: .nextToolRow),
        KeybindingBinding(chord: .control("p"), action: .previousToolRow),
        KeybindingBinding(chord: .control("b"), action: .collapse),
        KeybindingBinding(chord: .control("f"), action: .expand),
        KeybindingBinding(chord: .tab, action: .toggleExpanded),
        KeybindingBinding(
            chord: KeybindingChord(key: .character("<"), shift: true, option: true),
            action: .moveToTop
        ),
        KeybindingBinding(
            chord: KeybindingChord(key: .character(">"), shift: true, option: true),
            action: .moveToBottom
        ),
        KeybindingBinding(chord: .control("g"), action: .closeViewer),
        KeybindingBinding(chord: .control("o"), action: .focusComposer),
    ]

    private static let viewerBindings: [KeybindingBinding] = [
        KeybindingBinding(chord: .escape, action: .closeViewer),
    ]
}

/// Persists `KeybindingMode` under `KeybindingMode.preferenceKey`.
@MainActor
final class KeybindingPreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var mode: KeybindingMode {
        get { KeybindingMode.resolved(defaults.string(forKey: KeybindingMode.preferenceKey)) }
        set { defaults.set(newValue.rawValue, forKey: KeybindingMode.preferenceKey) }
    }
}
