import Testing
@testable import Oppi

/// The owner's fifth approved fix: Org markup inside table cells.
@Suite("Org table cell markup")
struct OrgTableMarkupTests {
    let parser = OrgParser()

    @Test func tableCellsParseBoldItalicVerbatimCodeAndStrike() {
        let org = """
        | Col |
        |-----|
        | *bold* /italic/ =verbatim= ~code~ +strike+ |
        """
        guard case let .table(_, rows) = parser.parse(org)[0] else {
            Issue.record("Expected a table")
            return
        }
        #expect(rows[0][0] == [
            .bold([.text("bold")]), .text(" "),
            .italic([.text("italic")]), .text(" "),
            .verbatim("verbatim"), .text(" "),
            .code("code"), .text(" "),
            .strikethrough([.text("strike")]),
        ])
    }

    @Test func tableCellsParseLinks() {
        let org = """
        | Col |
        |-----|
        | [[https://example.com][site]] |
        """
        guard case let .table(_, rows) = parser.parse(org)[0] else {
            Issue.record("Expected a table")
            return
        }
        #expect(rows[0][0] == [.link(url: "https://example.com", description: [.text("site")])])
    }

    @Test func tableCellMarkupSurvivesTheMarkdownRoundTrip() {
        let markdown = DocumentRenderPipeline.orgToMarkdown("""
        | Col |
        |-----|
        | =verbatim= |
        """)
        let parsed = parseCommonMark(markdown)
        guard case .table(_, let rows)? = parsed.first else {
            Issue.record("Expected a table, got \(parsed)")
            return
        }
        #expect(rows[0][0].contains { if case .code("verbatim") = $0 { return true }; return false })
    }
}
