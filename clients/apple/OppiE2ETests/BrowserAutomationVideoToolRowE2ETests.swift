import Foundation
import XCTest

/// Paired-server proof for a browser_automation_video-style tool result:
/// a recorded browser MP4 is materialized as a session attachment, appears in
/// the extension tool row, and launches the authenticated native video player.
@MainActor
final class BrowserAutomationVideoToolRowE2ETests: E2ETestCase {
    func testBrowserAutomationVideoAttachmentPlaysBackFromExtensionToolRow() throws {
        let (_, fileName) = try publishBrowserAutomationVideoToolRow()

        let videoTitle = app.descendants(matching: .any)["toolRow.videoAttachment.title"]
        let videoSubtitle = app.descendants(matching: .any)["toolRow.videoAttachment.subtitle"]
        let videoPlayButton = app.descendants(matching: .any)["toolRow.videoAttachment.play"]
        XCTAssertTrue(videoTitle.waitForExistence(timeout: 10), "Expanded video title did not appear")
        XCTAssertTrue(videoSubtitle.waitForExistence(timeout: 5), "Expanded video subtitle did not appear")
        XCTAssertTrue(videoPlayButton.waitForExistence(timeout: 5), "Expanded video play button did not appear")
        XCTAssertEqual(videoTitle.label, fileName)
        XCTAssertTrue(videoSubtitle.label.contains("video/mp4"), "Video subtitle should describe MP4 media")

        tap(videoPlayButton, named: "browser automation video play button", timeout: 5)
        XCTAssertTrue(
            app.otherElements["videoPlayer.native"].waitForExistence(timeout: 15),
            "Native video player did not launch from the extension tool row"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        try saveLabScreenshot(name: "browser-automation-video-tool-row-playback-e2e")
    }

    /// The tool row's Play pushes the full-screen `.video` reader; its own
    /// Back and the chat's Back must each land once (reader, then list).
    func testFullScreenVideoReaderBackReturnsToChatThenSessionList() throws {
        let (_, fileName) = try publishBrowserAutomationVideoToolRow()

        let videoPlayButton = app.descendants(matching: .any)["toolRow.videoAttachment.play"]
        XCTAssertTrue(videoPlayButton.waitForExistence(timeout: 10), "Expanded video play button did not appear")
        tap(videoPlayButton, named: "browser automation video play button", timeout: 5)

        let readerBack = app.buttons["fullscreen-video.back"]
        XCTAssertTrue(
            readerBack.waitForExistence(timeout: 15),
            "Full-screen video reader did not appear for \(fileName)"
        )
        let player = app.otherElements["videoPlayer.native"]
        XCTAssertTrue(player.waitForExistence(timeout: 15), "Reader video player did not appear")
        try saveLabScreenshot(name: "browser-automation-video-reader")

        readerBack.tap()
        XCTAssertTrue(
            waitForElementToExist(app.textViews["chat.input"], timeout: 10),
            "Reader Back did not return to the chat"
        )

        let chatBack = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(chatBack.waitForExistence(timeout: 10), "Chat Back did not appear after the reader")
        chatBack.tap()
        XCTAssertTrue(
            waitForElementToExist(app.collectionViews["workspace.sessionList"], timeout: 15),
            "Chat Back did not reach the session list. chatBack=\(app.buttons["chat.toolbar.back"].exists)"
        )
        XCTAssertTrue(
            waitUntilGone(app.textViews["chat.input"], timeout: 5),
            "Chat stayed on screen after Back to the session list"
        )
    }

    private func publishBrowserAutomationVideoToolRow() throws -> (toolId: String, fileName: String) {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let toolId = "browser-automation-video-e2e-\(UUID().uuidString.prefix(6).lowercased())"
        let videoURL = try browserAutomationVideoFixtureURL()
        let videoData = try Data(contentsOf: videoURL)
        let fileName = videoURL.lastPathComponent

        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setToolsExpanded",
            "toolsExpanded": false,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": "browser_automation_video",
            "toolCallId": toolId,
            "args": [
                "url": "https://www.google.com",
                "commands": [
                    "type Hacker News into Google",
                    "submit search",
                    "open Hacker News result",
                ],
            ],
        ])

        let summary = [
            "Browser automation video recorded.",
            "URL: https://www.google.com",
            "Final URL: https://news.ycombinator.com/",
            "Title: Hacker News",
            "MP4: stored session attachment",
            "Verified: Google query was entered and the browser reached Hacker News.",
        ].joined(separator: "\n")

        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_output",
            "toolCallId": toolId,
            "output": summary,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": "browser_automation_video",
            "toolCallId": toolId,
            "details": [
                "expandedText": summary,
                "presentationFormat": "markdown",
                "url": "https://www.google.com",
                "finalURL": "https://news.ycombinator.com/",
                "title": "Hacker News",
                "media": [[
                    "kind": "video",
                    "mimeType": "video/mp4",
                    "fileName": fileName,
                    "sizeBytes": videoData.count,
                    "width": 640,
                    "height": 360,
                    "base64": videoData.base64EncodedString(),
                ]],
            ],
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])

        let toolRow = app.descendants(matching: .any)["chat.timeline.row.\(toolId)"]
        XCTAssertTrue(toolRow.waitForExistence(timeout: 10), "Browser automation tool row did not appear")
        tapToolRowChrome(toolRow)
        return (toolId, fileName)
    }

    private func browserAutomationVideoFixtureURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["OPPI_BROWSER_VIDEO_FIXTURE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Browser automation video fixture missing at \(path)")
            return URL(fileURLWithPath: path)
        }

        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile
            .deletingLastPathComponent() // OppiE2ETests
            .deletingLastPathComponent() // apple
            .deletingLastPathComponent() // clients
            .deletingLastPathComponent() // repo root
        let fallback = repoRoot.appendingPathComponent(".internal/browser-automation-video/google-hn-small/google-hacker-news-small2.mp4")
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw XCTSkip("Run browser_automation_video first or set OPPI_BROWSER_VIDEO_FIXTURE_PATH")
        }
        return fallback
    }

    private func tapToolRowChrome(_ row: XCUIElement) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Tool row did not exist before tap")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.16)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }
}
