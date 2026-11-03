import XCTest

/// The book reader over the seeded harness book (`--book-reader-harness`):
/// table of contents, chapter change, and a position that survives leaving the
/// reader, including after a text-size change.
@MainActor
final class BookReaderHarnessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Book reader harness is simulator-only")
#endif
        continueAfterFailure = false
    }

    func testTableOfContentsKeepsTheParagraphAcrossReopenAndTextSize() throws {
        launchHarness()
        openBook()
        XCTAssertTrue(chapterTitle.waitUntilExists(timeout: 10), "The reader did not open")
        XCTAssertEqual(chapterTitle.label, "One")

        chooseChapter("Three")
        XCTAssertTrue(
            waitUntil { self.chapterTitle.label == "Three" },
            "The third chapter did not open, title is \(chapterTitle.label)"
        )

        // The body answers bookmark the view and its collection; the collection
        // is the scroll view a swipe belongs to.
        let body = app.collectionViews["fullScreen.book.body"].firstMatch
        XCTAssertTrue(body.waitUntilExists(timeout: 5))
        body.swipeUp()
        body.swipeUp()

        let paragraph = try XCTUnwrap(
            topVisibleParagraph(timeout: 5),
            "No chapter paragraph was visible after scrolling"
        )
        assertParagraphIsNearTheTop(paragraph)

        // Leave the reader and come back: the same paragraph, same chapter.
        closeReader()
        openBook()
        XCTAssertTrue(
            waitUntil { self.chapterTitle.label == "Three" },
            "Reopening lost the chapter, title is \(chapterTitle.label)"
        )
        assertParagraphIsNearTheTop(paragraph)

        // A text-size change re-flows the chapter; the paragraph still leads.
        changeTextSize()
        closeReader()
        openBook()
        XCTAssertTrue(
            waitUntil { self.chapterTitle.label == "Three" },
            "Reopening after a text-size change lost the chapter"
        )
        assertParagraphIsNearTheTop(paragraph)
    }

    // MARK: - Actions

    private func launchHarness() {
        app = OppiTestLaunch.makeApp()
        app.launchArguments.append("--book-reader-harness")
        app.launchEnvironment["PI_BOOK_READER_HARNESS"] = "1"
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"].waitUntilExists(timeout: 10),
            "The book harness did not become ready"
        )
    }

    private func openBook() {
        let open = app.buttons["harness.book.open"]
        XCTAssertTrue(open.waitUntilExists(timeout: 5), "The shelf has no Open book button")
        open.tap()
    }

    private func closeReader() {
        let close = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "The reader has no close control")
        close.tap()
        XCTAssertTrue(
            close.waitUntilGone(timeout: 5),
            "The reader did not close"
        )
    }

    private func chooseChapter(_ title: String) {
        let toc = app.buttons["fullScreen.book.toc"]
        XCTAssertTrue(toc.waitUntilExists(timeout: 5), "The reader has no table of contents")
        toc.tap()
        // A popover action is a button, and the chapter's own text can share
        // its label, so match the whole label on buttons only.
        let item = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(item.waitUntilExists(timeout: 5), "No table of contents row for \(title)")
        item.tap()
        _ = waitUntil { !item.exists || !item.isHittable }
    }

    private func changeTextSize() {
        let options = app.buttons["fullscreen.viewingOptions.button"]
        XCTAssertTrue(options.waitUntilExists(timeout: 5), "The reader has no Viewing Options")
        options.tap()

        let slider = app.sliders["fullscreen.viewingOptions.textSize"]
        XCTAssertTrue(slider.waitUntilExists(timeout: 5), "Viewing Options has no text size slider")
        slider.adjust(toNormalizedSliderPosition: 0.1)

        let sheet = app.otherElements["fullscreen.viewingOptions"]
        sheet.swipeDown()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "Viewing Options did not close")
    }

    // MARK: - Reading position

    private var chapterTitle: XCUIElement {
        app.staticTexts["fullScreen.book.title"]
    }

    /// The label of the paragraph nearest the top of the reading area.
    private func topVisibleParagraph(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let label = visibleParagraphs().min(by: { $0.frame.minY < $1.frame.minY })?.label {
                return label
            }
            hold(for: 0.2)
        } while Date() < deadline
        return nil
    }

    /// Assert `paragraph` is on screen in the upper part of the reading area,
    /// which is where a restored block lands.
    private func assertParagraphIsNearTheTop(
        _ paragraph: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", paragraph))
            .firstMatch
        XCTAssertTrue(
            match.waitUntilExists(timeout: 5),
            "The saved paragraph is not on screen: \(paragraph)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            waitUntil { (0...360).contains(match.frame.minY) },
            "The saved paragraph is not near the top: y=\(match.frame.minY)",
            file: file,
            line: line
        )
    }

    /// A condition read on the run loop, so a settled layout is not raced.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            hold(for: 0.2)
        } while Date() < deadline
        return condition()
    }

    /// Chapter paragraphs are the only texts that carry this sentence.
    private func visibleParagraphs() -> [XCUIElement] {
        let predicate = NSPredicate(format: "label CONTAINS %@", "says the same calm thing")
        // A rendered paragraph is a TextKit text view, not a plain label.
        return app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex.filter {
            $0.exists && $0.frame.height > 0 && $0.frame.minY > 120 && $0.frame.maxY < app.windows.firstMatch.frame.height - 60
        }
    }
}
