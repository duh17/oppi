import XCTest

@MainActor
final class ReviewCommentStashUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Review comment stash UI test is simulator-only")
#endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--review-comment-stash-harness",
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launchEnvironment["PI_REVIEW_COMMENT_STASH_HARNESS"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testEditingCommentSavesAndReturnsToStash() {
        let editButton = app.buttons["Edit review comment"].firstMatch
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), "Staged review comment did not appear")
        editButton.tap()

        let editor = app.textViews["Review comment text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Review comment editor did not appear")
        editor.tap()
        editor.typeText(" Updated")

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.isEnabled, "Save should enable after the comment changes")
        saveButton.tap()

        let savedDiagnostic = app.descendants(matching: .any)["diag.reviewCommentStash.saved"]
        XCTAssertTrue(savedDiagnostic.waitForExistence(timeout: 5), "Save callback did not complete")
        XCTAssertEqual(savedDiagnostic.value as? String, "1")
        XCTAssertFalse(editor.exists, "Editor should close after a successful save")
        XCTAssertTrue(editButton.exists, "Stash list should return after a successful save")
    }

    func testCancelEditingReturnsToStashWithoutSaving() {
        let editButton = app.buttons["Edit review comment"].firstMatch
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), "Staged review comment did not appear")
        editButton.tap()

        let editor = app.textViews["Review comment text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Review comment editor did not appear")
        editor.tap()
        editor.typeText(" Discarded")

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Editor cancel button did not appear")
        cancelButton.tap()

        XCTAssertFalse(editor.exists, "Editor should close after cancellation")
        XCTAssertTrue(editButton.exists, "Stash list should return after cancellation")
        let savedDiagnostic = app.descendants(matching: .any)["diag.reviewCommentStash.saved"]
        XCTAssertEqual(savedDiagnostic.value as? String, "0")
    }
}
