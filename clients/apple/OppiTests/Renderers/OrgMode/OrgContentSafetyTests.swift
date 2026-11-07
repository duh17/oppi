import Testing
@testable import Oppi

/// Content-hiding Org bugs the owner approved first: each one loses or
/// misrenders content rather than merely showing it plainly. Every case here
/// failed before the fix landed.
@Suite("Org content-safety fixes")
struct OrgContentSafetyTests {
    let parser = OrgParser()

    // MARK: - Unterminated drawer

    @Test func unterminatedDrawerDoesNotSwallowTheRestOfTheFile() {
        let blocks = parser.parse("""
        * Heading one
        :PROPERTIES:
        :ID: abc
        * Heading two
        Body text.
        """)
        let headings = blocks.compactMap { block -> String? in
            if case let .heading(_, _, _, title, _) = block { return headingPlainText(title) }
            return nil
        }
        #expect(headings == ["Heading one", "Heading two"], "the second heading must not vanish into an unterminated drawer")
        #expect(blocks.contains { if case .paragraph(let inlines) = $0 { return inlines == [.text("Body text.")] }; return false })
    }

    @Test func drawerWithAnEndStillParsesAsADrawer() {
        let blocks = parser.parse("""
        :PROPERTIES:
        :ID: abc
        :END:
        After.
        """)
        guard case .drawer = blocks[0] else {
            Issue.record("Expected a drawer, got \(blocks[0])")
            return
        }
        #expect(blocks[1] == .paragraph([.text("After.")]))
    }

    // MARK: - Indented `*`

    @Test func indentedStarUnderAListItemStaysPlainTextNotAHeading() {
        let blocks = parser.parse("""
        - Item
          * not a heading
        """)
        #expect(!blocks.contains { if case .heading = $0 { return true }; return false })
    }

    @Test func indentedStarAtTopLevelStaysAParagraph() {
        let blocks = parser.parse("  * item")
        #expect(blocks.count == 1)
        guard case .paragraph = blocks[0] else {
            Issue.record("Expected a paragraph, got \(blocks[0])")
            return
        }
    }

    @Test func indentedStarSurvivesTheMarkdownRoundTripAsPlainTextNotABullet() {
        // The paragraph it falls back to still starts with a literal "* ",
        // which Markdown reads as its own bullet marker unless escaped.
        let markdown = DocumentRenderPipeline.orgToMarkdown("  * item")
        let parsed = parseCommonMark(markdown)
        #expect(!parsed.contains { if case .unorderedList = $0 { return true }; return false }, "got \(parsed)")
        guard case .paragraph(let inlines)? = parsed.first else {
            Issue.record("Expected a paragraph, got \(parsed)")
            return
        }
        #expect(plainText(from: inlines).contains("* item"))
    }

    @Test func columnZeroStarIsStillAHeading() {
        // The fix narrows heading detection to column 0; it must not break it.
        #expect(parser.parse("* item") == [
            .heading(level: 1, keyword: nil, priority: nil, title: [.text("item")], tags: []),
        ])
    }

    // MARK: - 4-space indented body

    @Test func fourSpaceIndentedBodyStaysAParagraphNotACodeBlock() {
        let blocks = parser.parse("""
        * Heading
            Indented body text.
        """)
        #expect(blocks[1] == .paragraph([.text("Indented body text.")]))
    }

    @Test func fourSpaceIndentSurvivesTheMarkdownRoundTripAsAParagraph() {
        let markdown = DocumentRenderPipeline.orgToMarkdown("""
        * Heading
            Indented body text.
        """)
        let parsed = parseCommonMark(markdown)
        #expect(!parsed.contains { if case .codeBlock = $0 { return true }; return false }, "got \(parsed)")
        #expect(parsed.contains { if case .paragraph(let inlines) = $0 { return plainText(from: inlines).contains("Indented body text.") }; return false })
    }

    // MARK: - Markdown escaping

    @Test func backslashEscapedLatexDoesNotSilentlyLoseItsBackslashes() {
        // The reader's own `\(...\)` math protection (CMarkFastParser) keeps
        // an escaped pair verbatim rather than collapsing it the way a plain
        // backslash escape would: the fix's job is that the backslash is
        // never silently dropped (the original bug), not byte-exact
        // round-tripping through that unrelated machinery.
        let markdown = DocumentRenderPipeline.orgToMarkdown(#"Equation \(a+b\) holds."#)
        let parsed = parseCommonMark(markdown)
        guard case .paragraph(let inlines)? = parsed.first else {
            Issue.record("Expected a paragraph, got \(parsed)")
            return
        }
        let text = plainText(from: inlines)
        #expect(text.contains("\\"), "a backslash must not silently vanish: got \(text)")
        #expect(text.contains("a+b"))
    }

    @Test func doubleBackslashLineBreakSurvivesTheMarkdownRoundTrip() {
        let markdown = DocumentRenderPipeline.orgToMarkdown(#"A line break\\ here."#)
        let parsed = parseCommonMark(markdown)
        guard case .paragraph(let inlines)? = parsed.first else {
            Issue.record("Expected a paragraph, got \(parsed)")
            return
        }
        #expect(plainText(from: inlines) == #"A line break\\ here."#)
    }

    @Test func leadingAngleBracketQuoteDoesNotBecomeABlockQuote() {
        let markdown = DocumentRenderPipeline.orgToMarkdown("> not a quote")
        let parsed = parseCommonMark(markdown)
        #expect(!parsed.contains { if case .blockQuote = $0 { return true }; return false }, "got \(parsed)")
        guard case .paragraph(let inlines)? = parsed.first else {
            Issue.record("Expected a paragraph, got \(parsed)")
            return
        }
        #expect(plainText(from: inlines) == "> not a quote")
    }

    @Test func literalAngleBracketTagStaysTextNotRawHTML() {
        let markdown = DocumentRenderPipeline.orgToMarkdown("A <tag> in prose.")
        let parsed = parseCommonMark(markdown)
        #expect(!parsed.contains { if case .htmlBlock = $0 { return true }; return false }, "got \(parsed)")
        guard case .paragraph(let inlines)? = parsed.first else {
            Issue.record("Expected a paragraph, got \(parsed)")
            return
        }
        #expect(plainText(from: inlines) == "A <tag> in prose.")
    }

    @Test func literalBracketsDoNotBecomeALink() {
        let markdown = DocumentRenderPipeline.orgToMarkdown("See [x](y) in text.")
        let parsed = parseCommonMark(markdown)
        guard case .paragraph(let inlines)? = parsed.first else {
            Issue.record("Expected a paragraph, got \(parsed)")
            return
        }
        #expect(!inlines.contains { if case .link = $0 { return true }; return false })
        #expect(plainText(from: inlines) == "See [x](y) in text.")
    }

    @Test func escapingABracketNeverWritesTheTwoByteSequenceThatTriggersAWholeDocumentMathScan() {
        // CMarkFastParser's math-protection fast path skips a document that
        // has none of `$`, `\[`, or `\(...\)`; writing `\[` for an ordinary
        // `]( ` escape would push every large file through that scan.
        let markdown = DocumentRenderPipeline.orgToMarkdown("See [x](y) and [a][b] and [lone] brackets.")
        #expect(!markdown.contains("\\["), "got \(markdown)")
    }

    @Test func backticksStillWorkAfterEscaping() {
        let markdown = DocumentRenderPipeline.orgToMarkdown("Use `println` here.")
        let parsed = parseCommonMark(markdown)
        guard case .paragraph(let inlines)? = parsed.first else {
            Issue.record("Expected a paragraph, got \(parsed)")
            return
        }
        #expect(inlines.contains { if case .code("println") = $0 { return true }; return false })
    }

    // MARK: - CRLF

    @Test func crlfOrgFileParsesTheSameAsLF() {
        let lf = "* Heading one\nBody one.\n\n* Heading two\nBody two.\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(parser.parse(crlf) == parser.parse(lf))
        #expect(parser.parse(crlf).count == 4, "a CRLF file must not collapse into one block")
    }

    @Test func crlfOrgFileSurvivesTheWholePipeline() {
        let crlf = "* Heading one\r\nBody one.\r\n\r\n* Heading two\r\nBody two.\r\n"
        let markdown = DocumentRenderPipeline.orgToMarkdown(crlf)
        let parsed = parseCommonMark(markdown)
        let headings = parsed.filter { if case .heading = $0 { return true }; return false }
        #expect(headings.count == 2, "expected 2 headings, got \(parsed)")
    }

    // MARK: - Helpers

    private func headingPlainText(_ inlines: [OrgInline]) -> String {
        inlines.map { inline -> String in
            if case .text(let s) = inline { return s }
            return ""
        }.joined()
    }
}
