import XCTest

/// Regression coverage for the chat-attached file browser entry point.
///
/// The Files control must open the in-chat Changed/All file panel. A tap must
/// not push the workspace file-browser route or SwiftUI's missing-destination
/// fallback screen.
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
        XCTAssertFalse(app.buttons["fullscreen-code.dismiss"].exists, "Write activation presented the output modal")

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

final class ChatFileBrowserE2ETests: E2ETestCase {
    override var e2eStartsInAutoCreatedChat: Bool { true }

    @MainActor
    func testChatToolbarFilesButtonOpensAttachedPanel() throws {
        dismissExtensionSheetIfNeeded(timeout: 3)

        let filesButtons = app.buttons.matching(identifier: "chat.toolbar.files")
        let filesButton = filesButtons.firstMatch
        XCTAssertTrue(
            filesButton.waitForExistence(timeout: 10),
            "Chat Files toolbar button did not appear"
        )
        XCTAssertTrue(filesButton.isHittable, "Chat Files toolbar button is not hittable")
        let backButton = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(backButton.exists, "Chat should use one leading pill with Back and Files")
        XCTAssertLessThan(
            filesButton.frame.midX,
            app.frame.midX,
            "Chat Files toolbar button should live on the leading side of the navigation bar"
        )
        XCTAssertLessThan(
            backButton.frame.maxX,
            filesButton.frame.minX + 2,
            "Back and Files controls should be adjacent in the leading pill"
        )
        XCTAssertFalse(
            app.collectionViews["workspace.list"].exists,
            "Workspace list should not be the active accessibility surface before tapping chat Files"
        )

        filesButton.tap()

        let panelTitle = app.staticTexts["Files"]
        XCTAssertTrue(
            panelTitle.waitForExistence(timeout: 2),
            "Tapping chat Files should open the attached file panel, not reveal Workspace Home or fallback navigation"
        )
        XCTAssertTrue(
            app.buttons["Changed"].waitForExistence(timeout: 3),
            "Changed tab did not appear in attached file panel"
        )
        XCTAssertTrue(
            app.buttons["All"].waitForExistence(timeout: 3),
            "All tab did not appear in attached file panel"
        )
        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 2),
            "File panel should use the shared sheet navigation container"
        )
        XCTAssertFalse(
            app.buttons["chat.files.fullscreen.expand"].exists,
            "File panel should rely on the native sheet detent instead of a custom expand button"
        )
    }
}
