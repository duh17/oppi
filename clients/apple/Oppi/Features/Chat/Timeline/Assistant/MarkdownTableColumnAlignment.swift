import Foundation

/// Where a table column's cells sit in their width. The source's delimiter row
/// decides first (`:---`, `:---:`, `---:`). A column it leaves alone reads from
/// the trailing edge when it holds numbers, as in a spreadsheet, so its digits
/// stack by place value (cells draw tabular digits, `TableInlineText.Fonts`),
/// and from the leading edge otherwise. The header follows its column.
enum MarkdownTableColumnAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing

    /// Each column's alignment: the source's where it sets one, else `detected`.
    static func resolve(explicit: [MarkdownTableAlignment?], detected: [Self]) -> [Self] {
        detected.indices.map { column in
            switch column < explicit.count ? explicit[column] : nil {
            case .left?: .leading
            case .center?: .center
            case .right?: .trailing
            case nil: detected[column]
            }
        }
    }

    /// What one body cell says about its column.
    enum CellKind: Equatable, Sendable {
        /// Blank, or a placeholder for a missing value ("—", "n/a").
        case empty
        /// A number with an optional sign, currency, and short unit, maybe
        /// hedged: "0.35 ms", "1,702 ms", "99.95%", "$7.76", "−3", "4x",
        /// "about 2.0 ms".
        case number
        case text
    }

    private static let placeholders: Set<String> = ["—", "–", "-", "?", "…", "n/a", "na", "none", "tbd"]
    private static let prefixes: Set<Character> = ["~", "≈", "<", ">", "≤", "≥", "±", "+", "-", "−", "$", "€", "£", "¥"]
    private static let unitSymbols: Set<Character> = ["%", "/", "µ", "°", "×", "‰"]
    /// Words that hedge a number without making it prose.
    private static let hedges = ["about ", "approx. ", "approx ", "around ", "roughly ", "ca. ", "up to "]

    static func kind(of text: String) -> CellKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || placeholders.contains(trimmed.lowercased()) { return .empty }
        var rest = Substring(trimmed)
        if let hedge = hedges.first(where: { trimmed.lowercased().hasPrefix($0) }) {
            rest = rest.dropFirst(hedge.count)
        }
        while let first = rest.first, prefixes.contains(first) { rest = rest.dropFirst() }
        rest = rest.drop { $0 == " " }
        guard let first = rest.first, first.isASCII, first.isNumber else { return .text }
        rest = rest.drop { ($0.isASCII && $0.isNumber) || $0 == "," || $0 == "." }
        // An optional short unit, attached or after one space.
        if rest.first == " " { rest = rest.dropFirst() }
        guard rest.count <= 5,
              rest.allSatisfy({ ($0.isLetter && !$0.isNumber) || unitSymbols.contains($0) })
        else { return .text }
        return .number
    }

    /// The columns' alignments for a table's body rows, kept as rows arrive: a
    /// streamed table appends rows, so only the new ones are read.
    struct Detector {
        private var rowKinds: [[CellKind]] = []
        private var numbers: [Int] = []
        private var texts: [Int] = []

        /// Keeps the first `kept` rows read and reads `rows[kept...]`. A change in
        /// column count reads every row again.
        mutating func replaceRows(keeping kept: Int, with rows: [[[MarkdownInline]]], columnCount: Int) {
            var kept = min(kept, rowKinds.count)
            if numbers.count != columnCount {
                rowKinds = []
                numbers = Array(repeating: 0, count: columnCount)
                texts = numbers
                kept = 0
            }
            for row in rowKinds[kept...] { count(row, by: -1) }
            rowKinds.removeSubrange(kept...)
            for row in rows[min(kept, rows.count)...] {
                let kinds = (0 ..< columnCount).map { column in
                    column < row.count ? MarkdownTableColumnAlignment.kind(of: plainText(from: row[column])) : .empty
                }
                count(kinds, by: 1)
                rowKinds.append(kinds)
            }
        }

        private mutating func count(_ row: [CellKind], by step: Int) {
            for (column, kind) in row.enumerated() {
                switch kind {
                case .number: numbers[column] += step
                case .text: texts[column] += step
                case .empty: break
                }
            }
        }

        /// Trailing for a column with numbers and nothing but numbers or blanks.
        var alignments: [MarkdownTableColumnAlignment] {
            zip(numbers, texts).map { $0 > 0 && $1 == 0 ? .trailing : .leading }
        }
    }
}
