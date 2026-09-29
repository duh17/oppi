import AppKit
import SwiftUI

/// Session-owned timeline selection, expansion, and catalog application.
///
/// Expansion lives here instead of a row-local `@State`. Platform views map
/// AppKit/SwiftUI key events through `KeybindingEventMap` into
/// `KeybindingChord` and call `apply`.
enum MacTimelineKeybinding {
    struct State: Equatable {
        var selectedToolRowID: String?
        var expandedToolRowIDs: Set<String>
        var focus: KeybindingFocus
        /// Sticky document-column identity. Independent of row expansion.
        var openToolDocumentID: String?

        init(
            selectedToolRowID: String? = nil,
            expandedToolRowIDs: Set<String> = [],
            focus: KeybindingFocus = .composer,
            openToolDocumentID: String? = nil
        ) {
            self.selectedToolRowID = selectedToolRowID
            self.expandedToolRowIDs = expandedToolRowIDs
            self.focus = focus
            self.openToolDocumentID = openToolDocumentID
        }
    }

    /// Vim's insert-mode exit. Composer-owned, so it is not a catalog row.
    static func composerEscapeFocusesTimeline(mode: KeybindingMode) -> Bool {
        mode == .vim
    }

    static func toolRowIDs(in items: [ChatItem]) -> [String] {
        items.compactMap { item in
            if case .toolCall(let id, _, _, _, _, _, _) = item {
                return id
            }
            return nil
        }
    }

    static func selectToolRow(_ id: String, in state: inout State) {
        state.selectedToolRowID = id
        state.focus = .timeline
    }

    @discardableResult
    static func apply(
        chord: KeybindingChord,
        mode: KeybindingMode,
        to state: inout State,
        toolRowIDs: [String]
    ) -> KeybindingAction? {
        let action = KeybindingCatalog.action(for: chord, mode: mode, focus: state.focus)
        guard let action else { return nil }
        apply(action, to: &state, toolRowIDs: toolRowIDs)
        return action
    }

    static func apply(
        _ action: KeybindingAction,
        to state: inout State,
        toolRowIDs: [String]
    ) {
        switch action {
        case .nextToolRow:
            state.selectedToolRowID = nextID(after: state.selectedToolRowID, in: toolRowIDs)
            state.focus = .timeline
        case .previousToolRow:
            state.selectedToolRowID = previousID(before: state.selectedToolRowID, in: toolRowIDs)
            state.focus = .timeline
        case .collapse:
            if let id = state.selectedToolRowID {
                state.expandedToolRowIDs.remove(id)
            }
        case .expand:
            if let id = state.selectedToolRowID {
                state.expandedToolRowIDs.insert(id)
            }
        case .toggleExpanded:
            guard let id = state.selectedToolRowID else { return }
            if state.expandedToolRowIDs.contains(id) {
                state.expandedToolRowIDs.remove(id)
            } else {
                state.expandedToolRowIDs.insert(id)
            }
        case .openViewer:
            if let id = state.selectedToolRowID {
                state.openToolDocumentID = id
            }
        case .closeViewer:
            state.openToolDocumentID = nil
            if state.focus == .viewer {
                state.focus = state.selectedToolRowID == nil ? .composer : .timeline
            }
        case .moveToTop:
            state.selectedToolRowID = toolRowIDs.first ?? state.selectedToolRowID
            state.focus = .timeline
        case .moveToBottom:
            state.selectedToolRowID = toolRowIDs.last ?? state.selectedToolRowID
            state.focus = .timeline
        case .focusComposer:
            state.focus = .composer
        case .send:
            break
        }
    }

    /// Any catalog action resolved while the timeline is focused is consumed,
    /// including `.openViewer` (Cmd-Return / Return). That keeps the composer
    /// send shortcut from firing. Composer `.send` itself is not consumed.
    static func consumes(_ action: KeybindingAction?) -> Bool {
        switch action {
        case .nextToolRow, .previousToolRow, .collapse, .expand, .toggleExpanded,
             .openViewer, .closeViewer, .moveToTop, .moveToBottom, .focusComposer:
            return true
        case .send, nil:
            return false
        }
    }

    private static func nextID(after selected: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return selected }
        guard let selected, let index = ids.firstIndex(of: selected) else {
            return ids.first
        }
        let next = index + 1
        return next < ids.count ? ids[next] : selected
    }

    private static func previousID(before selected: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return selected }
        guard let selected, let index = ids.firstIndex(of: selected) else {
            return ids.last
        }
        let previous = index - 1
        return previous >= 0 ? ids[previous] : selected
    }
}

/// Mouse contract for a tool row header. AppKit delivers the second click of
/// a double click as its own click with `clickCount == 2`, after the first
/// click already toggled expansion; the double click undoes that toggle so
/// the row keeps its prior state while its document opens beside the timeline.
enum MacToolRowClick: Equatable {
    case toggleExpanded
    case openDocument(revertExpansion: Bool)

    static func action(clickCount: Int, canExpand: Bool, canOpenDocument: Bool) -> Self? {
        switch clickCount {
        case 1:
            return canExpand ? .toggleExpanded : nil
        case 2:
            return canOpenDocument ? .openDocument(revertExpansion: canExpand) : nil
        default:
            return nil
        }
    }
}

extension KeyPress {
    /// SwiftUI `characters` carries Control / Option transforms (`⌃N` is
    /// U+000E, `⌥⇧,` is `¯`). The catalog matches base keys, so read the
    /// AppKit key-down's `charactersIgnoringModifiers` when it is this press.
    var keybindingChord: KeybindingChord? {
        let baseCharacters: String
        if let event = NSApp.currentEvent,
           event.type == .keyDown,
           let ignoring = event.charactersIgnoringModifiers {
            baseCharacters = ignoring
        } else {
            baseCharacters = characters
        }
        return KeybindingEventMap.chord(
            characters: baseCharacters,
            isUpArrow: key == .upArrow,
            isDownArrow: key == .downArrow,
            isLeftArrow: key == .leftArrow,
            isRightArrow: key == .rightArrow,
            isReturn: key == .return,
            isEscape: key == .escape,
            isTab: key == .tab,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control)
        )
    }
}
