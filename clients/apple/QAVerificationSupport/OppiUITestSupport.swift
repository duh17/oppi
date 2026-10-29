import XCTest

/// Queries shared by UI and E2E tests: controls found by their identifier, with
/// the label read only where the label is the state under test
/// (`dev/testing/ios-accessibility-testability.md`, "Identifier naming").
extension XCUIApplication {
    /// The server switcher whose label names `name` (`Current server: <name>`).
    /// Every switcher shares `server.switcher`; the label says which server is current.
    func serverSwitcher(named name: String) -> XCUIElement {
        buttons.matching(identifier: "server.switcher")
            .matching(NSPredicate(format: "label == %@", "Current server: \(name)"))
            .firstMatch
    }

    /// Ends the search `field` has started, as a person does. The system draws its own
    /// control for that, with no identifier, and which one depends on the window's
    /// horizontal size class (not the field's: a regular-width column reports compact).
    /// Compact width has a Close or Cancel button beside the field and requires it, so a
    /// missing one fails instead of clearing. Regular width has only the field's Clear
    /// text button; clearing the text returns the list to its unfiltered content.
    func dismissSearch(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if windows.firstMatch.horizontalSizeClass == .compact {
            let leave = buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
            XCTAssertTrue(leave.exists, "A compact-width search must offer Close or Cancel", file: file, line: line)
            leave.tap()
        } else {
            let clear = field.buttons["Clear text"]
            XCTAssertTrue(clear.exists, "A regular-width search must offer Clear text", file: file, line: line)
            clear.tap()
        }
    }
}
