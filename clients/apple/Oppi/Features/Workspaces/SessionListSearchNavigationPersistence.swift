import Foundation

/// Keeps session-list search across a push/pop of a result.
///
/// SwiftUI's searchable control dismisses — and often clears the query — when
/// a destination covers the list. Opening a result is still the same search
/// job, so Back should return to the flattened Results list. Explicit cancel
/// (the search X) and host reset still clear.
enum SessionListSearchNavigationPersistence {
    struct State: Equatable {
        var searchText = ""
        var isSearchPresented = false
        var heldQuery: String? = nil
        var preservesSearchAcrossDismiss = false
    }

    enum Event: Equatable {
        case searchTextChanged(String)
        case searchPresentationChanged(Bool)
        /// Arm after a session is known to open, before the push, so a
        /// system dismiss that races the path update does not look like
        /// Cancel. Also arm for split: the list is replaced, not covered,
        /// and dismiss would otherwise look like Cancel.
        case willOpenDestination
        case coverageChanged(isCovered: Bool)
        case reset
    }

    /// Compact inbox is covered by its stack. Split replaces the list with
    /// chat, so a non-nil session/detail target is also coverage.
    static func isInboxCovered(
        isSplitPresentation: Bool,
        stackDepth: Int,
        splitDetailReplacesList: Bool = false
    ) -> Bool {
        if isSplitPresentation {
            return splitDetailReplacesList
        }
        return stackDepth > 0
    }

    static func isWorkspaceListCovered(
        stackDepth: Int,
        hasSessionDestination: Bool,
        splitDetailReplacesList: Bool = false
    ) -> Bool {
        if splitDetailReplacesList {
            return true
        }
        return stackDepth > 1 || hasSessionDestination
    }

    static func reduce(
        _ state: State,
        event: Event,
        isCoveredByDestination: Bool
    ) -> State {
        var next = state
        switch event {
        case .searchTextChanged(let text):
            if shouldPreserve(state, isCoveredByDestination: isCoveredByDestination),
               !SessionListSearchPresentation.hasQuery(text),
               let held = state.heldQuery,
               SessionListSearchPresentation.hasQuery(held) {
                next.searchText = held
            } else {
                next.searchText = text
                if SessionListSearchPresentation.hasQuery(text) {
                    next.heldQuery = text
                } else if !shouldPreserve(state, isCoveredByDestination: isCoveredByDestination) {
                    next.heldQuery = nil
                }
            }

        case .searchPresentationChanged(let presented):
            next.isSearchPresented = presented
            if presented {
                if let held = state.heldQuery, SessionListSearchPresentation.hasQuery(held) {
                    next.searchText = held
                }
            } else if shouldPreserve(state, isCoveredByDestination: isCoveredByDestination) {
                if SessionListSearchPresentation.hasQuery(state.searchText) {
                    next.heldQuery = state.searchText
                }
                if !SessionListSearchPresentation.hasQuery(next.searchText),
                   let held = next.heldQuery,
                   SessionListSearchPresentation.hasQuery(held) {
                    next.searchText = held
                }
            } else {
                next.searchText = ""
                next.heldQuery = nil
                next.preservesSearchAcrossDismiss = false
            }

        case .willOpenDestination:
            if SessionListSearchPresentation.hasQuery(state.searchText) {
                next.heldQuery = state.searchText
                next.preservesSearchAcrossDismiss = true
            }

        case .coverageChanged(let covered):
            if covered {
                if SessionListSearchPresentation.hasQuery(state.searchText) {
                    next.heldQuery = state.searchText
                }
            } else if let held = state.heldQuery, SessionListSearchPresentation.hasQuery(held) {
                next.searchText = held
                next.isSearchPresented = true
                next.preservesSearchAcrossDismiss = false
            } else {
                next.preservesSearchAcrossDismiss = false
            }

        case .reset:
            next = State()
        }
        return next
    }

    private static func shouldPreserve(
        _ state: State,
        isCoveredByDestination: Bool
    ) -> Bool {
        isCoveredByDestination || state.preservesSearchAcrossDismiss
    }
}
