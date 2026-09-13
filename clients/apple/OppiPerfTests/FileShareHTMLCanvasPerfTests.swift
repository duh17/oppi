import Foundation
import Testing
import UIKit
@testable import Oppi

/// Slow HTML canvas share-export proofs moved out of OppiTests.
/// WKWebView rasterization is too expensive for the default unit lane.
@Suite("FileShare HTML canvas export", .tags(.perf))
@MainActor
struct FileShareHTMLCanvasPerfTests {
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
}
