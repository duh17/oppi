import Testing
@testable import Oppi

/// The owner's third approved fix: one parser path for every
/// `#+begin_NAME … #+end_NAME` block, case-insensitive, covering `src` (with
/// a language), `example`, `quote`, `verse`, `center`, `export`, `comment`,
/// and names Org does not define.
@Suite("Org generic block parser")
struct OrgGenericBlockTests {
    let parser = OrgParser()

    @Test func srcBlockStillCarriesItsLanguage() {
        let blocks = parser.parse("""
        #+begin_src swift
        let x = 1
        #+end_src
        """)
        #expect(blocks == [.codeBlock(language: "swift", code: "let x = 1")])
    }

    @Test func quoteBlockStillRecursesIntoItsOwnBlocks() {
        let blocks = parser.parse("""
        #+begin_quote
        *Bold* inside a quote.
        #+end_quote
        """)
        #expect(blocks == [.quote([.paragraph([.bold([.text("Bold")]), .text(" inside a quote.")])])])
    }

    @Test func exampleBlockStaysLiteralNotReparsedAsOrgProse() {
        let blocks = parser.parse("""
        #+begin_example
        *not bold* and [[https://example.com]]
        #+end_example
        """)
        guard case let .codeBlock(language, code) = blocks[0] else {
            Issue.record("Expected a code block, got \(blocks[0])")
            return
        }
        #expect(language == nil)
        #expect(code == "*not bold* and [[https://example.com]]")
    }

    @Test func exampleBlockSurvivesTheMarkdownRoundTripUnparsed() {
        let markdown = DocumentRenderPipeline.orgToMarkdown("""
        #+begin_example
        *not bold* and a URL https://example.com
        #+end_example
        """)
        let parsed = parseCommonMark(markdown)
        guard case .codeBlock(_, let code)? = parsed.first else {
            Issue.record("Expected a code block, got \(parsed)")
            return
        }
        #expect(code.contains("*not bold*"), "the example block's own markup must not be parsed as Org or Markdown")
    }

    @Test func verseBlockKeepsItsLineBreaks() {
        let blocks = parser.parse("""
        #+begin_verse
        Verse keeps
        its line breaks
        #+end_verse
        """)
        #expect(blocks == [.verse([[.text("Verse keeps")], [.text("its line breaks")]])])
    }

    @Test func verseBlockHardBreaksSurviveTheMarkdownRoundTrip() {
        let markdown = DocumentRenderPipeline.orgToMarkdown("""
        #+begin_verse
        Line one
        Line two
        #+end_verse
        """)
        let parsed = parseCommonMark(markdown)
        guard case .paragraph(let inlines)? = parsed.first else {
            Issue.record("Expected a paragraph, got \(parsed)")
            return
        }
        #expect(inlines.contains(.hardBreak), "verse must keep a break between its lines, not join them with a space")
    }

    @Test func centerBlockIsParsedAsOrgProseNotRawText() {
        let blocks = parser.parse("""
        #+begin_center
        *Centered* text
        #+end_center
        """)
        #expect(blocks == [.paragraph([.bold([.text("Centered")]), .text(" text")])])
    }

    @Test func exportBlockShowsItsTargetAsALabelledBox() {
        let blocks = parser.parse("""
        #+begin_export html
        <b>raw html</b>
        #+end_export
        """)
        guard case let .codeBlock(language, code) = blocks[0] else {
            Issue.record("Expected a code block, got \(blocks[0])")
            return
        }
        #expect(language == "html")
        #expect(code == "<b>raw html</b>")
    }

    @Test func commentBlockIsHidden() {
        let blocks = parser.parse("""
        Before.
        #+begin_comment
        Hidden content.
        #+end_comment
        After.
        """)
        let markdown = DocumentRenderPipeline.orgToMarkdown("""
        Before.

        #+begin_comment
        Hidden content.
        #+end_comment

        After.
        """)
        #expect(blocks.contains { if case .comment = $0 { return true }; return false })
        #expect(!markdown.contains("Hidden content"), "a comment block must not reach the reading view")
    }

    @Test func unknownBlockNameRendersAsALabelledBoxNotRawText() {
        let blocks = parser.parse("""
        #+begin_mystery
        Unknown block content.
        #+end_mystery
        """)
        guard case let .codeBlock(language, code) = blocks[0] else {
            Issue.record("Expected a code block, got \(blocks[0])")
            return
        }
        #expect(language == "mystery")
        #expect(code == "Unknown block content.")
    }

    @Test func caseInsensitiveDelimitersStillMatch() {
        let blocks = parser.parse("""
        #+BEGIN_SRC swift
        let x = 1
        #+END_src
        """)
        #expect(blocks == [.codeBlock(language: "swift", code: "let x = 1")])
    }

    @Test func todoDeclarationQuotedInsideAnyBlockIsNotASetting() {
        let blocks = parser.parse("#+BEGIN_EXAMPLE\n#+TODO: A | B\n#+END_EXAMPLE\n* A x\n* TODO y")
        let keywords = blocks.compactMap { block -> String? in
            if case let .heading(_, keyword, _, _, _) = block { return keyword ?? "none" }
            return nil
        }
        #expect(keywords == ["none", "TODO"])
    }
}
