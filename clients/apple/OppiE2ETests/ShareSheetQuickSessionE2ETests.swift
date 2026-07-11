import XCTest

@MainActor
final class ShareSheetQuickSessionE2ETests: E2ETestCase {
    override var e2eLaunchesWorkspaceHomeOnly: Bool { true }

    func testURLShareComposesAndSendsQuickSessionInsideExtension() throws {
        let marker = "oppi-share-send-e2e-8D14C2"
        let sharedURL = try XCTUnwrap(URL(string: "https://example.com/?share=\(marker)"))
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.open(sharedURL)

        let closeButton = safari.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) { closeButton.tap() }

        let menuButton = safari.buttons.matching(
            NSPredicate(format: "label ==[c] %@ OR label CONTAINS[c] %@", "More", "Menu")
        ).firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10), "Safari More menu button did not appear")
        tap(menuButton, named: "Safari More menu button", timeout: 2)

        let shareButton = safari.buttons.matching(NSPredicate(format: "label ==[c] %@", "Share")).firstMatch
        XCTAssertTrue(shareButton.waitForExistence(timeout: 10), "Safari Share menu item did not appear")
        tap(shareButton, named: "Safari Share menu item", timeout: 2)

        let oppiAction = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Oppi"))
            .firstMatch
        XCTAssertTrue(oppiAction.waitForExistence(timeout: 15), "Oppi did not appear in Safari's share sheet")
        tap(oppiAction, named: "Oppi share action", timeout: 2)

        let extensionTitle = safari.staticTexts["Quick Session"]
        XCTAssertTrue(
            extensionTitle.waitForExistence(timeout: 15),
            "Oppi's in-extension Quick Session form did not appear"
        )
        let sharedText = safari.textViews["share.quickSession.text"]
        XCTAssertTrue(sharedText.waitForExistence(timeout: 10), "Shared text editor did not appear")
        XCTAssertTrue(
            (sharedText.value as? String)?.contains(marker) == true,
            "Shared URL was not represented in the extension composer"
        )

        let workspace = safari.buttons["share.quickSession.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 15), "Workspace selector did not appear")
        let send = safari.buttons["share.quickSession.send"]
        let sendReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: send)
        XCTAssertEqual(
            XCTWaiter.wait(for: [sendReady], timeout: 20),
            .completed,
            "Send did not become available after workspace loading"
        )
        tap(send, named: "share extension Send", timeout: 2)

        XCTAssertTrue(
            extensionTitle.waitForNonExistence(timeout: 30),
            "Share extension did not finish after the server accepted the session"
        )

        let sessionID = try waitForSharedSession(marker: marker, timeout: 30)
        app.activate()
        openSessionDeepLink(id: sessionID, timeout: 30)
        XCTAssertTrue(
            waitForTimelineTextContaining(marker, timeout: 30),
            "The session created by the extension was not discoverable when Oppi reopened"
        )
    }

    private func waitForSharedSession(marker: String, timeout: TimeInterval) throws -> String {
        let encoded = marker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? marker
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try e2eLabAPIJSON(method: "GET", path: "/sessions/search?q=\(encoded)")
            if let results = response["results"] as? [[String: Any]],
               let sessionID = results.first?["sessionId"] as? String {
                return sessionID
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Server search never discovered the session created by the share extension")
        return "missing-share-session"
    }
}
