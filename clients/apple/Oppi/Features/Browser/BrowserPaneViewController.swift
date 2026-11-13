import UIKit
import WebKit

/// A web page in a pane (`PaneRoute.browser`): a `WKWebView` under the pane's
/// own bar with Back, Forward, Reload (Stop while loading), Share and Open in
/// Safari; the page's title and host name the pane. The pane's grip closes
/// it. `SFSafariViewController` cannot be a pane: Apple allows it only as a
/// modal, which is how a compact window still opens a tapped link.
///
/// - Pages load at once, whoever opened them (owner decision D3). A pane a
///   relaunch brought back opens paused and loads on a tap, so a relaunch
///   never starts every page it left open.
/// - The page never gets Oppi's credentials: no script message handlers, no
///   injected scripts, not inspectable, its own website data store apart
///   from Safari and Oppi's other web views, and no page at a paired
///   server's own origin. Only http and https load; a tapped link to another
///   scheme goes through the app's opener, pop-ups load in this pane, and a
///   file the page cannot show is left to Safari.
/// - A pane nobody sees (overflow, behind a zoom, collapsed) drops its web
///   view `PaneHostController.parkedViewLifetime` later, so web content
///   processes count toward the live-pane cap; it reloads its page when it
///   shows again.
final class BrowserPaneViewController: UIViewController, PaneVisibilityObserving {
    /// The page moved on by itself (a link, a redirect, Back): the leaf's
    /// entry follows, so a relaunch shows this page.
    var onNavigate: ((URL) -> Void)?

    private let root: AppRootEnvironment?
    /// The page the pane shows, or will load when it unpauses.
    private(set) var url: URL
    private(set) var isPaused: Bool
    private(set) var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private let stateView = UIContentUnavailableView(loadState: .loading(nil))
    private var failure: (title: String, message: String)?
    private var parkedRelease: Timer?
    private var isVisible = true

    /// One store for every browser pane, so a sign-in survives a relaunch.
    private static let dataStoreID = UUID(uuidString: "6F1D0B52-0C2E-4C59-9C3E-7A0B5E0D9B11") ?? UUID()

    private lazy var backItem = barItem("chevron.backward", String(localized: "Back"), "browser.back") { $0.webView?.goBack() }
    private lazy var forwardItem = barItem("chevron.forward", String(localized: "Forward"), "browser.forward") { $0.webView?.goForward() }
    private lazy var reloadItem = barItem("arrow.clockwise", String(localized: "Reload"), "browser.reload") { $0.reloadOrStop() }
    private lazy var shareItem = barItem("square.and.arrow.up", String(localized: "Share"), "browser.share") { $0.share() }
    private lazy var safariItem = barItem("safari", String(localized: "Open in Safari"), "browser.openInSafari") {
        $0.root?.opener.open(.system($0.url))
    }

    init(url: URL, paused: Bool, root: AppRootEnvironment?) {
        self.url = url
        self.isPaused = paused
        self.root = root
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItems = [backItem, forwardItem]
        // Right to left. On a narrow bar Share and Open in Safari fold into
        // the system's "…" first, so Reload stays one tap.
        if #available(iOS 27.0, *) {
            shareItem.visibilityPriority = .low
            safariItem.visibilityPriority = .low
        }
        navigationItem.rightBarButtonItems = [safariItem, shareItem, reloadItem]
        updateBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        parkedRelease?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "browser.pane"
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.accessibilityIdentifier = "browser.state"
        stateView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(stateTapped)))
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        if !isPaused { load(url) }
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme changes.
        view.backgroundColor = root?.themeStore.backgroundColor ?? .systemBackground
        updateState()
    }

    // MARK: Loading

    /// Shows `url` here, unpausing the pane.
    func open(_ url: URL) {
        isPaused = false
        load(url)
    }

    private func load(_ url: URL) {
        self.url = url
        failure = nil
        let webView = webView ?? makeWebView()
        webView.load(URLRequest(url: url))
        updateBar()
        view.setNeedsUpdateProperties()
    }

    @objc private func stateTapped() {
        if isPaused { open(url) }
    }

    private func reloadOrStop() {
        guard let webView else { return open(url) }
        if webView.isLoading {
            webView.stopLoading()
        } else if webView.url == nil || failure != nil {
            load(url)
        } else {
            webView.reload()
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.isInspectable = false
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.accessibilityIdentifier = "browser.webView"
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, belowSubview: stateView)
        NSLayoutConstraint.activate([
            // Below the bar: a page's own colours under the glass bar would
            // hide the theme's title.
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        observations = [
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateBar() } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateBar() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateBar() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateBar() } },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.webViewMoved(to: webView.url) }
            },
        ]
        self.webView = webView
        return webView
    }

    private func webViewMoved(to url: URL?) {
        guard let url, PaneWebAddress.isHTTP(url), url != self.url else { return updateBar() }
        self.url = url
        updateBar()
        onNavigate?(url)
    }

    /// Takes the web view and its content process away; the page stays as
    /// the pane's address.
    private func releaseWebView() {
        parkedRelease?.invalidate()
        parkedRelease = nil
        observations = []
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        updateBar()
    }

    // MARK: Visibility

    func paneVisibilityDidChange(_ visibility: PaneVisibility) {
        switch visibility {
        case .visible:
            isVisible = true
            parkedRelease?.invalidate()
            parkedRelease = nil
            if webView == nil, !isPaused, isViewLoaded { load(url) }
        case .covered, .parked:
            isVisible = false
            guard webView != nil, parkedRelease == nil else { return }
            let lifetime = PaneHostController.containing(self)?.parkedViewLifetime ?? 10
            parkedRelease = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseWebView() }
            }
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        if !isVisible { releaseWebView() }
    }

    // MARK: Bar

    private func barItem(
        _ symbol: String, _ title: String, _ identifier: String, action: @escaping (BrowserPaneViewController) -> Void
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(title: title, image: UIImage(systemName: symbol), primaryAction: UIAction(title: title) { [weak self] _ in
            guard let self else { return }
            action(self)
        })
        item.accessibilityIdentifier = identifier
        return item
    }

    private func updateBar() {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        let pageTitle = webView?.title.flatMap { $0.isEmpty ? nil : $0 }
        navigationItem.title = pageTitle ?? host
        navigationItem.subtitle = pageTitle == nil ? nil : host
        backItem.isEnabled = webView?.canGoBack == true
        forwardItem.isEnabled = webView?.canGoForward == true
        let loading = webView?.isLoading == true
        reloadItem.image = UIImage(systemName: loading ? "xmark" : "arrow.clockwise")
        reloadItem.title = loading ? String(localized: "Stop") : String(localized: "Reload")
        reloadItem.accessibilityLabel = reloadItem.title
        // Observed by the pane's grip, which names the pane by its title.
        PaneHostController.containing(self)?.view.setNeedsLayout()
    }

    private func share() {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceItem = shareItem
        Router.topPresenter(from: self).present(activity, animated: true)
    }

    // MARK: State

    private func updateState() {
        let palette = root?.themeStore.activeThemeID.palette ?? ThemeRuntimeState.currentPalette()
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        var config: UIContentUnavailableConfiguration?
        var kind = "page"
        if isPaused {
            kind = "paused"
            config = .loadState(.empty(
                title: host, systemImage: "pause.circle",
                message: String(localized: "This page loads when you tap it.")
            ), palette: palette)
            config?.setProminentButton(String(localized: "Load Page")) { [weak self] in self?.stateTapped() }
        } else if let failure {
            kind = "failed"
            config = .loadState(.failed(
                title: failure.title, message: failure.message,
                retry: RetryAction { [weak self] in self.map { $0.load($0.url) } }
            ), palette: palette)
        }
        stateView.accessibilityValue = kind
        stateView.isHidden = config == nil
        if let config { stateView.configuration = config }
    }

    private func show(failure title: String, _ message: String) {
        failure = (title, message)
        view.setNeedsUpdateProperties()
    }

    /// The paired servers' addresses, as each is reached now and as it was
    /// paired.
    private var serverOrigins: [(host: String, port: Int)] {
        guard let coordinator = root?.coordinator else { return [] }
        let paired = coordinator.serverStore.servers.map { ($0.host, $0.port) }
        let live = coordinator.connections.values.compactMap { $0.credentials.map { ($0.host, $0.port) } }
        return paired + live
    }
}

// MARK: - Navigation policy

extension BrowserPaneViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let target = action.request.url else { return (.cancel, preferences) }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if PaneWebAddress.isHTTP(target) {
            guard !PaneWebAddress.isServerOrigin(target, servers: serverOrigins) else {
                if isMainFrame {
                    show(
                        failure: String(localized: "Oppi Won\u{2019}t Open This Page"),
                        String(localized: "It is a paired Oppi server\u{2019}s own address. Open it in Safari instead.")
                    )
                }
                return (.cancel, preferences)
            }
            return (.allow, preferences)
        }
        let scheme = target.scheme?.lowercased() ?? ""
        if scheme == "about" || (!isMainFrame && (scheme == "data" || scheme == "blob")) {
            return (.allow, preferences)
        }
        // Another scheme (mail, an app, an Oppi link) opens only from a tap,
        // through the opener every other link takes.
        if action.navigationType == .linkActivated {
            root?.opener.open(AppOpenRequest(url: target, origin: .inAppHyperlink))
        }
        return (.cancel, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        guard response.isForMainFrame, !response.canShowMIMEType else { return .allow }
        errorAlerts.show(
            title: String(localized: "Can\u{2019}t Show This File"),
            message: String(localized: "Open the page in Safari to download it.")
        )
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        guard failure != nil else { return }
        failure = nil
        view.setNeedsUpdateProperties()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        failed(error)
    }

    private func failed(_ error: any Error) {
        let error = error as NSError
        // A cancelled load, or one this pane's policy stopped, is not a failure.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        show(failure: String(localized: "Can\u{2019}t Open This Page"), error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if isVisible { webView.reload() }
    }

    /// A `target=_blank` link or `window.open` from a tap loads in this pane.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if action.targetFrame == nil, action.navigationType == .linkActivated {
            webView.load(action.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny
    }
}
