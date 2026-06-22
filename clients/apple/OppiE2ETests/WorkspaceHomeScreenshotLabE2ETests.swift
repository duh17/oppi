import XCTest

/// Paired-server screenshot lab for workspace-home layout regressions.
///
/// This uses the existing E2E server/pairing harness instead of screenshot-preview
/// mocks, so the toolbar, server pill, workspace catalog refresh, and auth path are
/// the same path the app uses in a real paired simulator.
@MainActor
final class WorkspaceHomeScreenshotLabE2ETests: E2ETestCase {
    override var e2eLaunchesWorkspaceHomeOnly: Bool {
        true
    }

    override func seedE2EFixtures() throws {
        try seedLabWorkspaces(WorkspaceHomeLabScenario.allFixtures)
    }

    func testWorkspaceHomeWrappingScreenshotLab() throws {
        try runWorkspaceHomeLab(.wrapping)
    }

    func testWorkspaceHomeDenseCountsScreenshotLab() throws {
        try runWorkspaceHomeLab(.denseCounts)
    }

    func testQuickSessionComposerGrowthFitsMeasuredContent() throws {
        let workspaceList = app.collectionViews["workspace.list"]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 10), "Workspace home list not visible")

        tap(app.buttons["workspace.quickSession.start"], named: "quick session button")
        defer { dismissQuickSessionSheetIfNeeded() }

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10), "Quick Session input not visible")
        waitForE2EDiagnostic("e2e.quickSession.detentHeight", timeout: 5) { $0 == "150" }

        tap(chatInput, named: "quick session input", timeout: 5)
        let focusPredicate = NSPredicate(format: "hasKeyboardFocus == true")
        if !focusPredicate.evaluate(with: chatInput) {
            chatInput.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        }
        let focusDeadline = Date().addingTimeInterval(5)
        while !focusPredicate.evaluate(with: chatInput) && Date() < focusDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(focusPredicate.evaluate(with: chatInput), "Quick Session input did not gain keyboard focus")

        chatInput.typeText("first quick session line\nsecond quick session line\nthird quick session line")

        let detentLabel = waitForE2EDiagnostic("e2e.quickSession.detentHeight", timeout: 10) { value in
            guard let height = Double(value) else { return false }
            return height > 150 && height < 260
        }
        let detentHeight = try XCTUnwrap(Double(detentLabel))
        XCTAssertLessThan(detentHeight, 260, "Quick Session jumped to the tall detent bucket")

        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5), "Quick Session grabber not visible")
        let blankHeaderGap = chatInput.frame.minY - grabber.frame.maxY
        XCTAssertLessThan(blankHeaderGap, 90, "Quick Session left a large blank header above the composer")

        try saveLabScreenshot(name: "quick-session-measured-detent-composer-growth-e2e")
    }

    private nonisolated var currentScenario: WorkspaceHomeLabScenario {
        if name.contains("testWorkspaceHomeDenseCountsScreenshotLab") {
            return .denseCounts
        }
        return .wrapping
    }

    private func runWorkspaceHomeLab(_ scenario: WorkspaceHomeLabScenario) throws {
        let workspaceList = app.collectionViews["workspace.list"]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 10), "Workspace home list not visible")
        dismissExtensionSheetIfNeeded(timeout: 3)
        workspaceList.swipeDown()

        XCTAssertTrue(
            app.staticTexts[scenario.anchorWorkspaceName].waitForExistence(timeout: 20),
            "Seeded workspace did not appear after refresh"
        )

        try saveLabScreenshot(name: scenario.screenshotName)
    }

    private func dismissQuickSessionSheetIfNeeded() {
        let grabber = app.buttons["Sheet Grabber"]
        guard grabber.waitForExistence(timeout: 1) else { return }
        grabber.swipeDown()
        if grabber.waitForExistence(timeout: 1) {
            grabber.swipeDown()
        }
    }
}

private enum WorkspaceHomeLabScenario {
    case wrapping
    case denseCounts

    var screenshotName: String {
        switch self {
        case .wrapping:
            return "workspace-home-wrapping-e2e"
        case .denseCounts:
            return "workspace-home-dense-counts-e2e"
        }
    }

    var anchorWorkspaceName: String {
        switch self {
        case .wrapping:
            return "Oppi Config"
        case .denseCounts:
            return "Archive Saturation Workspace"
        }
    }

    static var allFixtures: [E2ELabWorkspaceFixture] {
        WorkspaceHomeLabScenario.wrapping.fixtures + WorkspaceHomeLabScenario.denseCounts.fixtures
    }

    var fixtures: [E2ELabWorkspaceFixture] {
        switch self {
        case .wrapping:
            return [
                E2ELabWorkspaceFixture("Oppi Config", stoppedSessionCount: 4),
                E2ELabWorkspaceFixture("voebb-watchdog", stoppedSessionCount: 2),
                E2ELabWorkspaceFixture("Metro Companion App With A Long Name"),
                E2ELabWorkspaceFixture("Oppi Apple Clients"),
            ]
        case .denseCounts:
            return [
                E2ELabWorkspaceFixture("Archive Saturation Workspace", stoppedSessionCount: 12),
                E2ELabWorkspaceFixture("Active Session Count Workspace", activeSessionCount: 2, stoppedSessionCount: 3),
                E2ELabWorkspaceFixture("Long Workspace Name With Dense Status Metadata", stoppedSessionCount: 8),
            ]
        }
    }
}
