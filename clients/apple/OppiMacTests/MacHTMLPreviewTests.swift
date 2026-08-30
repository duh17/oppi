import AppKit
import Foundation
import Testing
import WebKit
@testable import Oppi

@Suite("Mac HTML and SVG source + preview")
struct MacHTMLPreviewTests {
    @Test func htmlAndSVGFilesUseStringFetchPreviewNotRawURL() {
        #expect(MacHTMLPreviewSecurity.webViewLoadMode(for: "docs/report.html") == .htmlString)
        #expect(MacHTMLPreviewSecurity.webViewLoadMode(for: "docs/index.htm") == .htmlString)
        #expect(MacHTMLPreviewSecurity.webViewLoadMode(for: "icon.svg") == .htmlString)
        #expect(MacHTMLPreviewSecurity.webViewLoadMode(for: "notes.md") == .none)
        #expect(MacHTMLPreviewSecurity.webViewLoadMode(for: "photo.png") == .none)
        #expect(MacHTMLPreviewSecurity.usesMarkupPreview(path: "index.html"))
        #expect(MacHTMLPreviewSecurity.usesMarkupPreview(path: "logo.svg"))
        #expect(!MacHTMLPreviewSecurity.usesMarkupPreview(path: "App.swift"))
    }

    @Test func fileDescriptorsKeepHTMLAndSVGBytesForSourceAndPreview() throws {
        let html = try #require("<html><body>Hi</body></html>\n".data(using: .utf8))
        let svg = try #require("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>\n".data(using: .utf8))

        guard case .file(let htmlFile) = FileViewerDescriptorBuilder.descriptor(
            path: "index.html",
            data: html
        ) else {
            Issue.record("Expected HTML to stay a file descriptor")
            return
        }
        guard case .file(let svgFile) = FileViewerDescriptorBuilder.descriptor(
            path: "icon.svg",
            data: svg
        ) else {
            Issue.record("Expected SVG to stay a file descriptor")
            return
        }

        #expect(htmlFile.fileType == .html)
        #expect(svgFile.fileType == .image)
        #expect(MacMarkupPreviewKind.from(file: htmlFile) == .html)
        #expect(MacMarkupPreviewKind.from(file: svgFile) == .svg)
        #expect(MacToolDocumentColumnPaint.fileUsesMarkupPreview(htmlFile))
        #expect(MacToolDocumentColumnPaint.fileUsesMarkupPreview(svgFile))
        #expect(MacMarkupPreviewKind.from(htmlBlock: htmlFile.text) == .html)
        #expect(MacMarkupPreviewKind.from(htmlBlock: svgFile.text) == .svg)
    }

    @Test func previewInjectsCSPAndBlocksRemoteAndHostRawNavigation() throws {
        let policy = MacHTMLPreviewSecurity.contentSecurityPolicy
        #expect(policy.contains("default-src 'none'"))
        #expect(policy.contains("script-src 'unsafe-inline'"))
        #expect(policy.contains("style-src 'unsafe-inline'"))
        #expect(policy.contains("connect-src 'none'"))
        #expect(policy.contains("img-src data: blob:"))
        #expect(!policy.contains("http:"))
        #expect(!policy.contains("https:"))

        let withHead = MacHTMLPreviewSecurity.injectContentSecurityPolicy(
            into: "<html><head><title>Report</title></head><body>Hello</body></html>"
        )
        #expect(withHead.contains("<meta http-equiv=\"Content-Security-Policy\""))
        #expect(withHead.contains("<title>Report</title>"))

        let fragment = MacHTMLPreviewSecurity.injectContentSecurityPolicy(into: "<div>Hello</div>")
        #expect(fragment.contains("<head><meta http-equiv=\"Content-Security-Policy\""))
        #expect(fragment.contains("<div>Hello</div>"))

        #expect(MacHTMLPreviewSecurity.allowsEmbeddedNavigation(to: try #require(URL(string: "about:blank"))))
        #expect(MacHTMLPreviewSecurity.allowsEmbeddedNavigation(to: try #require(URL(string: "data:text/html,hi"))))
        #expect(MacHTMLPreviewSecurity.allowsEmbeddedNavigation(to: try #require(URL(string: "blob:https://example.com/id"))))
        #expect(!MacHTMLPreviewSecurity.allowsEmbeddedNavigation(to: try #require(URL(string: "file:///tmp/report.html"))))
        #expect(!MacHTMLPreviewSecurity.allowsEmbeddedNavigation(to: try #require(URL(string: "https://example.com"))))
        #expect(MacHTMLPreviewSecurity.isHostRawFileURL(
            try #require(URL(string: "https://example.com/files/raw?path=/tmp/report.html"))
        ))
        #expect(!MacHTMLPreviewSecurity.allowsEmbeddedNavigation(
            to: try #require(URL(string: "https://example.com/files/raw?path=/tmp/report.html"))
        ))
    }

    @MainActor
    @Test func previewWebViewConfigurationDisablesPersistentStateAndPopups() {
        let configuration = MacHTMLPreviewSecurity.makeConfiguration()

        #expect(configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
        #expect(configuration.userContentController.userScripts.isEmpty)
        #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript == true)
    }

    @Test func svgPreviewUsesImagePolicyNotHTMLJavaScript() throws {
        let policy = MacSVGPreviewSecurity.contentSecurityPolicy
        #expect(policy.contains("default-src 'none'"))
        #expect(policy.contains("img-src data:"))
        #expect(policy.contains("style-src 'unsafe-inline'"))
        #expect(policy.contains("media-src data:"))
        #expect(!policy.contains("script-src"))
        #expect(!policy.contains("http:"))
        #expect(!policy.contains("https:"))
        #expect(policy != MacHTMLPreviewSecurity.contentSecurityPolicy)
        #expect(MacHTMLPreviewSecurity.contentSecurityPolicy.contains("script-src 'unsafe-inline'"))

        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"
        let html = MacSVGPreviewSecurity.htmlDocumentEmbedding(svg: svg)
        #expect(html.contains("<img src=\"data:image/svg+xml;base64,"))
        #expect(html.contains(MacSVGPreviewSecurity.contentSecurityPolicy))
        #expect(!html.contains("script-src 'unsafe-inline'"))
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(!html.contains("<svg xmlns"))
        let decoded = try embeddedSVGDataURIPayload(in: html)
        #expect(String(data: decoded, encoding: .utf8) == svg)
    }

    @MainActor
    @Test func svgPreviewWebViewConfigurationDisablesJavaScript() {
        let configuration = MacSVGPreviewSecurity.makeConfiguration()

        #expect(configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
        #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(configuration.userContentController.userScripts.isEmpty)
    }

    @Test func markdownAndDocumentPaintersExposeSourceAndPreviewNotRawOnly() throws {
        let blocks = try source(named: "OppiMac/Views/MacMarkdownBlockViews.swift")
        let column = try source(named: "OppiMac/Views/MacToolDocumentColumn.swift")
        let preview = try source(named: "OppiMac/Views/MacHTMLPreview.swift")

        #expect(preview.contains("Text(\"Preview\")"))
        #expect(preview.contains("Text(\"Source\")"))
        #expect(preview.contains("MacHTMLWebView(html: source, kind: kind)"))
        #expect(preview.contains("MacSVGPreviewSecurity.makeConfiguration()"))
        #expect(preview.contains("htmlDocumentEmbedding(svg:"))
        #expect(preview.contains("data:image/svg+xml;base64,"))
        #expect(preview.contains("allowsContentJavaScript = false"))
        #expect(preview.contains("loadHTMLString"))
        #expect(preview.contains("baseURL: nil"))
        #expect(preview.contains("Picker"))
        #expect(!preview.contains("fullScreenCover"))
        #expect(!preview.contains("WindowGroup"))
        #expect(!preview.contains(".sheet("))

        #expect(blocks.contains("MacMarkupSourcePreviewView"))
        #expect(blocks.contains(".htmlBlock"))
        #expect(!blocks.contains("case .htmlBlock(let html):\n            Text(html)"))

        #expect(column.contains("fileUsesMarkupPreview"))
        #expect(column.contains("MacMarkupSourcePreviewView"))
        #expect(!column.contains("inspectorColumnWidth"))
        #expect(!column.contains("fullScreenCover"))
        #expect(!column.contains("WindowGroup"))
        #expect(!column.contains(".sheet("))
        #expect(MacToolDocumentColumnMetrics.minWidth >= 520)
    }

    @Test func htmlToSVGRecreatesWebViewBecauseConfigurationCannotChange() throws {
        let preview = try source(named: "OppiMac/Views/MacHTMLPreview.swift")

        // Identity follows kind so SwiftUI calls makeNSView again on HTML → SVG.
        #expect(preview.contains("MacHTMLWebView(html: source, kind: kind)"))
        #expect(preview.contains(".id(kind)"))

        // WKWebViewConfiguration is only applied in makeNSView. If this kind
        // ternary is ignored, SVG keeps HTML's allowsContentJavaScript.
        let makeNSView = try #require(makeNSViewSource(in: preview))
        #expect(makeNSView.contains("kind == .svg"))
        #expect(makeNSView.contains("MacSVGPreviewSecurity.makeConfiguration()"))
        #expect(makeNSView.contains("MacHTMLPreviewSecurity.makeConfiguration()"))
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeNSViewSource(in preview: String) -> String? {
        guard let start = preview.range(of: "func makeNSView(context: Context) -> WKWebView") else {
            return nil
        }
        guard let end = preview.range(of: "func updateNSView(") else {
            return nil
        }
        guard start.lowerBound < end.lowerBound else { return nil }
        return String(preview[start.lowerBound..<end.lowerBound])
    }

    private func embeddedSVGDataURIPayload(in html: String) throws -> Data {
        let marker = "<img src=\"data:image/svg+xml;base64,"
        let start = try #require(html.range(of: marker)?.upperBound)
        let end = try #require(html[start...].firstIndex(of: "\""))
        return try #require(Data(base64Encoded: String(html[start..<end])))
    }
}
