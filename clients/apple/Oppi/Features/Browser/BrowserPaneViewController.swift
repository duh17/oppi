import UIKit
import WebKit

/// A web page in a pane (`PaneRoute.browser`): a `WKWebView` under the pane's
/// own bar, laid out as Safari's on iPad: Back and Forward, the address field
/// (`BrowserAddressField`, with Reload or Stop in it), then Share and Open in
/// Safari, which fold into a … menu in a narrow pane. The page's title names
/// the pane (its grip). The grip closes it. `SFSafariViewController` cannot
/// be a pane: Apple allows it only as a modal, which is how a compact window
/// still opens a tapped link.
///
/// - The launcher's Web Page opens it with no page and the address field up
///   (`PaneLocalScreen.browser`); the first page it loads becomes the leaf's
///   entry, as every page it moves to does.
/// - An address typed into the field loads where it was typed: only http
///   and https with a host (`PaneTypedAddress`). Without a scheme it loads
///   over https, and once over http if the secure connection fails or
///   nothing answers on it, as Safari's field does; the field then shows
///   the page is not secure. The navigation policy below still refuses a
///   paired server's own origin, on either scheme.
///
/// - Pages load at once, whoever opened them (owner decision D3). A pane a
///   relaunch brought back opens paused and loads on a tap, so a relaunch
///   never starts every page it left open.
/// - The page never gets Oppi's credentials: no script message handlers, no
///   injected scripts, not inspectable, its own website data store apart
///   from Safari and Oppi's other web views, and no page at a paired
///   server's own origin except a Godot web build's signed play link
///   (`PaneWebAddress.refusesServerPage`), which carries its own access to
///   that one build. Only http and https load; a tapped link to another
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

    /// Below this width Share and Open in Safari fold into one … menu, so
    /// the address field keeps room in a 375 pt pane.
    static let foldedBarWidth: CGFloat = 500

    private let root: AppRootEnvironment?
    /// The page the pane shows, or will load when it unpauses; nil while it
    /// waits for its first address.
    private(set) var url: URL?
    private(set) var isPaused: Bool
    private(set) var webView: WKWebView?
    let addressField = BrowserAddressField()
    private var observations: [NSKeyValueObservation] = []
    private let stateView = UIContentUnavailableView(loadState: .loading(nil))
    private var failure: (title: String, message: String)?
    /// The address the person typed, while its load has not begun to arrive:
    /// it may move from https to http once. Cleared by the first byte of any
    /// page and by every other way of loading one.
    private var typedAddress: PaneTypedAddress?
    private var parkedRelease: Timer?
    private var isVisible = true
    /// A pane opened with no page puts its field up once, as it appears.
    private var editsAddressOnAppear: Bool
    private var isBarFolded: Bool?
    /// Whether the … menu was last built with a page to act on.
    private var menuHasPage: Bool?

    /// One store for every browser pane, so a sign-in survives a relaunch.
    private static let dataStoreID = UUID(uuidString: "6F1D0B52-0C2E-4C59-9C3E-7A0B5E0D9B11") ?? UUID()

    private lazy var backItem = barItem("chevron.backward", String(localized: "Back"), "browser.back") { $0.webView?.goBack() }
    private lazy var forwardItem = barItem("chevron.forward", String(localized: "Forward"), "browser.forward") { $0.webView?.goForward() }
    private lazy var shareItem = barItem("square.and.arrow.up", String(localized: "Share"), "browser.share") { $0.share() }
    private lazy var safariItem = barItem("safari", String(localized: "Open in Safari"), "browser.openInSafari") {
        $0.openInSafari()
    }
    /// Share and Open in Safari in a narrow pane.
    private lazy var moreItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: String(localized: "More"), image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: moreActions(hasPage: url != nil))
        )
        item.accessibilityIdentifier = "browser.more"
        return item
    }()
    private lazy var cancelItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.addressField.cancelEditing()
        })
        item.accessibilityIdentifier = "browser.address.cancel"
        return item
    }()

    /// `url` nil opens the pane waiting for an address, its field up.
    init(url: URL?, paused: Bool, root: AppRootEnvironment?) {
        self.url = url
        self.isPaused = paused && url != nil
        self.editsAddressOnAppear = url == nil
        self.root = root
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItems = [backItem, forwardItem]
        navigationItem.titleView = addressField
        addressField.onSubmit = { [weak self] text in self?.submit(text) ?? true }
        addressField.onEditingChanged = { [weak self] _ in self?.updateTrailingItems() }
        addressField.onReloadOrStop = { [weak self] in self?.reloadOrStop() }
        updateTrailingItems()
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
        if !isPaused, let url { load(url) }
    }

    /// The bar has placed the field in the window by now, so it can take
    /// the keyboard.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard editsAddressOnAppear else { return }
        editsAddressOnAppear = false
        addressField.beginEditing()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let folded = view.bounds.width < Self.foldedBarWidth
        guard folded != isBarFolded else { return }
        isBarFolded = folded
        updateTrailingItems()
    }

    /// Cancel while the address is edited; else Share and Open in Safari,
    /// or their … menu in a narrow pane.
    private func updateTrailingItems() {
        let items: [UIBarButtonItem] = if addressField.isEditing {
            [cancelItem]
        } else if isBarFolded == true {
            [moreItem]
        } else {
            [safariItem, shareItem]
        }
        guard navigationItem.rightBarButtonItems != items else { return }
        navigationItem.rightBarButtonItems = items
    }

    /// Share and Open in Safari, shown unavailable until the pane has a page.
    private func moreActions(hasPage: Bool) -> [UIMenuElement] {
        let attributes: UIMenuElement.Attributes = hasPage ? [] : .disabled
        return [
            UIAction(title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up"), attributes: attributes) { [weak self] _ in
                self?.share()
            },
            UIAction(title: String(localized: "Open in Safari"), image: UIImage(systemName: "safari"), attributes: attributes) { [weak self] _ in
                self?.openInSafari()
            },
        ]
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme changes.
        view.backgroundColor = root?.themeStore.backgroundColor ?? .systemBackground
        updateState()
    }

    // MARK: Loading

    /// Shows `url` here, unpausing the pane, and makes it the leaf's entry.
    func open(_ url: URL) {
        isPaused = false
        typedAddress = nil
        load(url)
        onNavigate?(url)
    }

    /// Go in the address field: the typed address loads, or the field stays
    /// up and says why it cannot.
    private func submit(_ text: String) -> Bool {
        guard let typed = PaneTypedAddress(text) else {
            errorAlerts.show(
                title: String(localized: "Can’t Open This Address"),
                message: String(localized: "Enter a web address, such as example.com or https://example.com.")
            )
            return false
        }
        open(typed.url)
        typedAddress = typed
        return true
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
        if isPaused, let url { open(url) }
        if url == nil { addressField.beginEditing() }
    }

    private func reloadOrStop() {
        guard let url else { return }
        guard let webView else { return open(url) }
        if webView.isLoading {
            webView.stopLoading()
        } else if webView.url == nil || failure != nil {
            loadAgain(url)
        } else {
            webView.reload()
        }
    }

    /// Loads the page again after it failed. A typed address that went on to
    /// http starts over from its first load, so a server that now has https
    /// gets it.
    private func loadAgain(_ url: URL) {
        guard var typed = typedAddress, typed.triedInsecure else { return load(url) }
        let first = typed.restart()
        typedAddress = typed
        load(first)
        onNavigate?(first)
    }

    private func openInSafari() {
        guard let url else { return }
        root?.opener.open(.system(url))
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Not `ReviewCommentWKWebView`: a web page is no workspace source to
        // comment on, and its Comment action would run script in the page.
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
            if webView == nil, !isPaused, isViewLoaded, let url { load(url) }
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
        let host = url.map(BrowserAddressField.idleText)
        let pageTitle = webView?.title.flatMap { $0.isEmpty ? nil : $0 }
        // The pane's name for its grip and VoiceOver; the bar shows the field.
        navigationItem.title = pageTitle ?? host ?? String(localized: "Web Page")
        backItem.isEnabled = webView?.canGoBack == true
        forwardItem.isEnabled = webView?.canGoForward == true
        shareItem.isEnabled = url != nil
        safariItem.isEnabled = url != nil
        // Only when it changes: a menu replaced while open would close.
        if menuHasPage != (url != nil) {
            menuHasPage = url != nil
            moreItem.menu = UIMenu(children: moreActions(hasPage: url != nil))
        }
        addressField.show(address: url, loading: webView?.isLoading == true)
        // Observed by the pane's grip, which names the pane by its title.
        PaneHostController.containing(self)?.view.setNeedsLayout()
    }

    private func share() {
        guard let url else { return }
        FileSharePresenter.share(link: url, from: self, sourceItem: isBarFolded == true ? moreItem : shareItem)
    }

    // MARK: State

    private func updateState() {
        let palette = root?.themeStore.activeThemeID.palette ?? ThemeRuntimeState.currentPalette()
        let host = url.map { $0.host(percentEncoded: false) ?? $0.absoluteString } ?? ""
        var config: UIContentUnavailableConfiguration?
        var kind = "page"
        if url == nil {
            kind = "empty"
            config = .loadState(.empty(
                title: String(localized: "Web Page"), systemImage: "safari",
                message: String(localized: "Type an address above, such as example.com.")
            ), palette: palette)
        } else if isPaused {
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
                retry: RetryAction { [weak self] in
                    guard let self, let url = self.url else { return }
                    self.loadAgain(url)
                }
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
            guard !PaneWebAddress.refusesServerPage(
                target,
                method: action.request.httpMethod ?? "GET",
                servers: serverOrigins
            ) else {
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
            root?.opener.open(AppOpenRequest(url: target, origin: .link))
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

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        typedAddress = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        failed(error, beforeCommit: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        failed(error, beforeCommit: false)
    }

    private func failed(_ error: any Error, beforeCommit: Bool) {
        let error = error as NSError
        // A cancelled load, or one this pane's policy stopped, is not a failure.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        // An address typed with no scheme that could not be reached over
        // https goes once to http, as Safari's field does.
        if beforeCommit, var typed = typedAddress, let retry = typed.retry(after: error) {
            typedAddress = typed
            load(retry)
            onNavigate?(retry)
            return
        }
        let failing = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        let secureFailure = typedAddress?.secureError
        let host = failing?.host(percentEncoded: false)
        if PaneTypedAddress.isSecureConnectionError(error) {
            show(failure: Self.certificateTitle, Self.certificateMessage(host: host, triedHTTP: secureFailure != nil))
        } else if let secureFailure, PaneTypedAddress.isSecureConnectionError(secureFailure) {
            // The certificate says more than a refusal on the http port.
            let secureHost = (secureFailure.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host(percentEncoded: false) ?? host
            show(failure: Self.certificateTitle, Self.certificateMessage(host: secureHost, triedHTTP: true))
        } else if secureFailure != nil {
            show(failure: String(localized: "Can\u{2019}t Open This Page"), Self.bothFailedMessage(error))
        } else {
            show(failure: String(localized: "Can\u{2019}t Open This Page"), error.localizedDescription)
        }
    }

    static var certificateTitle: String { String(localized: "Can\u{2019}t Open This Page Securely") }

    /// What a failed secure connection to `host` means and what to try. A
    /// short machine name (`mac-mini`) is the usual cause: a tailnet's HTTPS
    /// certificate names the full name, so the short one fails the check.
    /// `triedHTTP`: an address typed with no scheme was also tried over http,
    /// which did not open either, so that is no longer a thing to try. The
    /// pane never bypasses the check.
    static func certificateMessage(host: String?, triedHTTP: Bool) -> String {
        let name = host ?? String(localized: "This site")
        var message = String(localized: "\(name) didn\u{2019}t offer a secure connection this device trusts: its certificate is for another name, or isn\u{2019}t trusted. Oppi doesn\u{2019}t skip that check.")
        if triedHTTP { message += " " + String(localized: "Oppi also tried http://, which didn\u{2019}t open either.") }
        guard let host, !host.contains("."), !host.contains(":") else { return message }
        let hint = triedHTTP
            ? String(localized: "Try the full name its certificate is for, such as \(host).your-tailnet.ts.net on Tailscale.")
            : String(localized: "Try the full name its certificate is for, such as \(host).your-tailnet.ts.net on Tailscale, or http:// if it doesn\u{2019}t use HTTPS.")
        return message + " " + hint
    }

    /// An address typed with no scheme failed over https and then over http.
    static func bothFailedMessage(_ error: NSError) -> String {
        error.localizedDescription + " " + String(localized: "Oppi tried https:// and then http://.")
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
