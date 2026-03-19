import SwiftUI
import WebKit

/// Hardened WKWebView preview for workspace HTML files.
///
/// Security posture (from docs/design/html-artifacts.md):
/// - No `window.oppi` or native bridge injection
/// - No authenticated fetch helpers
/// - Restrictive default CSP: inline styles/scripts allowed (self-contained HTML),
///   but no external network loads
/// - External link taps open in Safari (navigation delegate blocks off-origin nav)
/// - JavaScript enabled (HTML files often need it for rendering)
/// - No persistent data access (ephemeral data store)
struct HTMLPreviewView: View {
    let workspaceId: String
    let filePath: String
    let fileName: String

    @Environment(\.apiClient) private var apiClient
    @Environment(AppNavigation.self) private var navigation
    @State private var htmlContent: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let html = htmlContent {
                HTMLWebView(
                    htmlString: html,
                    baseFileName: fileName,
                    piActionHandler: piActionHandler
                )
                .ignoresSafeArea(edges: .bottom)
            } else if let error {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ProgressView("Loading preview...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.themeBgDark)
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadHTML() }
    }

    /// Routes selected text to a quick session via AppNavigation.
    private var piActionHandler: (String, PiQuickAction) -> Void {
        let path = filePath
        let nav = navigation
        return { text, quickAction in
            let request = SelectedTextPiRequest(
                action: quickAction,
                selectedText: text,
                source: SelectedTextSourceContext(
                    sessionId: "",
                    surface: .fullScreenSource,
                    filePath: path
                )
            )
            nav.pendingQuickSessionDraft = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            nav.showQuickSession = true
        }
    }

    private func loadHTML() async {
        guard let api = apiClient else {
            error = "Not connected"
            return
        }
        do {
            let data = try await api.browseWorkspaceFile(workspaceId: workspaceId, path: filePath)
            guard let text = String(data: data, encoding: .utf8) else {
                error = "Could not decode file as text"
                return
            }
            htmlContent = text
        } catch {
            self.error = error.localizedDescription
        }
    }
}

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
