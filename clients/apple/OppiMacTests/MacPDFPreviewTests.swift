import Foundation
import PDFKit
import Testing
@testable import Oppi

@Suite("Mac PDF document column preview")
struct MacPDFPreviewTests {
    @Test func fileViewerPlanPDFBecomesAFileDescriptorNotAPlaceholder() throws {
        let data = try samplePDFData()
        let descriptor = FileViewerDescriptorBuilder.descriptor(path: "docs/report.pdf", data: data)

        guard case .file(let file) = descriptor else {
            Issue.record("Expected PDF to open as a file descriptor, got \(descriptor)")
            return
        }

        #expect(file.fileType == .pdf)
        #expect(file.filePath == "docs/report.pdf")
        #expect(FileViewerDescriptorBuilder.needsFileBytes(path: "docs/report.pdf"))
        #expect(MacPDFPreviewData.data(from: file) == data)
        #expect(MacToolDocumentColumnPaint.fileUsesPDFPreview(file))
        #expect(MacToolDocumentColumnPaint.surface(for: descriptor) == .file)
        #expect(MacToolDocumentColumnPaint.surface(for: descriptor) != .status)
    }

    @MainActor
    @Test func toolReadOfPDFUsesPDFPreviewInTheDocumentColumn() {
        let items: [ChatItem] = [
            .toolCall(
                id: "tool-pdf",
                tool: "read",
                argsSummary: "path: docs/report.pdf",
                outputPreview: "Binary file cannot be displayed as text.",
                outputByteCount: 40,
                isError: false,
                isDone: true
            ),
        ]
        let outputs = ToolOutputStore()
        outputs.replace("Binary file cannot be displayed as text.", for: "tool-pdf", previewOnly: false)
        let args = ToolArgsStore()
        args.set(["path": .string("docs/report.pdf")], for: "tool-pdf")

        let model = MacToolDocumentColumnModel.make(
            toolRowID: "tool-pdf",
            items: items,
            toolOutputStore: outputs,
            toolArgsStore: args,
            toolDetailsStore: ToolDetailsStore()
        )
        guard case .file(let file) = model?.presentation.content else {
            Issue.record("Expected tool PDF to be a file descriptor, got \(String(describing: model?.presentation.content))")
            return
        }

        #expect(file.fileType == .pdf)
        #expect(file.filePath == "docs/report.pdf")
        #expect(MacToolDocumentColumnPaint.fileUsesPDFPreview(file))
        #expect(MacPDFPreviewData.data(from: file) == nil)
    }

    @Test func toolPDFFileDescriptorPaintsPDFKitFromInlineBytes() throws {
        let data = try samplePDFData()
        let file = ToolContentDescriptor.File(
            text: data.base64EncodedString(),
            filePath: "docs/report.pdf",
            fileType: .pdf,
            language: nil,
            startLine: 1,
            attachments: []
        )

        #expect(MacToolDocumentColumnPaint.fileUsesPDFPreview(file))
        #expect(MacPDFPreviewData.data(from: file) == data)
        #expect(PDFDocument(data: data)?.pageCount ?? 0 >= 1)
    }

    @Test func toolPDFPathWithoutInlineBytesStillUsesPDFPreview() {
        let file = ToolContentDescriptor.File(
            text: "Binary file cannot be displayed as text.",
            filePath: "docs/report.pdf",
            fileType: .pdf,
            language: nil,
            startLine: 1,
            attachments: []
        )

        #expect(MacToolDocumentColumnPaint.fileUsesPDFPreview(file))
        #expect(MacPDFPreviewData.data(from: file) == nil)
    }

    @Test func invalidPDFBytesDoNotDecodeAsADocument() {
        let file = ToolContentDescriptor.File(
            text: Data("not a pdf".utf8).base64EncodedString(),
            filePath: "docs/report.pdf",
            fileType: .pdf,
            language: nil,
            startLine: 1,
            attachments: []
        )

        #expect(MacPDFPreviewData.data(from: file) == nil)
        #expect(MacPDFPreviewData.data(from: "") == nil)
        #expect(MacPDFPreviewData.data(from: "hello") == nil)
    }

    @Test func dataURIPayloadDecodesToPDFBytes() throws {
        let data = try samplePDFData()
        let text = "data:application/pdf;base64,\(data.base64EncodedString())"

        #expect(MacPDFPreviewData.data(from: text) == data)
    }

    @Test func loadDropsStaleWorkspaceWriteAfterAwait() throws {
        let preview = try source(named: "OppiMac/Views/MacPDFPreview.swift")
        guard let loadStart = preview.range(of: "private func load() async {") else {
            Issue.record("Expected MacToolDocumentPDFView.load()")
            return
        }
        let afterLoad = preview[loadStart.lowerBound...]
        let loadEnd = afterLoad.range(of: "struct MacPDFKitView")?.lowerBound ?? afterLoad.endIndex
        let loadBody = String(afterLoad[..<loadEnd])

        guard let awaitRange = loadBody.range(of: "await MacMarkdownWorkspaceFileLoader.data") else {
            Issue.record("Expected load() to await workspace file bytes")
            return
        }
        let afterAwait = String(loadBody[awaitRange.upperBound...])

        guard let cancelIndex = afterAwait.range(of: "Task.isCancelled")?.lowerBound else {
            Issue.record("Expected load() to drop the write when the task is cancelled")
            return
        }
        guard let identityIndex = afterAwait.range(of: "loadIdentity")?.lowerBound else {
            Issue.record("Expected load() to drop the write when loadIdentity changed")
            return
        }

        let didFailIndex = afterAwait.range(of: "didFail = true")?.lowerBound
        let documentIndex = afterAwait.range(of: "self.document")?.lowerBound
            ?? afterAwait.range(of: "document = document")?.lowerBound

        #expect(didFailIndex != nil, "Current-identity decode failure should still set didFail")
        if let didFailIndex {
            #expect(cancelIndex < didFailIndex)
            #expect(identityIndex < didFailIndex)
        }
        if let documentIndex {
            #expect(cancelIndex < documentIndex)
            #expect(identityIndex < documentIndex)
        }
    }

    @Test func paintersUsePDFKitInTheWideColumnNotAPlaceholder() throws {
        let column = try source(named: "OppiMac/Views/MacToolDocumentColumn.swift")
        let preview = try source(named: "OppiMac/Views/MacPDFPreview.swift")

        #expect(preview.contains("import PDFKit"))
        #expect(preview.contains("PDFView"))
        #expect(preview.contains("NSViewRepresentable"))
        #expect(preview.contains("autoScales"))
        #expect(preview.contains("singlePageContinuous"))
        #expect(preview.contains("mac.documentColumn.pdf"))
        #expect(preview.contains("MacMarkdownWorkspaceFileLoader"))
        #expect(!preview.contains("PDF preview is not available"))
        #expect(!preview.contains("fullScreenCover"))
        #expect(!preview.contains("WindowGroup"))
        #expect(!preview.contains(".sheet("))

        #expect(column.contains("fileUsesPDFPreview"))
        #expect(column.contains("MacToolDocumentPDFView"))
        #expect(!column.contains("PDF preview is not available"))
        #expect(!column.contains("inspectorColumnWidth"))
        #expect(!column.contains("fullScreenCover"))
        #expect(!column.contains("WindowGroup"))
        #expect(!column.contains(".sheet("))
        #expect(MacToolDocumentColumnMetrics.minWidth >= 520)
    }

    @Test func audioAndVideoStayStreamingMediaWhilePDFKeepsBytes() throws {
        let audio = FileViewerDescriptorBuilder.descriptor(
            path: "clip.m4a",
            data: Data([0x00, 0x01, 0x02])
        )
        let video = FileViewerDescriptorBuilder.descriptor(
            path: "clip.mp4",
            data: Data([0x00, 0x01, 0x02])
        )
        let pdf = FileViewerDescriptorBuilder.descriptor(
            path: "doc.pdf",
            data: try samplePDFData()
        )

        guard case .media = audio else {
            Issue.record("Expected audio to stay a media descriptor, got \(audio)")
            return
        }
        guard case .media = video else {
            Issue.record("Expected video to stay a media descriptor, got \(video)")
            return
        }
        guard case .file(let file) = pdf else {
            Issue.record("Expected PDF to keep file bytes, got \(pdf)")
            return
        }

        #expect(file.fileType == .pdf)
        #expect(FileViewerDescriptorBuilder.needsFileBytes(path: "clip.m4a") == false)
        #expect(FileViewerDescriptorBuilder.needsFileBytes(path: "clip.mp4") == false)
        #expect(FileViewerDescriptorBuilder.needsFileBytes(path: "doc.pdf"))
        #expect(MacToolDocumentColumnPaint.surface(for: audio) == .media)
        #expect(MacToolDocumentColumnPaint.surface(for: video) == .media)
        #expect(MacToolDocumentColumnPaint.surface(for: pdf) == .file)
    }

    private func samplePDFData() throws -> Data {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        return try #require(document.dataRepresentation())
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
