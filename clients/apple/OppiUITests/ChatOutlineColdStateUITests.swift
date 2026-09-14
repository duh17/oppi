import XCTest

/// Deterministic ChatView toolbar/outline drive. Launches the DEBUG harness
/// with production ChatView chrome. Does not construct SessionOutlineView,
/// call onSelect, or use a local model.
final class ChatOutlineColdStateUITests: XCTestCase {
    private let targetText = "COLD_OUTLINE_TARGET_ROW"
    private let targetItemID = "cold-outline-target"
    private let sessionA = "cold-outline-session-a"
    private let sessionB = "cold-outline-session-b"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testRealChatToolbarOutlineLifecycleNavigationAndOpenOutlineStreaming() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Chat outline cold harness is simulator-only")
#endif
        let app = launchHarness()

        waitForHarnessReady(in: app)
        XCTAssertEqual(diagnostic(app, "chat.outline.harness.sessionId"), sessionA)
        XCTAssertFalse(
            app.buttons["chat.toolbar.outline"].exists,
            "Empty session must not show the outline toolbar control"
        )

        tapHarnessControl(app.buttons["chat.outline.harness.seedA"])
        XCTAssertTrue(waitForDiagnostic(app, "chat.outline.harness.itemCount", atLeast: 1, timeout: 8))
        XCTAssertTrue(
            app.buttons["chat.toolbar.outline"].waitForExistence(timeout: 8),
            "Nonempty session must show chat.toolbar.outline"
        )
        XCTAssertTrue(waitForDiagnostic(app, "chat.outline.harness.outlineAvailable", equals: "1", timeout: 4))

        tapHarnessControl(app.buttons["chat.outline.harness.clear"])
        XCTAssertTrue(
            waitForElementToDisappear(app.buttons["chat.toolbar.outline"], timeout: 8),
            "Clearing the timeline must hide chat.toolbar.outline"
        )
        XCTAssertTrue(waitForDiagnostic(app, "chat.outline.harness.outlineAvailable", equals: "0", timeout: 4))

        tapHarnessControl(app.buttons["chat.outline.harness.seedA"])
        XCTAssertTrue(waitForDiagnostic(app, "chat.outline.harness.itemCount", atLeast: 1, timeout: 8))
        XCTAssertTrue(
            app.buttons["chat.toolbar.outline"].waitForExistence(timeout: 8),
            "Reseeding session A must restore chat.toolbar.outline"
        )

        tapHarnessControl(app.buttons["chat.outline.harness.rebindB"])
        XCTAssertTrue(
            waitForElementToDisappear(app.buttons["chat.toolbar.outline"], timeout: 8),
            "Nonempty A → empty B must hide chat.toolbar.outline before B receives tokens"
        )
        XCTAssertTrue(waitForDiagnostic(app, "chat.outline.harness.sessionId", equals: sessionB, timeout: 8))
        XCTAssertTrue(waitForDiagnostic(app, "chat.outline.harness.outlineAvailable", equals: "0", timeout: 4))
        XCTAssertTrue(waitForDiagnostic(app, "chat.outline.harness.itemCount", equals: "0", timeout: 4))
        XCTAssertTrue(waitForDiagnostic(app, "chat.outline.harness.ready", equals: "1", timeout: 8))

        tapHarnessControl(app.buttons["chat.outline.harness.seedB"])
        XCTAssertTrue(waitForDiagnostic(app, "chat.outline.harness.itemCount", atLeast: 1, timeout: 8))
        XCTAssertTrue(
            app.buttons["chat.toolbar.outline"].waitForExistence(timeout: 8),
            "Seeding B after the empty-B hide must show chat.toolbar.outline"
        )

        tapHarnessControl(app.buttons["chat.outline.harness.resetPerf"])
        tapHarnessControl(app.buttons["chat.outline.harness.armStream"])

        let outlineButton = app.buttons["chat.toolbar.outline"]
        tapHarnessControl(outlineButton)
        let outlineBar = app.navigationBars["Session Outline"]
        XCTAssertTrue(
            outlineBar.waitForExistence(timeout: 8),
            "chat.toolbar.outline must present Session Outline"
        )
        let outlineRow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", targetText))
            .firstMatch
        XCTAssertTrue(
            outlineRow.waitForExistence(timeout: 8),
            "Presented Session Outline must show the current target row"
        )
        XCTAssertTrue(
            outlineBar.exists,
            "Outline contents may be inspected only inside the presented Session Outline"
        )

        XCTAssertTrue(
            waitForDiagnostic(app, "chat.outline.harness.controllerOwnedApplyCount", atLeast: 1, timeout: 8),
            "Streaming while Session Outline is open must apply on the UIKit clock"
        )
        XCTAssertEqual(
            diagnostic(app, "chat.outline.harness.hostUpdateUIViewCount"),
            "0",
            "Streaming while Session Outline is open must not increment hostUpdateUIViewCount"
        )
        XCTAssertTrue(outlineBar.exists, "Open-outline stream must leave Session Outline presented")

        tapHarnessControl(outlineRow)
        XCTAssertTrue(
            waitForElementToDisappear(outlineBar, timeout: 8),
            "Selecting an outline row must dismiss Session Outline"
        )
        XCTAssertTrue(
            waitForDiagnostic(app, "chat.outline.harness.topVisibleItemId", equals: targetItemID, timeout: 8),
            "Outline row selection must land the timeline on the selected destination"
        )
    }

    @MainActor
    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState",
            "YES",
            "--chat-outline-cold-harness",
        ]
        app.launchEnvironment["PI_CHAT_OUTLINE_COLD_HARNESS"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func waitForHarnessReady(in app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["chat.toolbar.context"].waitForExistence(timeout: 10),
            "Real ChatView toolbar did not appear"
        )
        XCTAssertTrue(
            waitForDiagnostic(app, "chat.outline.harness.ready", equals: "1", timeout: 10),
            "Harness did not observe the mounted ChatView timeline"
        )
    }

    @MainActor
    private func tapHarnessControl(
        _ element: XCUIElement,
        timeout: TimeInterval = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Harness control did not exist",
            file: file,
            line: line
        )
        if element.isHittable {
            element.tap()
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    @MainActor
    private func diagnostic(_ app: XCUIApplication, _ id: String) -> String {
        let element = app.descendants(matching: .any)[id]
        guard element.exists else { return "" }
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    @MainActor
    private func waitForDiagnostic(
        _ app: XCUIApplication,
        _ id: String,
        equals expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if diagnostic(app, id) == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return diagnostic(app, id) == expected
    }

    @MainActor
    private func waitForDiagnostic(
        _ app: XCUIApplication,
        _ id: String,
        atLeast minimum: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = Int(diagnostic(app, id)), value >= minimum {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (Int(diagnostic(app, id)) ?? 0) >= minimum
    }
}
