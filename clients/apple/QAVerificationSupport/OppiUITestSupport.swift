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
    /// control for that, with no identifier: a Close or Cancel button beside the field
    /// where the search bar takes the navigation bar (compact width), and only the
    /// field's Clear text button in a regular-width column. Clearing the text returns
    /// the list to its unfiltered content.
    func dismissSearch(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let leave = buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
        if leave.exists {
            leave.tap()
            return
        }
        let clear = field.buttons["Clear text"]
        XCTAssertTrue(clear.exists, "The search has neither a Close/Cancel button nor a Clear text button", file: file, line: line)
        clear.tap()
    }
}
