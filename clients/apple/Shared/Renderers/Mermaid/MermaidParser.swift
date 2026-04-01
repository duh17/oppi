import Foundation

/// Line-oriented parser for Mermaid diagram source.
///
/// Detects diagram type from the first non-empty, non-comment line,
/// then dispatches to per-type parsing. Conforms to `DocumentParser` so
/// it can be benchmarked and tested with `RendererTestSupport`.
///
/// Thread-safe — `nonisolated` and `Sendable`.
struct MermaidParser: DocumentParser, Sendable {

    nonisolated func parse(_ source: String) -> MermaidDiagram {
        let lines = source.components(separatedBy: .newlines)
        let stripped = lines.map { stripComment($0) }

        // Find first non-blank line to detect diagram type.
        guard let firstIndex = stripped.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let header = parseHeader(stripped[firstIndex].trimmingCharacters(in: .whitespaces))
        else {
            return .unsupported(type: "unknown")
        }

        switch header.type {
        case .flowchart:
            let body = Array(stripped[(firstIndex + 1)...])
            let diagram = parseFlowchart(direction: header.direction ?? .TD, lines: body)
            return .flowchart(diagram)
        case .sequence:
            let body = Array(stripped[(firstIndex + 1)...])
            let diagram = parseSequence(lines: body)
            return .sequence(diagram)
        case .gantt:
            let body = Array(stripped[(firstIndex + 1)...])
            let diagram = MermaidGanttParser.parse(lines: body)
            return .gantt(diagram)
        case .mindmap:
            let body = Array(stripped[(firstIndex + 1)...])
            let diagram = MermaidMindmapParser.parse(lines: body)
            return .mindmap(diagram)
        case .unknown(let name):
            return .unsupported(type: name)
        }
    }

    // MARK: - Header parsing

    private enum DiagramType {
        case flowchart
        case sequence
        case gantt
        case mindmap
        case unknown(String)
    }

    private struct Header {
        let type: DiagramType
        let direction: FlowDirection?
    }

    private func parseHeader(_ line: String) -> Header? {
        let tokens = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let keyword = tokens.first?.lowercased() else { return nil }

        switch keyword {
        case "flowchart", "graph":
            let dir: FlowDirection?
            if tokens.count > 1, let d = FlowDirection(rawValue: tokens[1].trimmingCharacters(in: .whitespaces)) {
                dir = d
            } else {
                dir = nil
            }
            return Header(type: .flowchart, direction: dir)
        case "sequencediagram":
            return Header(type: .sequence, direction: nil)
        case "gantt":
            return Header(type: .gantt, direction: nil)
        case "mindmap":
            return Header(type: .mindmap, direction: nil)
        default:
            return Header(type: .unknown(tokens.first ?? keyword), direction: nil)
        }
    }

    // MARK: - Text normalization

    /// Normalize Mermaid HTML break tags to newlines.
    private func normalize(_ text: String) -> String {
        MermaidTextUtils.normalizeBrTags(text)
    }

    // MARK: - Comment stripping

    /// Remove `%%` comment from a line.
    private func stripComment(_ line: String) -> String {
        // Find %% that is not inside quotes
        var inDoubleQuote = false
        let chars = Array(line)
        for i in 0 ..< chars.count {
            if chars[i] == "\"" { inDoubleQuote.toggle() }
            if !inDoubleQuote, i + 1 < chars.count, chars[i] == "%", chars[i + 1] == "%" {
                return String(chars[0 ..< i])
            }
        }
        return line
    }

    // MARK: - Flowchart parsing

    private func parseFlowchart(direction: FlowDirection, lines: [String]) -> FlowchartDiagram {
        var nodesById: [String: FlowNode] = [:]
        var edges: [FlowEdge] = []
        var subgraphs: [FlowSubgraph] = []
        var classDefs: [String: [String: String]] = [:]
        var styleDirectives: [FlowStyleDirective] = []
        var classApplications: [String: String] = [:] // nodeId -> className

        // Flatten into statements: split on `;` and newlines, skip blanks.
        let statements = expandStatements(lines)

        // Parse subgraphs with a stack-based approach.
        var subgraphStack: [SubgraphBuilder] = []

        for stmt in statements {
            let trimmed = stmt.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // subgraph
            if let sg = parseSubgraphStart(trimmed) {
                subgraphStack.append(sg)
                continue
            }

            // direction inside subgraph
            if trimmed.hasPrefix("direction ") {
                let dirStr = trimmed.dropFirst("direction ".count).trimmingCharacters(in: .whitespaces)
                if let dir = FlowDirection(rawValue: dirStr), let last = subgraphStack.last {
                    last.direction = dir
                }
                continue
            }

            // end (closes subgraph)
            if trimmed.lowercased() == "end" {
                if let builder = subgraphStack.popLast() {
                    let sg = builder.build()
                    if let parent = subgraphStack.last {
                        parent.subgraphs.append(sg)
                    } else {
                        subgraphs.append(sg)
                    }
                }
                continue
            }

            // classDef
            if let (name, props) = parseClassDef(trimmed) {
                classDefs[name] = props
                continue
            }

            // class application: `class A,B className`
            if let (nodeIds, className) = parseClassApplication(trimmed) {
                for nid in nodeIds {
                    classApplications[nid] = className
                }
                continue
            }

            // style directive
            if let directive = parseStyleDirective(trimmed) {
                styleDirectives.append(directive)
                continue
            }

            // Node declarations and edges (the main parsing path).
            let parsed = parseNodeEdgeStatement(trimmed)
            for node in parsed.nodes {
                // Keep the first explicit declaration. An implicit reference
                // (shape == .default) never overwrites an explicit one.
                if let existing = nodesById[node.id] {
                    if existing.shape == .default, node.shape != .default {
                        nodesById[node.id] = node
                    }
                } else {
                    nodesById[node.id] = node
                }
                if let current = subgraphStack.last {
                    current.nodeIds.insert(node.id)
                }
            }
            edges.append(contentsOf: parsed.edges)
        }

        // Close any unclosed subgraphs (error recovery).
        while let builder = subgraphStack.popLast() {
            subgraphs.append(builder.build())
        }

        // Build ordered node list (insertion order via statements).
        let orderedNodes = Array(nodesById.values.sorted { a, b in a.id < b.id })

        return FlowchartDiagram(
            direction: direction,
            nodes: orderedNodes,
            edges: edges,
            subgraphs: subgraphs,
            classDefs: classDefs,
            styleDirectives: styleDirectives
        )
    }

    // MARK: - Statement expansion

    /// Split lines on `;`, trim, and flatten into individual statements.
    private func expandStatements(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            let parts = line.split(separator: ";", omittingEmptySubsequences: false)
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
            }
        }
        return result
    }

    // MARK: - Subgraph parsing

    private final class SubgraphBuilder {
        let id: String
        let title: String?
        var direction: FlowDirection?
        var nodeIds: Set<String> = []
        var subgraphs: [FlowSubgraph] = []

        init(id: String, title: String?) {
            self.id = id
            self.title = title
        }

        func build() -> FlowSubgraph {
            FlowSubgraph(
                id: id,
                title: title,
                direction: direction,
                nodeIds: Array(nodeIds.sorted()),
                subgraphs: subgraphs
            )
        }
    }

    /// Parse `subgraph id [title]` or `subgraph title`.
    private func parseSubgraphStart(_ line: String) -> SubgraphBuilder? {
        guard line.lowercased().hasPrefix("subgraph") else { return nil }
        let rest = line.dropFirst("subgraph".count).trimmingCharacters(in: .whitespaces)

        if rest.isEmpty {
            return SubgraphBuilder(id: "subgraph_\(UInt.random(in: 0...UInt.max))", title: nil)
        }

        // Check for bracket syntax: subgraph id [title]
        if let bracketStart = rest.firstIndex(of: "["),
           let bracketEnd = rest.lastIndex(of: "]") {
            let id = String(rest[rest.startIndex ..< bracketStart]).trimmingCharacters(in: .whitespaces)
            let title = String(rest[rest.index(after: bracketStart) ..< bracketEnd])
            return SubgraphBuilder(id: id.isEmpty ? title : id, title: title)
        }

        // Otherwise: first token is id (if there are multiple tokens) or title
        let tokens = rest.split(separator: " ", maxSplits: 1).map(String.init)
        if tokens.count == 1 {
            // Single token: use as both id and title
            return SubgraphBuilder(id: tokens[0], title: tokens[0])
        }

        // Multi-token: first is id, rest is title
        return SubgraphBuilder(id: tokens[0], title: tokens.count > 1 ? tokens[1] : nil)
    }

    // MARK: - classDef

    /// Parse `classDef className fill:#f9f,stroke:#333`.
    private func parseClassDef(_ line: String) -> (String, [String: String])? {
        guard line.hasPrefix("classDef ") else { return nil }
        let rest = line.dropFirst("classDef ".count).trimmingCharacters(in: .whitespaces)
        let tokens = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard tokens.count == 2 else { return nil }
        let name = tokens[0]
        let props = parseCSSProperties(tokens[1])
        return (name, props)
    }

    // MARK: - class application

    /// Parse `class A,B className`.
    private func parseClassApplication(_ line: String) -> ([String], String)? {
        guard line.hasPrefix("class ") else { return nil }
        let rest = line.dropFirst("class ".count).trimmingCharacters(in: .whitespaces)
        let tokens = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard tokens.count == 2 else { return nil }
        let nodeIds = tokens[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return (nodeIds, tokens[1])
    }

    // MARK: - style directive

    /// Parse `style A fill:#f9f,stroke:#333`.
    private func parseStyleDirective(_ line: String) -> FlowStyleDirective? {
        guard line.hasPrefix("style ") else { return nil }
        let rest = line.dropFirst("style ".count).trimmingCharacters(in: .whitespaces)
        let tokens = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard tokens.count == 2 else { return nil }
        let nodeId = tokens[0]
        let props = parseCSSProperties(tokens[1])
        return FlowStyleDirective(nodeId: nodeId, properties: props)
    }

    /// Parse CSS-like properties: `fill:#f9f,stroke:#333,stroke-width:2px`.
    private func parseCSSProperties(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let pairs = text.split(separator: ",")
        for pair in pairs {
            let kv = pair.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces)
                let value = kv[1].trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
        }
        return result
    }

    // MARK: - Node + Edge statement parsing

    private struct ParsedStatement {
        let nodes: [FlowNode]
        let edges: [FlowEdge]
    }

    /// Parse a statement that may contain node declarations and/or edges.
    ///
    /// Handles chains like `A --> B --> C` and ampersand syntax `A --> B & C`.
    private func parseNodeEdgeStatement(_ line: String) -> ParsedStatement {
        var nodes: [FlowNode] = []
        var edges: [FlowEdge] = []

        // Tokenize into node-refs and edge-operators.
        let tokens = tokenize(line)
        if tokens.isEmpty { return ParsedStatement(nodes: [], edges: []) }

        // Build chain from alternating node-groups and edges.
        var i = 0

        // Parse first node group (may have & separators).
        var prevGroup = parseNodeGroup(tokens: tokens, index: &i)
        for node in prevGroup {
            nodes.append(node)
        }

        while i < tokens.count {
            // Expect an edge operator.
            guard case .edge(let style, let label) = tokens[i] else { break }
            i += 1

            // Parse next node group.
            let nextGroup = parseNodeGroup(tokens: tokens, index: &i)
            for node in nextGroup {
                nodes.append(node)
            }

            // Create edges from each source to each target.
            for src in prevGroup {
                for dst in nextGroup {
                    edges.append(FlowEdge(from: src.id, to: dst.id, label: label, style: style))
                }
            }

            prevGroup = nextGroup
        }

        return ParsedStatement(nodes: nodes, edges: edges)
    }

    /// Parse a group of nodes separated by `&`.
    private func parseNodeGroup(tokens: [FlowToken], index: inout Int) -> [FlowNode] {
        var group: [FlowNode] = []
        while index < tokens.count {
            guard case .node(let node) = tokens[index] else { break }
            group.append(node)
            index += 1
            // Check for `&` separator.
            if index < tokens.count, case .ampersand = tokens[index] {
                index += 1 // skip &
            } else {
                break
            }
        }
        return group
    }

    // MARK: - Tokenizer

    private enum FlowToken {
        case node(FlowNode)
        case edge(FlowEdgeStyle, String?)
        case ampersand
    }

    /// Tokenize a flowchart statement line into nodes, edges, and ampersands.
    private func tokenize(_ line: String) -> [FlowToken] {
        var tokens: [FlowToken] = []
        let chars = Array(line)
        var pos = 0

        while pos < chars.count {
            skipSpaces(chars, &pos)
            if pos >= chars.count { break }

            // Try to match an edge operator.
            if let match = tryParseEdge(chars, pos) {
                tokens.append(.edge(match.style, match.label))
                pos = match.endPos
                continue
            }

            // Ampersand.
            if chars[pos] == "&" {
                tokens.append(.ampersand)
                pos += 1
                continue
            }

            // Must be a node reference.
            if let (node, newPos) = tryParseNodeRef(chars, pos) {
                tokens.append(.node(node))
                pos = newPos
                continue
            }

            // Unknown character — skip to avoid infinite loop.
            pos += 1
        }

        return tokens
    }

    private func skipSpaces(_ chars: [Character], _ pos: inout Int) {
        while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" {
            pos += 1
        }
    }

    // MARK: - Intermediate types (avoiding large tuples)

    private struct EdgeMatch {
        let style: FlowEdgeStyle
        let label: String?
        let endPos: Int
    }

    private struct LabeledEdgeMatch {
        let label: String
        let style: FlowEdgeStyle
        let endPos: Int
    }

    private struct ShapeMatch {
        let label: String
        let shape: FlowNodeShape
        let endPos: Int
    }

    // MARK: - Edge parsing

    /// Try to parse an edge operator starting at `pos`.
    private func tryParseEdge(_ chars: [Character], _ pos: Int) -> EdgeMatch? {
        let remaining = chars.count - pos

        // Try each pattern, longest first to avoid greedy mismatches.

        // Thick arrow: ==>
        if remaining >= 3, chars[pos] == "=", chars[pos + 1] == "=", chars[pos + 2] == ">" {
            // Check for label: ==>|text|
            let afterArrow = pos + 3
            if let (label, end) = tryParsePipeLabel(chars, afterArrow) {
                return EdgeMatch(style: .thick, label: label, endPos: end)
            }
            return EdgeMatch(style: .thick, label: nil, endPos: afterArrow)
        }

        // Thick labeled: ==text==>
        if remaining >= 4, chars[pos] == "=", chars[pos + 1] == "=" {
            if let (label, end) = tryParseInlineLabel(chars, pos + 2, terminator: "==>") {
                return EdgeMatch(style: .thick, label: label, endPos: end)
            }
        }

        // Dotted arrow: -.->
        if remaining >= 4, chars[pos] == "-", chars[pos + 1] == ".", chars[pos + 2] == "-", chars[pos + 3] == ">" {
            let afterArrow = pos + 4
            if let (label, end) = tryParsePipeLabel(chars, afterArrow) {
                return EdgeMatch(style: .dotted, label: label, endPos: end)
            }
            return EdgeMatch(style: .dotted, label: nil, endPos: afterArrow)
        }

        // Dotted with label: -. text .->
        if remaining >= 3, chars[pos] == "-", chars[pos + 1] == "." {
            if let (label, end) = tryParseDottedLabel(chars, pos + 2) {
                return EdgeMatch(style: .dotted, label: label, endPos: end)
            }
        }

        // Invisible: ~~~
        if remaining >= 3, chars[pos] == "~", chars[pos + 1] == "~", chars[pos + 2] == "~" {
            return EdgeMatch(style: .invisible, label: nil, endPos: pos + 3)
        }

        // Bidirectional arrow: <-->
        if remaining >= 4, chars[pos] == "<", chars[pos + 1] == "-", chars[pos + 2] == "-", chars[pos + 3] == ">" {
            let afterArrow = pos + 4
            if let (label, end) = tryParsePipeLabel(chars, afterArrow) {
                return EdgeMatch(style: .biArrow, label: label, endPos: end)
            }
            return EdgeMatch(style: .biArrow, label: nil, endPos: afterArrow)
        }

        // Bidirectional circle: o--o
        if remaining >= 4, chars[pos] == "o", chars[pos + 1] == "-", chars[pos + 2] == "-", chars[pos + 3] == "o" {
            let afterArrow = pos + 4
            if let (label, end) = tryParsePipeLabel(chars, afterArrow) {
                return EdgeMatch(style: .biCircle, label: label, endPos: end)
            }
            return EdgeMatch(style: .biCircle, label: nil, endPos: afterArrow)
        }

        // Bidirectional cross: x--x
        if remaining >= 4, chars[pos] == "x", chars[pos + 1] == "-", chars[pos + 2] == "-", chars[pos + 3] == "x" {
            let afterArrow = pos + 4
            if let (label, end) = tryParsePipeLabel(chars, afterArrow) {
                return EdgeMatch(style: .biCross, label: label, endPos: end)
            }
            return EdgeMatch(style: .biCross, label: nil, endPos: afterArrow)
        }

        // Circle edge: --o
        if remaining >= 3, chars[pos] == "-", chars[pos + 1] == "-", chars[pos + 2] == "o" {
            let afterArrow = pos + 3
            if let (label, end) = tryParsePipeLabel(chars, afterArrow) {
                return EdgeMatch(style: .circle, label: label, endPos: end)
            }
            return EdgeMatch(style: .circle, label: nil, endPos: afterArrow)
        }

        // Cross edge: --x
        if remaining >= 3, chars[pos] == "-", chars[pos + 1] == "-", chars[pos + 2] == "x" {
            let afterArrow = pos + 3
            if let (label, end) = tryParsePipeLabel(chars, afterArrow) {
                return EdgeMatch(style: .cross, label: label, endPos: end)
            }
            return EdgeMatch(style: .cross, label: nil, endPos: afterArrow)
        }

        // Arrow with pipe label: -->|text|
        if remaining >= 3, chars[pos] == "-", chars[pos + 1] == "-", chars[pos + 2] == ">" {
            let afterArrow = pos + 3
            if let (label, end) = tryParsePipeLabel(chars, afterArrow) {
                return EdgeMatch(style: .arrow, label: label, endPos: end)
            }
            return EdgeMatch(style: .arrow, label: nil, endPos: afterArrow)
        }

        // Arrow with inline label: -- text -->
        if remaining >= 2, chars[pos] == "-", chars[pos + 1] == "-" {
            // Must check if this is a labeled edge: -- text -->  or  -- text ---
            if let match = tryParseDoubleHyphenLabel(chars, pos + 2) {
                return EdgeMatch(style: match.style, label: match.label, endPos: match.endPos)
            }
        }

        // Open link: ---
        if remaining >= 3, chars[pos] == "-", chars[pos + 1] == "-", chars[pos + 2] == "-" {
            // Consume extra hyphens
            var end = pos + 3
            while end < chars.count, chars[end] == "-" { end += 1 }
            if let (label, endL) = tryParsePipeLabel(chars, end) {
                return EdgeMatch(style: .open, label: label, endPos: endL)
            }
            return EdgeMatch(style: .open, label: nil, endPos: end)
        }

        return nil
    }

    /// Try to parse `|text|` at the given position.
    private func tryParsePipeLabel(_ chars: [Character], _ pos: Int) -> (String, Int)? {
        guard pos < chars.count, chars[pos] == "|" else { return nil }
        var end = pos + 1
        while end < chars.count, chars[end] != "|" {
            end += 1
        }
        guard end < chars.count else { return nil }
        let label = normalize(String(chars[(pos + 1) ..< end]))
        return (label, end + 1)
    }

    /// Try to parse inline label for `-- text -->` or `-- text ---` patterns.
    private func tryParseDoubleHyphenLabel(_ chars: [Character], _ pos: Int) -> LabeledEdgeMatch? {
        // Skip leading space.
        var start = pos
        while start < chars.count, chars[start] == " " { start += 1 }
        if start >= chars.count { return nil }

        // Look ahead for --> or ---
        let remaining = String(chars[start...])

        // Find --> or ---
        if let arrowRange = remaining.range(of: "-->") {
            let labelEnd = remaining.distance(from: remaining.startIndex, to: arrowRange.lowerBound)
            let label = normalize(String(remaining[remaining.startIndex ..< arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces))
            if !label.isEmpty {
                let totalConsumed = start + labelEnd + 3
                return LabeledEdgeMatch(label: label, style: .arrow, endPos: totalConsumed)
            }
        }

        if let openRange = remaining.range(of: "---") {
            let labelEnd = remaining.distance(from: remaining.startIndex, to: openRange.lowerBound)
            let label = normalize(String(remaining[remaining.startIndex ..< openRange.lowerBound]).trimmingCharacters(in: .whitespaces))
            if !label.isEmpty {
                var totalConsumed = start + labelEnd + 3
                // Consume extra hyphens
                while totalConsumed < chars.count, chars[totalConsumed] == "-" { totalConsumed += 1 }
                return LabeledEdgeMatch(label: label, style: .open, endPos: totalConsumed)
            }
        }

        return nil
    }

    /// Try to parse inline label in thick edges: `== text ==>`.
    private func tryParseInlineLabel(_ chars: [Character], _ pos: Int, terminator: String) -> (String, Int)? {
        let remaining = String(chars[pos...])
        guard let range = remaining.range(of: terminator) else { return nil }
        let label = normalize(String(remaining[remaining.startIndex ..< range.lowerBound]).trimmingCharacters(in: .whitespaces))
        if label.isEmpty { return nil }
        let consumed = pos + remaining.distance(from: remaining.startIndex, to: range.upperBound)
        return (label, consumed)
    }

    /// Try to parse dotted label: `-. text .->`.
    private func tryParseDottedLabel(_ chars: [Character], _ pos: Int) -> (String, Int)? {
        let remaining = String(chars[pos...])
        // Look for .-> terminator
        guard let range = remaining.range(of: ".->") else { return nil }
        let label = normalize(String(remaining[remaining.startIndex ..< range.lowerBound]).trimmingCharacters(in: .whitespaces))
        if label.isEmpty { return nil }
        let consumed = pos + remaining.distance(from: remaining.startIndex, to: range.upperBound)
        return (label, consumed)
    }

    // MARK: - Node reference parsing

    /// Try to parse a node reference: `A`, `A[text]`, `A(text)`, etc.
    /// Also handles `:::className` suffix.
    private func tryParseNodeRef(_ chars: [Character], _ pos: Int) -> (FlowNode, Int)? {
        // Parse the node ID (alphanumeric, underscore, hyphen).
        var idEnd = pos
        while idEnd < chars.count, isIdChar(chars[idEnd]) {
            idEnd += 1
        }
        guard idEnd > pos else { return nil }
        let id = String(chars[pos ..< idEnd])

        // Try to parse shape brackets.
        if idEnd < chars.count {
            if let match = tryParseShape(chars, idEnd) {
                let finalEnd = skipClassSuffix(chars, match.endPos)
                return (FlowNode(id: id, label: match.label, shape: match.shape), finalEnd)
            }
        }

        // No shape — implicit node.
        let finalEnd = skipClassSuffix(chars, idEnd)
        return (FlowNode(id: id, label: id, shape: .default), finalEnd)
    }

    /// Skip `:::className` suffix.
    private func skipClassSuffix(_ chars: [Character], _ pos: Int) -> Int {
        var p = pos
        if p + 2 < chars.count, chars[p] == ":", chars[p + 1] == ":", chars[p + 2] == ":" {
            p += 3
            while p < chars.count, isIdChar(chars[p]) {
                p += 1
            }
        }
        return p
    }

    /// Check if a character is valid in a node ID.
    private func isIdChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }

    /// Try to parse a node shape starting at `pos`.
    private func tryParseShape(_ chars: [Character], _ pos: Int) -> ShapeMatch? {
        guard pos < chars.count else { return nil }
        let c = chars[pos]

        switch c {
        case "[":
            // Could be: [text], [(text)], [[text]], [/text/], [/text\], [\text\], [\text/]
            if pos + 1 < chars.count {
                if chars[pos + 1] == "(" {
                    // Cylindrical: [(text)]
                    if let end = findClosing(chars, pos + 2, open: nil, close: ")") {
                        if end + 1 < chars.count, chars[end + 1] == "]" {
                            let label = normalize(String(chars[(pos + 2) ..< end]))
                            return ShapeMatch(label: label, shape: .cylindrical, endPos: end + 2)
                        }
                    }
                } else if chars[pos + 1] == "[" {
                    // Subroutine: [[text]]
                    if let end = findDoubleClosing(chars, pos + 2, close: "]") {
                        let label = normalize(String(chars[(pos + 2) ..< end]))
                        return ShapeMatch(label: label, shape: .subroutine, endPos: end + 2)
                    }
                } else if chars[pos + 1] == "/" {
                    // Parallelogram [/text/] or Trapezoid [/text\]
                    if let end = findClosing(chars, pos + 2, open: nil, close: "]") {
                        let inner = chars[(pos + 2) ..< end]
                        if inner.last == "/" {
                            let label = normalize(String(inner.dropLast()))
                            return ShapeMatch(label: label, shape: .parallelogram, endPos: end + 1)
                        } else if inner.last == "\\" {
                            let label = normalize(String(inner.dropLast()))
                            return ShapeMatch(label: label, shape: .trapezoid, endPos: end + 1)
                        }
                    }
                } else if chars[pos + 1] == "\\" {
                    // Parallelogram alt [\text\] or Trapezoid alt [\text/]
                    if let end = findClosing(chars, pos + 2, open: nil, close: "]") {
                        let inner = chars[(pos + 2) ..< end]
                        if inner.last == "\\" {
                            let label = normalize(String(inner.dropLast()))
                            return ShapeMatch(label: label, shape: .parallelogramAlt, endPos: end + 1)
                        } else if inner.last == "/" {
                            let label = normalize(String(inner.dropLast()))
                            return ShapeMatch(label: label, shape: .trapezoidAlt, endPos: end + 1)
                        }
                    }
                }
            }
            // Rectangle: [text]
            if let end = findClosing(chars, pos + 1, open: nil, close: "]") {
                let label = normalize(String(chars[(pos + 1) ..< end]))
                return ShapeMatch(label: label, shape: .rectangle, endPos: end + 1)
            }

        case "(":
            // Could be: (text), ([text]), ((text))
            if pos + 1 < chars.count {
                if chars[pos + 1] == "[" {
                    // Stadium: ([text])
                    if let end = findClosing(chars, pos + 2, open: nil, close: "]") {
                        if end + 1 < chars.count, chars[end + 1] == ")" {
                            let label = normalize(String(chars[(pos + 2) ..< end]))
                            return ShapeMatch(label: label, shape: .stadium, endPos: end + 2)
                        }
                    }
                } else if chars[pos + 1] == "(" {
                    // Double circle: (((text))) or Circle: ((text))
                    if pos + 2 < chars.count, chars[pos + 2] == "(" {
                        // Triple-paren: (((text)))
                        if let end = findTripleClosing(chars, pos + 3, close: ")") {
                            let label = normalize(String(chars[(pos + 3) ..< end]))
                            return ShapeMatch(label: label, shape: .doubleCircle, endPos: end + 3)
                        }
                    }
                    if let end = findDoubleClosing(chars, pos + 2, close: ")") {
                        let label = normalize(String(chars[(pos + 2) ..< end]))
                        return ShapeMatch(label: label, shape: .circle, endPos: end + 2)
                    }
                }
            }
            // Rounded: (text)
            if let end = findClosing(chars, pos + 1, open: nil, close: ")") {
                let label = normalize(String(chars[(pos + 1) ..< end]))
                return ShapeMatch(label: label, shape: .rounded, endPos: end + 1)
            }

        case "{":
            // Could be: {text}, {{text}}
            if pos + 1 < chars.count, chars[pos + 1] == "{" {
                // Hexagon: {{text}}
                if let end = findDoubleClosing(chars, pos + 2, close: "}") {
                    let label = normalize(String(chars[(pos + 2) ..< end]))
                    return ShapeMatch(label: label, shape: .hexagon, endPos: end + 2)
                }
            }
            // Diamond: {text}
            if let end = findClosing(chars, pos + 1, open: nil, close: "}") {
                let label = normalize(String(chars[(pos + 1) ..< end]))
                return ShapeMatch(label: label, shape: .diamond, endPos: end + 1)
            }

        case ">":
            // Asymmetric: >text]
            if let end = findClosing(chars, pos + 1, open: nil, close: "]") {
                let label = normalize(String(chars[(pos + 1) ..< end]))
                return ShapeMatch(label: label, shape: .asymmetric, endPos: end + 1)
            }

        default:
            break
        }

        return nil
    }

    /// Find the index of a closing character, handling basic nesting.
    private func findClosing(_ chars: [Character], _ start: Int, open: Character?, close: Character) -> Int? {
        var depth = 1
        var i = start
        while i < chars.count {
            if let o = open, chars[i] == o { depth += 1 }
            if chars[i] == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        // If no nesting required, just find first occurrence.
        if open == nil {
            return nil
        }
        return nil
    }

    /// Find `]]`, `))`, `}}` — two consecutive closing chars.
    private func findDoubleClosing(_ chars: [Character], _ start: Int, close: Character) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == close, chars[i + 1] == close {
                return i
            }
            i += 1
        }
        return nil
    }

    /// Find `)))`, `}}}` — three consecutive closing chars.
    private func findTripleClosing(_ chars: [Character], _ start: Int, close: Character) -> Int? {
        var i = start
        while i + 2 < chars.count {
            if chars[i] == close, chars[i + 1] == close, chars[i + 2] == close {
                return i
            }
            i += 1
        }
        return nil
    }

    // MARK: - Sequence diagram parsing (Phase 2, basic)

    // Keywords that should not become participants when seen as standalone lines.
    private static let sequenceKeywords: Set<String> = [
        "autonumber", "activate", "deactivate",
        "loop", "alt", "else", "opt", "par", "and",
        "critical", "option", "break", "end",
        "rect", "box",
    ]

    private func parseSequence(lines: [String]) -> SequenceDiagram {
        var participants: [SequenceParticipant] = []
        var messages: [SequenceMessage] = []
        var notes: [SequenceNote] = []
        var blocks: [SequenceBlock] = []
        var knownIds: Set<String> = []
        var autonumber = false

        // Block nesting stack: (kind, label, elseBlocks)
        var blockStack: [(kind: SequenceBlockKind, label: String, elseBlocks: [SequenceElseBlock])] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let lower = trimmed.lowercased()

            // autonumber
            if lower == "autonumber" || lower.hasPrefix("autonumber ") {
                autonumber = true
                continue
            }

            // activate / deactivate keywords
            if lower.hasPrefix("activate ") || lower.hasPrefix("deactivate ") {
                continue
            }

            // box ... end (skip — just don't let it become a participant)
            if lower.hasPrefix("box") {
                blockStack.append((kind: .rect, label: "", elseBlocks: []))
                continue
            }

            // rect rgb(...) ... end
            if lower.hasPrefix("rect ") || lower == "rect" {
                blockStack.append((kind: .rect, label: "", elseBlocks: []))
                continue
            }

            // Block openers: loop, alt, opt, par, critical, break
            if let blockInfo = parseBlockOpener(lower, raw: trimmed) {
                blockStack.append((kind: blockInfo.kind, label: blockInfo.label, elseBlocks: []))
                continue
            }

            // else / and / option (adds to current block)
            if lower.hasPrefix("else") || lower.hasPrefix("and ") || lower.hasPrefix("option ") {
                if !blockStack.isEmpty {
                    let label: String
                    if lower.hasPrefix("else") {
                        label = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    } else if lower.hasPrefix("and ") {
                        label = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    } else {
                        label = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    }
                    blockStack[blockStack.count - 1].elseBlocks.append(SequenceElseBlock(label: label))
                }
                continue
            }

            // end (closes block)
            if lower == "end" {
                if let top = blockStack.popLast() {
                    if top.kind != .rect {
                        blocks.append(SequenceBlock(
                            kind: top.kind,
                            label: top.label,
                            elseBlocks: top.elseBlocks.isEmpty ? nil : top.elseBlocks
                        ))
                    }
                }
                continue
            }

            // Note
            if let note = parseSequenceNote(trimmed) {
                // Auto-add actors from notes.
                for actor in note.actors where !knownIds.contains(actor) {
                    participants.append(SequenceParticipant(id: actor, label: actor, isActor: false))
                    knownIds.insert(actor)
                }
                notes.append(note)
                continue
            }

            // participant / actor
            if let p = parseParticipant(trimmed) {
                if !knownIds.contains(p.id) {
                    participants.append(p)
                    knownIds.insert(p.id)
                }
                continue
            }

            // message
            if let msg = parseSequenceMessage(trimmed) {
                // Auto-add participants if not declared.
                for pid in [msg.from, msg.to] where !knownIds.contains(pid) {
                    participants.append(SequenceParticipant(id: pid, label: pid, isActor: false))
                    knownIds.insert(pid)
                }
                messages.append(msg)
            }
        }

        // Close unclosed blocks (error recovery).
        while let top = blockStack.popLast() {
            if top.kind != .rect {
                blocks.append(SequenceBlock(
                    kind: top.kind,
                    label: top.label,
                    elseBlocks: top.elseBlocks.isEmpty ? nil : top.elseBlocks
                ))
            }
        }

        return SequenceDiagram(
            participants: participants,
            messages: messages,
            notes: notes,
            blocks: blocks,
            autonumber: autonumber
        )
    }

    /// Parse a block-opening keyword (loop, alt, opt, par, critical, break).
    private func parseBlockOpener(_ lower: String, raw: String) -> (kind: SequenceBlockKind, label: String)? {
        let patterns: [(String, SequenceBlockKind)] = [
            ("loop ", .loop),
            ("alt ", .alt),
            ("opt ", .opt),
            ("par ", .par),
            ("critical ", .critical),
            ("break ", .break),
        ]
        for (prefix, kind) in patterns {
            if lower.hasPrefix(prefix) {
                let label = String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return (kind, label)
            }
        }
        // Handle keyword without label: "loop" with no text after it.
        let keywordOnly: [(String, SequenceBlockKind)] = [
            ("loop", .loop), ("alt", .alt), ("opt", .opt),
            ("par", .par), ("critical", .critical),
        ]
        for (keyword, kind) in keywordOnly {
            if lower == keyword { return (kind, "") }
        }
        return nil
    }

    /// Parse a Note line: `Note [right of | left of | over] Actor[,Actor]: text`
    private func parseSequenceNote(_ line: String) -> SequenceNote? {
        let lower = line.lowercased()
        guard lower.hasPrefix("note ") else { return nil }
        let rest = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        let restLower = rest.lowercased()

        let position: NotePosition
        let afterPosition: String

        if restLower.hasPrefix("right of ") {
            position = .rightOf
            afterPosition = String(rest.dropFirst(9)).trimmingCharacters(in: .whitespaces)
        } else if restLower.hasPrefix("left of ") {
            position = .leftOf
            afterPosition = String(rest.dropFirst(8)).trimmingCharacters(in: .whitespaces)
        } else if restLower.hasPrefix("over ") {
            position = .over
            afterPosition = String(rest.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        // Split on `:` — actors : text
        let parts = afterPosition.split(separator: ":", maxSplits: 1).map(String.init)
        guard let actorPart = parts.first else { return nil }
        let text = parts.count > 1 ? normalize(parts[1].trimmingCharacters(in: .whitespaces)) : ""
        let actors = actorPart.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        return SequenceNote(text: text, position: position, actors: actors)
    }

    private func parseParticipant(_ line: String) -> SequenceParticipant? {
        let isActor: Bool
        let rest: String

        if line.hasPrefix("participant ") {
            isActor = false
            rest = String(line.dropFirst("participant ".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("actor ") {
            isActor = true
            rest = String(line.dropFirst("actor ".count)).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        // Check for `as` alias: `participant A as Alice`
        let parts = rest.components(separatedBy: " as ")
        if parts.count >= 2 {
            return SequenceParticipant(id: parts[0].trimmingCharacters(in: .whitespaces),
                                       label: normalize(parts[1].trimmingCharacters(in: .whitespaces)),
                                       isActor: isActor)
        }

        return SequenceParticipant(id: rest, label: normalize(rest), isActor: isActor)
    }

    /// Parse sequence message: `A->>B: text`, `A-->>B: text`, etc.
    private func parseSequenceMessage(_ line: String) -> SequenceMessage? {
        // Find the arrow pattern.
        // Order matters: longer patterns first.
        let arrowPatterns: [(String, SequenceArrowStyle)] = [
            ("-->>", .dashed),
            ("->>", .solid),
            ("--)", .dashedAsync),
            ("-)", .solidAsync),
            ("--x", .dashedCross),
            ("-x", .solidCross),
            ("-->", .dashedOpen),
            ("->", .solidOpen),
        ]

        for (pattern, style) in arrowPatterns {
            if let range = line.range(of: pattern) {
                let from = String(line[line.startIndex ..< range.lowerBound]).trimmingCharacters(in: .whitespaces)
                var remaining = String(line[range.upperBound...])

                // Activation shorthand: +/- immediately after arrow.
                var activationModifier: ActivationModifier?
                if remaining.hasPrefix("+") {
                    activationModifier = .activate
                    remaining = String(remaining.dropFirst())
                } else if remaining.hasPrefix("-") {
                    activationModifier = .deactivate
                    remaining = String(remaining.dropFirst())
                }

                // Split on `:` for target and message text.
                let parts = remaining.split(separator: ":", maxSplits: 1).map(String.init)
                guard let firstPart = parts.first else { continue }
                let to = firstPart.trimmingCharacters(in: .whitespaces)
                let text = parts.count > 1 ? normalize(parts[1].trimmingCharacters(in: .whitespaces)) : ""

                if !from.isEmpty, !to.isEmpty {
                    return SequenceMessage(
                        from: from, to: to, text: text,
                        arrowStyle: style,
                        activationModifier: activationModifier
                    )
                }
            }
        }

        return nil
    }
}
