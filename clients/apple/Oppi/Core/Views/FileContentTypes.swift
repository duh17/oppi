import SwiftUI

enum FileContentPresentation {
    /// Compact card-style rendering used inside timeline/list rows.
    case inline
    /// Native full-page rendering for dedicated file viewers.
    case document

    var usesInlineChrome: Bool {
        self == .inline
    }

    var viewportMaxHeight: CGFloat? {
        usesInlineChrome ? 500 : nil
    }

    var allowsExpansionAffordance: Bool {
        usesInlineChrome
    }
}

enum ExpandableInlineTextSelectionPolicy {
    static func allowsInlineSelection(hasFullScreenAffordance: Bool) -> Bool {
        !hasFullScreenAffordance
    }
}

extension View {
    @ViewBuilder
    func applyInlineTextSelectionPolicy(_ enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}
