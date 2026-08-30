import Foundation

/// UI-framework-free hardware event → `KeybindingChord` mapping.
///
/// Mac and iOS adapters translate AppKit / UIKit / `UIKeyCommand` fields into
/// these booleans, then share this mapper. The catalog still owns mode × focus.
enum KeybindingEventMap {
    static func chord(
        characters: String,
        isUpArrow: Bool,
        isDownArrow: Bool,
        isLeftArrow: Bool,
        isRightArrow: Bool,
        isReturn: Bool,
        isEscape: Bool,
        isTab: Bool,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) -> KeybindingChord? {
        let key: KeybindingKey
        if isUpArrow {
            key = .upArrow
        } else if isDownArrow {
            key = .downArrow
        } else if isLeftArrow {
            key = .leftArrow
        } else if isRightArrow {
            key = .rightArrow
        } else if isReturn {
            key = .return
        } else if isEscape {
            key = .escape
        } else if isTab {
            key = .tab
        } else if let character = characters.first {
            key = .character(character)
        } else {
            return nil
        }
        return KeybindingChord(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }
}
