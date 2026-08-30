import Foundation

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
        case .send, .moveToTop, .moveToBottom, .focusComposer:
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
