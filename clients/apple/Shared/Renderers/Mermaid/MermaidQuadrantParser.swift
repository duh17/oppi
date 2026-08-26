import Foundation

/// Parser for Mermaid `quadrantChart` body syntax.
///
/// Spec: https://mermaid.js.org/syntax/quadrantChart.html
///
/// Covered:
/// - `title`
/// - `x-axis` left / `left --> right`
/// - `y-axis` bottom / `bottom --> top`
/// - `quadrant-1` … `quadrant-4`
/// - `Name: [x, y]` with 0...1 range stored raw
/// - `%%` comments and blank lines
///
/// Deferred: point radius/color/classDef styling.
enum MermaidQuadrantParser {

    nonisolated static func parse(lines: [String]) -> QuadrantChartDiagram {
        var title: String?
        var xAxisLeft: String?
        var xAxisRight: String?
        var yAxisBottom: String?
        var yAxisTop: String?
        var quadrant1: String?
        var quadrant2: String?
        var quadrant3: String?
        var quadrant4: String?
        var points: [QuadrantChartPoint] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("%%") { continue }

            if consumingKeyword(line, "quadrantChart") != nil
                || consumingKeyword(line, "quadrantchart") != nil {
                continue
            }

            if let value = consumingKeyword(line, "title") {
                title = parseTitleValue(value)
                continue
            }

            if let remainder = consumingKeyword(line, "x-axis") {
                let parts = splitArrow(remainder)
                xAxisLeft = parseTitleValue(parts.left)
                xAxisRight = parseTitleValue(parts.right)
                continue
            }

            if let remainder = consumingKeyword(line, "y-axis") {
                let parts = splitArrow(remainder)
                yAxisBottom = parseTitleValue(parts.left)
                yAxisTop = parseTitleValue(parts.right)
                continue
            }

            if let value = consumingKeyword(line, "quadrant-1") {
                quadrant1 = parseTitleValue(value)
                continue
            }
            if let value = consumingKeyword(line, "quadrant-2") {
                quadrant2 = parseTitleValue(value)
                continue
            }
            if let value = consumingKeyword(line, "quadrant-3") {
                quadrant3 = parseTitleValue(value)
                continue
            }
            if let value = consumingKeyword(line, "quadrant-4") {
                quadrant4 = parseTitleValue(value)
                continue
            }

            if let point = parsePoint(line) {
                points.append(point)
                continue
            }
        }

        return QuadrantChartDiagram(
            title: title,
            xAxisLeft: xAxisLeft,
            xAxisRight: xAxisRight,
            yAxisBottom: yAxisBottom,
            yAxisTop: yAxisTop,
            quadrant1: quadrant1,
            quadrant2: quadrant2,
            quadrant3: quadrant3,
            quadrant4: quadrant4,
            points: points
        )
    }

    private static func splitArrow(_ text: String) -> (left: String, right: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: "-->") else {
            return (trimmed, nil)
        }
        let left = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let right = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (left, right.isEmpty ? nil : right)
    }

    /// `Name: [x, y]` — optional class (`:::class`) is stripped.
    private static func parsePoint(_ line: String) -> QuadrantChartPoint? {
        guard let bracket = line.firstIndex(of: "[") else { return nil }
        let prefix = String(line[..<bracket]).trimmingCharacters(in: .whitespaces)
        guard let colon = prefix.lastIndex(of: ":") else { return nil }
        var name = String(prefix[..<colon]).trimmingCharacters(in: .whitespaces)
        if let classRange = name.range(of: ":::") {
            name = String(name[..<classRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        name = parseTitleValue(name) ?? name
        guard !name.isEmpty else { return nil }

        let after = String(line[bracket...])
        guard after.hasPrefix("["), let close = after.firstIndex(of: "]") else { return nil }
        let inner = String(after[after.index(after: after.startIndex)..<close])
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2,
              let x = Double(parts[0]), let y = Double(parts[1]),
              x.isFinite, y.isFinite
        else { return nil }
        return QuadrantChartPoint(name: name, x: x, y: y)
    }

    private static func consumingKeyword(_ text: String, _ keyword: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let key = keyword.lowercased()
        guard trimmed.lowercased().hasPrefix(key) else { return nil }
        if trimmed.count == key.count { return "" }
        let nextIndex = trimmed.index(trimmed.startIndex, offsetBy: key.count)
        let next = trimmed[nextIndex]
        if next.isWhitespace || next == "\"" || next == "'" {
            return String(trimmed[nextIndex...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func parseTitleValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if (trimmed.first == "\"" || trimmed.first == "'"),
           trimmed.count >= 2,
           trimmed.last == trimmed.first {
            return MermaidTextUtils.normalizeLabel(String(trimmed.dropFirst().dropLast()))
        }
        let normalized = MermaidTextUtils.normalizeLabel(trimmed)
        return normalized.isEmpty ? nil : normalized
    }
}
