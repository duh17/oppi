import XCTest

/// Fast, serverless repro for the compact navigation state used by chat Files.
///
/// This launches the DEBUG navigation chrome harness directly, auto-pushes the
/// workspace → chat stack over the production `ChatViewController`, then taps
/// the top Files control. It keeps the slow server-pairing E2E for end-to-end
/// coverage, but gives us a seconds-fast signal for toolbar tap delivery and
/// accidental root fallback.
final class ChatFilesNavigationReproUITests: XCTestCase {
    @MainActor
    func testRealChatTopFilesControlOpensPanelWithoutRevealingWorkspaceList() {
        let app = launchRealChatHarness()

        let filesButton = app.buttons["chat.toolbar.files"]
        XCTAssertTrue(filesButton.waitForExistence(timeout: 8), "Real ChatViewController repro did not reach the chat surface")
        XCTAssertFalse(app.collectionViews["navChrome.repro.root"].exists, "Workspace list should not be visible before tapping Files")

        filesButton.tap()

        XCTAssertTrue(
            app.staticTexts["Files"].waitForExistence(timeout: 2),
            "Production ChatViewController top Files control should open the in-chat panel"
        )
        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 2),
            "File panel should use the shared sheet navigation container"
        )
        XCTAssertFalse(
            app.collectionViews["navChrome.repro.root"].exists,
            "Tapping production ChatViewController top Files should not reveal the workspace list"
        )
    }

    @MainActor
    func testChatBackFromLocalDestinationDoesNotPopWorkspaceRoute() {
        let app = launchRealChatHarness(extraArguments: ["--nav-chrome-chat-back-local-repro"])

        let workspace = app.collectionViews["navChrome.repro.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 8), "Local chat repro should auto-open the workspace detail")
        XCTAssertEqual(app.staticTexts["navChrome.repro.pathCount"].label, "1", "Workspace should stay on the app navigation path before local chat opens")

        app.buttons["navChrome.repro.openLocalChat"].tap()

        let backButton = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 8), "Local ChatViewController should expose the chat Back control")
        XCTAssertEqual(app.staticTexts["navChrome.repro.pathCount"].label, "1", "Opening local chat must not add a workspace route")

        backButton.tap()

        XCTAssertTrue(
            workspace.waitForExistence(timeout: 2),
            "Chat Back should dismiss the local ChatViewController and reveal the workspace detail"
        )
        XCTAssertEqual(
            app.staticTexts["navChrome.repro.pathCount"].label,
            "1",
            "Chat Back from a local destination must not pop a workspace route"
        )
        XCTAssertFalse(
            app.collectionViews["navChrome.repro.root"].exists,
            "Chat Back from a local destination should not reveal the workspace list"
        )
    }

    @MainActor
    private func launchRealChatHarness(extraArguments: [String] = []) -> XCUIApplication {
        let app = OppiTestLaunch.makeApp()
        app.launchArguments += ["--nav-chrome-profile"] + ChatTopBarTestLayout.panelButtons + extraArguments
        app.launch()
        return app
    }
}
