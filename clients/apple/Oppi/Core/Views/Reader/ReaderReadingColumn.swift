import UIKit

/// Where a full-screen Markdown or Org document's blocks sit across a wide
/// window: prose in a centered column about 75 characters wide, tables and code
/// blocks widened up to the full width (still centered) so they scroll sideways
/// only when the window itself is too narrow for them. A window narrower than
/// the column reads at its full width.
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
    func inset(for segment: FlatSegment, in available: CGFloat) -> CGFloat {
        inset(blockWidth: Self.naturalWidth(of: segment), in: available)
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
    private static func naturalWidth(of segment: FlatSegment) -> CGFloat? {
        switch segment {
        case .table(let headers, let rows):
            // Mirrors NativeTableBlockView's card: single-line columns, or the
            // wrap grid of capped columns once any column exceeds the cap.
            let metrics = NativeTableBlockView.measureNaturalColumns(headers: headers, rows: rows)
            guard MarkdownTableColumnLayout.needsGridMode(naturalWidths: metrics.columnWidths) else {
                return metrics.totalWidth
            }
            let columns = MarkdownTableColumnLayout.clampedColumnWidths(naturalWidths: metrics.columnWidths)
            let gaps = MarkdownTableColumnLayout.columnSpacing * CGFloat(max(0, columns.count - 1))
            return ceil(columns.reduce(0, +) + gaps + MarkdownTableColumnLayout.horizontalContentInset * 2)
        case .codeBlock(_, let code):
            let longestLine = code.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { max($0, $1.count) }
            return ceil(CGFloat(longestLine) * MarkdownTableColumnLayout.monoAdvanceWidth)
                + NativeCodeBlockView.codeHorizontalPadding
        default:
            return nil
        }
    }
}
