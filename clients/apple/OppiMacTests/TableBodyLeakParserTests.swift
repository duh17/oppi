import Testing
@testable import Oppi

/// Shared-core parser proof for the streaming mid-row freeze.
/// Not a Mac paint test and not a claim about the static fullscreen screenshot.
@Suite("Table body leak parser")
struct TableBodyLeakParserTests {
    private static let expectedBodyTitles = [
        "Cheap collapsed tool rows",
        "Bounded preparation runway",
        "Thermal work admission",
        "Separate diagram parse/layout/raster caching",
        "Larger Markdown segment cache",
        "Core Text tool follow-tail measurement",
        "Cached-height timeline layout",
        "Suffix-only native attributed conversion and TextKit append",
        "Unused streaming cache/test surface/plain-host fallback deletion",
        "Reserved Mermaid/math geometry and source fallback",
    ]

    private static let tenRowTableMarkdown = """
    | Work | Commit | Qualification |
    |---|---|---|
    | Cheap collapsed tool rows | `563a6bed` | Do not propose this split again. |
    | Bounded preparation runway | `522d5163` | Existing owner; do not add another broker. |
    | Thermal work admission | `605ad1dc` | Preserve it. |
    | Separate diagram parse/layout/raster caching | `918a37df` | Does not imply a GPU bottleneck. |
    | Larger Markdown segment cache | `00312c24` | Cache-cap increase, not completed fullscreen first-open optimization. |
    | Core Text tool follow-tail measurement | `76daea89` | Removed forced TextKit layout; whole-text measurement remains. |
    | Cached-height timeline layout | `2b075fe2` | Custom layout already exists. |
    | Suffix-only native attributed conversion and TextKit append | `36cc390e` | Upstream segment construction and change detection remain. |
    | Unused streaming cache/test surface/plain-host fallback deletion | `f227e4f1` | Do not count those as remaining removals. |
    | Reserved Mermaid/math geometry and source fallback | `1a4a253b`, `0e78323c` | Later session records Chen's device confirmation. |
    """

    @Test(arguments: [24, 1])
    func streamingCharacterChunksKeepEveryLandedRowOnce(chunkSize: Int) throws {
        var parser = CommonMarkStreamingParser()
        var content = ""
        forEachChunk(Self.tenRowTableMarkdown, size: chunkSize) { prefix in
            content = prefix
            #expect(parser.parse(prefix).blocks == parseCommonMark(prefix))
        }
        try assertIntactTable(parser.parse(content).blocks)
    }

    @Test(arguments: [24, 1])
    func optionalLeadingPipeRowsStayOneTable(chunkSize: Int) throws {
        let source = Self.optionalLeadingPipeTable(Self.tenRowTableMarkdown)
        var parser = CommonMarkStreamingParser()
        var content = ""
        forEachChunk(source, size: chunkSize) { prefix in
            content = prefix
            #expect(parser.parse(prefix).blocks == parseCommonMark(prefix))
        }
        try assertIntactTable(parser.parse(content).blocks)
    }

    @Test(arguments: [24, 1])
    func quotedTableRowsStayOneTable(chunkSize: Int) throws {
        let source = Self.quoted(Self.tenRowTableMarkdown)
        var parser = CommonMarkStreamingParser()
        var content = ""
        forEachChunk(source, size: chunkSize) { prefix in
            content = prefix
            #expect(parser.parse(prefix).blocks == parseCommonMark(prefix))
        }
        try assertIntactTable(parser.parse(content).blocks)
    }

    @Test func blankAfterTableDoesNotFoldLaterPipes() throws {
        var parser = CommonMarkStreamingParser()
        var content = ""
        forEachChunk(Self.tenRowTableMarkdown, size: 24) { prefix in
            content = prefix
            _ = parser.parse(prefix)
        }
        try assertIntactTable(parser.parse(content).blocks)

        content += "\n\n| Extra leaked | `deadbeef` | should stay prose |\n"
        let parsed = parser.parse(content)
        #expect(parsed.blocks == parseCommonMark(content))
        try assertIntactTable(parsed.blocks)
        let prose = visibleProse(parsed.blocks)
        #expect(prose.contains("| Extra leaked") || prose.contains("Extra leaked"))
    }

    private func forEachChunk(_ source: String, size: Int, body: (String) -> Void) {
        var content = ""
        let chars = Array(source)
        var offset = 0
        while offset < chars.count {
            let end = min(offset + size, chars.count)
            content.append(contentsOf: chars[offset..<end])
            offset = end
            body(content)
        }
    }

    private func assertIntactTable(_ blocks: [MarkdownBlock]) throws {
        let table = try #require(landedTable(in: blocks))
        #expect(table.headers.map { plainText(from: $0) } == ["Work", "Commit", "Qualification"])
        #expect(table.rows.count == 10)
        #expect(table.rows.map { plainText(from: $0.first ?? []) } == Self.expectedBodyTitles)
        let prose = visibleProse(blocks)
        for title in Self.expectedBodyTitles {
            #expect(!prose.contains(title), "row title leaked as prose: \(title)")
        }
    }

    private func landedTable(
        in blocks: [MarkdownBlock]
    ) -> (headers: [[MarkdownInline]], rows: [[[MarkdownInline]]])? {
        for block in blocks {
            if let table = landedTable(block) { return table }
        }
        return nil
    }

    private func landedTable(
        _ block: MarkdownBlock
    ) -> (headers: [[MarkdownInline]], rows: [[[MarkdownInline]]])? {
        switch block {
        case .table(let headers, let rows)
            where headers.first.map({ plainText(from: $0) }) == "Work":
            return (headers, rows)
        case .blockQuote(let children):
            return landedTable(in: children)
        case .unorderedList(let items):
            for item in items {
                if let table = landedTable(in: item) { return table }
            }
            return nil
        case .orderedList(_, let items):
            for item in items {
                if let table = landedTable(in: item) { return table }
            }
            return nil
        default:
            return nil
        }
    }

    private func visibleProse(_ blocks: [MarkdownBlock]) -> String {
        blocks.flatMap(proseLines).joined(separator: "\n")
    }

    private func proseLines(_ block: MarkdownBlock) -> [String] {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines):
            return [plainText(from: inlines)]
        case .blockQuote(let children):
            return children.flatMap(proseLines)
        case .unorderedList(let items):
            return items.flatMap { $0.flatMap(proseLines) }
        case .orderedList(_, let items):
            return items.flatMap { $0.flatMap(proseLines) }
        default:
            return []
        }
    }

    private static func optionalLeadingPipeTable(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                trimmed.removeFirst()
            }
            if trimmed.hasSuffix("|") {
                trimmed.removeLast()
            }
            return trimmed.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private static func quoted(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }
}
