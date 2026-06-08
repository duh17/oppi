import XCTest

@MainActor
final class FullScreenReviewCommentUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Full-screen review comment UI test is simulator-only")
#endif
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testFullScreenCodeSelectionShowsNativeActionBar() throws {
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--fullscreen-review-comment-harness",
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launchEnvironment["PI_FULLSCREEN_REVIEW_COMMENT_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"].waitForExistence(timeout: 10),
            "Full-screen review comment harness did not become ready"
        )

        let selectButton = app.buttons["harness.reviewComment.select"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5), "Select-code harness control did not appear")
        selectButton.tap()

        XCTAssertFalse(
            app.buttons["review-comment.selection-bar"].waitForExistence(timeout: 1),
            "Full-screen text selection should use the native edit menu only, not a standalone Comment bar"
        )

        let commentAction = try XCTUnwrap(
            waitForActionBarElement(named: "Comment", timeout: 5),
            "Native selection action bar did not expose Comment"
        )
        let copyAction = try XCTUnwrap(
            waitForActionBarElement(named: "Copy", timeout: 2),
            "Native selection action bar did not expose Copy"
        )
        XCTAssertTrue(commentAction.exists)
        XCTAssertTrue(copyAction.exists)
        saveScreenshot(name: "fullscreen-review-comment-action-bar")

        tapElement(commentAction)
        XCTAssertTrue(
            app.descendants(matching: .any)["review-comment.inline-composer"].waitForExistence(timeout: 5),
            "Native Comment action did not open the inline comment composer"
        )
        saveScreenshot(name: "fullscreen-review-comment-inline-composer")
    }

    private func waitForActionBarElement(named title: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = [
                app.buttons[title],
                app.menuItems[title],
                app.staticTexts[title],
                app.descendants(matching: .any)[title],
            ]
            if let match = candidates.first(where: { $0.exists }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func saveScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: outputURL, options: .atomic)
    }
}
