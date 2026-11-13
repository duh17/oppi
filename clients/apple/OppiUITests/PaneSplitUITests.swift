import XCTest

/// Splits in the production shell over the chat-routes fixtures
/// (`SCREENSHOT_SCREEN=pane-restore`), on the iPad mini in landscape: ⌘D puts
/// the launcher beside the chat, its choices fill the pane, the grip's menu
/// zooms and closes, and a file dragged from the Files pane onto the chat
/// becomes a file reference in the message. A divider dragged past a pane
/// collapses it to a strip. Compact width shows one pane at a time with the
/// pane chip, which is the one test that runs on iPhone.
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
        // room again it shows them all. A drag short of half the chat's
        // minimum holds it there; further would collapse it.
        let barButtons = ["chat.toolbar.files", "chat.toolbar.git", "chat.toolbar.outline", "chat.toolbar.context"]
        let shownButtons = { barButtons.filter { self.app.buttons[$0].exists }.count }
        let roomy = shownButtons()
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
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

    /// R2: a divider dragged past half a pane's minimum collapses that pane
    /// to a 20 pt strip, and the chat takes the room; a tap on the strip
    /// brings the pane back.
    func testADividerDraggedPastAPaneCollapsesItToAStrip() throws {
        try openChatInLandscape()
        let window = app.windows.firstMatch
        app.typeKey("d", modifierFlags: .command)
        let launcher = app.descendants(matching: .any)["pane.launcher"]
        XCTAssertTrue(launcher.waitUntilExists(timeout: 5), "⌘D opened the launcher beside the chat")
        let divider = app.descendants(matching: .any)["pane.divider.1"]
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "A divider sits between the panes")
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)))
        let strip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.strip.'")).firstMatch
        XCTAssertTrue(strip.waitUntilExists(timeout: 5), "Past the launcher's minimum, the release collapsed it")
        XCTAssertEqual(strip.frame.width, 20, accuracy: 1, "A collapsed pane is a 20 pt strip")
        XCTAssertEqual(strip.frame.maxX, window.frame.maxX, accuracy: 1)
        XCTAssertTrue(waitFor(!launcher.exists || !launcher.isHittable), "The launcher is out of reach")
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertEqual(timeline.frame.maxX, strip.frame.minX - 1, accuracy: 2, "The chat takes the room")
        attachScreenCapture("collapse-strip")

        strip.tap()
        XCTAssertTrue(waitFor(launcher.exists && launcher.isHittable), "A tap on the strip brought the pane back")
        XCTAssertTrue(strip.waitUntilGone(timeout: 5))
        XCTAssertGreaterThan(launcher.frame.width, 300, "at a pane's width")
        attachScreenCapture("collapse-restored")
    }

    /// §1.5 and I2: a compact window (the iPhone) shows a tree a wide window
    /// left behind one pane at a time. The chip under the bar names the pane
    /// and its place; its list shows another pane, and a swipe the next or
    /// previous one in tree order.
    func testACompactWindowShowsOnePaneAndTheChipListsTheOthers() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Compact width is the phone's; the iPad mini is always wide")
        }
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "pane-restore", environment: ["PANE_RESTORE_SEED": "splits"], ready: nil)
        let chip = app.buttons["pane.chip"]
        XCTAssertTrue(chip.waitUntilExists(timeout: 10), "Three panes on a phone show the chip")
        XCTAssertTrue(chip.label.hasSuffix("1 of 3"), "The chip names the shown pane's place: \(chip.label)")
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        XCTAssertEqual(grips.count, 0, "No grips on a compact window")
        attachScreenCapture("chip-first")

        chip.tap()
        let files = app.buttons["pane.list.leaf-2"]
        XCTAssertTrue(files.waitUntilExists(timeout: 5), "The chip lists the panes")
        files.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fileBrowser.row.Route.md"].waitUntilExists(timeout: 10),
                      "The chosen Files pane fills the window")
        XCTAssertTrue(waitFor(chip.label.hasSuffix("2 of 3")), "and the chip follows: \(chip.label)")
        attachScreenCapture("chip-files")

        chip.swipeLeft()
        XCTAssertTrue(waitFor(chip.label.hasSuffix("3 of 3")), "A swipe shows the next pane: \(chip.label)")
        chip.swipeRight()
        chip.swipeRight()
        XCTAssertTrue(waitFor(chip.label.hasSuffix("1 of 3")), "and back: \(chip.label)")
    }

    /// The pane control under the Sessions screen's bar (the chip on a
    /// compact window, the pane's grip on a wide one) never covers its
    /// search field: not when the screen appears, and not after the list
    /// scrolls the search away and back. Portrait on the iPad mini too: the
    /// sidebar is a drawer there, so the Sessions pane is not under it.
    func testThePaneControlNeverCoversTheSessionsSearch() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "pane-restore", environment: ["PANE_RESTORE_SEED": "splits"], ready: nil)
        let control = isPad
            ? app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.' AND label ENDSWITH '1 of 3'")).firstMatch
            : app.buttons["pane.chip"]
        XCTAssertTrue(control.waitUntilExists(timeout: 10), "The Sessions pane shows its pane control")
        let search = app.searchFields["Search sessions"]
        XCTAssertTrue(search.waitUntilExists(timeout: 10), "The Sessions screen shows its search")
        XCTAssertTrue(waitFor(search.isHittable), "The search shows")
        let clear = { !control.frame.intersects(search.frame) || !search.isHittable }
        XCTAssertTrue(waitFor(!control.frame.intersects(search.frame)),
                      "The pane control covers the search: \(control.frame) over \(search.frame)")
        hold()
        XCTAssertFalse(control.frame.intersects(search.frame),
                       "The pane control slid over the search once it settled: \(control.frame) over \(search.frame)")
        attachScreenCapture("sessions-search-clear")

        let list = app.collectionViews.firstMatch
        list.swipeUp()
        hold()
        XCTAssertTrue(clear(), "After a scroll: \(control.frame) over \(search.frame)")
        list.swipeDown()
        list.swipeDown()
        hold()
        XCTAssertTrue(search.isHittable, "The search is back")
        XCTAssertFalse(control.frame.intersects(search.frame), "With the search back: \(control.frame) over \(search.frame)")
        attachScreenCapture("sessions-search-after-scroll")
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
