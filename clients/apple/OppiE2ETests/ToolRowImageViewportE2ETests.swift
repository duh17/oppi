import UIKit
import XCTest

/// Paired-server proof that read-tool image rows expand to the rendered image
/// height instead of keeping a stale text viewport.
@MainActor
final class ToolRowImageViewportE2ETests: E2ETestCase {
    func testToolRowReadImageFitsViewportToRenderedImageHeight() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let toolId = "tool-row-image-e2e"
        let imagePath = "/tmp/tool-row-image-proof.png"
        let imageData = try XCTUnwrap(Self.imageViewportPNG())
        let output = """
        Read image file [image/png]
        [Image: original 300x180, displayed at 300x180. Multiply coordinates by 1.00 to map to original image.]
        """

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
            "args": ["path": imagePath],
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_output",
            "toolCallId": toolId,
            "output": output,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": "read",
            "toolCallId": toolId,
            "details": [
                "media": [[
                    "kind": "image",
                    "mimeType": "image/png",
                    "fileName": "tool-row-image-proof.png",
                    "sizeBytes": imageData.count,
                    "width": 300,
                    "height": 180,
                    "base64": imageData.base64EncodedString(),
                ]],
            ],
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])

        let toolRow = app.descendants(matching: .any)["chat.timeline.row.\(toolId)"]
        XCTAssertTrue(toolRow.waitForExistence(timeout: 10), "Image tool row did not appear")
        let collapsedFrame = stableFrame(of: toolRow)
        tapToolRowChrome(toolRow)

        let imageViewport = toolRow.descendants(matching: .any)["toolRow.readMedia.imageViewport"]
        XCTAssertTrue(imageViewport.waitForExistence(timeout: 10), "Expanded image viewport did not appear")
        let viewportFrame = waitForFrame(of: imageViewport, timeout: 5) { frame in
            guard frame.width > 120 else { return false }
            let expectedHeight = frame.width * Self.imageViewportHeightToWidthRatio
            return abs(frame.height - expectedHeight) <= 6
        }
        let expandedFrame = stableFrame(of: toolRow)
        let expectedHeight = viewportFrame.width * Self.imageViewportHeightToWidthRatio

        XCTAssertLessThanOrEqual(
            abs(viewportFrame.height - expectedHeight),
            6,
            "Image viewport should match the rendered image aspect-fit height. frame=\(viewportFrame), expectedHeight=\(expectedHeight)"
        )
        XCTAssertGreaterThan(
            viewportFrame.width,
            expandedFrame.width - 40,
            "Image should use the available tool-row width. image=\(viewportFrame), row=\(expandedFrame)"
        )
        XCTAssertGreaterThan(expandedFrame.height, collapsedFrame.height + 80, "Tool row should expand around the image viewport")

        let debugTextPredicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            "original 300x180",
            "original 300x180"
        )
        XCTAssertFalse(
            toolRow.descendants(matching: .any).matching(debugTextPredicate).firstMatch.exists,
            "Read-tool image metadata should be hidden when the rendered image is visible"
        )
        try saveLabScreenshot(name: "tool-row-image-viewport-e2e")
    }

    private static let imageViewportHeightToWidthRatio: CGFloat = 180.0 / 300.0

    private static func imageViewportPNG() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 180))
        return renderer.image { context in
            UIColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 300, height: 180))
            UIColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 20, y: 20, width: 260, height: 140))
        }.pngData()
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
