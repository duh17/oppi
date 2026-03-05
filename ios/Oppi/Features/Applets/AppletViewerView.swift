import SwiftUI
import WebKit

/// Full-screen WKWebView renderer for an applet.
struct AppletViewerView: View {
    let applet: Applet

    @Environment(ServerConnection.self) private var connection
    @State private var isLoading = true
    @State private var error: String?

    private var htmlURL: URL? {
        connection.apiClient?.appletHTMLURL(
            workspaceId: applet.workspaceId,
            appletId: applet.id,
            version: applet.currentVersion
        )
    }

    var body: some View {
        Group {
            if let url = htmlURL {
                AppletWebView(url: url, isLoading: $isLoading, error: $error)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView(
                    "Cannot Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Could not build applet URL")
                )
            }
        }
        .navigationTitle(applet.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isLoading {
                    ProgressView()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Text("v\(applet.currentVersion)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - WKWebView Wrapper

private struct AppletWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var error: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, error: $error)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Separate process pool for sandboxing
        config.processPool = WKProcessPool()

        // Preferences
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        // Allow back/forward swipe
        webView.allowsBackForwardNavigationGestures = false

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // URL changes handled by SwiftUI navigation (new view instance)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        @Binding var error: String?

        init(isLoading: Binding<Bool>, error: Binding<String?>) {
            _isLoading = isLoading
            _error = error
        }

        // swiftlint:disable no_force_unwrap_production
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                isLoading = true
                error = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError err: Error) {
            Task { @MainActor in
                isLoading = false
                error = err.localizedDescription
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError err: Error
        ) {
            Task { @MainActor in
                isLoading = false
                error = err.localizedDescription
            }
        }
        // swiftlint:enable no_force_unwrap_production

        /// Block navigation to external URLs — keep everything inside the applet.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // Allow the initial load and same-origin navigations
            if navigationAction.navigationType == .other {
                return .allow
            }

            // Block external link clicks — they'd leave the applet context
            if navigationAction.navigationType == .linkActivated,
               let targetURL = navigationAction.request.url,
               targetURL.host != webView.url?.host {
                await MainActor.run {
                    UIApplication.shared.open(targetURL)
                }
                return .cancel
            }

            return .allow
        }
    }
}
