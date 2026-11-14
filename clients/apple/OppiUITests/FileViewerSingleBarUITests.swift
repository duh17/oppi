import XCTest

/// Every kind of file the viewer opens shows one navigation bar, wherever it
/// sits (`SCREENSHOT_SCREEN=reader-task-edit` over its fixture files,
/// `ReaderTaskEditFixture.seedKinds`). A reader that draws its own bar (text, a
/// book) takes the stack's place; every other kind keeps the stack's bar. A book
/// once showed the stack's bar, the reader's bar under it, and its own header.
@MainActor
final class FileViewerSingleBarUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    private static let screenshotDirectory = "/tmp/oppi-single-bar"

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("The viewer runs on the simulator's disk fixture")
#endif
        continueAfterFailure = false
    }

    /// The reported case: a book opened from a chat link. One bar holds Back and
    /// the reader's buttons, the book keeps Contents and Aa in its own header,
    /// and Back returns to the page the link was on.
    func testABookFromALinkShowsOneBarAndBackReturns() {
        open("book.epub", chrome: "linked")
        assertOneBar("book.epub opened from a link")
        XCTAssertTrue(app.buttons["fullScreen.book.toc"].isHittable, "the book keeps its Contents")
        XCTAssertTrue(app.buttons["fullScreen.book.aa"].isHittable, "the book keeps its Aa")
        save(chrome: "linked", file: "book.epub")

        let back = app.buttons["fullScreen.code.close"].firstMatch
        XCTAssertTrue(back.isHittable, "the one bar holds Back")
        back.tap()
        XCTAssertTrue(
            app.staticTexts["harness.readerTask.files"].waitUntilExists(timeout: 5),
            "Back returns to the page the book was opened from"
        )
        hold()
        XCTAssertEqual(shownBars.count, 1, "the page below has its own bar back")
    }

    /// Every kind, embedded the way the shell's linked-file route shows a chat
    /// or wiki link, a tool row's file, or a pane leaf.
    func testEveryKindFromALinkShowsOneBar() {
        sweep(chrome: "linked")
    }

    /// Every kind as the root of a chat's side panel, where the reader names
    /// the file and closes with X (regular width only).
    func testEveryKindInTheSidePanelShowsOneBar() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The side panel opens only at regular width")
        }
        sweep(chrome: "pane")
    }

    // MARK: Steps

    /// One kind's failure still checks the rest, so a run names every kind affected.
    private func sweep(chrome: String) {
        continueAfterFailure = true
        for file in Self.kindFiles {
            open(file, chrome: chrome)
            save(chrome: chrome, file: file)
            assertOneBar("\(file) (\(chrome))")
        }
    }

    /// `ReaderTaskEditFixture.seedKinds`. Text too large to format is left out:
    /// its megabyte of text stalls every accessibility query, and it is text in
    /// the same reader as `notes.md`.
    private static let kindFiles = [
        "notes.md", "tasks.org", "main.swift", "table.csv", "page.html", "guide.pdf",
        "photo.png", "clip.mp4", "book.epub", "archive.zip",
    ]

    /// Opens `file` and waits until the viewer shows it, not a spinner or an error.
    private func open(_ file: String, chrome: String) {
        XCUIDevice.shared.orientation = .portrait
        launchPreview(
            screen: "reader-task-edit",
            environment: [
                "OPPI_READER_TASK_FILE": file,
                "OPPI_READER_TASK_CHROME": chrome,
                "OPPI_READER_TASK_READONLY": "1",
            ],
            colorScheme: "dark",
            readyTimeout: 20
        )
        _ = waitFor(self.app.activityIndicators.count == 0, timeout: 15)
        hold()
        XCTAssertFalse(app.staticTexts["Unable to Load"].exists, "\(file) loaded")
        switch file {
        case "book.epub":
            showBookChrome()
        case "archive.zip":
            XCTAssertTrue(app.staticTexts["fileViewer.card.summary"].waitUntilExists(timeout: 10), "the archive opens as a file card")
        default:
            break
        }
    }

    /// A book opens as pages with the controls out of the way; a tap in the
    /// middle of the page brings them back.
    private func showBookChrome() {
        let toc = app.buttons["fullScreen.book.toc"]
        XCTAssertTrue(app.descendants(matching: .any)["fullScreen.book.progress"].waitUntilExists(timeout: 15), "the book opens")
        if !(toc.exists && toc.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(waitFor(toc.exists && toc.isHittable), "a tap in the middle of the page shows the controls")
        // The fade is short, but the capture has to see the controls it brought back.
        hold(for: 0.4)
    }

    /// The navigation bars on screen: a hidden bar leaves the tree.
    private var shownBars: [XCUIElement] {
        app.navigationBars.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
    }

    private func assertOneBar(_ context: String) {
        let bars = shownBars
        if bars.count != 1 { attachHierarchy("bars for \(context)") }
        XCTAssertEqual(bars.count, 1, "\(context) shows one navigation bar, not \(bars.map(\.frame))")
        XCTAssertLessThanOrEqual(
            app.buttons.matching(identifier: "fileViewer.share").count, 1,
            "\(context) offers one Share"
        )
    }

    private func attachHierarchy(_ name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    /// Keeps a screenshot in the result bundle and the screenshot folder,
    /// named for the device so the profiles do not overwrite each other.
    private func save(chrome: String, file name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "device"
        let file = "\(model)-\(chrome)-\(name)"
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
        try? FileManager.default.createDirectory(atPath: Self.screenshotDirectory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(Self.screenshotDirectory)/\(file).png"), options: .atomic)
    }
}
