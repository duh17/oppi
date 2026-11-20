import XCTest

/// The Rex screen (`RexListViewController`) over the preview's two saved hosts,
/// each reading a fake Rex (`SCREENSHOT_SCREEN=ssh-terminal-rex-list`): a
/// session's ⊕ New Pane, the chevron that folds its panes, and the heading's ⋯
/// with New Session.
@MainActor
final class RexListUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!
    static var reusesLaunch: Bool { true }

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Rex list tests are simulator-only")
#endif
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// One session is folded and the other left open, which is what the capture shows.
    func testRexSectionsOfferNewPaneNewSessionAndACollapseChevron() {
        let hostID = "5E5E5E5E-0000-4000-8000-000000000001"
        let oppi = "session:01a18a26-6620-76be-b529-4d9ad2b36c63"
        let dotfiles = "session:01a18a26-6620-76be-b529-4d9ad2b36c64"
        launchPreview(
            screen: "ssh-terminal-rex-list",
            colorScheme: "dark",
            arguments: OppiTestLaunch.experimentArguments([.rex: true])
        )
        let prefix = "sshTerminal.rexList.\(hostID)."
        XCTAssertTrue(app.buttons[prefix + oppi].waitUntilExists(timeout: 15), "The Rex section did not list its sessions")

        // The session's own ⊕ adds a pane to it.
        XCTAssertTrue(app.buttons[prefix + oppi + ".newPane"].exists, "A session has no ⊕ New Pane")
        // The heading is the Rex, so its ⋯ carries New Session.
        let menu = app.buttons[prefix + "menu"]
        XCTAssertTrue(menu.waitUntilExists(timeout: 5), "The heading has no ⋯ menu")
        menu.tap()
        // The ＋ in the bar is titled New Session too, so the item is the element with
        // that label that is not the bar button.
        let newSession = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "New Session", "rex.newSession")
        ).firstMatch
        XCTAssertTrue(newSession.waitUntilExists(timeout: 5), "The heading must offer New Session")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()

        // Every session shows its panes until its chevron folds them.
        let pane = app.cells[prefix + "block:01a18a7e-911a-721b-a50b-14dfc0cc62ca"]
        XCTAssertTrue(pane.waitUntilExists(timeout: 5), "An open session lists its panes")
        let dotfilesDisclosure = app.buttons[prefix + dotfiles + ".disclosure"]
        XCTAssertEqual(dotfilesDisclosure.value as? String, "Expanded")
        dotfilesDisclosure.tap()
        XCTAssertTrue(waitFor((dotfilesDisclosure.value as? String) == "Collapsed"), "The chevron must fold the session")
        XCTAssertEqual(app.buttons[prefix + oppi + ".disclosure"].value as? String, "Expanded")
        XCTAssertTrue(pane.exists, "Folding one session leaves the other's panes")
        attachScreenshot("rex-screen-panes")
        assertRunning()
    }
}
