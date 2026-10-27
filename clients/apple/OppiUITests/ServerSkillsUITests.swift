import XCTest

/// The server Skills screens (list, a Skill's page, its file browser) on the
/// real UIKit controllers over the settings sweep fixture server
/// (`SCREENSHOT_SCREEN=settings-sweep`). Writes that reach the fixture server
/// show in `settingsSweep.lastWrite`.
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
        XCTAssertTrue(app.staticTexts["skills.noResults"].waitForExistence(timeout: 5))
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

    /// The page shows the Skill, its switch saves through the server, and the
    /// file list is one row away.
    func testSkillDetailSwitchSavesAndOffersFiles() {
        launch(page: "skill-detail")
        let enabled = app.switches["skills.detail.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10), "Skill page did not load")
        XCTAssertEqual(enabled.label, "Enable release on mac-studio")
        XCTAssertEqual(enabled.value as? String, "1")

        enabled.tap()
        XCTAssertTrue(
            waitFor(lastWrite.contains("PUT /server/resources/skills/release/enabled") && lastWrite.contains("\"enabled\":false")),
            "The switch must save through the Skill: \(lastWrite)"
        )

        let files = app.buttons["skills.files.open"]
        XCTAssertTrue(files.waitForExistence(timeout: 10), "The file list row did not show")
        XCTAssertEqual(files.label, "Browse release files")
        XCTAssertEqual(files.value as? String, "3 files")
        assertRunning()
    }

    /// Folders open and close in place; files are buttons that open by path.
    func testSkillBrowserOpensFolders() {
        launch(page: "skill-browser")
        let file = app.buttons["skills.file.SKILL.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 10), "The file tree did not load")
        XCTAssertEqual(file.label, "Open SKILL.md")
        let folder = app.buttons["skills.dir.scripts"]
        XCTAssertTrue(folder.exists)
        XCTAssertEqual(folder.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["skills.file.scripts/check.sh"].exists)

        folder.tap()
        XCTAssertTrue(app.buttons["skills.file.scripts/check.sh"].waitForExistence(timeout: 5), "Opening a folder must list its files")
        XCTAssertEqual(folder.value as? String, "Expanded")
        folder.tap()
        XCTAssertTrue(waitFor(!app.buttons["skills.file.scripts/check.sh"].exists), "Closing the folder must hide its files")
        assertRunning()
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

    private var lastWrite: String {
        app.staticTexts["settingsSweep.lastWrite"].label
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
