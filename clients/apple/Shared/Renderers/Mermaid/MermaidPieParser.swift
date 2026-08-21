import Foundation

// MARK: - Pie diagram types

/// AST for a Mermaid `pie` diagram.
///
/// Spec: https://mermaid.js.org/syntax/pie.html (tagged v11.17.0)
///
/// Syntax:
///   pie [showData] [title <title value>]
///   title <title value>
///   "<label>" : <positive value>
///
/// `donutHole`, `legendPosition`, and `highlightSlice` are v11.16.0+
/// frontmatter/config parameters and are intentionally not modeled here;
/// the renderer draws a solid pie with a side (or stacked) legend.
struct PieDiagram: Equatable, Sendable {
    let title: String?
    /// Slices in declaration order. Mermaid draws slices clockwise in the
    /// same order as the labels appear in source.
    let slices: [PieSlice]
    /// `showData` renders the actual data values after the legend text.
    let showData: Bool

    init(title: String?, slices: [PieSlice], showData: Bool) {
        self.title = title
        self.slices = slices
        self.showData = showData
    }

    static let empty = Self(title: nil, slices: [], showData: false)
}

struct PieSlice: Equatable, Sendable {
    let label: String
    /// Raw positive numeric value from source. The renderer derives
    /// percentages from the slice-value total.
    let value: Double

    init(label: String, value: Double) {
        self.label = label
        self.value = value
    }
}

// MARK: - Parser

/// Parser for Mermaid `pie` chart syntax.
///
/// Accepts the body after the `pie` header, but is also tolerant of a
/// leading `pie` / `pie showData` / `pie title ...` line so it can be
/// called directly from tests before the shared dispatcher is wired.
///
/// Tolerates:
/// - `%%` comments and blank lines
/// - optional `title` (quoted or unquoted), including on the `pie` line
/// - `"label" : value` and bare `label : value`
/// - quoted labels that contain colons (`"HTTP: 5xx" : 10`)
/// - non-positive or non-numeric values: skipped without crashing, since
///   the spec says pie values must be positive and negatives are an error
///   upstream — we recover by dropping the slice.
enum MermaidPieParser {

    nonisolated static func parse(lines: [String]) -> PieDiagram {
        var title: String?
        var slices: [PieSlice] = []
        var showData = false

        var seenHeader = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // `%%` comments.
            if line.hasPrefix("%%") { continue }

            let lower = line.lowercased()

            // First `pie` line. Official examples put `showData` and/or
            // `title ...` on this same line:
            //   pie title Pets adopted by volunteers
            //   pie showData title ...
            if !seenHeader && lower.hasPrefix("pie") {
                seenHeader = true
                var remainder = String(line.dropFirst("pie".count))
                    .trimmingCharacters(in: .whitespaces)
                if let afterShowData = consumingKeyword(remainder, "showData") {
                    showData = true
                    remainder = afterShowData
                }
                if let titleValue = consumingKeyword(remainder, "title") {
                    title = MermaidTextUtils.normalizeLabel(titleValue)
                }
                continue
            }

            // A bare `showData` line in the body is also accepted.
            if lower == "showdata" {
                showData = true
                continue
            }

            // `title <value>` — value may be quoted.
            if let value = consumingKeyword(line, "title") {
                title = MermaidTextUtils.normalizeLabel(value)
                continue
            }

            // Dataset row: `<label> : <value>`.
            if let slice = parseSlice(line) {
                slices.append(slice)
                continue
            }

            // Unknown line: skip rather than crash. The shared dispatcher
            // only feeds us `pie` bodies, so this is defensive.
            continue
        }

        return PieDiagram(title: title, slices: slices, showData: showData)
    }

    /// Parse a single `"label" : value` (or bare `label : value`) row.
    ///
    /// Quoted labels may contain colons. The separator is the first colon
    /// after the closing quote, not the first colon in the line.
    private static func parseSlice(_ line: String) -> PieSlice? {
        guard let parts = splitLabelAndValue(line) else { return nil }

        let labelPart = parts.label
        let valuePart = parts.value

        // Label: prefer the quoted form; fall back to a bare token so a
        // missing quote does not drop the slice entirely.
        let label: String
        if isDoubleQuoted(labelPart) {
            let inner = String(labelPart.dropFirst().dropLast())
            label = MermaidTextUtils.normalizeLabel(inner)
        } else if isSingleQuoted(labelPart) {
            let inner = String(labelPart.dropFirst().dropLast())
            label = MermaidTextUtils.normalizeLabel(inner)
        } else {
            label = MermaidTextUtils.normalizeLabel(labelPart)
        }
        guard !label.isEmpty else { return nil }

        // Value: positive numeric, up to two decimals per spec. We accept
        // any Double parse and let the renderer/total derive the share.
        guard let value = Double(valuePart) else { return nil }
        // Spec: values must be positive numbers greater than zero. Skip
        // non-positive values without crashing.
        guard value.isFinite, value > 0 else { return nil }

        return PieSlice(label: label, value: value)
    }

    /// Split `"label" : value` after the closing quote so inner colons
    /// stay inside the label. Bare rows still split on the first colon.
    private static func splitLabelAndValue(_ line: String) -> (label: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            guard let close = indexOfClosingQuote(in: trimmed, quote: quote) else {
                return nil
            }
            let afterQuote = trimmed[trimmed.index(after: close)...]
            guard let colon = afterQuote.firstIndex(of: ":") else { return nil }
            let label = String(trimmed[...close]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            return (label, value)
        }

        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let label = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (label, value)
    }

    /// Index of the matching closer, skipping `\"` / `\'` escapes.
    private static func indexOfClosingQuote(in text: String, quote: Character) -> String.Index? {
        var index = text.index(after: text.startIndex)
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// If `text` starts with `keyword` as a whole token, return the rest.
    /// Allows `title"Quoted"` (quote immediately after the keyword).
    private static func consumingKeyword(_ text: String, _ keyword: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let key = keyword.lowercased()
        guard trimmed.lowercased().hasPrefix(key) else { return nil }
        if trimmed.count == key.count { return "" }
        let nextIndex = trimmed.index(trimmed.startIndex, offsetBy: key.count)
        let next = trimmed[nextIndex]
        if next.isWhitespace {
            return String(trimmed[nextIndex...]).trimmingCharacters(in: .whitespaces)
        }
        if next == "\"" || next == "'" {
            return String(trimmed[nextIndex...])
        }
        return nil
    }

    private static func isDoubleQuoted(_ s: String) -> Bool {
        s.count >= 2 && s.first == "\"" && s.last == "\""
    }

    private static func isSingleQuoted(_ s: String) -> Bool {
        s.count >= 2 && s.first == "'" && s.last == "'"
    }
}
