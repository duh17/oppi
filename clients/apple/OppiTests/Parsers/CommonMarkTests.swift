import Testing
import Foundation
@testable import Oppi

/// Tests CommonMark rendering via `parseCommonMark(_:)`.
///
/// Verifies that the cmark-gfm parser produces the correct
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

    @Test func completeDisplayMathIsOpaqueBeforeSetextHeadingParsing() throws {
        let markdown = #"""
        A larger display block:

        $$
        \mathcal L(\theta)
        =
        -\sum_{i=1}^{n}\log
        \left(
        \frac{\exp(z_{i,y_i}/\tau)}
        {\sum_{j=1}^{K}\exp(z_{i,j}/\tau)}
        \right)
        +\lambda\lVert\theta\rVert_2^2
        $$
        ### After formula
        """#

        let blocks = parseCommonMark(markdown)

        #expect(blocks.count == 3)
        guard case .codeBlock(let language, let source) = blocks[1] else {
            Issue.record("Expected the complete display to be one typed LaTeX block, got \(blocks[1])")
            return
        }
        #expect(language == "latex")
        #expect(source.contains("\n=\n"))
        #expect(source.hasPrefix(#"\mathcal L(\theta)"#))
        #expect(source.hasSuffix(#"+\lambda\lVert\theta\rVert_2^2"#))
        guard case .heading(3, let heading) = blocks[2] else {
            Issue.record("Expected the heading immediately after the display closer")
            return
        }
        #expect(plainText(from: heading) == "After formula")
    }

    @Test func displayMathMayContainBlankLinesWithoutBecomingMarkdownBlocks() {
        let markdown = #"""
        $$

        \begin{cases}
        x^2, & x \ge 0 \\
        -x, & x < 0
        \end{cases}

        $$
        """#

        let blocks = parseCommonMark(markdown)

        #expect(blocks.count == 1)
        guard case .codeBlock("latex", let source) = blocks.first else {
            Issue.record("Expected one LaTeX block")
            return
        }
        #expect(source.hasPrefix("\n"))
        #expect(source.contains(#"\begin{cases}"#))
        #expect(source.hasSuffix("\n"))
    }

    @Test func multilineBracketDisplayIsOpaqueToCommonMark() {
        let markdown = #"""
        \[
        \begin{aligned}
        \mathbf H &= \mathbf X^\top\mathbf W\mathbf X+\lambda\mathbf I,\\
        \Delta\theta &= -\mathbf H^{-1}\nabla_\theta\mathcal L
        \end{aligned}
        \]
        """#

        let blocks = parseCommonMark(markdown)

        guard case .codeBlock("latex", let source) = blocks.first else {
            Issue.record("Expected one bracket-delimited LaTeX block")
            return
        }
        #expect(source.contains(#"\begin{aligned}"#))
        #expect(source.contains(#"\Delta\theta &= -\mathbf H^{-1}"#))
        #expect(!source.contains(#"\["#))
        #expect(!source.contains(#"\]"#))
    }

    @Test func displayDelimitersInsideCodeRemainExactCodeSource() {
        let markdown = #"""
        ```text
        $$
        x^2
        $$
        \[
        y_0
        \]
        ```
        """#

        let blocks = parseCommonMark(markdown)

        guard case .codeBlock("text", let source) = blocks.first else {
            Issue.record("Expected ordinary fenced code")
            return
        }
        #expect(source.contains("$$\nx^2\n$$"))
        #expect(source.contains("\\[\ny_0\n\\]"))
    }

    @Test func displayDelimitersInsideMultilineCodeSpanRemainInlineCode() {
        let markdown = #"""
        ``code begins
        $$
        x^2
        $$
        code ends``
        """#

        let blocks = parseCommonMark(markdown)

        guard case .paragraph(let inlines) = blocks.first,
              case .code(let source) = inlines.first else {
            Issue.record("Expected one multiline CommonMark code span")
            return
        }
        #expect(source.contains("$$ x^2 $$"))
    }

    @Test func displayMathLocatedRangeIncludesDelimitersAndFollowingHeadingKeepsItsLine() {
        let markdown = "Before\n\n$$\nx^2\n=\ny^2\n$$\n### After\n"

        let blocks = parseCommonMarkLocated(markdown)

        #expect(blocks.map(\.lineRange) == [1...1, 3...7, 8...8])
    }

    @Test func simpleCompletedDisplayMathIsAcceptedWithoutHeuristics() throws {
        for markdown in ["$$ x $$\n", "$$\nx\n$$\n"] {
            let block = try #require(parseCommonMark(markdown).first)
            guard case .codeBlock("latex", let source) = block else {
                Issue.record("Expected explicit completed display to render as LaTeX: \(block)")
                continue
            }
            #expect(source.trimmingCharacters(in: .whitespacesAndNewlines) == "x")
        }
    }

    @Test func displayMarkersInsideCommonMarkHTMLBlocksRemainExactAndNeverLeakTokens() throws {
        let sources = [
            "<div>\n$$\nx\n$$\n</div>\n\n### After\n",
            "<script>\nconst formula = `$$\\n x \\n$$`;\n</script>\n\n- After\n",
            "<!--\n$$\nx\n$$\n-->\n\n### After\n",
        ]

        for markdown in sources {
            let blocks = parseCommonMark(markdown)
            guard case .htmlBlock(let html) = try #require(blocks.first) else {
                Issue.record("Expected CommonMark HTML block")
                continue
            }
            #expect(html.contains("$$"))
            #expect(!html.contains("opmath"))
            #expect(blocks.contains { block in
                if case .heading = block { return true }
                if case .unorderedList = block { return true }
                return false
            })
        }
    }

    @Test func tabAndMixedIndentationKeepDisplayMarkersInsideIndentedCode() throws {
        for markdown in ["\t$$\n\tx\n\t$$\n", " \t$$\n \tx\n \t$$\n"] {
            let block = try #require(parseCommonMark(markdown).first)
            guard case .codeBlock(nil, let code) = block else {
                Issue.record("Expected tab-indented CommonMark code, got \(block)")
                continue
            }
            #expect(code == "$$\nx\n$$")
            #expect(!code.contains("opmath"))
        }
    }

    @Test func unclosedDisplayDoesNotConsumeFollowingHeadingOrList() {
        let markdown = "Before\n\n$$\nx\n### Still a heading\n\n- Still a list\n"
        let blocks = parseCommonMark(markdown)

        #expect(blocks.contains { if case .heading(3, _) = $0 { return true }; return false })
        #expect(blocks.contains { if case .unorderedList = $0 { return true }; return false })
        let visible = blocks.map { block -> String in
            switch block {
            case .paragraph(let inlines): return plainText(from: inlines)
            case .heading(_, let inlines): return plainText(from: inlines)
            default: return ""
            }
        }.joined(separator: "\n")
        #expect(visible.contains("$$"))
        #expect(visible.contains("Still a heading"))
    }

    @Test func recoveredDisplayStopsBeforeOrdinaryBlocksEvenIfLaterDollarLineExists() {
        let markdown = "$$\nx\n### Heading after unmatched display\n\n- List after unmatched display\n\n$$\nAfter\n"
        let blocks = parseCommonMark(markdown)

        #expect(blocks.contains { if case .heading(3, _) = $0 { return true }; return false })
        #expect(blocks.contains { if case .unorderedList = $0 { return true }; return false })
        #expect(!blocks.contains { if case .codeBlock("latex", _) = $0 { return true }; return false })
    }

    @Test func apparentCloserInsideFenceDoesNotCloseDisplay() {
        let markdown = "$$\nx\n```text\n$$\n```\n### After\n"
        let blocks = parseCommonMark(markdown)

        #expect(blocks.contains { if case .heading(3, _) = $0 { return true }; return false })
        let code = blocks.compactMap { block -> String? in
            guard case .codeBlock(let language, let source) = block, language == "text" else {
                return nil
            }
            return source
        }.first
        #expect(code == "$$")
    }

    @Test func laterCloserAfterFenceDoesNotTurnCodeIntoDisplayMath() throws {
        let markdown = "$$\nx\n```text\nordinary code\n```\n$$\nAfter\n"
        let blocks = parseCommonMark(markdown)

        #expect(!blocks.contains { if case .codeBlock("latex", _) = $0 { return true }; return false })
        let code = try #require(blocks.compactMap { block -> String? in
            guard case .codeBlock("text", let source) = block else { return nil }
            return source
        }.first)
        #expect(code == "ordinary code")
        let paragraphs = blocks.compactMap { block -> [MarkdownInline]? in
            guard case .paragraph(let inlines) = block else { return nil }
            return inlines
        }
        #expect(paragraphs.first == [.text("$$"), .softBreak, .text("x")])
        #expect(paragraphs.last == [.text("$$"), .softBreak, .text("After")])
    }

    @Test func laterCloserAfterHTMLBlockDoesNotTurnHTMLIntoDisplayMath() throws {
        let markdown = "$$\nx\n<div>\nordinary html\n</div>\n\n$$\nAfter\n"
        let blocks = parseCommonMark(markdown)

        #expect(!blocks.contains { if case .codeBlock("latex", _) = $0 { return true }; return false })
        let html = try #require(blocks.compactMap { block -> String? in
            guard case .htmlBlock(let source) = block else { return nil }
            return source
        }.first)
        #expect(html == "<div>\nordinary html\n</div>\n")
        let paragraphs = blocks.compactMap { block -> [MarkdownInline]? in
            guard case .paragraph(let inlines) = block else { return nil }
            return inlines
        }
        #expect(paragraphs.first == [.text("$$"), .softBreak, .text("x")])
        #expect(paragraphs.last == [.text("$$"), .softBreak, .text("After")])
    }

    @Test func laterCloserAfterMultilineCodeSpanDoesNotTurnCodeIntoDisplayMath() throws {
        let markdown = "$$\nx\n``code begins\nordinary code\ncode ends``\n$$\nAfter\n"
        let blocks = parseCommonMark(markdown)

        #expect(!blocks.contains { if case .codeBlock("latex", _) = $0 { return true }; return false })
        let inlineCode = try #require(blocks.compactMap { block -> String? in
            guard case .paragraph(let inlines) = block else { return nil }
            return inlines.compactMap { inline -> String? in
                guard case .code(let source) = inline else { return nil }
                return source
            }.first
        }.first)
        #expect(inlineCode == "code begins ordinary code code ends")
        let paragraphs = blocks.compactMap { block -> [MarkdownInline]? in
            guard case .paragraph(let inlines) = block else { return nil }
            return inlines
        }
        #expect(paragraphs == [[
            .text("$$"), .softBreak,
            .text("x"), .softBreak,
            .code("code begins ordinary code code ends"), .softBreak,
            .text("$$"), .softBreak,
            .text("After"),
        ]])
    }

    @Test func repeatedUnmatchedBracketOpenersRemainBoundedLiteralMarkdown() {
        let markdown = (0..<2_000).map { "\\[ unmatched-\($0)" }.joined(separator: "\n")
        let blocks = parseCommonMark(markdown)

        #expect(!blocks.contains { if case .codeBlock("latex", _) = $0 { return true }; return false })
        let visible = blocks.compactMap { block -> String? in
            guard case .paragraph(let inlines) = block else { return nil }
            return plainText(from: inlines)
        }.joined(separator: "\n")
        #expect(visible.contains("[ unmatched-0"))
        #expect(visible.contains("[ unmatched-1999"))
    }

    @Test func varyingUnmatchedBacktickRunsDoNotRescanDocumentSuffixes() {
        let runCount = 192
        let varyingRuns = (1...runCount).map { length in
            "prefix \(String(repeating: "`", count: length)) unmatched-\(length)"
        }
        let markdown = ([#"\["#] + varyingRuns + varyingRuns).joined(separator: "\n")

        let diagnostics = markdownMathScannerDiagnostics(markdown)
        let lineCount = 1 + varyingRuns.count * 2

        #expect(diagnostics.indexedBacktickRuns == varyingRuns.count * 2)
        #expect(
            diagnostics.suffixLineVisits == 0,
            "Scanner revisited \(diagnostics.suffixLineVisits) suffix lines for \(lineCount) input lines"
        )
    }

    @Test func boundedCandidateScannerStaysFastAcrossLateOpaqueBoundaryAndLaterCloser() {
        let openers = Array(repeating: #"\["#, count: 1_023)
        let largeGap = (0..<8_000).map { "gap line \($0)" }
        let markdown = (openers + largeGap + ["<div>", "opaque", "</div>", "", #"\]"#, "After"])
            .joined(separator: "\n")

        let clock = ContinuousClock()
        let start = clock.now
        let blocks = parseCommonMark(markdown)
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(8), "Display scan should be linear/bounded; elapsed \(elapsed)")
        #expect(!blocks.contains { if case .codeBlock("latex", _) = $0 { return true }; return false })
        #expect(blocks.contains { block in
            guard case .htmlBlock(let html) = block else { return false }
            return html.contains("opaque")
        })
    }

    @Test func displayTokenBaseExhaustionFailsClosedWithoutChangingSource() {
        let collisions = [
            "opmathaz", "opmathbz", "opmathcz", "opmathdz",
            "opmathez", "opmathfz", "opmathgz", "opmathhz",
        ].joined(separator: " ")
        let markdown = "\(collisions)\n\n$$\nx\n$$\n"
        let blocks = parseCommonMark(markdown)
        let visible = blocks.compactMap { block -> String? in
            guard case .paragraph(let inlines) = block else { return nil }
            return plainText(from: inlines)
        }.joined(separator: "\n")

        #expect(visible.contains(collisions))
        #expect(visible.contains("$$"))
        #expect(visible.contains("x"))
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

    // MARK: - Four-backtick fence cleanup

    @Test func fourBacktickFenceStripsTrailingInnerFence() {
        let md = "````swift\nlet x = 1\n```\n````\n"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .codeBlock(let lang, let code) = blocks[0] else {
            Issue.record("Expected codeBlock"); return
        }
        #expect(lang == "swift")
        #expect(code == "let x = 1")
    }

    @Test func fourBacktickFenceWithClosingBraceAndInnerFence() {
        let md = "````swift\nfunc foo() {\n    let x = 1\n}\n```\n````\n"
        let blocks = parseCommonMark(md)
        guard case .codeBlock(let lang, let code) = blocks[0] else {
            Issue.record("Expected codeBlock"); return
        }
        #expect(lang == "swift")
        #expect(code == "func foo() {\n    let x = 1\n}")
    }

    @Test func fourBacktickFencePreservesInternalFences() {
        let md = "````markdown\nHere is code:\n```python\nprint('hi')\n```\n````\n"
        let blocks = parseCommonMark(md)
        guard case .codeBlock(_, let code) = blocks[0] else {
            Issue.record("Expected codeBlock"); return
        }
        #expect(code == "Here is code:\n```python\nprint('hi')\n```")
    }

    @Test func fourBacktickFenceWithTildeInnerFence() {
        let md = "````swift\nlet x = 1\n~~~\n````\n"
        let blocks = parseCommonMark(md)
        guard case .codeBlock(_, let code) = blocks[0] else {
            Issue.record("Expected codeBlock"); return
        }
        #expect(code == "let x = 1")
    }

    @Test func standardThreeBacktickFenceUnchanged() {
        let md = "```swift\nlet x = 1\n```\n"
        let blocks = parseCommonMark(md)
        guard case .codeBlock(_, let code) = blocks[0] else {
            Issue.record("Expected codeBlock"); return
        }
        #expect(code == "let x = 1")
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

    @Test func bulletListInlineParenLatexKeepsExactMathSource() {
        let markdown = #"""
        - \(\mathrm{target\_burn} = R / T\)
        - \(\mathrm{recent\_burn} = \max(0, R_{\mathrm{prev}} - R_{\mathrm{now}}) / \mathrm{lookback}\), smoothed over that window using the same unit as T
        - \(\mathrm{pace\_ratio} = \mathrm{recent\_burn} \times T / R\)
        """#

        let blocks = parseCommonMark(markdown)
        guard case .unorderedList(let items) = blocks.first else {
            Issue.record("Expected one unordered list, got \(blocks)")
            return
        }
        #expect(items.count == 3)

        let itemSources = items.map { item in
            item.compactMap { block -> String? in
                guard case .paragraph(let inlines) = block else { return nil }
                return plainText(from: inlines)
            }.joined()
        }

        #expect(itemSources == [
            #"\(\mathrm{target\_burn} = R / T\)"#,
            #"\(\mathrm{recent\_burn} = \max(0, R_{\mathrm{prev}} - R_{\mathrm{now}}) / \mathrm{lookback}\), smoothed over that window using the same unit as T"#,
            #"\(\mathrm{pace\_ratio} = \mathrm{recent\_burn} \times T / R\)"#,
        ])
        #expect(!itemSources.joined().contains("opmath"))
    }

    // MARK: - Task Lists

    @Test func taskListUnchecked() {
        let md = "- [ ] item 1\n- [ ] item 2\n"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .taskList(let items) = blocks[0] else {
            Issue.record("Expected taskList, got \(blocks[0])")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].checked == false)
        #expect(items[1].checked == false)
    }

    @Test func taskListChecked() {
        let md = "- [x] done\n- [ ] todo\n- [x] also done\n"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .taskList(let items) = blocks[0] else {
            Issue.record("Expected taskList, got \(blocks[0])")
            return
        }
        #expect(items.count == 3)
        #expect(items[0].checked == true)
        #expect(items[1].checked == false)
        #expect(items[2].checked == true)
    }

    @Test func taskListItemContent() {
        let md = "- [x] **bold** task\n"
        let blocks = parseCommonMark(md)
        guard case .taskList(let items) = blocks[0] else {
            Issue.record("Expected taskList")
            return
        }
        #expect(items.count == 1)
        #expect(items[0].checked == true)
        guard case .paragraph(let inlines) = items[0].content.first else {
            Issue.record("Expected paragraph in task item content")
            return
        }
        #expect(plainText(from: inlines) == "bold task")
    }

    @Test func regularListNotTaskList() {
        let md = "- normal item\n- another item\n"
        let blocks = parseCommonMark(md)
        guard case .unorderedList = blocks[0] else {
            Issue.record("Expected unorderedList, not taskList")
            return
        }
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
        #expect(headers.map { plainText(from: $0) } == ["Header 1", "Header 2"])
        #expect(rows.count == 2)
        #expect(rows[0].map { plainText(from: $0) } == ["Cell A", "Cell B"])
        #expect(rows[1].map { plainText(from: $0) } == ["Cell C", "Cell D"])
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

        #expect(headers.map { plainText(from: $0) } == ["What", "Path"])
        #expect(rows[0].map { plainText(from: $0) } == ["Session state", "~/.config/pi-remote/sessions/<userId>/<sessionId>.json"])
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
        let markdown = "Migrate via [invite](oppi://connect?v=3&invite=test-payload).\n"
        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks)

        guard let first = segments.first,
              case .text(let attributed) = first else {
            Issue.record("Expected first segment to be .text")
            return
        }

        let links = attributed.runs.compactMap(\.link)
        #expect(links.count == 1)
        #expect(links.first?.absoluteString == "oppi://connect?v=3&invite=test-payload")
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

    @Test func codeBlockInsideListItemStillProducesCodeSegment() {
        let markdown = """
        1. Start the server:

           ```bash
           cd server
           node dist/src/cli.js serve
           ```

        2. Continue setup.
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

        #expect(String(before.characters).contains("1. Start the server:"))
        #expect(language == "bash")
        #expect(code == "cd server\nnode dist/src/cli.js serve")
        #expect(String(after.characters).contains("2. Continue setup."))
    }

    @Test func fourBacktickFenceCodeBlockCleanInFlatSegments() {
        let markdown = "Before.\n\n````swift\nfunc foo() {\n    return 1\n}\n```\n````\n\nAfter.\n"
        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks)
        #expect(segments.count == 3)
        guard case .codeBlock(let language, let code) = segments[1] else {
            Issue.record("Expected second segment to be code block"); return
        }
        #expect(language == "swift")
        #expect(code == "func foo() {\n    return 1\n}")
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
        #expect(headers.map { plainText(from: $0) } == ["Col A", "Col B"])
        #expect(rows.count == 2)
        #expect(rows[0].map { plainText(from: $0) } == ["val1", "val2"])
        #expect(rows[1].map { plainText(from: $0) } == ["val3", "va"])
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
        #expect(headers.map { plainText(from: $0) } == ["Col A", "Col B"])
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
        #expect(headers.map { plainText(from: $0) } == ["Col A", "Col B"])
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
        #expect(rows[1].map { plainText(from: $0) } == ["3", "4"])
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
        #expect(rows[1].map { plainText(from: $0) } == ["3", ""])
    }
}

// MARK: - Lenient table markup

@Suite("Lenient table markup")
struct LenientTableMarkupTests {
    @Test func alignedGFMTableFromUserReportParses()
    {
        let md = """
        | Tree | Files | Lines |
        |------|------:|------:|
        | `server/src/**/*.ts` | 245 | 84,865 |
        | `clients/apple/**/*.swift` (tests, E2E, perf, Mac included) | 1,002 | 353,511 |
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .table(let headers, let rows) = blocks[0] else {
            Issue.record("Expected GFM table, got \(String(describing: blocks.first))")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["Tree", "Files", "Lines"])
        #expect(rows.count == 2)
        #expect(rows[0].map { plainText(from: $0) } == ["server/src/**/*.ts", "245", "84,865"])
        #expect(rows[1][1...].map { plainText(from: $0) } == ["1,002", "353,511"])
    }

    @Test func orgStylePlusDelimiterParsesAsTable() throws {
        let md = """
        | Name | Value |
        |------+-------|
        | foo  | bar   |
        """
        let blocks = parseCommonMark(md)
        guard case .table(let headers, let rows) = try #require(blocks.first) else {
            Issue.record("Expected org-style delimiter to become a table")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["Name", "Value"])
        #expect(rows.map { $0.map { plainText(from: $0) } } == [["foo", "bar"]])
    }

    @Test func unicodeDashDelimiterParsesAsTable() throws {
        let md = """
        Tree | Files | Lines
        —— | —— | ——
        server | 245 | 84865
        """
        let blocks = parseCommonMark(md)
        guard case .table(let headers, let rows) = try #require(blocks.first) else {
            Issue.record("Expected em-dash delimiter to become a table")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["Tree", "Files", "Lines"])
        #expect(rows.map { $0.map { plainText(from: $0) } } == [["server", "245", "84865"]])
    }

    @Test func boxDrawingDelimiterParsesAsTable() throws {
        let md = """
        | Path | Lines |
        | ──── | ────: |
        | a.ts | 12 |
        """
        let blocks = parseCommonMark(md)
        guard case .table(_, let rows) = try #require(blocks.first) else {
            Issue.record("Expected box-drawing delimiter to become a table")
            return
        }
        #expect(rows.map { $0.map { plainText(from: $0) } } == [["a.ts", "12"]])
    }

    @Test func simpleHTMLTableParsesAsTable() throws {
        let md = """
        <table>
        <tr><th>Path</th><th>Lines</th></tr>
        <tr><td><code>a.ts</code></td><td>12</td></tr>
        </table>
        """
        let blocks = parseCommonMark(md)
        guard case .table(let headers, let rows) = try #require(blocks.first) else {
            Issue.record("Expected simple HTML table, got \(String(describing: blocks.first))")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["Path", "Lines"])
        #expect(rows.map { $0.map { plainText(from: $0) } } == [["a.ts", "12"]])
    }

    @Test func htmlTableWithColspanStaysHTML()
    {
        let md = """
        <table>
        <tr><td colspan=\"2\">wide</td></tr>
        </table>
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.contains { if case .htmlBlock = $0 { true } else { false } })
        #expect(!blocks.contains { if case .table = $0 { true } else { false } })
    }

    @Test func fencedHTMLTableStaysCode()
    {
        let md = """
        ```html
        <table>
        <tr><th>A</th></tr>
        <tr><td>1</td></tr>
        </table>
        ```
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .codeBlock("html", let code) = blocks[0] else {
            Issue.record("Expected fenced HTML to stay a code block")
            return
        }
        #expect(code.contains("<table>"))
    }

    @Test func plusInTableCellIsNotADelimiter() throws {
        let md = """
        | Expr | Value |
        | --- | --- |
        | 1+2 | 3 |
        """
        let blocks = parseCommonMark(md)
        guard case .table(_, let rows) = try #require(blocks.first) else {
            Issue.record("Expected ordinary GFM table")
            return
        }
        #expect(rows.map { $0.map { plainText(from: $0) } } == [["1+2", "3"]])
    }

    @Test func emDashThematicBreakIsNotATable()
    {
        let blocks = parseCommonMark("———\n")
        #expect(!blocks.contains { if case .table = $0 { true } else { false } })
    }

    @Test func htmlTableAfterParagraphWithoutBlankLineStillParses() throws {
        let md = """
        Summary
        <table><tr><th>Path</th><th>Lines</th></tr><tr><td>a.ts</td><td>12</td></tr></table>
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.contains { if case .paragraph = $0 { true } else { false } })
        guard let table = blocks.first(where: { if case .table = $0 { true } else { false } }),
              case .table(let headers, let rows) = table else {
            Issue.record("Expected a table after the paragraph, got \(blocks)")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["Path", "Lines"])
        #expect(rows.map { $0.map { plainText(from: $0) } } == [["a.ts", "12"]])
    }

    @Test func htmlTableWithTheadTbodyParses() throws {
        let md = """
        <table>
        <thead><tr><th>A</th><th>B</th></tr></thead>
        <tbody><tr><td>1</td><td>2</td></tr></tbody>
        </table>
        """
        let blocks = parseCommonMark(md)
        guard case .table(let headers, let rows) = try #require(blocks.first) else {
            Issue.record("Expected thead/tbody HTML to become a table")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["A", "B"])
        #expect(rows.map { $0.map { plainText(from: $0) } } == [["1", "2"]])
    }

    @Test func dashOnlyBodyRowAfterDelimiterIsNotRewritten() throws {
        let md = """
        | A | B |
        | --- | --- |
        | + | - |
        | foo | bar |
        """
        let blocks = parseCommonMark(md)
        guard case .table(_, let rows) = try #require(blocks.first) else {
            Issue.record("Expected a table")
            return
        }
        #expect(rows.map { $0.map { plainText(from: $0) } } == [["+", "-"], ["foo", "bar"]])
    }

    @Test func locatedHTMLTableDoesNotShiftFollowingHeadingLine() throws {
        let md = """
        <table>
        <tr><th>A</th></tr>
        <tr><td>1</td></tr>
        </table>

        ## After
        """
        let located = parseCommonMarkLocated(md)
        guard let heading = located.first(where: {
            if case .heading = $0.block { return true }
            return false
        }) else {
            Issue.record("Expected a heading after the HTML table")
            return
        }
        #expect(heading.lineRange?.lowerBound == 6)
    }

    @Test func fencedOrgDelimiterStaysCode() {
        let md = """
        ```
        | Name | Value |
        |------+-------|
        | foo  | bar   |
        ```
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        guard case .codeBlock(_, let code) = blocks[0] else {
            Issue.record("Expected fenced org table to stay a code block")
            return
        }
        #expect(code.contains("|------+-------|"))
        #expect(!blocks.contains { if case .table = $0 { true } else { false } })
    }
}
