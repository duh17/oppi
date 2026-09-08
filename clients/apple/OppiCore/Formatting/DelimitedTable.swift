import Foundation

/// Bounded read-only CSV/TSV table. Source bytes stay on the viewer plan.
struct DelimitedTable: Equatable, Sendable {
    struct Limits: Equatable, Sendable {
        static let display = Limits(maxRows: 500, maxColumns: 32, maxCellCharacters: 256)

        let maxRows: Int
        let maxColumns: Int
        let maxCellCharacters: Int
    }

    let headers: [String]
    let rows: [[String]]
    let columnCount: Int
    let totalRowCount: Int
    let totalColumnCount: Int
    let truncatedRows: Bool
    let truncatedColumns: Bool
    let truncatedCells: Bool

    var displayedRowCount: Int {
        if headers.isEmpty && rows.isEmpty { return 0 }
        return 1 + rows.count
    }

    static func parse(
        _ text: String,
        separator: Character,
        limits: Limits = .display
    ) -> DelimitedTable {
        var working = text
        if working.first == "\u{FEFF}" {
            working.removeFirst()
        }

        var stored: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        var atStartOfRecord = true
        var truncatedRows = false
        var truncatedCells = false
        var totalRowCount = 0
        var totalColumnCount = 0
        var index = working.startIndex

        func pushField() {
            currentRow.append(currentField)
            currentField.removeAll(keepingCapacity: true)
        }

        func pushRow() {
            totalRowCount += 1
            totalColumnCount = max(totalColumnCount, currentRow.count)
            if stored.count < limits.maxRows {
                stored.append(currentRow)
            } else {
                truncatedRows = true
            }
            currentRow.removeAll(keepingCapacity: true)
            atStartOfRecord = true
        }

        while index < working.endIndex {
            let character = working[index]
            let next = working.index(after: index)

            if inQuotes {
                if character == "\"" {
                    if next < working.endIndex, working[next] == "\"" {
                        currentField.append("\"")
                        index = working.index(after: next)
                        continue
                    }
                    inQuotes = false
                    index = next
                    continue
                }
                currentField.append(character)
                index = next
                continue
            }

            if character == "\"", currentField.isEmpty {
                inQuotes = true
                atStartOfRecord = false
                index = next
                continue
            }

            if character == separator {
                pushField()
                atStartOfRecord = false
                index = next
                continue
            }

            if character == "\n" || character == "\r" || character == "\r\n" {
                if atStartOfRecord && currentRow.isEmpty && currentField.isEmpty {
                    index = next
                    continue
                }
                pushField()
                pushRow()
                index = next
                continue
            }

            currentField.append(character)
            atStartOfRecord = false
            index = next
        }

        if inQuotes || !atStartOfRecord || !currentRow.isEmpty {
            pushField()
            pushRow()
        }

        let truncatedColumns = totalColumnCount > limits.maxColumns
        let columnCount = min(totalColumnCount, limits.maxColumns)

        func clipRow(_ row: [String]) -> [String] {
            var cells = Array(row.prefix(columnCount))
            if cells.count < columnCount {
                cells.append(contentsOf: repeatElement("", count: columnCount - cells.count))
            }
            return cells.map { cell in
                guard cell.count > limits.maxCellCharacters else { return cell }
                truncatedCells = true
                return String(cell.prefix(limits.maxCellCharacters))
            }
        }

        guard !stored.isEmpty else {
            return DelimitedTable(
                headers: [],
                rows: [],
                columnCount: 0,
                totalRowCount: 0,
                totalColumnCount: 0,
                truncatedRows: false,
                truncatedColumns: false,
                truncatedCells: truncatedCells
            )
        }

        let headers = clipRow(stored[0])
        let rows = stored.dropFirst().map(clipRow)
        return DelimitedTable(
            headers: headers,
            rows: rows,
            columnCount: columnCount,
            totalRowCount: totalRowCount,
            totalColumnCount: totalColumnCount,
            truncatedRows: truncatedRows,
            truncatedColumns: truncatedColumns,
            truncatedCells: truncatedCells
        )
    }
}

/// Routes CSV/TSV into the table/source document viewer without rewriting bytes.
struct DelimitedTableViewerPlan: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case csv
        case tsv

        var separator: Character {
            switch self {
            case .csv: ","
            case .tsv: "\t"
            }
        }

        var fileType: FileType {
            switch self {
            case .csv: .csv
            case .tsv: .tsv
            }
        }

        init?(path: String) {
            switch FileType.detect(from: path) {
            case .csv: self = .csv
            case .tsv: self = .tsv
            default: return nil
            }
        }

        init?(fileType: FileType) {
            switch fileType {
            case .csv: self = .csv
            case .tsv: self = .tsv
            default: return nil
            }
        }
    }

    let kind: Kind
    let source: String
    let table: DelimitedTable

    var truncationSummary: String? {
        var parts: [String] = []
        if table.truncatedRows {
            parts.append("Showing \(table.displayedRowCount) of \(table.totalRowCount) rows")
        }
        if table.truncatedColumns {
            parts.append("\(table.columnCount) of \(table.totalColumnCount) columns")
        }
        if table.truncatedCells {
            parts.append("long cells clipped")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    static func opening(
        path: String,
        text: String,
        limits: DelimitedTable.Limits = .display
    ) -> DelimitedTableViewerPlan? {
        guard let kind = Kind(path: path) else { return nil }
        return make(kind: kind, text: text, limits: limits)
    }

    static func opening(
        fileType: FileType,
        path: String?,
        text: String,
        limits: DelimitedTable.Limits = .display
    ) -> DelimitedTableViewerPlan? {
        if let path, let plan = opening(path: path, text: text, limits: limits) {
            return plan
        }
        guard let kind = Kind(fileType: fileType) else { return nil }
        return make(kind: kind, text: text, limits: limits)
    }

    static func resolved(
        path: String?,
        text: String,
        limits: DelimitedTable.Limits = .display
    ) -> DelimitedTableViewerPlan {
        if let plan = opening(
            fileType: FileType.detect(from: path, content: text),
            path: path,
            text: text,
            limits: limits
        ) {
            return plan
        }
        let kind: Kind = (path as NSString?)?.pathExtension.lowercased() == "tsv" ? .tsv : .csv
        return make(kind: kind, text: text, limits: limits)
    }

    private static func make(
        kind: Kind,
        text: String,
        limits: DelimitedTable.Limits
    ) -> DelimitedTableViewerPlan {
        DelimitedTableViewerPlan(
            kind: kind,
            source: text,
            table: DelimitedTable.parse(text, separator: kind.separator, limits: limits)
        )
    }
}
