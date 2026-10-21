import XCTest

/// A session list must re-fit its rows for their real width after returning
/// from a chat. Status, elapsed-time, and seen updates land while the chat
/// covers the list; the reconfigure that follows must not keep a cell height
/// the row has outgrown, or rows come back crammed and overlapping.
@MainActor
final class SessionRowRelayoutE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceId: String?
    nonisolated(unsafe) private var workingSessionId: String?
    nonisolated(unsafe) private var stoppedSessionId: String?

    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    override func seedE2EFixtures() throws {
        guard name.contains("testRowsKeepTheirHeightAfterChatBack") else { return }

        let workspaceId = try createLabWorkspace(named: "Row Relayout \(UUID().uuidString.prefix(6))")
        self.workspaceId = workspaceId
        let nowMs = Date().timeIntervalSince1970 * 1_000
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/fixtures/session-threads",
            body: [
                "workspaceId": workspaceId,
                "nowMs": nowMs,
                "sessions": [
                    [
                        "key": "working",
                        "name": "GLM server start",
                        "status": "busy",
                        "createdAtOffsetMs": -3_600_000,
                        "lastActivityOffsetMs": -1_000,
                        "model": "anthropic/claude-opus-5-5",
                        "cost": 1.25,
                        "contextTokens": 140_000,
                        "contextWindow": 1_000_000,
                        "messageCount": 12,
                    ],
                    [
                        "key": "stopped",
                        "name": "start server",
                        "status": "stopped",
                        "createdAtOffsetMs": -28_800_000,
                        "lastActivityOffsetMs": -10_800_000,
                        "model": "openai-codex/gpt-6-luna",
                        "cost": 2.4,
                        "contextTokens": 87_000,
                        "contextWindow": 272_000,
                        "messageCount": 30,
                    ],
                ],
                "interactions": [],
            ]
        )
        let ids = try XCTUnwrap(response["sessionIds"] as? [String: String], "Session fixture ids missing")
        workingSessionId = try XCTUnwrap(ids["working"])
        stoppedSessionId = try XCTUnwrap(ids["stopped"])
    }

    override func tearDownWithError() throws {
        defer {
            workspaceId = nil
            workingSessionId = nil
            stoppedSessionId = nil
            try? super.tearDownWithError()
        }
        terminateSharedApp()
        _ = try? e2eLabAPIJSON(method: "DELETE", path: "/e2e/ui/fixtures/session-threads")
        if let workspaceId {
            _ = try? e2eLabAPIJSON(method: "DELETE", path: "/workspaces/\(workspaceId)")
        }
    }

    func testRowsKeepTheirHeightAfterChatBack() throws {
        let stoppedId = try XCTUnwrap(stoppedSessionId, "Stopped fixture was not seeded")
        let workingId = try XCTUnwrap(workingSessionId, "Working fixture was not seeded")

        let list = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "All Sessions list did not appear")
        beat(1)

        let stoppedRow = app.buttons["session.nav.\(stoppedId)"]
        XCTAssertTrue(reveal(stoppedRow, in: list), "Seeded stopped row never appeared")
        let workingRow = app.buttons["session.nav.\(workingId)"]
        XCTAssertTrue(reveal(workingRow, in: list), "Seeded working row never appeared")

        let stoppedHeightBefore = stoppedRow.frame.height
        let workingHeightBefore = workingRow.frame.height
        try saveLabScreenshot(name: "session-rows-before-chat")

        tap(stoppedRow, named: "stopped session row")
        XCTAssertTrue(
            app.collectionViews["chat.timeline"].waitForExistence(timeout: 15),
            "Tapping the session row did not open chat"
        )
        beat(3)

        navigateBackToWorkspace()
        XCTAssertTrue(list.waitForExistence(timeout: 10), "All Sessions list did not come back")
        beat(1)
        try saveLabScreenshot(name: "session-rows-after-chat")

        let stoppedRowAfter = app.buttons["session.nav.\(stoppedId)"]
        let workingRowAfter = app.buttons["session.nav.\(workingId)"]

        XCTAssertGreaterThanOrEqual(
            stoppedRowAfter.frame.height,
            stoppedHeightBefore - 1,
            "Stopped row came back shorter than before the chat"
        )
        XCTAssertGreaterThanOrEqual(
            workingRowAfter.frame.height,
            workingHeightBefore - 1,
            "Working row came back shorter than before the chat"
        )
    }

    /// Scrolls `element` into the list until a tap can land on it.
    private func reveal(_ element: XCUIElement, in list: XCUIElement) -> Bool {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            list.swipeUp()
        }
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            list.swipeDown()
        }
        return element.exists && element.isHittable
    }

    /// Lets the recorded run show each state before the next interaction.
    private func beat(_ seconds: TimeInterval = 1.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
