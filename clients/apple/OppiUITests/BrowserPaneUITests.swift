import Network
import XCTest

/// Browser panes in the production shell over the chat-routes fixtures
/// (`SCREENSHOT_SCREEN=pane-restore`) on the iPad mini. The pages come from a
/// server this test runs on the simulator's loopback (`BrowserFixtureServer`),
/// never the internet: a link in the chat opens its page in a pane beside the
/// chat, the launcher opens a typed address, the bar goes back and forward,
/// the grip closes the pane, and a relaunch brings the pane back paused.
@MainActor
final class BrowserPaneUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!
    private var pages: BrowserFixtureServer!

    private let sessionRow = "session.nav.chat-routes-session"

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Pane tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// The iPad mini and this test's page server, which stops with the test.
    private func startPages() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Browser panes need a wide window; the iPad mini is the wide simulator")
        }
        let pages = try BrowserFixtureServer()
        self.pages = pages
        addTeardownBlock { @MainActor in
            pages.stop()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// A link tapped in the chat opens its page in a pane beside the chat in
    /// portrait (the chat at its 375 pt minimum), the chat stays where it
    /// was, and turning to landscape keeps both.
    func testAChatLinkOpensItsPageBesideTheChat() throws {
        try startPages()
        openChat(orientation: .portrait, link: pages.url("one"))
        let link = app.links.matching(NSPredicate(format: "label == 'Open the preview'")).firstMatch
        XCTAssertTrue(link.waitUntilExists(timeout: 10), "The reply shows its link")
        link.tap()

        let pane = app.descendants(matching: .any)["browser.pane"]
        XCTAssertTrue(pane.waitUntilExists(timeout: 10), "The link opened a browser pane")
        XCTAssertTrue(app.webViews.staticTexts["First fixture page"].waitUntilExists(timeout: 15), "The page loaded")
        XCTAssertTrue(app.navigationBars.staticTexts["Page One"].waitUntilExists(timeout: 5), "The bar names the page")
        XCTAssertFalse(app.descendants(matching: .any)["inAppBrowser.view"].exists, "Safari's modal stays closed")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let window = app.windows.firstMatch
            XCTAssertTrue(waitFor((window.frame.width > window.frame.height) == (orientation != .portrait)))
            hold()
            let composer = app.descendants(matching: .any)["chat.input"]
            XCTAssertTrue(composer.isHittable, "The chat stays beside the page")
            XCTAssertLessThanOrEqual(composer.frame.maxX, pane.frame.minX + 1, "The page sits after the chat")
            XCTAssertEqual(pane.frame.maxX, window.frame.maxX, accuracy: 1)
            attachScreenCapture("chat-link-\(orientation == .portrait ? "portrait" : "landscape")")
        }
    }

    /// The launcher's Web Page opens a typed address; Back, Forward and the
    /// grip's Close Pane work on it.
    func testTheLauncherOpensAPageAndTheBarGoesBackAndForward() throws {
        try startPages()
        openChat(orientation: .landscapeLeft)
        openFromLauncher(pages.url("one").absoluteString)
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.staticTexts["First fixture page"].waitUntilExists(timeout: 15), "The typed page loaded")
        let back = app.buttons["browser.back"]
        let forward = app.buttons["browser.forward"]
        XCTAssertFalse(back.isEnabled, "Nothing to go back to yet")

        webView.links["Go to page two"].tap()
        XCTAssertTrue(webView.staticTexts["Second fixture page"].waitUntilExists(timeout: 10), "The link loaded in the pane")
        XCTAssertTrue(app.navigationBars.staticTexts["Page Two"].waitUntilExists(timeout: 5))
        XCTAssertTrue(waitFor(back.isEnabled), "Back is offered after a link")
        attachScreenCapture("launcher-page-two")

        back.tap()
        XCTAssertTrue(webView.staticTexts["First fixture page"].waitUntilExists(timeout: 10), "Back returned to page one")
        XCTAssertTrue(waitFor(forward.isEnabled), "Forward is offered after Back")
        forward.tap()
        XCTAssertTrue(webView.staticTexts["Second fixture page"].waitUntilExists(timeout: 10), "Forward went to page two again")

        let grip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.' AND label ENDSWITH '2 of 2'")).firstMatch
        XCTAssertTrue(grip.waitUntilExists(timeout: 5), "The page's pane has a grip")
        grip.tap()
        let close = app.buttons["Close Pane"]
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "The grip opens the pane menu")
        close.tap()
        let pane = app.descendants(matching: .any)["browser.pane"]
        XCTAssertTrue(waitFor(!pane.exists), "Close Pane closed the page")
        XCTAssertEqual(
            app.collectionViews["chat.timeline"].frame.maxX, app.windows.firstMatch.frame.maxX, accuracy: 2,
            "The chat has the window to itself again"
        )
    }

    /// A relaunch brings the page's pane back paused: nothing loads until a
    /// tap. The address is one that cannot resolve, as no link to this
    /// test's loopback server may be restored (build plan §1.10).
    func testARelaunchBringsThePageBackPausedUntilATap() throws {
        try startPages()
        openChat(orientation: .landscapeLeft)
        openFromLauncher("https://pane-browser.invalid/restored")
        XCTAssertTrue(app.descendants(matching: .any)["browser.pane"].waitUntilExists(timeout: 10))
        // Past the 500 ms settle, so the tree is written before the process dies.
        hold(for: 1.5)

        launchPreview(screen: "pane-restore", environment: [:], ready: nil)
        let state = app.descendants(matching: .any)["browser.state"]
        XCTAssertTrue(state.waitUntilExists(timeout: 15), "The page's pane came back")
        XCTAssertEqual(state.value as? String, "paused", "A restored page waits for a tap")
        let site = app.staticTexts.matching(NSPredicate(format: "label == 'pane-browser.invalid'"))
        XCTAssertGreaterThan(site.count, 0, "The paused pane names the site")
        let webView = app.descendants(matching: .any)["browser.webView"]
        XCTAssertFalse(webView.exists, "Nothing loaded behind it")
        attachScreenCapture("restored-paused")

        app.buttons["Load Page"].tap()
        XCTAssertTrue(waitFor(state.value as? String != "paused", timeout: 10), "A tap loads the page")
        XCTAssertTrue(webView.waitUntilExists(timeout: 5), "The page's web view is back")
    }

    // MARK: Steps

    private func openChat(orientation: UIDeviceOrientation, link: URL? = nil) {
        XCUIDevice.shared.orientation = orientation
        var environment: [String: String] = [:]
        if let link { environment["CHAT_ROUTES_WEB_LINK"] = link.absoluteString }
        launchPreview(screen: "pane-restore", environment: environment, ready: nil)
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].waitUntilExists(timeout: 10), "The chat opened")
    }

    private func openFromLauncher(_ address: String) {
        app.typeKey("d", modifierFlags: .command)
        let web = app.buttons["pane.launcher.web"]
        XCTAssertTrue(web.waitUntilExists(timeout: 5), "⌘D opened the launcher")
        web.tap()
        let field = app.textFields["pane.launcher.web.address"]
        XCTAssertTrue(field.waitUntilExists(timeout: 5), "Web Page asks for the address")
        field.typeText(address)
        // The alert's action shows up twice in the tree (its view and its label).
        app.buttons["pane.launcher.web.open"].firstMatch.tap()
    }

    /// The screen's capture: in landscape `app.screenshot()` draws the iPad
    /// sideways into a portrait canvas.
    private func attachScreenCapture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // A copy for review outside the result bundle, when asked for.
        if let folder = ProcessInfo.processInfo.environment["OPPI_BROWSER_PANE_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(filePath: folder).appending(path: "\(name).png"))
        }
    }
}

/// Two linked pages over HTTP on the simulator's loopback, for as long as the
/// test runs.
final class BrowserFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BrowserFixtureServer")
    let port: UInt16

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.answer(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw XCTSkip("The fixture page server did not start")
        }
        self.port = port
    }

    func url(_ page: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(page)") ?? URL(filePath: "/")
    }

    func stop() { listener.cancel() }

    private static func answer(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let body = page(path)
            let status = body == nil ? "404 Not Found" : "200 OK"
            let bytes = Data((body ?? "").utf8)
            let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func page(_ path: String) -> String? {
        let (title, heading, link): (String, String, String)
        switch path {
        case "/one": (title, heading, link) = ("Page One", "First fixture page", "<a href=\"/two\">Go to page two</a>")
        case "/two": (title, heading, link) = ("Page Two", "Second fixture page", "<a href=\"/one\">Go to page one</a>")
        default: return nil
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>\(title)</title><style>body{font:22px -apple-system;margin:24px}a{display:block;margin-top:24px}</style>
        </head><body><h1>\(heading)</h1><p>A page served by the UI test, on this simulator.</p>\(link)</body></html>
        """
    }
}
