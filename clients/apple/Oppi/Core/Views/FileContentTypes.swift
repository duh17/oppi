import CoreGraphics

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
