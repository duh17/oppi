import UIKit

/// Thin iOS/iPad adapter over `KeybindingCatalog`.
///
/// Hardware events / `UIKeyCommand` become `KeybindingChord` through the shared
/// `KeybindingEventMap`, then the same catalog Mac uses. This type does not
/// own a mode×focus table and does not copy Mac document-column state.
enum HardwareKeybindingAdapter {
    struct Request: Equatable {
        var hardwareKeyboardConnected: Bool
        var userInterfaceIdiom: UIUserInterfaceIdiom
        var mode: KeybindingMode
        var focus: KeybindingFocus
        /// True when the responder also hosts the composer. Unmodified letters
        /// must never be registered in that case — they would steal typing.
        var hostsComposer: Bool
        var composerIsFirstResponder: Bool
    }

    /// iPhone and iPad bind catalog chords only while a hardware keyboard is
    /// attached. The software keyboard must not register vim letters.
    static func shouldBind(_ request: Request) -> Bool {
        request.hardwareKeyboardConnected
    }

    static func shouldBecomeFirstResponder(_ request: Request) -> Bool {
        shouldBind(request)
            && request.focus != .composer
            && !request.composerIsFirstResponder
    }

    /// Resolves through `KeybindingCatalog.action`. No second table.
    static func action(for chord: KeybindingChord, request: Request) -> KeybindingAction? {
        guard shouldBind(request) else { return nil }
        if request.hostsComposer, stealsComposerTyping(chord) {
            return nil
        }
        return KeybindingCatalog.action(for: chord, mode: request.mode, focus: request.focus)
    }

    /// Composer `.send` is not consumed — `PastableTextView` Cmd-Return owns it.
    static func consumes(_ action: KeybindingAction?) -> Bool {
        switch action {
        case .nextToolRow, .previousToolRow, .collapse, .expand, .toggleExpanded,
             .openViewer, .closeViewer, .moveToTop, .moveToBottom, .focusComposer:
            return true
        case .send, nil:
            return false
        }
    }

    static func chord(
        input: String?,
        modifierFlags: UIKeyModifierFlags
    ) -> KeybindingChord? {
        KeybindingEventMap.chord(
            characters: letterCharacters(from: input),
            isUpArrow: input == UIKeyCommand.inputUpArrow,
            isDownArrow: input == UIKeyCommand.inputDownArrow,
            isLeftArrow: input == UIKeyCommand.inputLeftArrow,
            isRightArrow: input == UIKeyCommand.inputRightArrow,
            isReturn: input == "\r",
            isEscape: input == UIKeyCommand.inputEscape,
            isTab: input == "\t",
            command: modifierFlags.contains(.command),
            shift: modifierFlags.contains(.shift),
            option: modifierFlags.contains(.alternate),
            control: modifierFlags.contains(.control)
        )
    }

    static func chord(from command: UIKeyCommand) -> KeybindingChord? {
        chord(input: command.input, modifierFlags: command.modifierFlags)
    }

    /// Chords this responder may install as `UIKeyCommand`s.
    ///
    /// Empty without a hardware keyboard, and empty when the composer is
    /// focused so Cmd-Return stays on `PastableTextView`. Bindings themselves
    /// come from `KeybindingCatalog.boundChords`.
    static func registeredChords(for request: Request) -> [KeybindingChord] {
        guard shouldBind(request) else { return [] }
        if request.composerIsFirstResponder || request.focus == .composer {
            return []
        }
        return KeybindingCatalog.boundChords(mode: request.mode, focus: request.focus)
            .filter { chord in
                if request.hostsComposer, stealsComposerTyping(chord) {
                    return false
                }
                return consumes(KeybindingCatalog.action(
                    for: chord,
                    mode: request.mode,
                    focus: request.focus
                ))
            }
    }

    static func uiKeyCommand(
        for chord: KeybindingChord,
        action: Selector
    ) -> UIKeyCommand? {
        guard let input = uiKeyCommandInput(for: chord.key) else { return nil }
        var flags: UIKeyModifierFlags = []
        if chord.command { flags.insert(.command) }
        if chord.shift { flags.insert(.shift) }
        if chord.option { flags.insert(.alternate) }
        if chord.control { flags.insert(.control) }
        return UIKeyCommand(input: input, modifierFlags: flags, action: action)
    }

    /// Unmodified / shift letters and Tab would steal composer typing.
    private static func stealsComposerTyping(_ chord: KeybindingChord) -> Bool {
        switch chord.key {
        case .character:
            return chord.hasNoModifiers || chord.hasOnlyShift
        case .tab:
            return chord.hasNoModifiers
        default:
            return false
        }
    }

    private static func letterCharacters(from input: String?) -> String {
        guard let input, !input.isEmpty else { return "" }
        if input == UIKeyCommand.inputUpArrow
            || input == UIKeyCommand.inputDownArrow
            || input == UIKeyCommand.inputLeftArrow
            || input == UIKeyCommand.inputRightArrow
            || input == UIKeyCommand.inputEscape
            || input == "\r"
            || input == "\t" {
            return ""
        }
        return input
    }

    private static func uiKeyCommandInput(for key: KeybindingKey) -> String? {
        switch key {
        case .character(let character):
            return String(character)
        case .upArrow:
            return UIKeyCommand.inputUpArrow
        case .downArrow:
            return UIKeyCommand.inputDownArrow
        case .leftArrow:
            return UIKeyCommand.inputLeftArrow
        case .rightArrow:
            return UIKeyCommand.inputRightArrow
        case .return:
            return "\r"
        case .escape:
            return UIKeyCommand.inputEscape
        case .tab:
            return "\t"
        }
    }
}
