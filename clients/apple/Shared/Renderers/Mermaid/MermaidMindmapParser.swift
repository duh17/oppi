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

    // MARK: - Public

    nonisolated static func parse(lines: [String]) -> MindmapDiagram {
        // Filter to non-empty lines, preserving original indentation.
        let entries: [(indent: Int, label: String, shape: MindmapNodeShape)] = lines.compactMap { line in
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            guard !stripped.isEmpty else { return nil }
            let indent = line.count - stripped.count
            let (label, shape) = parseNodeText(String(stripped))
            return (indent, label, shape)
        }

        guard let first = entries.first else {
            return .empty
        }

        // Build tree using a stack of (indent, accumulated node).
        let rootChildren = buildChildren(from: entries, startIndex: 1, parentIndent: first.indent)
        let root = MindmapNode(label: first.label, shape: first.shape, children: rootChildren)
        return MindmapDiagram(root: root)
    }

    // MARK: - Tree building

    /// Recursively build children for a parent at `parentIndent`.
    ///
    /// Scans `entries[startIndex...]` and groups consecutive lines that are deeper
    /// than `parentIndent` into child subtrees.
    private static func buildChildren(
        from entries: [(indent: Int, label: String, shape: MindmapNodeShape)],
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
            children.append(MindmapNode(label: entry.label, shape: entry.shape, children: subChildren))

            // Skip past all lines consumed by this child's subtree.
            i += 1 + countDescendants(from: entries, startIndex: i + 1, parentIndent: childIndent)
        }

        return children
    }

    /// Count how many consecutive entries starting at `startIndex` are deeper than `parentIndent`.
    private static func countDescendants(
        from entries: [(indent: Int, label: String, shape: MindmapNodeShape)],
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

    // MARK: - Shape parsing

    /// Parse the raw text of a node line into (label, shape).
    ///
    /// In Mermaid mindmap, the format is `id((label))` or `id[label]` etc.
    /// The id prefix (before the first delimiter) is optional.
    /// If no delimiters, the whole text is the label with `.default` shape.
    private static func parseNodeText(_ text: String) -> (String, MindmapNodeShape) {
        // Try to find shape delimiters after an optional id prefix.
        // Look for the first delimiter character that starts a shape.
        if let range = text.range(of: "(("), text.hasSuffix("))") {
            let inner = String(text[range.upperBound...].dropLast(2))
            return (inner, .circle)
        }

        // `((...))` — circle (no prefix)
        if text.hasPrefix("((") && text.hasSuffix("))") && text.count > 4 {
            let inner = String(text.dropFirst(2).dropLast(2))
            return (inner, .circle)
        }

        // `))...((` — bang/cloud
        if text.hasPrefix("))") && text.hasSuffix("((") && text.count > 4 {
            let inner = String(text.dropFirst(2).dropLast(2))
            return (inner, .bang)
        }

        // `)...(` — hexagon
        if text.hasPrefix(")") && text.hasSuffix("(") && text.count > 2
            && !text.hasPrefix("))") && !text.hasSuffix("((")
        {
            let inner = String(text.dropFirst(1).dropLast(1))
            return (inner, .hexagon)
        }

        // `(...)` — rounded (but not `((...))` which was already caught)
        if text.hasPrefix("(") && text.hasSuffix(")") && text.count > 2
            && !text.hasPrefix("((") && !text.hasSuffix("))")
        {
            let inner = String(text.dropFirst(1).dropLast(1))
            return (inner, .rounded)
        }

        // `[...]` or `id[...]` — square
        if let range = text.range(of: "["), text.hasSuffix("]") {
            let inner = String(text[range.upperBound...].dropLast(1))
            return (inner, .square)
        }

        // `id(...)` — rounded (not already caught by circle)
        if let range = text.range(of: "("), text.hasSuffix(")"),
           !text.hasSuffix("))") {
            let inner = String(text[range.upperBound...].dropLast(1))
            return (inner, .rounded)
        }

        // Default — plain text
        return (text, .default)
    }
}
