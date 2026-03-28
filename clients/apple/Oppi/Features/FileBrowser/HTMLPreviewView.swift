import SwiftUI
import WebKit

// MARK: - HTMLContentTracker

/// Tracks whether an HTML web view needs to reload its content.
///
/// Detects two reload scenarios:
/// 1. Content changed (hash mismatch)
/// 2. WKWebView content process was terminated (blank screen recovery)
final class HTMLContentTracker {
    private var loadedContentHash: Int?
    private var processTerminated = false

    /// Returns true if the web view should reload for the given content.
    /// Call before `loadHTMLString`.
    func needsReload(for content: String) -> Bool {
        let hash = content.hashValue
        if processTerminated {
            loadedContentHash = hash
            return true
        }
        if hash != loadedContentHash {
            loadedContentHash = hash
            return true
        }
        return false
    }

    /// Call after a successful `loadHTMLString` to clear the reload flag.
    func markLoaded() {
        processTerminated = false
    }

    /// Call from `webViewWebContentProcessDidTerminate` to force
    /// the next `needsReload` to return true — even for same content.
    func markProcessTerminated() {
        processTerminated = true
    }
}

// MARK: - WKWebView wrapper

/// UIViewRepresentable wrapper for a hardened WKWebView.
///
/// Loads HTML from a string with no network access, no bridge,
/// and external links opening in Safari.
///
/// Handles two blank-screen scenarios:
/// - SwiftUI reuses the UIView with different content → `updateUIView` reloads
/// - WKWebView content process crashes → coordinator triggers reload
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
        let tracker = context.coordinator.contentTracker
        if tracker.needsReload(for: htmlString) {
            webView.loadHTMLString(htmlString, baseURL: nil)
            tracker.markLoaded()
        }

        return webView
    }

    func updateUIView(_ webView: PiWKWebView, context: Context) {
        webView.piActionHandler = piActionHandler

        // Reload if content changed or process was terminated
        let tracker = context.coordinator.contentTracker
        if tracker.needsReload(for: htmlString) {
            webView.loadHTMLString(htmlString, baseURL: nil)
            tracker.markLoaded()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let contentTracker = HTMLContentTracker()

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

        /// Recover from navigation failures (blank screen).
        /// Marks the tracker so the next `updateUIView` reloads.
        // swiftlint:disable:next no_force_unwrap_production
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            contentTracker.markProcessTerminated()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            contentTracker.markProcessTerminated()
            // Force an immediate reload — WKWebView is blank at this point.
            // Re-request the last loaded content via about:blank → triggers SwiftUI update cycle.
            webView.loadHTMLString("", baseURL: nil)
        }
    }
}
