import XCTest

/// Splits in the production shell over the chat-routes fixtures
/// (`SCREENSHOT_SCREEN=pane-restore`), on the iPad mini in landscape: ⌘D puts
/// the launcher beside the chat, its choices fill the pane, the grip's menu
/// zooms and closes, and a file dragged from the Files pane onto the chat
/// becomes a file reference in the message. Compact width keeps one pane, so
/// every test skips on iPhone.
@MainActor
final class PaneSplitUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    private let sessionRow = "session.nav.chat-routes-session"

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Pane tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// WA2 and H1: ⌘D splits the chat's pane; the launcher sits beside it with
    /// a grip under each bar, its choices fill the pane, the grip's Zoom fills
    /// the window, and Close Pane leaves the chat alone again.
    func testSplitShowsTheLauncherAndItsChoicesFillThePane() throws {
        try openChatInLandscape()
        let window = app.windows.firstMatch
        app.typeKey("d", modifierFlags: .command)
        let launcher = app.descendants(matching: .any)["pane.launcher"]
        XCTAssertTrue(launcher.waitUntilExists(timeout: 5), "⌘D opened the launcher beside the chat")
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertLessThan(composer.frame.maxX, launcher.frame.minX + 1, "The launcher sits beside the chat")
        XCTAssertEqual(launcher.frame.maxX, window.frame.maxX, accuracy: 1)
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        XCTAssertEqual(grips.count, 2, "Each pane has a grip")
        attachScreenCapture("split-launcher")

        app.buttons["pane.launcher.files"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["fileBrowser.row.Route.md"].waitUntilExists(timeout: 10),
                      "Files fills the pane")
        attachScreenCapture("split-files")

        let filesGrip = grips.matching(NSPredicate(format: "label ENDSWITH '2 of 2'")).firstMatch
        filesGrip.tap()
        app.buttons["pane.menu.zoom"].tap()
        XCTAssertTrue(waitFor(!composer.isHittable), "Zoom filled the window with the Files pane")
        let capsule = grips.matching(NSPredicate(format: "value == 'Zoomed'")).firstMatch
        XCTAssertTrue(capsule.waitUntilExists(timeout: 5), "The zoomed pane's grip is the capsule")
        attachScreenCapture("split-zoomed")
        capsule.tap()
        XCTAssertTrue(waitFor(composer.isHittable), "The capsule restored the chat")

        filesGrip.tap()
        let close = app.buttons["Close Pane"]
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "The grip opens the pane menu")
        close.tap()
        XCTAssertTrue(waitFor(!launcher.exists && grips.count == 0), "Close Pane left the chat alone, with no grip")
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertEqual(timeline.frame.maxX, window.frame.maxX, accuracy: 2, "The chat has the window to itself again")
    }

    /// The owner's drop: a file dragged from the Files pane onto the chat's
    /// composer becomes a file reference in the message, and a file dropped
    /// on the Files pane's lower edge opens below it.
    func testAFileDraggedFromTheFilesPaneOntoTheChatBecomesAReference() throws {
        try openChatInLandscape()
        app.typeKey("d", modifierFlags: .command)
        let files = app.buttons["pane.launcher.files"]
        XCTAssertTrue(files.waitUntilExists(timeout: 5), "⌘D opened the launcher")
        files.tap()
        let row = app.descendants(matching: .any)["fileBrowser.row.Route.md"]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "Files listed the workspace")
        attachScreenCapture("drop-before")

        let composer = app.descendants(matching: .any)["chat.input"]
        row.press(forDuration: 0.8, thenDragTo: composer, withVelocity: .slow, thenHoldForDuration: 0.6)
        // The composer's file reference chip: "Repo", the file's name, and Remove.
        XCTAssertTrue(app.buttons["Remove file"].waitUntilExists(timeout: 5), "The dropped file is a reference in the message")
        XCTAssertTrue(app.staticTexts["Repo"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'Route.md'")).count, 2,
                       "Route.md shows in the Files row and in the message's reference")
        attachScreenCapture("drop-on-chat")

        let window = app.windows.firstMatch
        let lowerEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.93))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: lowerEdge, withVelocity: .slow, thenHoldForDuration: 0.6)
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        XCTAssertTrue(waitFor(grips.count == 3), "A drop on the Files pane's lower edge opened the file in a pane below it")
        attachScreenCapture("drop-on-edge")
    }

    /// Touch only, no keyboard: the chat's … menu makes the first split (there
    /// is no grip with one pane), the divider drags and a double tap
    /// equalises it, the grip's menu zooms, and the grip dragged onto the
    /// chat's leading edge moves the pane there.
    func testEveryPaneOperationWorksByTouch() throws {
        try openChatInLandscape()
        let window = app.windows.firstMatch
        app.buttons["chat.toolbar.more"].tap()
        let splitRight = app.buttons["pane.menu.splitRight"]
        XCTAssertTrue(splitRight.waitUntilExists(timeout: 5), "The chat's … menu offers Split Right")
        splitRight.tap()
        let launcher = app.descendants(matching: .any)["pane.launcher"]
        XCTAssertTrue(launcher.waitUntilExists(timeout: 5), "Split Right opened the launcher beside the chat")
        attachScreenCapture("touch-split")

        let divider = app.descendants(matching: .any)["pane.divider.1"]
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "A divider sits between the panes")
        let before = launcher.frame.minX
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
        XCTAssertTrue(waitFor(launcher.frame.minX > before + 50), "Dragging the divider resized the panes")
        attachScreenCapture("touch-resized")
        // The chat's bar fits its pane once the divider settles: narrowed to
        // its minimum it keeps fewer buttons (the rest move to …), and given
        // room again it shows them all.
        let barButtons = ["chat.toolbar.files", "chat.toolbar.git", "chat.toolbar.outline", "chat.toolbar.context"]
        let shownButtons = { barButtons.filter { self.app.buttons[$0].exists }.count }
        let roomy = shownButtons()
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        XCTAssertTrue(waitFor(shownButtons() < roomy), "A narrow chat pane moves bar buttons into … (\(roomy) before)")
        attachScreenCapture("touch-chat-narrow")
        divider.doubleTap()
        XCTAssertTrue(waitFor(abs(launcher.frame.minX - window.frame.midX) < 2), "A double tap equalised them")
        XCTAssertTrue(waitFor(shownButtons() == roomy), "Given its room back, the chat's bar shows its buttons again")

        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        let launcherGrip = grips.matching(NSPredicate(format: "label ENDSWITH '2 of 2'")).firstMatch
        launcherGrip.tap()
        let zoom = app.buttons["pane.menu.zoom"]
        XCTAssertTrue(zoom.waitUntilExists(timeout: 5), "Tapping the grip opens the pane menu")
        zoom.tap()
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(waitFor(!composer.isHittable && launcher.frame.width > window.frame.width * 0.9),
                      "Zoom filled the window with the pane")
        attachScreenCapture("touch-zoomed")
        let capsule = grips.matching(NSPredicate(format: "value == 'Zoomed'")).firstMatch
        capsule.tap()
        XCTAssertTrue(waitFor(composer.isHittable), "The capsule restored both panes")

        let chatLeadingEdge = app.collectionViews["chat.timeline"].coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        launcherGrip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: chatLeadingEdge, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitFor(composer.frame.minX > launcher.frame.maxX - 1),
                      "The held grip moved the pane to the chat's leading edge: the chat is now on the right")
        attachScreenCapture("touch-moved")
    }

    /// The owner's terminal pane: Terminal in the launcher opens the
    /// workspace's folder terminal in the split. With no saved SSH host the
    /// pane shows Add Host, filled in for the server, as the chat's own
    /// Terminal button does.
    func testTerminalOpensInTheSplitPane() throws {
        try openChatInLandscape()
        app.typeKey("d", modifierFlags: .command)
        let terminal = app.buttons["pane.launcher.terminal"]
        XCTAssertTrue(terminal.waitUntilExists(timeout: 5), "⌘D opened the launcher")
        terminal.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sshTerminal.setup.list"].waitUntilExists(timeout: 10),
                      "The terminal's first step opened in the pane")
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(composer.isHittable, "The chat stays beside it")
        attachScreenCapture("split-terminal")
    }

    private func openChatInLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Splits need a wide window; the iPad mini is the wide simulator")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: [:], ready: nil)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The shell came up")
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].waitUntilExists(timeout: 10), "The chat opened")
    }

    /// The screen's capture: in landscape `app.screenshot()` draws the iPad
    /// sideways into a portrait canvas.
    private func attachScreenCapture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
