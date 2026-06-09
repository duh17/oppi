import Foundation
import XCTest

/// Paired-server reproduction for large markdown web_fetch output rendering.
///
/// Fixture source: `web_fetch` of Node.js fs documentation that produced a
/// 7s+ client hang and multi-GB memory warning on device.
@MainActor
final class LargeMarkdownToolRowE2ETests: E2ETestCase {
    func testLargeWebFetchMarkdownExpansionDoesNotHang() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let markdown = try loadMarkdownFixture()
        XCTAssertGreaterThan(markdown.utf8.count, 300_000, "Fixture must stay large enough to reproduce markdown pressure")

        let toolId = "large-markdown-web-fetch-e2e"
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setToolsExpanded",
            "toolsExpanded": false,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": "web_fetch",
            "toolCallId": toolId,
            "args": [
                "url": "https://nodejs.org/api/fs.html#fscreatereadstreampath-options",
                "format": "markdown",
            ],
        ])
        try sendMarkdownToolOutputChunks(sessionId: sessionId, toolId: toolId, markdown: markdown)
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": "web_fetch",
            "toolCallId": toolId,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])

        let toolRow = app.descendants(matching: .any)["chat.timeline.row.\(toolId)"]
        XCTAssertTrue(toolRow.waitForExistence(timeout: 15), "Large web_fetch tool row did not appear")
        let collapsedFrame = stableFrame(of: toolRow)
        try saveLabScreenshot(name: "large-markdown-web-fetch-collapsed-e2e")

        let started = Date()
        tapToolRowChrome(toolRow)
        let expandedFrame = waitForFrame(of: toolRow, timeout: 45) { frame in
            frame.height > collapsedFrame.height + 160
        }
        let expandMs = Date().timeIntervalSince(started) * 1_000
        try saveLabScreenshot(name: "large-markdown-web-fetch-expanded-e2e")

        let fullScreenStarted = Date()
        openExpandedContentFullScreen(toolRow, toolId: toolId)
        let fullScreenMarkdownBody = app.collectionViews["full-screen.markdown.body"].firstMatch
        XCTAssertTrue(fullScreenMarkdownBody.waitForExistence(timeout: 15), "Large markdown full-screen reader did not open")
        let fullScreenMs = Date().timeIntervalSince(fullScreenStarted) * 1_000
        try saveLabScreenshot(name: "large-markdown-web-fetch-full-screen-e2e")
        try writeReproMetrics(
            expandMs: expandMs,
            fullScreenMs: fullScreenMs,
            collapsedFrame: collapsedFrame,
            expandedFrame: expandedFrame
        )

        XCTAssertGreaterThan(
            expandedFrame.height,
            collapsedFrame.height + 160,
            "Expanded row did not grow enough to prove large markdown was opened. collapsed=\(collapsedFrame), expanded=\(expandedFrame)"
        )
        XCTAssertLessThan(
            expandMs,
            5_000,
            "Large markdown expansion exceeded 5s hang threshold: \(Int(expandMs))ms. This reproduces the client-side rendering stall."
        )
        XCTAssertLessThan(
            fullScreenMs,
            5_000,
            "Large markdown full-screen open exceeded 5s hang threshold: \(Int(fullScreenMs))ms."
        )
    }

    private func loadMarkdownFixture() throws -> String {
        let bundle = Bundle(for: Self.self)
        let candidates = [
            bundle.url(forResource: "node-fs-web-fetch", withExtension: "md", subdirectory: "Fixtures"),
            bundle.url(forResource: "node-fs-web-fetch", withExtension: "md"),
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first, "Missing node-fs-web-fetch.md fixture")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sendMarkdownToolOutputChunks(sessionId: String, toolId: String, markdown: String) throws {
        let chunkCharacters = 20_000
        let totalBytes = markdown.utf8.count
        var lowerBound = markdown.startIndex
        while lowerBound < markdown.endIndex {
            let upperBound = markdown.index(
                lowerBound,
                offsetBy: chunkCharacters,
                limitedBy: markdown.endIndex
            ) ?? markdown.endIndex
            try sendE2EHarnessMessage(sessionId: sessionId, [
                "type": "tool_output",
                "toolCallId": toolId,
                "output": String(markdown[lowerBound..<upperBound]),
                "mode": "append",
                "truncated": false,
                "totalBytes": totalBytes,
            ])
            lowerBound = upperBound
        }
    }

    private func tapToolRowChrome(_ row: XCUIElement) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Tool row did not exist before tap")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.16)).tap()
    }

    private func openExpandedContentFullScreen(_ row: XCUIElement, toolId: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Tool row did not exist before full-screen activation")
        let viewport = app.collectionViews["chat.timeline.row.\(toolId).markdownViewport"].firstMatch
        if viewport.waitForExistence(timeout: 3) {
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.45)).doubleTap()
            return
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.34)).doubleTap()
    }

    private func stableFrame(of element: XCUIElement) -> CGRect {
        _ = element.waitForExistence(timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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

    private func writeReproMetrics(
        expandMs: TimeInterval,
        fullScreenMs: TimeInterval,
        collapsedFrame: CGRect,
        expandedFrame: CGRect
    ) throws {
        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("large-markdown-web-fetch-metrics.json")
        let payload: [String: Any] = [
            "expandMs": Int(expandMs),
            "fullScreenMs": Int(fullScreenMs),
            "collapsedHeight": collapsedFrame.height,
            "expandedHeight": expandedFrame.height,
            "fixtureBytes": try loadMarkdownFixture().utf8.count,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputURL, options: .atomic)
        print("[LargeMarkdownToolRowE2E] metrics: \(outputURL.path) expandMs=\(Int(expandMs)) fullScreenMs=\(Int(fullScreenMs))")
    }
}
