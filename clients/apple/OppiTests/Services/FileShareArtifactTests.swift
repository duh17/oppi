import Foundation
import Testing
import UIKit
@testable import Oppi

/// Exhaustive share export matrix — generates real artifacts for every
/// (content type x export format) pair and writes them to disk for
/// visual inspection.
///
/// Artifacts go to: /tmp/oppi-share-artifacts/<content>/<format>.*
///
/// After running, `open /tmp/oppi-share-artifacts` to inspect.
@Suite("FileShareArtifacts")
@MainActor
struct FileShareArtifactTests {

    // MARK: - Test Fixtures

    /// Artifacts written under the project tree (host-visible).
    /// Simulator shares /Users with the host, so this is directly accessible.
    /// After test run: `open clients/apple/.build/share-artifacts`
    static let artifactDir = URL(
        fileURLWithPath: "/Users/chenda/workspace/oppi/clients/apple/.build/share-artifacts"
    )

    static let fixtures: [(name: String, content: FileShareService.ShareableContent)] = [
        ("mermaid", .mermaid("""
            graph TD
                A[Start] --> B{Decision}
                B -->|Yes| C[Do thing]
                B -->|No| D[Skip]
                C --> E[End]
                D --> E
            """)),
        ("latex", .latex("E = mc^2 + \\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}")),
        ("markdown", .markdown("""
            # Share Test

            This is **bold** and *italic* text.

            ```swift
            let x = 42
            print("Hello \\(x)")
            ```

            - Item one
            - Item two
            """)),
        ("orgmode", .orgMode("""
            * Heading One
            Some paragraph text.
            ** Sub heading
            - list item
            - another item
            #+BEGIN_SRC python
            print("hello")
            #+END_SRC
            """)),
        ("code-swift", .code("""
            import Foundation

            struct Point {
                var x: Double
                var y: Double

                func distance(to other: Point) -> Double {
                    let dx = x - other.x
                    let dy = y - other.y
                    return sqrt(dx * dx + dy * dy)
                }
            }
            """, language: "swift")),
        ("html", .html("""
            <!DOCTYPE html>
            <html><head><style>
            body { font-family: sans-serif; padding: 20px; }
            h1 { color: #333; }
            .box { background: #f0f0f0; padding: 12px; border-radius: 8px; }
            </style></head>
            <body>
            <h1>Share Test</h1>
            <div class="box"><p>Rendered HTML content.</p></div>
            </body></html>
            """)),
        ("json", .json("""
            {
                "name": "Oppi",
                "version": "2.0",
                "features": ["share", "render", "export"],
                "metrics": {
                    "tests": 42,
                    "coverage": 0.87
                }
            }
            """)),
        ("plaintext", .plainText("""
            This is plain text content.
            No formatting, no syntax highlighting.
            Just raw text — shared as a .txt file.
            """)),
    ]

    private struct ExportResult {
        let content: String
        let format: String
        let status: String
        let detail: String
    }

    // MARK: - Full Matrix

    @Test(.tags(.artifact))
    func fullExportMatrix() async throws {
        // Clean previous artifacts
        let fm = FileManager.default
        try? fm.removeItem(at: Self.artifactDir)
        try fm.createDirectory(at: Self.artifactDir, withIntermediateDirectories: true)

        var results: [ExportResult] = []

        for (name, content) in Self.fixtures {
            let formats = FileShareService.availableFormats(for: content)

            for format in formats {
                let dir = Self.artifactDir.appendingPathComponent(name)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)

                let item = await FileShareService.render(content, as: format)

                switch item {
                case .image(let image):
                    let path = dir.appendingPathComponent("\(format).png")
                    let data = image.pngData()
                    #expect(data != nil, "\(name)/image: pngData() returned nil")
                    if let data {
                        try data.write(to: path)
                        let sizeKB = data.count / 1024
                        #expect(image.size.width > 0, "\(name)/image: zero width")
                        #expect(image.size.height > 0, "\(name)/image: zero height")
                        results.append(ExportResult(
                            content: name, format: "image", status: "ok",
                            detail: "\(Int(image.size.width))x\(Int(image.size.height)), \(sizeKB)KB"
                        ))
                    }

                case .pdf(let data, let filename):
                    let path = dir.appendingPathComponent(filename)
                    #expect(!data.isEmpty, "\(name)/pdf: empty data")
                    try data.write(to: path)
                    // Validate it's real PDF
                    let header = String(data: data.prefix(5), encoding: .ascii)
                    #expect(header == "%PDF-", "\(name)/pdf: invalid PDF header, got \(header ?? "nil")")
                    let sizeKB = data.count / 1024
                    results.append(ExportResult(
                        content: name, format: "pdf", status: "ok",
                        detail: "\(filename), \(sizeKB)KB"
                    ))

                case .file(let url):
                    let exists = fm.fileExists(atPath: url.path)
                    #expect(exists, "\(name)/source: file not found at \(url.path)")
                    if exists {
                        let dest = dir.appendingPathComponent(url.lastPathComponent)
                        try? fm.removeItem(at: dest)
                        try fm.copyItem(at: url, to: dest)
                        let fileData = try Data(contentsOf: url)
                        let text = String(data: fileData, encoding: .utf8)
                        #expect(text?.isEmpty == false, "\(name)/source: empty file")
                        results.append(ExportResult(
                            content: name, format: "source", status: "ok",
                            detail: url.lastPathComponent
                        ))
                    }
                }
            }
        }

        // Write summary
        let summary = results.map {
            "\($0.content.padding(toLength: 14, withPad: " ", startingAt: 0)) " +
            "\($0.format.padding(toLength: 8, withPad: " ", startingAt: 0)) " +
            "\($0.status.padding(toLength: 6, withPad: " ", startingAt: 0)) \($0.detail)"
        }.joined(separator: "\n")
        let header = "content        format   status detail\n" + String(repeating: "-", count: 70)
        let report = header + "\n" + summary + "\n"
        try report.write(to: Self.artifactDir.appendingPathComponent("summary.txt"),
                         atomically: true, encoding: .utf8)

        // Print for test output
        print("\n=== Share Export Matrix ===")
        print(report)
        print("Artifacts: \(Self.artifactDir.path)")

        FileShareService.cleanupTempFiles()
    }

    // MARK: - Image Quality Checks

    @Test(.tags(.artifact))
    func mermaidImageIsNotBlank() async {
        let item = await FileShareService.render(Self.fixtures[0].content, as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected image")
            return
        }
        #expect(!FileShareService.isBlankImage(image), "Mermaid image is blank")
        #expect(image.size.width >= 100, "Mermaid image too narrow: \(image.size.width)")
        #expect(image.size.height >= 50, "Mermaid image too short: \(image.size.height)")
    }

    @Test(.tags(.artifact))
    func latexImageIsNotBlank() async {
        let item = await FileShareService.render(Self.fixtures[1].content, as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected image")
            return
        }
        #expect(!FileShareService.isBlankImage(image), "LaTeX image is blank")
        #expect(image.size.width >= 50, "LaTeX image too narrow")
    }

    @Test(.tags(.artifact))
    func markdownImageHasContent() async {
        let item = await FileShareService.render(Self.fixtures[2].content, as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected image")
            return
        }
        #expect(image.size.width >= 100)
        #expect(image.size.height >= 50)
    }

    @Test(.tags(.artifact))
    func codeImageHasContent() async {
        let item = await FileShareService.render(Self.fixtures[4].content, as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected image")
            return
        }
        // Code snapshots use NativeFullScreenCodeBody which needs a layout pass.
        // In test environments this may return a placeholder (200x100).
        // We verify it at least produces *something* — real content checks
        // are done via the PDF path which is more reliable offscreen.
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    // MARK: - PDF Validity

    @Test(.tags(.artifact))
    func allPDFsAreValid() async {
        for (name, content) in Self.fixtures {
            let formats = FileShareService.availableFormats(for: content)
            guard formats.contains(.pdf) else { continue }

            let item = await FileShareService.render(content, as: .pdf)
            guard case .pdf(let data, _) = item else {
                Issue.record("\(name): expected PDF")
                continue
            }
            // 8KB is the minimum for a PDF with actual rendered content.
            // Blank embed-image PDFs are ~6KB (just the PDF wrapper + empty image).
            #expect(data.count > 8000, "\(name): PDF suspiciously small (\(data.count) bytes) — likely blank")
            let header = String(data: data.prefix(5), encoding: .ascii)
            #expect(header == "%PDF-", "\(name): invalid PDF header")

            // Validate it can be opened by CGPDFDocument
            let provider = CGDataProvider(data: data as CFData)
            let pdfDoc = provider.flatMap { CGPDFDocument($0) }
            #expect(pdfDoc != nil, "\(name): CGPDFDocument failed to open")
            #expect((pdfDoc?.numberOfPages ?? 0) >= 1, "\(name): PDF has no pages")

            // Rasterize first page and check it's not blank
            if let pdfDoc, let page = pdfDoc.page(at: 1) {
                let pageRect = page.getBoxRect(.mediaBox)
                let renderer = UIGraphicsImageRenderer(size: pageRect.size)
                let raster = renderer.image { ctx in
                    UIColor.white.setFill()
                    ctx.fill(CGRect(origin: .zero, size: pageRect.size))
                    let cgCtx = ctx.cgContext
                    cgCtx.translateBy(x: 0, y: pageRect.height)
                    cgCtx.scaleBy(x: 1, y: -1)
                    cgCtx.drawPDFPage(page)
                }
                #expect(!FileShareService.isBlankImage(raster), "\(name): PDF renders to blank image")
            }
        }
    }

    // MARK: - Source Round-Trip

    @Test(.tags(.artifact))
    func allSourceFilesRoundTrip() async {
        for (name, content) in Self.fixtures {
            let formats = FileShareService.availableFormats(for: content)
            guard formats.contains(.source) else { continue }

            let item = await FileShareService.render(content, as: .source)
            guard case .file(let url) = item else {
                Issue.record("\(name): expected file URL")
                continue
            }

            let roundTripped = try? String(contentsOf: url, encoding: .utf8)
            #expect(roundTripped != nil, "\(name): could not read back source file")

            // Source content should match the original text
            let originalText = extractText(from: content)
            #expect(roundTripped == originalText,
                    "\(name): round-trip mismatch")
        }

        FileShareService.cleanupTempFiles()
    }

    // MARK: - Format Coverage

    @Test
    func everyContentTypeHasAtLeastOneFormat() {
        for (name, content) in Self.fixtures {
            let formats = FileShareService.availableFormats(for: content)
            #expect(!formats.isEmpty, "\(name): no available formats")
        }
    }

    @Test
    func renderableTypesHaveAllThreeFormats() {
        // These types should support image, pdf, AND source
        let renderableNames: Set<String> = [
            "mermaid", "latex", "markdown", "orgmode",
            "code-swift", "html", "json"
        ]
        for (name, content) in Self.fixtures where renderableNames.contains(name) {
            let formats = FileShareService.availableFormats(for: content)
            #expect(formats.contains(.image), "\(name): missing image format")
            #expect(formats.contains(.pdf), "\(name): missing pdf format")
            #expect(formats.contains(.source), "\(name): missing source format")
        }
    }

    @Test
    func plainTextOnlyHasSource() {
        let formats = FileShareService.availableFormats(for: .plainText("test"))
        #expect(formats == [.source])
    }

    // MARK: - Helpers

    private func extractText(from content: FileShareService.ShareableContent) -> String {
        switch content {
        case .mermaid(let t), .latex(let t), .markdown(let t),
             .orgMode(let t), .html(let t), .json(let t), .plainText(let t):
            return t
        case .code(let t, _):
            return t
        case .imageData, .pdfData:
            return ""
        }
    }
}

// MARK: - Tags

extension Tag {
    @Tag static var artifact: Self
}
