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

    func testFullScreenCodeSelectionDoesNotShowStandaloneCommentBar() throws {
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

        let commentBar = app.buttons["review-comment.selection-bar"]
        XCTAssertFalse(
            commentBar.waitForExistence(timeout: 1),
            "Full-screen text selection should use the native edit menu only, not a standalone Comment bar"
        )
        saveScreenshot(name: "fullscreen-review-comment-native-menu")
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
