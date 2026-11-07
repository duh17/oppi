import Foundation

/// Turns a selection in a table's drawn text back into table text.
///
/// The clip-mode table is one string of padded cells, tabs, and `│` separators.
/// Copying that as drawn pastes the padding and the separators. Every cell run
/// carries its position instead (`.tableCell`), so a selection copies as TSV: the
/// selected cells, tab-separated, one line per row.
enum TableSelectionText {
    /// Where a run of text sits in the table. Row 0 is the header.
    struct CellPosition: Hashable {
        let row: Int
        let column: Int
    }

    /// The cell a run of text belongs to. Separators and padding have none.
    static let cellAttribute = NSAttributedString.Key("oppi.tableCell")

    /// The `NSAttributedString` attribute value for one cell.
    static func attributeValue(row: Int, column: Int) -> NSValue {
        NSValue(cgPoint: CGPoint(x: column, y: row))
    }

    /// TSV for the cells inside `range`, or nil when no cell text is selected.
    ///
    /// A selection inside one cell is that text as is. A wider selection is TSV
    /// over the selected rows, with a column left empty where a row's selection
    /// starts after the others, so a column stays a column.
    static func text(in attributed: NSAttributedString, range: NSRange) -> String? {
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: attributed.length))
        guard bounded.length > 0 else { return nil }

        var order: [CellPosition] = []
        var pieces: [CellPosition: String] = [:]
        let string = attributed.string as NSString
        attributed.enumerateAttribute(cellAttribute, in: bounded, options: []) { value, runRange, _ in
            guard let point = (value as? NSValue)?.cgPointValue else { return }
            let position = CellPosition(row: Int(point.y), column: Int(point.x))
            if pieces[position] == nil { order.append(position) }
            pieces[position, default: ""] += string.substring(with: runRange)
        }
        guard let first = order.first else { return nil }
        if order.count == 1 { return pieces[first] }

        let rows = Array(Set(order.map(\.row))).sorted()
        let columns = order.map(\.column)
        guard let firstColumn = columns.min(), let lastColumn = columns.max() else { return nil }
        return rows.map { row in
            (firstColumn ... lastColumn)
                .map { pieces[CellPosition(row: row, column: $0)] ?? "" }
                .joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
