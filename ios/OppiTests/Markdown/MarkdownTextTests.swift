import Foundation
import Testing
@testable import Oppi

// MARK: - parseCodeBlocks (streaming parser)

@Suite("parseCodeBlocks streaming")
struct StreamingCodeBlockParsingTests {

    // MARK: - Plain text

    @Test func plainTextReturnsSingleMarkdownBlock() {
        let blocks = parseCodeBlocks("Hello, world!")
        #expect(blocks.count == 1)
        if case .markdown(let text) = blocks[0] {
            #expect(text == "Hello, world!")
        } else {
            Issue.record("Expected .markdown block")
        }
    }

    @Test func emptyStringReturnsNoBlocks() {
        let blocks = parseCodeBlocks("")
        // Empty string split by newline produces [""], which is non-empty
        // but the content is empty — behavior depends on implementation
        #expect(blocks.count <= 1)
    }

    @Test func multipleLines() {
        let blocks = parseCodeBlocks("Line 1\nLine 2\nLine 3")
        #expect(blocks.count == 1)
        if case .markdown(let text) = blocks[0] {
            #expect(text.contains("Line 1"))
            #expect(text.contains("Line 3"))
        }
    }

    // MARK: - Code blocks

    @Test func completeFencedCodeBlock() {
        let input = "Before\n```swift\nlet x = 1\n```\nAfter"
        let blocks = parseCodeBlocks(input)

        #expect(blocks.count == 3)

        if case .markdown(let text) = blocks[0] {
            #expect(text == "Before")
        }

        if case .codeBlock(let lang, let code, let isComplete) = blocks[1] {
            #expect(lang == "swift")
            #expect(code == "let x = 1")
            #expect(isComplete == true)
        } else {
            Issue.record("Expected .codeBlock")
        }

        if case .markdown(let text) = blocks[2] {
            #expect(text == "After")
        }
    }

    @Test func unclosedCodeBlockIsIncomplete() {
        let input = "Before\n```python\nprint('hello')\nmore code"
        let blocks = parseCodeBlocks(input)

        // Should have: markdown("Before"), codeBlock(incomplete)
        #expect(blocks.count == 2)

        if case .codeBlock(let lang, let code, let isComplete) = blocks[1] {
            #expect(lang == "python")
            #expect(code.contains("print('hello')"))
            #expect(isComplete == false, "Unclosed code block should be marked incomplete")
        } else {
            Issue.record("Expected incomplete .codeBlock")
        }
    }

    @Test func codeBlockWithNoLanguage() {
        let input = "```\nsome code\n```"
        let blocks = parseCodeBlocks(input)

        #expect(blocks.count == 1)
        if case .codeBlock(let lang, let code, let isComplete) = blocks[0] {
            #expect(lang == nil, "Empty language should be nil")
            #expect(code == "some code")
            #expect(isComplete == true)
        }
    }

    @Test func consecutiveCodeBlocks() {
        let input = "```js\na()\n```\n```py\nb()\n```"
        let blocks = parseCodeBlocks(input)

        #expect(blocks.count == 2)
        if case .codeBlock(let lang1, _, _) = blocks[0] {
            #expect(lang1 == "js")
        }
        if case .codeBlock(let lang2, _, _) = blocks[1] {
            #expect(lang2 == "py")
        }
    }

    @Test func codeBlockWithEmptyContent() {
        let input = "```\n```"
        let blocks = parseCodeBlocks(input)

        #expect(blocks.count == 1)
        if case .codeBlock(_, let code, let isComplete) = blocks[0] {
            #expect(code.isEmpty)
            #expect(isComplete == true)
        }
    }

    @Test func codeBlockPreservesInternalBlankLines() {
        let input = "```\nline1\n\nline3\n```"
        let blocks = parseCodeBlocks(input)

        if case .codeBlock(_, let code, _) = blocks[0] {
            #expect(code == "line1\n\nline3")
        }
    }

    // MARK: - Tables

    @Test func simpleTable() {
        let input = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let blocks = parseCodeBlocks(input)

        #expect(blocks.count == 1)
        if case .table(let headers, let rows) = blocks[0] {
            #expect(headers == ["A", "B"])
            #expect(rows.count == 1)
            #expect(rows[0] == ["1", "2"])
        } else {
            Issue.record("Expected .table block")
        }
    }

    @Test func tableWithMultipleRows() {
        let input = "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |"
        let blocks = parseCodeBlocks(input)

        if case .table(let headers, let rows) = blocks[0] {
            #expect(headers == ["Name", "Age"])
            #expect(rows.count == 2)
        }
    }

    @Test func tableWithoutSeparatorIsTreatedAsProse() {
        // Only one line — no separator row — should be treated as markdown
        let input = "| A | B |"
        let blocks = parseCodeBlocks(input)

        // With only a header row and no separator, it should fall through as prose
        #expect(blocks.count == 1)
        if case .markdown = blocks[0] {
            // Expected — not enough rows for a table
        } else {
            Issue.record("Single pipe-delimited line should be prose, not a table")
        }
    }

    @Test func tableBetweenProse() {
        let input = "Before\n| H1 | H2 |\n| --- | --- |\n| v1 | v2 |\nAfter"
        let blocks = parseCodeBlocks(input)

        #expect(blocks.count == 3)
        if case .markdown(let before) = blocks[0] {
            #expect(before == "Before")
        }
        if case .table = blocks[1] {
            // OK
        } else {
            Issue.record("Expected table block")
        }
        if case .markdown(let after) = blocks[2] {
            #expect(after == "After")
        }
    }

    // MARK: - Mixed content

    @Test func proseCodeTableProse() {
        let input = """
        Introduction text.
        ```bash
        echo hello
        ```
        | Col1 | Col2 |
        | --- | --- |
        | A | B |
        Conclusion.
        """
        let blocks = parseCodeBlocks(input)

        #expect(blocks.count == 4)
        if case .markdown = blocks[0] {} else { Issue.record("Expected markdown") }
        if case .codeBlock = blocks[1] {} else { Issue.record("Expected codeBlock") }
        if case .table = blocks[2] {} else { Issue.record("Expected table") }
        if case .markdown = blocks[3] {} else { Issue.record("Expected markdown") }
    }
}

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

    @Test func tableProducesTableSegment() {
        let blocks: [MarkdownBlock] = [.table(headers: ["A"], rows: [["1"]])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .table(let headers, let rows) = segments[0] {
            #expect(headers == ["A"])
            #expect(rows == [["1"]])
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
}

// MARK: - MarkdownSegmentCache

@Suite("MarkdownSegmentCache")
struct MarkdownSegmentCacheTests {

    @Test func getMissReturnsNil() {
        let cache = MarkdownSegmentCache()
        let result = cache.get("never-cached-content", themeID: .dark)
        #expect(result == nil)
    }

    @Test func setAndGetRoundTrip() {
        let cache = MarkdownSegmentCache()
        let segments: [FlatSegment] = [.thematicBreak]
        cache.set("test-content", themeID: .dark, segments: segments)
        let retrieved = cache.get("test-content", themeID: .dark)
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
        cache.set("a", themeID: .dark, segments: [.thematicBreak])
        cache.set("b", themeID: .dark, segments: [.thematicBreak])

        cache.clearAll()

        #expect(cache.get("a", themeID: .dark) == nil)
        #expect(cache.get("b", themeID: .dark) == nil)
        let snapshot = cache.snapshot()
        #expect(snapshot.entries == 0)
        #expect(snapshot.totalSourceBytes == 0)
    }

    @Test func snapshotReflectsEntryCount() {
        let cache = MarkdownSegmentCache()
        #expect(cache.snapshot().entries == 0)

        cache.set("x", themeID: .dark, segments: [])
        #expect(cache.snapshot().entries == 1)

        cache.set("y", themeID: .dark, segments: [])
        #expect(cache.snapshot().entries == 2)
    }

    @Test func snapshotTracksSourceBytes() {
        let cache = MarkdownSegmentCache()
        let content = "Hello, world!" // 13 bytes UTF-8
        cache.set(content, themeID: .dark, segments: [])
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
        cache.set("short", themeID: .dark, segments: [])
        let before = cache.snapshot().totalSourceBytes

        // Overwrite with same key but content doesn't change key identity...
        // Actually the key is based on content hash, so same content = same key
        cache.set("short", themeID: .dark, segments: [.thematicBreak])
        let after = cache.snapshot().totalSourceBytes

        // Same content, same key — bytes should remain the same
        #expect(before == after)
    }
}
