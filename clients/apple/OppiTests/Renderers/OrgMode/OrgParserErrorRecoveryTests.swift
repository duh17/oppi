import Testing
@testable import Oppi

/// Error recovery tests — verify the parser never crashes on malformed input
/// and degrades gracefully to plain text paragraphs.
@Suite("OrgParser Error Recovery")
struct OrgParserErrorRecoveryTests {

    let parser = OrgParser()

    // MARK: - Bulk Fuzz (no crashes)

    @Test("Parser does not crash on adversarial inputs")
    func noCrashOnAdversarial() {
        RendererTestSupport.assertNoParseFailure(parser: parser, inputs: [
            "",
            " ",
            "\n",
            "\n\n\n",
            "*",
            "**",
            "***",
            "****",
            "*****",
            "* ",
            "#+",
            "#+begin_src",
            "#+end_src",
            "#+begin_quote",
            "#+end_quote",
            "#+begin_src\n",
            "[[",
            "]]",
            "[[url",
            "[[url]",
            "[[url][desc",
            "[[url][desc]",
            "[[][]]",
            "=",
            "==",
            "~",
            "~~",
            "++",
            "__",
            "//",
            "*unclosed bold",
            "/unclosed italic",
            "_unclosed underline",
            "=unclosed verbatim",
            "~unclosed code",
            "+unclosed strike",
            "- ",
            "+ ",
            "1.",
            "1. ",
            "1)",
            "1) ",
            "#",
            "# ",
            "-----",
            "----",
            "---",
            "--",
            "-",
        ])
    }

    @Test("Parser does not crash on deeply nested markup")
    func noCrashDeepNesting() {
        // Generate deeply nested bold
        var input = ""
        for _ in 0..<50 {
            input += "*"
        }
        input += "text"
        for _ in 0..<50 {
            input += "*"
        }
        RendererTestSupport.assertNoParseFailure(parser: parser, inputs: [input])
    }

    @Test("Parser does not crash on very long lines")
    func noCrashLongLine() {
        let longLine = String(repeating: "a", count: 100_000)
        RendererTestSupport.assertNoParseFailure(parser: parser, inputs: [longLine])
    }

    @Test("Parser does not crash on many headings")
    func noCrashManyHeadings() {
        let input = (1...1000).map { "* Heading \($0)" }.joined(separator: "\n")
        RendererTestSupport.assertNoParseFailure(parser: parser, inputs: [input])
    }

    @Test("Parser does not crash on binary-like content")
    func noCrashBinaryContent() {
        let binaryish = String((0..<128).map { Character(UnicodeScalar($0)) })
        RendererTestSupport.assertNoParseFailure(parser: parser, inputs: [binaryish])
    }

    // MARK: - Unclosed Blocks

    @Test("Unclosed source block returns code with remaining content")
    func unclosedCodeBlock() {
        let input = """
        #+begin_src python
        def broken():
            pass
        """
        let result = parser.parse(input)
        // Should not crash; code block grabs everything until EOF
        #expect(result.count == 1)
        if case let .codeBlock(lang, code) = result[0] {
            #expect(lang == "python")
            #expect(code.contains("def broken()"))
        } else {
            Issue.record("Expected codeBlock, got \(result[0])")
        }
    }

    @Test("Unclosed quote block returns content")
    func unclosedQuoteBlock() {
        let input = """
        #+begin_quote
        This quote never ends.
        """
        let result = parser.parse(input)
        #expect(result.count == 1)
        if case let .quote(blocks) = result[0] {
            #expect(!blocks.isEmpty)
        } else {
            Issue.record("Expected quote, got \(result[0])")
        }
    }

    // MARK: - Malformed Headings

    @Test("Stars with no space are paragraphs")
    func starsNoSpaceAreParagraphs() {
        let result = parser.parse("***word")
        #expect(result.count == 1)
        if case .paragraph = result[0] { } else {
            Issue.record("Expected paragraph for '***word'")
        }
    }

    @Test("Heading with unknown keyword treated as title")
    func unknownKeywordInTitle() {
        let result = parser.parse("* CUSTOM This is title")
        // CUSTOM is not a recognized keyword, so it becomes part of the title
        if case let .heading(_, keyword, _, title, _) = result[0] {
            #expect(keyword == nil)
            // "CUSTOM This is title" should be in the title
            let fullText = title.map { inline -> String in
                if case let .text(t) = inline { return t }
                return ""
            }.joined()
            #expect(fullText.contains("CUSTOM"))
        }
    }

    // MARK: - Malformed Links

    @Test("Incomplete link treated as text")
    func incompleteLinkAsText() {
        let result = parser.parse("Visit [[broken link")
        if case let .paragraph(inlines) = result[0] {
            // Should contain text, not a link
            let hasLink = inlines.contains { if case .link = $0 { return true }; return false }
            #expect(!hasLink)
        }
    }

    @Test("Single brackets are text")
    func singleBracketsAreText() {
        let result = parser.parse("[not a link]")
        #expect(result == [.paragraph([.text("[not a link]")])])
    }

    // MARK: - Malformed Lists

    @Test("Dash without space is paragraph")
    func dashWithoutSpace() {
        let result = parser.parse("-not a list item")
        if case .paragraph = result[0] { } else {
            Issue.record("Expected paragraph for '-not a list item'")
        }
    }

    @Test("Number without period/paren is paragraph")
    func numberAloneIsParagraph() {
        let result = parser.parse("42 is the answer")
        if case .paragraph = result[0] { } else {
            Issue.record("Expected paragraph")
        }
    }

    // MARK: - Malformed Markup

    @Test("Unmatched bold marker preserved as text")
    func unmatchedBoldText() {
        let result = parser.parse("This *never closes")
        if case let .paragraph(inlines) = result[0] {
            let hasBold = inlines.contains { if case .bold = $0 { return true }; return false }
            #expect(!hasBold, "Unmatched * should not produce bold")
        }
    }

    @Test("Marker with space after opening is not markup")
    func markerSpaceAfterOpening() {
        // `* text*` — space after opening * means not markup
        // (but we need to be careful: `* ` at line start IS a heading)
        let result = parser.parse("word * not bold* end")
        if case let .paragraph(inlines) = result[0] {
            let hasBold = inlines.contains { if case .bold = $0 { return true }; return false }
            #expect(!hasBold, "Space after * should prevent markup")
        }
    }

    @Test("Marker with space before closing is not markup")
    func markerSpaceBeforeClosing() {
        let result = parser.parse("This is *not bold * here")
        if case let .paragraph(inlines) = result[0] {
            let hasBold = inlines.contains { if case .bold = $0 { return true }; return false }
            #expect(!hasBold, "Space before closing * should prevent markup")
        }
    }

    // MARK: - Edge Cases

    @Test("Only newlines")
    func onlyNewlines() {
        let result = parser.parse("\n\n\n\n\n")
        #expect(result.isEmpty)
    }

    @Test("Mixed valid and invalid on same line")
    func mixedValidInvalid() {
        let result = parser.parse("Valid *bold* and broken *unclosed and =good= end")
        if case let .paragraph(inlines) = result[0] {
            // Should have at least one bold and one verbatim
            let hasBold = inlines.contains { if case .bold = $0 { return true }; return false }
            let hasVerbatim = inlines.contains { if case .verbatim = $0 { return true }; return false }
            #expect(hasBold, "Should parse valid *bold*")
            #expect(hasVerbatim, "Should parse valid =good=")
        }
    }

    @Test("Keywords that look like block delimiters but aren't")
    func fakeBlockDelimiters() {
        // #+begin_unknown should be a keyword, not crash
        let result = parser.parse("#+begin_unknown something")
        #expect(result.count >= 1)
    }

    @Test("Comment vs keyword disambiguation")
    func commentVsKeyword() {
        // `# text` is a comment, `#+text` is a keyword
        let result = parser.parse("# Just a comment\n#+TITLE: Hello")
        #expect(result.count == 2)
        if case .comment = result[0] { } else { Issue.record("Expected comment") }
        if case .keyword = result[1] { } else { Issue.record("Expected keyword") }
    }

    @Test("Horizontal rule vs list item")
    func ruleVsListItem() {
        // `-----` is a rule, `- item` is a list
        let result = parser.parse("-----\n- item")
        #expect(result.count == 2)
        if case .horizontalRule = result[0] { } else { Issue.record("Expected rule") }
        if case .list = result[1] { } else { Issue.record("Expected list") }
    }

    @Test("Unicode content handled correctly")
    func unicodeContent() {
        let result = parser.parse("* 日本語の見出し :タグ:")
        #expect(result.count == 1)
        if case .heading = result[0] { } else {
            Issue.record("Expected heading with unicode content")
        }
    }

    @Test("Empty source block")
    func emptyCodeBlock() {
        let input = """
        #+begin_src
        #+end_src
        """
        let result = parser.parse(input)
        #expect(result == [.codeBlock(language: nil, code: "")])
    }

    @Test("Empty quote block")
    func emptyQuoteBlock() {
        let input = """
        #+begin_quote
        #+end_quote
        """
        let result = parser.parse(input)
        #expect(result == [.quote([])])
    }
}
