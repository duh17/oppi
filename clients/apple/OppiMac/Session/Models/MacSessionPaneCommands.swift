import Foundation
import Observation
import SwiftUI

enum MacSessionPaneCommand: String, CaseIterable, Sendable {
    case splitRight
    case splitDown
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case closePane
}

enum MacSessionPaneCommandAvailability {
    /// Pane commands belong to the visible Home deck, not a hidden retained tree.
    /// Stats-only Home detail is the exception: the deck is not on screen.
    static func isDeckDisplayed(
        section: MacSidebarSection,
        homeDetail: MacHomeSessionSelection
    ) -> Bool {
        guard section == .sessionHome else { return false }
        if case .statsOnly = homeDetail { return false }
        return true
    }
}

@MainActor
@Observable
final class MacSessionPaneCommandCenter {
    let deck: MacSessionPaneDeck
    var isDeckDisplayed = true

    init(deck: MacSessionPaneDeck) {
        self.deck = deck
    }

    var canSplit: Bool { isDeckDisplayed && deck.layout != nil }
    var canClosePane: Bool { isDeckDisplayed && deck.layout != nil }
    func perform(_ command: MacSessionPaneCommand) {
        guard isDeckDisplayed else { return }
        let originID = deck.focusedPaneID
        switch command {
        case .splitRight:
            _ = deck.splitFocusedRight()
        case .splitDown:
            _ = deck.splitFocusedBelow()
        case .focusLeft:
            _ = deck.focusAdjacent(.left)
        case .focusRight:
            _ = deck.focusAdjacent(.right)
        case .focusUp:
            _ = deck.focusAdjacent(.up)
        case .focusDown:
            _ = deck.focusAdjacent(.down)
        case .closePane:
            _ = deck.closeFocused()
        }
        if deck.focusedPaneID != originID {
            deck.synchronizeKeyboardOwnership()
        }
    }
}

private struct MacSessionPaneCommandCenterKey: FocusedValueKey {
    typealias Value = MacSessionPaneCommandCenter
}

extension FocusedValues {
    var macSessionPaneCommands: MacSessionPaneCommandCenter? {
        get { self[MacSessionPaneCommandCenterKey.self] }
        set { self[MacSessionPaneCommandCenterKey.self] = newValue }
    }
}
