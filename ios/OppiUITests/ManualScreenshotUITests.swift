import XCTest

@MainActor
final class ManualScreenshotUITests: XCTestCase {
    func testPrepareJumpToBottomState() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-hang-harness")
        app.launchEnvironment["PI_UI_HANG_HARNESS"] = "1"
        app.launchEnvironment["PI_UI_HANG_UI_TEST_MODE"] = "1"
        app.launchEnvironment["PI_UI_HANG_NO_STREAM"] = "1"
        app.launch()

        let ready = app.descendants(matching: .any)["harness.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 8))

        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        XCTAssertTrue(expandAll.waitForExistence(timeout: 4))
        expandAll.tap()

        let topButton = app.descendants(matching: .any)["harness.scroll.top"]
        XCTAssertTrue(topButton.waitForExistence(timeout: 4))
        topButton.tap()

        // Keep the app in this state long enough for external simctl screenshot capture.
        Thread.sleep(forTimeInterval: 12)
    }

    func testPrepareLiveChatDetachedState() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["PI_SCREEN_TOKEN"], !token.isEmpty else {
            throw XCTSkip("PI_SCREEN_TOKEN env var is required")
        }

        let host = env["PI_SCREEN_HOST"] ?? "127.0.0.1"

        let app = XCUIApplication()
        app.launch()

        let connectButton = app.buttons["Connect to Server"]
        if connectButton.waitForExistence(timeout: 4) {
            connectButton.tap()

            let hostField = app.textFields["Host (e.g. my-mac.local)"]
            XCTAssertTrue(hostField.waitForExistence(timeout: 8))
            hostField.tap()
            hostField.typeText(host)

            let tokenField = app.secureTextFields["Token"]
            XCTAssertTrue(tokenField.waitForExistence(timeout: 8))
            tokenField.tap()
            tokenField.typeText(token)

            let nameField = app.textFields["Name"]
            if nameField.waitForExistence(timeout: 2) {
                nameField.tap()
                nameField.typeText("Sim")
            }

            app.navigationBars.buttons["Connect"].tap()
        }

        XCTAssertTrue(app.tabBars.buttons["Workspaces"].waitForExistence(timeout: 25))
        app.tabBars.buttons["Workspaces"].tap()

        let firstWorkspaceCell = app.tables.cells.element(boundBy: 0)
        XCTAssertTrue(firstWorkspaceCell.waitForExistence(timeout: 20))
        firstWorkspaceCell.tap()

        var sessionCell = app.tables.cells.matching(
            NSPredicate(format: "label CONTAINS[c] 'Session'")
        ).firstMatch

        if !sessionCell.waitForExistence(timeout: 8) {
            sessionCell = app.tables.cells.element(boundBy: 1)
        }

        XCTAssertTrue(sessionCell.waitForExistence(timeout: 20))
        sessionCell.tap()

        let input = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 25))

        for _ in 0..<4 {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.35)
        }

        Thread.sleep(forTimeInterval: 12)
    }
}
