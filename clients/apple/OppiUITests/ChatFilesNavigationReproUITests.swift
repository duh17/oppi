import XCTest

/// Fast, serverless repro for the compact navigation state used by chat Files.
///
/// This launches the DEBUG navigation chrome harness directly, auto-pushes the
/// workspace → chat stack, then taps the top Files control. It keeps the slow
/// server-pairing E2E for end-to-end coverage, but gives us a seconds-fast
/// signal for toolbar tap delivery and accidental root fallback.
final class ChatFilesNavigationReproUITests: XCTestCase {
    @MainActor
    func testTopFilesControlOpensPanelWithoutRevealingWorkspaceList() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState",
            "YES",
            "--nav-chrome-profile",
            "--nav-chrome-chat-files-repro",
        ]
        app.launchEnvironment["PI_NAV_CHROME_CHAT_FILES_REPRO"] = "1"
        app.launch()

        let filesButton = app.buttons["navChrome.chat.files"]
        let backButton = app.buttons["navChrome.chat.back"]
        XCTAssertTrue(filesButton.waitForExistence(timeout: 8), "Fast chat Files repro did not reach the chat surface")
        XCTAssertTrue(backButton.exists, "Fast chat repro should use one leading pill with Back and Files")
        XCTAssertLessThan(filesButton.frame.midX, app.frame.midX, "Files control should live on the leading side of chat navigation")
        XCTAssertLessThan(backButton.frame.maxX, filesButton.frame.minX + 2, "Back and Files controls should be adjacent in the leading pill")
        XCTAssertFalse(app.collectionViews["navChrome.repro.root"].exists, "Workspace list should not be visible before tapping Files")

        filesButton.tap()

        XCTAssertTrue(
            app.staticTexts["navChrome.chat.filesPanel"].waitForExistence(timeout: 2),
            "Top Files control should open the in-chat panel"
        )
        XCTAssertFalse(
            app.collectionViews["navChrome.repro.root"].exists,
            "Tapping top Files should not reveal the workspace list"
        )
        XCTAssertEqual(app.staticTexts["navChrome.repro.filesTapCount"].label, "1")
    }

    @MainActor
    func testRealChatTopFilesControlOpensPanelWithoutRevealingWorkspaceList() {
        let app = launchRealChatHarness()

        let filesButton = app.buttons["chat.toolbar.files"]
        let backButton = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(filesButton.waitForExistence(timeout: 8), "Real ChatView repro did not reach the chat surface")
        XCTAssertTrue(backButton.exists, "Chat should use one leading pill with Back and Files")
        XCTAssertLessThan(filesButton.frame.midX, app.frame.midX, "Files control should live on the leading side of chat navigation")
        XCTAssertLessThan(backButton.frame.maxX, filesButton.frame.minX + 2, "Back and Files controls should be adjacent in the leading pill")
        XCTAssertFalse(app.collectionViews["navChrome.repro.root"].exists, "Workspace list should not be visible before tapping Files")

        filesButton.tap()

        XCTAssertTrue(
            app.staticTexts["Files"].waitForExistence(timeout: 2),
            "Production ChatView top Files control should open the in-chat panel"
        )
        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 2),
            "File panel should use the shared sheet navigation container"
        )
        XCTAssertFalse(
            app.buttons["chat.files.fullscreen.expand"].exists,
            "File panel should rely on the native sheet detent instead of a custom expand button"
        )
        XCTAssertFalse(
            app.collectionViews["navChrome.repro.root"].exists,
            "Tapping production ChatView top Files should not reveal the workspace list"
        )
    }

    @MainActor
    func testChatBackFromLocalDestinationDoesNotPopWorkspacePath() {
        let app = launchRealChatHarness(extraArguments: ["--nav-chrome-chat-back-local-repro"], extraEnvironment: [
            "PI_NAV_CHROME_CHAT_BACK_LOCAL_REPRO": "1",
        ])

        let workspace = app.collectionViews["navChrome.repro.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 8), "Local chat repro should auto-open the workspace detail")
        XCTAssertEqual(app.staticTexts["navChrome.repro.pathCount"].label, "1", "Workspace should stay on the app navigation path before local chat opens")

        app.buttons["navChrome.repro.openLocalChat"].tap()

        let backButton = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 8), "Local ChatView should expose the chat Back control")
        XCTAssertEqual(app.staticTexts["navChrome.repro.pathCount"].label, "1", "Opening local chat must not append to AppNavigation.workspacePath")

        backButton.tap()

        XCTAssertTrue(
            workspace.waitForExistence(timeout: 2),
            "Chat Back should dismiss the local ChatView and reveal the workspace detail"
        )
        XCTAssertEqual(
            app.staticTexts["navChrome.repro.pathCount"].label,
            "1",
            "Chat Back from a local destination must not pop AppNavigation.workspacePath"
        )
        XCTAssertFalse(
            app.collectionViews["navChrome.repro.root"].exists,
            "Chat Back from a local destination should not reveal the workspace list"
        )
    }

    @MainActor
    private func launchRealChatHarness(
        extraArguments: [String] = [],
        extraEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState",
            "YES",
            "--nav-chrome-profile",
            "--nav-chrome-chat-files-repro",
            "--nav-chrome-chat-files-real-chat",
        ] + extraArguments
        app.launchEnvironment["PI_NAV_CHROME_CHAT_FILES_REPRO"] = "1"
        app.launchEnvironment["PI_NAV_CHROME_CHAT_FILES_REAL_CHAT"] = "1"
        for (key, value) in extraEnvironment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }
}
