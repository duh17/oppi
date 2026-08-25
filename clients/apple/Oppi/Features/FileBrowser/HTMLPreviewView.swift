import UIKit
import WebKit

// MARK: - HTMLContentTracker

/// Decides when a WKWebView should call `loadHTMLString`.
///
/// Solves two problems:
/// 1. **Deferred first load.** WKWebView renders blank when `loadHTMLString`
///    is called before the view has a window with a non-zero frame. Content
///    is queued until `markReady()` signals the view can render.
/// 2. **Redundant reload suppression.** Same content is not reloaded
///    unless the web content process was terminated.
///
/// Usage from the view:
/// - `setContent(_:)` whenever new HTML arrives (init, updateUIView).
/// - `markReady()` from `didMoveToWindow` + `layoutSubviews` when
///   `window != nil && bounds.width > 0`.
/// - `markNotReady()` when the window goes away.
/// - `markProcessTerminated()` from the WKNavigationDelegate.
///
/// Both `setContent` and `markReady` return the HTML to load (or nil).
/// Whichever fires last with all conditions met triggers the load.
final class HTMLContentTracker {
    private var currentHTML: String?
    private var loadedHash: Int?
    private var forceReload = false
    private(set) var isReady = false

    /// Set desired content. Returns HTML to load now, or nil if deferred/unchanged.
    @discardableResult
    func setContent(_ html: String) -> String? {
        currentHTML = html
        return evaluateLoad()
    }

    /// Mark the view as render-ready (window + non-zero frame).
    /// Returns pending content to load, or nil.
    @discardableResult
    func markReady() -> String? {
        isReady = true
        return evaluateLoad()
    }

    /// Mark the view as not ready (removed from window).
    func markNotReady() {
        isReady = false
    }

    /// Forget the loaded HTML while preserving render readiness.
    ///
    /// Use when the owning view changes identity and will wait for a fresh
    /// navigation completion before revealing the web view, even if the next
    /// HTML bytes match the prior load.
    func resetLoadedContent() {
        currentHTML = nil
        loadedHash = nil
        forceReload = false
    }

    /// Force the next evaluation to return content, even if hash matches.
    func markProcessTerminated() {
        forceReload = true
    }

    private func evaluateLoad() -> String? {
        guard isReady, let html = currentHTML else { return nil }
        let hash = html.hashValue
        guard forceReload || hash != loadedHash else { return nil }
        loadedHash = hash
        forceReload = false
        return html
    }
}

// MARK: - HTML Security

enum HTMLContentSecurity {
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
}

enum HostFilePreviewWebViewLoadMode: Equatable {
    case htmlString
    case none
}

/// Host HTML/SVG must stay on fetch -> `loadHTMLString` + CSP.
/// Direct WKWebView URL loads of `/files/raw` are forbidden.
enum HostFilePreviewPolicy {
    static func usesStringFetchViewer(for path: String) -> Bool {
        webViewLoadMode(for: path) == .htmlString
    }

    static func webViewLoadMode(for path: String) -> HostFilePreviewWebViewLoadMode {
        switch FileType.detect(from: path) {
        case .html:
            return .htmlString
        case .image where (path as NSString).pathExtension.lowercased() == "svg":
            return .htmlString
        default:
            return .none
        }
    }
}

// MARK: - HTMLRenderView

/// Single canonical UIView for rendering HTML strings via WKWebView.
///
/// Used directly by UIKit callers. All WKWebView configuration, navigation
/// blocking, popup blocking, and process termination recovery live here — no
/// duplication.
///
/// Defers `loadHTMLString` until the view has a window AND a non-zero frame.
/// Checks both `didMoveToWindow` and `layoutSubviews` — whichever fires last
/// with all conditions met triggers the load.
final class HTMLRenderView: UIView, WKNavigationDelegate, FullScreenReaderConfigurable {
    private let webView: ReviewCommentWKWebView
    private let contentTracker = HTMLContentTracker()
    private(set) var isRenderReady = false
    var onRenderStateChange: (() -> Void)?

    init(htmlString: String, reviewCommentHandler: ((String, UIViewController?) -> Void)? = nil) {
        let wv = ReviewCommentWKWebView(frame: .zero, configuration: HTMLContentSecurity.makeConfiguration())
        wv.isInspectable = false
        wv.allowsBackForwardNavigationGestures = false
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.reviewCommentHandler = reviewCommentHandler
        self.webView = wv

        super.init(frame: .zero)

        configureWebView(htmlString: htmlString)
    }

    init(
        htmlString: String,
        reviewCommentRouter: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        let wv = ReviewCommentWKWebView(frame: .zero, configuration: HTMLContentSecurity.makeConfiguration())
        wv.isInspectable = false
        wv.allowsBackForwardNavigationGestures = false
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.configureReviewCommentRouter(reviewCommentRouter, sourceContext: sourceContext)
        self.webView = wv

        super.init(frame: .zero)

        configureWebView(htmlString: htmlString)
    }

    private func configureWebView(htmlString: String) {
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Queue for loading — will fire when view is ready
        contentTracker.setContent(HTMLContentSecurity.injectContentSecurityPolicy(into: htmlString))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - View lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            flushIfReady()
        } else {
            contentTracker.markNotReady()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        flushIfReady()
    }

    // MARK: - Content updates

    /// Load new HTML content. Loads immediately if ready, otherwise deferred.
    func load(_ htmlString: String) {
        if let html = contentTracker.setContent(HTMLContentSecurity.injectContentSecurityPolicy(into: htmlString)) {
            setRenderReady(false)
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        webView.pageZoom = preferences.textScale
    }

    /// Update the review comment handler (e.g., when SwiftUI re-renders).
    func updateReviewCommentHandler(_ handler: ((String, UIViewController?) -> Void)?) {
        webView.reviewCommentHandler = handler
    }

    func snapshotRenderedImage() async throws -> UIImage {
        guard isRenderReady else {
            throw PaperMarkupCanvasSession.SnapshotError.notReady
        }
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                continuation.resume(with: PaperMarkupCanvasSession.renderedSnapshot(image: image, error: error))
            }
        }
    }

    func markRenderReadyForTesting() {
        setRenderReady(true)
    }

    private func setRenderReady(_ ready: Bool) {
        guard isRenderReady != ready else { return }
        isRenderReady = ready
        onRenderStateChange?()
    }

    // MARK: - Private

    private func flushIfReady() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if let html = contentTracker.markReady() {
            setRenderReady(false)
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setRenderReady(true)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if HTMLContentSecurity.isHostRawFileURL(navigationAction.request.url) {
            decisionHandler(.cancel)
            return
        }
        if HTMLContentSecurity.allowsEmbeddedNavigation(to: navigationAction.request.url) {
            decisionHandler(.allow)
            return
        }
        if HTMLContentSecurity.isHTTPURL(navigationAction.request.url),
           navigationAction.navigationType != .other,
           let url = navigationAction.request.url {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if HTMLContentSecurity.isHostRawFileURL(navigationAction.request.url) {
            return nil
        }
        if HTMLContentSecurity.isHTTPURL(navigationAction.request.url),
           let url = navigationAction.request.url {
            UIApplication.shared.open(url)
        }
        return nil
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        setRenderReady(false)
        contentTracker.markProcessTerminated()
        flushIfReady()
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        setRenderReady(false)
        contentTracker.markProcessTerminated()
        flushIfReady()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setRenderReady(false)
        contentTracker.markProcessTerminated()
        flushIfReady()
    }
}
