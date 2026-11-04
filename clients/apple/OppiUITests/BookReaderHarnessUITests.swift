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

    /// A text-size change made in Viewing Options re-flows the chapter in
    /// place. The chapter has to come out as one ordered stack: a row from the
    /// old size left drawn over the new layout is the bug this covers.
    func testLiveTextSizeChangeLeavesOneOrderedChapter() throws {
        launchHarness()
        openBook()
        XCTAssertTrue(chapterTitle.waitUntilExists(timeout: 10), "The reader did not open")
        capture("epub-chapter")

        // The table of contents stays readable over the chapter it lists.
        let toc = app.buttons["fullScreen.book.toc"]
        XCTAssertTrue(toc.waitUntilExists(timeout: 5), "The reader has no table of contents")
        toc.tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label == %@", "Two")).firstMatch
                .waitUntilExists(timeout: 5),
            "The table of contents did not open"
        )
        capture("epub-toc")
        // The open menu closes on the chapter it already shows.
        let current = app.buttons.matching(NSPredicate(format: "label == %@", "One")).firstMatch
        current.tap()
        _ = waitUntil { !current.exists || !current.isHittable }

        chooseChapter("Three")
        XCTAssertTrue(
            waitUntil { self.chapterTitle.label == "Three" },
            "The third chapter did not open, title is \(chapterTitle.label)"
        )
        assertReaderChromeClearsThePage()

        setTextSizeToMaximum()
        // Captured straight after the live change, before any reopen: the path
        // that left the old layout drawn on screen.
        capture("epub-larger-text")
        assertReaderChromeClearsThePage()

        let paragraphs = visibleParagraphFrames()
        XCTAssertGreaterThan(paragraphs.count, 3, "The chapter drew almost nothing after the change")
        let ordered = paragraphs.sorted { $0.frame.minY < $1.frame.minY }
        for (above, below) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThanOrEqual(
                above.frame.maxY,
                below.frame.minY + 0.5,
                "\"\(above.label)\" runs into \"\(below.label)\" after the text-size change"
            )
        }
        let labels = ordered.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "A paragraph is drawn twice: \(labels)")
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

    /// The largest text size, changed in place: the chapter re-flows while the
    /// person watches, without a reopen.
    private func setTextSizeToMaximum() {
        let options = app.buttons["fullscreen.viewingOptions.button"]
        XCTAssertTrue(options.waitUntilExists(timeout: 5), "The reader has no Viewing Options")
        options.tap()

        let slider = app.sliders["fullscreen.viewingOptions.textSize"]
        XCTAssertTrue(slider.waitUntilExists(timeout: 5), "Viewing Options has no text size slider")
        slider.adjust(toNormalizedSliderPosition: 1)

        let sheet = app.otherElements["fullscreen.viewingOptions"]
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "Viewing Options did not open")
        sheet.swipeDown()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "Viewing Options did not close")
    }

    /// The reader's floating chrome and the body's own chrome do not overlap:
    /// the chapter header sits below the close control and the footer's two
    /// buttons share one row.
    private func assertReaderChromeClearsThePage(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let close = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "The reader has no close control", file: file, line: line)
        XCTAssertFalse(
            close.frame.intersects(chapterTitle.frame),
            "The chapter header \(chapterTitle.frame) sits under the close control \(close.frame)",
            file: file,
            line: line
        )

        let previous = app.buttons["fullScreen.book.previous"]
        let next = app.buttons["fullScreen.book.next"]
        XCTAssertTrue(previous.waitUntilExists(timeout: 5), "The reader has no Previous", file: file, line: line)
        XCTAssertTrue(next.waitUntilExists(timeout: 5), "The reader has no Next", file: file, line: line)
        XCTAssertEqual(
            previous.frame.minY,
            next.frame.minY,
            accuracy: 1,
            "Previous and Next are not on one baseline",
            file: file,
            line: line
        )
    }

    /// Writes the screen to `OPPI_BOOK_SHOTS` when that is set, and keeps it on
    /// the test result either way. Under `xcodebuild` the variable reaches the
    /// test runner through the `TEST_RUNNER_` prefix.
    private func capture(_ name: String) {
        waitUntilThePageIsStill()
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["TEST_RUNNER_OPPI_BOOK_SHOTS"]
            ?? environment["OPPI_BOOK_SHOTS"],
            !directory.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }

    /// Lets the reader finish presenting or re-flowing: the chapter's frame has
    /// stopped moving, so a capture sees the page at rest.
    private func waitUntilThePageIsStill() {
        var previous: CGRect = .null
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let frame = app.collectionViews["fullScreen.book.body"].firstMatch.frame
            if frame == previous, !frame.isEmpty { return }
            previous = frame
            hold(for: 0.2)
        } while Date() < deadline
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

    /// The chapter paragraphs the body is showing right now, in window space.
    private func visibleParagraphFrames() -> [(label: String, frame: CGRect)] {
        let area = app.collectionViews["fullScreen.book.body"].firstMatch.frame
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Chapter 3 paragraph"))
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 0 && $0.frame.minY >= area.minY && $0.frame.maxY <= area.maxY }
            .map { ($0.label, $0.frame) }
    }
}
