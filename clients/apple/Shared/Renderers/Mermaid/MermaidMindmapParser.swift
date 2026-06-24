import Foundation

/// Parser for Mermaid mindmap syntax.
///
/// Mindmaps use indentation to define tree structure:
/// ```
/// mindmap
///   root((Central Idea))
///     Branch A
///       Leaf 1
///       Leaf 2
///     Branch B
/// ```
///
/// The parser receives lines *after* the `mindmap` header (stripped by `MermaidParser`).
/// Each line's leading whitespace determines its depth. Children have strictly more
/// indentation than their parent. Inconsistent indentation is handled gracefully by
/// attaching the node to the nearest ancestor with less indent.
enum MermaidMindmapParser {

    struct Options: Equatable, Sendable {
        var layout: MindmapLayout = .default
    }

    private struct MindmapEntry {
        let indent: Int
        let label: String
        let shape: MindmapNodeShape
        var icon: String?
        var classes: [String]
    }

    // MARK: - Public

    nonisolated static func parse(lines: [String], options: Options = Options()) -> MindmapDiagram {
        // Join multi-line markdown strings: lines containing unclosed "`...
        // are joined with following lines until `"` is found.
        let joined = joinMultilineStrings(lines)

        // Filter to non-empty lines, preserving original indentation.
        var entries: [MindmapEntry] = []
        for line in joined {
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            guard !stripped.isEmpty else { continue }
            let strippedStr = String(stripped)

            if let icon = parseIconAnnotation(strippedStr) {
                if !entries.isEmpty {
                    entries[entries.count - 1].icon = icon
                }
                continue
            }

            if let classes = parseClassAnnotation(strippedStr) {
                if !entries.isEmpty {
                    entries[entries.count - 1].classes.append(contentsOf: classes)
                }
                continue
            }

            let indent = line.count - stripped.count
            let (label, shape) = parseNodeText(strippedStr)
            entries.append(MindmapEntry(
                indent: indent,
                label: label,
                shape: shape,
                icon: nil,
                classes: []
            ))
        }

        guard let first = entries.first else {
            return .empty
        }

        // Build tree using a stack of (indent, accumulated node).
        let rootChildren = buildChildren(from: entries, startIndex: 1, parentIndent: first.indent)
        let root = MindmapNode(
            label: first.label,
            shape: first.shape,
            children: rootChildren,
            icon: first.icon,
            classes: first.classes
        )
        return MindmapDiagram(root: root, layout: options.layout)
    }

    // MARK: - Tree building

    /// Recursively build children for a parent at `parentIndent`.
    ///
    /// Scans `entries[startIndex...]` and groups consecutive lines that are deeper
    /// than `parentIndent` into child subtrees.
    private static func buildChildren(
        from entries: [MindmapEntry],
        startIndex: Int,
        parentIndent: Int
    ) -> [MindmapNode] {
        var children: [MindmapNode] = []
        var i = startIndex

        while i < entries.count {
            let entry = entries[i]

            // If this line is at or before the parent's indent, we've left the subtree.
            guard entry.indent > parentIndent else { break }

            // This entry is a direct child. Collect its own children recursively.
            let childIndent = entry.indent
            let subChildren = buildChildren(from: entries, startIndex: i + 1, parentIndent: childIndent)
            children.append(MindmapNode(
                label: entry.label,
                shape: entry.shape,
                children: subChildren,
                icon: entry.icon,
                classes: entry.classes
            ))

            // Skip past all lines consumed by this child's subtree.
            i += 1 + countDescendants(from: entries, startIndex: i + 1, parentIndent: childIndent)
        }

        return children
    }

    /// Count how many consecutive entries starting at `startIndex` are deeper than `parentIndent`.
    private static func countDescendants(
        from entries: [MindmapEntry],
        startIndex: Int,
        parentIndent: Int
    ) -> Int {
        var count = 0
        var i = startIndex
        while i < entries.count, entries[i].indent > parentIndent {
            count += 1
            i += 1
        }
        return count
    }

    // MARK: - Icon and class annotations

    private static func parseIconAnnotation(_ text: String) -> String? {
        guard text.hasPrefix("::icon("), text.hasSuffix(")") else { return nil }
        let icon = text
            .dropFirst("::icon(".count)
            .dropLast()
            .trimmingCharacters(in: .whitespaces)
        return icon.isEmpty ? nil : icon
    }

    private static func parseClassAnnotation(_ text: String) -> [String]? {
        guard text.hasPrefix(":::") else { return nil }
        let classes = text
            .dropFirst(3)
            .split { $0.isWhitespace }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return classes.isEmpty ? nil : classes
    }

    // MARK: - Shape parsing

    /// Parse the raw text of a node line into (label, shape).
    ///
    /// In Mermaid mindmap, the format is `id((label))` or `id[label]` etc.
    /// The id prefix (before the first delimiter) is optional.
    /// If no delimiters, the whole text is the label with `.default` shape.
    /// Strip markdown string delimiters: "`text`" → text
    private static func stripMarkdownString(_ text: String) -> String {
        var s = text
        // Remove outer quotes if present
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        // Remove backtick delimiters
        if s.hasPrefix("`") && s.hasSuffix("`") && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Check if a label is a markdown string (starts with "`)
    private static func isMarkdownString(_ text: String) -> Bool {
        text.contains("\"`") && text.contains("`\"")
    }

    private static func parseNodeText(_ text: String) -> (String, MindmapNodeShape) {
        // Try to find shape delimiters after an optional id prefix.
        // Look for the first delimiter character that starts a shape.
        if let range = text.range(of: "(("), text.hasSuffix("))") {
            let inner = normalize(String(text[range.upperBound...].dropLast(2)))
            return (inner, .circle)
        }

        // `((...))` — circle (no prefix)
        if text.hasPrefix("((") && text.hasSuffix("))") && text.count > 4 {
            let inner = normalize(String(text.dropFirst(2).dropLast(2)))
            return (inner, .circle)
        }

        // `id))...((` — bang
        if let range = text.range(of: "))"), text.hasSuffix("((") {
            let inner = normalize(String(text[range.upperBound...].dropLast(2)))
            return (inner, .bang)
        }

        // `id)...(` — cloud
        if let range = text.range(of: ")"), text.hasSuffix("(") {
            let inner = normalize(String(text[range.upperBound...].dropLast(1)))
            return (inner, .cloud)
        }

        // `id{{...}}` — hexagon
        if let range = text.range(of: "{{"), text.hasSuffix("}}") {
            let inner = normalize(String(text[range.upperBound...].dropLast(2)))
            return (inner, .hexagon)
        }

        // `(...)` — rounded (but not `((...))` which was already caught)
        if text.hasPrefix("(") && text.hasSuffix(")") && text.count > 2
            && !text.hasPrefix("((") && !text.hasSuffix("))") {
            let inner = normalize(String(text.dropFirst(1).dropLast(1)))
            return (inner, .rounded)
        }

        // `[...]` or `id[...]` — square
        if let range = text.range(of: "["), text.hasSuffix("]") {
            var inner = String(text[range.upperBound...].dropLast(1))
            if isMarkdownString(inner) {
                inner = stripMarkdownString(inner)
            }
            return (normalize(inner), .square)
        }

        // `id(...)` — rounded (not already caught by circle)
        if let range = text.range(of: "("), text.hasSuffix(")"),
           !text.hasSuffix("))") {
            let inner = normalize(String(text[range.upperBound...].dropLast(1)))
            return (inner, .rounded)
        }

        // Default — plain text
        return (normalize(text), .default)
    }

    /// Join lines that contain unclosed markdown strings ("`...`").
    ///
    /// When a line contains `"\`` but not a closing `\`"`, subsequent lines
    /// are appended (with \n) until the closing delimiter is found.
    private static func joinMultilineStrings(_ lines: [String]) -> [String] {
        var result: [String] = []
        var accumulator: String?

        for line in lines {
            if let acc = accumulator {
                // We're in a multi-line string. Append this line.
                let joined = acc + "\n" + line
                if line.contains("`\"") {
                    // Closing delimiter found.
                    result.append(joined)
                    accumulator = nil
                } else {
                    accumulator = joined
                }
            } else if line.contains("\"`") && !line.contains("`\"") {
                // Opening delimiter without closing on same line.
                accumulator = line
            } else {
                result.append(line)
            }
        }
        // Flush unclosed accumulator.
        if let acc = accumulator {
            result.append(acc)
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        MermaidTextUtils.normalizeLabel(text)
    }
}
