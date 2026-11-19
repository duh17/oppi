import XCTest

/// The Rex pane in the production shell over the chat-routes fixtures
/// (`SCREENSHOT_SCREEN=pane-restore`, `PANE_RESTORE_REX=1`) on the iPad mini,
/// with the Rex experiment on. The saved host's Rex is a fake one in process
/// (`RexFakeWorld`), and a session opens a fake Rex session terminal
/// (`RexFakeSession`), so the launcher, the list and the terminal are the real
/// screens inside a real pane.
///
/// Captures go to the result bundle and, with `OPPI_REX_PANE_SHOTS` set, to that
/// folder upright at 1400 px at most.
@MainActor
final class RexPaneUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    private let sessionRow = "session.nav.chat-routes-session"
    private let rexRow = "sshTerminal.rexList.5E5E5E5E-0000-4000-8000-000000000001.session:01a18a26-6620-76be-b529-4d9ad2b36c63"

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Pane tests are simulator-only")
#endif
        continueAfterFailure = false
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
    }

    /// Rex in the launcher opens the Rex list beside the chat, with no mode
    /// button; a session opens its terminal inside that pane, which follows a
    /// divider drag and a rotation and stays beside the chat.
    func testRexOpensFromTheLauncherBesideTheChat() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Panes need a wide window; the iPad mini is the wide simulator")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        launchPreview(
            screen: "pane-restore",
            environment: ["PANE_RESTORE_REX": "1"],
            colorScheme: "dark",
            arguments: OppiTestLaunch.experimentArguments([.rex: true]),
            ready: nil
        )
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(composer.waitUntilExists(timeout: 10), "The chat opened")

        app.typeKey("d", modifierFlags: .command)
        let rex = app.buttons["pane.launcher.rex"]
        XCTAssertTrue(rex.waitUntilExists(timeout: 5), "⌘D opened the launcher, which offers Rex")
        hold()
        capture("launcher")
        rex.tap()

        let session = app.buttons[rexRow]
        XCTAssertTrue(session.waitUntilExists(timeout: 15), "The Rex pane lists the host's sessions")
        XCTAssertFalse(app.buttons["sshTerminal.mode"].exists, "The Rex pane has no mode button")
        XCTAssertTrue(composer.isHittable, "The chat stays beside the Rex pane")
        hold()
        capture("rex-list")

        session.tap()
        let grid = app.descendants(matching: .any)["sshTerminal.grid"]
        XCTAssertTrue(grid.waitUntilExists(timeout: 15), "The session's terminal opened")
        XCTAssertTrue(composer.isHittable, "The chat stays beside the terminal")
        XCTAssertLessThanOrEqual(composer.frame.maxX, grid.frame.minX + 1, "The terminal is in the pane after the chat")
        hold(for: 1.5)
        capture("rex-terminal")

        // The divider: the Rex pane grows, and the terminal with it.
        let before = grid.frame.width
        let divider = app.descendants(matching: .any)["pane.divider.1"]
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "A divider sits between the panes")
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -160, dy: 0)))
        XCTAssertTrue(waitFor(grid.frame.width > before + 100), "The terminal follows the divider (\(before) → \(grid.frame.width))")
        hold(for: 1.5)
        capture("rex-terminal-resized")

        // A rotation keeps the terminal in its pane (portrait may show one pane
        // at a time, so the claim is made back in landscape).
        XCUIDevice.shared.orientation = .portrait
        hold(for: 1.5)
        capture("rex-terminal-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        hold(for: 1.5)
        XCTAssertTrue(grid.exists && composer.isHittable, "Back in landscape, the terminal is beside the chat")
        assertRunning()
    }

    /// A Rex terminal that fills the panes beside the shown sidebar fits its
    /// grid beside the sidebar, not under it, and takes the sidebar's room
    /// back when the sidebar hides.
    func testAZoomedRexTerminalFitsBesideTheSidebar() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The sidebar sits beside the panes on the iPad mini in landscape")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        launchPreview(
            screen: "pane-restore",
            environment: ["PANE_RESTORE_REX": "1"],
            colorScheme: "dark",
            arguments: OppiTestLaunch.experimentArguments([.rex: true]),
            ready: nil
        )
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].waitUntilExists(timeout: 10), "The chat opened")
        app.typeKey("d", modifierFlags: .command)
        let rex = app.buttons["pane.launcher.rex"]
        XCTAssertTrue(rex.waitUntilExists(timeout: 5), "⌘D opened the launcher, which offers Rex")
        rex.tap()
        let session = app.buttons[rexRow]
        XCTAssertTrue(session.waitUntilExists(timeout: 15), "The Rex pane lists the host's sessions")
        session.tap()
        let grid = app.descendants(matching: .any)["sshTerminal.grid"]
        XCTAssertTrue(grid.waitUntilExists(timeout: 15), "The session's terminal opened")
        hold(for: 1.5)
        capture("split-beside-chat")

        let grip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.' AND label ENDSWITH '2 of 2'")).firstMatch
        XCTAssertTrue(grip.waitUntilExists(timeout: 5), "The terminal's pane has a grip")
        let sidebar = app.descendants(matching: .any)["workspace.sidebar.scroll"]
        if !(sidebar.exists && sidebar.isHittable) { app.buttons["workspace.split.sidebarToggle"].tap() }
        XCTAssertTrue(waitFor(sidebar.exists && sidebar.isHittable), "The sidebar shows")
        grip.tap()
        app.buttons["pane.menu.zoom"].tap()
        XCTAssertTrue(waitFor(grid.frame.width > 600), "Zoom filled the panes with the terminal: \(grid.frame)")
        hold(for: 1.5)
        capture("zoomed-sidebar-shown")
        XCTAssertGreaterThanOrEqual(grid.frame.minX, sidebar.frame.maxX - 1,
                                    "The grid is under the sidebar: \(grid.frame), sidebar \(sidebar.frame)")
        let besideSidebar = grid.frame.width

        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(waitFor(!sidebar.exists || !sidebar.isHittable), "⌃⌘S hid the sidebar")
        XCTAssertTrue(waitFor(grid.frame.width > besideSidebar + 200),
                      "The grid takes the sidebar's room: \(besideSidebar) → \(grid.frame.width)")
        hold(for: 1.5)
        capture("zoomed-sidebar-hidden")

        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(waitFor(sidebar.exists && sidebar.isHittable), "⌃⌘S showed the sidebar again")
        XCTAssertTrue(waitFor(abs(grid.frame.width - besideSidebar) < 1), "The grid fits beside the sidebar again: \(grid.frame)")
        hold(for: 1.5)
        capture("zoomed-sidebar-shown-again")
        XCTAssertGreaterThanOrEqual(grid.frame.minX, sidebar.frame.maxX - 1, "The grid is beside the sidebar again")
    }

    /// In landscape `app.screenshot()` draws the iPad sideways; the screen's
    /// capture is upright.
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(uprightScreenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["OPPI_REX_PANE_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let image = screenshot.image
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, 1400 / max(pixels.width, pixels.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        try? png.write(to: URL(filePath: folder).appending(path: "\(name).png"))
    }
}
