import XCTest

/// Markdown tables on the `markdown-tables` preview, driven as a user would:
/// the "N more columns" cue on a table that scrolls sideways, a long table
/// folded behind "Show all 30 rows", the full-screen viewer those open, its
/// pinned header, and a clipped cell opening its full text. The preview holds
/// one live-renderer message; unit tests own the layout numbers.
@MainActor
final class MarkdownTablesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI harness tests are simulator-only")
#endif
        continueAfterFailure = false
        let application = OppiTestLaunch.makeApp()
        application.launchArguments.append("--screenshot-preview")
        application.launchEnvironment["SCREENSHOT_SCREEN"] = "markdown-tables"
        application.launch()
        app = application
        XCTAssertTrue(
            app.descendants(matching: .any)["screenshot.ready"].waitUntilExists(timeout: 10),
            "Markdown tables preview did not become ready"
        )
    }

    private func scrollUntilHittable(_ element: XCUIElement) {
        let scroll = app.scrollViews["markdownTables.scroll"]
        for _ in 0 ..< 8 where !element.isHittable {
            scroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable, "\(element) never became hittable")
    }

    func testWideTableShowsAMoreColumnsCueThatOpensTheViewer() {
        let cue = app.buttons["markdown.table.moreColumns"].firstMatch
        scrollUntilHittable(cue)
        XCTAssertTrue(cue.label.hasSuffix("more columns"), "Cue reads \(cue.label)")

        cue.tap()
        let grid = app.collectionViews["delimited-table.grid"]
        XCTAssertTrue(grid.waitUntilExists(timeout: 6), "The cue should open the full-screen table viewer")
        // Every column is in the viewer: the last one is a click away from view.
        XCTAssertTrue(app.staticTexts["Endpoint"].exists || app.otherElements["Endpoint"].exists)
    }

    func testLongTableFoldsAndShowAllOpensEveryRowWithAPinnedHeader() {
        let showAll = app.buttons["markdown.table.showAll"].firstMatch
        scrollUntilHittable(showAll)
        XCTAssertEqual(showAll.label, "Show all 30 rows")

        showAll.tap()
        let grid = app.collectionViews["delimited-table.grid"]
        XCTAssertTrue(grid.waitUntilExists(timeout: 6), "Show all should open the full-screen table viewer")

        let header = grid.cells.matching(NSPredicate(format: "label == 'Item'")).firstMatch
        XCTAssertTrue(header.waitUntilExists(timeout: 3), "The header row is in the viewer")
        let before = header.frame.minY

        grid.swipeUp(velocity: .slow)
        grid.swipeUp(velocity: .slow)
        let lastRow = grid.cells.matching(NSPredicate(format: "label CONTAINS 'row 30'")).firstMatch
        XCTAssertTrue(lastRow.waitUntilExists(timeout: 3), "Scrolling reaches the 30th row (\(grid.cells.count) cells mounted)")
        XCTAssertTrue(header.exists, "The header stays mounted while the rows scroll")
        XCTAssertEqual(header.frame.minY, before, accuracy: 1, "The header stays pinned at the top")
        XCTAssertLessThan(grid.cells.count, 150, "Only the cells in view are mounted")

        // A tap on a cell opens its whole text in a sheet.
        lastRow.tap()
        let detail = app.textViews["table.cell.detail.text"]
        XCTAssertTrue(detail.waitUntilExists(timeout: 4), "Tapping a cell should show its full text")
        XCTAssertFalse((detail.value as? String ?? "").isEmpty)
    }

    func testViewerOffersCopyAsTSVAndMarkdown() {
        let showAll = app.buttons["markdown.table.showAll"].firstMatch
        scrollUntilHittable(showAll)
        showAll.tap()
        XCTAssertTrue(app.collectionViews["delimited-table.grid"].waitUntilExists(timeout: 6))

        let copy = app.buttons["fullscreen-code.copy"]
        XCTAssertTrue(copy.waitUntilExists(timeout: 3))
        copy.tap()
        XCTAssertTrue(
            app.buttons["Copy as TSV"].waitUntilExists(timeout: 3),
            "Copy should offer TSV"
        )
        XCTAssertTrue(app.buttons["Copy as Markdown"].exists, "Copy should offer Markdown")
    }
}
