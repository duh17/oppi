import SwiftUI
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

// MARK: - HTMLRenderView

/// Single canonical UIView for rendering HTML strings via WKWebView.
///
/// Used directly by UIKit callers (FullScreenCodeViewController) and wrapped
/// by ``HTMLWebView`` for SwiftUI embedding. All WKWebView configuration,
/// navigation blocking, popup blocking, and process termination recovery
/// live here — no duplication.
///
/// Defers `loadHTMLString` until the view has a window AND a non-zero frame.
/// Checks both `didMoveToWindow` and `layoutSubviews` — whichever fires last
/// with all conditions met triggers the load.
final class HTMLRenderView: UIView, WKNavigationDelegate {
    private let webView: PiWKWebView
    private let contentTracker = HTMLContentTracker()

    init(htmlString: String, piActionHandler: ((String, PiQuickAction) -> Void)? = nil) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all

        let wv = PiWKWebView(frame: .zero, configuration: config)
        wv.isInspectable = false
        wv.allowsBackForwardNavigationGestures = false
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.piActionHandler = piActionHandler
        self.webView = wv

        super.init(frame: .zero)

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
        contentTracker.setContent(htmlString)
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
        if let html = contentTracker.setContent(htmlString) {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Update the pi action handler (e.g., when SwiftUI re-renders).
    func updatePiActionHandler(_ handler: ((String, PiQuickAction) -> Void)?) {
        webView.piActionHandler = handler
    }

    // MARK: - Private

    private func flushIfReady() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if let html = contentTracker.markReady() {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .other {
            decisionHandler(.allow)
            return
        }
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
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
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            UIApplication.shared.open(url)
        }
        return nil
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        contentTracker.markProcessTerminated()
        flushIfReady()
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        contentTracker.markProcessTerminated()
        flushIfReady()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        contentTracker.markProcessTerminated()
        flushIfReady()
    }
}

// MARK: - HTMLWebView (SwiftUI wrapper)

/// SwiftUI wrapper around ``HTMLRenderView``.
///
/// Thin UIViewRepresentable — all WKWebView logic lives in HTMLRenderView.
struct HTMLWebView: UIViewRepresentable {
    let htmlString: String
    let baseFileName: String
    var piActionHandler: ((String, PiQuickAction) -> Void)?

    func makeUIView(context: Context) -> HTMLRenderView {
        HTMLRenderView(htmlString: htmlString, piActionHandler: piActionHandler)
    }

    func updateUIView(_ view: HTMLRenderView, context: Context) {
        view.updatePiActionHandler(piActionHandler)
        view.load(htmlString)
    }
}
