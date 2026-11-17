import Network
import XCTest

/// Browser panes in the production shell over the chat-routes fixtures
/// (`SCREENSHOT_SCREEN=pane-restore`) on the iPad mini. The pages come from a
/// server this test runs on the simulator's loopback (`BrowserFixtureServer`),
/// never the internet: a link in the chat opens its page in a pane beside the
/// chat, the launcher's Web Page opens the browser with its address field up
/// (also in a short lower pane in portrait), the address field shows the host
/// and edits the whole address (a bare one tries https, then http), the bar
/// goes back and forward, the grip closes the pane, and a relaunch brings
/// the pane back paused.
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

    /// A link tapped in the chat opens its page in a pane below the chat in
    /// portrait, where a tall window has its room, the chat stays where it
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
        XCTAssertTrue(paneGrip(named: "Page One").waitUntilExists(timeout: 5), "The grip names the page")
        XCTAssertEqual(app.textFields["browser.address"].value as? String, pages.host, "The address field shows the host")
        XCTAssertFalse(app.descendants(matching: .any)["inAppBrowser.view"].exists, "Safari's modal stays closed")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let window = app.windows.firstMatch
            XCTAssertTrue(waitFor((window.frame.width > window.frame.height) == (orientation != .portrait)))
            hold()
            let composer = app.descendants(matching: .any)["chat.input"]
            XCTAssertTrue(composer.isHittable, "The chat stays above the page")
            XCTAssertLessThanOrEqual(composer.frame.maxY, pane.frame.minY + 1, "The page sits below the chat")
            XCTAssertEqual(pane.frame.maxX, window.frame.maxX, accuracy: 1)
            attachScreenCapture("chat-link-\(orientation == .portrait ? "portrait" : "landscape")")
        }
    }

    /// The owner's report: a link tapped after panes changed did nothing. In
    /// portrait, each tap leaves the page open on screen below the chat:
    /// after Close Pane and its Undo, with the page's pane folded to its
    /// strip, and on the second line of a bare address that wraps.
    func testEveryWebLinkTapLeavesThePageOnScreen() throws {
        try startPages()
        openChat(orientation: .portrait, link: pages.url("one"), colorScheme: "dark")
        let named = app.links.matching(NSPredicate(format: "label == 'Open the preview'")).firstMatch
        let bare = app.links.matching(NSPredicate(format: "label CONTAINS 'ref=magic-keyboard'")).firstMatch
        let pane = app.descendants(matching: .any)["browser.pane"]
        let composer = app.descendants(matching: .any)["chat.input"]
        let window = app.windows.firstMatch
        func assertPageOnScreen(_ step: String) {
            XCTAssertTrue(app.webViews.staticTexts["First fixture page"].waitUntilExists(timeout: 15), "\(step): the page loaded")
            XCTAssertTrue(waitFor(pane.exists && pane.frame.height > 200), "\(step): its pane is open, not a strip")
            XCTAssertGreaterThanOrEqual(pane.frame.minY, composer.frame.maxY - 1, "\(step): below the chat")
            XCTAssertFalse(app.descendants(matching: .any)["inAppBrowser.view"].exists, "\(step): no Safari sheet")
        }
        func closePagePane() {
            let grip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.' AND label ENDSWITH '2 of 2'")).firstMatch
            XCTAssertTrue(grip.waitUntilExists(timeout: 5), "The page's pane has a grip")
            grip.tap()
            let close = app.buttons["Close Pane"]
            XCTAssertTrue(close.waitUntilExists(timeout: 5), "The grip opens the pane menu")
            close.tap()
            XCTAssertTrue(waitFor(!pane.exists), "Close Pane closed the page")
        }

        XCTAssertTrue(bare.waitUntilExists(timeout: 10), "The reply shows the bare address")
        XCTAssertGreaterThan(bare.frame.height, 30, "The bare address wraps")
        bare.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.85)).tap()
        assertPageOnScreen("Second line of a wrapped address")

        closePagePane()
        let undo = app.buttons["pane.undo"]
        XCTAssertTrue(undo.waitUntilExists(timeout: 5), "The toast offers Undo")
        undo.tap()
        XCTAssertTrue(pane.waitUntilExists(timeout: 5), "Undo brought the page back")
        closePagePane()
        XCTAssertTrue(undo.waitUntilExists(timeout: 5))
        named.tap()
        assertPageOnScreen("After Close Pane, with Undo up")

        app.descendants(matching: .any)["pane.divider.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995)))
        let strip = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'pane.strip.'")).firstMatch
        XCTAssertTrue(strip.waitUntilExists(timeout: 5), "The page's pane folded to its strip")
        named.tap()
        assertPageOnScreen("With the page's pane folded")
        attachScreenCapture("web-link-after-fold-portrait")
    }

    /// The launcher's Web Page opens a typed address; Back, Forward, the
    /// address field and the grip's Close Pane work on it.
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
        XCTAssertTrue(paneGrip(named: "Page Two").waitUntilExists(timeout: 5), "The grip names the page")
        XCTAssertTrue(waitFor(back.isEnabled), "Back is offered after a link")
        attachScreenCapture("launcher-page-two")

        back.tap()
        XCTAssertTrue(webView.staticTexts["First fixture page"].waitUntilExists(timeout: 10), "Back returned to page one")
        XCTAssertTrue(waitFor(forward.isEnabled), "Forward is offered after Back")
        forward.tap()
        XCTAssertTrue(webView.staticTexts["Second fixture page"].waitUntilExists(timeout: 10), "Forward went to page two again")

        // The address field: the host at rest, the whole address to edit;
        // Cancel puts the host back, and Go loads what was typed.
        let field = app.textFields["browser.address"]
        XCTAssertEqual(field.value as? String, pages.host, "At rest the field shows the host")
        field.tap()
        XCTAssertTrue(waitFor((field.value as? String) == self.pages.url("two").absoluteString), "Editing shows the whole address")
        attachScreenCapture("address-editing")
        app.buttons["browser.address.cancel"].tap()
        XCTAssertTrue(waitFor((field.value as? String) == self.pages.host), "Cancel put the host back")
        field.tap()
        XCTAssertTrue(waitFor((field.value(forKey: "hasKeyboardFocus") as? Bool) == true))
        field.typeText(pages.url("one").absoluteString + "\n")
        XCTAssertTrue(webView.staticTexts["First fixture page"].waitUntilExists(timeout: 10), "Go loaded the typed address")

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

    /// An address typed with no scheme tries https first. The test's server
    /// speaks only http, so the secure connection fails and the pane goes to
    /// http once, as Safari does: the page loads, and the field says it is
    /// not secure.
    func testABareAddressFallsBackToHTTPWhenHTTPSFails() throws {
        try startPages()
        openChat(orientation: .landscapeLeft)
        openFromLauncher("\(pages.host)/one")
        XCTAssertTrue(app.webViews.staticTexts["First fixture page"].waitUntilExists(timeout: 20), "The bare address loaded over http")
        let field = app.textFields["browser.address"]
        XCTAssertTrue(waitFor((field.value as? String) == self.pages.host), "The field shows the host")
        XCTAssertTrue(app.images["browser.notSecure"].waitUntilExists(timeout: 5), "The field marks the page not secure")
        attachScreenCapture("bare-address-not-secure")
        field.tap()
        XCTAssertTrue(waitFor((field.value as? String) == self.pages.url("one").absoluteString), "Editing shows the http address")
        attachScreenCapture("bare-address-http-fallback")
        app.buttons["browser.address.cancel"].tap()
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

    /// The owner's portrait report: Split Down, the lower pane dragged as
    /// short as it goes. The launcher's choices sit apart, Web Page opens the
    /// browser with its address field focused (no alert), the pane rises over
    /// the chat while the keyboard is up, and the typed page loads there. The
    /// pane dragged to the very bottom collapses to a strip above the home
    /// indicator, which expands it.
    func testAShortLowerPaneOpensAWebPageFromItsAddressField() throws {
        try startPages()
        let scheme = ProcessInfo.processInfo.environment["OPPI_PANE_SHOTS_SCHEME"] ?? "dark"
        openChat(orientation: .portrait, colorScheme: scheme)
        let window = app.windows.firstMatch
        app.typeKey("d", modifierFlags: [.command, .shift])
        let launcher = app.descendants(matching: .any)["pane.launcher"]
        XCTAssertTrue(launcher.waitUntilExists(timeout: 5), "⇧⌘D opened the launcher below the chat")
        let divider = app.descendants(matching: .any)["pane.divider.1"]
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.84)))
        XCTAssertTrue(waitFor(launcher.frame.height < window.frame.height / 3), "The lower pane is short")
        XCTAssertGreaterThanOrEqual(window.frame.maxY - launcher.frame.minY, 300 - 1, "280 pt above the home indicator")
        let choices = ["sessions", "files", "terminal", "web"].map { app.buttons["pane.launcher.\($0)"] }
        for (index, choice) in choices.enumerated() {
            for other in choices[(index + 1)...] {
                XCTAssertFalse(choice.frame.intersects(other.frame), "\(choice.identifier) overlaps \(other.identifier)")
            }
        }
        attachScreenCapture("portrait-short-launcher-\(scheme)")

        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995)))
        let strip = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'pane.strip.'")).firstMatch
        XCTAssertTrue(strip.waitUntilExists(timeout: 5), "Dragged to the bottom, the pane collapsed to its strip")
        attachScreenCapture("portrait-collapsed-strip-\(scheme)")
        // Tapped on its upper part, clear of the home indicator's 20 pt.
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 8)).tap()
        XCTAssertTrue(launcher.waitUntilExists(timeout: 5), "The strip expanded the pane")

        app.buttons["pane.launcher.web"].tap()
        let field = app.textFields["browser.address"]
        XCTAssertTrue(field.waitUntilExists(timeout: 5), "Web Page opened the browser")
        XCTAssertFalse(app.alerts.firstMatch.exists, "No address alert")
        XCTAssertTrue(waitFor((field.value(forKey: "hasKeyboardFocus") as? Bool) == true), "The address field is focused")
        if app.keyboards.firstMatch.waitUntilExists(timeout: 3) {
            XCTAssertLessThan(field.frame.maxY, app.keyboards.firstMatch.frame.minY, "The field sits above the keyboard")
        }
        attachScreenCapture("portrait-address-editing-\(scheme)")
        field.typeText(pages.url("one").absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["First fixture page"].waitUntilExists(timeout: 15), "The typed page loaded")
        XCTAssertTrue(waitFor((field.value as? String) == self.pages.host), "At rest the field shows the host")
        XCTAssertTrue(waitFor(!app.keyboards.firstMatch.exists), "The keyboard went down")
        hold()
        attachScreenCapture("portrait-browser-idle-\(scheme)")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitFor(window.frame.width > window.frame.height))
        hold(for: 1.5)
        attachScreenCapture("landscape-browser-\(scheme)")
    }

    // MARK: Steps

    /// A pane's grip, found by the page title it names.
    private func paneGrip(named title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.' AND label CONTAINS %@", title)).firstMatch
    }

    private func openChat(orientation: UIDeviceOrientation, link: URL? = nil, colorScheme: String? = nil) {
        XCUIDevice.shared.orientation = orientation
        var environment: [String: String] = [:]
        if let link { environment["CHAT_ROUTES_WEB_LINK"] = link.absoluteString }
        launchPreview(screen: "pane-restore", environment: environment, colorScheme: colorScheme, ready: nil)
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
        let field = app.textFields["browser.address"]
        XCTAssertTrue(field.waitUntilExists(timeout: 5), "Web Page opened the browser")
        XCTAssertTrue(waitFor((field.value(forKey: "hasKeyboardFocus") as? Bool) == true), "Its address field is up")
        field.typeText(address + "\n")
    }

    /// The screen's capture: in landscape `app.screenshot()` draws the iPad
    /// sideways into a portrait canvas.
    private func attachScreenCapture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // A copy for review outside the result bundle, when asked for. The
        // image carries the screen's orientation; drawing it bakes that into
        // the pixels, so a landscape PNG is upright with no orientation tag.
        if let folder = ProcessInfo.processInfo.environment["OPPI_BROWSER_PANE_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let image = screenshot.image
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            let upright = UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
            try? upright.write(to: URL(filePath: folder).appending(path: "\(name).png"))
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

    /// What the address field shows at rest for these pages.
    var host: String { "127.0.0.1:\(port)" }

    func stop() { listener.cancel() }

    private static func answer(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first ?? "/"
            let path = String(target.split(separator: "?").first ?? target)
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
