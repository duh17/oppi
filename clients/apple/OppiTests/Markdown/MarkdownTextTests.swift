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

    @Test func displayMathParagraphWithBracketDelimitersPromotesToLatexSegment() {
        let markdown = #"""
        \[
        \text{hit_rate} = \frac{\text{cacheRead}}{\text{cacheRead} + \text{uncachedInput}}
        \]
        """#

        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        #expect(segments.count == 1)
        if case .latexBlock(let code) = segments[0] {
            #expect(code.contains(#"\frac"#))
            #expect(!code.contains(#"\["#))
            #expect(!code.contains(#"\]"#))
        } else {
            Issue.record("Expected .latexBlock segment, got \(segments[0])")
        }
    }

    @Test func displayMathParagraphWithDollarDelimitersPromotesToLatexSegment() {
        let markdown = #"""
        $$
        x = \frac{1}{2}
        $$
        """#

        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        #expect(segments.count == 1)
        if case .latexBlock(let code) = segments[0] {
            #expect(code == #"x = \frac{1}{2}"#)
        } else {
            Issue.record("Expected .latexBlock segment, got \(segments[0])")
        }
    }

    @Test func bracketDelimitedPlainTextParagraphStaysText() {
        let markdown = """
        [
        this is not latex
        ]
        """

        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("this is not latex"))
        } else {
            Issue.record("Expected .text segment, got \(segments[0])")
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

    @Test func imageWithEmptyAltTextFallsBackToGenericPlaceholder() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "", source: "img.png")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            #expect(String(attr.characters).contains("[image]"))
        } else {
            Issue.record("Expected .text fallback segment")
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

    @Test func cacheKeyDiffersByImageResolutionContext() {
        let cache = MarkdownSegmentCache()
        cache.set(
            "![image](/tmp/chart.png)",
            themeID: .dark,
            workspaceID: "workspace-1",
            sessionID: nil,
            serverBaseURL: URL(string: "https://example.com/api")!,
            sourceDirectory: nil,
            segments: [.thematicBreak]
        )

        let result = cache.get(
            "![image](/tmp/chart.png)",
            themeID: .dark,
            workspaceID: "workspace-1",
            sessionID: "session-1",
            serverBaseURL: URL(string: "https://example.com/api")!,
            sourceDirectory: nil
        )

        #expect(result == nil, "Markdown segment cache must not reuse image segments across different session resolution contexts")
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

    @Test func imageOnlyParagraphWithoutWorkspaceContextUsesGenericImageFallbackWhenAltIsEmpty() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "   ", source: "charts/mockup.png")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("[image]"))
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
        if case .text = segments[0] {
            // Without session context, absolute filesystem paths cannot be resolved safely.
        } else {
            Issue.record("Expected fallback to text without session context")
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
        // Empty alt: promoted to .image with empty alt and a generic placeholder on load failure.
        if case .image(let alt, _) = segments[0] {
            #expect(alt.isEmpty)
        } else {
            // Also acceptable: empty paragraph filtered out entirely
            #expect(segments.isEmpty || segments.count == 1)
        }
    }

    // MARK: - Source directory resolution

    @Test func relativeImagePathIsResolvedAgainstSourceDirectory() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Chart", source: "images/chart.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL,
            sourceDirectory: "docs"
        )
        #expect(segments.count == 1)
        if case .image(_, let url) = segments[0] {
            // Should resolve to docs/images/chart.png, not images/chart.png
            #expect(url.absoluteString.contains("/files/docs/images/chart.png"),
                    "Expected docs/images/chart.png, got \(url.absoluteString)")
        } else {
            Issue.record("Expected .image segment, got \(segments[0])")
        }
    }

    @Test func absolutePathWithSessionContextUsesSessionFileURL() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Fig", source: "/absolute/image.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            sessionID: "sess-123",
            serverBaseURL: baseURL,
            sourceDirectory: "docs"
        )
        if case .image(_, let url) = segments[0] {
            let components = SessionFileURL.parse(url)
            #expect(components?.workspaceID == workspaceID)
            #expect(components?.sessionID == "sess-123")
            #expect(components?.filePath == "/absolute/image.png")
        } else {
            Issue.record("Expected session-scoped .image segment")
        }
    }

    @Test func httpsURLIgnoresSourceDirectory() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Remote", source: "https://example.com/pic.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL,
            sourceDirectory: "docs"
        )
        if case .image(_, let url) = segments[0] {
            #expect(url.absoluteString == "https://example.com/pic.png",
                    "HTTPS URLs should pass through unchanged")
        }
    }

    @Test func nilSourceDirectoryLeavesPathUnchanged() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Fig", source: "images/fig.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL,
            sourceDirectory: nil
        )
        if case .image(_, let url) = segments[0] {
            #expect(url.absoluteString.contains("/files/images/fig.png"))
            #expect(!url.absoluteString.contains("docs"))
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
        view.apply(url: url, alt: "Test", fetchWorkspaceFile: nil, fetchSessionFile: nil)

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
        view.apply(url: url, alt: "Loading test", fetchWorkspaceFile: nil, fetchSessionFile: nil)

        // The view should reserve a medium inline-prose placeholder while loading.
        let expectedHeight = ImageViewportSizing.policy(for: .inlineProse, screenHeight: UIScreen.main.bounds.height).placeholderHeight
        let heightConstraints = view.constraints.filter { $0.firstAttribute == .height }
        let hasPlaceholderHeight = heightConstraints.contains { $0.constant == expectedHeight }
        #expect(hasPlaceholderHeight, "Should have inline-prose loading placeholder height. Constraints: \(heightConstraints.map { "\($0.constant)" })")
    }

    @Test func svgLoadedStateInstallsTapOverlayForFullscreen() async throws {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        view.layoutIfNeeded()

        let svg = """
        <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"300\" height=\"180\">
          <rect width=\"300\" height=\"180\" fill=\"#111827\"/>
        </svg>
        """
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://example.com/api")!,
            workspaceID: "workspace-1",
            filePath: "chart.svg"
        ))
        view.apply(
            url: url,
            alt: "Chart",
            fetchWorkspaceFile: { _, _ in Data(svg.utf8) },
            fetchSessionFile: nil
        )

        let hasTapOverlay = await waitForTimelineCondition(timeoutMs: 1_500) { @MainActor in
            view.layoutIfNeeded()
            return timelineAllViews(in: view).contains { $0.accessibilityIdentifier == "markdown-image.svg.tap-overlay" }
        }

        #expect(hasTapOverlay, "SVG markdown images need an explicit tap target for fullscreen")
    }

    @Test func unsupportedURLWithEmptyAltShowsGenericPlaceholder() async throws {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        view.layoutIfNeeded()

        view.apply(
            url: URL(fileURLWithPath: "/tmp/not-an-inline-image"),
            alt: "",
            fetchWorkspaceFile: nil,
            fetchSessionFile: nil
        )

        var showedPlaceholder = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            let visibleLabels = view.subviews.compactMap { $0 as? UILabel }.filter { !$0.isHidden }
            if visibleLabels.contains(where: { $0.text == "[image]" }) {
                showedPlaceholder = true
                break
            }
        }

        #expect(showedPlaceholder, "Broken markdown image should show a generic placeholder instead of collapsing")
        #expect(!view.isHidden)
    }

    @Test func loadedSVGRendererIsFocusable() async throws {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 180)
        view.layoutIfNeeded()

        let svgData = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 60">
          <rect width="100" height="60" fill="red"/>
        </svg>
        """.utf8)
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://example.com/api")!,
            workspaceID: "workspace-1",
            filePath: "images/diagram.svg"
        ))

        view.apply(
            url: url,
            alt: "Diagram",
            fetchWorkspaceFile: { _, _ in svgData },
            fetchSessionFile: nil
        )

        var visibleWebRenderer: UIView?
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            visibleWebRenderer = view.subviews.first {
                String(describing: type(of: $0)).contains("WKWebView") && !$0.isHidden
            }
            if visibleWebRenderer != nil { break }
        }

        let renderer = try #require(visibleWebRenderer)
        let hasTapGesture = renderer.gestureRecognizers?.contains { $0 is UITapGestureRecognizer } == true
        #expect(hasTapGesture, "SVG markdown images should be focusable just like raster images")
    }

    @Test func fullScreenMarkdownBodyCreatesImageViewsForSessionAbsolutePaths() {
        let body = NativeFullScreenMarkdownBody(
            content: "![Generated chart](/tmp/chart.png)",
            stream: nil,
            palette: ThemeID.dark.palette,
            plainTextFallbackThreshold: nil,
            selectedTextPiRouter: nil,
            selectedTextSourceContext: nil,
            workspaceID: "workspace-1",
            sessionID: "session-1",
            serverBaseURL: URL(string: "https://example.com/api")!,
            fetchWorkspaceFile: nil,
            fetchSessionFile: { _, _, _ in Data() }
        )

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 1000))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        let imageView = timelineFirstView(ofType: NativeMarkdownImageView.self, in: body)
        #expect(imageView != nil, "Full-screen markdown should resolve absolute session image paths the same way assistant messages do")
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

    /// Find the diagram image view: a visible UIImageView with a tap gesture
    /// and user interaction enabled. Skips button images and other incidental
    /// image views in the hierarchy.
    private func firstTappableImageView(in root: UIView) -> UIImageView? {
        for sub in root.subviews {
            if let iv = sub as? UIImageView,
               !iv.isHidden,
               iv.isUserInteractionEnabled,
               iv.image != nil,
               (iv.gestureRecognizers ?? []).contains(where: { $0 is UITapGestureRecognizer }) {
                return iv
            }
            if let found = firstTappableImageView(in: sub) {
                return found
            }
        }
        return nil
    }

    /// Tap on diagram image view must work inside a real collection view
    /// hierarchy with a dismiss-keyboard gesture — same setup as on device.
    @Test func tapWorksInCollectionViewHierarchy() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))

        let layout = UICollectionViewFlowLayout()
        layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
        let collectionView = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Same dismiss-keyboard tap as ChatTimelineCollectionView
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
        var imageView: UIImageView?
        for _ in 0..<500 {
            window.layoutIfNeeded()
            if let iv = firstTappableImageView(in: mermaidView) {
                imageView = iv
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        guard let imageView else {
            Issue.record("Diagram never rendered")
            return
        }

        // 1. Image view must be directly tappable (no scroll view wrapper)
        #expect(!(imageView.superview is UIScrollView),
                "Image view must NOT be inside a UIScrollView")

        // 2. Image view must have a tap gesture
        let taps = (imageView.gestureRecognizers ?? [])
            .compactMap { $0 as? UITapGestureRecognizer }
        #expect(!taps.isEmpty, "Image view must own a tap gesture")

        // 3. Image view must be the hit-test target
        let center = imageView.convert(
            CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY),
            to: window
        )
        let hitView = window.hitTest(center, with: nil)
        #expect(hitView === imageView,
                "hitTest must return imageView, got \(type(of: hitView as Any))")

        // 4. isUserInteractionEnabled all the way up
        var v: UIView? = imageView
        while let current = v, current !== window {
            #expect(current.isUserInteractionEnabled,
                    "\(type(of: current)) blocks interaction")
            v = current.superview
        }

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

    /// When markdown containing a mermaid code block is exported as an image,
    /// the mermaid diagram must render with actual content — not appear as a
    /// blank box. We verify by comparing pixel diversity in the diagram area
    /// against the standalone mermaid export (which is known to work).
    @Test func markdownExportRendersMermaidDiagramNotBlankBox() async {
        let code = "graph TD\n    A[Start] --> B[End]"

        // 1. Standalone mermaid export (known working)
        let standalone = await FileShareService.render(.mermaid(code), as: .image)
        guard case .image(let standaloneImg) = standalone else {
            Issue.record("Standalone mermaid export failed")
            return
        }

        // 2. Markdown export containing the same mermaid
        let markdown = "```mermaid\n\(code)\n```"
        let mdExport = await FileShareService.render(.markdown(markdown), as: .image)
        guard case .image(let mdImg) = mdExport else {
            Issue.record("Markdown export failed")
            return
        }

        // 3. The standalone image has diagram content (colored pixels).
        //    Count distinct colors in the center region of each image.
        let standaloneColors = sampleDistinctColors(in: standaloneImg)
        let mdColors = sampleDistinctColors(in: mdImg)

        // The standalone diagram has many distinct colors (node fills, borders,
        // text, background). The markdown export should too — if it rendered
        // only a blank box, it would have very few colors (just background +
        // box border).
        #expect(standaloneColors >= 5,
                "Standalone mermaid should have varied colors, got \(standaloneColors)")
        #expect(mdColors >= 5,
                "Markdown mermaid export only has \(mdColors) distinct colors — diagram likely didn't render (blank box)")
    }

    /// Sample the center 50% of an image and count distinct colors.
    private func sampleDistinctColors(in image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let w = cgImage.width, h = cgImage.height
        guard w > 4, h > 4 else { return 0 }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * w
        var pixelData = [UInt8](repeating: 0, count: w * h * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Sample center 50% region
        let x0 = w / 4, x1 = 3 * w / 4
        let y0 = h / 4, y1 = 3 * h / 4
        var colors = Set<UInt32>()
        // Sample every 4th pixel for speed
        for y in stride(from: y0, to: y1, by: 4) {
            for x in stride(from: x0, to: x1, by: 4) {
                let offset = (y * w + x) * bytesPerPixel
                // Quantize to 6-bit per channel to ignore anti-aliasing noise
                let r = UInt32(pixelData[offset] >> 2)
                let g = UInt32(pixelData[offset + 1] >> 2)
                let b = UInt32(pixelData[offset + 2] >> 2)
                colors.insert((r << 16) | (g << 8) | b)
            }
        }
        return colors.count
    }
}
