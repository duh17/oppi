import XCTest

/// Finding a heading in the file reader: the Outline and Find, on the handbook fixture (`ReaderTaskEditFixture.handbookSeed`). The
/// headings are ordinals: 1 Index, 2 Planning, 3 Goals, 4 Shipping plan,
/// 5 Deep dive, 6 Details, 7 Research, 8 Prior art, 9 Release notes, 10 Appendix.
@MainActor
final class ReaderHeadingNavigationUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Heading navigation runs on the simulator's disk fixture")
#endif
        continueAfterFailure = false
    }

    // MARK: Links

    func testALinkScrollsToItsHeading() throws {
        launch(file: "handbook.org")
        tapLink("Go to the deep dive")
        let arrived = waitUntilNearTop(fold(5))
        saveScreenshot(name: "heading-link-jump")
        XCTAssertTrue(arrived, "the link brought Deep dive to the top")
    }

    func testALinkIntoAFoldedSectionOpensItFirst() throws {
        launch(file: "handbook.org")
        // Planning holds Goals, Shipping plan and Deep dive.
        tapChevron(2)
        XCTAssertTrue(waitForFold(2, "Collapsed"), "Planning folds")
        XCTAssertTrue(fold(5).waitUntilGone(timeout: 10), "and takes Deep dive with it")
        saveScreenshot(name: "heading-link-folded-before")
        tapLink("Go to the deep dive")
        // Deep dive sat inside the folded Planning: seeing it means the section opened.
        XCTAssertTrue(waitUntilNearTop(fold(5)), "the link opened the section above Deep dive and scrolled to it")
        saveScreenshot(name: "heading-link-folded-after")
    }

    func testIdAndCustomIdLinksScroll() throws {
        launch(file: "handbook.org")
        tapLink("Go to the shipping plan")
        XCTAssertTrue(waitUntilNearTop(fold(4)), "[[id:…]] reached Shipping plan")
        scrollToTop()
        tapLink("Go to the release notes")
        XCTAssertTrue(waitUntilScrolledTo(fold(9)), "[[#custom-id]] reached Release notes")
    }

    // MARK: Outline

    func testTheOutlineListsHeadingsAndJumpsToOne() throws {
        launch(file: "handbook.org", colorScheme: "light")
        let button = app.buttons["fileViewer.outline.button"]
        XCTAssertTrue(button.waitUntilExists(timeout: 15), "a file with headings offers its outline")
        button.tap()
        let list = app.descendants(matching: .any)["fileViewer.outline"]
        let opened = list.waitUntilExists(timeout: 10)
        saveScreenshot(name: "outline-opened")
        XCTAssertTrue(opened, "the outline opens")
        for ordinal in [1, 5, 9] {
            XCTAssertTrue(app.descendants(matching: .any)["fileViewer.outline.row.\(ordinal)"].waitUntilExists(timeout: 5), "row \(ordinal)")
        }
        saveScreenshot(name: "outline-light")
        app.descendants(matching: .any)["fileViewer.outline.row.9"].tap()
        XCTAssertTrue(list.waitUntilGone(timeout: 10), "choosing a heading closes the outline")
        // A heading near the end of a short document cannot reach the top: the scroll stops at the end.
        XCTAssertTrue(waitUntilScrolledTo(fold(9)), "and scrolls to it")
    }

    func testTheOutlineAtTheLargestTextSizeStillJumps() throws {
        launch(file: "handbook.org", colorScheme: "dark", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["fileViewer.outline.button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["fileViewer.outline"].waitUntilExists(timeout: 10))
        saveScreenshot(name: "outline-dark-xxxl")
        let row = app.descendants(matching: .any)["fileViewer.outline.row.6"]
        for _ in 0..<12 where !row.exists || !row.isHittable { app.descendants(matching: .any)["fileViewer.outline.list"].swipeUp() }
        row.tap()
        XCTAssertTrue(waitUntilScrolledTo(fold(6)), "and scrolls to Details")
    }

    func testAFileWithoutHeadingsHasNoOutline() throws {
        launch(file: "flat.org", readyLabel: "A second paragraph")
        XCTAssertFalse(app.buttons["fileViewer.outline.button"].exists, "there is nothing to list")
        saveScreenshot(name: "outline-empty")
    }

    // MARK: Find

    func testFindOpensTheFoldedSectionHoldingAMatch() throws {
        launch(file: "handbook.org", colorScheme: "light")
        tapChevron(2)
        XCTAssertTrue(waitForFold(2, "Collapsed"), "Planning folds")
        XCTAssertTrue(fold(5).waitUntilGone(timeout: 10), "and takes Deep dive with it")
        search("Paragraph 2 of section 4")
        XCTAssertTrue(waitForFold(2, "Expanded"), "the match opened the section above it")
        XCTAssertTrue(waitUntilScrolledTo(fold(5)), "and scrolled to the section holding it")
        XCTAssertTrue(waitForMatchAboveFindBar("Paragraph 2 of section 4"), "the match itself is marked and clear of the find bar")
        saveScreenshot(name: "find-match-in-fold")
    }

    func testFindReachesAMatchFarDownALongFile() throws {
        launch(file: "handbook.org", colorScheme: "dark")
        search("Paragraph 3 of section 9")
        XCTAssertTrue(waitUntilScrolledTo(fold(10)), "the match near the end of the file is on screen")
        XCTAssertTrue(waitForMatchAboveFindBar("Paragraph 3 of section 9"), "the match itself is marked and clear of the find bar")
        saveScreenshot(name: "find-long-file")
    }

    func testFindWithNoMatchesSaysSoAndLeavesTheFileAlone() throws {
        launch(file: "handbook.org", colorScheme: "dark")
        search("zzzqq no such words")
        // The system bar shows its query with a result count of 0, not words.
        XCTAssertEqual(findField.value as? String, "zzzqq no such words", "the find bar holds the query")
        saveScreenshot(name: "find-no-matches")
        XCTAssertTrue(onScreen(fold(1)), "the file did not move")
        XCTAssertTrue(fold(2).exists && fold(2).value as? String == "Expanded", "and no section opened")
    }

    func testFindAtTheLargestTextSize() throws {
        launch(file: "handbook.org", colorScheme: "dark", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        search("Paragraph 1 of section 6")
        XCTAssertTrue(waitUntilScrolledTo(fold(7)), "the match's section is shown")
        XCTAssertTrue(waitForMatchAboveFindBar("Paragraph 1 of section 6"), "the match itself is marked and clear of the find bar")
        saveScreenshot(name: "find-xxxl")
    }

    func testCommandFOpensFindOnIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Command-F is the iPad's keyboard path") }
        launch(file: "handbook.org")
        // The reader takes first responder as it lays out, which can land after
        // the first key press on a busy run: press again until the bar is up.
        var opened = false
        for _ in 0..<4 where !opened {
            app.typeKey("f", modifierFlags: .command)
            opened = findField.waitUntilExists(timeout: 5)
        }
        XCTAssertTrue(opened, "the standard find command opens the find bar")
        saveScreenshot(name: "find-command-f")
    }

    // MARK: Helpers

    /// Taps a link of the reader's text by its words.
    private func tapLink(_ label: String) {
        let link = app.links.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        XCTAssertTrue(link.waitUntilExists(timeout: 15), "the reader shows a link \(label)")
        link.tap()
    }

    private func waitUntilNearTop(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let window = app.windows.firstMatch.frame
        while Date() < deadline {
            if element.exists, element.frame.minY > 0, element.frame.minY < window.height * 0.4 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func scrollToTop() {
        for _ in 0..<12 where !onScreen(fold(1)) { app.swipeDown() }
    }

    private var findField: XCUIElement {
        let search = app.searchFields.firstMatch
        return search.exists ? search : app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS[c] 'find' OR label CONTAINS[c] 'find'")).firstMatch
    }

    /// The current find match is on screen, between the top bar and the find
    /// bar riding on the keyboard, and only a marked (highlighted) match exists.
    private func waitForMatchAboveFindBar(_ words: String, timeout: TimeInterval = 15) -> Bool {
        // The element is the highlight itself, a view behind the match's words.
        let match = app.descendants(matching: .any)["fileViewer.find.currentMatch"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if match.exists, match.label.contains(words), findField.exists {
                let frame = match.frame
                if frame.height > 0, frame.minY > 60, frame.maxY <= findField.frame.minY { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// Opens the system find bar from the toolbar and types a query.
    private func search(_ query: String) {
        let button = app.buttons["fileViewer.find.button"]
        XCTAssertTrue(button.waitUntilExists(timeout: 15), "a file reader offers Find")
        button.tap()
        XCTAssertTrue(findField.waitUntilExists(timeout: 10), "the find bar opens")
        app.typeText(query)
    }

    private func waitForFold(_ ordinal: Int, _ value: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fold(ordinal).exists, fold(ordinal).value as? String == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return fold(ordinal).value as? String == value
    }

    private func tapChevron(_ ordinal: Int) {
        let element = fold(ordinal)
        XCTAssertTrue(element.waitUntilExists(timeout: 15), "fold \(ordinal) exists")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 10, dy: 0)).tap()
    }


    private func fold(_ ordinal: Int) -> XCUIElement {
        app.descendants(matching: .any)["fileViewer.heading.fold.\(ordinal)"]
    }

    private func onScreen(_ element: XCUIElement) -> Bool {
        element.exists && element.frame.intersects(app.windows.firstMatch.frame)
    }

    /// The element is on screen and the document's start has scrolled away.
    private func waitUntilScrolledTo(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if onScreen(element), !onScreen(fold(1)) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func launch(
        file: String,
        colorScheme: String? = nil,
        arguments: [String] = [],
        readyLabel: String? = nil
    ) {
        XCUIDevice.shared.orientation = .portrait
        // A read-only server keeps the fixture still: nothing here edits a file.
        launchPreview(
            screen: "reader-task-edit",
            environment: ["OPPI_READER_TASK_FILE": file, "OPPI_READER_TASK_READONLY": "1"],
            colorScheme: colorScheme,
            arguments: arguments,
            readyTimeout: 20
        )
        if let readyLabel {
            let text = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", readyLabel)).firstMatch
            XCTAssertTrue(text.waitUntilExists(timeout: 20), "the reader shows \(file)")
        } else {
            XCTAssertTrue(fold(1).waitUntilExists(timeout: 20), "the reader shows \(file)")
        }
    }

    private func saveScreenshot(name: String) {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(device)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Each suite writes only to its own folder in the shared screenshot directory.
        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots/reader-headings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(device)-\(name).png"), options: .atomic)
    }
}
