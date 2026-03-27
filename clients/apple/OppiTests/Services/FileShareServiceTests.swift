import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("FileShareService")
@MainActor
struct FileShareServiceTests {

    // MARK: - Format Selection

    @Test func defaultFormatForMermaidIsImage() {
        let format = FileShareService.defaultFormat(for: .mermaid("graph TD; A-->B"))
        #expect(format == .image)
    }

    @Test func defaultFormatForLatexIsImage() {
        let format = FileShareService.defaultFormat(for: .latex("E = mc^2"))
        #expect(format == .image)
    }

    @Test func defaultFormatForMarkdownIsImage() {
        let format = FileShareService.defaultFormat(for: .markdown("# Hello"))
        #expect(format == .image)
    }

    @Test func defaultFormatForCodeIsImage() {
        let format = FileShareService.defaultFormat(for: .code("let x = 1", language: "swift"))
        #expect(format == .image)
    }

    @Test func defaultFormatForPlainTextIsSource() {
        let format = FileShareService.defaultFormat(for: .plainText("hello"))
        #expect(format == .source)
    }

    @Test func defaultFormatForPDFDataIsPDF() {
        let format = FileShareService.defaultFormat(for: .pdfData(Data(), filename: "test.pdf"))
        #expect(format == .pdf)
    }

    // MARK: - Available Formats

    @Test func mermaidHasThreeFormats() {
        let formats = FileShareService.availableFormats(for: .mermaid("graph TD; A-->B"))
        #expect(formats.count == 3)
        #expect(formats.contains(.image))
        #expect(formats.contains(.pdf))
        #expect(formats.contains(.source))
    }

    @Test func plainTextHasOnlySource() {
        let formats = FileShareService.availableFormats(for: .plainText("hello"))
        #expect(formats == [.source])
    }

    @Test func imageDataHasOnlyImage() {
        let formats = FileShareService.availableFormats(for: .imageData(Data(), filename: "test.png"))
        #expect(formats == [.image])
    }

    // MARK: - RenderTheme.light

    @Test func lightThemeHasLightBackground() {
        let theme = RenderTheme.light
        // CGColor(gray:alpha:) has 2 components [gray, alpha]
        let components = theme.background.components ?? []
        #expect(components.count >= 2)
        #expect(components[0] > 0.9) // gray value near white
    }

    @Test func lightThemeHasDarkForeground() {
        let theme = RenderTheme.light
        let components = theme.foreground.components ?? []
        #expect(components.count >= 2)
        #expect(components[0] < 0.2) // gray value near black
    }

    // MARK: - Mermaid Image Rendering

    @Test func mermaidRendersToImage() async {
        let item = await FileShareService.render(.mermaid("graph TD\n    A-->B"), as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected image, got \(item)")
            return
        }
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    // MARK: - LaTeX Image Rendering

    @Test func latexRendersToImage() async {
        let item = await FileShareService.render(.latex("E = mc^2"), as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected image, got \(item)")
            return
        }
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    // MARK: - PDF Rendering

    @Test func mermaidRendersToPDF() async {
        let item = await FileShareService.render(.mermaid("graph TD\n    A-->B"), as: .pdf)
        guard case .pdf(let data, let filename) = item else {
            Issue.record("Expected PDF, got \(item)")
            return
        }
        #expect(data.count > 0)
        #expect(filename == "diagram.pdf")
    }

    // MARK: - Source File Export

    @Test func sourceFileCreation() async {
        let item = await FileShareService.render(.markdown("# Test"), as: .source)
        guard case .file(let url) = item else {
            Issue.record("Expected file URL, got \(item)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "document.md")

        // Read back
        let content = try? String(contentsOf: url, encoding: .utf8)
        #expect(content == "# Test")

        // Cleanup
        FileShareService.cleanupTempFiles()
    }

    @Test func tempFileCleanup() async {
        // Create a temp file
        _ = await FileShareService.render(.plainText("cleanup test"), as: .source)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-share", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: dir.path))

        // Cleanup
        FileShareService.cleanupTempFiles()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Activity Items

    @Test func imageShareItemProvidesActivityItems() async {
        let item = await FileShareService.render(.mermaid("graph TD\n    A-->B"), as: .image)
        guard case .image = item else {
            Issue.record("Expected image")
            return
        }
        #expect(item.activityItems.count == 1)
        #expect(item.activityItems.first is UIImage)
    }

    @Test func sourceShareItemProvidesActivityItems() async {
        let item = await FileShareService.render(.plainText("test"), as: .source)
        guard case .file = item else {
            Issue.record("Expected file")
            return
        }
        #expect(item.activityItems.count == 1)
        #expect(item.activityItems.first is URL)

        FileShareService.cleanupTempFiles()
    }
}
