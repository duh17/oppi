import XCTest

/// Real paired-server proof for the server-global Skills and Extensions routes.
///
/// The native harness creates an isolated OPPI_DATA_DIR and PI_CODING_AGENT_DIR,
/// so this journey can persist the built-in Oppi setting without touching a
/// developer's Pi configuration. Its catalog intentionally relies on the
/// server's always-present built-in Oppi row; fixture-only normal/error/offline
/// resource rows live in the screenshot-preview suite.
@MainActor
final class ServerResourcesE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool {
        true
    }

    override var e2eAutoCreatesSessionOnLaunch: Bool {
        false
    }

    func testIPhoneSkillsSearchShowsNoResults() throws {
        XCUIDevice.shared.orientation = .portrait

        openCompactSidebar()
        tap(app.buttons["workspace.skills.open"], named: "Skills sidebar destination")
        XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 10))
        assertServerScope()

        let search = app.searchFields["Search skills"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Skills search field did not render")
        search.tap()
        search.typeText("no-matching-e2e-skill")
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 5))
        try saveLabScreenshot(name: "iphone-server-resources-skills-no-results-e2e")
    }

    func testIPhoneExtensionsSavesOppiReadOnlyPolicy() throws {
        XCUIDevice.shared.orientation = .portrait

        openCompactSidebar()
        tap(app.buttons["workspace.extensions.open"], named: "Extensions sidebar destination")
        XCTAssertTrue(app.navigationBars["Extensions"].waitForExistence(timeout: 10))
        assertServerScope()

        let oppi = app.buttons["extensions.row.oppi"]
        XCTAssertTrue(oppi.waitForExistence(timeout: 15), "Built-in Oppi extension did not load from the E2E server")
        XCTAssertTrue(oppi.label.contains("Built-in extension"), "Oppi row lost its built-in provenance")
        tap(oppi, named: "Oppi extension")

        let enabled = app.switches["extensions.oppi.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10), "Oppi enable toggle did not render")
        XCTAssertEqual(
            app.switches.matching(identifier: "extensions.oppi.enabled").count,
            1,
            "Oppi availability must expose one native switch element"
        )
        XCTAssertGreaterThanOrEqual(
            enabled.frame.height,
            44,
            "Oppi availability needs a real 44pt vertical hit target"
        )

        let wasEnabled = isOn(enabled)
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        guard waitForSwitch(enabled, isOn: !wasEnabled, timeout: 10) else {
            let visibleError = app.staticTexts["extensions.oppi.enabled.error"]
            let detail = visibleError.exists ? visibleError.label : "No visible mutation error rendered."
            XCTFail("Upper edge of Oppi availability target did not toggle exactly once. \(detail)")
            return
        }
        if wasEnabled {
            enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            guard waitForSwitch(enabled, isOn: true, timeout: 10) else {
                XCTFail("Oppi availability did not restore after hit-target proof.")
                return
            }
        }

        let readOnly = app.descendants(matching: .any)["extensions.oppi.policy.readOnly"]
        XCTAssertTrue(readOnly.waitForExistence(timeout: 10), "Read only policy did not render")
        tap(readOnly, named: "Read only approval policy")
        let saved = app.descendants(matching: .any)["extensions.oppi.savedMessage"]
        if !saved.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        guard saved.waitForExistence(timeout: 10) else {
            let visibleError = app.descendants(matching: .any)["extensions.oppi.policy.error"]
            let detail = visibleError.exists ? visibleError.label : "No visible mutation error rendered."
            XCTFail("Saved/apply copy did not render. \(detail)")
            return
        }
        XCTAssertTrue(saved.label.hasPrefix("Saved on "))
        XCTAssertTrue(saved.label.contains("New sessions use this setting. Reload an active session to apply it now."))
        try saveLabScreenshot(name: "iphone-server-resources-oppi-read-only-e2e")
    }

    func testIPadSidebarRemainsSelectedThroughServerResourcesAndOppiDetail() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        try requireIPadSplitCanvas()

        let sidebar = app.scrollViews["workspace.sidebar.scroll"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15), "iPad workspace sidebar did not render")

        let skills = app.buttons["workspace.skills.open"]
        let extensions = app.buttons["workspace.extensions.open"]
        tap(skills, named: "Skills sidebar destination")
        XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 10))
        XCTAssertTrue(sidebar.exists && sidebar.isHittable, "Skills replaced the iPad sidebar instead of detail")
        XCTAssertTrue(skills.isSelected, "Skills row did not expose selected state")
        XCTAssertFalse(extensions.isSelected, "Extensions was selected before it was opened")

        tap(extensions, named: "Extensions sidebar destination")
        XCTAssertTrue(app.navigationBars["Extensions"].waitForExistence(timeout: 10))
        XCTAssertTrue(sidebar.exists && sidebar.isHittable, "Extensions replaced the iPad sidebar instead of detail")
        XCTAssertTrue(extensions.isSelected, "Extensions row did not expose selected state")
        XCTAssertFalse(skills.isSelected, "Skills and Extensions rows were both selected")

        let oppi = app.buttons["extensions.row.oppi"]
        XCTAssertTrue(oppi.waitForExistence(timeout: 15), "Built-in Oppi row did not load")
        tap(oppi, named: "Oppi extension")
        XCTAssertTrue(app.navigationBars["Oppi"].waitForExistence(timeout: 10))
        XCTAssertTrue(sidebar.exists && sidebar.isHittable, "Oppi detail replaced the iPad sidebar")
        XCTAssertTrue(extensions.isSelected, "Extensions selection was lost while showing Oppi detail")
        try saveLabScreenshot(name: "ipad-server-resources-oppi-detail-e2e")
    }

    private func openCompactSidebar() {
        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button", timeout: 10)
        XCTAssertTrue(
            app.buttons["workspace.skills.open"].waitForExistence(timeout: 10),
            "Compact sidebar did not reveal Skills"
        )
    }

    private func assertServerScope() {
        let scope = app.descendants(matching: .any)["serverCatalog.server.passive"]
        XCTAssertTrue(scope.waitForExistence(timeout: 10), "Single-server catalog scope row did not render")
        XCTAssertTrue(scope.label.hasPrefix("Current server:"), "Catalog scope row did not name the active server")
        XCTAssertEqual(scope.value as? String, "Connected")
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        let value = (toggle.value as? String)?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "on"
    }

    private func waitForSwitch(_ toggle: XCUIElement, isOn expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isOn(toggle) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return isOn(toggle) == expected
    }

    private func requireIPadSplitCanvas() throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let size = app.frame.size
            if min(size.width, size.height) >= 700, size.width >= 980, size.width >= size.height {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        try XCTSkipUnless(
            min(app.frame.width, app.frame.height) >= 700,
            "Server-resource split proof requires an iPad simulator"
        )
        XCTFail("iPad simulator did not reach a landscape split canvas: \(app.frame.size)")
    }
}
