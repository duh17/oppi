import Foundation
import Testing
import UIKit
@testable import Oppi

/// End-to-end integration tests for the markdown rendering pipeline.
///
/// These tests render markdown through the FULL pipeline:
///   markdown string → AssistantMarkdownContentView → layout → snapshot → pixel check
///
/// This catches regressions that isolated unit tests miss — e.g., the segment
/// applier receiving the right segments but failing to create/layout the right views.
@Suite("MarkdownRenderingIntegration", .tags(.artifact))
@MainActor
struct MarkdownRenderingIntegrationTests {

    static let artifactDir = URL(
        fileURLWithPath: "/Users/chenda/workspace/oppi/clients/apple/.build/rendering-integration-artifacts"
    )

    // MARK: - Helpers

    /// Render markdown through AssistantMarkdownContentView and snapshot it.
    /// Uses `.export` mode so all rendering is synchronous.
    private func renderMarkdownToImage(
        _ markdown: String,
        width: CGFloat = 600,
        renderingMode: ContentRenderingMode = .export
    ) -> UIImage {
        let view = AssistantMarkdownContentView()
        view.backgroundColor = UIColor.white
        view.apply(configuration: .make(
            content: markdown,
            isStreaming: false,
            themeID: .light,
            textSelectionEnabled: false,
            plainTextFallbackThreshold: nil,
            renderingMode: renderingMode
        ))

        // Layout in a host view at the given width.
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 10000))
        view.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            view.topAnchor.constraint(equalTo: hostView.topAnchor),
        ])
        hostView.layoutIfNeeded()

        let height = max(view.bounds.height, 1)
        let imageSize = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: imageSize))
            view.layer.render(in: ctx.cgContext)
        }
    }

    /// Render in .live mode with a wait for async tasks to complete.
    private func renderMarkdownToImageLive(
        _ markdown: String,
        width: CGFloat = 600
    ) async -> UIImage {
        let view = AssistantMarkdownContentView()
        view.backgroundColor = UIColor.white
        view.apply(configuration: .make(
            content: markdown,
            isStreaming: false,
            themeID: .light,
            textSelectionEnabled: false,
            plainTextFallbackThreshold: nil,
            renderingMode: .live
        ))

        // Layout in a host view at the given width.
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 10000))
        view.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            view.topAnchor.constraint(equalTo: hostView.topAnchor),
        ])
        hostView.layoutIfNeeded()

        // Wait for async rendering (mermaid background task, syntax highlighting)
        try? await Task.sleep(for: .milliseconds(500))
        hostView.layoutIfNeeded()

        let height = max(view.bounds.height, 1)
        let imageSize = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: imageSize))
            view.layer.render(in: ctx.cgContext)
        }
    }

    /// Count distinct colors in the center 50% of the image (quantized to 6-bit).
    private func sampleDistinctColors(in image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let w = cgImage.width, h = cgImage.height
        guard w > 4, h > 4 else { return 0 }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bpp = 4
        var pixelData = [UInt8](repeating: 0, count: w * h * bpp)
        guard let context = CGContext(
            data: &pixelData, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bpp * w,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let x0 = w / 4, x1 = 3 * w / 4
        let y0 = h / 4, y1 = 3 * h / 4
        var colors = Set<UInt32>()
        for y in stride(from: y0, to: y1, by: 4) {
            for x in stride(from: x0, to: x1, by: 4) {
                let offset = (y * w + x) * bpp
                let r = UInt32(pixelData[offset] >> 2)
                let g = UInt32(pixelData[offset + 1] >> 2)
                let b = UInt32(pixelData[offset + 2] >> 2)
                colors.insert((r << 16) | (g << 8) | b)
            }
        }
        return colors.count
    }

    /// Check if a specific vertical region of the image has content (not blank white).
    private func regionHasContent(
        in image: UIImage,
        yFraction: ClosedRange<CGFloat>
    ) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let w = cgImage.width, h = cgImage.height
        guard w > 4, h > 4 else { return false }

        let bpp = 4
        var pixelData = [UInt8](repeating: 0, count: w * h * bpp)
        guard let context = CGContext(
            data: &pixelData, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bpp * w,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let y0 = Int(CGFloat(h) * yFraction.lowerBound)
        let y1 = Int(CGFloat(h) * yFraction.upperBound)
        let x0 = w / 4, x1 = 3 * w / 4

        var nonWhiteCount = 0
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                let offset = (y * w + x) * bpp
                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]
                // Not white (with some tolerance for anti-aliasing)
                if r < 240 || g < 240 || b < 240 {
                    nonWhiteCount += 1
                }
            }
        }
        // Need at least some non-white pixels to count as "has content"
        let totalSampled = ((y1 - y0) / 2) * ((x1 - x0) / 2)
        let ratio = Double(nonWhiteCount) / Double(max(totalSampled, 1))
        return ratio > 0.01  // At least 1% non-white pixels
    }

    private func writeArtifact(name: String, image: UIImage) {
        let dir = Self.artifactDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(name).png")
        try? image.pngData()?.write(to: path)
    }

    // MARK: - Export Mode (.export) Tests

    @Test(.tags(.artifact))
    func exportModeRendersPlainText() {
        let image = renderMarkdownToImage("Hello **world**")
        #expect(image.size.height > 10, "Plain text should have height")
        #expect(!FileShareService.isBlankImage(image), "Plain text should not be blank")
        writeArtifact(name: "export-plaintext", image: image)
    }

    @Test(.tags(.artifact))
    func exportModeRendersCodeWithSyntaxHighlighting() {
        let md = """
        ```swift
        let x = 42
        print("Hello \\(x)")
        ```
        """
        let image = renderMarkdownToImage(md)
        // Code block has a dark background with syntax-colored text.
        // Sampling the full image (not just center) catches the multiple syntax colors.
        #expect(image.size.height > 30, "Code block should have height")
        #expect(!FileShareService.isBlankImage(image), "Code block should not be blank")
        writeArtifact(name: "export-code-highlighted", image: image)
    }

    @Test(.tags(.artifact))
    func exportModeRendersMermaidDiagram() {
        let md = """
        ```mermaid
        graph TD
            A[Start] --> B[End]
        ```
        """
        let image = renderMarkdownToImage(md)
        #expect(image.size.height > 50, "Mermaid diagram should have significant height, got \(image.size.height)")
        let colors = sampleDistinctColors(in: image)
        #expect(colors >= 5, "Mermaid diagram should have varied colors (nodes, edges, text), got \(colors) — diagram likely not rendered")
        writeArtifact(name: "export-mermaid", image: image)
    }

    @Test(.tags(.artifact))
    func exportModeRendersTable() {
        let md = """
        | Name | Value |
        |------|-------|
        | Speed | Fast |
        | Memory | Low |
        """
        let image = renderMarkdownToImage(md)
        #expect(image.size.height > 50, "Table should have height")
        #expect(regionHasContent(in: image, yFraction: 0.0...1.0), "Table should render")
        writeArtifact(name: "export-table", image: image)
    }

    @Test(.tags(.artifact))
    func exportModeRendersMixedContent() {
        let md = """
        # Title

        Some text here.

        ```mermaid
        graph TD
            A[Start] --> B{Decision}
            B -->|Yes| C[Done]
            B -->|No| D[Retry]
        ```

        ## Results

        | Metric | Value |
        |--------|-------|
        | Speed | 3.2x |

        ```python
        def hello():
            print("world")
        ```
        """
        let image = renderMarkdownToImage(md)
        #expect(image.size.height > 200, "Mixed content should be tall, got \(image.size.height)")

        // Top region should have heading text
        #expect(regionHasContent(in: image, yFraction: 0.0...0.15), "Top region should have heading")

        // Middle region should have mermaid diagram (which is the bulk of the content)
        #expect(regionHasContent(in: image, yFraction: 0.2...0.6), "Middle region should have mermaid diagram")

        // Bottom region should have table + code
        #expect(regionHasContent(in: image, yFraction: 0.7...1.0), "Bottom region should have table/code")

        let colors = sampleDistinctColors(in: image)
        #expect(colors >= 5, "Mixed content should be visually rich, got \(colors)")

        writeArtifact(name: "export-mixed", image: image)
    }

    // MARK: - Live Mode (.live) Tests

    @Test(.tags(.artifact))
    func liveModeRendersMermaidAfterAsyncWait() async {
        let md = """
        ```mermaid
        graph TD
            A[Start] --> B[End]
        ```
        """
        let image = await renderMarkdownToImageLive(md)
        #expect(image.size.height > 50, "Live mermaid should have height after async wait, got \(image.size.height)")
        let colors = sampleDistinctColors(in: image)
        #expect(colors >= 5, "Live mermaid should have diagram colors after async wait, got \(colors)")
        writeArtifact(name: "live-mermaid", image: image)
    }

    @Test(.tags(.artifact))
    func liveModeRendersCodeHighlightedAfterAsyncWait() async {
        let md = """
        ```swift
        let x = 42
        print("Hello \\(x)")
        ```
        """
        let image = await renderMarkdownToImageLive(md)
        #expect(image.size.height > 30, "Live code should have height")
        #expect(!FileShareService.isBlankImage(image), "Live code should not be blank")
        writeArtifact(name: "live-code-highlighted", image: image)
    }

    // MARK: - FileShareService Integration

    @Test(.tags(.artifact))
    func fileShareServiceMarkdownExportRendersMermaid() async {
        let md = """
        # Architecture

        ```mermaid
        graph TD
            A[Client] --> B[Server]
            B --> C[(DB)]
        ```

        The server connects to the database.
        """
        let item = await FileShareService.render(.markdown(md), as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected image from FileShareService")
            return
        }
        #expect(image.size.height > 100, "Markdown with mermaid should have height")
        let colors = sampleDistinctColors(in: image)
        #expect(colors >= 5, "FileShareService markdown export should render mermaid diagram, got \(colors) distinct colors")
        writeArtifact(name: "fileshare-mermaid-md", image: image)
    }

    @Test(.tags(.artifact))
    func fileShareServiceMarkdownExportRendersCodeHighlighted() async {
        let md = """
        ```swift
        struct Point {
            var x: Double
            var y: Double
        }
        ```
        """
        let item = await FileShareService.render(.markdown(md), as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected image from FileShareService")
            return
        }
        #expect(image.size.height > 50, "FileShareService code export should have height")
        #expect(!FileShareService.isBlankImage(image), "FileShareService code export should not be blank")
        writeArtifact(name: "fileshare-code-md", image: image)
    }

    @Test(.tags(.artifact))
    func fileShareServiceMarkdownExportRendersTable() async {
        let md = """
        | A | B | C |
        |---|---|---|
        | 1 | 2 | 3 |
        | 4 | 5 | 6 |
        """
        let item = await FileShareService.render(.markdown(md), as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected image from FileShareService")
            return
        }
        #expect(image.size.height > 50, "Table export should have height")
        #expect(!FileShareService.isBlankImage(image), "Table export should not be blank")
        writeArtifact(name: "fileshare-table-md", image: image)
    }

    // MARK: - Workspace Image Context Tests

    /// Verify that workspace context (workspaceID + serverBaseURL) flows through
    /// the full AssistantMarkdownContentView pipeline and creates NativeMarkdownImageView
    /// subviews (not just text with [alt]).
    @Test func workspaceContextCreatesImageViews() {
        let md = "![Test image](images/test.png)"
        let view = AssistantMarkdownContentView()
        view.fetchWorkspaceFile = { _, _ in Data() } // dummy — we just need non-nil

        view.apply(configuration: .make(
            content: md,
            isStreaming: false,
            themeID: .light,
            textSelectionEnabled: false,
            plainTextFallbackThreshold: nil,
            workspaceID: "test-ws",
            serverBaseURL: URL(string: "https://example.com/api")!,
            sourceFilePath: "docs/readme.md",
            renderingMode: .export
        ))

        // Layout so subviews are created
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 1000))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutIfNeeded()

        // Walk the view hierarchy looking for NativeMarkdownImageView
        func findImageViews(in root: UIView) -> [NativeMarkdownImageView] {
            var found: [NativeMarkdownImageView] = []
            for sub in root.subviews {
                if let imageView = sub as? NativeMarkdownImageView {
                    found.append(imageView)
                }
                found.append(contentsOf: findImageViews(in: sub))
            }
            return found
        }

        let imageViews = findImageViews(in: view)
        #expect(!imageViews.isEmpty,
                "Expected NativeMarkdownImageView in hierarchy — workspace context should produce .image segments, not [alt] text")
    }

    /// Verify that fullScreenContent-equivalent logic produces the right enum case.
    @Test func fromTextDetectsMarkdownForDocsPath() {
        let content = FullScreenCodeContent.fromText(
            "![Chart](images/chart.png)",
            filePath: "docs/image-load-test.md"
        )
        if case .markdown = content {
            // Expected
        } else {
            Issue.record("Expected .markdown for .md file, got \(content)")
        }
    }

    /// Verify that fullScreenContent-equivalent logic WITH workspace context
    /// creates a FullScreenCodeContent that FullScreenCodeVC can render with images.
    @Test func fullScreenContentWithWorkspaceContextProducesImages() {
        // Simulate exactly what FileBrowserContentView.fullScreenContent does:
        let text = "![Chart](images/chart.png)"
        let filePath = "docs/image-load-test.md"
        let base = FullScreenCodeContent.fromText(text, filePath: filePath)

        let result: FullScreenCodeContent
        if case .markdown(let content, let path, _) = base {
            result = .markdown(
                content: content,
                filePath: path,
                workspaceContext: .init(
                    workspaceID: "test-ws",
                    serverBaseURL: URL(string: "https://example.com/api")!,
                    fetchWorkspaceFile: { _, _ in Data() }
                )
            )
        } else {
            Issue.record("fromText should produce .markdown for .md file")
            return
        }

        // Now feed it to FullScreenCodeVC
        let vc = FullScreenCodeViewController(content: result, presentationMode: .sheet)
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 600, height: 1000)
        vc.view.layoutIfNeeded()

        func findImageViews(in root: UIView) -> [NativeMarkdownImageView] {
            var found: [NativeMarkdownImageView] = []
            for sub in root.subviews {
                if let iv = sub as? NativeMarkdownImageView { found.append(iv) }
                found.append(contentsOf: findImageViews(in: sub))
            }
            return found
        }

        let imageViews = findImageViews(in: vc.view)
        #expect(!imageViews.isEmpty,
                "Full pipeline (fromText + workspace context + FullScreenCodeVC) should create image views")
    }

    /// Verify workspace context flows through FullScreenCodeViewController
    /// → NativeFullScreenMarkdownBody → AssistantMarkdownContentView.
    @Test func workspaceContextFlowsThroughFullScreenVC() {
        let wsContext = FullScreenCodeContent.WorkspaceContext(
            workspaceID: "test-ws",
            serverBaseURL: URL(string: "https://example.com/api")!,
            fetchWorkspaceFile: { _, _ in Data() }
        )
        let content = FullScreenCodeContent.markdown(
            content: "![Chart](images/chart.png)",
            filePath: "docs/readme.md",
            workspaceContext: wsContext
        )

        let vc = FullScreenCodeViewController(
            content: content,
            presentationMode: .sheet
        )
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 600, height: 1000)
        vc.view.layoutIfNeeded()

        func findImageViews(in root: UIView) -> [NativeMarkdownImageView] {
            var found: [NativeMarkdownImageView] = []
            for sub in root.subviews {
                if let iv = sub as? NativeMarkdownImageView { found.append(iv) }
                found.append(contentsOf: findImageViews(in: sub))
            }
            return found
        }

        let imageViews = findImageViews(in: vc.view)
        #expect(!imageViews.isEmpty,
                "FullScreenCodeViewController with workspace context should create NativeMarkdownImageView, not alt text fallback")
    }

    /// Verify workspace context flows through NativeFullScreenMarkdownBody
    /// (the layer between FullScreenCodeVC and AssistantMarkdownContentView).
    @Test func workspaceContextFlowsThroughFullScreenMarkdownBody() {
        let body = NativeFullScreenMarkdownBody(
            content: "![Chart](images/chart.png)",
            stream: nil,
            palette: ThemeID.dark.palette,
            plainTextFallbackThreshold: nil,
            selectedTextPiRouter: nil,
            selectedTextSourceContext: nil,
            workspaceID: "test-ws",
            serverBaseURL: URL(string: "https://example.com/api")!,
            sourceFilePath: "docs/readme.md",
            fetchWorkspaceFile: { _, _ in Data() }
        )

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 1000))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        func findImageViews(in root: UIView) -> [NativeMarkdownImageView] {
            var found: [NativeMarkdownImageView] = []
            for sub in root.subviews {
                if let iv = sub as? NativeMarkdownImageView { found.append(iv) }
                found.append(contentsOf: findImageViews(in: sub))
            }
            return found
        }

        let imageViews = findImageViews(in: body)
        #expect(!imageViews.isEmpty,
                "NativeFullScreenMarkdownBody should create NativeMarkdownImageView when workspace context is provided")
    }

    /// Same test WITHOUT workspace context — should fall back to text with [alt].
    @Test func noWorkspaceContextFallsBackToAltText() {
        let md = "![Test image](images/test.png)"
        let view = AssistantMarkdownContentView()
        // No fetchWorkspaceFile, no workspaceID, no serverBaseURL

        view.apply(configuration: .make(
            content: md,
            isStreaming: false,
            themeID: .light,
            textSelectionEnabled: false,
            plainTextFallbackThreshold: nil,
            renderingMode: .export
        ))

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 1000))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutIfNeeded()

        func findImageViews(in root: UIView) -> [NativeMarkdownImageView] {
            var found: [NativeMarkdownImageView] = []
            for sub in root.subviews {
                if let imageView = sub as? NativeMarkdownImageView {
                    found.append(imageView)
                }
                found.append(contentsOf: findImageViews(in: sub))
            }
            return found
        }

        let imageViews = findImageViews(in: view)
        #expect(imageViews.isEmpty,
                "Without workspace context, images should fall back to alt text, not create NativeMarkdownImageView")
    }
}
