import Foundation

/// Parser for Mermaid `sankey` / `sankey-beta` CSV body.
///
/// Spec: https://mermaid.js.org/syntax/sankey.html
///
/// Covered:
/// - 3-column CSV: source, target, value
/// - empty lines
/// - quoted commas
/// - escaped quotes (`""`)
/// - `nodeAlignment` / `nodeWidth` / `nodePadding` via options
///
/// Color themes (`linkColor`, mermaid `theme`) are ignored so they cannot
/// paint a diagram page.
enum MermaidSankeyParser {

    nonisolated static func parse(
        lines: [String],
        options: SankeyOptions = SankeyOptions()
    ) -> SankeyDiagram {
        var links: [SankeyLink] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("%%") { continue }
            let lower = line.lowercased()
            if lower == "sankey" || lower == "sankey-beta"
                || lower.hasPrefix("sankey ") || lower.hasPrefix("sankey-beta ") {
                continue
            }
            guard let row = parseCSVRow(line), row.count == 3 else { continue }
            let source = row[0]
            let target = row[1]
            guard !source.isEmpty, !target.isEmpty,
                  let value = Double(row[2]), value.isFinite, value > 0
            else { continue }
            links.append(SankeyLink(source: source, target: target, value: value))
        }

        return SankeyDiagram(links: links, options: options)
    }

    /// RFC 4180-ish: commas inside quotes, `""` as escaped quote.
    nonisolated static func parseCSVRow(_ line: String) -> [String]? {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if inQuotes {
                if character == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        if inQuotes { return nil }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    nonisolated static func alignment(from raw: String?) -> SankeyNodeAlignment {
        guard let raw else { return .justify }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "justify": return .justify
        case "center": return .center
        case "left": return .left
        case "right": return .right
        case "": return .justify
        default: return .unsupported(raw.trimmingCharacters(in: .whitespaces))
        }
    }
}
