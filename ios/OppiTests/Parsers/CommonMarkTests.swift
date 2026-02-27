import Testing
import Foundation
@testable import Oppi

/// Tests CommonMark rendering via `parseCommonMark(_:)`.
///
/// Verifies that the swift-markdown parser produces the correct
/// intermediate `MarkdownBlock` / `MarkdownInline` AST for all
/// CommonMark block and inline elements.
@Suite("CommonMark Parsing")
struct CommonMarkTests {

    // MARK: - Headings

    @Test func atxHeadings() {
        let blocks = parseCommonMark("# Heading 1\n## Heading 2\n### Heading 3\n")
        #expect(blocks.count == 3)
        guard case .heading(let level1, let inlines1) = blocks[0] else {
            Issue.record("Expected heading at [0]")
            return
        }
        #expect(level1 == 1)
        #expect(plainText(from: inlines1) == "Heading 1")

        guard case .heading(let level2, _) = blocks[1] else {
            Issue.record("Expected heading at [1]")
            return
        }
        #expect(level2 == 2)

        guard case .heading(let level3, _) = blocks[2] else {
            Issue.record("Expected heading at [2]")
            return
        }
        #expect(level3 == 3)
    }

    @Test func headingLevels1Through6() {
        let md = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 6)
        for (i, block) in blocks.enumerated() {
            guard case .heading(let level, _) = block else {
                Issue.record("Expected heading at [\(i)]")
                return
            }
            #expect(level == i + 1)
        }
    }

    @Test func setextHeadings() {
        let md = "Heading 1\n=========\n\nHeading 2\n---------\n"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 2)
        guard case .heading(1, let inlines1) = blocks[0] else {
            Issue.record("Expected setext h1")
            return
        }
        #expect(plainText(from: inlines1) == "Heading 1")
        guard case .heading(2, _) = blocks[1] else {
            Issue.record("Expected setext h2")
            return
        }
    }

    @Test func headingWithInlineFormatting() {
        let blocks = parseCommonMark("# Hello **bold** *world*\n")
        #expect(blocks.count == 1)
        guard case .heading(1, let inlines) = blocks[0] else {
            Issue.record("Expected heading")
            return
        }
        #expect(plainText(from: inlines) == "Hello bold world")
        // Should contain emphasis and strong nodes
        let hasStrong = inlines.contains { if case .strong = $0 { return true } else { return false } }
        let hasEmphasis = inlines.contains { if case .emphasis = $0 { return true } else { return false } }
        #expect(hasStrong)
        #expect(hasEmphasis)
    }

    // MARK: - Paragraphs

    @Test func simpleParagraph() {
        let blocks = parseCommonMark("Hello world\n")
        #expect(blocks.count == 1)
        guard case .paragraph(let inlines) = blocks[0] else {
            Issue.record("Expected paragraph")
            return
        }
        #expect(plainText(from: inlines) == "Hello world")
    }

    @Test func twoParagraphs() {
        let blocks = parseCommonMark("First paragraph.\n\nSecond paragraph.\n")
        #expect(blocks.count == 2)
        guard case .paragraph = blocks[0], case .paragraph = blocks[1] else {
            Issue.record("Expected two paragraphs")
            return
        }
    }

    // MARK: - Inline Formatting

    @Test func boldText() {
        let blocks = parseCommonMark("**bold text**\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        guard case .strong(let children) = inlines.first else {
            Issue.record("Expected strong")
            return
        }
        #expect(plainText(from: children) == "bold text")
    }

    @Test func italicText() {
        let blocks = parseCommonMark("*italic text*\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        guard case .emphasis(let children) = inlines.first else {
            Issue.record("Expected emphasis")
            return
        }
        #expect(plainText(from: children) == "italic text")
    }

    @Test func boldItalicText() {
        let blocks = parseCommonMark("***bold italic***\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        #expect(plainText(from: inlines) == "bold italic")
    }

    @Test func inlineCode() {
        let blocks = parseCommonMark("Use `code` here\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        let hasCode = inlines.contains { if case .code("code") = $0 { return true } else { return false } }
        #expect(hasCode)
    }

    @Test func strikethroughText() {
        let blocks = parseCommonMark("~~deleted~~\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        guard case .strikethrough(let children) = inlines.first else {
            Issue.record("Expected strikethrough")
            return
        }
        #expect(plainText(from: children) == "deleted")
    }

    @Test func link() {
        let blocks = parseCommonMark("[click here](https://example.com)\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        guard case .link(let children, let dest) = inlines.first else {
            Issue.record("Expected link")
            return
        }
        #expect(plainText(from: children) == "click here")
        #expect(dest == "https://example.com")
    }

    @Test func image() {
        let blocks = parseCommonMark("![alt text](image.png)\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        guard case .image(let alt, let source) = inlines.first else {
            Issue.record("Expected image")
            return
        }
        #expect(alt == "alt text")
        #expect(source == "image.png")
    }

    @Test func hardLineBreak() {
        let blocks = parseCommonMark("line one  \nline two\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        let hasHardBreak = inlines.contains { if case .hardBreak = $0 { return true } else { return false } }
        #expect(hasHardBreak)
    }

    @Test func softLineBreak() {
        let blocks = parseCommonMark("line one\nline two\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        let hasSoftBreak = inlines.contains { if case .softBreak = $0 { return true } else { return false } }
        #expect(hasSoftBreak)
    }

    // MARK: - Code Blocks

    @Test func fencedCodeBlock() {
        let md = "```swift\nlet x = 1\n```\n"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .codeBlock(let lang, let code) = blocks[0] else {
            Issue.record("Expected codeBlock")
            return
        }
        #expect(lang == "swift")
        #expect(code == "let x = 1")
    }

    @Test func fencedCodeBlockNoLanguage() {
        let md = "```\nplain code\n```\n"
        let blocks = parseCommonMark(md)
        guard case .codeBlock(let lang, let code) = blocks.first else {
            Issue.record("Expected codeBlock")
            return
        }
        #expect(lang == nil)
        #expect(code == "plain code")
    }

    @Test func indentedCodeBlock() {
        let md = "    indented code\n    second line\n"
        let blocks = parseCommonMark(md)
        guard case .codeBlock(let lang, let code) = blocks.first else {
            Issue.record("Expected codeBlock for indented code")
            return
        }
        #expect(lang == nil)
        #expect(code.contains("indented code"))
    }

    @Test func tildeCodeBlock() {
        let md = "~~~python\nprint('hi')\n~~~\n"
        let blocks = parseCommonMark(md)
        guard case .codeBlock(let lang, let code) = blocks.first else {
            Issue.record("Expected codeBlock")
            return
        }
        #expect(lang == "python")
        #expect(code == "print('hi')")
    }

    // MARK: - Block Quotes

    @Test func simpleBlockQuote() {
        let blocks = parseCommonMark("> quoted text\n")
        #expect(blocks.count == 1)
        guard case .blockQuote(let children) = blocks[0] else {
            Issue.record("Expected blockQuote")
            return
        }
        #expect(children.count == 1)
        guard case .paragraph(let inlines) = children[0] else {
            Issue.record("Expected paragraph inside quote")
            return
        }
        #expect(plainText(from: inlines) == "quoted text")
    }

    @Test func nestedBlockQuote() {
        let md = "> outer\n>> inner\n"
        let blocks = parseCommonMark(md)
        guard case .blockQuote(let outer) = blocks.first else {
            Issue.record("Expected blockQuote")
            return
        }
        let hasNestedQuote = outer.contains {
            if case .blockQuote = $0 { return true } else { return false }
        }
        #expect(hasNestedQuote)
    }

    @Test func blockQuoteWithMultipleBlocks() {
        let md = "> # Heading\n>\n> Paragraph\n"
        let blocks = parseCommonMark(md)
        guard case .blockQuote(let children) = blocks.first else {
            Issue.record("Expected blockQuote")
            return
        }
        #expect(children.count == 2)
        guard case .heading = children[0] else {
            Issue.record("Expected heading in quote")
            return
        }
        guard case .paragraph = children[1] else {
            Issue.record("Expected paragraph in quote")
            return
        }
    }

    // MARK: - Lists

    @Test func unorderedList() {
        let md = "- item 1\n- item 2\n- item 3\n"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .unorderedList(let items) = blocks[0] else {
            Issue.record("Expected unorderedList")
            return
        }
        #expect(items.count == 3)
    }

    @Test func orderedList() {
        let md = "1. first\n2. second\n3. third\n"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .orderedList(_, let items) = blocks[0] else {
            Issue.record("Expected orderedList")
            return
        }
        #expect(items.count == 3)
    }

    @Test func nestedList() {
        let md = "- outer\n  - inner\n"
        let blocks = parseCommonMark(md)
        guard case .unorderedList(let items) = blocks.first else {
            Issue.record("Expected unorderedList")
            return
        }
        #expect(items.count == 1)
        // Outer item should contain a paragraph and a nested list
        let outerBlocks = items[0]
        let hasNestedList = outerBlocks.contains {
            if case .unorderedList = $0 { return true } else { return false }
        }
        #expect(hasNestedList)
    }

    @Test func listWithInlineFormatting() {
        let md = "- **bold** item\n- *italic* item\n- `code` item\n"
        let blocks = parseCommonMark(md)
        guard case .unorderedList(let items) = blocks.first else {
            Issue.record("Expected unorderedList")
            return
        }
        #expect(items.count == 3)
        // First item's paragraph should contain strong
        guard case .paragraph(let inlines) = items[0].first else {
            Issue.record("Expected paragraph in first item")
            return
        }
        let hasStrong = inlines.contains { if case .strong = $0 { return true } else { return false } }
        #expect(hasStrong)
    }

    // MARK: - Thematic Breaks

    @Test func thematicBreakDashes() {
        let blocks = parseCommonMark("---\n")
        #expect(blocks.count == 1)
        guard case .thematicBreak = blocks[0] else {
            Issue.record("Expected thematicBreak")
            return
        }
    }

    @Test func thematicBreakAsterisks() {
        let blocks = parseCommonMark("***\n")
        guard case .thematicBreak = blocks.first else {
            Issue.record("Expected thematicBreak for ***")
            return
        }
    }

    @Test func thematicBreakUnderscores() {
        let blocks = parseCommonMark("___\n")
        guard case .thematicBreak = blocks.first else {
            Issue.record("Expected thematicBreak for ___")
            return
        }
    }

    // MARK: - Tables (GFM)

    @Test func simpleTable() {
        let md = """
        | Header 1 | Header 2 |
        | -------- | -------- |
        | Cell A   | Cell B   |
        | Cell C   | Cell D   |

        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .table(let headers, let rows) = blocks[0] else {
            Issue.record("Expected table")
            return
        }
        #expect(headers == ["Header 1", "Header 2"])
        #expect(rows.count == 2)
        #expect(rows[0] == ["Cell A", "Cell B"])
        #expect(rows[1] == ["Cell C", "Cell D"])
    }

    @Test func tableCellInlineCodeText() {
        let md = """
        | What | Path |
        | --- | --- |
        | Session state | `~/.config/pi-remote/sessions/<userId>/<sessionId>.json` |

        """

        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .table(let headers, let rows) = blocks[0] else {
            Issue.record("Expected table")
            return
        }

        #expect(headers == ["What", "Path"])
        #expect(rows == [["Session state", "~/.config/pi-remote/sessions/<userId>/<sessionId>.json"]])
    }

    // MARK: - HTML Blocks

    @Test func htmlBlock() {
        let md = "<div>\nHello\n</div>\n"
        let blocks = parseCommonMark(md)
        let hasHtmlBlock = blocks.contains {
            if case .htmlBlock = $0 { return true } else { return false }
        }
        #expect(hasHtmlBlock)
    }

    // MARK: - Mixed Content

    @Test func headingThenParagraphThenCode() {
        let md = """
        # Title

        Some text here.

        ```swift
        let x = 42
        ```

        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 3)
        guard case .heading(1, _) = blocks[0] else {
            Issue.record("Expected heading")
            return
        }
        guard case .paragraph = blocks[1] else {
            Issue.record("Expected paragraph")
            return
        }
        guard case .codeBlock("swift", "let x = 42") = blocks[2] else {
            Issue.record("Expected codeBlock")
            return
        }
    }

    @Test func listThenQuoteThenBreak() {
        let md = """
        - item 1
        - item 2

        > quoted

        ---

        Final paragraph.

        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 4)
        guard case .unorderedList = blocks[0] else {
            Issue.record("Expected list")
            return
        }
        guard case .blockQuote = blocks[1] else {
            Issue.record("Expected blockQuote")
            return
        }
        guard case .thematicBreak = blocks[2] else {
            Issue.record("Expected thematicBreak")
            return
        }
        guard case .paragraph = blocks[3] else {
            Issue.record("Expected paragraph")
            return
        }
    }

    @Test func realWorldAssistantMessage() {
        let md = """
        Here's how to set it up:

        ## Installation

        ```bash
        brew install pi
        ```

        ### Configuration

        1. Create a config file
        2. Add your **API key**
        3. Run `pi serve`

        > **Note**: Make sure port 7749 is available.

        ---

        That should work! See [the docs](https://example.com) for more.

        """
        let blocks = parseCommonMark(md)

        // Should have: paragraph, heading, codeBlock, heading, orderedList,
        // blockQuote, thematicBreak, paragraph
        #expect(blocks.count == 8)

        guard case .paragraph = blocks[0] else {
            Issue.record("Expected intro paragraph")
            return
        }
        guard case .heading(2, _) = blocks[1] else {
            Issue.record("Expected h2 Installation")
            return
        }
        guard case .codeBlock("bash", _) = blocks[2] else {
            Issue.record("Expected bash code block")
            return
        }
        guard case .heading(3, _) = blocks[3] else {
            Issue.record("Expected h3 Configuration")
            return
        }
        guard case .orderedList(_, let items) = blocks[4] else {
            Issue.record("Expected ordered list")
            return
        }
        #expect(items.count == 3)
        guard case .blockQuote = blocks[5] else {
            Issue.record("Expected blockquote")
            return
        }
        guard case .thematicBreak = blocks[6] else {
            Issue.record("Expected thematic break")
            return
        }
        guard case .paragraph(let lastInlines) = blocks[7] else {
            Issue.record("Expected final paragraph")
            return
        }
        // Final paragraph should contain a link
        let hasLink = lastInlines.contains {
            if case .link = $0 { return true } else { return false }
        }
        #expect(hasLink)
    }

    // MARK: - Plain Text Extraction

    @Test func plainTextFromInlines() {
        let inlines: [MarkdownInline] = [
            .text("Hello "),
            .strong([.text("bold")]),
            .text(" and "),
            .emphasis([.text("italic")]),
            .text(" with "),
            .code("code"),
        ]
        #expect(plainText(from: inlines) == "Hello bold and italic with code")
    }

    @Test func plainTextFromNestedInlines() {
        let inlines: [MarkdownInline] = [
            .strong([.emphasis([.text("bold italic")])]),
        ]
        #expect(plainText(from: inlines) == "bold italic")
    }

    // MARK: - Edge Cases

    @Test func emptyInput() {
        let blocks = parseCommonMark("")
        #expect(blocks.isEmpty)
    }

    @Test func whitespaceOnlyInput() {
        let blocks = parseCommonMark("   \n\n  \n")
        #expect(blocks.isEmpty)
    }

    @Test func backslashEscapes() {
        let blocks = parseCommonMark("\\*not italic\\*\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        let text = plainText(from: inlines)
        #expect(text == "*not italic*")
    }

    @Test func linkReferenceDefinition() {
        let md = "[foo]: /url \"title\"\n\n[foo]\n"
        let blocks = parseCommonMark(md)
        // Link reference definitions don't produce visible output themselves.
        // The [foo] reference should resolve to a link.
        let hasLink = blocks.contains { block in
            guard case .paragraph(let inlines) = block else { return false }
            return inlines.contains { if case .link = $0 { return true } else { return false } }
        }
        #expect(hasLink)
    }

    @Test func entityReferences() {
        let blocks = parseCommonMark("&amp; &lt; &gt;\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        let text = plainText(from: inlines)
        #expect(text.contains("&"))
        #expect(text.contains("<"))
        #expect(text.contains(">"))
    }

    @Test func inlineHtml() {
        let blocks = parseCommonMark("text <em>html</em> text\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("Expected paragraph")
            return
        }
        let hasHtml = inlines.contains { if case .html = $0 { return true } else { return false } }
        #expect(hasHtml)
    }
}

// MARK: - Streaming Parser Edge Cases

/// Ensures the streaming `parseCodeBlocks` function remains unchanged.
@Suite("parseCodeBlocks (streaming)")
struct StreamingParserTests {

    @Test func plainMarkdown() {
        let blocks = parseCodeBlocks("Hello world")
        #expect(blocks == [.markdown("Hello world")])
    }

    @Test func singleCodeBlock() {
        let input = "before\n```\ncode here\n```\nafter"
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .markdown("before"))
        #expect(blocks[1] == .codeBlock(language: nil, code: "code here", isComplete: true))
        #expect(blocks[2] == .markdown("after"))
    }

    @Test func codeBlockWithLanguage() {
        let input = "```swift\nlet x = 1\n```"
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 1)
        #expect(blocks[0] == .codeBlock(language: "swift", code: "let x = 1", isComplete: true))
    }

    @Test func unclosedCodeBlock() {
        let input = "text\n```swift\nlet x = 1\nlet y = 2"
        let blocks = parseCodeBlocks(input)
        #expect(blocks.count == 2)
        #expect(blocks[0] == .markdown("text"))
        #expect(blocks[1] == .codeBlock(language: "swift", code: "let x = 1\nlet y = 2", isComplete: false))
    }

    @Test func markdownTable() {
        let text = "Header:\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        let blocks = parseCodeBlocks(text)
        #expect(blocks.count == 2)
        #expect(blocks[0] == .markdown("Header:\n"))
        #expect(blocks[1] == .table(headers: ["A", "B"], rows: [["1", "2"]]))
    }

    @Test func emptyInput() {
        let blocks = parseCodeBlocks("")
        #expect(blocks.isEmpty)
    }
}

@Suite("Flat Segment Text")
struct FlatSegmentTextTests {
    @Test func todoIDsRemainPlainTextInFlatSegments() {
        let blocks = parseCommonMark("Track this: TODO-65cabfd5\n")
        let segments = FlatSegment.build(from: blocks)

        guard let first = segments.first,
              case .text(let attributed) = first else {
            Issue.record("Expected first segment to be .text")
            return
        }

        let links = attributed.runs.compactMap(\.link)
        #expect(links.isEmpty)
    }

    @Test func plainParagraphHasNoLinks() {
        let blocks = parseCommonMark("No task IDs in this paragraph.\n")
        let segments = FlatSegment.build(from: blocks)

        guard let first = segments.first,
              case .text(let attributed) = first else {
            Issue.record("Expected first segment to be .text")
            return
        }

        let links = attributed.runs.compactMap(\.link)
        #expect(links.isEmpty)
    }

    @Test func deepLinkMarkdownPreservesTapTarget() {
        let markdown = "Migrate via [invite](pi://connect?v=3&invite=test-payload).\n"
        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks)

        guard let first = segments.first,
              case .text(let attributed) = first else {
            Issue.record("Expected first segment to be .text")
            return
        }

        let links = attributed.runs.compactMap(\.link)
        #expect(links.count == 1)
        #expect(links.first?.absoluteString == "pi://connect?v=3&invite=test-payload")
    }

    @Test func adjacentTextBlocksMergeForCrossBlockSelection() {
        let markdown = """
        # Heading

        Intro paragraph.

        - One
        - Two

        Outro paragraph.
        """

        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks)

        #expect(segments.count == 1)

        guard let first = segments.first,
              case .text(let attributed) = first else {
            Issue.record("Expected merged .text segment")
            return
        }

        let text = String(attributed.characters)
        #expect(text.contains("Heading"))
        #expect(text.contains("• One"))
        #expect(text.contains("Outro paragraph."))
    }

    @Test func codeBlockStillSplitsTextSegments() {
        let markdown = """
        Before paragraph.

        ```swift
        let value = 1
        ```

        After paragraph.
        """

        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks)

        #expect(segments.count == 3)

        guard case .text(let before) = segments[0] else {
            Issue.record("Expected first segment to be text")
            return
        }
        guard case .codeBlock(let language, let code) = segments[1] else {
            Issue.record("Expected second segment to be code block")
            return
        }
        guard case .text(let after) = segments[2] else {
            Issue.record("Expected third segment to be text")
            return
        }

        #expect(String(before.characters).contains("Before paragraph."))
        #expect(language == "swift")
        #expect(code.contains("let value = 1"))
        #expect(String(after.characters).contains("After paragraph."))
    }
}

// MARK: - Partial Table Streaming Tests

/// Tests how cmark handles tables at various stages of streaming completion.
/// Verifies that partial/incomplete tables are parseable during streaming
/// so that `AssistantMarkdownContentView` can render them incrementally.
@Suite("Partial Table Parsing (Streaming)")
struct PartialTableParsingTests {

    @Test func incompleteRowIncludedInTable() {
        // cmark includes partial rows in the table — critical for streaming rendering.
        let md = """
        | Col A | Col B |
        | --- | --- |
        | val1 | val2 |
        | val3 | va
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .table(let headers, let rows) = blocks[0] else {
            Issue.record("Expected table")
            return
        }
        #expect(headers == ["Col A", "Col B"])
        #expect(rows.count == 2)
        #expect(rows[0] == ["val1", "val2"])
        #expect(rows[1] == ["val3", "va"])
    }

    @Test func headerAndSeparatorOnly() {
        let md = """
        | Col A | Col B |
        | --- | --- |
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .table(let headers, let rows) = blocks[0] else {
            Issue.record("Expected table")
            return
        }
        #expect(headers == ["Col A", "Col B"])
        #expect(rows.isEmpty)
    }

    @Test func headerOnly_noSeparator_isParagraph() {
        // Without separator, cmark treats the line as a paragraph — expected.
        let md = "| Col A | Col B |\n"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .paragraph = blocks[0] else {
            Issue.record("Expected paragraph (no separator = not a table)")
            return
        }
    }

    @Test func incompleteSeparatorStillParsesTable() {
        // Even with an incomplete separator, cmark recognizes the table.
        let md = """
        | Col A | Col B |
        | --- | --
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .table(let headers, _) = blocks[0] else {
            Issue.record("Expected table even with incomplete separator")
            return
        }
        #expect(headers == ["Col A", "Col B"])
    }

    @Test func missingClosingPipeStillParsesRow() {
        let md = """
        | A | B |
        | --- | --- |
        | 1 | 2 |
        | 3 | 4
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .table(_, let rows) = blocks[0] else {
            Issue.record("Expected table")
            return
        }
        #expect(rows.count == 2)
        #expect(rows[1] == ["3", "4"])
    }

    @Test func singleCellPartialRowFillsEmptyCells() {
        let md = """
        | A | B |
        | --- | --- |
        | 1 | 2 |
        | 3
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .table(_, let rows) = blocks[0] else {
            Issue.record("Expected table")
            return
        }
        #expect(rows.count == 2)
        #expect(rows[1] == ["3", ""])
    }
}
