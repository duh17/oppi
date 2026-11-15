import XCTest

/// A server plugin's sidebar entry against a real paired server: the MCP Servers plugin, drawn
/// by the app's generic plugin page. Adding a server through its form, switching it off, and
/// removing it all reach the server's `mcp.json` and come back as the page's own updates.
@MainActor
final class PluginScreenE2ETests: E2ETestCase {
    /// The server's own MCP Servers entry, as `/server/info` lists it.
    private var entry = ""

    /// The plugin-sidebar experiment is a launch argument, which only a fresh launch applies.
    override var e2eRequiresFreshLaunch: Bool { true }
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchArguments += ["-dev.chenda.Oppi.experiments.pluginSidebar", "YES"]
    }

    private func id(_ page: String, _ section: String, _ row: String) -> String {
        "screen.\(entry).\(page).\(section).\(row)"
    }

    func testPluginEntryAddsTogglesAndRemovesAServer() throws {
        let sidebar = try e2eLabAPIJSON(method: "GET", path: "/server/info")["sidebar"] as? [[String: Any]]
        entry = try XCTUnwrap(sidebar?.first { $0["title"] as? String == "MCP Servers" }?["id"] as? String, "No plugin MCP entry")
        let name = "e2e-\(UUID().uuidString.prefix(6).lowercased())"
        let detail = "server/\(name)"

        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")
        tap(app.buttons["workspace.plugin.\(entry).open"], named: "plugin MCP Servers entry")
        XCTAssertTrue(app.navigationBars["MCP Servers"].waitForExistence(timeout: 15), "The plugin page did not open")

        // Add, through the plugin's form: a sheet with a local draft and its own submit.
        tap(app.buttons["screen.\(entry).list.bar.add"], named: "Add bar button", timeout: 30)
        let field = app.textFields[id("add", "configuration", "name")]
        tap(field, named: "server name field")
        field.typeText(name)
        let url = app.textFields[id("add", "http", "url")]
        tap(url, named: "URL field")
        url.typeText("http://127.0.0.1:9/mcp")
        tap(app.buttons["screen.\(entry).add.submit"], named: "Add")
        XCTAssertTrue(field.waitForNonExistence(timeout: 30), "The Add sheet did not close")

        // The list probes again by itself and shows the new server.
        let row = app.buttons[id("list", "servers", "server.\(name)")]
        XCTAssertTrue(row.waitForExistence(timeout: 45), "The added server is not listed")
        tap(row, named: "the added server")
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 15), "The server's page did not open")

        // Enabled: the switch acts on the server, and the page's next value shows it off.
        let enabled = app.switches[id(detail, "config", "enabled")]
        XCTAssertTrue(enabled.waitForExistence(timeout: 30))
        XCTAssertEqual(enabled.value as? String, "1")
        enabled.tap()
        let off = NSPredicate(format: "value == '0' AND isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: off, evaluatedWith: enabled)], timeout: 30), .completed)
        let status = app.cells[id(detail, "info", "status")]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(
            for: NSPredicate(format: "value == 'Disabled'"), evaluatedWith: status
        )], timeout: 30), .completed, "The server's status did not follow the switch")

        // Remove: the plugin asks for confirmation through the app, then the page closes.
        let list = app.collectionViews["screen.\(entry).\(detail).list"]
        let remove = app.buttons[id(detail, "remove", "remove")]
        XCTAssertTrue(scrollToElement(remove, in: list, timeout: 15), "No Remove Server row")
        tap(remove, named: "Remove Server")
        tap(app.buttons["\(id(detail, "remove", "remove")).confirm"].firstMatch, named: "Remove confirmation")
        XCTAssertTrue(app.navigationBars["MCP Servers"].waitForExistence(timeout: 30), "Remove did not return to the list")
        XCTAssertTrue(row.waitForNonExistence(timeout: 45), "The removed server is still listed")
    }
}
