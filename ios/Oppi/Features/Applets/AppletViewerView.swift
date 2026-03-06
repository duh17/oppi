import SwiftUI
import WebKit

/// Full-screen viewer for an applet.
///
/// Fetches HTML via APIClient (which handles TLS pinning), then loads
/// into WKWebView via `loadHTMLString`. No network from WKWebView to
/// the server — CDN resources load normally since they're public HTTPS.
struct AppletViewerView: View {
    let applet: Applet

    @Environment(ServerConnection.self) private var connection
    @State private var html: String?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if let html {
                AppletWebView(html: html)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error {
                ContentUnavailableView(
                    "Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ProgressView("Loading applet...")
            }
        }
        .navigationTitle(applet.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text("v\(applet.currentVersion)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await loadHTML()
        }
    }

    private func loadHTML() async {
        guard let api = connection.apiClient else {
            error = "Not connected"
            isLoading = false
            return
        }

        do {
            let (_, version) = try await api.getApplet(
                workspaceId: applet.workspaceId,
                appletId: applet.id
            )
            if let version {
                html = version.html
            } else {
                error = "No version available"
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - WKWebView Wrapper

private struct AppletWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}
}
