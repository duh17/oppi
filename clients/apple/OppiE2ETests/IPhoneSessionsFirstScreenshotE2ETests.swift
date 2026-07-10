import XCTest

/// iPhone screenshot lab for the sessions-first inbox.
///
/// Runs through the paired E2E server so the screenshot includes the same
/// pairing, workspace refresh, and session projection path as the app uses
/// outside preview mode.
@MainActor
final class IPhoneSessionsFirstScreenshotE2ETests: E2ETestCase {
    private let anchorWorkspaceName = "e2e-workspace"

    override var e2eLaunchesSessionsInboxOnly: Bool {
        true
    }

    override var e2eAutoCreatesSessionOnLaunch: Bool {
        false
    }

    override func seedE2EFixtures() throws {
        let anchorWorkspaceId = try e2eWorkspaceId(named: anchorWorkspaceName)

        if name.contains("testIPhoneAllActiveSessionsInboxScreenshot") {
            try createLabSessions(count: 1, workspaceId: anchorWorkspaceId, stopAfterCreate: false)
            let secondWorkspaceId = try createLabWorkspace(named: "Sidebar Review Queue")
            try createLabSessions(count: 1, workspaceId: secondWorkspaceId, stopAfterCreate: false)
        } else if name.contains("testIPhoneAllSessionsSidebarEdgeSwipeScreenshot") {
            _ = try createLabWorkspace(named: "Sidebar Review Queue")
        } else if name.contains("testIPhoneWorkspaceScopedSeparateControlsScreenshot") {
            try createLabSessions(count: 1, workspaceId: anchorWorkspaceId, stopAfterCreate: false)
            try createLabSessions(count: 2, workspaceId: anchorWorkspaceId, stopAfterCreate: true)
        } else if name.contains("testIPhoneHierarchicalBackSwipeNavigation") {
            try createLabSessions(count: 1, workspaceId: anchorWorkspaceId, stopAfterCreate: false)
        } else if name.contains("testIPhoneWorkspaceSidebarScrolls") {
            for index in 1...18 {
                _ = try createLabWorkspace(named: "Scroll Workspace \(index)")
            }
        }
    }

    func testIPhoneAllActiveSessionsInboxScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()

        XCTAssertTrue(
            app.staticTexts[anchorWorkspaceName].waitForExistence(timeout: 20)
                || app.staticTexts["Sidebar Review Queue"].waitForExistence(timeout: 2)
                || app.staticTexts["Screenshot Lab Session 1"].waitForExistence(timeout: 2),
            "Seeded iPhone active session rows did not appear after refresh"
        )
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Current server:")).firstMatch.waitForExistence(timeout: 10),
            "Server switcher pill did not appear on the right side of the sessions inbox"
        )

        try saveLabScreenshot(name: "iphone-all-active-sessions-inbox-e2e")
    }

    func testIPhoneAllSessionsSidebarEdgeSwipeScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.50))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.50))
            )
        if !app.buttons["workspace.create.sidebar.open"].waitForExistence(timeout: 2) {
            tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")
        }
        let createWorkspaceButton = app.buttons["workspace.create.sidebar.open"]
        XCTAssertTrue(createWorkspaceButton.waitForExistence(timeout: 10), "Sidebar did not open")

        try saveLabScreenshot(name: "iphone-workspace-sidebar-e2e")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.50))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.50))
            )
        let sidebarDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: createWorkspaceButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sidebarDismissed], timeout: 5),
            .completed,
            "Left swipe did not dismiss the workspace sidebar"
        )
    }

    func testIPhoneWorkspaceScopedSeparateControlsScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait
        openAnchorWorkspace()

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "Workspace-scoped sessions inbox did not appear")
        XCTAssertTrue(app.buttons["All Sessions"].waitForExistence(timeout: 10), "Native All Sessions back button missing")
        XCTAssertTrue(app.buttons["workspace.files.open"].waitForExistence(timeout: 10), "Workspace files button missing")
        XCTAssertTrue(app.buttons["workspace.newSession"].waitForExistence(timeout: 10), "New session button missing")

        try saveLabScreenshot(name: "iphone-workspace-scoped-separated-controls-e2e")

        swipeBack()
        XCTAssertTrue(app.staticTexts["All Sessions"].waitForExistence(timeout: 5), "Edge swipe did not return to All Sessions")
    }

    func testIPhoneHierarchicalBackSwipeNavigation() throws {
        XCUIDevice.shared.orientation = .portrait
        openAnchorWorkspace()

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "Workspace-scoped sessions inbox did not appear")

        let sessionButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "session.nav.")
        ).firstMatch
        XCTAssertTrue(sessionButton.waitForExistence(timeout: 15), "Workspace session row did not appear")
        tap(sessionButton, named: "workspace session row")
        XCTAssertTrue(app.collectionViews["chat.timeline"].waitForExistence(timeout: 15), "Chat timeline did not appear")

        swipeBack()
        XCTAssertTrue(app.buttons["All Sessions"].waitForExistence(timeout: 10), "Chat swipe did not return to workspace sessions")

        swipeBack()
        XCTAssertTrue(app.staticTexts["All Sessions"].waitForExistence(timeout: 10), "Workspace swipe did not return to All Sessions")
    }

    func testIPhoneWorkspaceSidebarScrolls() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()
        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")

        XCTAssertTrue(
            app.buttons["workspace.create.sidebar.open"].waitForExistence(timeout: 10),
            "Workspace sidebar did not appear"
        )

        let lastWorkspace = app.buttons["workspace.open.Scroll Workspace 9"]
        for _ in 0..<6 where !lastWorkspace.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.82))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.22))
                )
        }
        XCTAssertTrue(lastWorkspace.isHittable, "Workspace sidebar did not scroll to the final workspace")
        tap(app.buttons["workspace.sidebar.close"], named: "workspace sidebar close button")
    }

    private func openAnchorWorkspace() {
        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 5), "Sessions inbox missing before workspace selection")
        sessionList.swipeDown()
        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")
        let openWorkspaceButton = app.buttons["workspace.open.\(anchorWorkspaceName)"]
        XCTAssertTrue(openWorkspaceButton.waitForExistence(timeout: 10), "Anchor workspace did not appear in sidebar")
        tap(openWorkspaceButton, named: "anchor workspace button")
    }

    private func swipeBack() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.50))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.50))
            )
    }
}
