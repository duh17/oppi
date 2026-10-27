import XCTest

/// The server Skills list on the real UIKit controller over the settings sweep
/// fixture server (`SCREENSHOT_SCREEN=settings-sweep`).
@MainActor
final class ServerSkillsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Settings sweep previews are simulator-only")
#endif
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// Rows group by what needs attention, speak their name, source, and state,
    /// and search narrows them in the bar until nothing matches.
    func testSkillsListRowsSearchAndNoResults() {
        launch(page: "skills")
        let release = app.buttons["skills.row.release"]
        XCTAssertTrue(release.waitForExistence(timeout: 10), "Skills list did not load")
        XCTAssertEqual(release.label, "release, ~/.pi/agent/skills, Enabled")
        XCTAssertEqual(app.buttons["skills.row.broken"].label, "release-checks, ~/.pi/agent/skills, Error")
        XCTAssertEqual(app.buttons["skills.row.deep-research"].label, "deep-research, Pi user settings, Disabled")
        let scope = app.descendants(matching: .any)["serverCatalog.server.passive"]
        XCTAssertTrue(scope.exists, "One paired server shows the passive server row")
        XCTAssertEqual(scope.label, "Current server: mac-studio")
        XCTAssertFalse(app.buttons["serverCatalog.server.menu"].exists)

        let search = app.searchFields["Search skills"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Skills must search in the host's bar")
        search.tap()
        search.typeText("deep")
        XCTAssertTrue(app.buttons["skills.row.deep-research"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(!release.exists), "Search must narrow the list")
        search.clearText()
        search.typeText("no-matching-skill")
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["skills.row.deep-research"].exists)
        assertRunning()
    }

    /// A refresh that fails keeps the seeded catalog and says so.
    func testOfflineCatalogShowsCachedWarning() {
        launch(page: "skills-offline")
        XCTAssertTrue(
            app.descendants(matching: .any)["skills.cachedWarning"].waitForExistence(timeout: 10),
            "A failed refresh with cached rows must warn"
        )
        XCTAssertTrue(app.buttons["skills.row.release"].exists, "The cached catalog must stay listed")
    }

    // MARK: Helpers

    private func launch(page: String) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += ["--screenshot-preview", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "settings-sweep"
        app.launchEnvironment["SCREENSHOT_SWEEP_PAGE"] = page
        app.launchEnvironment["SCREENSHOT_SWEEP_SHOWS_WRITES"] = "1"
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = "dark"
        app.launch()
        XCTAssertTrue(app.staticTexts["settingsSweep.lastWrite"].waitForExistence(timeout: 10), "Settings sweep harness did not appear")
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "The app must still be running", file: file, line: line)
    }
}

private extension XCUIElement {
    /// Empties a text field: select-all then delete is flaky in a search bar,
    /// so type one delete per character.
    func clearText() {
        guard let text = value as? String, !text.isEmpty else { return }
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    }
}
