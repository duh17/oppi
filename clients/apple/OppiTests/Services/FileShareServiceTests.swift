import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("FileShareService")
@MainActor
struct FileShareServiceTests {

    // MARK: - Format Selection

    @Test func defaultFormatForMermaidIsPDF() {
        let format = FileShareService.defaultFormat(for: .mermaid("graph TD; A-->B"))
        #expect(format == .pdf)
    }

    @Test func defaultFormatForLatexIsPDF() {
        let format = FileShareService.defaultFormat(for: .latex("E = mc^2"))
        #expect(format == .pdf)
    }

    @Test func defaultFormatForMarkdownIsPDF() {
        let format = FileShareService.defaultFormat(for: .markdown("# Hello"))
        #expect(format == .pdf)
    }

    @Test func defaultFormatForCodeIsPDF() {
        let format = FileShareService.defaultFormat(for: .code("let x = 1", language: "swift"))
        #expect(format == .pdf)
    }

    @Test func defaultFormatForHTMLIsPDF() {
        let format = FileShareService.defaultFormat(for: .html("<h1>Hello</h1>"))
        #expect(format == .pdf)
    }

    @Test func defaultFormatForOrgModeIsPDF() {
        let format = FileShareService.defaultFormat(for: .orgMode("* Hello"))
        #expect(format == .pdf)
    }

    @Test func defaultFormatForJSONIsPDF() {
        let format = FileShareService.defaultFormat(for: .json("{\"key\": 1}"))
        #expect(format == .pdf)
    }

    @Test func defaultFormatForPlainTextIsSource() {
        let format = FileShareService.defaultFormat(for: .plainText("hello"))
        #expect(format == .source)
    }

    @Test func defaultFormatForImageDataIsImage() {
        let format = FileShareService.defaultFormat(for: .imageData(Data(), filename: "test.png"))
        #expect(format == .image)
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

    @Test func pdfIsFirstAvailableFormatForRenderedTypes() {
        // PDF should be listed first for non-HTML rendered types
        let mdFormats = FileShareService.availableFormats(for: .markdown("# test"))
        #expect(mdFormats.first == .pdf)

        let mermaidFormats = FileShareService.availableFormats(for: .mermaid("graph TD"))
        #expect(mermaidFormats.first == .pdf)

        let orgFormats = FileShareService.availableFormats(for: .orgMode("* test"))
        #expect(orgFormats.first == .pdf)
    }

    @Test func htmlFormatsIncludeAllThree() {
        let htmlFormats = FileShareService.availableFormats(for: .html("<p>test</p>"))
        #expect(htmlFormats.contains(.image))
        #expect(htmlFormats.contains(.pdf))
        #expect(htmlFormats.contains(.source))
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

    @Test func sourceExportsUseIsolatedTempDirectories() async {
        defer { FileShareService.cleanupTempFiles() }

        let first = await FileShareService.render(.plainText("first export"), as: .source)
        let second = await FileShareService.render(.plainText("second export"), as: .source)

        guard case .file(let firstURL) = first,
              case .file(let secondURL) = second else {
            Issue.record("Expected file URLs for plain text source export")
            return
        }

        #expect(
            firstURL.deletingLastPathComponent() != secondURL.deletingLastPathComponent(),
            "Source exports should be isolated per-share to avoid cleanup races across overlapping sheets"
        )
    }

    // MARK: - Render Default

    @Test func renderDefaultProducesPDFForMarkdown() async {
        let content = FileShareService.ShareableContent.markdown("# Hello World")
        let item = await FileShareService.render(content, as: FileShareService.defaultFormat(for: content))
        guard case .pdf(let data, let filename) = item else {
            Issue.record("Expected PDF, got \(item)")
            return
        }
        #expect(data.count > 0)
        #expect(filename == "document.pdf")
    }

    @Test func renderDefaultProducesPDFForHTML() async {
        let content = FileShareService.ShareableContent.html("<h1>Hello</h1>")
        let item = await FileShareService.render(content, as: FileShareService.defaultFormat(for: content))
        guard case .pdf(let data, let filename) = item else {
            Issue.record("Expected PDF, got \(item)")
            return
        }
        #expect(!data.isEmpty)
        #expect(filename == "page.pdf")
    }

    @Test func renderDefaultProducesSourceForPlainText() async {
        let content = FileShareService.ShareableContent.plainText("hello")
        let item = await FileShareService.render(content, as: FileShareService.defaultFormat(for: content))
        guard case .file(let url) = item else {
            Issue.record("Expected file, got \(item)")
            return
        }
        #expect(url.lastPathComponent == "text.txt")
        FileShareService.cleanupTempFiles()
    }

    // MARK: - HTML Canvas Export (end-to-end)

    @Test func htmlCanvasRendersToImageWithCanvasPixels() async {
        let item = await FileShareService.render(.html(Self.canvasFixtureHTML), as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected image, got \(item)")
            return
        }

        #expect(image.size.width > 10)
        #expect(image.size.height > 10)
        #expect(Self.containsApproxMagentaPixel(in: image))
    }

    @Test func htmlCanvasRendersToPDFWithCanvasPixels() async {
        let item = await FileShareService.render(.html(Self.canvasFixtureHTML), as: .pdf)
        guard case .pdf(let data, let filename) = item else {
            Issue.record("Expected PDF, got \(item)")
            return
        }

        #expect(filename == "page.pdf")
        #expect(!data.isEmpty)
        let header = String(data: data.prefix(5), encoding: .ascii)
        #expect(header == "%PDF-")

        guard let image = Self.rasterizeFirstPDFPage(data) else {
            Issue.record("Failed to rasterize exported HTML PDF")
            return
        }
        #expect(Self.containsApproxMagentaPixel(in: image))
    }

    @Test func htmlCanvasManualArtifactExportWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["OPPI_EXPORT_HTML_ARTIFACTS"] == "1" else {
            return
        }

        let imageItem = await FileShareService.render(.html(Self.canvasFixtureHTML), as: .image)
        guard case .image(let image) = imageItem else {
            Issue.record("Expected image, got \(imageItem)")
            return
        }

        let pdfItem = await FileShareService.render(.html(Self.canvasFixtureHTML), as: .pdf)
        guard case .pdf(let pdfData, _) = pdfItem else {
            Issue.record("Expected pdf, got \(pdfItem)")
            return
        }

        guard let pngData = image.pngData() else {
            Issue.record("Could not encode PNG")
            return
        }

        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-html-export-artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let pngURL = exportDir.appendingPathComponent("html-canvas-export.png")
        let pdfURL = exportDir.appendingPathComponent("html-canvas-export.pdf")
        try pngData.write(to: pngURL)
        try pdfData.write(to: pdfURL)

        print("OPPI_HTML_EXPORT_ARTIFACT_PNG=\(pngURL.path)")
        print("OPPI_HTML_EXPORT_ARTIFACT_PDF=\(pdfURL.path)")

        #expect(FileManager.default.fileExists(atPath: pngURL.path))
        #expect(FileManager.default.fileExists(atPath: pdfURL.path))
    }

    // MARK: - PDF Rendering (additional types)

    @Test func latexRendersToPDF() async {
        let item = await FileShareService.render(.latex("E = mc^2"), as: .pdf)
        guard case .pdf(let data, let filename) = item else {
            Issue.record("Expected PDF, got \(item)")
            return
        }
        #expect(data.count > 0)
        #expect(filename == "formula.pdf")
    }

    @Test func codeRendersToPDF() async {
        let item = await FileShareService.render(.code("let x = 1", language: "swift"), as: .pdf)
        guard case .pdf(let data, let filename) = item else {
            Issue.record("Expected PDF, got \(item)")
            return
        }
        #expect(data.count > 0)
        #expect(filename == "code.pdf")
    }

    // MARK: - Source File Extensions

    @Test func sourceExportUsesCorrectExtensions() async {
        let cases: [(FileShareService.ShareableContent, String)] = [
            (.markdown("# test"), "document.md"),
            (.orgMode("* test"), "document.org"),
            (.html("<p>test</p>"), "page.html"),
            (.json("{\"a\":1}"), "data.json"),
            (.mermaid("graph TD"), "diagram.mmd"),
            (.latex("x^2"), "formula.tex"),
            (.code("fn main()", language: "rust"), "code.rs"),
            (.plainText("hello"), "text.txt"),
        ]

        for (content, expectedFilename) in cases {
            let item = await FileShareService.render(content, as: .source)
            guard case .file(let url) = item else {
                Issue.record("Expected file for \(expectedFilename), got \(item)")
                continue
            }
            #expect(url.lastPathComponent == expectedFilename, "Expected \(expectedFilename), got \(url.lastPathComponent)")
        }

        FileShareService.cleanupTempFiles()
    }

    // MARK: - Diff Export Spec

    @Test func defaultFormatForDiffIsImage() {
        let hunks = Self.sampleDiffHunks
        let format = FileShareService.defaultFormat(for: .diff(hunks, filePath: "test.swift"))
        #expect(format == .image)
    }

    @Test func diffHasImagePDFAndSourceFormats() {
        let hunks = Self.sampleDiffHunks
        let formats = FileShareService.availableFormats(for: .diff(hunks, filePath: "test.swift"))
        #expect(formats == [.image, .pdf, .source])
    }

    @Test func diffExportSpecHasCorrectMetadata() {
        let hunks = Self.sampleDiffHunks
        let spec = FileShareService.exportSpec(for: .diff(hunks, filePath: "test.swift"))
        #expect(spec.defaultFormat == .image)
        #expect(spec.sourceLabel == "Diff File")
        #expect(spec.sourceBaseName == "test")
        #expect(spec.sourceExtension == "diff")
        #expect(spec.pdfFilename == "test.pdf")
    }

    @Test func diffFormatDisplayInfoShowsCorrectLabels() {
        let hunks = Self.sampleDiffHunks
        let content = FileShareService.ShareableContent.diff(hunks, filePath: "test.swift")

        let imageInfo = FileShareService.formatDisplayInfo(.image, for: content)
        #expect(imageInfo.label == "Image")
        #expect(imageInfo.icon == "photo")

        let pdfInfo = FileShareService.formatDisplayInfo(.pdf, for: content)
        #expect(pdfInfo.label == "PDF")

        let sourceInfo = FileShareService.formatDisplayInfo(.source, for: content)
        #expect(sourceInfo.label == "Diff File")
        #expect(sourceInfo.icon == "doc.text")
    }

    // MARK: - Diff Source Export (Unified Diff Text)

    @Test func diffSourceExportProducesUnifiedDiffFormat() async {
        let hunks = Self.sampleDiffHunks
        let item = await FileShareService.render(.diff(hunks, filePath: "test.swift"), as: .source)
        guard case .file(let url) = item else {
            Issue.record("Expected file URL, got \(item)")
            return
        }

        #expect(url.lastPathComponent == "test.diff")
        let content = try? String(contentsOf: url, encoding: .utf8)
        guard let content else {
            Issue.record("Could not read diff file")
            return
        }

        // Must contain the hunk header
        #expect(content.contains("@@ -1,4 +1,4 @@"))

        // Must contain prefixed lines
        #expect(content.contains(" let x = 1"))       // context line with space prefix
        #expect(content.contains("-let y = 2"))        // removed line with - prefix
        #expect(content.contains("+let y = 3"))        // added line with + prefix

        FileShareService.cleanupTempFiles()
    }

    @Test func diffSourceExportMultipleHunksJoinedByNewline() async {
        let hunks = Self.multiHunkDiff
        let item = await FileShareService.render(.diff(hunks, filePath: "test.swift"), as: .source)
        guard case .file(let url) = item else {
            Issue.record("Expected file URL, got \(item)")
            return
        }

        let content = try? String(contentsOf: url, encoding: .utf8)
        guard let content else {
            Issue.record("Could not read diff file")
            return
        }

        // Both hunk headers must be present
        #expect(content.contains("@@ -1,4 +1,4 @@"))
        #expect(content.contains("@@ -20,3 +20,4 @@"))

        // Content from both hunks
        #expect(content.contains("-let y = 2"))
        #expect(content.contains("+let y = 3"))
        #expect(content.contains("+    let extra = true"))

        FileShareService.cleanupTempFiles()
    }

    @Test func emptyDiffSourceExportProducesEmptyContent() async {
        let item = await FileShareService.render(.diff([], filePath: "test.swift"), as: .source)
        guard case .file(let url) = item else {
            Issue.record("Expected file URL, got \(item)")
            return
        }

        let content = try? String(contentsOf: url, encoding: .utf8)
        #expect(content == "")
        FileShareService.cleanupTempFiles()
    }

    // MARK: - Diff Image Rendering

    @Test func diffRendersToImage() async {
        let hunks = Self.sampleDiffHunks
        let item = await FileShareService.render(.diff(hunks, filePath: "test.swift"), as: .image)
        assertRenderedImage(item, expectedFileName: "test.png")
    }

    @Test func emptyDiffRendersToImage() async {
        let item = await FileShareService.render(.diff([], filePath: "test.swift"), as: .image)
        // Should produce *something* even for empty input (attributed string is empty but layout still runs)
        assertRenderedImage(item, expectedFileName: "test.png")
    }

    @Test func diffImageDefaultRenderUsesImageFormat() async {
        let hunks = Self.sampleDiffHunks
        let content = FileShareService.ShareableContent.diff(hunks, filePath: "test.swift")
        let item = await FileShareService.render(content, as: FileShareService.defaultFormat(for: content))
        assertRenderedImage(item, expectedFileName: "test.png")
    }

    // MARK: - Diff PDF Rendering

    @Test func diffRendersToPDF() async {
        let hunks = Self.sampleDiffHunks
        let item = await FileShareService.render(.diff(hunks, filePath: "test.swift"), as: .pdf)
        guard case .pdf(let data, let filename) = item else {
            Issue.record("Expected PDF, got \(item)")
            return
        }
        #expect(!data.isEmpty)
        #expect(filename == "test.pdf")

        // Validate PDF header
        let header = String(data: data.prefix(5), encoding: .ascii)
        #expect(header == "%PDF-")
    }

    @Test func emptyDiffRendersToPDF() async {
        let item = await FileShareService.render(.diff([], filePath: "test.swift"), as: .pdf)
        guard case .pdf(let data, let filename) = item else {
            Issue.record("Expected PDF, got \(item)")
            return
        }
        #expect(filename == "test.pdf")
        // Even empty diff should produce valid PDF structure
        if !data.isEmpty {
            let header = String(data: data.prefix(5), encoding: .ascii)
            #expect(header == "%PDF-")
        }
    }

    // MARK: - Diff Attributed String Line Kind Attributes

    @Test func diffAttributedStringHasCorrectLineKindAttributes() {
        let hunks = Self.sampleDiffHunks
        let attrString = DiffAttributedStringBuilder.build(
            hunks: hunks, filePath: "test.swift", includeStats: true
        )
        let text = attrString.string as NSString

        // Collect all diffLineKindAttributeKey values
        var kinds: [String] = []
        attrString.enumerateAttribute(
            diffLineKindAttributeKey,
            in: NSRange(location: 0, length: text.length),
            options: []
        ) { value, _, _ in
            if let kind = value as? String {
                kinds.append(kind)
            }
        }

        // Must contain all three kinds from the sample hunks
        #expect(kinds.contains("added"), "Must tag added lines")
        #expect(kinds.contains("removed"), "Must tag removed lines")
        #expect(kinds.contains("header"), "Must tag header lines")
    }

    @Test func diffAttributedStringContextLinesHaveNoLineKind() {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
                lines: [
                    WorkspaceReviewDiffLine(kind: .context, text: "unchanged", oldLine: 1, newLine: 1, spans: nil),
                ]
            ),
        ]
        let attrString = DiffAttributedStringBuilder.build(hunks: hunks, filePath: "test.txt")
        let text = attrString.string as NSString

        // Find the code portion of the context line (after gutter + line nums)
        // The context gutter is "   " (3 spaces), then line numbers, then code
        var foundLineKindOnCode = false
        attrString.enumerateAttribute(
            diffLineKindAttributeKey,
            in: NSRange(location: 0, length: text.length),
            options: []
        ) { value, range, _ in
            if let kind = value as? String, kind != "header" {
                // Context lines should not have "added" or "removed" kind
                let rangeText = text.substring(with: range)
                if rangeText.contains("unchanged") {
                    foundLineKindOnCode = true
                }
            }
        }
        #expect(!foundLineKindOnCode, "Context code region should not have a diffLineKind attribute")
    }

    // MARK: - Diff with Word-Level Spans

    @Test func diffWithWordSpansRendersToImage() async {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 10, oldCount: 2, newStart: 10, newCount: 2,
                lines: [
                    WorkspaceReviewDiffLine(
                        kind: .removed, text: "let color = .red",
                        oldLine: 10, newLine: nil,
                        spans: [WorkspaceReviewDiffSpan(start: 13, end: 17, kind: .changed)]
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .added, text: "let color = .blue",
                        oldLine: nil, newLine: 10,
                        spans: [WorkspaceReviewDiffSpan(start: 13, end: 18, kind: .changed)]
                    ),
                ]
            ),
        ]
        let item = await FileShareService.render(.diff(hunks, filePath: "test.swift"), as: .image)
        assertRenderedImage(item, expectedFileName: "test.png")
    }

    @Test func diffWordSpansGetBackgroundAttributes() {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 1, oldCount: 2, newStart: 1, newCount: 2,
                lines: [
                    WorkspaceReviewDiffLine(
                        kind: .removed, text: "let x = old",
                        oldLine: 1, newLine: nil,
                        spans: [WorkspaceReviewDiffSpan(start: 8, end: 11, kind: .changed)]
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .added, text: "let x = new",
                        oldLine: nil, newLine: 1,
                        spans: [WorkspaceReviewDiffSpan(start: 8, end: 11, kind: .changed)]
                    ),
                ]
            ),
        ]
        let attrString = DiffAttributedStringBuilder.build(hunks: hunks, filePath: "test.swift")
        let text = attrString.string as NSString

        // Find "old" in the removed line and verify it has a background color
        let oldRange = text.range(of: "old")
        guard oldRange.location != NSNotFound else {
            Issue.record("Could not find 'old' in diff text")
            return
        }
        let oldBg = attrString.attribute(.backgroundColor, at: oldRange.location, effectiveRange: nil) as? UIColor
        #expect(oldBg != nil, "Word-level span on removed line must have background color")

        // Find "new" in the added line and verify it has a background color
        let newRange = text.range(of: "new")
        guard newRange.location != NSNotFound else {
            Issue.record("Could not find 'new' in diff text")
            return
        }
        let newBg = attrString.attribute(.backgroundColor, at: newRange.location, effectiveRange: nil) as? UIColor
        #expect(newBg != nil, "Word-level span on added line must have background color")

        // The two backgrounds should differ (removed vs added use different highlight colors)
        #expect(oldBg != newBg, "Removed and added word-span backgrounds should differ")
    }

    // MARK: - Large Diff Handling

    @Test func largeDiffRendersWithoutCrash() async {
        // Generate a diff with 500 lines to verify no OOM or excessive rendering time
        var lines: [WorkspaceReviewDiffLine] = []
        for i in 1...500 {
            let kind: WorkspaceReviewDiffLine.Kind = i % 3 == 0 ? .added : (i % 3 == 1 ? .removed : .context)
            lines.append(WorkspaceReviewDiffLine(
                kind: kind,
                text: "    let variable\(i) = \(i) // some code here with padding",
                oldLine: kind == .added ? nil : i,
                newLine: kind == .removed ? nil : i,
                spans: nil
            ))
        }
        let hunks = [WorkspaceReviewDiffHunk(oldStart: 1, oldCount: 334, newStart: 1, newCount: 334, lines: lines)]

        let item = await FileShareService.render(.diff(hunks, filePath: "test.swift"), as: .image)
        assertRenderedImage(item, expectedFileName: "test.png")
    }

    // MARK: - Diff Stats Summary

    @Test func diffAttributedStringIncludesStatsWhenRequested() {
        let hunks = Self.sampleDiffHunks
        let withStats = DiffAttributedStringBuilder.build(
            hunks: hunks, filePath: "test.swift", includeStats: true
        )
        let text = withStats.string

        // Stats line should include counts
        #expect(text.contains("+1"), "Stats should show added count")
        #expect(text.contains("-1"), "Stats should show removed count")
        #expect(text.contains("lines"), "Stats should show total line count")
    }

    @Test func diffAttributedStringOmitsStatsWhenNotRequested() {
        let hunks = Self.sampleDiffHunks
        let withoutStats = DiffAttributedStringBuilder.build(
            hunks: hunks, filePath: "test.swift", includeStats: false
        )
        let text = withoutStats.string

        // Should not have the stats summary prefix (the "+1 -1 N lines" line)
        // But should still have the hunk content.
        #expect(text.contains("let x = 1"))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.hasPrefix("1   let x = 1"), "Without stats, content should start with the first rendered diff line")
        #expect(!text.contains("Change 1 of 1"))
        #expect(!text.contains("Lines 1–4"))
        #expect(!text.contains("@@ -"), "Attributed diff rendering should not emit raw unified-diff hunk headers")
    }

    // MARK: - Diff Unified Text Correctness

    @Test func diffSourceExportContextLinesHaveSpacePrefix() async {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 5, oldCount: 1, newStart: 5, newCount: 1,
                lines: [
                    WorkspaceReviewDiffLine(kind: .context, text: "return true", oldLine: 5, newLine: 5, spans: nil),
                ]
            ),
        ]
        let item = await FileShareService.render(.diff(hunks, filePath: "test.swift"), as: .source)
        guard case .file(let url) = item else {
            Issue.record("Expected file URL")
            return
        }

        let content = try? String(contentsOf: url, encoding: .utf8)
        guard let content else {
            Issue.record("Could not read file")
            return
        }

        // Unified diff format: context lines start with " " (space)
        let lines = content.components(separatedBy: "\n")
        let contextLine = lines.first(where: { $0.contains("return true") })
        #expect(contextLine?.hasPrefix(" ") == true, "Context lines must have space prefix in unified diff")

        FileShareService.cleanupTempFiles()
    }

    @Test func diffSourceExportAddedLinesHavePlusPrefix() async {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 1, oldCount: 0, newStart: 1, newCount: 1,
                lines: [
                    WorkspaceReviewDiffLine(kind: .added, text: "import UIKit", oldLine: nil, newLine: 1, spans: nil),
                ]
            ),
        ]
        let item = await FileShareService.render(.diff(hunks, filePath: "test.swift"), as: .source)
        guard case .file(let url) = item else {
            Issue.record("Expected file URL")
            return
        }

        let content = try? String(contentsOf: url, encoding: .utf8)
        let lines = content?.components(separatedBy: "\n")
        let addedLine = lines?.first(where: { $0.contains("import UIKit") })
        #expect(addedLine?.hasPrefix("+") == true, "Added lines must have + prefix in unified diff")

        FileShareService.cleanupTempFiles()
    }

    @Test func diffSourceExportRemovedLinesHaveMinusPrefix() async {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 1, oldCount: 1, newStart: 1, newCount: 0,
                lines: [
                    WorkspaceReviewDiffLine(kind: .removed, text: "import UIKit", oldLine: 1, newLine: nil, spans: nil),
                ]
            ),
        ]
        let item = await FileShareService.render(.diff(hunks, filePath: "test.swift"), as: .source)
        guard case .file(let url) = item else {
            Issue.record("Expected file URL")
            return
        }

        let content = try? String(contentsOf: url, encoding: .utf8)
        let lines = content?.components(separatedBy: "\n")
        let removedLine = lines?.first(where: { $0.contains("import UIKit") })
        #expect(removedLine?.hasPrefix("-") == true, "Removed lines must have - prefix in unified diff")

        FileShareService.cleanupTempFiles()
    }

    // MARK: - Diff Fixtures

    private static let canvasFixtureHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <style>
          html, body { margin: 0; padding: 0; background: #111; }
          canvas { display: block; }
        </style>
      </head>
      <body>
        <canvas id="c" width="640" height="240"></canvas>
        <script>
          (function() {
            window.__captureReady = false;
            const canvas = document.getElementById('c');
            const ctx = canvas.getContext('2d');
            ctx.fillStyle = '#111111';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            ctx.fillStyle = '#ff00ff';
            ctx.fillRect(40, 40, 560, 160);
            ctx.fillStyle = '#00ff88';
            ctx.fillRect(260, 80, 120, 80);

            window.__oppiPrepareForCapture = function() {};
            window.__oppiReadyForCapture = function() { return window.__captureReady; };

            requestAnimationFrame(function() {
              window.__captureReady = true;
            });
          })();
        </script>
      </body>
    </html>
    """

    private static func rasterizeFirstPDFPage(_ data: Data) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdfDoc = CGPDFDocument(provider),
              let page = pdfDoc.page(at: 1) else {
            return nil
        }

        let pageRect = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let cgCtx = ctx.cgContext
            cgCtx.translateBy(x: 0, y: size.height)
            cgCtx.scaleBy(x: scale, y: -scale)
            cgCtx.drawPDFPage(page)
        }
    }

    private static func containsApproxMagentaPixel(in image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sampleStride = max(2, min(width, height) / 80)
        for y in stride(from: 0, to: height, by: sampleStride) {
            for x in stride(from: 0, to: width, by: sampleStride) {
                let idx = (y * width + x) * 4
                let r = buffer[idx]
                let g = buffer[idx + 1]
                let b = buffer[idx + 2]
                let a = buffer[idx + 3]

                if a > 200, r > 200, b > 200, g < 140 {
                    return true
                }
            }
        }

        return false
    }

    private static let sampleDiffHunks: [WorkspaceReviewDiffHunk] = [
        WorkspaceReviewDiffHunk(
            oldStart: 1, oldCount: 4, newStart: 1, newCount: 4,
            lines: [
                WorkspaceReviewDiffLine(kind: .context, text: "let x = 1", oldLine: 1, newLine: 1, spans: nil),
                WorkspaceReviewDiffLine(kind: .removed, text: "let y = 2", oldLine: 2, newLine: nil, spans: nil),
                WorkspaceReviewDiffLine(kind: .added, text: "let y = 3", oldLine: nil, newLine: 2, spans: nil),
                WorkspaceReviewDiffLine(kind: .context, text: "let z = 4", oldLine: 3, newLine: 3, spans: nil),
            ]
        ),
    ]

    private static let multiHunkDiff: [WorkspaceReviewDiffHunk] = [
        WorkspaceReviewDiffHunk(
            oldStart: 1, oldCount: 4, newStart: 1, newCount: 4,
            lines: [
                WorkspaceReviewDiffLine(kind: .context, text: "let x = 1", oldLine: 1, newLine: 1, spans: nil),
                WorkspaceReviewDiffLine(kind: .removed, text: "let y = 2", oldLine: 2, newLine: nil, spans: nil),
                WorkspaceReviewDiffLine(kind: .added, text: "let y = 3", oldLine: nil, newLine: 2, spans: nil),
                WorkspaceReviewDiffLine(kind: .context, text: "let z = 4", oldLine: 3, newLine: 3, spans: nil),
            ]
        ),
        WorkspaceReviewDiffHunk(
            oldStart: 20, oldCount: 3, newStart: 20, newCount: 4,
            lines: [
                WorkspaceReviewDiffLine(kind: .context, text: "func test() {", oldLine: 20, newLine: 20, spans: nil),
                WorkspaceReviewDiffLine(kind: .context, text: "    let result = true", oldLine: 21, newLine: 21, spans: nil),
                WorkspaceReviewDiffLine(kind: .added, text: "    let extra = true", oldLine: nil, newLine: 22, spans: nil),
                WorkspaceReviewDiffLine(kind: .context, text: "}", oldLine: 22, newLine: 23, spans: nil),
            ]
        ),
    ]

    // MARK: - Named vs Unnamed Export Filenames

    @Test func unnamedContentKeepsGenericExportNames() async {
        let cases: [(FileShareService.ShareableContent, String, String)] = [
            (.markdown("# test"), "document.md", "document.pdf"),
            (.html("<p>test</p>"), "page.html", "page.pdf"),
            (.code("let x = 1", language: "swift"), "code.swift", "code.pdf"),
            (.json("{\"a\":1}"), "data.json", "data.pdf"),
            (.mermaid("graph TD"), "diagram.mmd", "diagram.pdf"),
            (.latex("x^2"), "formula.tex", "formula.pdf"),
            (.orgMode("* test"), "document.org", "document.pdf"),
            (.plainText("hello"), "text.txt", "text.pdf"),
        ]

        for (content, expectedSource, expectedPDF) in cases {
            let spec = FileShareService.exportSpec(for: content)
            #expect(spec.pdfFilename == expectedPDF, "Unnamed PDF for \(expectedSource)")

            let source = await FileShareService.render(content, as: .source)
            guard case .file(let url) = source else {
                Issue.record("Expected source file for \(expectedSource), got \(source)")
                continue
            }
            #expect(url.lastPathComponent == expectedSource)
        }

        FileShareService.cleanupTempFiles()
    }

    @Test func fromTextWithPathPreservesOriginalFileName() async {
        let cases: [(path: String, source: String, pdf: String)] = [
            ("skills/SKILL.md", "SKILL.md", "SKILL.pdf"),
            ("src/Foo.swift", "Foo.swift", "Foo.pdf"),
            ("foo.test.ts", "foo.test.ts", "foo.test.pdf"),
            ("Makefile", "Makefile", "Makefile.pdf"),
            (".gitignore", ".gitignore", ".gitignore.pdf"),
            ("docs/report.html", "report.html", "report.pdf"),
            ("config.json", "config.json", "config.pdf"),
            ("charts/flow.mmd", "flow.mmd", "flow.pdf"),
            ("energy.tex", "energy.tex", "energy.pdf"),
            ("notes.org", "notes.org", "notes.pdf"),
        ]

        defer { FileShareService.cleanupTempFiles() }

        for item in cases {
            let content = FileShareService.ShareableContent.fromText("content", filePath: item.path)
            let spec = FileShareService.exportSpec(for: content)
            #expect(spec.pdfFilename == item.pdf, "PDF name for \(item.path)")

            let source = await FileShareService.render(content, as: .source)
            guard case .file(let url) = source else {
                Issue.record("Expected source file for \(item.path), got \(source)")
                continue
            }
            #expect(url.lastPathComponent == item.source, "Source name for \(item.path)")
        }
    }

    @Test func namedSkillMarkdownExportsOriginalStem() async {
        defer { FileShareService.cleanupTempFiles() }

        let content = FileShareService.ShareableContent.fromText("# Skill", filePath: "skills/SKILL.md")

        let source = await FileShareService.render(content, as: .source)
        guard case .file(let sourceURL) = source else {
            Issue.record("Expected source file, got \(source)")
            return
        }
        #expect(sourceURL.lastPathComponent == "SKILL.md")

        let pdf = await FileShareService.render(content, as: .pdf)
        guard case .pdf(_, let filename) = pdf else {
            Issue.record("Expected PDF, got \(pdf)")
            return
        }
        #expect(filename == "SKILL.pdf")
        #expect(activityItemFileName(pdf) == "SKILL.pdf")

        let image = await FileShareService.render(content, as: .image)
        #expect(activityItemFileName(image) == "SKILL.png")
    }

    @Test func namedSwiftCodeExportsOriginalStem() async {
        defer { FileShareService.cleanupTempFiles() }

        let content = FileShareService.ShareableContent.fromText("let x = 1", filePath: "Foo.swift")

        let source = await FileShareService.render(content, as: .source)
        guard case .file(let sourceURL) = source else {
            Issue.record("Expected source file, got \(source)")
            return
        }
        #expect(sourceURL.lastPathComponent == "Foo.swift")

        let pdf = await FileShareService.render(content, as: .pdf)
        guard case .pdf(_, let filename) = pdf else {
            Issue.record("Expected PDF, got \(pdf)")
            return
        }
        #expect(filename == "Foo.pdf")
        #expect(activityItemFileName(pdf) == "Foo.pdf")

        let image = await FileShareService.render(content, as: .image)
        #expect(activityItemFileName(image) == "Foo.png")
    }

    @Test func namedDiffReplacesLastExtensionOnly() async {
        defer { FileShareService.cleanupTempFiles() }

        let content = FileShareService.ShareableContent.diff(Self.sampleDiffHunks, filePath: "Foo.swift")
        let spec = FileShareService.exportSpec(for: content)
        #expect(spec.pdfFilename == "Foo.pdf")
        #expect(spec.sourceBaseName == "Foo")
        #expect(spec.sourceExtension == "diff")

        let source = await FileShareService.render(content, as: .source)
        guard case .file(let url) = source else {
            Issue.record("Expected diff source file, got \(source)")
            return
        }
        #expect(url.lastPathComponent == "Foo.diff")

        let pdf = await FileShareService.render(content, as: .pdf)
        guard case .pdf(_, let filename) = pdf else {
            Issue.record("Expected PDF, got \(pdf)")
            return
        }
        #expect(filename == "Foo.pdf")
    }

    @Test func unnamedPDFActivityItemCarriesGenericFilename() async {
        defer { FileShareService.cleanupTempFiles() }
        let item = await FileShareService.render(.markdown("# Hello"), as: .pdf)
        guard case .pdf(_, let filename) = item else {
            Issue.record("Expected PDF, got \(item)")
            return
        }
        #expect(filename == "document.pdf")
        #expect(activityItemFileName(item) == "document.pdf")
    }

    @Test func namedImageDataShareUsesOriginalFilename() async {
        defer { FileShareService.cleanupTempFiles() }
        let item = await FileShareService.render(
            .imageData(Data([0x89, 0x50, 0x4E, 0x47]), filename: "photo.jpg"),
            as: .image
        )
        #expect(activityItemFileName(item) == "photo.jpg")
    }

    @Test func fullScreenCodeShareableContentPreservesFilePathName() async {
        let controller = FullScreenCodeViewController(
            content: .markdown(content: "# Skill", filePath: "skills/SKILL.md")
        )
        let shareable = controller.shareableContentForTesting
        guard let shareable else {
            Issue.record("Expected shareable content from full-screen viewer")
            return
        }
        let spec = FileShareService.exportSpec(for: shareable)
        #expect(spec.pdfFilename == "SKILL.pdf")

        let codeController = FullScreenCodeViewController(
            content: .code(content: "let x = 1", language: "swift", filePath: "Foo.swift", startLine: 1)
        )
        let codeShareable = codeController.shareableContentForTesting
        guard let codeShareable else {
            Issue.record("Expected shareable code content from full-screen viewer")
            return
        }
        let codeSpec = FileShareService.exportSpec(for: codeShareable)
        #expect(codeSpec.pdfFilename == "Foo.pdf")

        let diffDocument = ToolDiffDocument(
            lines: [
                DiffLine(kind: .added, text: "new", oldLineNumber: nil, newLineNumber: 1),
            ],
            filePath: "Value.swift",
            copyText: "+new\n"
        )
        let diffController = FullScreenCodeViewController(content: .diff(diffDocument))
        guard let diffShareable = diffController.shareableContentForTesting,
              case .plainText(let shared, let diffFileName) = diffShareable else {
            Issue.record("Expected named plain-text share payload for full-screen diff")
            return
        }
        #expect(shared == diffDocument.copyText)
        #expect(diffFileName == "Value.diff")
        let diffSource = await FileShareService.render(diffShareable, as: .source)
        guard case .file(let url) = diffSource else {
            Issue.record("Expected source file for full-screen diff, got \(diffSource)")
            return
        }
        #expect(url.lastPathComponent == "Value.diff")
        FileShareService.cleanupTempFiles()
    }

    private func activityItemFileName(_ item: FileShareService.ShareItem) -> String? {
        item.activityItems.compactMap { $0 as? URL }.first?.lastPathComponent
    }

    private func assertRenderedImage(
        _ item: FileShareService.ShareItem,
        expectedFileName: String? = nil
    ) {
        if let expectedFileName {
            #expect(activityItemFileName(item) == expectedFileName)
        }
        switch item {
        case .image(let image):
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        case .file(let url):
            let image = UIImage(contentsOfFile: url.path)
            #expect(image != nil, "Named image export should write a readable PNG")
            #expect((image?.size.width ?? 0) > 0)
            #expect((image?.size.height ?? 0) > 0)
        default:
            Issue.record("Expected image or named image file, got \(item)")
        }
        FileShareService.cleanupTempFiles()
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
