import Testing
@testable import Oppi

// MARK: - Spec Coverage
//
// org-syntax coverage:
// [x] §2.2 Headlines — level, keyword, priority, title, tags
// [x] §3.1 Paragraphs — single line, multi-line, adjacent
// [x] §3.3 Greater blocks — quote blocks (recursive)
// [x] §3.4 Blocks — source blocks with language
// [x] §3.5 Plain lists — unordered (-, +), ordered (1., 1)), checkboxes
// [x] §3.6 Keywords — #+KEY: value
// [x] §3.7 Comments — # lines
// [x] §3.8 Horizontal rules — 5+ dashes
// [x] §4.2 Text markup — bold, italic, underline, verbatim, code, strikethrough
// [x] §4.2 Nested markup — bold inside italic, etc.
// [x] §4.4 Links — with/without description
// [x] Edge cases — empty input, mixed elements, consecutive blanks

@Suite("OrgParser Conformance")
struct OrgParserConformanceTests {

    let parser = OrgParser()

    // MARK: - Headlines (§2.2)

    @Test("Simple heading level 1")
    func headingLevel1() {
        let result = parser.parse("* Hello")
        #expect(result == [
            .heading(level: 1, keyword: nil, priority: nil, title: [.text("Hello")], tags: []),
        ])
    }

    @Test("Heading levels 1-4")
    func headingLevels() {
        let input = """
        * Level 1
        ** Level 2
        *** Level 3
        **** Level 4
        """
        let result = parser.parse(input)
        #expect(result.count == 4)
        if case let .heading(level, _, _, _, _) = result[0] { #expect(level == 1) }
        if case let .heading(level, _, _, _, _) = result[1] { #expect(level == 2) }
        if case let .heading(level, _, _, _, _) = result[2] { #expect(level == 3) }
        if case let .heading(level, _, _, _, _) = result[3] { #expect(level == 4) }
    }

    @Test("Heading with TODO keyword")
    func headingWithTodo() {
        let result = parser.parse("* TODO Buy groceries")
        #expect(result == [
            .heading(level: 1, keyword: "TODO", priority: nil, title: [.text("Buy groceries")], tags: []),
        ])
    }

    @Test("Heading with DONE keyword")
    func headingWithDone() {
        let result = parser.parse("** DONE Ship feature")
        #expect(result == [
            .heading(level: 2, keyword: "DONE", priority: nil, title: [.text("Ship feature")], tags: []),
        ])
    }

    @Test("Heading with priority")
    func headingWithPriority() {
        let result = parser.parse("* TODO [#A] Urgent task")
        #expect(result == [
            .heading(level: 1, keyword: "TODO", priority: "A", title: [.text("Urgent task")], tags: []),
        ])
    }

    @Test("Heading with tags")
    func headingWithTags() {
        let result = parser.parse("* Project meeting :work:planning:")
        #expect(result == [
            .heading(level: 1, keyword: nil, priority: nil, title: [.text("Project meeting")], tags: ["work", "planning"]),
        ])
    }

    @Test("Heading with keyword, priority, and tags")
    func headingFull() {
        let result = parser.parse("** TODO [#B] Review PR :code:review:")
        #expect(result == [
            .heading(level: 2, keyword: "TODO", priority: "B", title: [.text("Review PR")], tags: ["code", "review"]),
        ])
    }

    @Test("Heading with single tag")
    func headingSingleTag() {
        let result = parser.parse("* Task :urgent:")
        #expect(result == [
            .heading(level: 1, keyword: nil, priority: nil, title: [.text("Task")], tags: ["urgent"]),
        ])
    }

    @Test("Stars without trailing space are not headings")
    func starsNoSpace() {
        let result = parser.parse("**not a heading")
        #expect(result.count == 1)
        if case .paragraph = result[0] { } else {
            Issue.record("Expected paragraph, got \(result[0])")
        }
    }

    @Test("Heading with empty title")
    func headingEmptyTitle() {
        let result = parser.parse("* ")
        #expect(result == [
            .heading(level: 1, keyword: nil, priority: nil, title: [], tags: []),
        ])
    }

    @Test("Heading with inline markup in title")
    func headingInlineMarkup() {
        let result = parser.parse("* This is *important*")
        #expect(result == [
            .heading(level: 1, keyword: nil, priority: nil, title: [
                .text("This is "),
                .bold([.text("important")]),
            ], tags: []),
        ])
    }

    // MARK: - Paragraphs (§3.1)

    @Test("Simple paragraph")
    func simpleParagraph() {
        let result = parser.parse("Hello, world!")
        #expect(result == [.paragraph([.text("Hello, world!")])])
    }

    @Test("Multi-line paragraph joined with spaces")
    func multiLineParagraph() {
        let input = """
        First line
        second line
        third line
        """
        let result = parser.parse(input)
        #expect(result == [.paragraph([.text("First line second line third line")])])
    }

    @Test("Two paragraphs separated by blank line")
    func twoParagraphs() {
        let input = """
        First paragraph.

        Second paragraph.
        """
        let result = parser.parse(input)
        #expect(result == [
            .paragraph([.text("First paragraph.")]),
            .paragraph([.text("Second paragraph.")]),
        ])
    }

    @Test("Paragraph with inline bold")
    func paragraphBold() {
        let result = parser.parse("This is *bold* text")
        #expect(result == [
            .paragraph([
                .text("This is "),
                .bold([.text("bold")]),
                .text(" text"),
            ]),
        ])
    }

    @Test("Paragraph with inline italic")
    func paragraphItalic() {
        let result = parser.parse("This is /italic/ text")
        #expect(result == [
            .paragraph([
                .text("This is "),
                .italic([.text("italic")]),
                .text(" text"),
            ]),
        ])
    }

    @Test("Paragraph with inline underline")
    func paragraphUnderline() {
        let result = parser.parse("This is _underlined_ text")
        #expect(result == [
            .paragraph([
                .text("This is "),
                .underline([.text("underlined")]),
                .text(" text"),
            ]),
        ])
    }

    @Test("Paragraph with inline verbatim")
    func paragraphVerbatim() {
        let result = parser.parse("This is =verbatim= text")
        #expect(result == [
            .paragraph([
                .text("This is "),
                .verbatim("verbatim"),
                .text(" text"),
            ]),
        ])
    }

    @Test("Paragraph with inline code")
    func paragraphCode() {
        let result = parser.parse("Use ~println~ for output")
        #expect(result == [
            .paragraph([
                .text("Use "),
                .code("println"),
                .text(" for output"),
            ]),
        ])
    }

    @Test("Paragraph with strikethrough")
    func paragraphStrikethrough() {
        let result = parser.parse("This is +deleted+ text")
        #expect(result == [
            .paragraph([
                .text("This is "),
                .strikethrough([.text("deleted")]),
                .text(" text"),
            ]),
        ])
    }

    // MARK: - Nested Inline Markup (§4.2)

    @Test("Bold inside italic")
    func boldInsideItalic() {
        let result = parser.parse("/*bold and italic*/")
        #expect(result == [
            .paragraph([
                .italic([.bold([.text("bold and italic")])]),
            ]),
        ])
    }

    @Test("Multiple markup types in one paragraph")
    func multipleMarkup() {
        let result = parser.parse("*bold* and /italic/ and =verbatim=")
        #expect(result == [
            .paragraph([
                .bold([.text("bold")]),
                .text(" and "),
                .italic([.text("italic")]),
                .text(" and "),
                .verbatim("verbatim"),
            ]),
        ])
    }

    // MARK: - Links (§4.4)

    @Test("Link with description")
    func linkWithDescription() {
        let result = parser.parse("Visit [[https://example.com][Example]] today")
        #expect(result == [
            .paragraph([
                .text("Visit "),
                .link(url: "https://example.com", description: [.text("Example")]),
                .text(" today"),
            ]),
        ])
    }

    @Test("Link without description")
    func linkWithoutDescription() {
        let result = parser.parse("See [[https://example.com]]")
        #expect(result == [
            .paragraph([
                .text("See "),
                .link(url: "https://example.com", description: nil),
            ]),
        ])
    }

    @Test("Link with markup in description")
    func linkMarkupDescription() {
        let result = parser.parse("[[https://example.com][*Bold* link]]")
        #expect(result == [
            .paragraph([
                .link(url: "https://example.com", description: [
                    .bold([.text("Bold")]),
                    .text(" link"),
                ]),
            ]),
        ])
    }

    // MARK: - Lists (§3.5)

    @Test("Unordered list with dash")
    func unorderedListDash() {
        let input = """
        - Item one
        - Item two
        - Item three
        """
        let result = parser.parse(input)
        #expect(result == [
            .list(kind: .unordered, items: [
                OrgListItem(bullet: "-", checkbox: nil, content: [.text("Item one")]),
                OrgListItem(bullet: "-", checkbox: nil, content: [.text("Item two")]),
                OrgListItem(bullet: "-", checkbox: nil, content: [.text("Item three")]),
            ]),
        ])
    }

    @Test("Unordered list with plus")
    func unorderedListPlus() {
        let input = """
        + Alpha
        + Beta
        """
        let result = parser.parse(input)
        #expect(result == [
            .list(kind: .unordered, items: [
                OrgListItem(bullet: "+", checkbox: nil, content: [.text("Alpha")]),
                OrgListItem(bullet: "+", checkbox: nil, content: [.text("Beta")]),
            ]),
        ])
    }

    @Test("Ordered list with period")
    func orderedListPeriod() {
        let input = """
        1. First
        2. Second
        3. Third
        """
        let result = parser.parse(input)
        #expect(result == [
            .list(kind: .ordered, items: [
                OrgListItem(bullet: "1.", checkbox: nil, content: [.text("First")]),
                OrgListItem(bullet: "2.", checkbox: nil, content: [.text("Second")]),
                OrgListItem(bullet: "3.", checkbox: nil, content: [.text("Third")]),
            ]),
        ])
    }

    @Test("Ordered list with paren")
    func orderedListParen() {
        let input = """
        1) First
        2) Second
        """
        let result = parser.parse(input)
        #expect(result == [
            .list(kind: .ordered, items: [
                OrgListItem(bullet: "1)", checkbox: nil, content: [.text("First")]),
                OrgListItem(bullet: "2)", checkbox: nil, content: [.text("Second")]),
            ]),
        ])
    }

    @Test("List with checkboxes")
    func listCheckboxes() {
        let input = """
        - [X] Done task
        - [ ] Pending task
        - [-] Partial task
        """
        let result = parser.parse(input)
        #expect(result == [
            .list(kind: .unordered, items: [
                OrgListItem(bullet: "-", checkbox: .checked, content: [.text("Done task")]),
                OrgListItem(bullet: "-", checkbox: .unchecked, content: [.text("Pending task")]),
                OrgListItem(bullet: "-", checkbox: .partial, content: [.text("Partial task")]),
            ]),
        ])
    }

    @Test("List with inline markup")
    func listInlineMarkup() {
        let input = """
        - *Bold* item
        - Item with =code=
        """
        let result = parser.parse(input)
        #expect(result == [
            .list(kind: .unordered, items: [
                OrgListItem(bullet: "-", checkbox: nil, content: [.bold([.text("Bold")]), .text(" item")]),
                OrgListItem(bullet: "-", checkbox: nil, content: [.text("Item with "), .verbatim("code")]),
            ]),
        ])
    }

    // MARK: - Code Blocks (§3.4)

    @Test("Source block with language")
    func codeBlockWithLang() {
        let input = """
        #+begin_src python
        def hello():
            print("world")
        #+end_src
        """
        let result = parser.parse(input)
        #expect(result == [
            .codeBlock(language: "python", code: "def hello():\n    print(\"world\")"),
        ])
    }

    @Test("Source block without language")
    func codeBlockNoLang() {
        let input = """
        #+begin_src
        some code
        #+end_src
        """
        let result = parser.parse(input)
        #expect(result == [
            .codeBlock(language: nil, code: "some code"),
        ])
    }

    @Test("Source block case insensitive delimiters")
    func codeBlockCaseInsensitive() {
        let input = """
        #+BEGIN_SRC swift
        let x = 42
        #+END_SRC
        """
        let result = parser.parse(input)
        #expect(result == [
            .codeBlock(language: "swift", code: "let x = 42"),
        ])
    }

    @Test("Source block preserves blank lines in code")
    func codeBlockBlankLines() {
        let input = """
        #+begin_src
        line 1

        line 3
        #+end_src
        """
        let result = parser.parse(input)
        #expect(result == [
            .codeBlock(language: nil, code: "line 1\n\nline 3"),
        ])
    }

    // MARK: - Quote Blocks (§3.3)

    @Test("Simple quote block")
    func quoteBlock() {
        let input = """
        #+begin_quote
        To be or not to be.
        #+end_quote
        """
        let result = parser.parse(input)
        #expect(result == [
            .quote([.paragraph([.text("To be or not to be.")])]),
        ])
    }

    @Test("Quote block with multiple paragraphs")
    func quoteBlockMultiPara() {
        let input = """
        #+begin_quote
        First paragraph.

        Second paragraph.
        #+end_quote
        """
        let result = parser.parse(input)
        #expect(result == [
            .quote([
                .paragraph([.text("First paragraph.")]),
                .paragraph([.text("Second paragraph.")]),
            ]),
        ])
    }

    @Test("Quote block case insensitive")
    func quoteBlockCaseInsensitive() {
        let input = """
        #+BEGIN_QUOTE
        Quoted text.
        #+END_QUOTE
        """
        let result = parser.parse(input)
        #expect(result == [
            .quote([.paragraph([.text("Quoted text.")])]),
        ])
    }

    // MARK: - Keywords (§3.6)

    @Test("Title keyword")
    func keywordTitle() {
        let result = parser.parse("#+TITLE: My Document")
        #expect(result == [.keyword(key: "TITLE", value: "My Document")])
    }

    @Test("Author keyword")
    func keywordAuthor() {
        let result = parser.parse("#+AUTHOR: Alice")
        #expect(result == [.keyword(key: "AUTHOR", value: "Alice")])
    }

    @Test("Keyword case insensitive")
    func keywordCaseInsensitive() {
        let result = parser.parse("#+title: lower case")
        #expect(result == [.keyword(key: "TITLE", value: "lower case")])
    }

    @Test("Keyword with empty value")
    func keywordEmptyValue() {
        let result = parser.parse("#+OPTIONS:")
        #expect(result == [.keyword(key: "OPTIONS", value: "")])
    }

    // MARK: - Horizontal Rules (§3.8)

    @Test("Standard horizontal rule (5 dashes)")
    func horizontalRule5() {
        let result = parser.parse("-----")
        #expect(result == [.horizontalRule])
    }

    @Test("Long horizontal rule")
    func horizontalRuleLong() {
        let result = parser.parse("----------")
        #expect(result == [.horizontalRule])
    }

    @Test("Four dashes is not a rule")
    func fourDashesNotRule() {
        let result = parser.parse("----")
        // Should be a paragraph, not a horizontal rule
        if case .paragraph = result[0] { } else {
            Issue.record("Expected paragraph for 4 dashes, got \(result[0])")
        }
    }

    // MARK: - Comments (§3.7)

    @Test("Simple comment")
    func simpleComment() {
        let result = parser.parse("# This is a comment")
        #expect(result == [.comment("This is a comment")])
    }

    @Test("Empty comment")
    func emptyComment() {
        let result = parser.parse("#")
        #expect(result == [.comment("")])
    }

    // MARK: - Empty Input

    @Test("Empty string")
    func emptyInput() {
        let result = parser.parse("")
        #expect(result == [])
    }

    @Test("Only whitespace")
    func whitespaceOnly() {
        let result = parser.parse("   \n  \n   ")
        #expect(result == [])
    }

    // MARK: - Mixed Document

    @Test("Full document with mixed elements")
    func fullDocument() {
        let input = """
        #+TITLE: Test Document
        #+AUTHOR: Test

        * Introduction

        This is the first paragraph with *bold* text.

        ** Details :info:

        - Item one
        - Item two

        #+begin_src python
        print("hello")
        #+end_src

        -----

        #+begin_quote
        A wise quote.
        #+end_quote
        """
        let result = parser.parse(input)
        #expect(result.count == 9)

        // Verify element types in order
        if case .keyword(let key, _) = result[0] { #expect(key == "TITLE") }
        if case .keyword(let key, _) = result[1] { #expect(key == "AUTHOR") }
        if case .heading(let level, _, _, _, _) = result[2] { #expect(level == 1) }
        if case .paragraph = result[3] { } else { Issue.record("Expected paragraph at index 3") }
        if case .heading(let level, _, _, _, let tags) = result[4] {
            #expect(level == 2)
            #expect(tags == ["info"])
        }
        if case .list(let kind, let items) = result[5] {
            #expect(kind == .unordered)
            #expect(items.count == 2)
        }
        if case .codeBlock(let lang, _) = result[6] { #expect(lang == "python") }
        if case .horizontalRule = result[7] { } else { Issue.record("Expected rule at index 7") }
        if case .quote = result[8] { } else { Issue.record("Expected quote at index 8") }
    }

    // MARK: - Consecutive Elements

    @Test("Heading immediately followed by paragraph")
    func headingThenParagraph() {
        let input = """
        * Heading
        Some text below.
        """
        let result = parser.parse(input)
        #expect(result.count == 2)
        if case .heading = result[0] { } else { Issue.record("Expected heading") }
        if case .paragraph = result[1] { } else { Issue.record("Expected paragraph") }
    }

    @Test("Two lists separated by blank line")
    func twoLists() {
        let input = """
        - A
        - B

        1. One
        2. Two
        """
        let result = parser.parse(input)
        #expect(result.count == 2)
        if case .list(let kind, _) = result[0] { #expect(kind == .unordered) }
        if case .list(let kind, _) = result[1] { #expect(kind == .ordered) }
    }

    @Test("Paragraph ends at structural line")
    func paragraphEndsAtStructure() {
        let input = """
        Some text here.
        * A heading
        """
        let result = parser.parse(input)
        #expect(result.count == 2)
        if case .paragraph = result[0] { } else { Issue.record("Expected paragraph") }
        if case .heading = result[1] { } else { Issue.record("Expected heading") }
    }

    // MARK: - Inline Edge Cases

    @Test("Markup at start of text")
    func markupAtStart() {
        let result = parser.parse("*bold* at start")
        #expect(result == [
            .paragraph([
                .bold([.text("bold")]),
                .text(" at start"),
            ]),
        ])
    }

    @Test("Markup at end of text")
    func markupAtEnd() {
        let result = parser.parse("end with *bold*")
        #expect(result == [
            .paragraph([
                .text("end with "),
                .bold([.text("bold")]),
            ]),
        ])
    }

    @Test("Markup spanning entire text")
    func markupEntireText() {
        let result = parser.parse("*all bold*")
        #expect(result == [
            .paragraph([.bold([.text("all bold")])]),
        ])
    }

    @Test("Unmatched marker treated as text")
    func unmatchedMarker() {
        let result = parser.parse("5 * 3 = 15")
        // The `*` should not create markup since spacing rules prevent it
        if case let .paragraph(inlines) = result[0] {
            // Should contain text (possibly fragmented, but no bold)
            let hasBold = inlines.contains(where: { if case .bold = $0 { return true }; return false })
            #expect(!hasBold, "Should not parse * as bold in arithmetic context")
        }
    }

    @Test("Adjacent different markup types")
    func adjacentMarkup() {
        let result = parser.parse("*bold*/italic/")
        // After *bold* closes, /italic/ should not open because `*` is not a valid pre char for `/`
        // This is an edge case — the result depends on pre/post rules
        if case .paragraph = result[0] { } else {
            Issue.record("Expected paragraph")
        }
    }
}
