import Foundation
import Testing
import UIKit
import WebKit
@testable import Oppi

/// Diagnostic tests for HTML-to-PDF export with Chart.js content.
///
/// Uses a real HTML file with Chart.js charts and Leaflet maps to validate
/// the full export pipeline. Saves PDF output to /tmp for visual inspection.
@Suite("HTML PDF Export Diagnostic")
@MainActor
struct HTMLPDFExportDiagnosticTests {

    /// Load the test HTML fixture.
    private func loadTestHTML() throws -> String {
        let bundle = Bundle(for: BundleAnchor.self)
        guard let url = bundle.url(forResource: "test-iran-war", withExtension: "html") else {
            throw HTMLPDFTestError.fixtureNotFound
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - WKWebView Chart.js Loading

    @Test func chartJSLoadsInOffscreenWebView() async throws {
        let html = try loadTestHTML()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)

        // Load and wait for navigation
        let loaded = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let del = NavDelegate(continuation: cont)
            webView.navigationDelegate = del
            objc_setAssociatedObject(webView, &NavDelegate.key, del, .OBJC_ASSOCIATION_RETAIN)
            webView.loadHTMLString(html, baseURL: nil)
        }
        #expect(loaded, "WKWebView navigation should succeed")

        // Wait for external scripts
        try await Task.sleep(for: .seconds(3))

        // Check if Chart.js loaded
        let chartLoaded = try await webView.evaluateJavaScript("typeof Chart !== 'undefined'") as? Bool
        print("[DIAG] Chart.js loaded: \(chartLoaded ?? false)")
        #expect(chartLoaded == true, "Chart.js should load from CDN")

        // Check canvas count
        let canvasCount = try await webView.evaluateJavaScript("document.querySelectorAll('canvas').length") as? Int
        print("[DIAG] Canvas count: \(canvasCount ?? 0)")
        #expect((canvasCount ?? 0) > 0, "Should have canvas elements")

        // Check Chart instances
        let instanceCount = try await webView.evaluateJavaScript(
            "window.Chart && Chart.instances ? Object.keys(Chart.instances).length : -1"
        ) as? Int
        print("[DIAG] Chart instances: \(instanceCount ?? -1)")

        // Check document.readyState
        let readyState = try await webView.evaluateJavaScript("document.readyState") as? String
        print("[DIAG] readyState: \(readyState ?? "unknown")")

        // Check canvas pixel content at center
        let canvasInfo = try await webView.evaluateJavaScript("""
            (function() {
                var results = [];
                document.querySelectorAll('canvas').forEach(function(c, i) {
                    var ctx = c.getContext('2d');
                    var w = c.width, h = c.height;
                    var cx = Math.floor(w/2), cy = Math.floor(h/2);
                    var hasCenterPx = false;
                    var hasAnyPx = false;
                    try {
                        var centerData = ctx.getImageData(cx, cy, 1, 1).data;
                        hasCenterPx = centerData[3] > 0;
                        // Sample 10 random spots
                        for (var s = 0; s < 10; s++) {
                            var sx = Math.floor(Math.random() * w);
                            var sy = Math.floor(Math.random() * h);
                            var sd = ctx.getImageData(sx, sy, 1, 1).data;
                            if (sd[3] > 0) { hasAnyPx = true; break; }
                        }
                    } catch(e) {}
                    results.push({
                        index: i,
                        id: c.id || '(no id)',
                        size: w + 'x' + h,
                        centerPixelOpaque: hasCenterPx,
                        anyPixelOpaque: hasAnyPx
                    });
                });
                return JSON.stringify(results);
            })();
        """) as? String
        print("[DIAG] Canvas info: \(canvasInfo ?? "null")")
    }

    // MARK: - Chart.js toBase64Image API

    @Test func chartToBase64ImageProducesContent() async throws {
        let html = try loadTestHTML()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)

        let loaded = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let del = NavDelegate(continuation: cont)
            webView.navigationDelegate = del
            objc_setAssociatedObject(webView, &NavDelegate.key, del, .OBJC_ASSOCIATION_RETAIN)
            webView.loadHTMLString(html, baseURL: nil)
        }
        #expect(loaded)

        // Wait for CDN scripts
        try await Task.sleep(for: .seconds(3))

        // Test toBase64Image on each chart instance
        let base64Info = try await webView.evaluateJavaScript("""
            (function() {
                if (!window.Chart || !Chart.instances) return 'no Chart.js';
                var keys = Object.keys(Chart.instances);
                var results = [];
                keys.forEach(function(k) {
                    var chart = Chart.instances[k];
                    chart.options.animation = false;
                    chart.resize();
                    chart.update('none');
                    var b64 = chart.toBase64Image('image/png', 1);
                    results.push({
                        id: chart.canvas.id,
                        b64Length: b64 ? b64.length : 0,
                        startsWithData: b64 ? b64.substring(0, 30) : 'null',
                        isBlank: !b64 || b64 === 'data:,' || b64.length < 100
                    });
                });
                return JSON.stringify(results);
            })();
        """) as? String
        print("[DIAG] toBase64Image results: \(base64Info ?? "null")")

        // At least one chart should produce a non-blank image
        #expect(base64Info?.contains("\"isBlank\":false") == true,
                "At least one chart should render via toBase64Image")
    }

    // MARK: - Full PDF Pipeline

    @Test func fullHTMLPDFExport() async throws {
        let html = try loadTestHTML()
        let item = await FileShareService.render(.html(html), as: .pdf)
        guard case .pdf(let data, let filename) = item else {
            Issue.record("Expected PDF, got \(item)")
            return
        }

        #expect(filename == "page.pdf")
        #expect(data.count > 0, "PDF data should not be empty")

        // Save to /tmp for visual inspection
        let outputPath = "/tmp/oppi-html-pdf-test.pdf"
        try data.write(to: URL(fileURLWithPath: outputPath))
        print("[DIAG] PDF saved to \(outputPath) (\(data.count) bytes)")
        print("[DIAG] Open with: open \(outputPath)")

        // A PDF with rendered charts should be significantly larger than text-only
        // Text-only PDF of this HTML would be ~50-100KB, with charts ~200KB+
        print("[DIAG] PDF size: \(data.count) bytes (\(data.count / 1024) KB)")
    }
}

// MARK: - Helpers

private enum HTMLPDFTestError: Error {
    case fixtureNotFound
}

/// Bundle anchor for finding test resources.
private final class BundleAnchor: NSObject {}

private final class NavDelegate: NSObject, WKNavigationDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    // swiftlint:disable no_force_unwrap_production
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(returning: true)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(returning: false)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(returning: false)
        continuation = nil
    }
    // swiftlint:enable no_force_unwrap_production
}
