import Foundation
import Testing
import UIKit
@testable import Oppi

/// Proven defect: streaming mid-row prefix freeze (short table + pipe prose).
/// Not a claim that the original static fullscreen 6+4 screenshot is fixed.
/// Fullscreen readers use `parseCommonMarkLocated`, never `CommonMarkStreamingParser`.
@Suite("Table body leak regressions")
@MainActor
struct TableBodyLeakRegressionTests {
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

    /// Reproducing input from the character-chunk freeze (2-row table + pipe prose).
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

    @Test func staticParseKeepsEveryRowOnce() throws {
        try assertIntactTable(parseCommonMark(Self.tenRowTableMarkdown))
        try assertIntactTable(parseCommonMarkLocated(Self.tenRowTableMarkdown).map(\.block))
    }

    @Test(arguments: [24, 1])
    func streamingParserKeepsEveryRowOnCharacterChunks(chunkSize: Int) throws {
        var parser = CommonMarkStreamingParser()
        var content = ""
        forEachChunk(Self.tenRowTableMarkdown, size: chunkSize) { prefix in
            content = prefix
            #expect(parser.parse(prefix).blocks == parseCommonMark(prefix))
        }
        try assertIntactTable(parser.parse(content).blocks)
    }

    @Test(arguments: [24, 1])
    func contentViewApplyKeepsEveryRowOnStreamedChunks(chunkSize: Int) throws {
        let (markdown, window) = makeHostedMarkdown()
        defer { window.isHidden = true }

        var content = ""
        forEachChunk(Self.tenRowTableMarkdown, size: chunkSize) { prefix in
            content = prefix
            markdown.apply(configuration: .make(
                content: prefix,
                isStreaming: true,
                themeID: .dark
            ))
        }
        layoutHosted(markdown, window: window)
        try assertMountedTenRowTable(in: markdown)

        if chunkSize == 24 {
            try writeStreamedRender(of: markdown, to: "/tmp/oppi-table-body-leak-streamed-24.png")
        }

        markdown.apply(configuration: .make(
            content: content,
            isStreaming: false,
            themeID: .light
        ))
        layoutHosted(markdown, window: window)
        try assertMountedTenRowTable(in: markdown)
    }

    @Test(arguments: [24, 1])
    func streamingParserHoldsOptionalLeadingPipeRows(chunkSize: Int) throws {
        let source = Self.optionalLeadingPipeTable(Self.tenRowTableMarkdown)
        var parser = CommonMarkStreamingParser()
        var content = ""
        forEachChunk(source, size: chunkSize) { prefix in
            content = prefix
            #expect(parser.parse(prefix).blocks == parseCommonMark(prefix))
        }
        try assertIntactTable(parser.parse(content).blocks)
        try assertIntactTable(parseCommonMark(source))
    }

    @Test(arguments: [24, 1])
    func streamingParserKeepsQuotedTableRows(chunkSize: Int) throws {
        let source = Self.quoted(Self.tenRowTableMarkdown)
        var parser = CommonMarkStreamingParser()
        var content = ""
        forEachChunk(source, size: chunkSize) { prefix in
            content = prefix
            #expect(parser.parse(prefix).blocks == parseCommonMark(prefix))
        }
        try assertIntactTable(parser.parse(content).blocks)
    }

    @Test func holdThenBlankLeavesLaterPipesAsProse() throws {
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
        #expect(landedRowCount(in: parsed.blocks) == 10)
    }

    @Test func blankLineAfterSixRowsStaysOrdinaryGFMProse() throws {
        let sixThenBlank = """
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

        After the table.
        """
        var parser = CommonMarkStreamingParser()
        var content = ""
        forEachChunk(sixThenBlank, size: 24) { prefix in
            content = prefix
            #expect(parser.parse(prefix).blocks == parseCommonMark(prefix))
        }
        let blocks = parser.parse(content).blocks
        #expect(landedRowCount(in: blocks) == 6)
        let prose = visibleProse(blocks)
        #expect(prose.contains("| Cached-height timeline layout") || prose.contains("Cached-height timeline layout"))
        #expect(prose.contains("After the table."))
        #expect(!prose.contains("Cheap collapsed tool rows"))
    }

    @Test func streamingParserPromotesHeaderWhenDelimiterArrives() throws {
        var parser = CommonMarkStreamingParser()
        let header = "| Work | Commit | Qualification |\n"
        let headerBlocks = parser.parse(header).blocks
        #expect(landedRowCount(in: headerBlocks) == nil)
        #expect(visibleProse(headerBlocks).contains("| Work |"))

        let withRows = header + "|---|---|---|\n| Cheap collapsed tool rows | `563a6bed` | keep |\n"
        let parsed = parser.parse(withRows)
        #expect(parsed.blocks == parseCommonMark(withRows))
        let table = try #require(landedTable(in: parsed.blocks))
        #expect(table.rows.count == 1)
        #expect(plainText(from: table.rows[0][0]) == "Cheap collapsed tool rows")
        #expect(!visibleProse(parsed.blocks).contains("| Work |"))
    }

    @Test func contentViewPromotesHeaderWhenDelimiterArrives() throws {
        let (markdown, window) = makeHostedMarkdown()
        defer { window.isHidden = true }

        let header = "| Work | Commit | Qualification |\n"
        markdown.apply(configuration: .make(content: header, isStreaming: true, themeID: .dark))
        layoutHosted(markdown, window: window)
        #expect(timelineFirstView(ofType: NativeTableBlockView.self, in: markdown) == nil)
        #expect(proseOutsideTable(in: markdown).contains("| Work |"))

        markdown.apply(configuration: .make(
            content: Self.tenRowTableMarkdown,
            isStreaming: true,
            themeID: .dark
        ))
        layoutHosted(markdown, window: window)
        try assertMountedTenRowTable(in: markdown)
        #expect(!proseOutsideTable(in: markdown).contains("| Work |"))
    }

    // MARK: - Hosting / paint

    private func makeHostedMarkdown() -> (AssistantMarkdownContentView, UIWindow) {
        let markdown = AssistantMarkdownContentView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2400))
        markdown.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(markdown)
        NSLayoutConstraint.activate([
            markdown.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            markdown.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            markdown.topAnchor.constraint(equalTo: window.topAnchor),
            markdown.widthAnchor.constraint(equalToConstant: 390),
        ])
        window.makeKeyAndVisible()
        return (markdown, window)
    }

    private func layoutHosted(_ markdown: AssistantMarkdownContentView, window: UIWindow) {
        window.layoutIfNeeded()
        markdown.layoutIfNeeded()
        let size = markdown.systemLayoutSizeFitting(
            CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = max(size.height, 1)
        window.frame.size.height = height
        markdown.frame.size = CGSize(width: 390, height: height)
        window.layoutIfNeeded()
        markdown.layoutIfNeeded()
    }

    private func writeStreamedRender(of markdown: AssistantMarkdownContentView, to path: String) throws {
        let renderer = UIGraphicsImageRenderer(bounds: markdown.bounds)
        let image = renderer.image { context in
            markdown.layer.render(in: context.cgContext)
        }
        let url = URL(fileURLWithPath: path)
        try #require(image.pngData()).write(to: url)
    }

    private func assertMountedTenRowTable(in root: UIView) throws {
        let tables = timelineAllViews(in: root).compactMap { $0 as? NativeTableBlockView }
        #expect(tables.count == 1, "expected exactly one mounted table, got \(tables.count)")
        let table = try #require(tables.first)
        let tableText = timelineRenderedTableText(in: table)
        for title in Self.expectedBodyTitles {
            #expect(tableText.contains(title), "mounted table missing \(title)")
        }
        if let rows = mountedBodyRowCount(in: table) {
            #expect(rows == 10, "mounted body rows \(rows), expected 10")
        } else {
            let found = Self.expectedBodyTitles.filter { tableText.contains($0) }
            #expect(found.count == 10, "clip-mode table titles \(found.count), expected 10")
        }
        let prose = proseOutsideTable(in: root)
        #expect(!containsLeakedPipes(prose), "pipe prose outside table: \(prose)")
        for title in Self.expectedBodyTitles {
            #expect(!prose.contains(title), "row title leaked as prose: \(title)")
        }
    }

    private func mountedBodyRowCount(in table: NativeTableBlockView) -> Int? {
        let stacks = timelineAllViews(in: table).compactMap { $0 as? UIStackView }
        guard let wrap = stacks.first(where: { stack in
            !stack.isHidden
                && stack.axis == .vertical
                && stack.arrangedSubviews.contains(where: { ($0 as? UIStackView)?.axis == .horizontal })
        }) else {
            return nil
        }
        return wrap.arrangedSubviews.filter { $0 is UIStackView }.count - 1
    }

    private func proseOutsideTable(in root: UIView) -> String {
        guard let table = timelineFirstView(ofType: NativeTableBlockView.self, in: root) else {
            return timelineAllTextViews(in: root)
                .map { timelineRenderedText(of: $0) }
                .joined(separator: "\n")
        }
        return timelineAllTextViews(in: root)
            .filter { !$0.isDescendant(of: table) }
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")
    }

    // MARK: - Parser helpers

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
        #expect(!containsLeakedPipes(prose))
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

    private func landedRowCount(in blocks: [MarkdownBlock]) -> Int? {
        landedTable(in: blocks).map { $0.rows.count }
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

    private func containsLeakedPipes(_ text: String) -> Bool {
        Self.expectedBodyTitles.contains { text.contains("| \($0)") || text.contains("|\($0)") }
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
