import UIKit

/// Colors and fonts a wrap grid is drawn with.
///
/// Colors are resolved, so the grid can be drawn off the main thread and two
/// conversions of the same palette compare equal; a dynamic color would compare
/// by provider identity.
struct MarkdownTableGridStyle: Equatable, @unchecked Sendable {
    let headerBackground: UIColor
    let zebraBackground: UIColor
    let separator: UIColor
    let headerText: UIColor
    let bodyText: UIColor
    let link: UIColor
    let code: UIColor
    let fonts: TableInlineText.Fonts
    /// What the grid shows under a cell, composited over the card it sits on: an
    /// opaque color a view can paint to cover the drawn cell exactly.
    private let plainCellBackground: UIColor
    private let headerCellBackground: UIColor
    private let zebraCellBackground: UIColor

    init(palette: ThemePalette, traits: UITraitCollection, fonts: TableInlineText.Fonts) {
        let highlight = palette.ui.bgHighlight.resolvedColor(with: traits)
        headerBackground = highlight
        zebraBackground = highlight.withAlphaComponent(0.45)
        separator = palette.ui.comment.resolvedColor(with: traits).withAlphaComponent(0.25)
        headerText = palette.ui.cyan.resolvedColor(with: traits)
        bodyText = palette.ui.fg.resolvedColor(with: traits)
        link = palette.ui.blue.resolvedColor(with: traits)
        code = palette.ui.mdCode.resolvedColor(with: traits)
        self.fonts = fonts
        let card = palette.ui.bgDark.resolvedColor(with: traits)
        plainCellBackground = card
        headerCellBackground = Self.composite(highlight, over: card)
        zebraCellBackground = Self.composite(highlight.withAlphaComponent(0.45), over: card)
    }

    /// The opaque color behind row `row`'s text, as drawn by the grid: row 0 is
    /// the header, then body rows alternate plain and striped.
    func cellBackground(row: Int) -> UIColor {
        if row == 0 { return headerCellBackground }
        return (row - 1) % 2 == 1 ? zebraCellBackground : plainCellBackground
    }

    private struct RGBA {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        init(_ color: UIColor) {
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
        }
    }

    private static func composite(_ color: UIColor, over base: UIColor) -> UIColor {
        let top = RGBA(color)
        let bottom = RGBA(base)
        return UIColor(
            red: top.r * top.a + bottom.r * (1 - top.a),
            green: top.g * top.a + bottom.g * (1 - top.a),
            blue: top.b * top.a + bottom.b * (1 - top.a),
            alpha: 1
        )
    }

    var cellColors: TableInlineText.Colors {
        TableInlineText.Colors(text: bodyText, link: link, code: code, codeBackground: headerBackground)
    }

    var headerColors: TableInlineText.Colors {
        TableInlineText.Colors(text: headerText, link: link, code: code, codeBackground: headerBackground)
    }
}

/// Geometry and text of a wrap-grid table, computed once and drawn by
/// `MarkdownTableGridView` in a single pass.
///
/// Row 0 is the header; body row `i` is row `i + 1`. A hairline separator sits
/// between them. Every row is as tall as its tallest cell at the column's
/// pinned width, rounded up to the pixel grid so summed rounding can only leave
/// a sliver of slack. A streamed table grows a row at a time, so rows can be
/// dropped from the end and appended without touching the rows before them.
struct MarkdownTableGridLayout: @unchecked Sendable {
    /// Space above the header and below the last row.
    static let verticalPadding: CGFloat = 6
    /// Space above and below a cell's text.
    static let cellVerticalInset: CGFloat = 5
    /// How a cell's text is measured and drawn. The body font has leading (the
    /// system font's is about 1.7pt at 17pt), and the text view mounted on a
    /// touched cell is TextKit 2, which adds it to every line; measuring and
    /// drawing without it would make that view taller than its row.
    static let cellDrawingOptions: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    let columnWidths: [CGFloat]
    let style: MarkdownTableGridStyle
    let scale: CGFloat
    let separatorHeight: CGFloat
    /// Left edge of each column.
    let columnOrigins: [CGFloat]
    /// `cells[row][column]`, row 0 the header.
    private(set) var cells: [[NSAttributedString]] = []
    /// What the grid draws: `cells` without `.link`. String drawing paints a
    /// link run in the system link color over the run's own color, while the
    /// text view mounted on a touched cell paints it in the theme's. A cell
    /// without a link is the same object as in `cells`.
    private(set) var drawnCells: [[NSAttributedString]] = []
    private(set) var rowHeights: [CGFloat] = []
    /// Top edge of each row. The separator occupies the gap after row 0.
    private(set) var rowOrigins: [CGFloat] = []

    @MainActor
    init(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]],
        columnWidths: [CGFloat],
        style: MarkdownTableGridStyle,
        scale: CGFloat
    ) {
        self.columnWidths = columnWidths
        self.style = style
        self.scale = max(scale, 1)
        separatorHeight = 1 / max(scale, 1)

        var origins: [CGFloat] = []
        var x = MarkdownTableColumnLayout.horizontalContentInset
        for width in columnWidths {
            origins.append(x)
            x += width + MarkdownTableColumnLayout.columnSpacing
        }
        columnOrigins = origins

        appendRow(headers, isHeader: true)
        for row in rows {
            appendRow(row, isHeader: false)
        }
    }

    var bodyRowCount: Int { max(0, cells.count - 1) }

    /// Width of the columns and the gaps between them.
    var gridWidth: CGFloat {
        columnWidths.reduce(0, +)
            + MarkdownTableColumnLayout.columnSpacing * CGFloat(max(0, columnWidths.count - 1))
    }

    var contentWidth: CGFloat {
        gridWidth + MarkdownTableColumnLayout.horizontalContentInset * 2
    }

    /// Height of the whole table, padding included.
    var contentHeight: CGFloat {
        guard let lastOrigin = rowOrigins.last, let lastHeight = rowHeights.last else { return 0 }
        // A header-only table still shows the separator under the header.
        let end = cells.count == 1 ? lastOrigin + lastHeight + separatorHeight : lastOrigin + lastHeight
        return end + Self.verticalPadding
    }

    /// Y of the separator line.
    var separatorOrigin: CGFloat {
        (rowOrigins.first ?? Self.verticalPadding) + (rowHeights.first ?? 0)
    }

    /// Keeps the header and the first `keptRows` body rows, then builds the rest
    /// from `rows`. `rows` must agree with the kept rows.
    @MainActor
    mutating func replaceBodyRows(keeping keptRows: Int, with rows: [[[MarkdownInline]]]) {
        let keptViews = min(cells.count, 1 + keptRows)
        cells.removeSubrange(keptViews...)
        drawnCells.removeSubrange(keptViews...)
        rowHeights.removeSubrange(keptViews...)
        rowOrigins.removeSubrange(keptViews...)
        for row in rows[min(keptRows, rows.count)...] {
            appendRow(row, isHeader: false)
        }
    }

    @MainActor
    private mutating func appendRow(_ inlines: [[MarkdownInline]], isHeader: Bool) {
        var rowCells: [NSAttributedString] = []
        var drawnRow: [NSAttributedString] = []
        rowCells.reserveCapacity(columnWidths.count)
        drawnRow.reserveCapacity(columnWidths.count)
        var tallest: CGFloat = 0
        for (column, width) in columnWidths.enumerated() {
            let cell = column < inlines.count ? inlines[column] : [.text("")]
            let text = Self.cellText(cell, isHeader: isHeader, style: style)
            rowCells.append(text)
            drawnRow.append(Self.withoutLinks(text))
            tallest = max(tallest, Self.cellHeight(text, width: width))
        }
        // Round each row up to the pixel grid.
        let height = ceil(tallest * scale) / scale
        let origin: CGFloat
        if let lastOrigin = rowOrigins.last, let lastHeight = rowHeights.last {
            origin = lastOrigin + lastHeight + (cells.count == 1 ? separatorHeight : 0)
        } else {
            origin = Self.verticalPadding
        }
        cells.append(rowCells)
        drawnCells.append(drawnRow)
        rowHeights.append(height)
        rowOrigins.append(origin)
    }

    // MARK: Cell text

    @MainActor
    static func cellParagraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        return paragraph
    }

    @MainActor
    static func cellText(
        _ inlines: [MarkdownInline],
        isHeader: Bool,
        style: MarkdownTableGridStyle
    ) -> NSAttributedString {
        let colors = isHeader ? style.headerColors : style.cellColors
        let paragraph = cellParagraphStyle()
        let result = NSMutableAttributedString()
        TableInlineText.appendCell(
            inlines,
            to: result,
            fonts: style.fonts,
            isHeader: isHeader,
            colors: colors,
            paragraph: paragraph
        )
        if result.length == 0 {
            result.append(NSAttributedString(string: " ", attributes: [
                .font: isHeader ? style.fonts.bold : style.fonts.body,
                .foregroundColor: colors.text,
                .paragraphStyle: paragraph,
            ]))
        }
        return result
    }

    private static func withoutLinks(_ text: NSAttributedString) -> NSAttributedString {
        let range = NSRange(location: 0, length: text.length)
        var hasLink = false
        text.enumerateAttribute(.link, in: range) { value, _, stop in
            if value != nil {
                hasLink = true
                stop.pointee = true
            }
        }
        guard hasLink else { return text }
        let drawn = NSMutableAttributedString(attributedString: text)
        drawn.removeAttribute(.link, range: range)
        return drawn
    }

    @MainActor
    private static func cellHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let bounds = text.boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: cellDrawingOptions,
            context: nil
        )
        return ceil(bounds.height) + cellVerticalInset * 2
    }

    // MARK: Geometry queries

    func cellFrame(row: Int, column: Int) -> CGRect {
        CGRect(
            x: columnOrigins[column],
            y: rowOrigins[row],
            width: columnWidths[column],
            height: rowHeights[row]
        )
    }

    /// Rows whose vertical extent meets `[minY, maxY)`.
    func rows(intersecting minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
        guard !cells.isEmpty, maxY > minY else { return 0 ..< 0 }
        // First row whose bottom edge is below minY.
        var low = 0
        var high = cells.count
        while low < high {
            let mid = (low + high) / 2
            if rowOrigins[mid] + rowHeights[mid] <= minY { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < cells.count, rowOrigins[end] < maxY { end += 1 }
        return low ..< end
    }

    /// Columns whose horizontal extent meets `[minX, maxX)`.
    func columns(intersecting minX: CGFloat, _ maxX: CGFloat) -> Range<Int> {
        var first: Int?
        var end = 0
        for column in columnWidths.indices
        where columnOrigins[column] + columnWidths[column] > minX && columnOrigins[column] < maxX {
            if first == nil { first = column }
            end = column + 1
        }
        return (first ?? 0) ..< end
    }

    func cell(at point: CGPoint) -> (row: Int, column: Int)? {
        let rows = rows(intersecting: point.y, point.y + 0.001)
        guard let row = rows.first else { return nil }
        let columns = columns(intersecting: point.x, point.x + 0.001)
        guard let column = columns.first else { return nil }
        return (row, column)
    }
}
