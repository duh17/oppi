import XCTest

/// The server's feature switches as the iPad mini shows them: Rex stands alone (a server with
/// Terminal off and Rex on lists Rex in the sidebar without Terminal), Rex and Herdr have no
/// device Experiment, and Server Settings › Features holds only Herdr under Terminal.
@MainActor
final class ServerFeatureSwitchesUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Server feature journeys are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testTerminalOffLeavesRexInTheSidebarAndExperimentsHaveNoRexOrHerdr() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The split sidebar needs the iPad mini in landscape")
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(
            screen: "workspace-shell",
            environment: ["SCREENSHOT_FEATURES_OFF": "terminal"],
            colorScheme: "dark",
            ready: nil
        )
        XCTAssertTrue(app.collectionViews["workspace.sessionList"].waitUntilExists(timeout: 10), "The workspace shell did not appear")

        let rex = app.buttons["workspace.rex.open"]
        // Every place shows until the server's switches load; then Terminal goes and Rex stays.
        XCTAssertTrue(app.buttons["workspace.terminal.open"].waitUntilGone(timeout: 10), "Terminal is off on the server")
        XCTAssertTrue(rex.waitUntilExists(timeout: 5), "Rex is on on the server, without Terminal")
        captureScreen("sidebar-terminal-off-rex-on")

        rex.tap()
        XCTAssertTrue(app.collectionViews["rex.list"].waitUntilExists(timeout: 10), "Rex did not open")

        app.buttons["workspace.settings.open"].tap()
        let experiments = app.buttons["settings.row.experiments"]
        scroll(app.collectionViews["settings.list"], to: experiments)
        XCTAssertTrue(experiments.waitUntilExists(timeout: 5), "App Settings has no Experiments row")
        experiments.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.experiments.calendarEvents"].waitUntilExists(timeout: 10),
            "Experiments did not open"
        )
        // ax-id-guard: absent-on-purpose
        XCTAssertFalse(app.descendants(matching: .any)["settings.experiments.rex"].exists, "Rex is no longer an Experiment")
        // ax-id-guard: absent-on-purpose
        XCTAssertFalse(app.descendants(matching: .any)["settings.experiments.herdr"].exists, "Herdr is no longer an Experiment")
        captureScreen("settings-experiments")
    }

    /// Terminal off: Herdr, which runs inside Terminal, is held off; Rex keeps its own switch.
    func testServerFeaturesHoldOnlyHerdrUnderTerminal() throws {
        launchPreview(
            screen: "settings-sweep",
            environment: ["SCREENSHOT_SWEEP_PAGE": "server-settings", "SCREENSHOT_FEATURES_OFF": "terminal"],
            colorScheme: "dark",
            ready: nil
        )
        let features = app.buttons["server.row.features"]
        scroll(app.collectionViews["server.details.list"], to: features)
        XCTAssertTrue(features.waitUntilExists(timeout: 5), "Server Settings has no Features row")
        features.tap()
        // On a phone the Terminal group sits below the fold, and the list
        // builds only the rows on screen.
        let list = app.collectionViews["server.features.list"]
        let terminal = app.switches["server.features.terminal"]
        let herdr = app.switches["server.features.herdr"]
        let rex = app.switches["server.features.rex"]
        scroll(list, to: terminal)
        // The switches load from the server, then settle.
        XCTAssertTrue(waitFor(terminal.isEnabled && terminal.value as? String == "0", timeout: 10), "The fixture server has Terminal off")
        XCTAssertFalse(herdr.isEnabled, "Herdr is held off while Terminal is off")
        scroll(list, to: rex)
        XCTAssertTrue(rex.waitUntilExists(timeout: 10), "Features has no Rex switch")
        XCTAssertTrue(rex.isEnabled, "Rex stands alone")
        attachScreenshot("server-features-terminal-off")
    }

    /// The screen as the simulator captured it: `attachScreenshot`'s upright copy crops a
    /// landscape iPad into a portrait canvas.
    private func captureScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A list builds only the rows on screen: swipes until `row` is built and hittable.
    private func scroll(_ list: XCUIElement, to row: XCUIElement) {
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "The list did not appear")
        for _ in 0..<6 where !(row.exists && row.isHittable) { list.swipeUp() }
    }
}
