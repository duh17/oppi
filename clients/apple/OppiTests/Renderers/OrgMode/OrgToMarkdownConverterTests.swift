import Testing
@testable import Oppi

// MARK: - Org → Markdown Conversion Tests

@Suite("Org to Markdown Conversion")
struct OrgToMarkdownConverterTests {
    let parser = OrgParser()

    // MARK: - Tables

    @Test func tableConvertsToMarkdownTable() {
        let org = """
        | Name  | Age |
        |-------+-----|
        | Alice | 30  |
        | Bob   | 25  |
        """
        let blocks = parser.parse(org)
        let mdBlocks = OrgToMarkdownConverter.convert(blocks)

        // Should produce exactly one table block
        #expect(mdBlocks.count == 1)
        guard case .table(let headers, let rows) = mdBlocks[0] else {
            Issue.record("Expected table block, got \(mdBlocks[0])")
            return
        }
        #expect(headers.count == 2)
        #expect(rows.count == 2)

        // Header content
        #expect(plainText(from: headers[0]) == "Name")
        #expect(plainText(from: headers[1]) == "Age")

        // Row content
        #expect(plainText(from: rows[0][0]) == "Alice")
        #expect(plainText(from: rows[0][1]) == "30")
        #expect(plainText(from: rows[1][0]) == "Bob")
        #expect(plainText(from: rows[1][1]) == "25")
    }

    @Test func tableSerializesToValidMarkdown() {
        let org = """
        | Phase   | Status      |
        |---------+-------------|
        | Parser  | Done        |
        | Folding | In Progress |
        """
        let blocks = parser.parse(org)
        let mdBlocks = OrgToMarkdownConverter.convert(blocks)
        let md = MarkdownBlockSerializer.serialize(mdBlocks)

        // Should contain markdown table syntax
        #expect(md.contains("| Phase"))
        #expect(md.contains("| ---"))
        #expect(md.contains("| Parser"))
        #expect(md.contains("In Progress"))
    }

    @Test func tableWithoutSeparatorTreatsFirstRowAsHeader() {
        let org = """
        | A | B |
        | 1 | 2 |
        """
        let blocks = parser.parse(org)
        guard case .table(let headers, let rows) = blocks[0] else {
            Issue.record("Expected table")
            return
        }
        #expect(headers.count == 2)
        #expect(rows.count == 1)
    }

    // MARK: - Keywords

    @Test func titleConvertsToHeading() {
        let blocks = parser.parse("#+TITLE: My Document")
        let mdBlocks = OrgToMarkdownConverter.convert(blocks)

        guard case .heading(let level, let inlines) = mdBlocks[0] else {
            Issue.record("Expected heading")
            return
        }
        #expect(level == 1)
        #expect(plainText(from: inlines) == "My Document")
    }

    @Test func startupKeywordIsSkipped() {
        let blocks = parser.parse("#+STARTUP: content")
        let mdBlocks = OrgToMarkdownConverter.convert(blocks)
        #expect(mdBlocks.isEmpty)
    }

    @Test func authorConvertsToEmphasis() {
        let blocks = parser.parse("#+AUTHOR: Test User")
        let mdBlocks = OrgToMarkdownConverter.convert(blocks)

        guard case .paragraph(let inlines) = mdBlocks[0] else {
            Issue.record("Expected paragraph")
            return
        }
        // Should be wrapped in emphasis
        guard case .emphasis = inlines[0] else {
            Issue.record("Expected emphasis, got \(inlines[0])")
            return
        }
    }

    // MARK: - Drawers

    @Test func drawerConvertsToCodeBlock() {
        let org = """
        :PROPERTIES:
        :ID: test-123
        :CREATED: 2024-01-01
        :END:
        """
        let blocks = parser.parse(org)
        let mdBlocks = OrgToMarkdownConverter.convert(blocks)

        guard case .codeBlock(let language, let code) = mdBlocks[0] else {
            Issue.record("Expected code block, got \(mdBlocks)")
            return
        }
        #expect(language == "properties")
        #expect(code.contains(":ID:"))
        #expect(code.contains("test-123"))
    }

    // MARK: - Headings

    @Test func headingWithTodoKeyword() {
        let blocks = parser.parse("* TODO Fix the bug")
        let mdBlocks = OrgToMarkdownConverter.convert(blocks)

        guard case .heading(_, let inlines) = mdBlocks[0] else {
            Issue.record("Expected heading")
            return
        }
        // First inline should be strong (TODO keyword)
        guard case .strong(let children) = inlines[0] else {
            Issue.record("Expected strong for TODO keyword")
            return
        }
        #expect(plainText(from: children) == "TODO")
    }

    @Test func headingWithTags() {
        let blocks = parser.parse("* My Heading   :tag1:tag2:")
        let mdBlocks = OrgToMarkdownConverter.convert(blocks)

        guard case .heading(_, let inlines) = mdBlocks[0] else {
            Issue.record("Expected heading")
            return
        }
        // Last inline should be code with tags
        guard case .code(let tagStr) = inlines.last else {
            Issue.record("Expected code for tags")
            return
        }
        #expect(tagStr.contains("tag1"))
        #expect(tagStr.contains("tag2"))
    }

    // MARK: - Folding

    @Test func buildSectionTreeGroupsByHeadingLevel() {
        let blocks = parser.parse("""
        * Section 1
        Body text
        ** Subsection 1.1
        Sub body
        * Section 2
        """)
        let (sections, _) = buildOrgSectionTree(blocks)

        #expect(sections.count == 2) // Two top-level sections
        #expect(sections[0].children.count == 1) // Section 1 has one child
        #expect(sections[1].children.count == 0)
    }

    @Test func startupOverviewSetsCorrectFoldState() {
        let blocks = parser.parse("#+STARTUP: overview\n* Heading")
        let (_, foldState) = buildOrgSectionTree(blocks)
        #expect(foldState == .overview)
    }

    @Test func startupContentSetsCorrectFoldState() {
        let blocks = parser.parse("#+STARTUP: content\n* Heading")
        let (_, foldState) = buildOrgSectionTree(blocks)
        #expect(foldState == .content)
    }

    @Test func startupNofoldSetsShowAll() {
        let blocks = parser.parse("#+STARTUP: nofold\n* Heading")
        let (_, foldState) = buildOrgSectionTree(blocks)
        #expect(foldState == .showAll)
    }

    @Test func zerothSectionCapturedBeforeFirstHeading() {
        let blocks = parser.parse("Some text before headings\n* First Heading")
        let (sections, _) = buildOrgSectionTree(blocks)

        #expect(sections.count == 2) // zeroth + heading
        #expect(sections[0].heading == nil) // zeroth has no heading
        #expect(!sections[0].bodyBlocks.isEmpty)
    }

    // MARK: - Coverage: conversion branches

    @Test func convertCoversListAndKeywordFallbackBranches() {
        let blocks: [OrgBlock] = [
            .list(kind: .unordered, items: [
                .init(bullet: "-", checkbox: nil, content: [.text("alpha")]),
            ]),
            .list(kind: .unordered, items: [
                .init(bullet: "-", checkbox: .checked, content: [.text("done")]),
                .init(bullet: "-", checkbox: .partial, content: [.text("partial")]),
            ]),
            .list(kind: .ordered, items: [
                .init(bullet: "1.", checkbox: nil, content: [.text("first")]),
                .init(bullet: "2.", checkbox: nil, content: [.text("second")]),
            ]),
            .keyword(key: "EMAIL", value: "dev@example.com"),
            .keyword(key: "FOO", value: "bar"),
            .drawer(name: "PROPERTIES", properties: []), // skipped when empty
            .comment("skip me"),
        ]

        let converted = OrgToMarkdownConverter.convert(blocks)
        #expect(converted.count == 5)

        guard case .unorderedList(let unorderedItems) = converted[0] else {
            Issue.record("Expected unordered list")
            return
        }
        #expect(unorderedItems.count == 1)

        guard case .taskList(let taskItems) = converted[1] else {
            Issue.record("Expected task list")
            return
        }
        #expect(taskItems.count == 2)
        #expect(taskItems[0].checked)
        #expect(!taskItems[1].checked)

        guard case .orderedList(let start, let orderedItems) = converted[2] else {
            Issue.record("Expected ordered list")
            return
        }
        #expect(start == 1)
        #expect(orderedItems.count == 2)

        guard case .paragraph(let emailInlines) = converted[3],
              case .emphasis = emailInlines.first else {
            Issue.record("Expected emphasized email metadata paragraph")
            return
        }

        guard case .paragraph(let keywordInlines) = converted[4],
              case .code(let keywordText) = keywordInlines.first else {
            Issue.record("Expected fallback keyword paragraph as code")
            return
        }
        #expect(keywordText == "#+FOO: bar")
    }

    @Test func serializeDirectlySkipsEmptyOrUnsupportedBlocks() {
        let markdown = OrgToMarkdownConverter.serializeDirectly([
            .paragraph([.text("Visible")]),
            .keyword(key: "OPTIONS", value: "toc:nil"), // skipped
            .table(headers: [], rows: []), // skipped by guard
            .drawer(name: "PROPERTIES", properties: [.init(key: "ID", value: "123")]), // skipped
            .comment("hidden"), // skipped
        ])

        #expect(markdown == "Visible")
    }

    @Test func serializeDirectlyIncludesNonEmptyTable() {
        let markdown = OrgToMarkdownConverter.serializeDirectly([
            .table(
                headers: [[.text("Name")], [.text("Score")]],
                rows: [
                    [[.text("Alice")], [.text("10")]],
                ]
            ),
        ])

        #expect(markdown.contains("| Name | Score |"))
        #expect(markdown.contains("| --- | --- |"))
        #expect(markdown.contains("| Alice | 10 |"))
    }

    @Test func serializeInlinesAndConvertSingleInlineHandleAllInlineKinds() {
        let inlines: [OrgInline] = [
            .text("plain"),
            .bold([.text("bold")]),
            .italic([.text("italic")]),
            .underline([.text("under")]),
            .verbatim("tick`value"),
            .code("code"),
            .strikethrough([.text("gone")]),
            .link(url: "https://example.com", description: [.text("site")]),
            .link(url: "https://oppi.dev", description: nil),
        ]

        let serialized = OrgToMarkdownConverter.serializeInlines(inlines)
        #expect(serialized.contains("plain"))
        #expect(serialized.contains("**bold**"))
        #expect(serialized.contains("*italic*"))
        #expect(serialized.contains("*under*"))
        #expect(serialized.contains("`` tick`value ``"))
        #expect(serialized.contains("`code`"))
        #expect(serialized.contains("~~gone~~"))
        #expect(serialized.contains("[site](https://example.com)"))

        let underline = OrgToMarkdownConverter.convertSingleInline(.underline([.text("u")]))
        #expect(underline == .emphasis([.text("u")]))

        let bareLink = OrgToMarkdownConverter.convertSingleInline(
            .link(url: "https://example.com", description: nil)
        )
        #expect(bareLink == .link(children: [.text("https://example.com")], destination: "https://example.com"))
    }
}
