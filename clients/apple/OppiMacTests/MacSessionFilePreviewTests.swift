import AppKit
import Foundation
import Testing
@testable import Oppi

@Suite("Mac session file preview")
struct MacSessionFilePreviewTests {
    @Test func decodesUTF8TextPreview() throws {
        let data = try #require("hello\nworld\n".data(using: .utf8))

        let preview = MacSessionFilePreview(path: "Sources/App.swift", data: data)

        #expect(preview.path == "Sources/App.swift")
        #expect(preview.fileType == .code(language: .swift))
        #expect(preview.kind == .text)
        #expect(preview.text == "hello\nworld\n")
        #expect(preview.imageData == nil)
        #expect(preview.byteCount == data.count)
        #expect(!preview.truncated)
    }

    @Test func classifiesImageDataForInlinePreview() throws {
        let data = try #require(Self.pngData(width: 2, height: 3))

        let preview = MacSessionFilePreview(path: "image.png", data: data)

        #expect(preview.fileType == .image)
        #expect(preview.kind == .image)
        #expect(preview.text == nil)
        #expect(preview.imageData == data)
        #expect(preview.imageWidth == 2)
        #expect(preview.imageHeight == 3)
        #expect(!preview.truncated)
    }

    @Test func classifiesUnknownBinaryDataWithoutThrowing() {
        let data = Data([0xFF, 0xFE, 0x00, 0x00])

        let preview = MacSessionFilePreview(path: "blob.bin", data: data)

        #expect(preview.fileType == .binary)
        #expect(preview.kind == .binary)
        #expect(preview.text == nil)
        #expect(preview.imageData == nil)
        #expect(preview.byteCount == data.count)
    }

    @Test func truncatesLongTextPreview() throws {
        let text = String(repeating: "a", count: MacSessionFilePreview.maxPreviewCharacters + 10)
        let data = try #require(text.data(using: .utf8))

        let preview = MacSessionFilePreview(path: "large.txt", data: data)

        #expect(preview.fileType == .plain)
        #expect(preview.text?.count == MacSessionFilePreview.maxPreviewCharacters)
        #expect(preview.truncated)
        #expect(preview.byteCount == data.count)
    }

    @Test func usesSharedFileTypeDetectionForRenderableTextDocuments() throws {
        let mermaid = try #require("flowchart TD\nA --> B\n".data(using: .utf8))
        let org = try #require("* TODO Ship Mac renderers\n".data(using: .utf8))

        let mermaidPreview = MacSessionFilePreview(path: "diagram.mmd", data: mermaid)
        let orgPreview = MacSessionFilePreview(path: "notes.org", data: org)

        #expect(mermaidPreview.fileType == .mermaid)
        #expect(mermaidPreview.sourceLanguageLabel == "Mermaid")
        #expect(orgPreview.fileType == .orgMode)
        #expect(orgPreview.sourceLanguageLabel == "Org")
    }

    private static func pngData(width: Int, height: Int) -> Data? {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        return bitmap?.representation(using: .png, properties: [:])
    }
}
