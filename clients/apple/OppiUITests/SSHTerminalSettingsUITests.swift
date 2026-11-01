import XCTest

/// Settings › Terminal, reached both ways: the Terminal page's ⚙︎ and Settings →
/// Terminal, over the settings sweep (`SCREENSHOT_SWEEP_PAGE=ssh-hosts` for the
/// tab, `ssh-term-settings` for App Settings and the page it pushes). A saved
/// host's form opens from its row in Settings and from the row's ⋯ on the tab,
/// where the same menu deletes a host after asking; Rex on Your Tailnet takes a
/// name typed by hand.
@MainActor
final class SSHTerminalSettingsUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Terminal settings tests are simulator-only")
#endif
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// The sweep page with both experiments on: this page's Rex row (and the Rex
    /// host the sweep seeds) exist only while Rex's switch is on, and a launch that
    /// does not say so gets the app's stored answer.
    private func launch(page: String) {
        launchPreview(
            screen: "settings-sweep",
            environment: ["SCREENSHOT_SWEEP_PAGE": page],
            colorScheme: "dark",
            arguments: OppiTestLaunch.experimentArguments([.rex: true, .herdr: true])
        )
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private var hostMenus: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshTerminal.host.menu."))
    }

    private func openTerminalSettings() {
        let settings = app.buttons["sshTerminal.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "The Terminal page's ⚙︎ did not appear")
        settings.tap()
        XCTAssertTrue(
            element("settings.sshTerminal.list").waitForExistence(timeout: 5),
            "⚙︎ must open Settings › Terminal"
        )
    }

    /// The tab's own setup is one tap off it: the Bottom Bar row, and a saved
    /// host's ⋯, which opens the form the row's Edit button used to.
    func testThePageOpensTerminalSettingsAndItsHostForm() {
        launch(page: "ssh-hosts")
        attachScreenshot("terminal-page")
        openTerminalSettings()
        attachScreenshot("settings-terminal")

        let hosts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.sshTerminal.host."))
        XCTAssertEqual(hosts.count, 2, "Both saved hosts are rows")
        XCTAssertTrue(element("settings.sshTerminal.rexTailnet").exists)
        XCTAssertTrue(element("settings.sshTerminal.bar").exists)

        // The Bottom Bar row opens the bar's own page, and Back returns here.
        app.buttons["settings.sshTerminal.bar"].firstMatch.tap()
        XCTAssertTrue(element("settings.sshTerminal.bar.list").waitForExistence(timeout: 5), "Bottom Bar did not open")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(element("settings.sshTerminal.list").waitForExistence(timeout: 5), "Back must return to Terminal Settings")

        // The ⋯ is the Terminal page's row, so Back once more takes this there.
        app.buttons["BackButton"].firstMatch.tap()
        let menu = hostMenus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "The Terminal page's host row has no ⋯ menu")
        menu.tap()
        attachScreenshot("host-menu")
        // A menu's items carry no identifier, so each is found by its title.
        let edit = app.descendants(matching: .any)["Edit Host"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "The host menu must offer Edit Host")
        edit.tap()
        XCTAssertTrue(app.textFields["sshTerminal.host"].waitForExistence(timeout: 5), "Edit Host did not push the form")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons["sshTerminal.settings"].waitForExistence(timeout: 5),
            "Back must return to the Terminal page the form was opened from"
        )
        assertRunning()
    }

    /// Rex on Your Tailnet lists the names saved by hand, and adds one typed in the
    /// prompt, which is the only way onto a tailnet Oppi cannot list itself.
    func testARexAddedByItsTailscaleNameIsListed() {
        launch(page: "ssh-hosts")
        openTerminalSettings()
        app.buttons["settings.sshTerminal.rexTailnet"].firstMatch.tap()
        XCTAssertTrue(
            element("settings.sshTerminal.rexTailnet.list").waitForExistence(timeout: 5),
            "Rex on Your Tailnet did not open"
        )
        let add = app.buttons["settings.sshTerminal.rexTailnet.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "The page has no Add Rex by Tailscale Name row")

        add.tap()
        let field = app.textFields["sshTerminal.rexTailnet.addName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Add Rex by Tailscale Name did not ask for a name")
        field.tap()
        field.typeText("rex.tail1234.ts.net")
        // The alert's button is exposed twice on iOS 27 (once as a key artifact), so
        // the tap takes the first match.
        app.buttons["sshTerminal.rexTailnet.addConfirm"].firstMatch.tap()

        let row = element("settings.sshTerminal.rexTailnet.rex.tail1234.ts.net")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The added Rex must be a row")
        attachScreenshot("settings-rex-tailnet-added")
        assertRunning()
    }

    /// Settings → Terminal is the same page: App Settings is beneath the page the
    /// sweep shows, so one Back reaches it and the row pushes it again. Its Hosts
    /// rows open the form.
    func testSettingsRootOpensTerminalAndItsHostForm() {
        launch(page: "ssh-term-settings")
        XCTAssertTrue(element("settings.sshTerminal.list").waitForExistence(timeout: 10), "Settings › Terminal did not open")

        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(element("settings.list").waitForExistence(timeout: 5), "Back must reach App Settings")
        let terminal = app.buttons["settings.sshTerminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "App Settings has no Terminal row")
        terminal.tap()
        XCTAssertTrue(
            element("settings.sshTerminal.list").waitForExistence(timeout: 5),
            "Settings → Terminal must open Terminal Settings"
        )

        let host = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.sshTerminal.host.")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5), "Terminal Settings has no host row")
        host.tap()
        XCTAssertTrue(app.textFields["sshTerminal.host"].waitForExistence(timeout: 5), "A host row must open its form")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(element("settings.sshTerminal.list").waitForExistence(timeout: 5), "Back must return to Terminal Settings")
        assertRunning()
    }

    /// The tab's ⋯ offers Delete Host, and it asks before it touches anything.
    ///
    /// It cannot go on to assert the row leaving: the sweep seeds the saved hosts in
    /// the argument domain, which outranks the persistent one a delete writes to, so
    /// the host is still read back after the deletion. What the confirmation runs is
    /// the same `deleteHost(_:)` the row's swipe uses, which `SSHTerminalHostRowActionTests`
    /// covers.
    func testTheHostMenuAsksBeforeDeletingAHost() {
        launch(page: "ssh-hosts")
        let menus = hostMenus
        XCTAssertEqual(menus.count, 2, "Both saved hosts have a ⋯ menu")
        menus.firstMatch.tap()
        let delete = app.descendants(matching: .any)["Delete Host"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "The host menu must offer Delete Host")
        delete.tap()
        // A sheet on iPhone, a popover on iPad; the confirming button is the one
        // element with its own identifier, exposed twice (once as a key artifact).
        let confirm = app.buttons["sshTerminal.host.delete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting a host must ask first")
        attachScreenshot("host-delete-confirmation")

        // Since iOS 26 an action sheet anchored to its source is drawn as a popover
        // and the system omits the `.cancel` action: a tap outside dismisses it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "Tapping outside must close the confirmation")
        assertRunning()
    }
}
