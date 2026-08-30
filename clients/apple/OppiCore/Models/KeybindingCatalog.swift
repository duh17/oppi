import Foundation

/// Hardware-keyboard catalog mode.
///
/// `macDefault` is arrows / Return / Esc. It never consumes unmodified
/// letters, so a global or timeline monitor cannot steal composer typing.
/// `vim` adds letter bindings only while the timeline is focused.
enum KeybindingMode: String, CaseIterable, Sendable {
    case macDefault
    case vim

    /// Named UserDefaults key for the persisted catalog mode.
    static let preferenceKey = "oppi.keybinding.mode"

    /// Missing and unknown raw values fall back to `macDefault`.
    static func resolved(_ rawValue: String?) -> KeybindingMode {
        guard let rawValue, let mode = KeybindingMode(rawValue: rawValue) else {
            return .macDefault
        }
        return mode
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

    var hasNoModifiers: Bool {
        !command && !shift && !option && !control
    }

    var hasOnlyCommand: Bool {
        command && !shift && !option && !control
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

/// Mode × focus lookup. Pure data; platform adapters decide how to paint.
enum KeybindingCatalog {
    static func action(
        for chord: KeybindingChord,
        mode: KeybindingMode,
        focus: KeybindingFocus
    ) -> KeybindingAction? {
        switch (mode, focus) {
        case (_, .composer):
            return composerAction(for: chord)
        case (.macDefault, .timeline):
            return macDefaultTimelineAction(for: chord)
        case (.vim, .timeline):
            return vimTimelineAction(for: chord)
        case (_, .viewer):
            return viewerAction(for: chord)
        }
    }

    /// Chords that currently produce an action for this mode×focus.
    /// Adapters register from this list; they do not keep a second table.
    static func boundChords(mode: KeybindingMode, focus: KeybindingFocus) -> [KeybindingChord] {
        registrableHardwareChords.filter { action(for: $0, mode: mode, focus: focus) != nil }
    }

    /// Composer keeps letter keys. Cmd-Return stays send, never a timeline
    /// `openViewer` consume.
    private static func composerAction(for chord: KeybindingChord) -> KeybindingAction? {
        if chord.key == .return, chord.hasOnlyCommand {
            return .send
        }
        return nil
    }

    /// Arrows + Return / Cmd-Return + Esc. Unmodified letters are not bound.
    private static func macDefaultTimelineAction(for chord: KeybindingChord) -> KeybindingAction? {
        switch chord.key {
        case .upArrow where chord.hasNoModifiers:
            return .previousToolRow
        case .downArrow where chord.hasNoModifiers:
            return .nextToolRow
        case .leftArrow where chord.hasNoModifiers:
            return .collapse
        case .rightArrow where chord.hasNoModifiers:
            return .expand
        case .return where chord.hasNoModifiers || chord.hasOnlyCommand:
            return .openViewer
        case .escape where chord.hasNoModifiers:
            return .closeViewer
        default:
            return nil
        }
    }

    /// macDefault timeline plus j/k h/l e g/G Tab/i.
    private static func vimTimelineAction(for chord: KeybindingChord) -> KeybindingAction? {
        if let action = macDefaultTimelineAction(for: chord) {
            return action
        }
        switch chord.key {
        case .character("j") where chord.hasNoModifiers:
            return .nextToolRow
        case .character("k") where chord.hasNoModifiers:
            return .previousToolRow
        case .character("h") where chord.hasNoModifiers:
            return .collapse
        case .character("l") where chord.hasNoModifiers:
            return .expand
        case .character("e") where chord.hasNoModifiers:
            return .toggleExpanded
        case .character("g") where chord.hasNoModifiers:
            return .moveToTop
        case .character("g") where chord.hasOnlyShift:
            return .moveToBottom
        case .tab where chord.hasNoModifiers:
            return .focusComposer
        case .character("i") where chord.hasNoModifiers:
            return .focusComposer
        default:
            return nil
        }
    }

    private static func viewerAction(for chord: KeybindingChord) -> KeybindingAction? {
        if chord.key == .escape, chord.hasNoModifiers {
            return .closeViewer
        }
        return nil
    }

    /// Hardware keys adapters may probe. Not a mode×focus table; `action` is
    /// the matcher.
    private static let registrableHardwareChords: [KeybindingChord] = {
        var chords: [KeybindingChord] = [
            .upArrow, .downArrow, .leftArrow, .rightArrow,
            .return, .commandReturn, .escape, .tab,
        ]
        let a = UnicodeScalar("a").value
        let z = UnicodeScalar("z").value
        for scalar in a...z {
            guard let unicode = UnicodeScalar(scalar) else { continue }
            let character = Character(unicode)
            chords.append(.letter(character))
            chords.append(.letter(character, shift: true))
        }
        return chords
    }()
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
