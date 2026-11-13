import XCTest

/// Markdown tables on the `markdown-tables` preview, driven as a user would:
/// the Show all bar under a table cut at the card's edge or folded behind
/// "Show all 40 rows", the full-screen viewer it opens, and that viewer's
/// header. The preview holds one live-renderer message; unit tests own the
/// layout numbers.
@MainActor
final class MarkdownTablesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI harness tests are simulator-only")
#endif
        continueAfterFailure = false
        // The simulator keeps the orientation an earlier test left; the preview's
        // scroll distances assume a portrait window.
        XCUIDevice.shared.orientation = .portrait
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

    private func showAllBar(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == 'markdown.table.showAll' AND label == %@", label
        )).firstMatch
    }

    /// The bar under each cut or folded table sits below its last row: nothing
    /// it says covers a cell (a pill over the rows once hid the last row's values).
    func testShowAllBarNeverCoversTheRows() {
        for label in ["Show all 11 columns", "Show all 40 rows"] {
            let bar = showAllBar(label)
            scrollUntilHittable(bar)
            let tables = app.descendants(matching: .any).matching(identifier: "markdown.table").allElementsBoundByIndex
            guard let table = tables.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(bar.frame) }) else {
                return XCTFail("No table holds the bar \(label) at \(bar.frame): \(tables.map(\.frame))")
            }
            let rows = table.descendants(matching: .textView).allElementsBoundByIndex
                + table.descendants(matching: .cell).allElementsBoundByIndex
            XCTAssertFalse(rows.isEmpty, "\(label): the table's rows are visible to the test")
            for row in rows where row.frame.width > 1 {
                XCTAssertLessThanOrEqual(row.frame.maxY, bar.frame.minY + 0.5, "\(label) covers \(row.frame)")
            }
        }
    }

    /// The viewer's body, once the bar has opened it.
    private func openViewer(from label: String) -> XCUIElement {
        let bar = showAllBar(label)
        scrollUntilHittable(bar)
        bar.tap()
        let body = app.descendants(matching: .any)["fullScreen.markdownTable.body"]
        XCTAssertTrue(body.waitUntilExists(timeout: 6), "\(label) should open the full-screen table")
        return body
    }

    private func cell(_ label: String, in body: XCUIElement) -> XCUIElement {
        body.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testCutTableNamesItsColumnsInTheBarThatOpensTheViewer() {
        let body = openViewer(from: "Show all 11 columns")
        // Every column is in the viewer, the last one a swipe away.
        XCTAssertTrue(cell("Endpoint", in: body).waitUntilExists(timeout: 3))
        XCTAssertTrue(cell("runbookDocumentationPath", in: body).exists)
    }

    /// A table shorter than the screen starts below the bar, not under its
    /// Back button (the grid once took no inset when it could not scroll).
    func testShortTableHeaderSitsBelowTheBarInTheViewer() {
        let body = openViewer(from: "Show all 11 columns")
        let header = cell("Endpoint", in: body)
        XCTAssertTrue(header.waitUntilExists(timeout: 3))
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.exists)
        XCTAssertGreaterThanOrEqual(header.frame.minY, bar.frame.maxY - 0.5, "Header \(header.frame) under the bar \(bar.frame)")
        XCTAssertTrue(app.staticTexts["11 columns \u{00B7} 3 rows"].exists, "The caption counts what the table holds")
    }

    func testLongTableFoldsAndShowAllOpensEveryRow() {
        let body = openViewer(from: "Show all 40 rows")
        XCTAssertTrue(cell("Item", in: body).waitUntilExists(timeout: 3), "The header row is in the viewer")
        let lastRow = cell("item-40", in: body)
        let scroll = app.scrollViews["fullScreen.markdownTable.scroll"]
        for _ in 0 ..< 6 where !lastRow.isHittable {
            scroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(lastRow.isHittable, "Scrolling reaches the 40th row")
    }

    /// A table that fits has no bar; a long press offers View Full Screen.
    func testFittingTableOpensFullScreenFromItsLongPressMenu() {
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Qualification'")).firstMatch
        scrollUntilHittable(cell)
        cell.press(forDuration: 1.0)
        let view = app.buttons["View Full Screen"].firstMatch
        XCTAssertTrue(view.waitUntilExists(timeout: 3), "The long-press menu offers View Full Screen")
        XCTAssertTrue(app.buttons["Copy as Markdown"].exists, "and the copy actions")
        view.tap()
        let body = app.descendants(matching: .any)["fullScreen.markdownTable.body"]
        XCTAssertTrue(body.waitUntilExists(timeout: 6), "View Full Screen opens the table")
        XCTAssertTrue(app.staticTexts["3 columns \u{00B7} 3 rows"].exists)
    }

    func testViewerOffersCopyAsTSVAndMarkdown() {
        _ = openViewer(from: "Show all 40 rows")
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
