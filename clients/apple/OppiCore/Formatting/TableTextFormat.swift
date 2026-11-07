import Foundation

/// The two text forms of a table that can be copied.
enum TableCopyFormat: Equatable, Sendable, CaseIterable {
    case markdown
    case tsv
}

/// Plain-text forms of a table: what Copy as TSV and Copy as Markdown put on the
/// clipboard, and the TSV the full-screen table viewer parses back.
///
/// A table has `max(headers.count, first row's count)` columns, the rule the
/// markdown renderer uses: short rows are padded with empty cells, extra cells
/// are dropped.
enum TableTextFormat {
    /// Tab-separated rows, header first, no trailing newline. A cell never
    /// contains a tab or a line break (each becomes one space), so one row is one
    /// line. A cell that starts with `"` is quoted, which is how spreadsheets and
    /// `DelimitedTable.parse` tell a literal quote from the start of a quoted field.
    static func tsv(headers: [String], rows: [[String]]) -> String {
        let columns = columnCount(headers: headers, rows: rows)
        guard columns > 0 else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        for row in [headers] + rows {
            lines.append(
                (0 ..< columns)
                    .map { tsvCell($0 < row.count ? row[$0] : "", columns: columns) }
                    .joined(separator: "\t")
            )
        }
        return lines.joined(separator: "\n")
    }

    /// A GitHub-flavored Markdown table. `|` is escaped and line breaks become
    /// spaces, so each row stays on one line.
    static func markdown(headers: [String], rows: [[String]]) -> String {
        let columns = columnCount(headers: headers, rows: rows)
        guard columns > 0 else { return "" }
        func line(_ cells: [String]) -> String {
            "| " + (0 ..< columns)
                .map { markdownCell($0 < cells.count ? cells[$0] : "") }
                .joined(separator: " | ") + " |"
        }
        var lines = [line(headers), "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"]
        lines.append(contentsOf: rows.map(line))
        return lines.joined(separator: "\n")
    }

    static func columnCount(headers: [String], rows: [[String]]) -> Int {
        max(headers.count, rows.first?.count ?? 0)
    }

    private static func singleLine(_ text: String) -> String {
        guard text.contains(where: { $0 == "\t" || $0.isNewline }) else { return text }
        return String(text.map { $0 == "\t" || $0.isNewline ? " " : $0 })
    }

    private static func tsvCell(_ text: String, columns: Int) -> String {
        let cell = singleLine(text)
        // An empty one-column row would be a blank line, which parsers skip.
        if cell.isEmpty, columns == 1 { return "\"\"" }
        guard cell.first == "\"" else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func markdownCell(_ text: String) -> String {
        singleLine(text).replacingOccurrences(of: "|", with: "\\|")
    }
}

extension DelimitedTable {
    /// The displayed header and rows as TSV; see `TableTextFormat.tsv`.
    var tsvText: String { TableTextFormat.tsv(headers: headers, rows: rows) }

    /// The displayed header and rows as a Markdown table.
    var markdownText: String { TableTextFormat.markdown(headers: headers, rows: rows) }

    func copyText(_ format: TableCopyFormat) -> String {
        switch format {
        case .markdown: markdownText
        case .tsv: tsvText
        }
    }
}
