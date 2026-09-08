import Foundation
import Testing
@testable import Oppi

@Suite("Delimited table parser")
struct DelimitedTableTests {
    @Test func csvSplitsOnCommasAndUsesFirstRowAsHeaders() {
        let table = DelimitedTable.parse(
            "name,watts,seconds\nEasy,150,1800\nThreshold,250,1200\n",
            separator: ","
        )

        #expect(table.headers == ["name", "watts", "seconds"])
        #expect(table.rows == [
            ["Easy", "150", "1800"],
            ["Threshold", "250", "1200"],
        ])
        #expect(table.columnCount == 3)
        #expect(table.totalRowCount == 3)
        #expect(!table.truncatedRows)
        #expect(!table.truncatedColumns)
        #expect(!table.truncatedCells)
    }

    @Test func tsvSplitsOnTabsNotCommas() {
        let table = DelimitedTable.parse(
            "city\tlat,long\nSeattle\t47.6,-122.3\n",
            separator: "\t"
        )

        #expect(table.headers == ["city", "lat,long"])
        #expect(table.rows == [["Seattle", "47.6,-122.3"]])
    }

    @Test func quotedCommaStaysOneCell() {
        let table = DelimitedTable.parse(
            "name,note\n\"Chen, Da\",\"hello, world\"\n",
            separator: ","
        )

        #expect(table.headers == ["name", "note"])
        #expect(table.rows == [["Chen, Da", "hello, world"]])
    }

    @Test func doubledQuotesUnescapeInsideQuotedFields() {
        let table = DelimitedTable.parse(
            "title\n\"He said \"\"go\"\"\"\n",
            separator: ","
        )

        #expect(table.rows == [["He said \"go\""]])
    }

    @Test func quotedNewlineStaysOneCell() {
        let table = DelimitedTable.parse(
            "name,note\nAda,\"line 1\nline 2\"\n",
            separator: ","
        )

        #expect(table.rows == [["Ada", "line 1\nline 2"]])
        #expect(table.totalRowCount == 2)
    }

    @Test func crlfDoesNotCreateEmptyTrailingRow() {
        let table = DelimitedTable.parse("a,b\r\n1,2\r\n", separator: ",")

        #expect(table.headers == ["a", "b"])
        #expect(table.rows == [["1", "2"]])
        #expect(table.totalRowCount == 2)
    }

    @Test func emptyFieldsArePreserved() {
        let table = DelimitedTable.parse("a,b,c\n,2,\n", separator: ",")

        #expect(table.rows == [["", "2", ""]])
    }

    @Test func formulaTextStaysLiteral() {
        let table = DelimitedTable.parse(
            "value\n=SUM(A1:A2)\n=1+1\n",
            separator: ","
        )

        #expect(table.rows == [["=SUM(A1:A2)"], ["=1+1"]])
    }

    @Test func semicolonIsNotACsvSeparator() {
        let table = DelimitedTable.parse("a;b,c\n1;2,3\n", separator: ",")

        #expect(table.headers == ["a;b", "c"])
        #expect(table.rows == [["1;2", "3"]])
    }

    @Test func boundsTruncateRowsColumnsAndCells() {
        let limits = DelimitedTable.Limits(maxRows: 3, maxColumns: 2, maxCellCharacters: 4)
        let table = DelimitedTable.parse(
            "h1,h2,h3\none,two,three\nfour,five,six\nseven,eight,nine\n",
            separator: ",",
            limits: limits
        )

        #expect(table.headers == ["h1", "h2"])
        #expect(table.rows == [
            ["one", "two"],
            ["four", "five"],
        ])
        #expect(table.columnCount == 2)
        #expect(table.totalRowCount == 4)
        #expect(table.totalColumnCount == 3)
        #expect(table.truncatedRows)
        #expect(table.truncatedColumns)
        #expect(!table.truncatedCells)

        let clipped = DelimitedTable.parse(
            "name\nverylong\n",
            separator: ",",
            limits: limits
        )
        #expect(clipped.rows == [["very"]])
        #expect(clipped.truncatedCells)
    }

    @Test func utf8BomIsIgnoredForCells() {
        let table = DelimitedTable.parse("\u{FEFF}name,watts\nEasy,150\n", separator: ",")

        #expect(table.headers == ["name", "watts"])
        #expect(table.rows == [["Easy", "150"]])
    }
}

@Suite("Delimited table viewer plan")
struct DelimitedTableViewerPlanTests {
    @Test func csvAndTsvOpenATablePlanInsteadOfPlainText() throws {
        let csv = "name,watts\nEasy,150\n"
        let tsv = "name\twatts\nEasy\t150\n"

        let csvPlan = try #require(DelimitedTableViewerPlan.opening(path: "rides.csv", text: csv))
        let tsvPlan = try #require(DelimitedTableViewerPlan.opening(path: "rides.tsv", text: tsv))

        #expect(csvPlan.kind == .csv)
        #expect(tsvPlan.kind == .tsv)
        #expect(csvPlan.table.headers == ["name", "watts"])
        #expect(tsvPlan.table.rows == [["Easy", "150"]])
        #expect(FileType.detect(from: "rides.csv") == .csv)
        #expect(FileType.detect(from: "rides.tsv") == .tsv)
        #expect(FileType.detect(from: "rides.csv") != .plain)
        #expect(FileType.detect(from: "notes.txt") == .plain)
        #expect(DelimitedTableViewerPlan.opening(path: "notes.txt", text: csv) == nil)
        #expect(DelimitedTableViewerPlan.opening(path: "sheet.xlsx", text: csv) == nil)
    }

    @Test func sourceModeKeepsOriginalBytesIncludingBomAndTrailingNewline() throws {
        let original = "\u{FEFF}name,note\n\"a,b\",\n"
        let plan = try #require(DelimitedTableViewerPlan.opening(path: "export.csv", text: original))

        #expect(plan.source == original)
        #expect(plan.source != plan.table.headers.joined(separator: ","))
        #expect(plan.table.headers == ["name", "note"])
        #expect(plan.table.rows == [["a,b", ""]])
    }

    @Test func fileDescriptorKeepsCsvTypeAndOriginalText() throws {
        let original = "col\n=SUM(1,2)\n"
        let data = try #require(original.data(using: .utf8))

        guard case .file(let file) = FileViewerDescriptorBuilder.descriptor(
            path: "metrics.csv",
            data: data
        ) else {
            Issue.record("Expected a file descriptor for CSV")
            return
        }

        #expect(file.fileType == .csv)
        #expect(file.text == original)
        #expect(file.language == nil)
        #expect(DelimitedTableViewerPlan.opening(path: file.filePath ?? "", text: file.text) != nil)
    }

    @Test func fileDescriptorKeepsTsvTypeAndOriginalText() throws {
        let original = "a\tb\n1\t2\n"
        let data = try #require(original.data(using: .utf8))

        guard case .file(let file) = FileViewerDescriptorBuilder.descriptor(
            path: "metrics.tsv",
            data: data
        ) else {
            Issue.record("Expected a file descriptor for TSV")
            return
        }

        #expect(file.fileType == .tsv)
        #expect(file.text == original)
        #expect(DelimitedTableViewerPlan.opening(path: file.filePath ?? "", text: file.text)?.kind == .tsv)
    }

    @Test func fullScreenContentRoutesCsvAndTsvToTheTableViewer() {
        let csv = FullScreenCodeContent.fromText("a,b\n1,2\n", filePath: "export.csv")
        let tsv = FullScreenCodeContent.fromText("a\tb\n1\t2\n", filePath: "export.tsv")
        let txt = FullScreenCodeContent.fromText("hello\n", filePath: "notes.txt")

        guard case .delimitedTable(let csvText, let csvPath) = csv else {
            Issue.record("CSV still has no table plan, got \(csv)")
            return
        }
        guard case .delimitedTable(let tsvText, let tsvPath) = tsv else {
            Issue.record("TSV still has no table plan, got \(tsv)")
            return
        }

        #expect(csvText == "a,b\n1,2\n")
        #expect(csvPath == "export.csv")
        #expect(tsvText == "a\tb\n1\t2\n")
        #expect(tsvPath == "export.tsv")
        guard case .plainText = txt else {
            Issue.record("Plain text should stay a source viewer, got \(txt)")
            return
        }
    }
}
