import XCTest

/// A tool call's arguments in the full-screen reader while the model is still
/// writing them, on the `tool-args-stream` preview: one generic call whose long
/// `task` argument streams in through the reducer, shown as YAML in its row.
/// A double tap on the row opens the reader, which keeps growing with the
/// arguments, follows the tail while the reader is at the bottom, stops
/// following once scrolled up, and shows the finished call's output at the end.
@MainActor
final class ToolArgsStreamReaderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI harness tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// Each test needs the stream from its start, so each launches its own app.
    private func launchPreview() {
        XCUIDevice.shared.orientation = .portrait
        let application = OppiTestLaunch.makeApp()
        application.launchArguments.append("--screenshot-preview")
        application.launchEnvironment["SCREENSHOT_SCREEN"] = "tool-args-stream"
        application.launch()
        app = application
        XCTAssertTrue(
            app.descendants(matching: .any)["screenshot.ready"].waitUntilExists(timeout: 10),
            "Tool arguments stream preview did not become ready"
        )
    }

    func testDoubleTapOpensStreamingArgumentsAndFollowsThem() throws {
        launchPreview()
        let row = app.descendants(matching: .any)["chat.timeline.row.spawn-worker"].firstMatch
        XCTAssertTrue(row.waitUntilExists(timeout: 6), "The streaming tool row did not appear")
        let inlineCode = row.descendants(matching: .any)["tool.notebook.code"].firstMatch
        XCTAssertTrue(inlineCode.waitUntilExists(timeout: 6), "The row did not show its arguments")
        XCTAssertEqual(app.staticTexts["toolArgsStream.state"].label, "streaming")

        argumentsPoint(in: row).doubleTap()
        let close = app.descendants(matching: .any)["fullScreen.code.close"].firstMatch
        XCTAssertTrue(close.waitUntilExists(timeout: 4), "A double tap on streaming arguments did not open the reader")

        let reader = app.scrollViews["fullscreen-notebook.scroll"].firstMatch
        XCTAssertTrue(reader.waitUntilExists(timeout: 4), "The reader does not show the arguments as the row does")
        let code = reader.textViews["tool.notebook.code"].firstMatch
        XCTAssertTrue(code.waitUntilExists(timeout: 4))
        XCTAssertTrue(text(of: code).hasPrefix("action: spawn"), "The reader shows the YAML arguments: \(text(of: code).prefix(80))")

        // The reader keeps growing with the arguments.
        let opened = text(of: code).count
        XCTAssertTrue(
            wait(timeout: 6) { self.text(of: code).count > opened + 100 },
            "The reader stayed at \(opened) characters while the arguments streamed"
        )

        // XCUITest clips a frame to what is on screen, so the tail shows as the
        // "Running…" line under the arguments, and the arguments outgrowing
        // the screen as their first line leaving it.
        let running = reader.staticTexts["Running…"].firstMatch
        XCTAssertTrue(
            wait(timeout: 20) { code.frame.minY <= reader.frame.minY + 1 },
            "The arguments never outgrew the reader: code \(code.frame), reader \(reader.frame)"
        )
        for _ in 0 ..< 3 {
            let before = text(of: code).count
            XCTAssertTrue(wait(timeout: 4) { self.text(of: code).count > before })
            XCTAssertTrue(
                wait(timeout: 1) { self.isOnScreen(running, in: reader) },
                "The reader left the streaming tail below the screen at \(text(of: code).count) characters"
            )
        }

        // Scrolled up, the reader stays where it was read while text grows.
        reader.swipeDown(velocity: .slow)
        XCTAssertFalse(isOnScreen(running, in: reader), "A swipe down did not leave the tail")
        let heldCount = text(of: code).count
        XCTAssertTrue(wait(timeout: 4) { self.text(of: code).count > heldCount + 100 })
        XCTAssertFalse(isOnScreen(running, in: reader), "The reader pulled a scrolled-up reader back to the tail")

        // The finished call: the final arguments and the call's output.
        let output = reader.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Spawned thinking-menu-order", "Spawned thinking-menu-order"))
            .firstMatch
        XCTAssertTrue(output.waitUntilExists(timeout: 45), "The reader did not show the finished call's output")
        XCTAssertTrue(text(of: code).hasSuffix("End of brief."), "The reader does not end on the final arguments")
    }

    func testLongPressOffersFullScreenForStreamingArguments() throws {
        launchPreview()
        let row = app.descendants(matching: .any)["chat.timeline.row.spawn-worker"].firstMatch
        XCTAssertTrue(row.waitUntilExists(timeout: 6), "The streaming tool row did not appear")
        let inlineCode = row.descendants(matching: .any)["tool.notebook.code"].firstMatch
        XCTAssertTrue(inlineCode.waitUntilExists(timeout: 6), "The row did not show its arguments")

        argumentsPoint(in: row).press(forDuration: 1.2)
        let open = app.buttons["Open Full Screen"].firstMatch
        XCTAssertTrue(open.waitUntilExists(timeout: 4), "A long press on streaming arguments offered no Open Full Screen")
        XCTAssertEqual(app.staticTexts["toolArgsStream.state"].label, "streaming")
        open.tap()

        let reader = app.scrollViews["fullscreen-notebook.scroll"].firstMatch
        XCTAssertTrue(reader.waitUntilExists(timeout: 4), "Open Full Screen did not show the arguments")
        let code = reader.textViews["tool.notebook.code"].firstMatch
        XCTAssertTrue(code.waitUntilExists(timeout: 4))
        let opened = text(of: code).count
        XCTAssertTrue(
            wait(timeout: 6) { self.text(of: code).count > opened + 100 },
            "The reader stayed at \(opened) characters while the arguments streamed"
        )
    }

    /// Inside the arguments. The cell, not its text view: the cell repaints
    /// its text on every streamed chunk, so a query for the text goes stale
    /// before the tap lands. Its top quarter is the arguments' first lines.
    private func argumentsPoint(in row: XCUIElement) -> XCUICoordinate {
        row.descendants(matching: .any)["tool.notebook.cell"].firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
    }

    /// The cell repaints its pieces as text streams in, and an element off
    /// screen has no hit point, so visibility is read from the frame.
    private func isOnScreen(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty && container.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func text(of element: XCUIElement) -> String {
        (element.value as? String) ?? ""
    }

    private func wait(timeout: TimeInterval, until condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }
}
