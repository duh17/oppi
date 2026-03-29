import Testing
import UIKit
@testable import Oppi

private final class BundleToken {}

/// Tests for HTML → PDF and HTML → Image export pipelines.
///
/// These run on the simulator (WKWebView needs a window for GPU compositing).
/// Tests verify the full pipeline: HTML string → WKWebView → rendered output.
@Suite("HTML Export")
@MainActor
struct HTMLExportTests {

    // MARK: - Simple HTML

    private let simpleHTML = """
    <!DOCTYPE html>
    <html>
    <head><style>body { font-family: sans-serif; padding: 20px; }</style></head>
    <body><h1>Hello World</h1><p>This is a test paragraph with some content.</p></body>
    </html>
    """

    // MARK: - PDF

    @Test func simplePDFProducesNonEmptyData() async {
        let result = await FileShareService.render(.html(simpleHTML), as: .pdf)
        guard case .pdf(let data, let filename) = result else {
            Issue.record("Expected .pdf")
            return
        }
        let count = data.count
        #expect(count > 100, "PDF data should be non-trivial")
        #expect(filename == "page.pdf")
    }

    @Test func pdfStartsWithValidHeader() async {
        let result = await FileShareService.render(.html(simpleHTML), as: .pdf)
        guard case .pdf(let data, _) = result else {
            Issue.record("Expected .pdf")
            return
        }
        let header = String(data: data.prefix(5), encoding: .ascii)
        #expect(header == "%PDF-", "PDF should start with %PDF- header")
    }

    @Test func pdfHasReasonableSize() async {
        let result = await FileShareService.render(.html(simpleHTML), as: .pdf)
        guard case .pdf(let data, _) = result else {
            Issue.record("Expected .pdf")
            return
        }
        // Simple HTML PDF should be between 1KB and 1MB
        let count = data.count
        #expect(count > 1_000, "PDF too small")
        #expect(count < 1_000_000, "PDF too large")
    }

    // MARK: - Image

    @Test func simpleImageProducesNonBlankResult() async {
        let result = await FileShareService.render(.html(simpleHTML), as: .image)
        guard case .image(let image) = result else {
            Issue.record("Expected .image")
            return
        }
        #expect(image.size.width > 10, "Image too narrow")
        #expect(image.size.height > 10, "Image too short")
        #expect(!FileShareService.isBlankImage(image), "Image should not be blank")
    }

    @Test func imageHasExpectedWidth() async {
        let result = await FileShareService.render(.html(simpleHTML), as: .image)
        guard case .image(let image) = result else {
            Issue.record("Expected .image")
            return
        }
        // textLayoutWidth is 800pt, at 3x scale = 2400px
        // But snapshots may use 1x or 2x depending on sim — just check > 400
        #expect(image.size.width >= 400, "Image width below minimum")
    }

    // MARK: - Styled HTML

    private let styledHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <style>
        body { background: #1a1a2e; color: #eee; padding: 24px; font-family: system-ui; }
        .card { background: #16213e; border-radius: 12px; padding: 16px; margin: 8px 0; }
        h1 { color: #e94560; }
        code { background: #0f3460; padding: 2px 6px; border-radius: 4px; }
    </style>
    </head>
    <body>
        <h1>Styled Page</h1>
        <div class="card"><p>Card with <code>inline code</code></p></div>
        <div class="card"><p>Another card</p></div>
    </body>
    </html>
    """

    @Test func styledHTMLRendersToImage() async {
        let result = await FileShareService.render(.html(styledHTML), as: .image)
        guard case .image(let image) = result else {
            Issue.record("Expected .image")
            return
        }
        #expect(image.size.width > 10)
        #expect(image.size.height > 10)
    }

    @Test func styledHTMLRendersToPDF() async {
        let result = await FileShareService.render(.html(styledHTML), as: .pdf)
        guard case .pdf(let data, _) = result else {
            Issue.record("Expected .pdf")
            return
        }
        let header = String(data: data.prefix(5), encoding: .ascii)
        #expect(header == "%PDF-")
        #expect(data.count > 1_000)
    }

    // MARK: - Empty / Minimal HTML

    @Test func emptyHTMLProducesOutput() async {
        let result = await FileShareService.render(.html(""), as: .pdf)
        guard case .pdf(let data, _) = result else {
            Issue.record("Expected .pdf")
            return
        }
        // Even empty HTML should produce something (fallback)
        #expect(data.count > 0, "Empty HTML should still produce output")
    }

    @Test func minimalHTMLProducesImage() async {
        let result = await FileShareService.render(.html("<p>hi</p>"), as: .image)
        guard case .image(let image) = result else {
            Issue.record("Expected .image")
            return
        }
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    // MARK: - Source export

    @Test func sourceExportWritesHTMLFile() async {
        let result = await FileShareService.render(.html(simpleHTML), as: .source)
        guard case .file(let url) = result else {
            Issue.record("Expected .file")
            return
        }
        #expect(url.pathExtension == "html")
        let written = try? String(contentsOf: url, encoding: .utf8)
        #expect(written == simpleHTML)
    }

    // MARK: - Chart.js (real agent output)

    @Test func chartJsPDFProducesValidPDF() async {
        guard let html = chartJsFixtureHTML() else {
            Issue.record("Fixture chartjs-markets-dashboard.html not found in test bundle")
            return
        }
        let result = await FileShareService.render(.html(html), as: .pdf)
        guard case .pdf(let data, _) = result else {
            Issue.record("Expected .pdf")
            return
        }
        let header = String(data: data.prefix(5), encoding: .ascii)
        #expect(header == "%PDF-", "Should produce valid PDF")
        // Chart.js HTML with tables + charts should produce substantial PDF
        #expect(data.count > 5_000, "Chart.js PDF too small")
    }

    @Test func chartJsImageIsNotBlank() async {
        guard let html = chartJsFixtureHTML() else {
            Issue.record("Fixture chartjs-markets-dashboard.html not found in test bundle")
            return
        }
        let result = await FileShareService.render(.html(html), as: .image)
        guard case .image(let image) = result else {
            Issue.record("Expected .image")
            return
        }
        #expect(image.size.width > 100, "Image too narrow")
        #expect(image.size.height > 100, "Image too short")
        #expect(!FileShareService.isBlankImage(image), "Chart.js image should not be blank")
    }

    private func chartJsFixtureHTML() -> String? {
        guard let url = Bundle(for: BundleToken.self)
            .url(forResource: "chartjs-markets-dashboard", withExtension: "html") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - isBlankImage helper

    @Test func solidBlackImageIsBlank() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100))
        let blackImage = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        #expect(FileShareService.isBlankImage(blackImage))
    }

    @Test func colorfulImageIsNotBlank() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100))
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        }
        #expect(!FileShareService.isBlankImage(image))
    }
}
