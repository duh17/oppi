import Foundation
import XCTest

/// The full-screen document reader opened from a chat's Write row, on a paired
/// server: prose reads in a centered column on a wide iPad window, a wide table
/// and a long code block widen past it (centered with it), and a narrow iPhone
/// window keeps the full width. Screenshots land in `/tmp/oppi-screenshots/`.
@MainActor
final class ReaderCenteredColumnScreenshotE2ETests: E2ETestCase {
    override var e2eStartsInAutoCreatedChat: Bool { true }

    private static let proseMarker = "Discussion prep, not a plan."
    private static let fixture = """
    # Game dev with agents — prep notes

    \(proseMarker) A read-only survey of the checkout and its docs, plus web \
    sources cited inline. This paragraph is long enough to show whether the \
    reader runs it edge to edge across a wide window or keeps it in a \
    comfortable reading column.

    ## What already exists

    | Capability | Where | Game-dev use |
    | --- | --- | --- |
    | Stored image and video attachments in tool rows, details.media, H.264 MP4 | docs/attachment-rendering.md; server/src/sdk-backend.ts | Playtest frames and clips in the chat |
    | Markdown embeds of workspace files: images, inline video with poster and tap to play | attachment-rendering.md, Markdown embeds | Agent replies with a clip; sprite contact sheets; music review |

    ```sh
    oppi playtest run --scene arena --frames 600 --seed 42 --capture .pi/playtest/run-12/clip.mp4 --summary .pi/playtest/run-12/summary.json
    ```

    ```sh
    oppi playtest list
    ```

    The human closes a second, slower loop: play on the phone, say what feels wrong.
    """

    func testIPadLandscapeReaderCentersProseAndWidensTheTable() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape()
        try XCTSkipUnless(min(app.frame.width, app.frame.height) >= 700, "needs the iPad device profile")
        let reader = try openFixtureInFullScreenReader()
        try saveLabScreenshot(name: "reader-centered-column-ipad-landscape")

        let window = app.windows.firstMatch.frame
        let prose = reader.prose.frame
        let table = reader.table.frame
        XCTAssertLessThan(prose.width, window.width * 0.75, "a wide window caps the prose column: \(prose)")
        XCTAssertEqual(prose.midX, window.midX, accuracy: 24, "the prose column is centered: \(prose)")
        XCTAssertGreaterThan(table.width, prose.width + 40, "the wide table may use more than the prose width: \(table)")
        XCTAssertEqual(table.midX, window.midX, accuracy: 24, "the widened table stays centered: \(table)")
    }

    func testIPhoneReaderKeepsTheFullWidth() throws {
        try XCTSkipIf(min(app.frame.width, app.frame.height) >= 700, "needs the iPhone device profile")
        let reader = try openFixtureInFullScreenReader()
        try saveLabScreenshot(name: "reader-centered-column-iphone")

        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(reader.prose.frame.width, window.width - 48, "a narrow window keeps the full width")
    }

    // MARK: - Helpers

    private func waitForLandscape() {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, app.frame.width < app.frame.height {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Writes the fixture where the native server can read it, reports a Write
    /// of it in the chat, and double-taps the row: the chat's own full-screen
    /// reader, as a person reaches it.
    private func openFixtureInFullScreenReader() throws -> (prose: XCUIElement, table: XCUIElement) {
        let token = UUID().uuidString.prefix(8).lowercased()
        let path = "/tmp/oppi-reader-column-\(token).md"
        try Self.fixture.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertEqual(waitForWebSocketConnected(timeout: 20), "connected")
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let toolId = "reader-column-write-\(token)"
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": "write",
            "toolCallId": toolId,
            "args": ["path": path, "content": Self.fixture],
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "tool_end", "tool": "write", "toolCallId": toolId])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])

        let row = app.descendants(matching: .any)["chat.timeline.row.\(toolId)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Write row did not appear")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.16)).tap()
        let viewport = app.collectionViews["chat.timeline.row.\(toolId).markdownViewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10), "Write row did not expand")
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.45)).doubleTap()

        let body = app.descendants(matching: .any)["full-screen.markdown.body"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 15), "the full-screen Markdown reader did not open")
        let prose = body.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", Self.proseMarker, Self.proseMarker))
            .firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 15), "the reader did not draw the prose")
        let table = body.descendants(matching: .any)["markdown.table"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15), "the reader did not draw the table")
        // Let the reader's layout settle after the push before measuring.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        return (prose, table)
    }
}
