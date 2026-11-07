import Foundation
import Testing
@testable import Oppi

@Suite("Table text format")
struct TableTextFormatTests {
    @Test func tsvIsOneTabSeparatedLinePerRowWithTheHeaderFirst() {
        let text = TableTextFormat.tsv(
            headers: ["Name", "Role"],
            rows: [["Ada", "Engineer"], ["Grace", "Admiral"]]
        )
        #expect(text == "Name\tRole\nAda\tEngineer\nGrace\tAdmiral")
    }

    @Test func tsvCellsNeverBreakTheRowStructure() {
        let text = TableTextFormat.tsv(
            headers: ["Note", "Quote"],
            rows: [["line one\nline two\twith a tab", "\"quoted\" start"]]
        )
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2, "A newline inside a cell must not start a new row")
        #expect(lines[1].split(separator: "\t", omittingEmptySubsequences: false).count == 2)
        #expect(lines[1].hasPrefix("line one line two with a tab\t"))
    }

    @Test func tsvPadsShortRowsAndDropsExtraCells() {
        let text = TableTextFormat.tsv(
            headers: ["a", "b"],
            rows: [["1"], ["1", "2", "3"]]
        )
        #expect(text == "a\tb\n1\t\n1\t2")
    }

    @Test func tsvRoundTripsThroughTheDelimitedParser() {
        let headers = ["Name", "Note"]
        let rows = [
            ["Ada", "\"Analytical\" engines"],
            ["", "plain"],
            ["multi\nline", "tab\there"],
        ]
        let parsed = DelimitedTable.parse(
            TableTextFormat.tsv(headers: headers, rows: rows),
            separator: "\t"
        )
        #expect(parsed.headers == headers)
        #expect(parsed.rows == [
            ["Ada", "\"Analytical\" engines"],
            ["", "plain"],
            ["multi line", "tab here"],
        ])
    }

    @Test func oneColumnTableKeepsRowsWithEmptyCells() {
        let text = TableTextFormat.tsv(headers: ["Item"], rows: [["a"], [""], ["b"]])
        let parsed = DelimitedTable.parse(text, separator: "\t")
        #expect(parsed.rows == [["a"], [""], ["b"]], "An empty one-column row must not read as a blank line")
    }

    @Test func markdownEscapesPipesAndKeepsRowsOnOneLine() {
        let text = TableTextFormat.markdown(
            headers: ["Cmd", "Note"],
            rows: [["a | b", "two\nlines"]]
        )
        #expect(text == "| Cmd | Note |\n| --- | --- |\n| a \\| b | two lines |")
    }

    @Test func emptyTableIsEmptyText() {
        #expect(TableTextFormat.tsv(headers: [], rows: []).isEmpty)
        #expect(TableTextFormat.markdown(headers: [], rows: []).isEmpty)
    }
}
