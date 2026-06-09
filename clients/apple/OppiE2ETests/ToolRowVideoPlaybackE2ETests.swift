import XCTest

/// Paired-server proof that read-tool video rows expand into a compact launch
/// row and collapse again without using the large text viewport.
@MainActor
final class ToolRowVideoPlaybackE2ETests: E2ETestCase {
    func testToolRowVideoExpandsAndCollapsesWithCompactViewport() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let toolId = "tool-row-video-e2e"
        let videoPath = "tool-row-video-proof.mp4"

        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setToolsExpanded",
            "toolsExpanded": false,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": "read",
            "toolCallId": toolId,
            "args": ["path": videoPath],
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_output",
            "toolCallId": toolId,
            "output": "Read video file [video/mp4]",
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": "read",
            "toolCallId": toolId,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])

        let toolRow = app.descendants(matching: .any)["chat.timeline.row.\(toolId)"]
        XCTAssertTrue(toolRow.waitForExistence(timeout: 10), "Video tool row did not appear")
        let collapsedFrame = stableFrame(of: toolRow)
        XCTAssertGreaterThan(collapsedFrame.height, 24, "Collapsed row should have a visible header")

        tapToolRowChrome(toolRow)

        let videoTitle = app.descendants(matching: .any)["toolRow.videoAttachment.title"]
        let videoSubtitle = app.descendants(matching: .any)["toolRow.videoAttachment.subtitle"]
        let videoPlayButton = app.descendants(matching: .any)["toolRow.videoAttachment.play"]
        XCTAssertTrue(videoTitle.waitForExistence(timeout: 10), "Expanded video title did not appear")
        XCTAssertTrue(videoSubtitle.waitForExistence(timeout: 5), "Expanded video subtitle did not appear")
        XCTAssertTrue(videoPlayButton.waitForExistence(timeout: 5), "Expanded video play button did not appear")

        let expandedFrame = waitForFrame(of: toolRow, timeout: 5) { frame in
            frame.height > collapsedFrame.height + 24
        }
        let titleFrame = stableFrame(of: videoTitle)
        let subtitleFrame = stableFrame(of: videoSubtitle)
        let playFrame = stableFrame(of: videoPlayButton)
        let chatInputFrame = stableFrame(of: app.textViews["chat.input"])
        let mediaClusterHeight = [titleFrame, subtitleFrame, playFrame]
            .reduce(CGRect.null) { $0.union($1) }
            .height

        XCTAssertLessThan(
            expandedFrame.height,
            190,
            "Expanded video rows should stay compact instead of taking the large text viewport. frame=\(expandedFrame)"
        )
        XCTAssertGreaterThan(mediaClusterHeight, 32, "Video controls should not collapse. clusterHeight=\(mediaClusterHeight)")
        XCTAssertLessThan(mediaClusterHeight, 90, "Video controls should fit one compact media row. clusterHeight=\(mediaClusterHeight)")
        XCTAssertLessThan(
            max(titleFrame.maxY, subtitleFrame.maxY, playFrame.maxY),
            chatInputFrame.minY,
            "Expanded video row should remain above the composer. title=\(titleFrame), subtitle=\(subtitleFrame), play=\(playFrame), input=\(chatInputFrame)"
        )
        try saveLabScreenshot(name: "tool-row-video-expanded-e2e")

        tapToolRowChrome(toolRow)
        let collapsedAgainFrame = waitForFrame(of: toolRow, timeout: 5) { frame in
            frame.height < expandedFrame.height - 20
        }
        XCTAssertLessThan(
            collapsedAgainFrame.height,
            expandedFrame.height - 20,
            "Tapping the tool row again should collapse the video viewport"
        )
        try saveLabScreenshot(name: "tool-row-video-collapsed-e2e")
    }

    private func tapToolRowChrome(_ row: XCUIElement) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Tool row did not exist before tap")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.16)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func stableFrame(of element: XCUIElement) -> CGRect {
        _ = element.waitForExistence(timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        return element.frame
    }

    private func waitForFrame(
        of element: XCUIElement,
        timeout: TimeInterval,
        matching predicate: (CGRect) -> Bool
    ) -> CGRect {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = element.frame
        while Date() < deadline {
            latest = element.frame
            if element.exists, !latest.isEmpty, predicate(latest) {
                return latest
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return latest
    }
}
