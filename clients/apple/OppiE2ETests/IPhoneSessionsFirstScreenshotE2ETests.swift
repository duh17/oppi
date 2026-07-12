import XCTest

/// iPhone screenshot lab for the sessions-first inbox.
///
/// Runs through the paired E2E server so the screenshot includes the same
/// pairing, workspace refresh, and session projection path as the app uses
/// outside preview mode.
@MainActor
final class IPhoneSessionsFirstScreenshotE2ETests: E2ETestCase {
    private let anchorWorkspaceName = "e2e-workspace"
    private let stoppedIncognitoSessionName = "Hidden Incognito Session"
    nonisolated(unsafe) private var swipeRegressionSessionId: String?
    nonisolated(unsafe) private var swipeRegressionStoppedSessionId: String?

    override var e2eLaunchesSessionsInboxOnly: Bool {
        true
    }

    override var e2eAutoCreatesSessionOnLaunch: Bool {
        false
    }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchArguments += [
            "-dev.chenda.Oppi.theme.id", "light",
        ]
    }

    override func seedE2EFixtures() throws {
        let anchorWorkspaceId = try e2eWorkspaceId(named: anchorWorkspaceName)

        if name.contains("testSessionRowLeadingSwipeDoesNotNavigate") {
            swipeRegressionSessionId = try createLabSessions(
                count: 1,
                workspaceId: anchorWorkspaceId,
                stopAfterCreate: false
            ).first
            swipeRegressionStoppedSessionId = try createLabSessions(
                count: 1,
                workspaceId: anchorWorkspaceId,
                stopAfterCreate: true
            ).first
        } else if name.contains("testIPhoneAllActiveSessionsInboxScreenshot") {
            try createLabSessions(count: 1, workspaceId: anchorWorkspaceId, stopAfterCreate: false)
            let secondWorkspaceId = try createLabWorkspace(named: "Sidebar Review Queue")
            try createLabSessions(count: 1, workspaceId: secondWorkspaceId, stopAfterCreate: false)
        } else if name.contains("testIPhoneRecentStoppedSessionsInboxScreenshot") {
            try createLabSessions(count: 1, workspaceId: anchorWorkspaceId, stopAfterCreate: true)
            let response = try e2eLabAPIJSON(
                method: "POST",
                path: "/workspaces/\(anchorWorkspaceId)/sessions",
                body: [
                    "name": stoppedIncognitoSessionName,
                    "ephemeral": true,
                ]
            )
            let session = try XCTUnwrap(
                response["session"] as? [String: Any],
                "Incognito session create response missing session"
            )
            let sessionId = try XCTUnwrap(
                session["id"] as? String,
                "Incognito session create response missing id"
            )
            _ = try e2eLabAPIJSON(
                method: "POST",
                path: "/workspaces/\(anchorWorkspaceId)/sessions/\(sessionId)/stop"
            )
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

    func testSessionRowLeadingSwipeDoesNotNavigate() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionId = try XCTUnwrap(swipeRegressionSessionId, "Swipe regression session was not seeded")
        let stoppedSessionId = try XCTUnwrap(
            swipeRegressionStoppedSessionId,
            "Stopped swipe regression session was not seeded"
        )
        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()

        let row = app.buttons["session.nav.\(sessionId)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Seeded session row did not appear")

        row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.50))
            .press(
                forDuration: 0.05,
                thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.50))
            )

        XCTAssertTrue(sessionList.exists, "Leading session-row swipe navigated away from All Sessions")
        XCTAssertFalse(app.collectionViews["chat.timeline"].exists, "Leading session-row swipe opened chat")

        row.swipeLeft()
        XCTAssertTrue(
            app.buttons["session.stop.\(sessionId)"].waitForExistence(timeout: 5),
            "Trailing session-row swipe did not expose Stop"
        )
        row.swipeRight()

        let stoppedRow = app.buttons["session.nav.\(stoppedSessionId)"]
        XCTAssertTrue(stoppedRow.waitForExistence(timeout: 10), "Seeded stopped session row did not appear")
        stoppedRow.swipeLeft()
        XCTAssertTrue(
            app.buttons["session.resume.\(stoppedSessionId)"].waitForExistence(timeout: 5),
            "Trailing stopped-session swipe did not expose Resume"
        )
        XCTAssertTrue(
            app.buttons["session.delete.\(stoppedSessionId)"].waitForExistence(timeout: 5),
            "Trailing stopped-session swipe did not expose Delete"
        )
        stoppedRow.swipeRight()

        tap(row, named: "session row")
        XCTAssertTrue(
            app.collectionViews["chat.timeline"].waitForExistence(timeout: 15),
            "Tapping the session row did not open chat"
        )
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

    func testIPhoneRecentStoppedSessionsInboxScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()

        let stoppedHeader = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace.sessionList.stopped-day-")
        ).firstMatch
        XCTAssertTrue(stoppedHeader.waitForExistence(timeout: 15), "Recent stopped section did not appear")

        let stoppedRowTitle = app.staticTexts.matching(identifier: "Screenshot Lab Session 1").firstMatch
        XCTAssertTrue(stoppedRowTitle.waitForExistence(timeout: 10), "Today's stopped session was not expanded")
        XCTAssertFalse(
            app.staticTexts[stoppedIncognitoSessionName].exists,
            "Stopped incognito session should disappear from All Sessions"
        )
        XCTAssertTrue(
            waitForStableFrame(of: stoppedRowTitle, timeout: 2),
            "Stopped session row did not settle before screenshot capture"
        )
        try saveLabScreenshot(name: "iphone-recent-stopped-sessions-inbox-e2e")

        tap(stoppedHeader, named: "recent stopped section")
        let rowCollapsed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: stoppedRowTitle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [rowCollapsed], timeout: 5),
            .completed,
            "Recent stopped section did not collapse"
        )
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
        let createWorkspaceButton = app.buttons["workspace.create.sidebar.open"]
        if !waitForHittable(createWorkspaceButton, timeout: 2) {
            tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")
        }
        XCTAssertTrue(waitForHittable(createWorkspaceButton, timeout: 10), "Sidebar did not open")
        XCTAssertFalse(app.buttons["workspace.sidebar.close"].exists, "Sidebar should not show a redundant close button")

        try saveLabScreenshot(name: "iphone-workspace-sidebar-e2e")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.50))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.50))
            )
        XCTAssertTrue(
            waitForNotHittable(createWorkspaceButton, timeout: 5),
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

    func testIPhoneWorkspaceDeepLinkPresentsPrefilledCreate() throws {
        XCUIDevice.shared.orientation = .portrait
        let url = try XCTUnwrap(
            URL(string: "oppi://workspace?path=/tmp&name=Deep%20Link%20Workspace")
        )
        app.open(url)

        let nameField = app.textFields["workspace.create.name"]
        let pathField = app.textFields["workspace.create.hostMount"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20), "Workspace deep link did not open the create form")
        XCTAssertTrue(pathField.waitForExistence(timeout: 5), "Workspace deep link path field did not appear")
        XCTAssertEqual(nameField.value as? String, "Deep Link Workspace")
        XCTAssertEqual(pathField.value as? String, "/tmp")
    }

    func testIPhoneWorkspaceSidebarScrolls() throws {
        XCUIDevice.shared.orientation = .portrait

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "iPhone sessions inbox did not appear")
        sessionList.swipeDown()
        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")

        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.create.sidebar.open"], timeout: 10),
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
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.50)).tap()
        XCTAssertTrue(
            waitForHittable(app.buttons["workspace.sidebar.open"], timeout: 5),
            "Tapping the session card did not dismiss the workspace sidebar"
        )
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForHittableState(true, of: element, timeout: timeout)
    }

    private func waitForNotHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForHittableState(false, of: element, timeout: timeout)
    }

    private func waitForHittableState(
        _ isHittable: Bool,
        of element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == %@", NSNumber(value: isHittable)),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForStableFrame(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame: CGRect?
        var stableSampleCount = 0

        while Date() < deadline {
            if element.exists {
                let frame = element.frame
                if !frame.isEmpty {
                    if frame == previousFrame {
                        stableSampleCount += 1
                        if stableSampleCount >= 2 {
                            return true
                        }
                    } else {
                        previousFrame = frame
                        stableSampleCount = 0
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return false
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
