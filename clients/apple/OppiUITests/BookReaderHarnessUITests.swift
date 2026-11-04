import XCTest

/// The book reader over the seeded harness book (`--book-reader-harness`): the
/// pages a book opens as, the table of contents, page turns that cross chapters,
/// and a position that survives leaving the reader, including after a text-size
/// change. The scrolling body keeps its own journey, reached through the Aa menu.
@MainActor
final class BookReaderHarnessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Book reader harness is simulator-only")
#endif
        continueAfterFailure = false
    }

    /// The journey the owner asked for: table of contents → chapter three → turn
    /// pages → leave → come back on the same page, and again after a text-size
    /// change.
    func testPagedReadingKeepsThePageAcrossReopenAndTextSize() throws {
        launchHarness()
        openPagedBook()
        XCTAssertTrue(progressLine.waitUntilExists(timeout: 10), "The book did not open as pages")
        XCTAssertEqual(pageNumber, 1, "The book did not open on its first page")

        // The page is alone on screen until a tap in the middle brings the
        // controls back.
        XCTAssertFalse(chromeIsVisible, "The reader's chrome is showing while reading")
        // The fade is short, but a capture has to see the page it leaves behind.
        hold(for: 0.4)
        capture("epub-paged")
        let close = app.buttons["fullScreen.code.close"]
        XCTAssertFalse(
            close.exists && close.isHittable,
            "The reader's own controls are still over the page (exists: \(close.exists), hittable: \(close.isHittable))"
        )
        showChrome()
        capture("epub-paged-chrome")
        XCTAssertTrue(chromeIsVisible)

        openChapter("Three", captureSheet: true)
        XCTAssertTrue(
            waitUntil { self.chapterTitle.label == "Three" },
            "The third chapter did not open, title is \(chapterTitle.label)"
        )
        XCTAssertEqual(pageNumber, 1, "A chapter opened from the table of contents is not on its first page")

        // Two page turns by tapping the trailing third of the page.
        let turnedTo = turnPages(2)
        XCTAssertEqual(turnedTo, 3, "Two page turns from page 1 landed on page \(turnedTo)")
        // Read the page once its turn has settled: a snapshot taken mid-animation
        // can lose the cell it was reading.
        hold(for: 0.6)
        let openingWords = try XCTUnwrap(firstWordsOfThePage(), "The page has no text to read")

        // Leave and come back: the same chapter, and the words the person left
        // on screen. The page number can move by one when the sheet settles to
        // a point of a different height; the words cannot.
        closeReader()
        openPagedBook()
        showChrome()
        XCTAssertTrue(
            waitUntil { self.chapterTitle.label == "Three" },
            "Reopening lost the chapter, title is \(chapterTitle.label)"
        )
        XCTAssertTrue(
            pageContains(openingWords),
            "Reopening lost the words the person left: \"\(openingWords)\" is not on screen"
        )
        XCTAssertLessThanOrEqual(
            abs(pageNumber - turnedTo),
            1,
            "Reopening moved more than a page: page \(pageNumber), not \(turnedTo)"
        )

        // A text-size change re-flows the chapter. What the person was reading
        // is still on the page they come back to.
        let anchor = try XCTUnwrap(middleWordsOfThePage(), "The page has no text to read")
        changeTextSize()
        closeReader()
        openPagedBook()
        showChrome()
        XCTAssertTrue(
            pageContains(anchor),
            "After the text-size change the book opened away from \"\(anchor)\""
        )
    }

    /// The scrolling body is one choice away in the Aa menu, and it keeps its
    /// own journey: the chapter, and the paragraph the person was reading.
    func testScrollingModeKeepsTheParagraph() throws {
        launchHarness()
        openBook()
        XCTAssertTrue(progressLine.waitUntilExists(timeout: 10), "The book did not open")

        chooseScrollingMode()
        XCTAssertTrue(
            app.collectionViews["fullScreen.book.body"].firstMatch.waitUntilExists(timeout: 10),
            "The scrolling body did not appear"
        )
        XCTAssertTrue(
            app.buttons["fullScreen.book.previous"].waitUntilExists(timeout: 5),
            "Scrolling lost its Previous/Next footer"
        )
        capture("epub-scrolling")

        openChapter("Three")
        let body = app.collectionViews["fullScreen.book.body"].firstMatch
        body.swipeUp()
        body.swipeUp()
        let paragraph = try XCTUnwrap(topVisibleParagraph(timeout: 5), "No paragraph was visible after scrolling")
        assertParagraphIsNearTheTop(paragraph)

        closeReader()
        openBook()
        XCTAssertTrue(
            waitUntil { self.chapterTitle.label == "Three" },
            "Reopening lost the chapter, title is \(chapterTitle.label)"
        )
        assertParagraphIsNearTheTop(paragraph)
    }

    /// The reader's floating chrome and the body's own chrome do not overlap:
    /// the chapter header sits below the close control, and the scrolling
    /// footer's two buttons share one row.
    func testScrollingChromeClearsThePage() throws {
        launchHarness()
        openBook()
        XCTAssertTrue(progressLine.waitUntilExists(timeout: 10), "The book did not open")
        chooseScrollingMode()
        XCTAssertTrue(app.collectionViews["fullScreen.book.body"].firstMatch.waitUntilExists(timeout: 10))

        let close = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "The reader has no close control")
        XCTAssertFalse(
            close.frame.intersects(chapterTitle.frame),
            "The chapter header \(chapterTitle.frame) sits under the close control \(close.frame)"
        )

        let previous = app.buttons["fullScreen.book.previous"]
        let next = app.buttons["fullScreen.book.next"]
        XCTAssertTrue(previous.waitUntilExists(timeout: 5), "The reader has no Previous")
        XCTAssertTrue(next.waitUntilExists(timeout: 5), "The reader has no Next")
        XCTAssertEqual(previous.frame.minY, next.frame.minY, accuracy: 1, "Previous and Next are not on one baseline")
    }

    /// A live text-size change made in Viewing Options re-flows the chapter in
    /// place: the rows come out as one ordered stack, with no row from the old
    /// size left drawn over the new layout.
    func testScrollingTextSizeChangeLeavesOneOrderedChapter() throws {
        launchHarness()
        openBook()
        XCTAssertTrue(progressLine.waitUntilExists(timeout: 10), "The book did not open")
        chooseScrollingMode()
        XCTAssertTrue(app.collectionViews["fullScreen.book.body"].firstMatch.waitUntilExists(timeout: 10))
        openChapter("Three")

        setTextSizeToMaximum()
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
        openBookButton("harness.book.open")
    }

    /// The longer book the paged journey needs: its chapters run over several
    /// pages, which the short one does not.
    private func openPagedBook() {
        openBookButton("harness.book.paged.open")
    }

    private func openBookButton(_ identifier: String) {
        let open = app.buttons[identifier]
        XCTAssertTrue(open.waitUntilExists(timeout: 5), "The shelf has no \(identifier) button")
        open.tap()
    }

    private func closeReader() {
        showChrome()
        let close = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "The reader has no close control")
        close.tap()
        XCTAssertTrue(close.waitUntilGone(timeout: 5), "The reader did not close")
    }

    /// The chrome is faded out while a book is read as pages; a tap in the middle
    /// third of the page is what shows it.
    private func showChrome() {
        guard !chromeIsVisible else { return }
        let pages = app.descendants(matching: .any)["fullScreen.book.pages"].firstMatch
        if pages.exists {
            pages.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(
            waitUntil { self.chromeIsVisible },
            "A tap in the middle of the page did not show the reader's chrome. The screen reads: \(app.debugDescription)"
        )
    }

    private var chromeIsVisible: Bool {
        let toc = app.buttons["fullScreen.book.toc"]
        return toc.exists && toc.isHittable
    }

    /// The table of contents sheet opens on the chapter on screen; a row is a
    /// cell labelled with its title (and, for the open chapter, that it is).
    private func openChapter(_ title: String, captureSheet: Bool = false) {
        showChrome()
        let toc = app.buttons["fullScreen.book.toc"]
        XCTAssertTrue(toc.waitUntilExists(timeout: 5), "The reader has no table of contents")
        toc.tap()
        let sheet = app.descendants(matching: .any)["fullScreen.book.tocSheet"]
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "The table of contents sheet did not open")
        if captureSheet { capture("epub-books-toc") }
        // A row is a list cell, and the chapter's own text can share its words,
        // so the search stays inside the sheet.
        let row = sheet.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", title))
            .firstMatch
        XCTAssertTrue(row.waitUntilExists(timeout: 5), "No table of contents row for \(title)")
        row.tap()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "The table of contents sheet did not close")
    }

    /// The two sheets the reading themes bring, over a page: the table of
    /// contents, then the Aa sheet it sits beside.
    func testAppearanceSheetAndTableOfContentsOverThePage() throws {
        launchHarness()
        openPagedBook()
        XCTAssertTrue(progressLine.waitUntilExists(timeout: 10), "The book did not open as pages")
        showChrome()

        let toc = app.buttons["fullScreen.book.toc"]
        XCTAssertTrue(toc.waitUntilExists(timeout: 5), "The reader has no table of contents")
        toc.tap()
        let sheet = app.descendants(matching: .any)["fullScreen.book.tocSheet"]
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "The table of contents sheet did not open")
        hold(for: 0.5)
        capture("epub-books-toc")
        app.buttons["fullScreen.book.tocSheet.done"].tap()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "The table of contents sheet did not close")

        let appearance = app.buttons["fullScreen.book.aa"]
        XCTAssertTrue(appearance.waitUntilExists(timeout: 5), "The reader has no appearance control")
        appearance.tap()
        let sepia = app.buttons["Sepia"]
        XCTAssertTrue(sepia.waitUntilExists(timeout: 5), "The Aa sheet did not open")
        // The sheet's own detent settles, so the capture sees it at rest.
        hold(for: 0.8)
        capture("epub-books-aa")
    }

    private func chooseScrollingMode() {
        showChrome()
        let appearance = app.buttons["fullScreen.book.aa"]
        XCTAssertTrue(appearance.waitUntilExists(timeout: 5), "The reader has no appearance control")
        appearance.tap()
        let scrolling = app.buttons.matching(NSPredicate(format: "label == %@", "Scrolling")).firstMatch
        XCTAssertTrue(scrolling.waitUntilExists(timeout: 5), "The appearance menu has no Scrolling choice")
        scrolling.tap()
    }

    /// Taps the trailing third of the page `count` times, and answers the page
    /// number the reader shows afterwards.
    @discardableResult
    private func turnPages(_ count: Int, file: StaticString = #filePath, line: UInt = #line) -> Int {
        var page = pageNumber
        for _ in 0..<count {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertTrue(
                waitUntil { self.pageNumber == page + 1 },
                "The trailing tap did not turn the page from \(page)",
                file: file,
                line: line
            )
            page += 1
        }
        return page
    }

    private func changeTextSize() {
        showChrome()
        let options = app.buttons["fullscreen.viewingOptions.button"]
        XCTAssertTrue(options.waitUntilExists(timeout: 5), "The reader has no Viewing Options")
        options.tap()

        let slider = app.sliders["fullscreen.viewingOptions.textSize"]
        XCTAssertTrue(slider.waitUntilExists(timeout: 5), "Viewing Options has no text size slider")
        slider.adjust(toNormalizedSliderPosition: 0.1)

        let sheet = app.otherElements["fullscreen.viewingOptions"]
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "Viewing Options did not open")
        sheet.swipeDown()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "Viewing Options did not close")
    }

    private func setTextSizeToMaximum() {
        showChrome()
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

    // MARK: - Reading state

    private var chapterTitle: XCUIElement {
        app.staticTexts["fullScreen.book.title"]
    }

    private var progressLine: XCUIElement {
        app.descendants(matching: .any)["fullScreen.book.progress"]
    }

    /// The page number in "Page 3 of 12, 5 min left in chapter".
    private var pageNumber: Int {
        let label = progressLine.label
        guard let page = label.split(separator: " ").dropFirst().first, let number = Int(page) else {
            XCTFail("The progress line does not name a page: \"\(label)\"")
            return -1
        }
        return number
    }

    /// The text of the page on screen: the page cells are one accessibility stop
    /// each, and only the one in the reading area is the person's page.
    private func visiblePageTexts() -> [String] {
        let area = app.windows.firstMatch.frame
        return app.descendants(matching: .any)
            .matching(identifier: "fullScreen.book.page")
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minX >= area.minX && $0.frame.maxX <= area.minX + area.width + 1 }
            .map(\.label)
            .filter { !$0.isEmpty }
    }

    /// True when some text on screen carries `words`: the page the person left
    /// begins with them, wherever the re-flow put the page boundary.
    private func pageContains(_ words: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", words))
            .firstMatch
            .waitUntilExists(timeout: timeout)
    }

    /// The first words of the page on screen: where the page the person left
    /// begins.
    private func firstWordsOfThePage() -> String? {
        for text in visiblePageTexts() {
            let words = text.split(separator: " ")
            guard words.count > 4 else { continue }
            return words.prefix(4).joined(separator: " ")
        }
        return nil
    }

    /// Three words from the middle of the page: what the person is looking at,
    /// found again wherever a re-flow puts it.
    private func middleWordsOfThePage() -> String? {
        for text in visiblePageTexts() {
            let words = text.split(separator: " ")
            guard words.count > 12 else { continue }
            let start = words.count / 2
            return words[start..<min(start + 3, words.count)].joined(separator: " ")
        }
        return nil
    }

    /// The label of the paragraph nearest the top of the scrolling reading area.
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
            "The saved paragraph is not on screen: \(paragraph). Visible: \(visibleParagraphs().prefix(3).map(\.label))",
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

    /// The chapter paragraphs the scrolling body is drawing right now, ordered by
    /// where they sit.
    private func visibleParagraphFrames() -> [(label: String, frame: CGRect)] {
        let area = app.collectionViews["fullScreen.book.body"].firstMatch.frame
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Chapter 3 paragraph"))
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 0 && $0.frame.minY >= area.minY && $0.frame.maxY <= area.maxY }
            .map { ($0.label, $0.frame) }
    }

    private func visibleParagraphs() -> [XCUIElement] {
        let predicate = NSPredicate(format: "label CONTAINS %@", "says the same calm thing")
        // A rendered paragraph is a TextKit text view, not a plain label.
        return app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex.filter {
            $0.exists && $0.frame.height > 0 && $0.frame.minY > 120
                && $0.frame.maxY < app.windows.firstMatch.frame.height - 60
        }
    }

    // MARK: - Helpers

    /// A condition read on the run loop, so a settled layout is not raced.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            hold(for: 0.2)
        } while Date() < deadline
        return condition()
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

    /// Lets the reader finish presenting or re-flowing: the page's frame has
    /// stopped moving, so a capture sees the page at rest.
    private func waitUntilThePageIsStill() {
        let page = app.descendants(matching: .any)["fullScreen.book.pages"].firstMatch
        var previous: CGRect = .null
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let frame = page.exists ? page.frame : app.windows.firstMatch.frame
            if frame == previous, !frame.isEmpty { return }
            previous = frame
            hold(for: 0.2)
        } while Date() < deadline
    }
}
