import Foundation
import Testing
@testable import Oppi

@Suite("Mac CSV/TSV table viewer")
struct MacDelimitedTablePreviewTests {
    @Test func csvAndTsvFilesOpenATablePlanInsteadOfPlainText() throws {
        let csv = try #require("name,watts\nEasy,150\n".data(using: .utf8))
        let tsv = try #require("name\twatts\nEasy\t150\n".data(using: .utf8))

        guard case .file(let csvFile) = FileViewerDescriptorBuilder.descriptor(
            path: "rides.csv",
            data: csv
        ) else {
            Issue.record("Expected CSV to stay a file descriptor")
            return
        }
        guard case .file(let tsvFile) = FileViewerDescriptorBuilder.descriptor(
            path: "rides.tsv",
            data: tsv
        ) else {
            Issue.record("Expected TSV to stay a file descriptor")
            return
        }

        #expect(csvFile.fileType == .csv)
        #expect(tsvFile.fileType == .tsv)
        #expect(csvFile.text == "name,watts\nEasy,150\n")
        #expect(tsvFile.text == "name\twatts\nEasy\t150\n")
        #expect(MacToolDocumentColumnPaint.fileUsesTablePreview(csvFile))
        #expect(MacToolDocumentColumnPaint.fileUsesTablePreview(tsvFile))
        #expect(DelimitedTableViewerPlan.opening(path: "rides.csv", text: csvFile.text) != nil)
        #expect(DelimitedTableViewerPlan.opening(path: "rides.tsv", text: tsvFile.text) != nil)
    }

    @Test func markdownAndPlainFilesDoNotUseTheTablePlan() throws {
        let markdown = try #require("# Title\n".data(using: .utf8))
        guard case .file(let file) = FileViewerDescriptorBuilder.descriptor(
            path: "README.md",
            data: markdown
        ) else {
            Issue.record("Expected markdown to stay a file descriptor")
            return
        }

        #expect(!MacToolDocumentColumnPaint.fileUsesTablePreview(file))
        #expect(DelimitedTableViewerPlan.opening(path: "README.md", text: file.text) == nil)
        #expect(DelimitedTableViewerPlan.opening(path: "notes.txt", text: "a,b\n1,2\n") == nil)
    }

    @Test func documentColumnExposesTableAndSourceNotASheet() throws {
        let column = try source(named: "OppiMac/Views/MacToolDocumentColumn.swift")
        let preview = try source(named: "OppiMac/Views/MacDelimitedTablePreview.swift")

        #expect(column.contains("fileUsesTablePreview"))
        #expect(column.contains("MacDelimitedTablePreviewView"))
        #expect(preview.contains("Text(\"Table\")"))
        #expect(preview.contains("Text(\"Source\")"))
        #expect(preview.contains("Picker"))
        #expect(preview.contains("plan.source"))
        #expect(!preview.contains("fullScreenCover"))
        #expect(!preview.contains(".sheet("))
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
