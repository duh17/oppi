import XCTest

/// Markdown tables on the `markdown-tables` preview, driven as a user would:
/// the chip on the trailing edge of a table whose columns run past it, the
/// "Show 20 more rows" bar under a folded one, the full-screen viewer each
/// opens, and that viewer's header. The preview holds one live-renderer
/// message; unit tests own the layout numbers.
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
        for _ in 0 ..< 16 where !element.isHittable {
            scroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable, "\(element) never became hittable")
    }

    private func rowsBar(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == 'markdown.table.showAll' AND label == %@", label
        )).firstMatch
    }

    private func columnsChip(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == 'markdown.table.moreColumns' AND label == %@", label
        )).firstMatch
    }

    private func table(holding element: XCUIElement) -> XCUIElement? {
        app.descendants(matching: .any).matching(identifier: "markdown.table").allElementsBoundByIndex
            .first { $0.frame.insetBy(dx: -1, dy: -1).contains(element.frame) }
    }

    /// The rows bar sits below the last row: nothing it says covers a cell (a
    /// pill over the rows once hid the last row's values).
    func testRowsBarNeverCoversTheRows() {
        let bar = rowsBar("Show 20 more rows")
        scrollUntilHittable(bar)
        guard let table = table(holding: bar) else {
            return XCTFail("No table holds the rows bar at \(bar.frame)")
        }
        let rows = table.descendants(matching: .textView).allElementsBoundByIndex
            + table.descendants(matching: .cell).allElementsBoundByIndex
        XCTAssertFalse(rows.isEmpty, "The table's rows are visible to the test")
        for row in rows where row.frame.width > 1 {
            XCTAssertLessThanOrEqual(row.frame.maxY, bar.frame.minY + 0.5, "The bar covers \(row.frame)")
        }
    }

    /// The viewer's body, once a chip or bar has opened it.
    private func openViewer(from control: XCUIElement) -> XCUIElement {
        scrollUntilHittable(control)
        control.tap()
        let body = app.descendants(matching: .any)["fullScreen.markdownTable.body"]
        XCTAssertTrue(body.waitUntilExists(timeout: 6), "\(control) should open the full-screen table")
        return body
    }

    private func cell(_ label: String, in body: XCUIElement) -> XCUIElement {
        body.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// The chip on a cut table's edge goes away once the rows scroll to the last
    /// column, comes back on the way back, and opens the viewer.
    func testEdgeChipFollowsTheSidewaysScrollAndOpensTheViewer() throws {
        let first = app.buttons.matching(identifier: "markdown.table.moreColumns").firstMatch
        scrollUntilHittable(first)
        let table = try XCTUnwrap(table(holding: first), "No table holds the chip at \(first.frame)")
        let chip = table.buttons["markdown.table.moreColumns"]
        XCTAssertTrue(chip.label.hasPrefix("Show all "), chip.label)
        for _ in 0 ..< 10 where chip.exists {
            table.swipeLeft()
        }
        XCTAssertFalse(chip.exists, "At the last column nothing is past the edge")
        for _ in 0 ..< 10 where !chip.exists {
            table.swipeRight()
        }
        XCTAssertTrue(chip.waitUntilExists(timeout: 2), "Scrolling back brings the chip back")
        chip.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["fullScreen.markdownTable.body"].waitUntilExists(timeout: 6),
            "The chip opens the full-screen table"
        )
    }

    func testCutTableChipOpensEveryColumn() {
        let body = openViewer(from: columnsChip("Show all 11 columns"))
        // Every column is in the viewer, the last one a swipe away.
        XCTAssertTrue(cell("Endpoint", in: body).waitUntilExists(timeout: 3))
        XCTAssertTrue(cell("runbookDocumentationPath", in: body).exists)
    }

    /// A table shorter than the screen starts below the bar, not under its
    /// Back button (the grid once took no inset when it could not scroll).
    func testShortTableHeaderSitsBelowTheBarInTheViewer() {
        let body = openViewer(from: columnsChip("Show all 11 columns"))
        let header = cell("Endpoint", in: body)
        XCTAssertTrue(header.waitUntilExists(timeout: 3))
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.exists)
        XCTAssertGreaterThanOrEqual(header.frame.minY, bar.frame.maxY - 0.5, "Header \(header.frame) under the bar \(bar.frame)")
        XCTAssertTrue(app.staticTexts["11 columns \u{00B7} 3 rows"].exists, "The caption counts what the table holds")
    }

    func testLongTableFoldsAndTheRowsBarOpensEveryRow() {
        let body = openViewer(from: rowsBar("Show 20 more rows"))
        XCTAssertTrue(cell("Item", in: body).waitUntilExists(timeout: 3), "The header row is in the viewer")
        let lastRow = cell("item-40", in: body)
        let scroll = app.scrollViews["fullScreen.markdownTable.scroll"]
        for _ in 0 ..< 6 where !lastRow.isHittable {
            scroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(lastRow.isHittable, "Scrolling reaches the 40th row")
    }

    /// A table that fits wears no control; a long press offers View Full Screen.
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
        _ = openViewer(from: rowsBar("Show 20 more rows"))
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
