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
        let blocks = parser.parse("#+AUTHOR: Chen")
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
}
