import XCTest

/// Selected text in a PDF takes a review comment as every other reader's does:
/// the edit menu leads with the dictate mic and Comment, Comment opens the
/// inline composer, and the saved comment reaches the chat with the PDF's
/// path, the page, and the quote. The chat-routes harness opens its PDF
/// (`ChatRoutesPDF`) as a tapped file pill does, with the chat's comment scope.
@MainActor
final class PDFReviewCommentUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var pdf: XCUIElement { app.descendants(matching: .any)["fileViewer.pdf"].firstMatch }
    private var commentAction: XCUIElement { app.menuItems["Comment"] }
    /// `TEST_RUNNER_CHAT_ROUTES_PDF_FILE` swaps in a real PDF for proof recordings.
    private let pdfFile = ProcessInfo.processInfo.environment["CHAT_ROUTES_PDF_FILE"]
    private var pdfName: String { pdfFile.map { ($0 as NSString).lastPathComponent } ?? "trail-guide.pdf" }

    func testSelectedPDFTextTakesACommentWithItsPageAndQuote() throws {
        openPDF()
        // One page down: page 2 opens on its heading, "Water".
        pdf.swipeUp(velocity: .slow)
        hold()
        attachScreenshot("pdf-page-2")
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.2)

        XCTAssertTrue(commentAction.waitUntilExists(timeout: 5), "The PDF's edit menu must offer Comment")
        let dictate = app.menuItems["review-comment.dictate"]
        XCTAssertTrue(dictate.exists, "The PDF's edit menu must offer the dictate-comment mic")
        XCTAssertLessThan(dictate.frame.minX, commentAction.frame.minX, "The mic leads Comment")
        attachScreenshot("pdf-edit-menu")

        commentAction.tap()
        let composer = app.descendants(matching: .any)["review-comment.inline-composer"]
        XCTAssertTrue(composer.waitUntilExists(timeout: 5), "Comment must open the inline composer")
        let input = app.textViews["review-comment.inline-input"]
        XCTAssertTrue(input.waitUntilExists(timeout: 3))
        input.tap()
        input.typeText("Say which spring this is on the map.")
        attachScreenshot("pdf-inline-composer")
        app.buttons["review-comment.inline-save"].tap()
        XCTAssertTrue(composer.waitUntilGone(timeout: 5), "Save must close the composer")

        // The viewer's stash shows the chat's staged comments: on the iPad mini
        // in portrait and on the iPhone the PDF covers the chat.
        let stash = app.buttons["fullscreen-code.review-comments.stash"].firstMatch
        XCTAssertTrue(stash.waitUntilExists(timeout: 5), "The saved comment must reach the chat")
        XCTAssertEqual(stash.value as? String, "1 staged comment")
        attachScreenshot("pdf-comment-staged")
        stash.tap()
        XCTAssertTrue(app.navigationBars["1 review comment staged"].waitUntilExists(timeout: 5), "The stash sheet did not open")
        let page = NSPredicate(format: "label CONTAINS %@", "\(pdfName) page 2")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(page).firstMatch.waitUntilExists(timeout: 3),
            "The staged comment must name the PDF and its page"
        )
        attachScreenshot("pdf-comment-stash")
        assertRunning()
    }

    private func openPDF() {
        XCUIDevice.shared.orientation = .portrait
        var environment = ["CHAT_ROUTES_REVIEW_COMMENT": "none"]
        environment["CHAT_ROUTES_PDF_FILE"] = pdfFile
        launchPreview(
            screen: "chat-routes",
            environment: environment,
            colorScheme: "dark",
            ready: nil
        )
        let open = app.buttons["chatRoutes.openPDF"]
        XCTAssertTrue(open.waitUntilExists(timeout: 15), "Chat routes harness did not appear")
        XCTAssertTrue(app.buttons["chat.toolbar.outline"].waitUntilExists(timeout: 10), "The fixture timeline did not load")
        open.tap()
        XCTAssertTrue(pdf.waitUntilExists(timeout: 10), "The PDF pill did not open the PDF")
        hold()
    }
}
