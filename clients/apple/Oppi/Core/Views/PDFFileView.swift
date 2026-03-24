import SwiftUI
import WebKit

/// Renders PDF content using WKWebView.
///
/// Accepts base64-encoded PDF data or raw content and displays it
/// in an embedded web view with native PDF rendering.
struct PDFFileView: View {
    let content: String

    var body: some View {
        PDFWebView(content: content)
            .frame(minHeight: 300)
    }
}

private struct PDFWebView: UIViewRepresentable {
    let content: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    private static let blankURL = URL(string: "about:blank") ?? URL(fileURLWithPath: "/")

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Try base64 decode first
        if let data = Data(base64Encoded: content) {
            webView.load(data, mimeType: "application/pdf", characterEncodingName: "", baseURL: Self.blankURL)
        } else if let data = content.data(using: .utf8) {
            // Raw bytes as UTF-8 — unlikely for real PDF but handle gracefully
            webView.load(data, mimeType: "application/pdf", characterEncodingName: "", baseURL: Self.blankURL)
        }
    }
}
