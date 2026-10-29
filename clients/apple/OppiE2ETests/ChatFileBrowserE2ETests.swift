import XCTest

/// A completed Write row opens the file's current bytes, not the recorded
/// arguments, and a child link keeps the back stack. (The chat Files panel is
/// covered by `ChatRoutesUITests.testFilesPanelBrowsesTheCheckoutAndCloses`.)
@MainActor
final class WriteCurrentFileNavigationE2ETests: E2ETestCase {
    override var e2eStartsInAutoCreatedChat: Bool { true }

    func testCompletedWriteOpensCurrentFileAndPreservesChildBackStack() throws {
        try verifyCurrentWriteNavigation(emptyWrite: false)
    }

    func testEmptyRelativeWriteOpensCurrentFileAndPreservesChildBackStack() throws {
        try verifyCurrentWriteNavigation(emptyWrite: true)
    }

    private func verifyCurrentWriteNavigation(emptyWrite: Bool) throws {
        let token = UUID().uuidString.lowercased()
        let currentPath = "/tmp/oppi-write-current-\(token).md"
        let childPath = "/tmp/oppi-write-child-\(token).md"
        let currentMarker = "CURRENT FILE BYTES \(token)"
        let childMarker = "CHILD FILE BYTES \(token)"
        let recordedMarker = "RECORDED WRITE ARGUMENT \(token)"
        try "# Current\n\n\(currentMarker)\n\n[Open child](\((childPath as NSString).lastPathComponent))\n"
            .write(toFile: currentPath, atomically: true, encoding: .utf8)
        try "# Child\n\n\(childMarker)\n".write(toFile: childPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: currentPath)
            try? FileManager.default.removeItem(atPath: childPath)
        }

        XCTAssertEqual(waitForWebSocketConnected(timeout: 20), "connected", "Source session must be connected before activation")
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let toolId = "write-current-file-e2e-\(token)"
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": "write",
            "toolCallId": toolId,
            "args": [
                "path": emptyWrite ? (currentPath as NSString).lastPathComponent : currentPath,
                "content": emptyWrite ? "" : recordedMarker,
            ],
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": "write",
            "toolCallId": toolId,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])

        let row = app.descendants(matching: .any)["chat.timeline.row.\(toolId)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Write row did not appear")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.16)).tap()
        if emptyWrite {
            let affordance = app.staticTexts["Open current file"].firstMatch
            XCTAssertTrue(affordance.waitForExistence(timeout: 10), "Empty write has no reachable expanded surface")
            affordance.doubleTap()
        } else {
            let viewport = app.collectionViews["chat.timeline.row.\(toolId).markdownViewport"].firstMatch
            XCTAssertTrue(viewport.waitForExistence(timeout: 10), "Write row did not expand")
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.45)).doubleTap()
        }

        let currentText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", currentMarker))
            .firstMatch
        let recordedText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", recordedMarker))
            .firstMatch
        XCTAssertTrue(currentText.waitForExistence(timeout: 15), "Current file bytes did not load")
        XCTAssertFalse(recordedText.exists, "Recorded write arguments replaced current bytes")

        let childLink = app.links["Open child"]
        XCTAssertTrue(childLink.waitForExistence(timeout: 10), "Current file child link did not render")
        childLink.tap()
        let childText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", childMarker))
            .firstMatch
        XCTAssertTrue(childText.waitForExistence(timeout: 15), "Child file did not open")

        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "File Back button did not appear")
        backButton.tap()
        XCTAssertTrue(currentText.waitForExistence(timeout: 10), "Back did not return to current file")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.timeline"].waitForExistence(timeout: 10), "Back did not return to chat")
    }
}
