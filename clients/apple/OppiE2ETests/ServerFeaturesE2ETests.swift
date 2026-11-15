import XCTest

/// Server Settings → Features against a real paired server: Plain Pi turns every feature off,
/// and the sidebar (and, on iPad, a new pane's choices) keeps only chat, sessions and files.
/// Turning Terminal back on brings back exactly Terminal. Screenshots go to
/// `/tmp/oppi-screenshots/server-features-*.png`.
@MainActor
final class ServerFeaturesE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    /// The sidebar rows a server switch hides, by accessibility identifier.
    private static let switchedRows = [
        "workspace.agents.open", "workspace.schedules.open", "workspace.skills.open",
        "workspace.extensions.open", "workspace.mcpServers.open", "workspace.terminal.open",
    ]

    private var isPad: Bool { min(app.frame.width, app.frame.height) >= 700 }

    override func tearDownWithError() throws {
        // The switches outlive a case on the shared server: every feature back on.
        let allOn = Dictionary(uniqueKeysWithValues: Self.featureNames.map { ($0, true) })
        _ = try? e2eLabAPIJSON(method: "PUT", path: "/server/features", body: allOn)
        try super.tearDownWithError()
    }

    private static let featureNames = [
        "agents", "schedules", "skills", "extensions", "mcp", "terminal", "rex", "herdr", "godotPane", "browserPane",
    ]

    func testPlainPiLeavesChatSessionsAndFilesAndOneSwitchComesBack() throws {
        openFeatures()
        try saveLabScreenshot(name: "server-features-\(device)-all-on")
        // The presets sit at the top, above every switch.
        let plainPi = app.buttons["server.features.plainPi"]
        XCTAssertTrue(plainPi.waitForExistence(timeout: 10) && plainPi.isHittable, "Plain Pi is not at the top")
        tap(plainPi, named: "Plain Pi")
        waitForSwitch("server.features.agents", on: false)
        waitForSwitch("server.features.skills", on: false)
        try saveLabScreenshot(name: "server-features-\(device)-plain-pi-switches")
        let saved = try e2eLabAPIJSON(method: "GET", path: "/server/features")
        XCTAssertEqual(saved.values.compactMap { $0 as? Bool }.filter { $0 }.count, 0, "The server kept a feature on: \(saved)")

        openSidebar()
        XCTAssertTrue(app.buttons["workspace.settings.open"].waitForExistence(timeout: 10), "The sidebar did not show")
        expectSidebar(showing: [])
        try saveLabScreenshot(name: "server-features-\(device)-plain-pi-sidebar")
        if isPad {
            expectLauncher(offering: ["sessions", "files"], hiding: ["terminal", "web", "godot"])
            try saveLabScreenshot(name: "server-features-\(device)-plain-pi-launcher")
        }

        // One switch back: exactly Terminal returns.
        openFeatures()
        let terminal = app.switches["server.features.terminal"]
        XCTAssertTrue(scrollToElement(terminal, in: app.collectionViews["server.features.list"], timeout: 20), "No Terminal switch")
        tap(terminal, named: "Terminal switch")
        waitForSwitch("server.features.terminal", on: true)
        openSidebar()
        expectSidebar(showing: ["workspace.terminal.open"])
        try saveLabScreenshot(name: "server-features-\(device)-terminal-back-sidebar")
        if isPad {
            expectLauncher(offering: ["sessions", "files", "terminal"], hiding: ["web", "godot"])
        }
    }

    private var device: String { isPad ? "ipad" : "iphone" }

    /// Server Settings → Features, from wherever the app is.
    private func openFeatures() {
        returnToInbox()
        closeSidebar()
        tap(app.buttons["server.switcher"], named: "server switcher", timeout: 15)
        tap(app.buttons["hostSwitcher.serverSettings"], named: "Server Settings", timeout: 5)
        XCTAssertTrue(app.navigationBars["Server Settings"].waitForExistence(timeout: 10), "Server Settings did not open")
        tapListButton("server.row.features", named: "Features row", in: "server.details.list")
        XCTAssertTrue(app.navigationBars["Features"].waitForExistence(timeout: 10), "Features did not open")
        waitForSwitch("server.features.agents", on: nil)
    }

    /// Back until the root of the stack: the sessions inbox. Server Settings has a switcher of
    /// its own, so Back is the only sign of a page above the inbox.
    private func returnToInbox() {
        for _ in 0..<5 {
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            guard back.waitForExistence(timeout: 2), back.isHittable else { return }
            back.tap()
        }
    }

    /// A portrait window's sidebar covers the inbox: a tap beside it closes it.
    private func closeSidebar() {
        let settingsRow = app.buttons["workspace.settings.open"]
        guard settingsRow.exists, settingsRow.isHittable else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        _ = settingsRow.waitForNonExistence(timeout: 5)
    }

    private func openSidebar() {
        returnToInbox()
        let toggle = app.buttons["workspace.sidebar.open"]
        if toggle.waitForExistence(timeout: 5), toggle.isHittable { toggle.tap() }
    }

    private func expectSidebar(showing shown: Set<String>) {
        for row in Self.switchedRows {
            let element = app.buttons[row]
            if shown.contains(row) {
                XCTAssertTrue(element.waitForExistence(timeout: 15), "\(row) is missing")
            } else {
                XCTAssertTrue(element.waitForNonExistence(timeout: 15), "\(row) still shows")
            }
        }
    }

    /// A new pane's choices: ⌘D beside the focused pane the first time; later the launcher
    /// already open, which follows a switch while it shows.
    private func expectLauncher(offering shown: [String], hiding hidden: [String]) {
        returnToInbox()
        closeSidebar()
        if !app.buttons["pane.launcher.sessions"].exists { app.typeKey("d", modifierFlags: .command) }
        XCTAssertTrue(app.buttons["pane.launcher.sessions"].waitForExistence(timeout: 10), "⌘D opened no launcher")
        for choice in shown {
            XCTAssertTrue(app.buttons["pane.launcher.\(choice)"].waitForExistence(timeout: 10), "The launcher has no \(choice)")
        }
        for choice in hidden {
            XCTAssertFalse(app.buttons["pane.launcher.\(choice)"].exists, "The launcher offers \(choice)")
        }
    }

    private func tapListButton(_ identifier: String, named name: String, in list: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(scrollToElement(button, in: app.collectionViews[list], timeout: 20), "No \(name)")
        tap(button, named: name)
    }

    /// Waits for the switch to exist and, with `on`, for its value.
    private func waitForSwitch(_ identifier: String, on: Bool?) {
        let element = app.switches[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 20), "No \(identifier) switch")
        guard let on else { return }
        let value = NSPredicate(format: "value == %@", on ? "1" : "0")
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation(for: value, evaluatedWith: element)], timeout: 20),
            .completed,
            "\(identifier) did not turn \(on ? "on" : "off")"
        )
    }
}
