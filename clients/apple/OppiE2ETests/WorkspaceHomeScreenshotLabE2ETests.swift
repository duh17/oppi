import XCTest

/// Paired-server screenshot lab for workspace-home layout regressions.
///
/// This uses the existing E2E server/pairing harness instead of screenshot-preview
/// mocks, so the toolbar, server pill, workspace catalog refresh, and auth path are
/// the same path the app uses in a real paired simulator.
final class WorkspaceHomeScreenshotLabE2ETests: E2ETestCase {
    override var e2eLaunchesWorkspaceHomeOnly: Bool {
        true
    }

    override func seedE2EFixtures() throws {
        try seedLabWorkspaces(currentScenario.fixtures)
    }

    func testWorkspaceHomeWrappingScreenshotLab() throws {
        try runWorkspaceHomeLab(.wrapping)
    }

    func testWorkspaceHomeDenseCountsScreenshotLab() throws {
        try runWorkspaceHomeLab(.denseCounts)
    }

    private var currentScenario: WorkspaceHomeLabScenario {
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
