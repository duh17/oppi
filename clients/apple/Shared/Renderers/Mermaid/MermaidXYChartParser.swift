import Foundation

/// Parser for Mermaid `xychart` / `xychart-beta` body syntax.
///
/// Spec: https://mermaid.js.org/syntax/xyChart.html
///
/// Accepts the body after the header, and is also tolerant of a leading
/// `xychart` / `xychart-beta` line so tests can call it directly.
///
/// Covered:
/// - `title` (quoted or unquoted, including spaces / parentheses)
/// - categorical `x-axis` with optional title
/// - numeric `x-axis` `min --> max`
/// - numeric `y-axis` title + optional `min --> max`
/// - `bar` / `line` with optional series name
/// - `%%` comments and blank lines
///
/// Deferred: YAML theme/config, `horizontal` orientation, bar data labels,
/// accessibility titles, and other missing diagram types.
enum MermaidXYChartParser {

    nonisolated static func parse(lines: [String]) -> XYChartDiagram {
        var title: String?
        var xAxis = XYChartXAxis.categorical(title: nil, categories: [])
        var yAxis = XYChartYAxis(title: nil, min: nil, max: nil)
        var series: [XYChartSeries] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("%%") { continue }

            if consumingKeyword(line, "xychart-beta") != nil
                || consumingKeyword(line, "xychart") != nil
            {
                // Orientation (`horizontal` / `vertical`) is out of scope.
                continue
            }

            if let value = consumingKeyword(line, "title") {
                title = parseTitleValue(value)
                continue
            }

            if let remainder = consumingKeyword(line, "x-axis") {
                xAxis = parseXAxis(remainder)
                continue
            }

            if let remainder = consumingKeyword(line, "y-axis") {
                yAxis = parseYAxis(remainder)
                continue
            }

            if let remainder = consumingKeyword(line, "bar"),
               let parsed = parseSeries(remainder, kind: .bar)
            {
                series.append(parsed)
                continue
            }

            if let remainder = consumingKeyword(line, "line"),
               let parsed = parseSeries(remainder, kind: .line)
            {
                series.append(parsed)
                continue
            }
        }

        return XYChartDiagram(title: title, xAxis: xAxis, yAxis: yAxis, series: series)
    }

    // MARK: - Axis

    private static func parseXAxis(_ remainder: String) -> XYChartXAxis {
        let parsed = parseAxisRemainder(remainder)
        if let categories = parsed.array {
            return .categorical(title: parsed.title, categories: categories)
        }
        if let min = parsed.min, let max = parsed.max {
            return .numeric(title: parsed.title, min: min, max: max)
        }
        return .categorical(title: parsed.title, categories: [])
    }

    private static func parseYAxis(_ remainder: String) -> XYChartYAxis {
        let parsed = parseAxisRemainder(remainder)
        return XYChartYAxis(title: parsed.title, min: parsed.min, max: parsed.max)
    }

    private struct AxisParts {
        var title: String?
        var array: [String]?
        var min: Double?
        var max: Double?
    }

    /// Split an axis remainder into optional title, `[categories]`, and `min --> max`.
    private static func parseAxisRemainder(_ remainder: String) -> AxisParts {
        var rest = remainder.trimmingCharacters(in: .whitespaces)
        var parts = AxisParts()
        guard !rest.isEmpty else { return parts }

        if rest.hasPrefix("[") {
            if let (items, leftover) = parseBracketList(rest) {
                parts.array = items
                rest = leftover
            }
        } else if let (quoted, leftover) = parseQuotedPrefix(rest) {
            parts.title = quoted
            rest = leftover
        }

        if parts.array == nil, let bracket = rest.firstIndex(of: "[") {
            if bracket > rest.startIndex, parts.title == nil {
                parts.title = parseTitleValue(String(rest[..<bracket]))
            }
            if let (items, leftover) = parseBracketList(String(rest[bracket...])) {
                parts.array = items
                rest = leftover
            }
        }

        if let range = parseTrailingRange(rest) {
            if parts.title == nil {
                parts.title = range.leadingTitle
            } else if let extra = range.leadingTitle {
                parts.title = extra
            }
            parts.min = range.min
            parts.max = range.max
        } else if parts.title == nil {
            parts.title = parseTitleValue(rest)
        }

        return parts
    }

    // MARK: - Series

    private static func parseSeries(_ remainder: String, kind: XYChartSeriesKind) -> XYChartSeries? {
        var rest = remainder.trimmingCharacters(in: .whitespaces)
        var name: String?

        if let (quoted, leftover) = parseQuotedPrefix(rest) {
            name = quoted
            rest = leftover
        } else if let bracket = rest.firstIndex(of: "["), bracket > rest.startIndex {
            let rawName = String(rest[..<bracket]).trimmingCharacters(in: .whitespaces)
            name = parseTitleValue(rawName)
            rest = String(rest[bracket...])
        }

        guard let (items, _) = parseBracketList(rest) else { return nil }
        let values = items.compactMap { parseLeadingNumber($0) }
        return XYChartSeries(kind: kind, name: name, values: values)
    }

    // MARK: - Tokens

    /// If `text` starts with `keyword` as a whole token, return the rest.
    /// Allows `[` or a quote immediately after the keyword.
    private static func consumingKeyword(_ text: String, _ keyword: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let key = keyword.lowercased()
        guard trimmed.lowercased().hasPrefix(key) else { return nil }
        if trimmed.count == key.count { return "" }
        let nextIndex = trimmed.index(trimmed.startIndex, offsetBy: key.count)
        let next = trimmed[nextIndex]
        if next.isWhitespace || next == "\"" || next == "'" || next == "[" {
            return String(trimmed[nextIndex...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func parseTitleValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let (quoted, leftover) = parseQuotedPrefix(trimmed), leftover.isEmpty {
            return quoted
        }
        let normalized = MermaidTextUtils.normalizeLabel(trimmed)
        return normalized.isEmpty ? nil : normalized
    }

    /// Leading `"..."` or `'...'`, with leftover trimmed.
    private static func parseQuotedPrefix(_ text: String) -> (String, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else { return nil }
        guard let close = indexOfClosingQuote(in: trimmed, quote: quote) else { return nil }
        let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        let leftover = String(trimmed[trimmed.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        let title = MermaidTextUtils.normalizeLabel(inner)
        return (title, leftover)
    }

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

    /// Parse `[a, "b c", 3]` and return items plus leftover after `]`.
    private static func parseBracketList(_ text: String) -> (items: [String], leftover: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var index = trimmed.index(after: trimmed.startIndex)
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if escaped {
                current.append(character)
                escaped = false
                index = trimmed.index(after: index)
                continue
            }
            if character == "\\" && quote != nil {
                escaped = true
                index = trimmed.index(after: index)
                continue
            }
            if let active = quote {
                if character == active {
                    quote = nil
                }
                current.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                items.append(normalizeListItem(current))
                current = ""
            } else if character == "]" {
                items.append(normalizeListItem(current))
                let leftover = String(trimmed[trimmed.index(after: index)...])
                    .trimmingCharacters(in: .whitespaces)
                return (items.filter { !$0.isEmpty }, leftover)
            } else {
                current.append(character)
            }
            index = trimmed.index(after: index)
        }
        return nil
    }

    private static func normalizeListItem(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let (quoted, leftover) = parseQuotedPrefix(trimmed), leftover.isEmpty {
            return quoted
        }
        return MermaidTextUtils.normalizeLabel(trimmed)
    }

    /// `optional title 0 --> 10` at the end of an axis remainder.
    private static func parseTrailingRange(
        _ text: String
    ) -> (leadingTitle: String?, min: Double, max: Double)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let pattern = #"^(?:(.+?)\s+)?([+-]?(?:\d+(?:\.\d+)?|\.\d+))\s*-->\s*([+-]?(?:\d+(?:\.\d+)?|\.\d+))\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range) else { return nil }

        func group(_ index: Int) -> String? {
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound, let swift = Range(nsRange, in: trimmed) else {
                return nil
            }
            let value = String(trimmed[swift]).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        guard let minText = group(2), let maxText = group(3),
              let min = parseNumber(minText), let max = parseNumber(maxText)
        else { return nil }
        return (parseTitleValue(group(1) ?? ""), min, max)
    }

    /// First numeric token in a list item (`1 "one"` → 1).
    private static func parseLeadingNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            return nil
        }
        let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
        return parseNumber(token)
    }

    /// Accept `+1.3`, `.6`, `-.34`, and ordinary decimals.
    nonisolated static func parseNumber(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("+") {
            text = String(text.dropFirst())
        }
        if text.hasPrefix(".") {
            text = "0" + text
        } else if text.hasPrefix("-.") {
            text = "-0" + text.dropFirst()
        }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }
}
