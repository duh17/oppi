import XCTest

/// Reproduces the dense workspace shape from the July 2026 navigation-stall incident.
///
/// The hot projection remains large, but only today's stopped rows should mount by
/// default. Repeated chat push/pop cycles guard the NavigationStack transition that
/// previously blocked the main thread long enough for the watchdog to terminate Oppi.
@MainActor
final class SessionListNavigationStressE2ETests: E2ETestCase {
    private let workspaceName = "Dense Navigation \(UUID().uuidString.prefix(8))"
    nonisolated(unsafe) private var workspaceId: String?
    nonisolated(unsafe) private var activeSessionId: String?
    nonisolated(unsafe) private var stoppedSessionIds: [String] = []

    override var e2eLaunchesSessionsInboxOnly: Bool {
        true
    }

    override var e2eAutoCreatesSessionOnLaunch: Bool {
        false
    }

    override func seedE2EFixtures() throws {
        guard name.contains("testDenseWorkspace") else { return }

        let workspaceId = try createLabWorkspace(named: workspaceName)
        self.workspaceId = workspaceId
        activeSessionId = try createLabSessions(
            count: 1,
            workspaceId: workspaceId,
            stopAfterCreate: false
        ).first

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let twoDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let threeDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))

        stoppedSessionIds += try createStoppedSessionFixtures(
            count: 20,
            workspaceId: workspaceId,
            lastActivity: today,
            namePrefix: "Dense Today"
        )
        stoppedSessionIds += try createStoppedSessionFixtures(
            count: 52,
            workspaceId: workspaceId,
            lastActivity: yesterday,
            namePrefix: "Dense Yesterday"
        )
        stoppedSessionIds += try createStoppedSessionFixtures(
            count: 52,
            workspaceId: workspaceId,
            lastActivity: twoDaysAgo,
            namePrefix: "Dense Two Days Ago"
        )
        stoppedSessionIds += try createStoppedSessionFixtures(
            count: 24,
            workspaceId: workspaceId,
            lastActivity: threeDaysAgo,
            namePrefix: "Dense Three Days Ago"
        )
    }

    override func tearDownWithError() throws {
        defer {
            workspaceId = nil
            activeSessionId = nil
            stoppedSessionIds = []
            try? super.tearDownWithError()
        }

        // Remove server fixtures only after the app is gone. Deleting 148 rows
        // while their workspace list is mounted creates teardown churn that is
        // unrelated to the navigation transition under test. Clearing the base
        // class handle ensures the next E2E setup performs a real relaunch.
        terminateSharedApp()

        guard let workspaceId else { return }
        if let activeSessionId {
            _ = try e2eLabAPIJSON(
                method: "POST",
                path: "/workspaces/\(workspaceId)/sessions/\(activeSessionId)/stop"
            )
            _ = try e2eLabAPIJSON(
                method: "DELETE",
                path: "/workspaces/\(workspaceId)/sessions/\(activeSessionId)"
            )
        }
        try deleteStoppedSessionFixtures(
            sessionIds: stoppedSessionIds,
            workspaceId: workspaceId
        )
        _ = try e2eLabAPIJSON(method: "DELETE", path: "/workspaces/\(workspaceId)")
    }

    func testDenseWorkspaceExpandsTodayOnlyAndNavigatesWithoutStalling() throws {
        XCUIDevice.shared.orientation = .portrait
        let sessionId = try XCTUnwrap(activeSessionId, "Active navigation session was not seeded")

        openWorkspace()

        let groupHeaders = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace.stoppedGroup.day-")
        )
        XCTAssertTrue(
            groupHeaders.firstMatch.waitForExistence(timeout: 15),
            "Stopped-session day groups did not appear"
        )
        XCTAssertEqual(groupHeaders.firstMatch.value as? String, "Expanded")

        let collapsedHeaders = groupHeaders.matching(
            NSPredicate(format: "value == %@", "Collapsed")
        )
        let sessionList = app.collectionViews["workspace.sessionList"]
        for _ in 0..<6 where collapsedHeaders.count < 2 {
            sessionList.swipeUp()
        }
        XCTAssertGreaterThanOrEqual(
            collapsedHeaders.count,
            2,
            "Yesterday and older hot day groups should start collapsed"
        )
        XCTAssertFalse(
            app.staticTexts["Dense Yesterday 1"].exists,
            "Yesterday's stopped rows mounted despite the today-only default"
        )

        let activeRow = app.buttons["session.nav.\(sessionId)"]
        for _ in 0..<4 where !activeRow.isHittable {
            sessionList.swipeDown()
        }
        XCTAssertTrue(waitForHittable(activeRow, timeout: 15), "Active session row did not appear")

        var returnDurations: [TimeInterval] = []
        for cycle in 1...10 {
            tap(activeRow, named: "dense workspace active session", timeout: 10)
            let backButton = app.buttons["chat.toolbar.back"]
            XCTAssertTrue(backButton.waitForExistence(timeout: 15), "Chat did not open on cycle \(cycle)")

            let startedAt = ProcessInfo.processInfo.systemUptime
            tap(backButton, named: "chat back button", timeout: 5)
            XCTAssertTrue(
                waitForHittable(activeRow, timeout: 3),
                "Workspace list did not become interactive after chat pop on cycle \(cycle)"
            )
            returnDurations.append(ProcessInfo.processInfo.systemUptime - startedAt)
        }

        let slowestReturn = try XCTUnwrap(returnDurations.max())
        let returnMilliseconds = returnDurations.map { Int(($0 * 1_000).rounded()) }
        print("METRIC dense_workspace_chat_pop_ms=\(returnMilliseconds)")
        print("METRIC dense_workspace_chat_pop_max_ms=\(Int((slowestReturn * 1_000).rounded()))")
        XCTAssertLessThan(
            slowestReturn,
            3,
            "Dense workspace chat pop exceeded the 3-second regression budget: \(slowestReturn)s"
        )

        try saveLabScreenshot(name: "dense-session-list-today-only-navigation")
    }

    func testSharedAppRelaunchesAfterDenseCleanup() {
        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 15),
            "The shared app did not relaunch after dense-fixture cleanup"
        )
    }

    private func openWorkspace() {
        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "All Sessions did not appear")
        sessionList.swipeDown()
        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar", timeout: 10)
        tap(app.buttons["workspace.open.\(workspaceName)"], named: "dense workspace", timeout: 10)
        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 15),
            "Workspace session list did not appear"
        )
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
