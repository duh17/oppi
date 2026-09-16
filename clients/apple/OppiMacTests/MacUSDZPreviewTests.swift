import Foundation
import Testing
@testable import Oppi

@Suite("Mac USDZ document column preview")
struct MacUSDZPreviewTests {
    @Test func fileViewerPlanUSDZIsPathOnlyNotTextOrMedia() {
        let data = Data("PK\u{03}\u{04}utf8-looking".utf8)
        let descriptor = FileViewerDescriptorBuilder.descriptor(path: "models/scene.usdz", data: data)

        guard case .file(let file) = descriptor else {
            Issue.record("Expected USDZ to open as a file descriptor, got \(descriptor)")
            return
        }

        #expect(file.fileType == .usdz)
        #expect(file.text.isEmpty)
        #expect(FileViewerDescriptorBuilder.needsFileBytes(path: "models/scene.usdz") == false)
        #expect(MacToolDocumentColumnPaint.fileUsesUSDZPreview(file))
        #expect(MacToolDocumentColumnPaint.surface(for: descriptor) == .file)
        #expect(MacToolDocumentColumnPaint.surface(for: descriptor) != .media)
    }

    @Test func paintersUseRealityViewInTheWideColumn() throws {
        let column = try source(named: "OppiMac/Views/MacToolDocumentColumn.swift")
        let preview = try source(named: "OppiMac/Views/MacMarkdownUSDZView.swift")

        #expect(preview.contains("import RealityKit"))
        #expect(preview.contains("RealityView"))
        #expect(preview.contains("realityViewCameraControls"))
        #expect(preview.contains("mac.documentColumn.usdz"))
        #expect(preview.contains("MacMarkdownWorkspaceFileLoader"))
        #expect(preview.contains("MacUSDZInspectScrollLockKey"))
        #expect(!preview.contains("QLPreview"))
        #expect(column.contains("fileUsesUSDZPreview"))
        #expect(column.contains("MacToolDocumentUSDZView"))
        let timeline = try source(named: "OppiMac/Views/MacSessionTimelineViews.swift")
        #expect(timeline.contains("usdzInspectLocksScroll"))
        #expect(timeline.contains("MacUSDZInspectScrollLockKey"))
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
