import UIKit

/// Pure layout policy for assistant markdown tables.
///
/// Column widths are content-only: `min(naturalSingleLine, maxReadable)`.
/// Grid/wrap mode is used iff any column's natural width exceeds `maxReadable`.
/// Viewport width never chooses the mode and never squeezes a short column.
enum MarkdownTableColumnLayout {
    /// Horizontal padding inside the table card around cell content.
    static let horizontalContentInset: CGFloat = 8

    /// Gap between columns in grid mode (includes room for a thin divider).
    static let columnSpacing: CGFloat = 8

    /// Readable wrap budget, in mono cells of `AppFont.monoMedium`.
    /// 35 cells is about 280pt at the default 12pt SF Mono.
    static let maxReadableCharacterCount: CGFloat = 35

    /// One-column wrap cap shared by chat and Reader. Not viewport-derived.
    static var maxReadableColumnWidth: CGFloat {
        maxReadableCharacterCount * monoAdvanceWidth
    }

    static var monoAdvanceWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: AppFont.monoMedium]).width
    }

    /// Never shrink a column below its natural width unless that natural width
    /// exceeds `maxReadable`. There is no squeeze floor.
    static func clampedColumnWidths(naturalWidths: [CGFloat]) -> [CGFloat] {
        let cap = maxReadableColumnWidth
        return naturalWidths.map { min($0, cap) }
    }

    /// Grid mode depends only on content, never on available width or column count.
    static func needsGridMode(naturalWidths: [CGFloat]) -> Bool {
        let cap = maxReadableColumnWidth
        return naturalWidths.contains { $0 > cap }
    }
}
