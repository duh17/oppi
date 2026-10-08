import Foundation

/// Original-source index used while parsing. Offsets are UTF-8 bytes.
struct MermaidSourceIndex: Sendable {
    struct Line: Sendable {
        let number: Int
        let utf8Start: Int
        let text: String
        /// Byte offset where a trailing `%%` comment begins, or `text.utf8.count`.
        let commentCut: Int

        var stripped: String {
            String(decoding: Array(text.utf8.prefix(commentCut)), as: UTF8.self)
        }
    }

    let source: String
    let revision: String
    let lines: [Line]

    init(source: String) {
        self.source = source
        self.revision = SemanticSourceRevision.hash(of: source)
        self.lines = Self.indexLines(source)
    }

    func span(line: Line, byteRange: Range<Int>, role: SemanticSpanRole) -> SemanticSourceSpan {
        let lower = max(0, min(byteRange.lowerBound, line.text.utf8.count))
        let upper = max(lower, min(byteRange.upperBound, line.text.utf8.count))
        let excerpt = Self.excerpt(line.text, bytes: lower..<upper)
        return SemanticSourceSpan(
            startOffset: line.utf8Start + lower,
            endOffset: line.utf8Start + upper,
            startLine: line.number,
            startColumn: lower + 1,
            endLine: line.number,
            endColumn: upper + 1,
            role: role,
            excerpt: excerpt
        )
    }

    static func stripComment(_ line: String) -> String {
        let cut = commentCut(in: line)
        return String(decoding: Array(line.utf8.prefix(cut)), as: UTF8.self)
    }

    static func commentCut(in line: String) -> Int {
        var inDoubleQuote = false
        var byte = 0
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if character == "\"" { inDoubleQuote.toggle() }
            if !inDoubleQuote, index + 1 < chars.count, chars[index] == "%", chars[index + 1] == "%" {
                if index + 2 < chars.count, chars[index + 2] == "{" {
                    byte += character.utf8.count
                    index += 1
                    continue
                }
                return byte
            }
            byte += character.utf8.count
            index += 1
        }
        return byte
    }

    static func byteRange(in text: String, characters: Range<Int>) -> Range<Int> {
        var charIndex = 0
        var byte = 0
        var start = 0
        for character in text {
            if charIndex == characters.lowerBound {
                start = byte
            }
            let next = byte + character.utf8.count
            charIndex += 1
            if charIndex == characters.upperBound {
                return start..<next
            }
            byte = next
        }
        return start..<byte
    }

    static func excerpt(_ text: String, bytes: Range<Int>) -> String {
        let utf8 = Array(text.utf8)
        guard bytes.lowerBound >= 0, bytes.upperBound <= utf8.count, bytes.lowerBound <= bytes.upperBound else {
            return ""
        }
        return String(decoding: utf8[bytes], as: UTF8.self)
    }

    private static func indexLines(_ source: String) -> [Line] {
        var lines: [Line] = []
        var lineStart = source.startIndex
        var number = 1
        var index = source.startIndex
        func append(end: String.Index) {
            let text = String(source[lineStart..<end])
            let utf8Start = source.utf8.distance(
                from: source.utf8.startIndex,
                to: lineStart.samePosition(in: source.utf8) ?? source.utf8.endIndex
            )
            lines.append(Line(
                number: number,
                utf8Start: utf8Start,
                text: text,
                commentCut: commentCut(in: text)
            ))
            number += 1
        }
        let newlines = CharacterSet.newlines
        while index < source.endIndex {
            let character = source[index]
            if character.unicodeScalars.allSatisfy({ newlines.contains($0) }) {
                append(end: index)
                index = source.index(after: index)
                lineStart = index
            } else {
                index = source.index(after: index)
            }
        }
        append(end: source.endIndex)
        return lines
    }
}

enum MermaidSemanticID {
    static func node(_ id: String) -> String { "node:\(id)" }
    static func slice(_ ordinal: Int) -> String { "slice:\(ordinal)" }
    static func participant(_ id: String) -> String { "participant:\(id)" }
    static func message(_ ordinal: Int) -> String { "message:\(ordinal)" }

    /// Explicit ids and fallback ordinals live in disjoint namespaces, so a
    /// numeric id cannot collide with an earlier or later ordinal. Repeated
    /// explicit ids keep the first claim and give later copies an ordinal id.
    struct EdgeAllocator: Sendable {
        private var ordinal = 0
        private var claimedExplicit: Set<String> = []

        struct Allocated: Equatable, Sendable {
            var id: String
            var ordinal: Int
        }

        mutating func next(explicitID: String?) -> Allocated {
            ordinal += 1
            if let explicitID, !explicitID.isEmpty, claimedExplicit.insert(explicitID).inserted {
                return Allocated(id: "edge:id:\(explicitID)", ordinal: ordinal)
            }
            return Allocated(id: "edge:ord:\(ordinal)", ordinal: ordinal)
        }
    }

    static func edgeIDs(explicitIDs: [String?]) -> [String] {
        var allocator = EdgeAllocator()
        return explicitIDs.map { allocator.next(explicitID: $0).id }
    }

    static func edgeIDs(for edges: [FlowEdge]) -> [String] {
        edgeIDs(explicitIDs: edges.map(\.id))
    }
}

struct MermaidAnnotatedParse: Sendable {
    let diagram: MermaidDiagram
    let ledger: SemanticSourceLedger
}

struct SemanticSourceLedger: Equatable, Sendable {
    var revision: String
    var targets: [SemanticTarget]
}

/// Filled by the existing parsers as they accept constructs. Not a second grammar.
final class SemanticSourceCollector: @unchecked Sendable {
    let index: MermaidSourceIndex
    private var targets: [String: SemanticTarget] = [:]
    private var order: [String] = []
    private var edgeAllocator = MermaidSemanticID.EdgeAllocator()
    private var sliceOrdinal = 0
    private var messageOrdinal = 0

    init(index: MermaidSourceIndex) {
        self.index = index
    }

    var ledger: SemanticSourceLedger {
        SemanticSourceLedger(
            revision: index.revision,
            targets: order.compactMap { targets[$0] }
        )
    }

    func addFlowNode(
        id: String,
        label: String,
        shapeIsImplicit: Bool,
        line: MermaidSourceIndex.Line,
        byteRange: Range<Int>
    ) {
        let targetID = MermaidSemanticID.node(id)
        let hasDeclaration = targets[targetID]?.spans.contains { $0.role == .declaration } ?? false
        let role: SemanticSpanRole = (!shapeIsImplicit && !hasDeclaration) ? .declaration : .reference
        let span = index.span(line: line, byteRange: byteRange, role: role)
        upsert(
            id: targetID,
            kind: "flowchart.node",
            label: label,
            displayKey: id,
            span: span,
            origin: .source,
            adoptExplicitLabel: !shapeIsImplicit && !hasDeclaration
        )
    }

    func addFlowEdge(
        explicitID: String?,
        from: String,
        to: String,
        label: String?,
        line: MermaidSourceIndex.Line,
        byteRange: Range<Int>,
        endpointRanges: [Range<Int>]
    ) {
        let allocated = edgeAllocator.next(explicitID: explicitID)
        let display = (label?.isEmpty == false ? label : nil) ?? "\(from) → \(to)"
        let declaration = index.span(line: line, byteRange: byteRange, role: .declaration)
        upsert(
            id: allocated.id,
            kind: "flowchart.edge",
            label: display,
            displayKey: "\(from) → \(to) #\(allocated.ordinal)",
            span: declaration,
            origin: .source
        )
        for range in endpointRanges {
            let reference = index.span(line: line, byteRange: range, role: .reference)
            appendSpan(reference, to: allocated.id)
        }
    }

    func addPieSlice(label: String, line: MermaidSourceIndex.Line, byteRange: Range<Int>) {
        sliceOrdinal += 1
        let span = index.span(line: line, byteRange: byteRange, role: .declaration)
        upsert(
            id: MermaidSemanticID.slice(sliceOrdinal),
            kind: "pie.slice",
            label: label,
            displayKey: "slice \(sliceOrdinal)",
            span: span,
            origin: .source
        )
    }

    func addSequenceParticipant(
        id: String,
        label: String,
        line: MermaidSourceIndex.Line,
        byteRange: Range<Int>,
        isDeclaration: Bool
    ) {
        let span = index.span(
            line: line,
            byteRange: byteRange,
            role: isDeclaration ? .declaration : .reference
        )
        upsert(
            id: MermaidSemanticID.participant(id),
            kind: "sequence.participant",
            label: label,
            displayKey: id,
            span: span,
            origin: .source
        )
    }

    func addSequenceMessage(
        from: String,
        to: String,
        label: String,
        line: MermaidSourceIndex.Line,
        byteRange: Range<Int>
    ) {
        messageOrdinal += 1
        let text = label.isEmpty ? "\(from) → \(to)" : label
        let span = index.span(line: line, byteRange: byteRange, role: .declaration)
        upsert(
            id: MermaidSemanticID.message(messageOrdinal),
            kind: "sequence.message",
            label: text,
            displayKey: "\(from) → \(to) #\(messageOrdinal)",
            span: span,
            origin: .source
        )
    }

    private func upsert(
        id: String,
        kind: String,
        label: String,
        displayKey: String,
        span: SemanticSourceSpan,
        origin: SemanticSourceOrigin,
        adoptExplicitLabel: Bool = false
    ) {
        if var existing = targets[id] {
            if existing.spans.contains(span) == false {
                existing.spans.append(span)
            }
            // Flowchart keeps the first explicit shape. A later real label
            // replaces only a raw identifier, matching `nodesById`.
            let stillRawIdentifier = existing.label.isEmpty || existing.label == existing.displayKey
            if adoptExplicitLabel, !label.isEmpty, stillRawIdentifier {
                existing.label = label
            }
            targets[id] = existing
            return
        }
        order.append(id)
        targets[id] = SemanticTarget(
            id: id,
            kind: kind,
            label: label,
            displayKey: displayKey,
            spans: [span],
            sourceOrigin: origin,
            sourceRevision: index.revision
        )
    }

    private func appendSpan(_ span: SemanticSourceSpan, to id: String) {
        guard var existing = targets[id] else { return }
        if existing.spans.contains(span) == false {
            existing.spans.append(span)
        }
        targets[id] = existing
    }
}

enum MermaidSemanticAnnotation {
    static func map(
        source: String,
        diagram: MermaidDiagram,
        layout: MermaidFlowchartRenderer.FlowchartLayout
    ) -> SemanticAnnotationMap? {
        let ledger = MermaidParser().parseAnnotated(source).ledger
        let regions = layout.semanticRegions
        guard !ledger.targets.isEmpty, !regions.isEmpty else { return nil }
        let regionIDs = Set(regions.map(\.targetID))
        let targets = ledger.targets.filter { regionIDs.contains($0.id) }
        guard !targets.isEmpty else { return nil }
        let keptIDs = Set(targets.map(\.id))
        return SemanticAnnotationMap(
            sourceRevision: ledger.revision,
            targets: targets,
            regions: regions.filter { keptIDs.contains($0.targetID) }
        )
    }
}
