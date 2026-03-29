import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

// MARK: - FlatSegment.build

@Suite("FlatSegment.build")
struct FlatSegmentBuildTests {

    @Test func emptyBlocksProduceNoSegments() {
        let segments = FlatSegment.build(from: [], themeID: .dark)
        #expect(segments.isEmpty)
    }

    @Test func singleParagraphProducesTextSegment() {
        let blocks: [MarkdownBlock] = [.paragraph([.text("Hello")])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text = segments[0] {} else { Issue.record("Expected .text segment") }
    }

    @Test func codeBlockProducesCodeSegment() {
        let blocks: [MarkdownBlock] = [.codeBlock(language: "swift", code: "let x = 1")]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .codeBlock(let lang, let code) = segments[0] {
            #expect(lang == "swift")
            #expect(code == "let x = 1")
        } else {
            Issue.record("Expected .codeBlock segment")
        }
    }

    @Test func mermaidCodeBlockProducesMermaidDiagramSegment() {
        let blocks: [MarkdownBlock] = [.codeBlock(language: "mermaid", code: "graph TD\n    A-->B")]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .mermaidDiagram(let code) = segments[0] {
            #expect(code == "graph TD\n    A-->B")
        } else {
            Issue.record("Expected .mermaidDiagram segment, got \(segments[0])")
        }
    }

    @Test func mermaidCodeBlockWithMmdAlias() {
        let blocks: [MarkdownBlock] = [.codeBlock(language: "mmd", code: "sequenceDiagram\n    A->>B: Hello")]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .mermaidDiagram = segments[0] {} else {
            Issue.record("Expected .mermaidDiagram for 'mmd' language")
        }
    }

    @Test func nonMermaidCodeBlockStaysAsCodeBlock() {
        let blocks: [MarkdownBlock] = [.codeBlock(language: "python", code: "print('hi')")]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .codeBlock(let lang, _) = segments[0] {
            #expect(lang == "python")
        } else {
            Issue.record("Expected .codeBlock segment for python")
        }
    }

    @Test func tableProducesTableSegment() {
        let blocks: [MarkdownBlock] = [.table(headers: [[.text("A")]], rows: [[[.text("1")]]])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .table(let headers, let rows) = segments[0] {
            #expect(headers.map { plainText(from: $0) } == ["A"])
            #expect(rows.map { $0.map { plainText(from: $0) } } == [["1"]])
        }
    }

    @Test func thematicBreakProducesBreakSegment() {
        let blocks: [MarkdownBlock] = [.thematicBreak]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .thematicBreak = segments[0] {} else { Issue.record("Expected .thematicBreak") }
    }

    @Test func adjacentParagraphsMergeIntoSingleTextSegment() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.text("First")]),
            .paragraph([.text("Second")]),
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        // Adjacent text blocks should be merged into one .text segment
        #expect(segments.count == 1, "Adjacent paragraphs should merge into a single .text segment")
        if case .text(let attr) = segments[0] {
            let plainText = String(attr.characters)
            #expect(plainText.contains("First"))
            #expect(plainText.contains("Second"))
        }
    }

    @Test func codeBlockBreaksTextMerging() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.text("Before")]),
            .codeBlock(language: "js", code: "x()"),
            .paragraph([.text("After")]),
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        // Should be: text("Before"), codeBlock, text("After")
        #expect(segments.count == 3)
        if case .text = segments[0] {} else { Issue.record("Expected text") }
        if case .codeBlock = segments[1] {} else { Issue.record("Expected codeBlock") }
        if case .text = segments[2] {} else { Issue.record("Expected text") }
    }

    @Test func headingProducesTextSegment() {
        let blocks: [MarkdownBlock] = [.heading(level: 1, inlines: [.text("Title")])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text == "Title")
        }
    }

    @Test func blockQuoteProducesTextWithQuoteMarker() {
        let blocks: [MarkdownBlock] = [.blockQuote([.paragraph([.text("Quoted")])])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("▎"))
            #expect(text.contains("Quoted"))
        }
    }

    @Test func unorderedListRendersWithBullets() {
        let blocks: [MarkdownBlock] = [
            .unorderedList([
                [.paragraph([.text("Item A")])],
                [.paragraph([.text("Item B")])],
            ])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("•"))
            #expect(text.contains("Item A"))
            #expect(text.contains("Item B"))
        }
    }

    @Test func orderedListRendersWithNumbers() {
        let blocks: [MarkdownBlock] = [
            .orderedList(start: 1, [
                [.paragraph([.text("First")])],
                [.paragraph([.text("Second")])],
            ])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("1."))
            #expect(text.contains("2."))
            #expect(text.contains("First"))
            #expect(text.contains("Second"))
        }
    }

    @Test func orderedListWithNonOneStart() {
        let blocks: [MarkdownBlock] = [
            .orderedList(start: 5, [
                [.paragraph([.text("Fifth")])],
                [.paragraph([.text("Sixth")])],
            ])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("5."))
            #expect(text.contains("6."))
        }
    }

    @Test func htmlBlockRendersAsMonospaced() {
        let blocks: [MarkdownBlock] = [.htmlBlock("<div>hello</div>")]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("<div>hello</div>"))
        }
    }

    // MARK: - Inline formatting in AttributedString

    @Test func inlineCodeRendersInText() {
        let blocks: [MarkdownBlock] = [.paragraph([.text("Use "), .code("foo()"), .text(" here")])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("foo()"))
        }
    }

    @Test func linkRendersWithText() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.link(children: [.text("Click")], destination: "https://example.com")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("Click"))
        }
    }

    @Test func imageWithAltTextRendersAltInBrackets() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Photo", source: "img.png")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("[Photo]"))
        }
    }

    @Test func imageWithEmptyAltTextProducesNoText() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "", source: "img.png")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        // Empty image alt text produces empty attributed string, which
        // means the paragraph has no visible content.
        if segments.isEmpty {
            // OK — empty paragraph filtered out
        } else if case .text(let attr) = segments[0] {
            #expect(String(attr.characters).isEmpty)
        }
    }

    @Test func strikethroughRendersText() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.strikethrough([.text("deleted")])])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("deleted"))
        }
    }

    @Test func softBreakRendersAsNewline() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.text("Line 1"), .softBreak, .text("Line 2")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("\n"))
        }
    }

    @Test func taskListRendersWithCheckboxCharacters() {
        let blocks: [MarkdownBlock] = [
            .taskList([
                .init(checked: false, content: [.paragraph([.text("Todo")])]),
                .init(checked: true, content: [.paragraph([.text("Done")])]),
            ])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("\u{25CB}"))
            #expect(text.contains("\u{25C9}"))
            #expect(text.contains("Todo"))
            #expect(text.contains("Done"))
        } else {
            Issue.record("Expected .text segment for task list")
        }
    }

    @Test func checkedTaskListItemHasStrikethrough() {
        let blocks: [MarkdownBlock] = [
            .taskList([
                .init(checked: true, content: [.paragraph([.text("Done task")])]),
            ])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        guard case .text(let attr) = segments[0] else {
            Issue.record("Expected .text segment")
            return
        }
        // Find a run that contains strikethrough
        let hasStrikethrough = attr.runs.contains { $0.strikethroughStyle == .single }
        #expect(hasStrikethrough, "Checked task item text should have strikethrough")
    }
}

// MARK: - MarkdownSegmentCache

@Suite("MarkdownSegmentCache")
struct MarkdownSegmentCacheTests {

    @Test func getMissReturnsNil() {
        let cache = MarkdownSegmentCache()
        let result = cache.get("never-cached-content")
        #expect(result == nil)
    }

    @Test func setAndGetRoundTrip() {
        let cache = MarkdownSegmentCache()
        let segments: [FlatSegment] = [.thematicBreak]
        cache.set("test-content", segments: segments)
        let retrieved = cache.get("test-content")
        #expect(retrieved != nil)
        #expect(retrieved?.count == 1)
    }

    @Test func cacheKeyDiffersByTheme() {
        let cache = MarkdownSegmentCache()
        cache.set("content", themeID: .dark, segments: [.thematicBreak])
        let result = cache.get("content", themeID: .light)
        #expect(result == nil, "Different theme should produce a cache miss")
    }

    @Test func clearAllRemovesEverything() {
        let cache = MarkdownSegmentCache()
        cache.set("a", segments: [.thematicBreak])
        cache.set("b", segments: [.thematicBreak])

        cache.clearAll()

        #expect(cache.get("a") == nil)
        #expect(cache.get("b") == nil)
        let snapshot = cache.snapshot()
        #expect(snapshot.entries == 0)
        #expect(snapshot.totalSourceBytes == 0)
    }

    @Test func snapshotReflectsEntryCount() {
        let cache = MarkdownSegmentCache()
        #expect(cache.snapshot().entries == 0)

        cache.set("x", segments: [])
        #expect(cache.snapshot().entries == 1)

        cache.set("y", segments: [])
        #expect(cache.snapshot().entries == 2)
    }

    @Test func snapshotTracksSourceBytes() {
        let cache = MarkdownSegmentCache()
        let content = "Hello, world!" // 13 bytes UTF-8
        cache.set(content, segments: [])
        #expect(cache.snapshot().totalSourceBytes == content.utf8.count)
    }

    @Test func shouldCacheReturnsFalseForLargeContent() {
        let cache = MarkdownSegmentCache()
        let largeContent = String(repeating: "x", count: 20_000) // > 16KB threshold
        #expect(!cache.shouldCache(largeContent))
    }

    @Test func shouldCacheReturnsTrueForSmallContent() {
        let cache = MarkdownSegmentCache()
        #expect(cache.shouldCache("small"))
    }

    @Test func overwritingEntryUpdatesSourceBytes() {
        let cache = MarkdownSegmentCache()
        cache.set("short", segments: [])
        let before = cache.snapshot().totalSourceBytes

        // Overwrite with same key but content doesn't change key identity...
        // Actually the key is based on content hash, so same content = same key
        cache.set("short", segments: [.thematicBreak])
        let after = cache.snapshot().totalSourceBytes

        // Same content, same key — bytes should remain the same
        #expect(before == after)
    }
}

@MainActor
@Suite("Markdown document rendering")
struct MarkdownDocumentRenderingTests {
    @Test func documentPresentationDoesNotFallbackToRawSourceForLargeMarkdown() async throws {
        let content = [
            "# Heading",
            "",
            "**Bold intro** with `inline code`.",
            "",
            String(repeating: "Body paragraph with enough text to cross the inline fallback threshold.\n\n", count: 320),
        ].joined(separator: "\n")
        #expect(content.count > 20_000)

        let controller = UIHostingController(
            rootView: FileContentView(
                content: content,
                filePath: "Notes.md",
                presentation: .document
            )
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let rendered = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                let renderedText = timelineAllTextViews(in: controller.view)
                    .map { timelineRenderedText(of: $0) }
                    .joined(separator: "\n")
                return renderedText.contains("Heading")
                    && renderedText.contains("Bold intro")
                    && renderedText.contains("inline code")
                    && !renderedText.contains("# Heading")
                    && !renderedText.contains("**Bold intro**")
                    && !renderedText.contains("`inline code`")
            }
        }

        #expect(rendered)
    }
}

// MARK: - FlatSegment image resolution

@Suite("FlatSegment image URL resolution")
struct FlatSegmentImageResolutionTests {
    private let baseURL = URL(string: "https://server.example.com")! // swiftlint:disable:this force_unwrapping
    private let workspaceID = "ws-abc123"

    // MARK: - Image-only paragraph promotion

    @Test func imageOnlyParagraphWithWorkspaceContextProducesImageSegment() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Chart", source: "charts/mockup.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        #expect(segments.count == 1)
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "Chart")
            #expect(url.absoluteString.contains("/workspaces/ws-abc123/files/charts/mockup.png"))
            #expect(url.absoluteString.hasPrefix("https://server.example.com"))
        } else {
            Issue.record("Expected .image segment, got \(segments[0])")
        }
    }

    @Test func imageOnlyParagraphWithoutWorkspaceContextFallsBackToAltText() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Chart", source: "charts/mockup.png")])
        ]
        // No workspaceID or serverBaseURL — should fall back to alt text in brackets
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("[Chart]"))
        } else {
            Issue.record("Expected .text fallback segment")
        }
    }

    @Test func paragraphWithTextAndImageIsNotPromoted() {
        // Mixed paragraph: not image-only, falls back to text rendering.
        let blocks: [MarkdownBlock] = [
            .paragraph([
                .text("See this: "),
                .image(alt: "Chart", source: "chart.png"),
            ])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        #expect(segments.count == 1)
        if case .text = segments[0] {
            // Expected — mixed paragraph rendered as text
        } else {
            Issue.record("Expected .text segment for mixed paragraph")
        }
    }

    @Test func absoluteHTTPSURLImageIsPromotedToImageSegment() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Remote", source: "https://example.com/image.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        #expect(segments.count == 1)
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "Remote")
            #expect(url.absoluteString == "https://example.com/image.png")
        } else {
            Issue.record("Expected .image segment for https URL, got \(segments[0])")
        }
    }

    @Test func absoluteHTTPURLImageIsPromotedToImageSegment() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "HTTP", source: "http://cdn.example.com/photo.jpg")])
        ]
        // No workspace context needed for absolute URLs
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "HTTP")
            #expect(url.absoluteString == "http://cdn.example.com/photo.jpg")
        } else {
            Issue.record("Expected .image segment for http URL, got \(segments[0])")
        }
    }

    @Test func dataURIImageSourceIsNotPromoted() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Inline", source: "data:image/png;base64,abc123")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        if case .image = segments[0] {
            Issue.record("data: URI should not be promoted to workspace .image segment")
        }
    }

    @Test func imageURLContainsWorkspaceIDAndFilePath() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Fig", source: "output/figure1.jpg")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: "my-workspace",
            serverBaseURL: URL(string: "https://pi.local:8080")! // swiftlint:disable:this force_unwrapping
        )
        if case .image(_, let url) = segments[0] {
            let abs = url.absoluteString
            #expect(abs.contains("/workspaces/my-workspace/files/output/figure1.jpg"))
            #expect(abs.hasPrefix("https://pi.local:8080"))
        } else {
            Issue.record("Expected .image segment")
        }
    }

    @Test func leadingSlashInSourceIsStripped() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Fig", source: "/absolute/path/image.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        if case .image(_, let url) = segments[0] {
            // Should NOT have double slash from the leading /
            #expect(!url.absoluteString.contains("//absolute"))
            #expect(url.absoluteString.contains("/files/absolute/path/image.png"))
        }
    }

    @Test func imageAndTextParagraphsAreSeparatedCorrectly() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.text("Before the chart.")]),
            .paragraph([.image(alt: "Chart", source: "chart.png")]),
            .paragraph([.text("After the chart.")]),
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        // Expect: text (merged before+after gets interrupted by .image)
        // Segments: .text("Before..."), .image("Chart"), .text("After...")
        #expect(segments.count == 3)
        if case .text = segments[0] {} else { Issue.record("Expected text before image") }
        if case .image(let alt, _) = segments[1] {
            #expect(alt == "Chart")
        } else {
            Issue.record("Expected .image segment in middle")
        }
        if case .text = segments[2] {} else { Issue.record("Expected text after image") }
    }

    @Test func emptyAltImageInImageOnlyParagraphWithWorkspaceContext() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "", source: "chart.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        // Empty alt: promoted to .image with empty alt (hidden on error)
        if case .image(let alt, _) = segments[0] {
            #expect(alt.isEmpty)
        } else {
            // Also acceptable: empty paragraph filtered out entirely
            #expect(segments.isEmpty || segments.count == 1)
        }
    }
}

// MARK: - Table cell inline content (links in table cells)

@Suite("Table cell inline content")
struct TableCellInlineContentTests {

    /// Regression test: markdown links inside table cells should preserve
    /// their destination URL through the parse pipeline so they can be
    /// rendered as clickable links.
    @Test func parsedTableCellPreservesLinkURL() {
        let md = """
        | Title | Link |
        | --- | --- |
        | Article | [Click here](https://example.com) |
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)

        guard case .table(let headers, let rows) = blocks[0] else {
            Issue.record("Expected .table block, got \(blocks[0])")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["Title", "Link"])
        #expect(rows.count == 1)

        // The second cell should contain a .link inline with the destination URL.
        let linkCell = rows[0][1]
        let hasLink = linkCell.contains { inline in
            if case .link(_, let dest) = inline {
                return dest == "https://example.com"
            }
            return false
        }
        #expect(hasLink, "Table cell should preserve link with destination URL")
        #expect(plainText(from: linkCell) == "Click here")
    }

    @Test func parsedTableCellPreservesMultipleLinks() {
        let md = """
        | Source | Read? |
        | --- | --- |
        | [Article A](https://a.com) | [Full](https://a.com/full) |
        """
        let blocks = parseCommonMark(md)
        guard case .table(_, let rows) = blocks[0] else {
            Issue.record("Expected .table block")
            return
        }
        let cell0HasLink = rows[0][0].contains {
            if case .link(_, let d) = $0 { return d == "https://a.com" }
            return false
        }
        let cell1HasLink = rows[0][1].contains {
            if case .link(_, let d) = $0 { return d == "https://a.com/full" }
            return false
        }
        #expect(cell0HasLink, "First cell should preserve link URL")
        #expect(cell1HasLink, "Second cell should preserve link URL")
    }

    @Test func parsedTablePlainTextCellsUnchanged() {
        let md = """
        | Name | Value |
        | --- | --- |
        | foo | bar |
        """
        let blocks = parseCommonMark(md)
        guard case .table(let headers, let rows) = blocks[0] else {
            Issue.record("Expected .table block")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["Name", "Value"])
        #expect(rows[0].map { plainText(from: $0) } == ["foo", "bar"])
    }

    @Test func parsedTableCellWithBoldAndLink() {
        let md = """
        | Col |
        | --- |
        | **bold** and [link](https://x.com) |
        """
        let blocks = parseCommonMark(md)
        guard case .table(_, let rows) = blocks[0] else {
            Issue.record("Expected .table block")
            return
        }
        let cell = rows[0][0]
        let hasStrong = cell.contains { if case .strong = $0 { return true } else { return false } }
        let hasLink = cell.contains { if case .link = $0 { return true } else { return false } }
        #expect(hasStrong, "Table cell should preserve bold formatting")
        #expect(hasLink, "Table cell should preserve link")
    }

    @Test func flatSegmentTablePassesThroughInlines() {
        let blocks: [MarkdownBlock] = [
            .table(
                headers: [[.text("Title")], [.text("Link")]],
                rows: [
                    [[.text("Art")], [.link(children: [.text("Click")], destination: "https://example.com")]],
                ]
            )
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        guard case .table(_, let rows) = segments[0] else {
            Issue.record("Expected .table segment")
            return
        }
        let hasLink = rows[0][1].contains { inline in
            if case .link(_, let dest) = inline { return dest == "https://example.com" }
            return false
        }
        #expect(hasLink, "FlatSegment.table should preserve link inlines")
    }
}

// MARK: - End-to-end online image parsing

@Suite("Online image end-to-end")
struct OnlineImageEndToEndTests {

    @Test func httpsImageURLParsedFromRawMarkdown() {
        let md = "![GitHub avatar](https://avatars.githubusercontent.com/u/1?v=4)"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        if case .paragraph(let inlines) = blocks[0] {
            #expect(inlines.count == 1)
            if case .image(let alt, let source) = inlines[0] {
                #expect(alt == "GitHub avatar")
                #expect(source == "https://avatars.githubusercontent.com/u/1?v=4")
            } else {
                Issue.record("Expected .image inline, got \(inlines[0])")
            }
        } else {
            Issue.record("Expected .paragraph, got \(blocks[0])")
        }
    }

    @Test func httpsImageURLProducesImageSegment() {
        let md = "![GitHub avatar](https://avatars.githubusercontent.com/u/1?v=4)"
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "GitHub avatar")
            #expect(url.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4")
        } else {
            Issue.record("Expected .image segment, got \(segments[0])")
        }
    }

    @Test func httpsImageWithWorkspaceContextStillWorks() {
        let md = "![test](https://example.com/photo.jpg)"
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(
            from: blocks,
            themeID: .dark,
            workspaceID: "ws-123",
            serverBaseURL: URL(string: "https://server.local")!
        )
        #expect(segments.count == 1)
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "test")
            #expect(url.absoluteString == "https://example.com/photo.jpg")
        } else {
            Issue.record("Expected .image segment, got \(segments[0])")
        }
    }

    @Test func multipleImagesInMarkdown() {
        let md = """
        # Title

        ![img1](https://example.com/a.png)

        Some text

        ![img2](https://example.com/b.png)
        """
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        let imageSegments = segments.filter {
            if case .image = $0 { return true } else { return false }
        }
        #expect(imageSegments.count == 2, "Expected 2 image segments, got \(imageSegments.count). All segments: \(segments)")
    }
}

@Suite("Online image without workspace context")
struct OnlineImageNoWorkspaceTests {

    @Test func httpsImageWorksWithoutWorkspaceContext() {
        // This is exactly what MarkdownFileView does — no workspaceID, no serverBaseURL
        let md = "![GitHub avatar](https://avatars.githubusercontent.com/u/1?v=4)"
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        // Must produce .image, not .text with [GitHub avatar]
        #expect(segments.count == 1, "Expected 1 segment, got \(segments.count)")
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "GitHub avatar")
            #expect(url.scheme == "https")
        } else {
            Issue.record("Expected .image segment without workspace context, got \(segments[0])")
        }
    }

    @Test func fullMarkdownFileContent() {
        // Simulate the exact test file content
        let md = """
        ## Online Images

        ### GitHub avatar

        ![GitHub user 1](https://avatars.githubusercontent.com/u/1?v=4)

        ### Wikipedia image

        ![Wikipedia globe](https://upload.wikimedia.org/wikipedia/commons/thumb/8/80/Wikipedia-logo-v2.svg/200px-Wikipedia-logo-v2.svg.png)
        """
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        let imageSegments = segments.filter {
            if case .image = $0 { return true } else { return false }
        }
        #expect(imageSegments.count == 2, "Expected 2 image segments in full markdown. All segments: \(segments.map { "\($0)" }.joined(separator: ", "))")
    }
}

// MARK: - NativeMarkdownImageView loading

@Suite("NativeMarkdownImageView online loading")
@MainActor
struct NativeMarkdownImageViewTests {

    @Test func loadsHTTPSImageFromURL() async throws {
        let view = NativeMarkdownImageView()
        let url = URL(string: "https://avatars.githubusercontent.com/u/1?v=4")!
        view.apply(url: url, alt: "Test", fetchWorkspaceFile: nil)

        // Wait for async load (up to 10 seconds)
        var loaded = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            // Check if imageView has an image by inspecting subviews
            if let imageView = view.subviews.first(where: { $0 is UIImageView }) as? UIImageView,
               imageView.image != nil, !imageView.isHidden {
                loaded = true
                break
            }
        }
        #expect(loaded, "NativeMarkdownImageView should load and display the image from https URL")
    }

    @Test func showsLoadingPlaceholderHeight() {
        let view = NativeMarkdownImageView()
        // Force layout
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        view.layoutIfNeeded()

        let url = URL(string: "https://example.com/test.png")!
        view.apply(url: url, alt: "Loading test", fetchWorkspaceFile: nil)

        // The view should have a height constraint of 80 (loading placeholder)
        let heightConstraints = view.constraints.filter { $0.firstAttribute == .height }
        let hasPlaceholderHeight = heightConstraints.contains { $0.constant == 80 }
        #expect(hasPlaceholderHeight, "Should have 80pt loading placeholder height. Constraints: \(heightConstraints.map { "\($0.constant)" })")
    }
}

// MARK: - NativeMermaidBlockView tests

@Suite("NativeMermaidBlockView")
@MainActor
struct NativeMermaidBlockViewTests {

    private func makeDiagramView() -> NativeMermaidBlockView {
        let view = NativeMermaidBlockView()
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
        return view
    }

    private func allViews(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap(allViews)
    }

    private func isEffectivelyVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let visibleView = current {
            if visibleView.isHidden || visibleView.alpha <= 0.01 {
                return false
            }
            current = visibleView.superview
        }
        return true
    }

    private func firstRenderedDiagramImageView(in root: UIView) -> UIImageView? {
        for scrollView in allViews(in: root).compactMap({ $0 as? UIScrollView }) where isEffectivelyVisible(scrollView) {
            if let imageView = allViews(in: scrollView)
                .compactMap({ $0 as? UIImageView })
                .first(where: { imageView in
                    isEffectivelyVisible(imageView) && imageView.image != nil
                }) {
                return imageView
            }
        }

        return nil
    }

    /// The tap overlay must win hit-testing over the scroll view when the
    /// diagram is rendered, ensuring taps reach the overlay's gesture
    /// recognizer instead of being swallowed by UIScrollView's zoom handling.
    @Test func tapOverlayWinsHitTestOverScrollView() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))

        // Simulate real hierarchy: collectionView > cell > stack > mermaidView
        let layout = UICollectionViewFlowLayout()
        layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
        let collectionView = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Add the same "dismiss keyboard" tap as ChatTimelineCollectionView
        let dismissTap = UITapGestureRecognizer()
        dismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(dismissTap)
        window.addSubview(collectionView)

        let cell = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 300))
        let stack = UIStackView()
        stack.axis = .vertical
        stack.frame = cell.bounds
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cell.addSubview(stack)

        let mermaidView = NativeMermaidBlockView()
        stack.addArrangedSubview(mermaidView)
        collectionView.addSubview(cell)

        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        let palette = ThemeRuntimeState.currentPalette()
        mermaidView.applyAsDiagram(code: "graph TD\n    A-->B", palette: palette)

        // Wait for async render
        var rendered = false
        for _ in 0..<500 {
            window.layoutIfNeeded()
            if firstRenderedDiagramImageView(in: mermaidView) != nil {
                rendered = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(rendered, "Diagram must render before testing tap")

        // Hit-test from the window at the mermaid view's center
        let center = mermaidView.convert(
            CGPoint(x: mermaidView.bounds.midX, y: mermaidView.bounds.midY),
            to: window
        )
        guard let hitView = window.hitTest(center, with: nil) else {
            Issue.record("hitTest returned nil at \(center)")
            return
        }

        // The hit view must NOT be the scroll view or its subviews —
        // it must be the tap overlay (which sits above the scroll view).
        #expect(
            !(hitView is UIScrollView),
            "Hit view should be the tap overlay, not UIScrollView"
        )
        #expect(
            !(hitView is UIImageView),
            "Hit view should be the tap overlay, not UIImageView inside scroll view"
        )

        // The hit view (overlay) must have a single-tap gesture
        let taps = (hitView.gestureRecognizers ?? [])
            .compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 1 }
        #expect(!taps.isEmpty, "Hit view must own a single-tap gesture. Hit: \(type(of: hitView))")

        window.resignKey()
    }

    @Test func mermaidExportRendersNonBlankImage() async {
        // Verify the FileShareService export path produces a real image
        let code = "graph TD\n    A[Start] --> B[End]"
        let content = FileShareService.ShareableContent.mermaid(code)
        let item = await FileShareService.render(content, as: .image)
        if case .image(let image) = item {
            #expect(image.size.width >= 50, "Export image too narrow: \(image.size.width)")
            #expect(image.size.height >= 50, "Export image too short: \(image.size.height)")
            #expect(!FileShareService.isBlankImage(image), "Export image is blank")
        } else {
            Issue.record("Expected .image from mermaid export, got \(item)")
        }
    }
}
