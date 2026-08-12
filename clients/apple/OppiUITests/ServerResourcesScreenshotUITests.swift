import XCTest

/// Deterministic visual proof for server-scoped Skills and Extensions.
@MainActor
final class ServerResourcesScreenshotUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Screenshot preview tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testServerResourcesNormalPreviews() throws {
        launchPreview(screen: "server-resources-skills")
        XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 5))
        assertServerScope()
        XCTAssertTrue(app.descendants(matching: .any)["serverResources.skills.release"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["serverResources.skills.error"].label.contains("Error"))
        saveScreenshot(name: "server-resources-skills-normal")

        app.terminate()
        launchPreview(screen: "server-resources-extensions")
        XCTAssertTrue(app.navigationBars["Extensions"].waitForExistence(timeout: 5))
        assertServerScope()
        XCTAssertTrue(app.descendants(matching: .any)["serverResources.extensions.oppi"].label.contains("Built-in extension"))
        XCTAssertTrue(app.descendants(matching: .any)["serverResources.extensions.error"].label.contains("Error"))
        saveScreenshot(name: "server-resources-extensions-normal")

        app.terminate()
        launchPreview(screen: "server-resources-oppi")
        assertObservedUsageRenders()

        let readOnly = oppiPolicyButton(titled: "Read only")
        XCTAssertTrue(
            scrollForward(to: readOnly),
            "Read only approval option did not become visible after scrolling"
        )
        readOnly.tap()

        let selectedPolicy = app.staticTexts["serverResources.oppi.selectedPolicy"]
        XCTAssertTrue(scrollForward(to: selectedPolicy, requireHittable: false))
        XCTAssertEqual(selectedPolicy.label, "Selected: Read only")
        let savedMessage = app.descendants(matching: .any)["extensions.oppi.savedMessage"]
        XCTAssertTrue(
            scrollForward(to: savedMessage, requireHittable: false)
                && savedMessage.label.contains("Saved on Preview Server"),
            "Saved/apply copy did not render after an approval policy selection"
        )
        saveScreenshot(name: "server-resources-oppi-normal")
    }

    func testServerResourcesObservedUsageMatchesBothThemeSurfaces() throws {
        for colorScheme in ["dark", "light"] {
            launchPreview(
                screen: "server-resources-oppi",
                environment: ["SCREENSHOT_COLOR_SCHEME": colorScheme]
            )
            assertObservedUsageRenders()
            XCTAssertFalse(app.screenshot().pngRepresentation.isEmpty)
            saveScreenshot(name: "server-resources-oppi-\(colorScheme)")
            app.terminate()
        }
    }

    func testServerResourcesSkillUsageScreenshotEvidence() throws {
        for colorScheme in ["light", "dark"] {
            launchPreview(
                screen: "server-resources-skill-detail",
                environment: ["SCREENSHOT_COLOR_SCHEME": colorScheme]
            )
            XCTAssertTrue(app.navigationBars["Testing"].waitForExistence(timeout: 5))
            let usage = app.descendants(matching: .any)["resourceDetail.usage"]
            XCTAssertTrue(usage.waitForExistence(timeout: 5))
            let summary = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Observed usage for the last 90 days"))
                .firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 5))
            usage.tap()
            XCTAssertTrue(
                app.buttons["90d"].waitForExistence(timeout: 5),
                "Skill usage range picker did not expose the 90-day selection"
            )
            app.buttons["90d"].tap()
            app.swipeUp()
            app.swipeUp()
            XCTAssertTrue(
                app.staticTexts["Daily Activity"].waitForExistence(timeout: 5),
                "Skill daily activity did not render in the expanded detail"
            )
            app.swipeUp()
            XCTAssertTrue(
                app.staticTexts["Signals"].waitForExistence(timeout: 5),
                "Skill signal breakdown did not render in the expanded detail"
            )
            XCTAssertTrue(
                app.staticTexts["Agent load"].waitForExistence(timeout: 5),
                "Skill agent-load signal did not render"
            )
            XCTAssertTrue(
                app.staticTexts["Explicit activation"].waitForExistence(timeout: 5),
                "Skill explicit-activation signal did not render"
            )
            let coverageHeading = app.staticTexts["Coverage"]
            XCTAssertTrue(
                scrollForward(to: coverageHeading, requireHittable: false, maxSwipes: 4),
                "Skill coverage did not render in the expanded detail"
            )
            let coverageText = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Recorded by this server since")
            ).firstMatch
            XCTAssertTrue(
                coverageText.exists,
                "Skill coverage did not show the recording start"
            )
            let disabledHistory = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Historical observed activity remains available")
            ).firstMatch
            XCTAssertTrue(
                scrollForward(to: disabledHistory, requireHittable: false, maxSwipes: 4),
                "Skill screenshot did not retain disabled-resource history copy"
            )
            saveScreenshot(
                name: "server-resources-skill-usage-\(colorScheme)",
                path: ".pi/tmp/resource-usage-recording/final-theme"
            )
            app.terminate()
        }
    }

    func testServerResourcesResourceDetailEvidence() throws {
        for (screen, title) in [
            ("server-resources-skill-detail", "Testing"),
            ("server-resources-extension-detail", "Review Helper"),
            ("server-resources-oppi-detail", "Oppi"),
        ] {
            launchPreview(screen: screen)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            let disabledToggle = app.descendants(matching: .any)["resourceDetail.disabledToggle"]
            XCTAssertTrue(
                scrollForward(to: disabledToggle, requireHittable: false, maxSwipes: 12),
                "Disabled history toggle did not render for \(title)"
            )
            let usage = app.descendants(matching: .any)["resourceDetail.usage"]
            XCTAssertTrue(
                scrollForward(to: usage, requireHittable: false, maxSwipes: 12),
                "Usage detail did not render for \(title)"
            )
            let historyCopy = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Historical observed activity remains available")
            ).firstMatch
            XCTAssertTrue(
                scrollForward(to: historyCopy, requireHittable: false, maxSwipes: 12),
                "Disabled-history copy did not render for \(title)"
            )
            saveScreenshot(name: "server-resources-\(screen)-ordinary")
            app.terminate()
        }
    }

    func testServerResourcesUsageStatesAndToolActivityEvidence() throws {
        launchPreview(screen: "server-resources-usage-states")
        XCTAssertTrue(app.navigationBars["Usage States"].waitForExistence(timeout: 5))
        for anchorIdentifier in [
            "usageStates.empty.title",
            "usageStates.partial.title",
            "usageStates.loading.title",
            "usageStates.failure.title",
        ] {
            let anchor = app.descendants(matching: .any)[anchorIdentifier]
            XCTAssertTrue(
                scrollForward(to: anchor, requireHittable: false, maxSwipes: 12),
                "Missing usage state fixture: \(anchorIdentifier)"
            )
        }
        saveScreenshot(name: "server-resources-usage-states")

        app.terminate()
        launchPreview(screen: "server-resources-tool-activity")
        XCTAssertTrue(app.navigationBars["Tool Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["toolActivity.details"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Built-in Tools"].waitForExistence(timeout: 5),
            "Tool Activity did not show built-in grouping"
        )
        XCTAssertTrue(
            app.staticTexts["Extension Tools"].waitForExistence(timeout: 5),
            "Tool Activity did not show extension grouping"
        )
        let toolActivityChart = app.staticTexts["Daily Activity"]
        XCTAssertTrue(
            scrollForward(to: toolActivityChart, requireHittable: false, maxSwipes: 12),
            "90-day Tool Activity chart did not render"
        )
        saveScreenshot(name: "server-resources-tool-activity-90d")
    }

    func testServerResourcesLiveThemeSwitchKeepsMountedSurfaceInPlace() throws {
        launchPreview(screen: "server-resources-theme-switch")
        XCTAssertTrue(app.navigationBars["Live Theme Switch"].waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)["themeSwitch.row"]
        let separator = app.descendants(matching: .any)["themeSwitch.separator"]
        let chart = app.descendants(matching: .any)["themeSwitch.chart"]
        let disclosure = app.descendants(matching: .any)["themeSwitch.disclosure"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(separator.waitForExistence(timeout: 5))
        XCTAssertTrue(
            scrollForward(to: disclosure, requireHittable: false, maxSwipes: 8),
            "Mounted disclosure did not render"
        )
        XCTAssertTrue(
            scrollForward(to: chart, requireHittable: false, maxSwipes: 8),
            "Mounted chart did not render"
        )
        let before = app.screenshot().pngRepresentation
        app.buttons["themeSwitch.toggle"].tap()
        XCTAssertTrue(app.staticTexts["Light"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.exists && separator.exists && disclosure.exists)
        XCTAssertTrue(chart.exists, "Mounted chart disappeared during the theme switch")
        XCTAssertNotEqual(before, app.screenshot().pngRepresentation, "Mounted surface did not repaint in place")
        saveScreenshot(name: "server-resources-theme-switch-in-process")
    }

    func testServerResourcesIPadDetailEvidence() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "server-resources-extension-detail")
        XCUIDevice.shared.orientation = .landscapeLeft
        try requireIPadCanvasIfAvailable()
        XCTAssertTrue(app.navigationBars["Review Helper"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["resourceDetail.usage"].waitForExistence(timeout: 5))
        saveScreenshot(name: "ipad-server-resources-extension-detail")
    }

    func testServerResourcesOfflineAndPendingPreviews() throws {
        launchPreview(screen: "server-resources-cached-offline")
        XCTAssertTrue(app.navigationBars["Extensions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["serverResources.cachedWarning"].waitForExistence(timeout: 5))
        saveScreenshot(name: "server-resources-cached-offline")

        app.terminate()
        launchPreview(screen: "server-resources-oppi-pending")
        let readOnly = oppiPolicyButton(titled: "Read only")
        XCTAssertTrue(scrollForward(to: readOnly, requireHittable: false))
        XCTAssertTrue(readOnly.exists)
        let pending = app.descendants(matching: .any)["serverResources.oppi.pending"]
        XCTAssertTrue(scrollForward(to: pending, requireHittable: false))
        XCTAssertTrue(pending.label.contains("Saving approval behavior"))
        saveScreenshot(name: "server-resources-oppi-pending")

    }

    private func oppiPolicyButton(titled title: String) -> XCUIElement {
        let rawValue: String
        switch title {
        case "Confirm destructive only": rawValue = "confirmDestructiveOnly"
        case "Confirm all changes": rawValue = "confirmAllChanges"
        case "Read only": rawValue = "readOnly"
        default: rawValue = title
        }
        return app.descendants(matching: .any)["extensions.oppi.policy.\(rawValue)"]
    }

    private func assertObservedUsageRenders() {
        XCTAssertTrue(
            app.staticTexts["Observed Usage"].waitForExistence(timeout: 5),
            "Observed Usage section heading did not render"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["resourceUsage.details"].waitForExistence(timeout: 5),
            "Observed Usage detail disclosure did not render"
        )
        let summary = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Observed usage for the last 30 days"))
            .firstMatch
        XCTAssertTrue(
            summary.waitForExistence(timeout: 5),
            "Observed Usage summary did not finish rendering"
        )
    }

    private func scrollForward(
        to element: XCUIElement,
        requireHittable: Bool = true,
        maxSwipes: Int = 6
    ) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists, !requireHittable || element.isHittable {
                return true
            }
            app.swipeUp()
        }
        return element.exists && (!requireHittable || element.isHittable)
    }

    private func assertServerScope() {
        let scope = app.descendants(matching: .any)["serverResources.serverScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertEqual(scope.label, "Current server: Preview Server")
        XCTAssertEqual(scope.value as? String, "Connected")
    }

    private func requireIPadCanvasIfAvailable() throws {
        guard min(app.frame.width, app.frame.height) >= 700 else {
            throw XCTSkip("iPad screenshot evidence requires an iPad simulator")
        }
    }

    private func launchPreview(screen: String, environment: [String: String] = [:]) {
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()

        let ready = app.descendants(matching: .any)["screenshot.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 8), "Screenshot preview did not become ready")
        let portrait = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let application = object as? XCUIApplication else { return false }
                return application.frame.height > application.frame.width
            },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [portrait], timeout: 5),
            .completed,
            "Screenshot preview did not settle into portrait orientation"
        )
    }

    private func saveScreenshot(
        name: String,
        path: String = "/tmp/oppi-screenshots"
    ) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
