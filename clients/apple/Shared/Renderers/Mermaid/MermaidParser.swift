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
        let frontmatter = parseFrontmatterOptions(in: stripped)

        // Find first non-blank line to detect diagram type, skipping optional Mermaid YAML frontmatter.
        guard let firstIndex = firstDiagramLineIndex(in: stripped),
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
            let diagram = MermaidGanttParser.parse(lines: body, options: frontmatter.gantt)
            return .gantt(diagram)
        case .mindmap:
            let body = Array(stripped[(firstIndex + 1)...])
            let diagram = MermaidMindmapParser.parse(lines: body, options: frontmatter.mindmap)
            return .mindmap(diagram)
        case .state:
            let body = Array(stripped[(firstIndex + 1)...])
            let diagram = MermaidStateParser.parse(lines: body)
            return .state(diagram)
        case .unknown(let name):
            return .unsupported(type: name)
        }
    }

    // MARK: - Header parsing

    private struct FrontmatterOptions {
        var gantt = MermaidGanttParser.Options()
        var mindmap = MermaidMindmapParser.Options()
    }

    private func parseFrontmatterOptions(in lines: [String]) -> FrontmatterOptions {
        var options = FrontmatterOptions()
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return options }

        for line in lines[(first + 1)..<closing] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower == "displaymode: compact" || lower == "displaymode: 'compact'" || lower == "displaymode: \"compact\"" {
                options.gantt.displayMode = .compact
            } else if lower == "topaxis: true" {
                options.gantt.topAxis = true
            } else if lower == "layout: tidy-tree" || lower == "layout: 'tidy-tree'" || lower == "layout: \"tidy-tree\"" {
                options.mindmap.layout = .tidyTree
            }
        }
        return options
    }

    private func firstDiagramLineIndex(in lines: [String]) -> Int? {
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }

        guard lines[first].trimmingCharacters(in: .whitespaces) == "---" else {
            return first
        }

        guard let closing = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return first
        }

        return lines[(closing + 1)...].firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    private enum DiagramType {
        case flowchart
        case sequence
        case gantt
        case mindmap
        case state
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
        case "statediagram", "statediagram-v2":
            return Header(type: .state, direction: nil)
        default:
            return Header(type: .unknown(tokens.first ?? keyword), direction: nil)
        }
    }

    // MARK: - Text normalization

    /// Normalize Mermaid label syntax: HTML breaks, quote/backtick wrappers, and entity codes.
    private func normalize(_ text: String) -> String {
        MermaidTextUtils.normalizeLabel(text)
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
        var classApplications: [String: [String]] = [:] // nodeId -> class names

        func applyClass(_ className: String, to nodeId: String) {
            guard !className.isEmpty else { return }
            var classes = classApplications[nodeId] ?? []
            if !classes.contains(className) {
                classes.append(className)
            }
            classApplications[nodeId] = classes
        }

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

            // Edge metadata / animation directive: `e1@{ animation: fast }`.
            if let directive = parseMetadataDirective(trimmed) {
                styleDirectives.append(directive)
                continue
            }

            // classDef
            if let (names, props) = parseClassDef(trimmed) {
                for name in names {
                    classDefs[name] = props
                }
                continue
            }

            // class application: `class A,B className`
            if let (nodeIds, classNames) = parseClassApplication(trimmed) {
                for nid in nodeIds {
                    for className in classNames {
                        applyClass(className, to: nid)
                    }
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
                for className in node.classes {
                    applyClass(className, to: node.id)
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

        // Build ordered node list. When edges target subgraph IDs, Mermaid
        // treats those IDs as cluster endpoints, not implicit standalone nodes.
        let subgraphIds = Set(subgraphs.flatMap(allSubgraphIds(in:)))
        let orderedNodes = nodesById.values
            .filter { node in !(subgraphIds.contains(node.id) && node.shape == .default && node.label == node.id) }
            .sorted { a, b in a.id < b.id }

        return FlowchartDiagram(
            direction: direction,
            nodes: orderedNodes,
            edges: edges,
            subgraphs: subgraphs,
            classDefs: classDefs,
            styleDirectives: styleDirectives,
            classApplications: classApplications
        )
    }

    private func allSubgraphIds(in subgraph: FlowSubgraph) -> [String] {
        [subgraph.id] + subgraph.subgraphs.flatMap(allSubgraphIds(in:))
    }

    // MARK: - Statement expansion

    /// Split lines on statement separator semicolons, preserving semicolons
    /// inside labels and entity codes such as `#quot;` or `#9829;`.
    private func expandStatements(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            for part in splitStatements(in: line) {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
            }
        }
        return result
    }

    private func splitStatements(in line: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var inDoubleQuote = false
        var squareDepth = 0
        var parenDepth = 0
        var braceDepth = 0

        for char in line {
            if char == "\"" {
                inDoubleQuote.toggle()
                current.append(char)
                continue
            }

            if !inDoubleQuote {
                switch char {
                case "[": squareDepth += 1
                case "]": squareDepth = max(0, squareDepth - 1)
                case "(": parenDepth += 1
                case ")": parenDepth = max(0, parenDepth - 1)
                case "{": braceDepth += 1
                case "}": braceDepth = max(0, braceDepth - 1)
                case ";" where squareDepth == 0 && parenDepth == 0 && braceDepth == 0:
                    statements.append(current)
                    current = ""
                    continue
                default:
                    break
                }
            }

            current.append(char)
        }

        statements.append(current)
        return statements
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
                regionCount: 0,
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

    // MARK: - metadata directive

    /// Parse metadata directives for already-declared IDs, e.g. `e1@{ animation: fast }`.
    private func parseMetadataDirective(_ line: String) -> FlowStyleDirective? {
        guard let marker = line.range(of: "@{") else { return nil }
        let id = String(line[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        let bodyStart = marker.upperBound
        guard let end = line[bodyStart...].lastIndex(of: "}") else { return nil }
        let body = String(line[bodyStart..<end])
        let properties = parseMetadataProperties(body)
        guard !properties.isEmpty,
              properties["shape"] == nil,
              properties["icon"] == nil,
              properties["img"] == nil
        else { return nil }
        return FlowStyleDirective(nodeId: id, properties: properties)
    }

    // MARK: - classDef

    /// Parse `classDef className fill:#f9f,stroke:#333`.
    private func parseClassDef(_ line: String) -> ([String], [String: String])? {
        guard line.hasPrefix("classDef ") else { return nil }
        let rest = line.dropFirst("classDef ".count).trimmingCharacters(in: .whitespaces)
        let tokens = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard tokens.count == 2 else { return nil }
        let names = tokens[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let props = parseCSSProperties(tokens[1])
        return (names, props)
    }

    // MARK: - class application

    /// Parse `class A,B className`.
    private func parseClassApplication(_ line: String) -> ([String], [String])? {
        guard line.hasPrefix("class ") else { return nil }
        let rest = line.dropFirst("class ".count).trimmingCharacters(in: .whitespaces)
        let tokens = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard tokens.count == 2 else { return nil }
        let nodeIds = tokens[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let classNames = tokens[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return (nodeIds, classNames)
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
        for pair in splitEscapedCommaList(text) {
            let kv = pair.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces)
                let value = kv[1]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"\,"#, with: ",")
                result[key] = value
            }
        }
        return result
    }

    private func splitEscapedCommaList(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var isEscaped = false

        for char in text {
            if isEscaped {
                if char == "," {
                    current.append("\\")
                    current.append(char)
                } else {
                    current.append("\\")
                    current.append(char)
                }
                isEscaped = false
                continue
            }

            if char == "\\" {
                isEscaped = true
            } else if char == "," {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }

        if isEscaped {
            current.append("\\")
        }
        result.append(current)
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
            guard case .edge(let style, let label, let edgeId) = tokens[i] else { break }
            i += 1

            // Parse next node group.
            let nextGroup = parseNodeGroup(tokens: tokens, index: &i)
            for node in nextGroup {
                nodes.append(node)
            }

            // Create edges from each source to each target.
            for src in prevGroup {
                for dst in nextGroup {
                    edges.append(FlowEdge(from: src.id, to: dst.id, label: label, style: style, id: edgeId))
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
        case edge(FlowEdgeStyle, String?, String?)
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
                tokens.append(.edge(match.style, match.label, match.id))
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
        let id: String?

        init(style: FlowEdgeStyle, label: String?, endPos: Int, id: String? = nil) {
            self.style = style
            self.label = label
            self.endPos = endPos
            self.id = id
        }
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

        if let idMatch = tryParseEdgeIdPrefix(chars, pos) {
            return idMatch
        }

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

    /// Parse edge IDs like `e1@-->` before the edge operator.
    private func tryParseEdgeIdPrefix(_ chars: [Character], _ pos: Int) -> EdgeMatch? {
        var idEnd = pos
        while idEnd < chars.count, isIdChar(chars[idEnd]) {
            idEnd += 1
        }
        guard idEnd > pos,
              idEnd < chars.count,
              chars[idEnd] == "@",
              let match = tryParseEdge(chars, idEnd + 1)
        else { return nil }

        let id = String(chars[pos..<idEnd])
        return EdgeMatch(style: match.style, label: match.label, endPos: match.endPos, id: id)
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
            if isEdgeOperatorStartInNodeRef(chars, idEnd) {
                break
            }
            idEnd += 1
        }
        guard idEnd > pos else { return nil }
        let id = String(chars[pos ..< idEnd])

        // Try to parse v11.3+ metadata shape syntax before classic shape brackets.
        if idEnd < chars.count {
            if let match = tryParseMetadataShape(chars, idEnd, defaultLabel: id) {
                let suffix = parseClassSuffix(chars, match.endPos)
                return (FlowNode(id: id, label: match.label, shape: match.shape, classes: suffix.classes), suffix.endPos)
            }
            if let match = tryParseShape(chars, idEnd) {
                let suffix = parseClassSuffix(chars, match.endPos)
                return (FlowNode(id: id, label: match.label, shape: match.shape, classes: suffix.classes), suffix.endPos)
            }
        }

        // No shape — implicit node.
        let suffix = parseClassSuffix(chars, idEnd)
        return (FlowNode(id: id, label: id, shape: .default, classes: suffix.classes), suffix.endPos)
    }

    /// Parse `:::className` suffix.
    private func parseClassSuffix(_ chars: [Character], _ pos: Int) -> (endPos: Int, classes: [String]) {
        var p = pos
        var classes: [String] = []
        if p + 2 < chars.count, chars[p] == ":", chars[p + 1] == ":", chars[p + 2] == ":" {
            p += 3
            let classStart = p
            while p < chars.count, isIdChar(chars[p]) {
                p += 1
            }
            if p > classStart {
                classes.append(String(chars[classStart..<p]))
            }
        }
        return (p, classes)
    }

    /// Check if a character is valid in a node ID.
    private func isIdChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }

    /// Mermaid allows edge operators with no spaces (`A-->B`). Because `-`
    /// is also valid in node IDs, stop ID scanning before operator prefixes.
    private func isEdgeOperatorStartInNodeRef(_ chars: [Character], _ pos: Int) -> Bool {
        guard pos + 1 < chars.count else { return false }
        if chars[pos] == "-" {
            return chars[pos + 1] == "-" || chars[pos + 1] == "."
        }
        return false
    }

    /// Try to parse a Mermaid v11.3+ metadata shape: `A@{ shape: rect, label: "Text" }`.
    private func tryParseMetadataShape(_ chars: [Character], _ pos: Int, defaultLabel: String) -> ShapeMatch? {
        guard pos + 1 < chars.count,
              chars[pos] == "@",
              chars[pos + 1] == "{",
              let end = findMetadataEnd(chars, start: pos + 2)
        else { return nil }

        let body = String(chars[(pos + 2)..<end])
        let properties = parseMetadataProperties(body)
        let rawShape = properties["shape"].map(normalizeMetadataValue)
            ?? (properties["icon"] != nil || properties["img"] != nil ? "rect" : nil)
        guard let rawShape,
              let shape = flowNodeShape(forMetadataShape: rawShape)
        else { return nil }

        let label = properties["label"].map { normalize($0.trimmingCharacters(in: .whitespaces)) }
            ?? defaultLabel
        return ShapeMatch(label: label, shape: shape, endPos: end + 1)
    }

    private func findMetadataEnd(_ chars: [Character], start: Int) -> Int? {
        var inDoubleQuote = false
        var i = start
        while i < chars.count {
            let char = chars[i]
            if char == "\"" {
                inDoubleQuote.toggle()
            } else if !inDoubleQuote, char == "}" {
                return i
            }
            i += 1
        }
        return nil
    }

    private func parseMetadataProperties(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in splitMetadataPairs(body) {
            guard let colonIndex = firstUnquotedColon(in: pair) else { continue }
            let rawKey = String(pair[..<colonIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeMetadataValue(rawKey).lowercased()
            let valueStart = pair.index(after: colonIndex)
            let value = String(pair[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private func splitMetadataPairs(_ body: String) -> [String] {
        var pairs: [String] = []
        var current = ""
        var inDoubleQuote = false

        for char in body {
            if char == "\"" {
                inDoubleQuote.toggle()
                current.append(char)
            } else if char == ",", !inDoubleQuote {
                pairs.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }

        pairs.append(current)
        return pairs
    }

    private func firstUnquotedColon(in text: String) -> String.Index? {
        var inDoubleQuote = false
        for index in text.indices {
            let char = text[index]
            if char == "\"" {
                inDoubleQuote.toggle()
            } else if char == ":", !inDoubleQuote {
                return index
            }
        }
        return nil
    }

    private func normalizeMetadataValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.first == "\"",
              trimmed.last == "\""
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    private func flowNodeShape(forMetadataShape rawShape: String) -> FlowNodeShape? {
        switch rawShape.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rect", "rectangle", "proc", "process":
            return .rectangle
        case "rounded", "event":
            return .rounded
        case "stadium", "pill", "terminal":
            return .stadium
        case "subproc", "subprocess", "subroutine", "fr-rect", "framed-rectangle":
            return .subroutine
        case "cyl", "cylinder", "database", "db":
            return .cylindrical
        case "circle", "circ", "sm-circ", "small-circle", "start":
            return .circle
        case "dbl-circ", "double-circle", "fr-circ", "framed-circle", "stop":
            return .doubleCircle
        case "diamond", "diam", "decision", "question":
            return .diamond
        case "hex", "hexagon", "prepare":
            return .hexagon
        case "lean-r", "lean-right", "in-out":
            return .parallelogram
        case "lean-l", "lean-left", "out-in":
            return .parallelogramAlt
        case "trap-b", "trapezoid", "trapezoid-bottom", "priority":
            return .trapezoid
        case "trap-t", "inv-trapezoid", "trapezoid-top", "manual":
            return .trapezoidAlt
        case "bang":
            return .bang
        case "notch-rect", "card", "notched-rectangle":
            return .notchedRectangle
        case "cloud":
            return .cloud
        case "hourglass", "collate":
            return .hourglass
        case "bolt", "com-link", "lightning-bolt":
            return .bolt
        case "brace", "brace-l", "comment":
            return .brace
        case "brace-r":
            return .braceRight
        case "braces":
            return .braces
        case "datastore", "data-store":
            return .datastore
        case "h-cyl", "das", "horizontal-cylinder":
            return .horizontalCylinder
        case "lin-cyl", "disk", "lined-cylinder":
            return .linedCylinder
        case "curv-trap", "display":
            return .curvedTrapezoid
        case "div-rect", "div-proc", "divided-process", "divided-rectangle":
            return .dividedRectangle
        case "doc", "document":
            return .document
        case "delay", "half-rounded-rectangle":
            return .delay
        case "tri", "extract", "triangle":
            return .triangle
        case "fork", "join":
            return .forkJoin
        case "win-pane", "internal-storage", "window-pane":
            return .windowPane
        case "f-circ", "filled-circle", "junction":
            return .filledCircle
        case "lin-doc", "lined-document":
            return .linedDocument
        case "lin-rect", "lin-proc", "lined-process", "lined-rectangle", "shaded-process":
            return .dividedRectangle
        case "notch-pent", "loop-limit", "notched-pentagon":
            return .notchedPentagon
        case "flip-tri", "manual-file":
            return .flippedTriangle
        case "sl-rect", "manual-input", "sloped-rectangle":
            return .slopedRectangle
        case "docs", "documents", "st-doc", "stacked-document":
            return .stackedDocument
        case "st-rect", "processes", "procs", "stacked-rectangle":
            return .stackedRectangle
        case "flag", "paper-tape":
            return .flag
        case "bow-rect", "stored-data", "bow-tie-rectangle":
            return .bowTieRectangle
        case "cross-circ", "summary", "crossed-circle":
            return .crossedCircle
        case "tag-doc", "tagged-document":
            return .taggedDocument
        case "tag-rect", "tag-proc", "tagged-process", "tagged-rectangle":
            return .taggedRectangle
        case "text":
            return .textBlock
        case "odd":
            return .odd
        default:
            return nil
        }
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

    private struct SequenceBlockBuilder {
        let kind: SequenceBlockKind
        let label: String
        let startMessageIndex: Int
        var elseBlocks: [SequenceElseBlock] = []
    }

    private struct SequenceParticipantDeclaration {
        let id: String
        let alias: String?
        let kind: SequenceParticipantKind?
    }

    private final class SequenceBoxBuilder {
        let label: String?
        let color: String?
        var participantIds: [String] = []

        init(label: String?, color: String?) {
            self.label = label
            self.color = color
        }

        func addParticipant(_ id: String) {
            guard !participantIds.contains(id) else { return }
            participantIds.append(id)
        }

        func build() -> SequenceBox {
            SequenceBox(label: label, color: color, participantIds: participantIds)
        }
    }

    private func parseSequence(lines: [String]) -> SequenceDiagram {
        var participants: [SequenceParticipant] = []
        var messages: [SequenceMessage] = []
        var notes: [SequenceNote] = []
        var blocks: [SequenceBlock] = []
        var boxes: [SequenceBox] = []
        var links: [SequenceLink] = []
        var knownIds: Set<String> = []
        var autonumber = false
        var autonumberStart = 1.0
        var autonumberIncrement = 1.0

        var blockStack: [SequenceBlockBuilder] = []
        var boxStack: [SequenceBoxBuilder] = []

        func closeBlock(_ builder: SequenceBlockBuilder) {
            guard builder.kind != .rect || !builder.label.isEmpty else { return }
            blocks.append(SequenceBlock(
                kind: builder.kind,
                label: builder.label,
                elseBlocks: builder.elseBlocks.isEmpty ? nil : builder.elseBlocks,
                startMessageIndex: builder.startMessageIndex,
                endMessageIndex: max(builder.startMessageIndex, messages.count - 1)
            ))
        }

        func addParticipant(_ participant: SequenceParticipant) {
            boxStack.last?.addParticipant(participant.id)
            guard !knownIds.contains(participant.id) else { return }
            participants.append(participant)
            knownIds.insert(participant.id)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let lower = trimmed.lowercased()

            // autonumber [start] [increment]
            if lower == "autonumber" || lower.hasPrefix("autonumber ") {
                autonumber = true
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if parts.count >= 2, let start = Double(parts[1]) {
                    autonumberStart = start
                }
                if parts.count >= 3, let increment = Double(parts[2]) {
                    autonumberIncrement = increment
                }
                continue
            }

            // activate / deactivate keywords
            if lower.hasPrefix("activate ") || lower.hasPrefix("deactivate ") {
                continue
            }

            // create/destroy actor or participant directives.
            if lower.hasPrefix("create ") {
                let declaration = String(trimmed.dropFirst("create ".count)).trimmingCharacters(in: .whitespaces)
                if let participant = parseParticipant(declaration) {
                    addParticipant(participant)
                }
                continue
            }
            if lower.hasPrefix("destroy ") {
                continue
            }

            // Actor menus: `link Actor: Label @ URL` and JSON `links Actor: {...}`.
            if let parsedLinks = parseSequenceLinks(trimmed) {
                for link in parsedLinks {
                    addParticipant(SequenceParticipant(id: link.actorId, label: link.actorId, isActor: false))
                }
                links.append(contentsOf: parsedLinks)
                continue
            }

            // box ... end groups participants in a vertical background band.
            if lower == "box" || lower.hasPrefix("box ") {
                let header = lower == "box"
                    ? ""
                    : String(trimmed.dropFirst("box ".count)).trimmingCharacters(in: .whitespaces)
                let box = parseSequenceBoxHeader(header)
                boxStack.append(SequenceBoxBuilder(label: box.label, color: box.color))
                continue
            }

            // rect rgb(...) ... end
            if lower.hasPrefix("rect ") || lower == "rect" {
                let color = lower == "rect"
                    ? ""
                    : String(trimmed.dropFirst("rect ".count)).trimmingCharacters(in: .whitespaces)
                blockStack.append(SequenceBlockBuilder(
                    kind: .rect,
                    label: color,
                    startMessageIndex: messages.count
                ))
                continue
            }

            // Block openers: loop, alt, opt, par, critical, break
            if let blockInfo = parseBlockOpener(lower, raw: trimmed) {
                blockStack.append(SequenceBlockBuilder(
                    kind: blockInfo.kind,
                    label: blockInfo.label,
                    startMessageIndex: messages.count
                ))
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

            // end (closes message block first, otherwise a participant box)
            if lower == "end" {
                if let top = blockStack.popLast() {
                    closeBlock(top)
                } else if let box = boxStack.popLast() {
                    boxes.append(box.build())
                }
                continue
            }

            // Note
            if let note = parseSequenceNote(trimmed) {
                // Auto-add actors from notes.
                for actor in note.actors {
                    addParticipant(SequenceParticipant(id: actor, label: actor, isActor: false))
                }
                notes.append(note)
                continue
            }

            // participant / actor
            if let p = parseParticipant(trimmed) {
                addParticipant(p)
                continue
            }

            // message
            if let msg = parseSequenceMessage(trimmed) {
                // Auto-add participants if not declared.
                for pid in [msg.from, msg.to] {
                    addParticipant(SequenceParticipant(id: pid, label: pid, isActor: false))
                }
                messages.append(msg)
            }
        }

        // Close unclosed blocks (error recovery).
        while let top = blockStack.popLast() {
            closeBlock(top)
        }
        while let box = boxStack.popLast() {
            boxes.append(box.build())
        }

        return SequenceDiagram(
            participants: participants,
            messages: messages,
            notes: notes,
            blocks: blocks,
            boxes: boxes,
            links: links,
            autonumber: autonumber,
            autonumberStart: autonumberStart,
            autonumberIncrement: autonumberIncrement
        )
    }

    /// Parse a block-opening keyword (loop, alt, opt, par, critical, break).
    private func parseBlockOpener(_ lower: String, raw: String) -> (kind: SequenceBlockKind, label: String)? {
        let patterns: [(prefix: String, kind: SequenceBlockKind)] = [
            ("loop ", .loop),
            ("alt ", .alt),
            ("opt ", .opt),
            ("par ", .par),
            ("critical ", .critical),
            ("break ", .break),
        ]
        if let match = patterns.first(where: { lower.hasPrefix($0.prefix) }) {
            let label = String(raw.dropFirst(match.prefix.count)).trimmingCharacters(in: .whitespaces)
            return (match.kind, label)
        }

        // Handle keyword without label: "loop" with no text after it.
        let keywordOnly: [(keyword: String, kind: SequenceBlockKind)] = [
            ("loop", .loop), ("alt", .alt), ("opt", .opt),
            ("par", .par), ("critical", .critical),
        ]
        if let match = keywordOnly.first(where: { lower == $0.keyword }) {
            return (match.kind, "")
        }
        return nil
    }

    private func parseSequenceBoxHeader(_ header: String) -> (label: String?, color: String?) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, nil) }
        let lower = trimmed.lowercased()

        for prefix in ["rgb(", "rgba(", "hsl(", "hsla("] where lower.hasPrefix(prefix) {
            guard let close = trimmed.firstIndex(of: ")") else { return (trimmed, nil) }
            let color = String(trimmed[...close])
            let afterColor = trimmed.index(after: close)
            let label = String(trimmed[afterColor...]).trimmingCharacters(in: .whitespaces)
            return (label.isEmpty ? nil : normalize(label), color)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return (nil, nil) }
        if Self.sequenceBoxColorNames.contains(first.lowercased()) {
            let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return (label.isEmpty ? nil : normalize(label), first)
        }

        return (normalize(trimmed), nil)
    }

    private static let sequenceBoxColorNames: Set<String> = [
        "aqua", "black", "blue", "brown", "cyan", "gray", "green", "grey",
        "lime", "magenta", "orange", "pink", "purple", "red", "transparent",
        "violet", "white", "yellow",
    ]

    private func parseSequenceLinks(_ line: String) -> [SequenceLink]? {
        let lower = line.lowercased()
        if lower.hasPrefix("link ") {
            return parseSingleSequenceLink(String(line.dropFirst("link ".count)))
        }
        if lower.hasPrefix("links ") {
            return parseJSONSequenceLinks(String(line.dropFirst("links ".count)))
        }
        return nil
    }

    private func parseSingleSequenceLink(_ rest: String) -> [SequenceLink]? {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let actorId = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
        let payloadStart = rest.index(after: colon)
        let payload = String(rest[payloadStart...]).trimmingCharacters(in: .whitespaces)
        guard let separator = payload.range(of: " @ ") ?? payload.range(of: "@") else { return nil }
        let label = String(payload[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        let url = String(payload[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !actorId.isEmpty, !label.isEmpty, !url.isEmpty else { return nil }
        return [SequenceLink(actorId: actorId, label: normalize(label), url: url)]
    }

    private func parseJSONSequenceLinks(_ rest: String) -> [SequenceLink]? {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let actorId = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
        let payloadStart = rest.index(after: colon)
        let jsonText = String(rest[payloadStart...]).trimmingCharacters(in: .whitespaces)
        guard !actorId.isEmpty,
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let linksByLabel = object as? [String: String]
        else { return nil }

        return linksByLabel.keys.sorted().compactMap { label in
            guard let url = linksByLabel[label], !label.isEmpty, !url.isEmpty else { return nil }
            return SequenceLink(actorId: actorId, label: normalize(label), url: url)
        }
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
        let baseKind: SequenceParticipantKind

        if line.hasPrefix("participant ") {
            isActor = false
            baseKind = .participant
            rest = String(line.dropFirst("participant ".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("actor ") {
            isActor = true
            baseKind = .actor
            rest = String(line.dropFirst("actor ".count)).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        let (declaration, externalAlias) = splitParticipantAlias(rest)
        let parsed = parseParticipantDeclaration(declaration)
        guard !parsed.id.isEmpty else { return nil }

        let label = externalAlias.map(normalize)
            ?? parsed.alias.map(normalize)
            ?? normalize(parsed.id)
        return SequenceParticipant(
            id: parsed.id,
            label: label,
            isActor: isActor,
            kind: parsed.kind ?? baseKind
        )
    }

    private func splitParticipantAlias(_ rest: String) -> (declaration: String, alias: String?) {
        var inDoubleQuote = false
        var braceDepth = 0
        var index = rest.startIndex

        while index < rest.endIndex {
            let char = rest[index]
            if char == "\"" {
                inDoubleQuote.toggle()
            } else if !inDoubleQuote {
                if char == "{" {
                    braceDepth += 1
                } else if char == "}" {
                    braceDepth = max(0, braceDepth - 1)
                } else if braceDepth == 0,
                          rest[index...].hasPrefix(" as ") {
                    let declaration = String(rest[..<index]).trimmingCharacters(in: .whitespaces)
                    let aliasStart = rest.index(index, offsetBy: 4)
                    let alias = String(rest[aliasStart...]).trimmingCharacters(in: .whitespaces)
                    return (declaration, alias.isEmpty ? nil : alias)
                }
            }
            index = rest.index(after: index)
        }

        return (rest.trimmingCharacters(in: .whitespaces), nil)
    }

    private func parseParticipantDeclaration(_ declaration: String) -> SequenceParticipantDeclaration {
        guard let marker = declaration.range(of: "@{") else {
            return SequenceParticipantDeclaration(
                id: declaration.trimmingCharacters(in: .whitespaces),
                alias: nil,
                kind: nil
            )
        }

        let id = String(declaration[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
        let bodyStart = marker.upperBound
        guard let end = declaration[bodyStart...].lastIndex(of: "}") else {
            return SequenceParticipantDeclaration(id: id, alias: nil, kind: nil)
        }

        let body = String(declaration[bodyStart..<end])
        let properties = parseMetadataProperties(body)
        let alias = properties["alias"]
        let kind = properties["type"]
            .map(normalizeMetadataValue)
            .flatMap { SequenceParticipantKind(rawValue: $0.lowercased()) }
        return SequenceParticipantDeclaration(id: id, alias: alias, kind: kind)
    }

    /// Parse sequence message: `A->>B: text`, `A-->>B: text`, etc.
    private func parseSequenceMessage(_ line: String) -> SequenceMessage? {
        // Find the arrow pattern.
        // Order matters: longer patterns first.
        let arrowPatterns: [(String, SequenceArrowStyle)] = [
            ("<<-->>", .dashedBidirectional),
            ("<<->>", .solidBidirectional),
            ("--\\|\\", .dashedTopHalfArrow),
            ("-\\|\\", .solidTopHalfArrow),
            ("--\\|/", .dashedBottomHalfArrow),
            ("-\\|/", .solidBottomHalfArrow),
            ("/\\|--", .dashedReverseTopHalfArrow),
            ("/\\|-", .solidReverseTopHalfArrow),
            ("\\\\--", .dashedReverseBottomHalfArrow),
            ("\\\\-", .solidReverseBottomHalfArrow),
            ("--\\\\", .dashedTopStickHalfArrow),
            ("-\\\\", .solidTopStickHalfArrow),
            ("--//", .dashedBottomStickHalfArrow),
            ("-//", .solidBottomStickHalfArrow),
            ("//--", .dashedReverseTopStickHalfArrow),
            ("//-", .solidReverseTopStickHalfArrow),
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
                var from = String(line[line.startIndex ..< range.lowerBound]).trimmingCharacters(in: .whitespaces)
                var remaining = String(line[range.upperBound...])

                let fromCentral = from.hasSuffix("()")
                if fromCentral {
                    from = String(from.dropLast(2)).trimmingCharacters(in: .whitespaces)
                }

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
                var to = firstPart.trimmingCharacters(in: .whitespaces)
                let toCentral = to.hasPrefix("()")
                if toCentral {
                    to = String(to.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                let text = parts.count > 1 ? normalize(parts[1].trimmingCharacters(in: .whitespaces)) : ""

                if !from.isEmpty, !to.isEmpty {
                    return SequenceMessage(
                        from: from, to: to, text: text,
                        arrowStyle: style,
                        activationModifier: activationModifier,
                        fromCentral: fromCentral,
                        toCentral: toCentral
                    )
                }
            }
        }

        return nil
    }
}
