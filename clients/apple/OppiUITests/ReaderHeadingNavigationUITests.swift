import XCTest

/// Finding a heading in the file reader: the Outline, on the handbook fixture (`ReaderTaskEditFixture.handbookSeed`). The
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

    // MARK: Helpers


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
