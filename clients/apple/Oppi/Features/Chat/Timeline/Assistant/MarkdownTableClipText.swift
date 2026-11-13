import UIKit

/// A clip-mode table as one attributed string: tab stops align the columns, so
/// no cell wraps and a wide table pans sideways.
///
/// The string grows by rows. A streamed table appends the rows that arrived
/// instead of rebuilding every row, and the string is measured by a layout
/// manager that only lays out the text a tick changed. Building the whole table
/// at once and growing it to the same rows give the same string.
@MainActor
final class MarkdownTableClipText {
    /// A change to the string: replace `range` with `replacement`.
    struct Edit {
        let range: NSRange
        let replacement: NSAttributedString
    }

    /// Natural single-line width of each column; they set the tab stops.
    let columnWidths: [CGFloat]
    /// Identifies the palette the text is colored with.
    let paletteIdentity: ObjectIdentifier

    let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    ))

    private let fonts: TableInlineText.Fonts
    private var cellFont: UIFont { fonts.body }
    private let paragraph = NSMutableParagraphStyle()
    private let dimColor: UIColor
    private let cellColors: TableInlineText.Colors
    private let altRowBackground: UIColor
    /// The line break between rows. It carries the table font: a bare newline
    /// takes whatever default a text view fills in, so the string would depend
    /// on whether the view set it whole or grew it.
    private var newline: NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: cellFont])
    }
    /// UTF-16 offset where each body row's text (with its leading newline) starts.
    private var bodyRowStarts: [Int] = []

    init(headers: [[MarkdownInline]], columnWidths: [CGFloat], palette: ThemePalette, fonts: TableInlineText.Fonts) {
        self.columnWidths = columnWidths
        self.fonts = fonts
        paletteIdentity = ObjectIdentifier(palette.uiCache)
        dimColor = palette.ui.comment.withAlphaComponent(0.4)
        cellColors = TableInlineText.Colors(
            text: palette.ui.fg,
            link: palette.ui.blue,
            code: palette.ui.mdCode,
            codeBackground: palette.ui.bgHighlight,
            palette: palette
        )
        altRowBackground = palette.ui.bgHighlight.withAlphaComponent(0.45)

        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        container.lineFragmentPadding = 0

        guard !columnWidths.isEmpty else { return }

        // One tab stop per column at its right edge. After a cell, a \t moves
        // the cursor to the exact stop, so no space padding rounds off.
        let leadPadWidth = NativeTableBlockView.measuredTextWidth("  ", font: cellFont)
        let sepWidth = NativeTableBlockView.measuredTextWidth("  │  ", font: cellFont)
        // +1 buffer: when content exactly fills the column the cursor sits ON
        // the stop; a \t would then skip to the next one.
        let buffer: CGFloat = 1
        var tabStops: [NSTextTab] = []
        var position = leadPadWidth
        for (index, width) in columnWidths.enumerated() {
            position += width + buffer
            tabStops.append(NSTextTab(textAlignment: .left, location: position))
            if index < columnWidths.count - 1 { position += sepWidth }
        }
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 5
        paragraph.tabStops = tabStops

        // The trailing pad is as wide as the leading one.
        storage.append(headerAndSeparator(
            headers: headers,
            palette: palette,
            totalWidth: (tabStops.last?.location ?? 0) + leadPadWidth
        ))
    }

    var bodyRowCount: Int { bodyRowStarts.count }

    /// Size of the laid-out text. Lays out only what changed since the last call.
    var measuredSize: CGSize {
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).size
    }

    /// Keeps the header and the first `keptRows` body rows and swaps the rest
    /// for `rows[keptRows...]`. Returns the edit made to the string.
    @discardableResult
    func replaceRows(keeping keptRows: Int, with rows: [[[MarkdownInline]]]) -> Edit {
        guard !columnWidths.isEmpty else {
            return Edit(range: NSRange(location: 0, length: 0), replacement: NSAttributedString())
        }
        let kept = min(keptRows, bodyRowStarts.count)
        let start = kept < bodyRowStarts.count ? bodyRowStarts[kept] : storage.length
        let range = NSRange(location: start, length: storage.length - start)

        let replacement = NSMutableAttributedString()
        var starts = Array(bodyRowStarts.prefix(kept))
        for index in kept ..< rows.count {
            starts.append(start + replacement.length)
            replacement.append(bodyRow(rows[index], index: index))
        }
        storage.replaceCharacters(in: range, with: replacement)
        bodyRowStarts = starts
        return Edit(range: range, replacement: replacement)
    }

    // MARK: Rows

    private func headerAndSeparator(
        headers: [[MarkdownInline]],
        palette: ThemePalette,
        totalWidth: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let headerColor = palette.ui.cyan
        let headerStart = result.length
        let headerColors = TableInlineText.Colors(
            text: headerColor,
            link: cellColors.link,
            code: cellColors.code,
            codeBackground: cellColors.codeBackground,
            palette: palette
        )
        for (index, header) in headers.enumerated() {
            // Leading pad for the first column; tab-to-separator for the rest.
            if index == 0 {
                result.append(NSAttributedString(string: "  ", attributes: [
                    .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: paragraph,
                ]))
            }
            // Drawn as the grid draws it, so it is as wide as it was measured.
            let cellStart = result.length
            TableInlineText.appendCell(
                header,
                to: result,
                fonts: fonts,
                isHeader: true,
                colors: headerColors,
                paragraph: paragraph
            )
            // Selection reads the cell back from this, not the padding.
            result.addAttribute(
                TableSelectionText.cellAttribute,
                value: TableSelectionText.attributeValue(row: 0, column: index),
                range: NSRange(location: cellStart, length: result.length - cellStart)
            )
            if index < columnWidths.count - 1 {
                result.append(NSAttributedString(string: "\t  │  ", attributes: [
                    .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: paragraph,
                ]))
            }
        }
        // Trailing pad via tab stop.
        result.append(NSAttributedString(string: "\t  ", attributes: [
            .font: cellFont, .paragraphStyle: paragraph,
        ]))
        result.addAttribute(
            .backgroundColor,
            value: palette.ui.bgHighlight,
            range: NSRange(location: headerStart, length: result.length - headerStart)
        )

        // Separator line, exactly the table's total width: the dashes that fit,
        // with the remainder spread between them as kerning. The dash width is
        // measured unrounded; rounding it up left the rule a dash in nine short.
        let dashWidth = ("─" as NSString).size(withAttributes: [.font: cellFont]).width
        let separatorCharCount = max(1, Int(totalWidth / dashWidth))
        let kern = (totalWidth - CGFloat(separatorCharCount) * dashWidth) / CGFloat(separatorCharCount)
        // The separator has no tab stops so its dashes are not eaten by tabs.
        let separatorParagraph = NSMutableParagraphStyle()
        separatorParagraph.lineBreakMode = .byClipping
        separatorParagraph.lineSpacing = 5
        result.append(newline)
        result.append(NSAttributedString(
            string: String(repeating: "─", count: separatorCharCount),
            attributes: [
                .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: separatorParagraph, .kern: kern,
            ]
        ))
        return result
    }

    /// One body row, led by the newline that ends the row before it.
    private func bodyRow(_ row: [[MarkdownInline]], index rowIndex: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: newline)
        let rowStart = result.length
        let columnCount = columnWidths.count
        for index in 0 ..< columnCount {
            let inlines: [MarkdownInline] = index < row.count ? row[index] : [.text("")]
            if index == 0 {
                result.append(NSAttributedString(string: "  ", attributes: [
                    .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: paragraph,
                ]))
            }
            let cellStart = result.length
            TableInlineText.appendCell(
                inlines,
                to: result,
                fonts: fonts,
                isHeader: false,
                colors: cellColors,
                paragraph: paragraph
            )
            result.addAttribute(
                TableSelectionText.cellAttribute,
                value: TableSelectionText.attributeValue(row: rowIndex + 1, column: index),
                range: NSRange(location: cellStart, length: result.length - cellStart)
            )
            if index < columnCount - 1 {
                result.append(NSAttributedString(string: "\t  │  ", attributes: [
                    .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: paragraph,
                ]))
            }
        }
        // Trailing pad via tab stop.
        result.append(NSAttributedString(string: "\t  ", attributes: [
            .font: cellFont, .paragraphStyle: paragraph,
        ]))
        if rowIndex % 2 == 1 {
            // The stripe goes under the row, not over an inline code span's own background.
            let row = NSRange(location: rowStart, length: result.length - rowStart)
            result.enumerateAttribute(.backgroundColor, in: row) { value, range, _ in
                if value == nil { result.addAttribute(.backgroundColor, value: altRowBackground, range: range) }
            }
        }
        return result
    }
}
