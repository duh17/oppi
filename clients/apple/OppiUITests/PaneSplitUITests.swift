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
        app.buttons["pane.menu.zoom"].tap()
        XCTAssertTrue(waitFor(composer.isHittable), "The zoomed grip's Restore brought the chat back")

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
        app.buttons["pane.menu.zoom"].tap()
        XCTAssertTrue(waitFor(composer.isHittable), "The zoomed grip's Restore brought both panes back")

        let chatLeadingEdge = app.collectionViews["chat.timeline"].coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        launcherGrip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: chatLeadingEdge, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitFor(composer.frame.minX > launcher.frame.maxX - 1),
                      "The held grip moved the pane to the chat's leading edge: the chat is now on the right")
        attachScreenCapture("touch-moved")
    }

    /// The way out of a zoom by touch: the zoomed pane's grip stays, a
    /// longer accent pill, and one tap opens the pane menu with Restore, and
    /// Close Pane still in it. Restore gives both panes back, in landscape
    /// and after a rotation to portrait while zoomed.
    func testAZoomedPaneLeavesByItsGripMenu() throws {
        try openChatInLandscape()
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.buttons["pane.launcher.files"].waitUntilExists(timeout: 5), "⌘D opened the launcher")
        app.buttons["pane.launcher.files"].tap()
        let files = app.descendants(matching: .any)["fileBrowser.row.Route.md"]
        XCTAssertTrue(files.waitUntilExists(timeout: 10), "Files fills the pane")
        let composer = app.descendants(matching: .any)["chat.input"]
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        let filesGrip = grips.matching(NSPredicate(format: "label ENDSWITH '2 of 2'")).firstMatch
        let zoomed = grips.matching(NSPredicate(format: "value == 'Zoomed'")).firstMatch
        let menuZoom = app.buttons["pane.menu.zoom"]

        func zoomAndRestore(_ phase: String, rotateWhileZoomed: Bool) {
            filesGrip.tap()
            XCTAssertTrue(menuZoom.waitUntilExists(timeout: 5), "The grip opens the pane menu")
            menuZoom.tap()
            XCTAssertTrue(waitFor(!composer.isHittable), "Zoom filled the window with Files")
            if rotateWhileZoomed { XCUIDevice.shared.orientation = .portrait }
            XCTAssertTrue(zoomed.waitUntilExists(timeout: 5) && zoomed.isHittable, "The zoomed pane keeps its grip")
            hold()
            attachScreenCapture("\(phase)-zoomed")
            zoomed.tap()
            XCTAssertTrue(menuZoom.waitUntilExists(timeout: 5), "One tap on the zoomed grip opens the pane menu")
            XCTAssertEqual(menuZoom.label, "Restore")
            XCTAssertTrue(app.buttons["pane.menu.close"].exists, "Close Pane is in reach while zoomed")
            hold()
            attachScreenCapture("\(phase)-zoomed-menu")
            menuZoom.tap()
            XCTAssertTrue(waitFor(composer.isHittable && files.isHittable), "Restore gave both panes back")
            XCTAssertFalse(zoomed.exists, "No pane is zoomed")
            hold()
            attachScreenCapture("\(phase)-restored")
        }
        zoomAndRestore("landscape", rotateWhileZoomed: false)
        zoomAndRestore("rotated", rotateWhileZoomed: true)
    }

    /// Navigation in the main pane while another pane fills the window: a
    /// workspace tapped in the sidebar opens in the main pane, which comes
    /// back from behind the zoomed Terminal instead of changing unseen.
    func testNavigatingTheMainPaneBehindAZoomBringsItBack() throws {
        try openChatInLandscape()
        let toggleSidebar = app.buttons["workspace.split.sidebarToggle"]
        if toggleSidebar.waitUntilExists(timeout: 5), toggleSidebar.label.localizedCaseInsensitiveContains("show") {
            toggleSidebar.tap()
        }
        let workspace = app.buttons["workspace.open.routes-workspace"]
        XCTAssertTrue(workspace.waitUntilExists(timeout: 5), "The sidebar lists the workspace")
        app.typeKey("d", modifierFlags: .command)
        let terminal = app.buttons["pane.launcher.terminal"]
        XCTAssertTrue(terminal.waitUntilExists(timeout: 5), "⌘D opened the launcher")
        terminal.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sshTerminal.setup.list"].waitUntilExists(timeout: 10),
                      "The terminal opened in the pane")
        let composer = app.descendants(matching: .any)["chat.input"]
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        grips.matching(NSPredicate(format: "label ENDSWITH '2 of 2'")).firstMatch.tap()
        app.buttons["pane.menu.zoom"].tap()
        XCTAssertTrue(waitFor(!composer.isHittable), "The terminal fills the panes")
        let zoomed = grips.matching(NSPredicate(format: "value == 'Zoomed'")).firstMatch
        XCTAssertTrue(zoomed.waitUntilExists(timeout: 5))
        hold()
        attachScreenCapture("terminal-zoomed")

        XCTAssertTrue(workspace.isHittable, "The sidebar is still beside the panes")
        workspace.tap()
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(waitFor(row.exists && row.isHittable), "The main pane came back with the workspace's sessions")
        XCTAssertFalse(zoomed.exists, "The terminal's zoom ended")
        hold()
        attachScreenCapture("main-pane-revealed")
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

    /// The chat over a PDF on the iPad mini, its divider dragged all the way
    /// up: the chat folds into a strip whose mark sits below the status bar,
    /// out of the system's pull-down, and a drag down from that mark (or a
    /// tap) brings the chat back. An ordinary drag still resizes.
    func testAChatDraggedToTheTopFoldsBelowTheStatusBarAndPullsBackInPortrait() throws {
        try chatDraggedToTheTopFoldsBelowTheStatusBar(.portrait, name: "portrait")
    }

    func testAChatDraggedToTheTopFoldsBelowTheStatusBarAndPullsBackInLandscape() throws {
        try chatDraggedToTheTopFoldsBelowTheStatusBar(.landscapeLeft, name: "landscape")
    }

    private func chatDraggedToTheTopFoldsBelowTheStatusBar(_ orientation: UIDeviceOrientation, name: String) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("A pane below another is regular width only on the iPad mini")
        }
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: ["PANE_RESTORE_SEED": "chat-over-pdf"], colorScheme: "dark", ready: nil)
        let window = app.windows.firstMatch
        let timeline = app.collectionViews["chat.timeline"]
        let pdf = app.descendants(matching: .any)["pane.leaf.leaf-pdf"]
        XCTAssertTrue(timeline.waitUntilExists(timeout: 10), "The chat is in the upper pane")
        XCTAssertTrue(pdf.waitUntilExists(timeout: 10), "The PDF is in the pane below")
        let divider = app.descendants(matching: .any)["pane.divider.1"]
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "A divider sits between the panes")
        hold()
        attachScreenCapture("\(name)-1-split")

        // An ordinary drag resizes: the chat grows, and nothing folds. The
        // synthesized drag loses the pan's start slop, so it gives less than 80 pt.
        let chatHeight = timeline.frame.height
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 80)))
        XCTAssertTrue(waitFor(timeline.frame.height > chatHeight + 30), "The drag gave the chat room (\(timeline.frame.height) from \(chatHeight))")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.strip.'")).firstMatch.exists)
        hold()
        attachScreenCapture("\(name)-2-dragged")

        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)))
        let strip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.strip.'")).firstMatch
        XCTAssertTrue(strip.waitUntilExists(timeout: 5), "Dragged past the chat's minimum, the release folded it")
        // The strip's 20 pt sit under the status bar's inset, never in it.
        XCTAssertEqual(strip.frame.minY, window.frame.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(strip.frame.height, 40, "The strip carries the status bar's inset above its mark")
        XCTAssertGreaterThan(pdf.frame.minY, strip.frame.maxY - 1, "The PDF starts under the strip")
        hold()
        attachScreenCapture("\(name)-3-folded-to-top")

        // Pull the strip down from its mark, the way it was pushed up.
        let mark = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (strip.frame.height - 10) / strip.frame.height))
        mark.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        XCTAssertTrue(strip.waitUntilGone(timeout: 5), "The drag brought the chat back")
        XCTAssertTrue(waitFor(timeline.exists && timeline.frame.height > 200), "at a pane's height")
        hold()
        attachScreenCapture("\(name)-4-pulled-back")

        // A tap on the strip does the same.
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)))
        XCTAssertTrue(strip.waitUntilExists(timeout: 5), "Folded again")
        mark.tap()
        XCTAssertTrue(strip.waitUntilGone(timeout: 5), "A tap on the strip brought the chat back")
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

    /// The routed pane's grip follows its stack: after Sessions pushes the
    /// chat, the grip sits directly under the chat's bar, not where the
    /// Sessions search put it, over the transcript.
    func testTheGripFollowsAPushedScreen() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Grips show on a wide window; the iPad mini is the wide simulator")
        }
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "pane-restore", environment: ["PANE_RESTORE_SEED": "splits"], ready: nil)
        let grip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.' AND label ENDSWITH '1 of 3'")).firstMatch
        XCTAssertTrue(grip.waitUntilExists(timeout: 10), "The Sessions pane shows its grip")
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].waitUntilExists(timeout: 10), "The chat opened")
        hold()
        let bar = app.navigationBars.containing(.button, identifier: "chat.toolbar.more").firstMatch
        XCTAssertTrue(bar.exists, "The chat shows its bar")
        attachScreenCapture("grip-after-push")
        XCTAssertEqual(grip.frame.minY, bar.frame.maxY, accuracy: 3,
                       "The grip sits under the chat's bar: grip \(grip.frame), bar \(bar.frame)")
    }

    /// A file tapped in a split Files pane opens in a pane beside it; the
    /// chat keeps the main pane.
    func testAFileTappedInASplitFilesPaneOpensBesideIt() throws {
        try openChat(in: .landscapeLeft, colorScheme: "dark")
        app.typeKey("d", modifierFlags: .command)
        let files = app.buttons["pane.launcher.files"]
        XCTAssertTrue(files.waitUntilExists(timeout: 5), "⌘D opened the launcher")
        files.tap()
        let row = app.descendants(matching: .any)["fileBrowser.row.Route.md"]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "Files listed the workspace")
        hold()
        attachScreenCapture("file-pane-before-tap")

        row.tap()
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        XCTAssertTrue(waitFor(grips.count == 3), "The file opened in a third pane, saw \(grips.count) grips")
        XCTAssertTrue(row.exists, "The Files pane still lists the folder")
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].isHittable, "The chat keeps the main pane")
        hold()
        attachScreenCapture("file-pane-after-tap")
    }

    /// A home folder in a pane below the sessions, the window a pinned folder
    /// opened beside them leaves: full width in portrait and in landscape, so
    /// regular width. A tapped file opens on that pane's own stack and fills
    /// it, not as a sheet over both panes. The grip's Zoom fills the window
    /// with it, Restore puts it back, and the pane's Back returns to the folder.
    func testAFileTappedInAWidePaneBelowOpensInThatPaneInPortrait() throws {
        try fileTappedInAWidePaneBelowOpensInThatPane(.portrait, name: "portrait")
    }

    func testAFileTappedInAWidePaneBelowOpensInThatPaneInLandscape() throws {
        try fileTappedInAWidePaneBelowOpensInThatPane(.landscapeLeft, name: "landscape")
    }

    private func fileTappedInAWidePaneBelowOpensInThatPane(_ orientation: UIDeviceOrientation, name: String) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("A pane below another is regular width only on the iPad mini")
        }
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: ["PANE_RESTORE_SEED": "files-below"], colorScheme: "dark", ready: nil)
        let window = app.windows.firstMatch
        let pane = app.descendants(matching: .any)["pane.leaf.leaf-notebook"]
        let row = pane.descendants(matching: .any)["fileBrowser.row.~/notebook/garden.org"]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The pane below lists the notebook")
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        let filesGrip = app.buttons["pane.grip.leaf-notebook"]
        XCTAssertTrue(filesGrip.waitUntilExists(timeout: 5), "The notebook pane has its grip")
        let paneFrame = pane.frame
        XCTAssertGreaterThan(paneFrame.minY, window.frame.height * 0.3, "The notebook pane sits below the sessions")
        hold()
        attachScreenCapture("\(name)-pane-below-before-tap")

        row.tap()
        let body = app.descendants(matching: .any)["full-screen.org-mode.body"].firstMatch
        XCTAssertTrue(body.waitUntilExists(timeout: 10), "The Org file opened")
        XCTAssertTrue(waitFor(abs(body.frame.width - paneFrame.width) < 4 && body.frame.minY > paneFrame.minY),
                      "The file fills the pane below, not a sheet over both: file \(body.frame), pane \(paneFrame)")
        XCTAssertFalse(app.buttons["fileBrowser.reader.close"].exists, "No sheet's Close: the file is a page of the pane")
        XCTAssertEqual(grips.count, 2, "The file opened in its own pane, not a new one")
        hold()
        attachScreenCapture("\(name)-pane-below-file-open")

        filesGrip.tap()
        let menuZoom = app.buttons["pane.menu.zoom"]
        XCTAssertTrue(menuZoom.waitUntilExists(timeout: 5), "The grip opens the pane menu")
        menuZoom.tap()
        XCTAssertTrue(waitFor(body.frame.minY < paneFrame.minY - 100 && body.frame.height > paneFrame.height + 100),
                      "Zoom fills the window with the file (\(body.frame))")
        hold()
        attachScreenCapture("\(name)-pane-below-file-zoomed")

        let zoomed = grips.matching(NSPredicate(format: "value == 'Zoomed'")).firstMatch
        XCTAssertTrue(zoomed.waitUntilExists(timeout: 5), "The zoomed pane keeps its grip")
        zoomed.tap()
        XCTAssertTrue(menuZoom.waitUntilExists(timeout: 5), "The zoomed grip opens the pane menu")
        menuZoom.tap()
        XCTAssertTrue(waitFor(body.frame.minY > paneFrame.minY), "Restore puts the file back in its pane")
        pane.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(waitFor(row.isHittable && !body.exists), "Back returns the pane to the folder")
    }

    /// A workspace's Git in a pane below the sessions (a pinned Git opened
    /// from a portrait iPad): full width, so regular width. A changed file's
    /// review, a commit, and a commit's file diff each push onto that pane's
    /// own stack and fill it, and each Back returns one step, to the Git list
    /// last. Nothing opens as a sheet or a column beside.
    func testGitPaneRowsPushOnThatPaneAndBackReturnsInPortrait() throws {
        try gitPaneRowsPushOnThatPane(.portrait, name: "portrait")
    }

    func testGitPaneRowsPushOnThatPaneAndBackReturnsInLandscape() throws {
        try gitPaneRowsPushOnThatPane(.landscapeLeft, name: "landscape")
    }

    private func gitPaneRowsPushOnThatPane(_ orientation: UIDeviceOrientation, name: String) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("A pane below another is regular width only on the iPad mini")
        }
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: ["PANE_RESTORE_SEED": "git-below"], colorScheme: "dark", ready: nil)
        let pane = app.descendants(matching: .any)["pane.leaf.leaf-git"]
        let gitBar = pane.navigationBars["Git"]
        XCTAssertTrue(gitBar.waitUntilExists(timeout: 10), "The pane below shows the workspace's Git")
        let fileRow = pane.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "App.swift", "+2")).firstMatch
        XCTAssertTrue(fileRow.waitUntilExists(timeout: 10), "The Git pane lists the changed file")
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        // The Git list's bar: a page pushed onto the pane's stack has its bar there.
        let paneFrame = gitBar.frame
        hold()
        attachScreenCapture("\(name)-git-pane")

        // A changed file: its review fills the pane, with the stack's Back.
        fileRow.tap()
        let review = pane.navigationBars["App.swift"]
        XCTAssertTrue(review.waitUntilExists(timeout: 10), "The file's review opened in the Git pane")
        assertFillsPane(review, paneFrame, "review")
        XCTAssertEqual(grips.count, 2, "The review opened in its own pane, not a new one")
        hold()
        attachScreenCapture("\(name)-git-pane-diff")
        review.buttons["BackButton"].tap()
        XCTAssertTrue(waitFor(gitBar.exists && !review.exists && fileRow.isHittable), "Back returns the pane to the Git list")
        attachScreenCapture("\(name)-git-pane-diff-back")

        // A commit, then one of its files: two pushes, two Backs.
        let commitRow = pane.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Route commit")).firstMatch
        XCTAssertTrue(commitRow.waitUntilExists(timeout: 5), "The Git pane lists the commit")
        commitRow.tap()
        let commit = pane.navigationBars["Commit"]
        XCTAssertTrue(commit.waitUntilExists(timeout: 10), "The commit opened in the Git pane")
        assertFillsPane(commit, paneFrame, "commit")
        hold()
        attachScreenCapture("\(name)-git-pane-commit")
        let commitFile = pane.buttons["commit-detail.file"].firstMatch
        XCTAssertTrue(commitFile.waitUntilExists(timeout: 10), "The commit lists its file")
        commitFile.tap()
        let diff = pane.navigationBars["App.swift"]
        XCTAssertTrue(diff.waitUntilExists(timeout: 10), "The commit's file diff opened in the Git pane")
        assertFillsPane(diff, paneFrame, "commit diff")
        XCTAssertFalse(app.buttons["commit-detail.diff.close"].exists, "A pushed diff has Back, not its own Close")
        hold()
        attachScreenCapture("\(name)-git-pane-commit-diff")
        diff.buttons["BackButton"].tap()
        XCTAssertTrue(waitFor(commit.exists && !diff.exists), "Back returns to the commit")
        commit.buttons["BackButton"].tap()
        XCTAssertTrue(waitFor(gitBar.exists && !commit.exists && fileRow.isHittable), "Back again returns to the Git list")
        attachScreenCapture("\(name)-git-pane-commit-back")
    }

    /// A chat in the lower pane with its Git panel covering it (no room
    /// beside on the iPad mini in portrait): the pane's grip sits under the
    /// panel's bar, clear of its branch row, and of a review's header after a
    /// file pushes. The review keeps the stack's Back beside its Files button
    /// and returns to the Git list.
    func testAChatsGitPanelBelowKeepsBackAndClearsTheGrip() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("A pane below another is regular width only on the iPad mini")
        }
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "pane-restore", environment: ["PANE_RESTORE_SEED": "sessions-below"], colorScheme: "dark", ready: nil)
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed in the lower pane")
        row.tap()
        let git = app.buttons["chat.toolbar.git"]
        XCTAssertTrue(git.waitUntilExists(timeout: 10), "The chat opened")
        git.tap()
        let gitBar = app.navigationBars["Git"]
        XCTAssertTrue(gitBar.waitUntilExists(timeout: 10), "The chat's Git panel opened")
        let scope = app.segmentedControls["workspace-context-bar.scope"]
        XCTAssertTrue(scope.waitUntilExists(timeout: 5), "The panel offers This session / All changes")
        scope.buttons["All changes (2)"].tap()
        let grip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.' AND label ENDSWITH '2 of 2'")).firstMatch
        XCTAssertTrue(grip.waitUntilExists(timeout: 5), "The lower pane has its grip")
        let branch = app.staticTexts["main"].firstMatch
        XCTAssertTrue(branch.waitUntilExists(timeout: 5), "The panel shows its branch")
        hold()
        attachScreenCapture("chat-git-below")
        XCTAssertGreaterThanOrEqual(grip.frame.minY, gitBar.frame.maxY - 1, "The grip sits under the panel's bar: grip \(grip.frame), bar \(gitBar.frame)")
        XCTAssertFalse(grip.frame.intersects(branch.frame), "The grip covers the branch: grip \(grip.frame), branch \(branch.frame)")

        let fileRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "App.swift", "+2")).firstMatch
        fileRow.tap()
        let review = app.navigationBars["App.swift"]
        XCTAssertTrue(review.waitUntilExists(timeout: 10), "The file's review opened")
        XCTAssertTrue(review.buttons["review-file.list.show"].waitUntilExists(timeout: 5), "Two changed files offer the file list")
        XCTAssertTrue(review.buttons["BackButton"].exists, "The file list button sits beside Back, not in its place")
        hold()
        attachScreenCapture("chat-git-below-review")
        let header = app.staticTexts.matching(NSPredicate(format: "label == %@", "App.swift")).allElementsBoundByIndex
            .first { $0.frame.minY >= review.frame.maxY }
        let headerFrame = try XCTUnwrap(header?.frame, "The review shows its file header under the bar")
        XCTAssertFalse(grip.frame.intersects(headerFrame), "The grip covers the review's header: grip \(grip.frame), header \(headerFrame)")
        review.buttons["BackButton"].tap()
        XCTAssertTrue(waitFor(gitBar.exists && !review.exists), "Back returns to the Git list")
    }

    /// `bar` is the top of the pane's stack: where the Git list's bar was.
    private func assertFillsPane(_ bar: XCUIElement, _ listBar: CGRect, _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitFor(abs(bar.frame.width - listBar.width) < 4 && abs(bar.frame.minY - listBar.minY) < 4),
                      "The \(what) fills the Git pane: bar \(bar.frame), Git list's bar \(listBar)", file: file, line: line)
        XCTAssertTrue(bar.buttons["BackButton"].exists, "The \(what) has the stack's Back", file: file, line: line)
    }

    /// iPad mini portrait: the sidebar is a drawer that covers the panes, so
    /// ⌘D with it open closes it and splits the focused pane in sight.
    func testSplitWithTheDrawerOpenClosesItAndSplitsInSight() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The drawer covers splittable panes on the iPad mini in portrait")
        }
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "pane-restore", environment: [:], colorScheme: "dark", ready: nil)
        let open = app.buttons["workspace.sidebar.open"]
        XCTAssertTrue(open.waitUntilExists(timeout: 10), "Portrait shows the drawer's button")
        open.tap()
        let sidebar = app.descendants(matching: .any)["workspace.sidebar.scroll"]
        XCTAssertTrue(waitFor(sidebar.exists && sidebar.isHittable), "The drawer opened")
        hold()
        attachScreenCapture("drawer-open-before-split")

        app.typeKey("d", modifierFlags: .command)
        let launcher = app.descendants(matching: .any)["pane.launcher"]
        XCTAssertTrue(launcher.waitUntilExists(timeout: 5), "⌘D split the pane")
        XCTAssertTrue(waitFor(launcher.isHittable), "The new pane is in sight, not behind the drawer")
        XCTAssertTrue(waitFor(!sidebar.exists || !sidebar.isHittable), "⌘D closed the drawer")
        hold()
        attachScreenCapture("drawer-closed-after-split")
    }

    /// Landscape on the iPad mini with the sidebar shown: the sidebar floats
    /// over the split view's detail column, so the panes sit beside it. The
    /// leading pane's grip and search are never under the sidebar, and the
    /// search takes a tap.
    func testPanesSitBesideTheSidebarInLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The sidebar sits beside the panes on the iPad mini in landscape")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: ["PANE_RESTORE_SEED": "splits"], ready: nil)
        let sidebar = app.descendants(matching: .any)["workspace.sidebar.scroll"]
        XCTAssertTrue(sidebar.waitUntilExists(timeout: 10), "Landscape shows the sidebar")
        let grip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.' AND label ENDSWITH '1 of 3'")).firstMatch
        XCTAssertTrue(grip.waitUntilExists(timeout: 10), "The leading pane shows its grip")
        let search = app.searchFields["Search sessions"]
        XCTAssertTrue(search.waitUntilExists(timeout: 10), "The leading pane is the Sessions screen")
        hold()
        attachScreenCapture("sidebar-beside-panes")
        XCTAssertGreaterThanOrEqual(grip.frame.minX, sidebar.frame.maxX,
                                    "The grip is under the sidebar: \(grip.frame), sidebar \(sidebar.frame)")
        XCTAssertGreaterThanOrEqual(search.frame.minX, sidebar.frame.maxX,
                                    "The search is under the sidebar: \(search.frame), sidebar \(sidebar.frame)")
        search.tap()
        XCTAssertTrue(waitFor((search.value(forKey: "hasKeyboardFocus") as? Bool) == true), "The search takes a tap")
    }

    /// H1: the pane chords from a hardware keyboard. ⌥⌘ arrows and ⌃⌘
    /// digits move focus, ⌃⌘ arrows move the divider on the focused pane's
    /// edge, and ⌥⇧⌘ arrows move the pane. ⇧⌘↩ (Zoom Pane) is left out: a
    /// typed ⇧⌘↩ does not reach the app's menu command in the simulator, with
    /// or without priority over system behaviour; the grip zooms meanwhile.
    func testThePaneChordsFocusMoveResizeAndZoom() throws {
        try openChatInLandscape()
        app.typeKey("d", modifierFlags: .command)
        let launcher = app.descendants(matching: .any)["pane.launcher"]
        XCTAssertTrue(launcher.waitUntilExists(timeout: 5), "⌘D opened the launcher beside the chat")
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        let chatGrip = grips.matching(NSPredicate(format: "label ENDSWITH '1 of 2'")).firstMatch
        let launcherGrip = grips.matching(NSPredicate(format: "label ENDSWITH '2 of 2'")).firstMatch
        let focused = { (grip: XCUIElement) in (grip.value as? String) == "Focused" }

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.option, .command])
        XCTAssertTrue(waitFor(focused(launcherGrip)), "⌥⌘→ focused the pane on the right")
        app.typeKey("1", modifierFlags: [.control, .command])
        XCTAssertTrue(waitFor(focused(chatGrip)), "⌃⌘1 focused the first pane")

        let before = launcher.frame.minX
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.control, .command])
        XCTAssertTrue(waitFor(abs(launcher.frame.minX - (before + 32)) < 2),
                      "⌃⌘→ moved the chat's divider 32 pt: \(before) → \(launcher.frame.minX)")

        app.typeKey("2", modifierFlags: [.control, .command])
        XCTAssertTrue(waitFor(focused(launcherGrip)))
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.option, .shift, .command])
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(waitFor(composer.frame.minX > launcher.frame.maxX - 1), "⌥⇧⌘← moved the pane to the chat's left")
        attachScreenCapture("chords-moved")
    }

    /// §1.6 rule 5: on a wide window the chat bar's Terminal opens the folder
    /// terminal in a pane below the chat, focused, instead of over it: a
    /// shell wants the window's width (New Panes' Terminal default). With no
    /// saved SSH host its first step is Add Host.
    func testTheChatBarsTerminalOpensBelowTheChatInLandscape() throws {
        try openChat(in: .landscapeLeft, colorScheme: "dark")
        let (setup, composer) = openTerminalFromTheChatBar()
        XCTAssertGreaterThan(setup.frame.minY, composer.frame.maxY - 1, "The terminal is in a pane below the chat")
        attachScreenCapture("terminal-below-chat-landscape")
    }

    func testTheChatBarsTerminalOpensBelowTheChatInPortrait() throws {
        try openChat(in: .portrait, colorScheme: "dark")
        let (setup, composer) = openTerminalFromTheChatBar()
        XCTAssertGreaterThan(setup.frame.minY, composer.frame.maxY - 1, "The terminal is in a pane below the chat")
        attachScreenCapture("terminal-below-chat-portrait")
    }

    /// New Panes (Settings → Experiments, under Split Panes): Terminal reads
    /// Below until changed, and set to Right the chat bar's next terminal
    /// opens to the chat's right.
    func testNewPanesPutsTheChatBarsTerminalWhereItIsSet() throws {
        try openChat(in: .landscapeLeft, colorScheme: "dark")
        openExperiments()
        let list = app.collectionViews["settings.experiments.list"]
        let terminalSide = app.buttons["settings.experiments.newPanes.terminal"]
        for _ in 0..<6 where !(terminalSide.exists && terminalSide.isHittable) { list.swipeUp() }
        XCTAssertTrue(terminalSide.waitUntilExists(timeout: 5), "Experiments lists New Panes under Split Panes")
        XCTAssertEqual(terminalSide.value as? String, "Below")
        XCTAssertEqual(app.buttons["settings.experiments.newPanes.files"].value as? String, "Automatic")
        hold()
        attachScreenCapture("settings-new-panes")
        terminalSide.tap()
        let right = app.buttons["Right"]
        XCTAssertTrue(right.waitUntilExists(timeout: 5), "The row offers Automatic, Right and Below")
        right.tap()
        XCTAssertTrue(waitFor((terminalSide.value as? String) == "Right"), "Terminal now reads Right")

        app.buttons["workspace.open.routes-workspace"].tap()
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The workspace lists the session")
        row.tap()
        let (setup, composer) = openTerminalFromTheChatBar()
        XCTAssertGreaterThan(setup.frame.minX, composer.frame.maxX - 1, "The terminal is in a pane to the chat's right")
        attachScreenCapture("terminal-right-of-chat")
    }

    /// Taps the chat bar's Terminal and returns its first step (Add Host,
    /// with no saved host) and the chat's composer, once the terminal is a
    /// focused pane of its own beside the chat.
    private func openTerminalFromTheChatBar() -> (setup: XCUIElement, composer: XCUIElement) {
        app.buttons["chat.toolbar.more"].tap()
        let terminal = app.buttons["chat.toolbar.menu.terminal"]
        XCTAssertTrue(terminal.waitUntilExists(timeout: 5), "The … menu offers Terminal")
        terminal.tap()
        let setup = app.descendants(matching: .any)["sshTerminal.setup.list"]
        XCTAssertTrue(setup.waitUntilExists(timeout: 10), "The terminal's first step opened")
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(composer.isHittable, "The chat stays beside it")
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        XCTAssertEqual(grips.count, 2, "The terminal is a pane of its own")
        let terminalGrip = grips.matching(NSPredicate(format: "label ENDSWITH '2 of 2'")).firstMatch
        XCTAssertEqual(terminalGrip.value as? String, "Focused", "The new terminal pane has focus")
        hold()
        return (setup, composer)
    }

    /// §1.7: a closed pane comes back with Undo, from the toast that offers
    /// it, where it was and showing what it showed.
    func testUndoBringsAClosedPaneBack() throws {
        try openChatInLandscape()
        app.typeKey("d", modifierFlags: .command)
        let files = app.buttons["pane.launcher.files"]
        XCTAssertTrue(files.waitUntilExists(timeout: 5), "⌘D opened the launcher")
        files.tap()
        let row = app.descendants(matching: .any)["fileBrowser.row.Route.md"]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "Files fills the pane")
        let frame = row.frame
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        grips.matching(NSPredicate(format: "label ENDSWITH '2 of 2'")).firstMatch.tap()
        app.buttons["Close Pane"].tap()
        XCTAssertTrue(row.waitUntilGone(timeout: 5), "Close Pane closed Files")
        let undo = app.buttons["pane.undo"]
        XCTAssertTrue(undo.waitUntilExists(timeout: 5), "The toast offers Undo")
        XCTAssertEqual(undo.label, "Undo Close Pane")
        attachScreenCapture("undo-toast")
        undo.tap()
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "Undo brought Files back")
        XCTAssertEqual(row.frame.minX, frame.minX, accuracy: 2, "where it was")
        XCTAssertTrue(undo.waitUntilGone(timeout: 5), "The toast goes with the undo")
        attachScreenCapture("undo-restored")
    }

    /// The Split Panes experiment (Settings → Experiments) over a window
    /// with three panes: off, the panes and their grips leave and the window
    /// is the chat and its panel, with no Split in the chat's menu; on again,
    /// the panes come back where they were, without a relaunch.
    func testSplitPanesOffLeavesTheChatAndItsPanelAndOnBringsThePanesBack() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The switch is listed on a wide window; the iPad mini is the wide simulator")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: ["PANE_RESTORE_SEED": "splits"], ready: nil)
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        let filesPane = app.descendants(matching: .any)["fileBrowser.row.Route.md"]
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The Sessions pane lists the fixture session")
        row.tap()
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(composer.waitUntilExists(timeout: 10), "The chat opened")
        XCTAssertTrue(filesPane.waitUntilExists(timeout: 10), "The Files pane sits beside the chat")
        XCTAssertTrue(waitFor(grips.count == 3), "Each of the three panes has a grip")
        hold()
        attachScreenCapture("split-panes-on")

        setSplitPanes(false)
        XCTAssertTrue(waitFor(grips.count == 0), "No grips with the experiment off")
        XCTAssertTrue(filesPane.waitUntilGone(timeout: 5), "The Files pane left the window")
        // App Settings took the chat's place; the sidebar opens it again.
        app.buttons["workspace.open.routes-workspace"].tap()
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The workspace lists the session")
        row.tap()
        XCTAssertTrue(waitFor(composer.isHittable), "Back at the chat")
        let window = app.windows.firstMatch
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertEqual(timeline.frame.maxX, window.frame.maxX, accuracy: 2, "The chat has the window")
        app.buttons["chat.toolbar.git"].tap()
        XCTAssertTrue(app.navigationBars["Git"].waitUntilExists(timeout: 5), "The Git panel opened beside the chat")
        XCTAssertTrue(waitFor(composer.isHittable), "beside it, not over it")
        XCTAssertEqual(grips.count, 0)
        app.buttons["chat.toolbar.more"].tap()
        XCTAssertTrue(app.buttons["chat.toolbar.menu.customize"].waitUntilExists(timeout: 5), "The chat's menu opened")
        XCTAssertFalse(app.buttons["pane.menu.splitRight"].exists, "The chat's menu offers no Split Right")
        // A tap outside closes the menu (Escape does not reach it in the simulator).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6)).tap()
        XCTAssertTrue(app.buttons["chat.toolbar.menu.customize"].waitUntilGone(timeout: 5))
        hold()
        attachScreenCapture("split-panes-off")

        setSplitPanes(true)
        XCTAssertTrue(filesPane.waitUntilExists(timeout: 10), "The Files pane is back")
        // The sidebar is open (it led to Settings), so the fit rule keeps two
        // panes beside it and Git waits in Hidden Panes.
        XCTAssertTrue(waitFor(grips.count >= 2), "with the panes' grips")
    }

    /// Opens Settings → Experiments from the sidebar and sets the Split
    /// Panes switch.
    private func setSplitPanes(_ on: Bool) {
        openExperiments()
        let toggle = app.switches["settings.experiments.splitPanes"]
        XCTAssertTrue(toggle.waitUntilExists(timeout: 10), "Experiments lists Split Panes on the iPad")
        XCTAssertEqual(toggle.value as? String, on ? "0" : "1")
        hold()
        attachScreenCapture(on ? "settings-experiments-off" : "settings-experiments")
        toggle.tap()
        XCTAssertTrue(waitFor((toggle.value as? String) == (on ? "1" : "0")), "The switch turned \(on ? "on" : "off")")
    }

    /// Opens Settings → Experiments from the sidebar.
    private func openExperiments() {
        let toggleSidebar = app.buttons["workspace.split.sidebarToggle"]
        if toggleSidebar.waitUntilExists(timeout: 5), toggleSidebar.label.localizedCaseInsensitiveContains("show") {
            toggleSidebar.tap()
        }
        let appSettings = app.buttons["App Settings"]
        XCTAssertTrue(appSettings.waitUntilExists(timeout: 10), "The landscape sidebar offers App Settings")
        appSettings.tap()
        let list = app.collectionViews["settings.list"]
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "App Settings opened Settings")
        let experiments = app.descendants(matching: .any)["settings.row.experiments"]
        for _ in 0..<8 where !(experiments.exists && experiments.isHittable) { list.swipeUp() }
        XCTAssertTrue(experiments.waitUntilExists(timeout: 5), "Settings lists Experiments")
        experiments.tap()
    }

    private func openChatInLandscape() throws {
        try openChat(in: .landscapeLeft)
    }

    /// `colorScheme` pins the theme for a test whose captures are review proof.
    private func openChat(in orientation: UIDeviceOrientation, colorScheme: String? = nil) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Splits need a wide window; the iPad mini is the wide simulator")
        }
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: [:], colorScheme: colorScheme, ready: nil)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The shell came up")
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].waitUntilExists(timeout: 10), "The chat opened")
    }

    /// The screen's capture: in landscape `app.screenshot()` draws the iPad
    /// sideways into a portrait canvas.
    private func attachScreenCapture(_ name: String) {
        let attachment = XCTAttachment(uprightScreenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
