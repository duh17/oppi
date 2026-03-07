import OSLog
import SwiftUI
import UIKit
import WebKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "AppletViewer")

/// Full-screen viewer for an applet.
///
/// Fetches HTML via APIClient (which handles TLS pinning), then loads
/// into WKWebView via `loadHTMLString`. A JS bridge (`window.oppi`)
/// lets applets make authenticated API calls back to the server
/// through the native networking layer.
struct AppletViewerView: View {
    let applet: Applet

    @Environment(ServerConnection.self) private var connection
    @State private var html: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let html, let api = connection.apiClient {
                AppletWebView(
                    html: html,
                    apiClient: api,
                    context: AppletBridgeContext(
                        workspaceId: applet.workspaceId,
                        appletId: applet.id,
                        appletVersion: applet.currentVersion
                    )
                )
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
    }
}

// MARK: - Bridge Context

struct AppletBridgeContext {
    let workspaceId: String
    let appletId: String
    let appletVersion: Int

    var workspacePathPrefix: String {
        "/workspaces/\(workspaceId)"
    }
}

// MARK: - WKWebView Wrapper

private enum AppletBridgeJavaScript {
    static func stringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2
        else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }
}

private struct AppletWebView: UIViewRepresentable {
    let html: String
    let apiClient: APIClient
    let context: AppletBridgeContext

    func makeCoordinator() -> AppletBridgeCoordinator {
        AppletBridgeCoordinator(apiClient: apiClient, context: context)
    }

    func makeUIView(context ctx: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Register the JS→Swift message handler
        let coordinator = ctx.coordinator
        config.userContentController.add(coordinator, name: "oppiBridge")

        // Inject the bridge JS before any page scripts run
        let bridgeScript = WKUserScript(
            source: Self.bridgeJavaScript(context: context),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(bridgeScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
#if DEBUG
        webView.isInspectable = true
#endif
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        coordinator.webView = webView
        webView.loadHTMLString(Self.injectCSPIfMissing(html), baseURL: nil)
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    /// The JavaScript that creates `window.oppi` — injected at document start.
    private static func bridgeJavaScript(context: AppletBridgeContext) -> String {
        """
        (function() {
          'use strict';

          // Pending request callbacks keyed by request ID
          const _pending = Object.create(null);
          let _nextId = 1;

          window.oppi = {
            // Static context about this applet
            context: Object.freeze({
              workspaceId: \(AppletBridgeJavaScript.stringLiteral(context.workspaceId)),
              appletId: \(AppletBridgeJavaScript.stringLiteral(context.appletId)),
              appletVersion: \(context.appletVersion)
            }),

            /**
             * Make an authenticated API request to the Oppi server.
             *
             * @param {string} path - API path (workspace-scoped, starts with '/').
             * @param {object} [options] - { method: 'GET', body: object }
             * @returns {Promise<{status: number, data: any}>}
             */
            fetch(path, options) {
              return new Promise((resolve, reject) => {
                const id = String(_nextId++);
                _pending[id] = { resolve, reject };

                const msg = {
                  id: id,
                  type: 'fetch',
                  path: path,
                  method: (options && options.method) || 'GET',
                  body: (options && options.body) || null
                };

                try {
                  window.webkit.messageHandlers.oppiBridge.postMessage(msg);
                } catch (e) {
                  delete _pending[id];
                  reject(new Error('Bridge not available: ' + e.message));
                }
              });
            },

            // Called by native code to deliver responses
            _resolve(id, status, data) {
              const p = _pending[id];
              if (p) {
                delete _pending[id];
                p.resolve({ status: status, data: data });
              }
            },

            _reject(id, error) {
              const p = _pending[id];
              if (p) {
                delete _pending[id];
                p.reject(new Error(error));
              }
            }
          };
        })();
        """
    }

    /// `loadHTMLString` bypasses server response headers. Inject a baseline CSP
    /// unless the applet already declares one in a meta tag.
    private static func injectCSPIfMissing(_ html: String) -> String {
        if html.range(of: "content-security-policy", options: .caseInsensitive) != nil {
            return html
        }

        let csp = [
            "default-src 'self' 'unsafe-inline' 'unsafe-eval'",
            "https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com https://esm.sh",
            "data: blob:;",
            "img-src 'self' data: blob: https:;",
            "font-src 'self' data: https://cdnjs.cloudflare.com https://cdn.jsdelivr.net",
            "https://fonts.gstatic.com;",
        ].joined(separator: " ")
        let tag = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"

        if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: headRange, with: "<head>\n\(tag)")
        }

        return "<head>\n\(tag)\n</head>\n\(html)"
    }
}

// MARK: - Bridge Coordinator

/// Handles JS→Swift messages from the applet bridge and dispatches
/// authenticated API calls through the native APIClient.
final class AppletBridgeCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let apiClient: APIClient
    private let context: AppletBridgeContext

    weak var webView: WKWebView?

    init(apiClient: APIClient, context: AppletBridgeContext) {
        self.apiClient = apiClient
        self.context = context
        super.init()
    }

    func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "oppiBridge" else { return }
        guard message.frameInfo.isMainFrame else {
            logger.error("Bridge: rejected non-main-frame message")
            return
        }

        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let type = body["type"] as? String
        else {
            logger.error("Bridge: malformed message")
            return
        }

        switch type {
        case "fetch":
            handleFetch(id: id, body: body)
        default:
            rejectRequest(id: id, error: "Unknown message type: \(type)")
        }
    }

    private func handleFetch(id: String, body: [String: Any]) {
        guard let rawPath = body["path"] as? String else {
            rejectRequest(id: id, error: "Missing path")
            return
        }

        guard let path = sanitizeBridgePath(rawPath) else {
            rejectRequest(id: id, error: "Invalid path")
            return
        }

        guard isPathAllowed(path) else {
            rejectRequest(id: id, error: "Path outside applet workspace scope")
            return
        }

        let method = (body["method"] as? String) ?? "GET"
        let requestBody = body["body"]

        Task {
            do {
                let data = try await performRequest(method: method, path: path, body: requestBody)
                let json = try JSONSerialization.jsonObject(with: data)
                resolveRequest(id: id, status: 200, data: json)
            } catch let apiError as APIError {
                switch apiError {
                case .server(let status, let message):
                    resolveRequest(id: id, status: status, data: ["error": message])
                case .invalidResponse:
                    rejectRequestAsync(id: id, error: "Invalid response")
                }
            } catch {
                rejectRequestAsync(id: id, error: error.localizedDescription)
            }
        }
    }

    private func sanitizeBridgePath(_ raw: String) -> String? {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else { return nil }
        guard !path.hasPrefix("//") else { return nil }
        guard !path.contains("://") else { return nil }
        guard !routePath(for: path).contains("..") else { return nil }
        return path
    }

    private func isPathAllowed(_ path: String) -> Bool {
        let routePath = routePath(for: path)
        return routePath == context.workspacePathPrefix || routePath.hasPrefix(context.workspacePathPrefix + "/")
    }

    private func routePath(for path: String) -> String {
        String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    private func performRequest(method: String, path: String, body: Any?) async throws -> Data {
        switch method.uppercased() {
        case "GET":
            return try await apiClient.bridgeGet(path)
        case "POST":
            return try await apiClient.bridgePost(path, body: try encodeBody(body))
        case "PUT":
            return try await apiClient.bridgePut(path, body: try encodeBody(body))
        case "DELETE":
            return try await apiClient.bridgeDelete(path)
        default:
            throw APIError.server(status: 405, message: "Method not allowed: \(method)")
        }
    }

    private func encodeBody(_ body: Any?) throws -> Data {
        guard let body else { return Data() }
        guard JSONSerialization.isValidJSONObject(body) else {
            throw APIError.server(status: 400, message: "Body must be valid JSON")
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        if data.count > 256_000 {
            throw APIError.server(status: 413, message: "Body too large")
        }

        return data
    }

    // MARK: - Navigation

    @MainActor
    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame {
            let scheme = url.scheme?.lowercased() ?? ""
            let isInternalScheme = scheme == "about" || scheme == "data" || scheme == "blob"
            if !isInternalScheme {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }

    // MARK: - JS Callbacks

    @MainActor
    private func resolveRequest(id: String, status: Int, data: Any) {
        guard let webView else { return }
        let jsonData = (try? JSONSerialization.data(withJSONObject: data)) ?? Data("null".utf8)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "null"
        let js = "window.oppi._resolve(\(AppletBridgeJavaScript.stringLiteral(id)), \(status), \(jsonString));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                logger.error("Bridge resolve error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func rejectRequest(id: String, error: String) {
        Task { @MainActor in
            rejectRequestAsync(id: id, error: error)
        }
    }

    @MainActor
    private func rejectRequestAsync(id: String, error: String) {
        guard let webView else { return }
        let js = "window.oppi._reject(\(AppletBridgeJavaScript.stringLiteral(id)), \(AppletBridgeJavaScript.stringLiteral(error)));"
        webView.evaluateJavaScript(js) { _, err in
            if let err {
                logger.error("Bridge reject error: \(err.localizedDescription, privacy: .public)")
            }
        }
    }

}
