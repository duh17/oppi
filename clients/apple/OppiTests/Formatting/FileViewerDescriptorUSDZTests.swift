import Foundation
import Testing
@testable import Oppi

@Suite("FileViewerDescriptorBuilder USDZ")
struct FileViewerDescriptorUSDZTests {
    @Test("routes USDZ before UTF-8 and never stores text or base64")
    func routesUSDZBeforeUTF8WithoutPayload() {
        let utf8Looking = Data("PK\u{03}\u{04}this-is-utf8-looking-usdz-bytes".utf8)
        let descriptor = FileViewerDescriptorBuilder.descriptor(
            path: "models/scene.usdz",
            data: utf8Looking
        )

        guard case .file(let file) = descriptor else {
            Issue.record("Expected a path-only file descriptor, got \(descriptor)")
            return
        }

        #expect(file.fileType == .usdz)
        #expect(file.filePath == "models/scene.usdz")
        #expect(file.text.isEmpty)
        #expect(file.text != String(data: utf8Looking, encoding: .utf8))
        #expect(!file.text.contains("PK"))
        #expect(Data(base64Encoded: file.text) == nil || file.text.isEmpty)
        #expect(FileViewerDescriptorBuilder.needsFileBytes(path: "models/scene.usdz") == false)
        #expect(FileViewerDescriptorBuilder.needsFileBytes(path: "doc.pdf"))
        #expect(FileViewerDescriptorBuilder.needsFileBytes(path: "clip.mp4") == false)
    }

    @Test("does not treat USDZ as streaming media")
    func usdzIsNotStreamingMediaDescriptor() {
        let descriptor = FileViewerDescriptorBuilder.descriptor(
            path: "scene.usdz",
            data: Data([0x50, 0x4B, 0x03, 0x04])
        )
        guard case .file(let file) = descriptor else {
            Issue.record("Expected file descriptor, got \(descriptor)")
            return
        }
        #expect(file.fileType == .usdz)
        if case .media = descriptor {
            Issue.record("USDZ must not become a streaming media descriptor")
        }
    }
}
