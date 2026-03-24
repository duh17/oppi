import SwiftUI
import WebKit

// MARK: - WKWebView wrapper

/// UIViewRepresentable wrapper for a hardened WKWebView.
///
/// Loads HTML from a string with no network access, no bridge,
/// and external links opening in Safari.
struct HTMLWebView: UIViewRepresentable {
    let htmlString: String
    let baseFileName: String
    var piActionHandler: ((String, PiQuickAction) -> Void)?

    func makeUIView(context: Context) -> PiWKWebView {
        let config = WKWebViewConfiguration()

        // Ephemeral storage — no cookies, cache, or local storage persisted
        config.websiteDataStore = .nonPersistent()

        // JavaScript enabled (many HTML artifacts need it for rendering)

        // No media auto-play
        config.mediaTypesRequiringUserActionForPlayback = .all

        let webView = PiWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = false
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .always

        // Transparent background for dark mode compatibility
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        webView.piActionHandler = piActionHandler

        // Load HTML with a blank base URL — no relative resource loading
        webView.loadHTMLString(htmlString, baseURL: nil)

        return webView
    }

    func updateUIView(_ webView: PiWKWebView, context: Context) {
        webView.piActionHandler = piActionHandler
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Block all navigation except the initial load.
        /// External links open in Safari.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Allow the initial HTML string load (about:blank or nil URL)
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            // For link clicks: open in Safari, block in-view navigation
            if let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        /// Block any new window requests (target="_blank" links, popups)
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Open in Safari instead of creating a new web view
            if let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }
}
