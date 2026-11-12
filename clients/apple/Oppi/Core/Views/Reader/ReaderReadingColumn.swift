import UIKit

/// Where a full-screen Markdown or Org document's blocks sit across a wide
/// window: prose in a centered column about 75 characters wide, tables and code
/// blocks widened up to the full width (still centered) so they scroll sideways
/// only when the window itself is too narrow for them. A window narrower than
/// the column reads at its full width.
///
/// Reader prose keeps this column rather than `ReadableContentWidth`: it is
/// pure prose at the reader's own text scale (40 em), and it widens tables and code.
///
/// The reader's scroll view stays full-bleed: touches in the margins scroll the
/// document, the indicator sits at the window edge, and content passes under the
/// bars edge to edge. Only each block is inset (`inset(for:in:)`).
struct ReaderReadingColumn: Equatable {
    /// 40 em of the reader's prose font: about 75 characters, and the width of
    /// `readableContentGuide` (672 pt) at the default 17 pt body. It follows the
    /// reader's own text size, which `readableContentGuide` would ignore.
    static let proseEms: CGFloat = 40

    let proseWidth: CGFloat

    init(proseFontSize: CGFloat) {
        proseWidth = ceil(proseFontSize * Self.proseEms)
    }

    /// The leading and trailing inset of `segment` in `available` width.
    @MainActor
    func inset(for segment: FlatSegment, in available: CGFloat) -> CGFloat {
        inset(blockWidth: naturalWidth(of: segment, in: available), in: available)
    }

    /// The leading and trailing inset of prose in `available` width.
    func proseInset(in available: CGFloat) -> CGFloat {
        inset(blockWidth: nil, in: available)
    }

    private func inset(blockWidth: CGFloat?, in available: CGFloat) -> CGFloat {
        let width = min(available, max(proseWidth, blockWidth ?? 0))
        return max(0, floor((available - width) / 2))
    }

    /// The width a wide block draws at without sideways scrolling; nil for a
    /// block that reads in the prose column.
    @MainActor
    private func naturalWidth(of segment: FlatSegment, in available: CGFloat) -> CGFloat? {
        switch segment {
        case .table(let headers, let rows):
            // Mirrors NativeTableBlockView's card: the width its plan draws at
            // in `available`, so a table that fits as a grid narrower than the
            // window centers instead of hugging the leading edge. A wrapping
            // table grows to the prose column, not the window: the table view,
            // laid out at that width, fills it and plans the same columns.
            let metrics = NativeTableBlockView.measureNaturalColumns(headers: headers, rows: rows)
            let plan = MarkdownTableColumnLayout.plan(
                naturalWidths: metrics.columnWidths,
                longestWordWidths: metrics.longestWordWidths,
                clipContentWidth: metrics.totalWidth,
                availableWidth: available,
                fillWidth: proseWidth,
                displayScale: 1
            )
            switch plan.presentation {
            case .clip:
                return metrics.totalWidth
            case .grid:
                return ceil(MarkdownTableColumnLayout.gridContentWidth(columnWidths: plan.columnWidths))
            }
        case .codeBlock(_, let code):
            let longestLine = code.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { max($0, $1.count) }
            // Code is monospaced: its width is its longest line in advances.
            let advance = ("0" as NSString).size(withAttributes: [.font: AppFont.monoMedium]).width
            return ceil(CGFloat(longestLine) * advance)
                + NativeCodeBlockView.codeHorizontalPadding
        default:
            return nil
        }
    }
}
