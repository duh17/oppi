import AppKit
import SwiftUI
import WebKit

/// Host HTML/SVG stay on fetch → `loadHTMLString` + CSP.
/// WKWebView must not URL-load `/files/raw`.
enum MacHTMLPreviewLoadMode: Equatable, Sendable {
    case htmlString
    case none
}

enum MacHTMLPreviewSecurity {
    static let contentSecurityPolicy = "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; img-src data: blob:; media-src data: blob:; font-src data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; child-src 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'"

    @MainActor
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    static func injectContentSecurityPolicy(into html: String) -> String {
        let metaTag = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"

        if let headRange = html.range(of: "<head\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var secured = html
            secured.insert(contentsOf: metaTag, at: headRange.upperBound)
            return secured
        }

        if let htmlRange = html.range(of: "<html\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var secured = html
            secured.insert(contentsOf: "<head>\(metaTag)</head>", at: htmlRange.upperBound)
            return secured
        }

        return "<head>\(metaTag)</head>\(html)"
    }

    static func allowsEmbeddedNavigation(to url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return true }
        return scheme == "about" || scheme == "data" || scheme == "blob"
    }

    static func isHTTPURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func isHostRawFileURL(_ url: URL?) -> Bool {
        guard let url, isHTTPURL(url) else { return false }
        return url.path == "/files/raw" || url.path.hasSuffix("/files/raw")
    }

    static func webViewLoadMode(for path: String) -> MacHTMLPreviewLoadMode {
        switch FileType.detect(from: path) {
        case .html:
            return .htmlString
        case .image where (path as NSString).pathExtension.lowercased() == "svg":
            return .htmlString
        default:
            return .none
        }
    }

    static func usesMarkupPreview(path: String) -> Bool {
        webViewLoadMode(for: path) == .htmlString
    }
}

enum MacMarkupPreviewKind: Equatable, Hashable, Sendable {
    case html
    case svg

    var sourceLanguage: String {
        switch self {
        case .html: "html"
        case .svg: "xml"
        }
    }

    var label: String {
        switch self {
        case .html: "HTML"
        case .svg: "SVG"
        }
    }

    static func from(htmlBlock: String) -> MacMarkupPreviewKind {
        isSVGMarkup(htmlBlock) ? .svg : .html
    }

    static func from(file: ToolContentDescriptor.File) -> MacMarkupPreviewKind? {
        if file.fileType == .html {
            return .html
        }
        if let path = file.filePath, MacHTMLPreviewSecurity.usesMarkupPreview(path: path) {
            return .svg
        }
        return nil
    }

    static func isSVGMarkup(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("<svg") {
            return true
        }
        if trimmed.hasPrefix("<?xml") {
            return trimmed.contains("<svg")
        }
        return false
    }
}

/// Source + preview for HTML blocks, SVG markup, and HTML/SVG files.
/// Not a sheet. Document column stays the reading surface.
struct MacMarkupSourcePreviewView: View {
    private enum Mode: String, Hashable {
        case preview
        case source
    }

    let source: String
    var kind: MacMarkupPreviewKind = .html
    var fillsColumn: Bool = false
    var filePath: String? = nil
    var itemID: String? = nil

    @State private var mode: Mode = .preview
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(kind.label, systemImage: kind == .svg ? "photo" : "globe")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.text.secondary)
                Spacer(minLength: 8)
                Picker("Display", selection: $mode) {
                    Text("Preview").tag(Mode.preview)
                    Text("Source").tag(Mode.source)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                .accessibilityIdentifier(modeAccessibilityIdentifier)
            }

            if mode == .preview {
                // WKWebViewConfiguration is fixed in makeNSView; identity must
                // follow kind so HTML → SVG cannot reuse a JavaScript-on view.
                MacHTMLWebView(html: source, kind: kind)
                    .id(kind)
                    .frame(maxWidth: .infinity, minHeight: fillsColumn ? 240 : 160)
                    .frame(maxHeight: fillsColumn ? .infinity : 400)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.markdown.codeBlockBorder, lineWidth: 1)
                    }
            } else {
                MacCodeOutputPreview(
                    model: MacCodeOutputModel(language: kind.sourceLanguage, text: source),
                    source: MacReviewCommentSource.selectable(
                        filePath: filePath,
                        itemID: itemID
                    )
                )
                    .frame(maxHeight: fillsColumn ? .infinity : 400)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsColumn ? .infinity : nil, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerAccessibilityIdentifier)
    }

    private var containerAccessibilityIdentifier: String {
        if fillsColumn {
            return kind == .svg ? "mac.documentColumn.svg" : "mac.documentColumn.html"
        }
        return kind == .svg ? "markdown.svg" : "markdown.html"
    }

    private var modeAccessibilityIdentifier: String {
        if fillsColumn {
            return kind == .svg ? "mac.documentColumn.svg.mode" : "mac.documentColumn.html.mode"
        }
        return kind == .svg ? "markdown.svg.mode" : "markdown.html.mode"
    }
}

/// SVG preview matches iOS `ImagePreviewWebSecurity`: JS off, embed as `<img>` data URI.
enum MacSVGPreviewSecurity {
    static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; media-src data:"

    @MainActor
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return configuration
    }

    static func htmlDocumentEmbedding(svg: String) -> String {
        let base64 = Data(svg.utf8).base64EncodedString()
        return """
        <!doctype html>
        <html>
        <head>
          <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              overflow: hidden;
              width: 100%;
              height: 100%;
            }
            body {
              display: flex;
              align-items: center;
              justify-content: center;
            }
            img {
              display: block;
              max-width: 100%;
              max-height: 100%;
              width: 100%;
              height: auto;
            }
          </style>
        </head>
        <body>
          <img src="data:image/svg+xml;base64,\(base64)" />
        </body>
        </html>
        """
    }
}

/// WKWebView adapter: `loadHTMLString` only, CSP injected, no `/files/raw` URL loads.
/// HTML keeps inline script. SVG uses `MacSVGPreviewSecurity` instead of the HTML CSP.
struct MacHTMLWebView: NSViewRepresentable {
    let html: String
    var kind: MacMarkupPreviewKind = .html

    func makeCoordinator() -> Coordinator {
        Coordinator(kind: kind)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = kind == .svg
            ? MacSVGPreviewSecurity.makeConfiguration()
            : MacHTMLPreviewSecurity.makeConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = .clear
        context.coordinator.load(html, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.kind = kind
        context.coordinator.load(html, in: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var kind: MacMarkupPreviewKind
        private var loadedHTML: String?

        init(kind: MacMarkupPreviewKind) {
            self.kind = kind
        }

        func load(_ html: String, in webView: WKWebView) {
            let secured = kind == .svg
                ? MacSVGPreviewSecurity.htmlDocumentEmbedding(svg: html)
                : MacHTMLPreviewSecurity.injectContentSecurityPolicy(into: html)
            guard loadedHTML != secured else { return }
            loadedHTML = secured
            webView.loadHTMLString(secured, baseURL: nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if MacHTMLPreviewSecurity.isHostRawFileURL(navigationAction.request.url) {
                decisionHandler(.cancel)
                return
            }
            if MacHTMLPreviewSecurity.allowsEmbeddedNavigation(to: navigationAction.request.url) {
                decisionHandler(.allow)
                return
            }
            if MacHTMLPreviewSecurity.isHTTPURL(navigationAction.request.url),
               navigationAction.navigationType != .other,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if MacHTMLPreviewSecurity.isHostRawFileURL(navigationAction.request.url) {
                return nil
            }
            if MacHTMLPreviewSecurity.isHTTPURL(navigationAction.request.url),
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let html = loadedHTML else { return }
            loadedHTML = nil
            webView.loadHTMLString(html, baseURL: nil)
            loadedHTML = html
        }
    }
}
