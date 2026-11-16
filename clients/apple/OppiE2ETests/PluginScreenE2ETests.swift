import XCTest

/// MCP Servers against a real paired server: the server's MCP Servers plugin, drawn by the app's
/// generic plugin page. Adding a server through its form, switching it off, and removing it all
/// reach the server's `mcp.json` and come back as the page's own updates, in the sidebar's global
/// list and in a host workspace's own list from Workspace Settings.
@MainActor
final class PluginScreenE2ETests: E2ETestCase {
    /// The server's MCP Servers entry, as `/server/info` lists it.
    private var entry = ""

    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    private func id(_ page: String, _ section: String, _ row: String) -> String {
        "screen.\(entry).\(page).\(section).\(row)"
    }

    private func findEntry() throws {
        let sidebar = try e2eLabAPIJSON(method: "GET", path: "/server/info")["sidebar"] as? [[String: Any]]
        entry = try XCTUnwrap(sidebar?.first { $0["feature"] as? String == "mcp" }?["id"] as? String, "No MCP Servers entry")
    }

    /// The Add sheet: Add stays off until the name and URL are in, Cancel and swipe-down close
    /// it, and Add saves and closes it.
    private func addServer(_ name: String, on page: String) {
        let add = app.buttons["screen.\(entry).\(page).bar.add"]
        let sheet = app.navigationBars["Add MCP Server"]
        tap(add, named: "Add bar button", timeout: 30)
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "The Add sheet did not open")
        let cancel = app.buttons["Cancel"]
        tap(cancel, named: "Cancel")
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Cancel did not close the Add sheet")
        tap(add, named: "Add bar button")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "The Add sheet did not reopen")
        // Swipe the sheet down by its bar, as a person does.
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)),
            withVelocity: .fast, thenHoldForDuration: 0
        )
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Swipe-down did not close the Add sheet")

        tap(add, named: "Add bar button")
        let field = app.textFields[id("add", "configuration", "name")]
        tap(field, named: "server name field", timeout: 30)
        field.typeText(name)
        let submit = app.buttons["screen.\(entry).add.submit"]
        XCTAssertFalse(submit.isEnabled, "Add must stay off until the URL is in")
        let url = app.textFields[id("add", "http", "url")]
        tap(url, named: "URL field")
        url.typeText("http://127.0.0.1:9/mcp")
        XCTAssertTrue(submit.isEnabled, "Add must turn on once the name and URL are in")
        tap(submit, named: "Add")
        XCTAssertTrue(field.waitForNonExistence(timeout: 30), "The Add sheet did not close")
    }

    func testPluginEntryAddsTogglesAndRemovesAServer() throws {
        try findEntry()
        let name = "e2e-\(UUID().uuidString.prefix(6).lowercased())"
        let detail = "server/\(name)"

        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")
        tap(app.buttons["workspace.plugin.\(entry).open"], named: "MCP Servers entry")
        XCTAssertTrue(app.navigationBars["MCP Servers"].waitForExistence(timeout: 15), "MCP Servers did not open")

        addServer(name, on: "list")

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

    /// A host workspace's own servers: Workspace Settings opens the same plugin page on the
    /// workspace's scope, and a server added there lands in the workspace's `.pi/mcp.json`.
    func testWorkspaceSettingsOpensTheWorkspacesOwnServers() throws {
        try findEntry()
        let workspaceId = try e2eWorkspaceId()
        let name = "e2e-\(UUID().uuidString.prefix(6).lowercased())"

        let open = app.buttons["workspace.open.e2e-workspace"]
        if !(open.exists && open.isHittable) { tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button") }
        tap(open, named: "e2e workspace", timeout: 15)
        tap(app.buttons["workspace.edit.open"].firstMatch, named: "Workspace Settings", timeout: 15)
        tap(app.buttons["workspace.edit.mcpServers"], named: "MCP Servers row", timeout: 15)
        XCTAssertTrue(app.navigationBars["MCP Servers"].waitForExistence(timeout: 15), "The workspace's MCP Servers did not open")

        addServer(name, on: "list")
        let row = app.buttons[id("list", "servers", "server.\(name)")]
        XCTAssertTrue(row.waitForExistence(timeout: 45), "The added server is not listed")
        let scope = try e2eLabAPIJSON(method: "GET", path: "/mcp/scopes/\(workspaceId)/servers?cached=true")["scope"] as? [String: Any]
        let servers = scope?["servers"] as? [[String: Any]] ?? []
        XCTAssertTrue(servers.contains { $0["name"] as? String == name }, "The server did not land in the workspace's own file")
        _ = try? e2eLabAPIJSON(method: "DELETE", path: "/mcp/scopes/\(workspaceId)/servers/\(name)")
    }
}
