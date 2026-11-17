import XCTest

/// The server's plugin pages against a real paired server, drawn by the app's generic plugin page.
/// MCP Servers: adding a server through its form, switching it off, and removing it all reach the
/// server's `mcp.json` and come back as the page's own updates, in the sidebar's global list and
/// in a host workspace's own list from Workspace Settings. Skills: the catalog searches on the
/// device, a Skill's switch reaches Pi's settings, and its files open in the app's own viewer
/// (the native server starts with `server/e2e/skills`).
@MainActor
final class PluginScreenE2ETests: E2ETestCase {
    /// The server's MCP Servers entry, as `/server/info` lists it.
    private var entry = ""

    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    private func id(_ page: String, _ section: String, _ row: String) -> String {
        "screen.\(entry).\(page).\(section).\(row)"
    }

    private func findEntry(feature: String = "mcp") throws {
        let sidebar = try e2eLabAPIJSON(method: "GET", path: "/server/info")["sidebar"] as? [[String: Any]]
        entry = try XCTUnwrap(sidebar?.first { $0["feature"] as? String == feature }?["id"] as? String, "No \(feature) entry")
    }

    /// The Add sheet filled with `name` and an HTTP URL, then Add.
    private func submitServer(_ name: String, on page: String) {
        tap(app.buttons["screen.\(entry).\(page).bar.add"], named: "Add bar button", timeout: 30)
        let field = app.textFields[id("add", "configuration", "name")]
        tap(field, named: "server name field", timeout: 30)
        field.typeText(name)
        let url = app.textFields[id("add", "http", "url")]
        tap(url, named: "URL field")
        url.typeText("http://127.0.0.1:9/mcp")
        tap(app.buttons["screen.\(entry).add.submit"], named: "Add")
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

        // A failed action: the server refuses the same name again, and the sheet stays open with
        // the server's words in a row VoiceOver reads.
        submitServer(name, on: "list")
        let failure = app.cells["screen.\(entry).add.failure"]
        XCTAssertTrue(
            scrollToElement(failure, in: app.collectionViews["screen.\(entry).add.list"], timeout: 30),
            "The refused Add shows no failure row"
        )
        XCTAssertTrue(failure.label.contains("already exists"), "The failure row does not say why: '\(failure.label)'")
        tap(app.buttons["Cancel"], named: "Cancel")
        XCTAssertTrue(app.navigationBars["Add MCP Server"].waitForNonExistence(timeout: 10), "Cancel did not close the Add sheet")

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

    func testSkillsPageSearchesSwitchesAndOpensFiles() throws {
        try findEntry(feature: "skills")
        let catalog = try e2eLabAPIJSON(method: "GET", path: "/server/resources/skills")["skills"] as? [[String: Any]] ?? []
        guard let release = catalog.first(where: { $0["name"] as? String == "release-checklist" })?["id"] as? String else {
            throw XCTSkip("The server has no seeded Skills (e2e.sh --native copies server/e2e/skills)")
        }
        let skill = "skill/\(release)"
        let files = "files/\(release)"

        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button")
        tap(app.buttons["workspace.plugin.\(entry).open"], named: "Skills entry")
        XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 15), "Skills did not open")
        let row = app.buttons[id("list", "enabled", "skill.\(release)")]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The seeded Skill is not listed")

        // Search filters on the device; nothing matching says so.
        let search = app.searchFields["Search skills"]
        tap(search, named: "Search skills")
        search.typeText("no-matching-e2e-skill")
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "Search did not filter the list")
        XCTAssertTrue(app.staticTexts["screen.\(entry).list.state"].waitForExistence(timeout: 10), "No empty search state")
        // Clear the query (an iPad's bar search has no Cancel).
        tap(search.buttons["Clear text"], named: "Clear search")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Ending the search did not bring the rows back")

        // The Skill's switch writes Pi's settings and the page follows.
        tap(row, named: "release-checklist")
        XCTAssertTrue(app.navigationBars["release-checklist"].waitForExistence(timeout: 15), "The Skill's page did not open")
        let enabled = app.switches[id(skill, "default", "enabled")]
        XCTAssertTrue(enabled.waitForExistence(timeout: 30))
        enabled.tap()
        let off = NSPredicate(format: "value == '0' AND isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: off, evaluatedWith: enabled)], timeout: 30), .completed)
        let stored = try e2eLabAPIJSON(method: "GET", path: "/server/resources/skills")["skills"] as? [[String: Any]]
        XCTAssertEqual(stored?.first { $0["id"] as? String == release }?["state"] as? String, "disabled")
        enabled.tap()
        let on = NSPredicate(format: "value == '1' AND isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: on, evaluatedWith: enabled)], timeout: 30), .completed)

        // Files: folders are pages, and a file opens in the Skill file viewer with its editor.
        let browse = app.buttons[id(skill, "contents", "browse")]
        XCTAssertTrue(scrollToElement(browse, in: app.collectionViews["screen.\(entry).\(skill).list"], timeout: 15))
        tap(browse, named: "Browse Files")
        // Row ids are the plugin's: `folder.<name>` and `file.<name>`.
        let rowId = { (kind: String, name: String) in [kind, name].joined(separator: ".") }
        tap(app.buttons[id(files, "files", rowId("folder", "scripts"))], named: "scripts folder", timeout: 15)
        tap(app.buttons[id("\(files)/scripts", "files", rowId("file", "check.sh"))], named: "check.sh", timeout: 15)
        XCTAssertTrue(app.buttons["workspace-file-editor.edit"].waitForExistence(timeout: 20), "The Skill's file has no editor")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        tap(app.buttons[id(files, "files", rowId("file", "SKILL.md"))], named: "SKILL.md", timeout: 15)
        XCTAssertTrue(app.buttons["workspace-file-editor.edit"].waitForExistence(timeout: 20), "SKILL.md has no editor")
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
