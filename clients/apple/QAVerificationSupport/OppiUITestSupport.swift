import XCTest

/// A UI test class that drives one screenshot preview: the helpers below leave
/// the launched app in `app` for the test's steps, so every preview launch
/// (`--screenshot-preview`) and its readiness wait has one owner
/// (`dev/testing/README.md`, "UI and E2E launch state").
@MainActor
protocol PreviewUITestCase: AnyObject {
    /// The launched app the test's steps drive.
    var app: XCUIApplication! { get set }

    /// `true` in a class whose tests keep one app launch across tests
    /// (`ReusedHarnessLaunch`): a test whose launch arguments and non-screen
    /// environment match the running launch gets it back after an in-process
    /// reset to its own screen (`SCREENSHOT_*`). Everything the launch contract
    /// resets, the reset clears; what it cannot (a system service, a process-wide
    /// singleton a preview does not rebuild) is why a class opts in only once its
    /// tests pass in any order.
    static var reusesLaunch: Bool { get }
}

extension PreviewUITestCase {
    static var reusesLaunch: Bool { false }
}

extension PreviewUITestCase where Self: XCTestCase {
    /// Launches the preview `screen` into `app`, replacing a launch that is still
    /// running. `environment` goes on top of the preview launch (the site, page,
    /// or focus knob the screen reads), `colorScheme` pins the theme a capture
    /// asks for, and `arguments` are extra launch arguments.
    ///
    /// Waits for `ready`, the preview host's marker
    /// (`PreviewHost.publishScreenshotReady`) by default; pass nil for a screen
    /// whose test waits for its own surface instead.
    ///
    /// In a class that `reusesLaunch`, the first launch of a test may be the
    /// class's running app, reset in process. A second launch in the same test is
    /// a real relaunch that keeps what the test wrote, as without reuse.
    func launchPreview(
        screen: String,
        environment: [String: String] = [:],
        colorScheme: String? = nil,
        arguments: [String] = [],
        ready: String? = "screenshot.ready",
        readyTimeout: TimeInterval = 10
    ) {
        let relaunch = app != nil
        let reuses = ReusedHarnessLaunch.isEnabled(optedIn: Self.reusesLaunch)
        let owner = String(describing: Self.self)
        let application = OppiTestLaunch.makeApp(
            resetToken: relaunch && reuses ? ReusedHarnessLaunch.appliedResetToken(owner: owner) : nil
        )
        application.launchArguments += ["--screenshot-preview"] + arguments
        application.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        if let colorScheme { application.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = colorScheme }
        for (key, value) in environment { application.launchEnvironment[key] = value }
        if reuses {
            app = ReusedHarnessLaunch.app(
                owner: owner,
                application: application,
                readyID: ready,
                freshProcess: relaunch
            ) {
                application.launch()
            }
        } else {
            app?.terminate()
            application.launch()
            app = application
        }
        XCTAssertEqual(
            app.wait(for: .runningForeground, timeout: readyTimeout), true,
            "Preview \(screen) did not come up"
        )
        guard let ready else { return }
        XCTAssertTrue(
            app.descendants(matching: .any)[ready].waitUntilExists(timeout: readyTimeout),
            "Preview \(screen) did not publish \(ready)"
        )
        app.requireNonCompactWindowOnPad()
    }

    /// Launches the settings sweep (`SCREENSHOT_SCREEN=settings-sweep`) on `page`
    /// over its fixture server. `showsWrites` puts the last write the fixture
    /// server received in `settingsSweep.lastWrite` (`lastWrite`), which a test
    /// that asserts a write reads; `writeDelay` holds each write's answer that
    /// long. The page publishes both markers once its host is up, so a test
    /// starts from the harness and not from a spinner.
    func launchSettingsSweep(page: String, showsWrites: Bool = false, writeDelay: Int = 0) {
        var environment = ["SCREENSHOT_SWEEP_PAGE": page]
        if showsWrites { environment["SCREENSHOT_SWEEP_SHOWS_WRITES"] = "1" }
        if writeDelay > 0 { environment["SCREENSHOT_SWEEP_WRITE_DELAY"] = String(writeDelay) }
        launchPreview(screen: "settings-sweep", environment: environment, colorScheme: "dark")
        guard showsWrites else { return }
        XCTAssertTrue(lastWriteElement.waitUntilExists(timeout: 10), "The sweep's write record did not appear")
    }

    /// The sweep's record of the last write its fixture server received.
    private var lastWriteElement: XCUIElement { app.staticTexts["settingsSweep.lastWrite"] }

    /// What that record says: an edit the test made reaches the server here.
    var lastWrite: String { lastWriteElement.label }

    /// The app survived the step: a page that lost a service it was presented
    /// over crashes on its first read, and a test that only reads the screen
    /// would report the missing control instead.
    func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "The app must still be running", file: file, line: line)
    }

    /// Keeps a screenshot of the app's current state in the result bundle.
    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(uprightScreenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The open thinking list runs from Max at the top to Off at the bottom, in
    /// the chat and Quick Session alike, as a pop-up menu (regular width) or a
    /// popover (compact width). `levels` are the ones the fixture model offers
    /// (a model that advertises none offers every level).
    func assertThinkingOptionsRunMaxToLow(
        _ levels: [String] = ["max", "xhigh", "high", "medium", "low", "minimal", "off"],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let options = levels.map { app.buttons["session.toolbar.thinking.option.\($0)"] }
        for (option, level) in zip(options, levels) {
            XCTAssertTrue(option.waitUntilExists(timeout: 5), "Thinking option \(level) did not appear", file: file, line: line)
        }
        for (upper, lower) in zip(options, options.dropFirst()) {
            XCTAssertLessThan(
                upper.frame.midY,
                lower.frame.midY,
                "The thinking list must run from the strongest level at the top down",
                file: file,
                line: line
            )
        }
    }

    /// Polls `condition` until it holds or `timeout` passes, for a claim XCTest
    /// cannot ask as one element's existence: a value, an order, or two elements
    /// together. Prefer `waitUntilExists` and `waitUntilGone` when the claim is
    /// one element's presence.
    ///
    /// 5 s is the budget most of the suite's classes used. A sheet-heavy class
    /// (`RouterSettingsModalsUITests`, `ModelProvidersUITests`) passes 10 s itself: a loaded pool simulator can take
    /// several seconds to finish a dismissal.
    func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}

/// Element waits without XCTest's one-second first check. `waitForExistence` and
/// `waitForNonExistence` first evaluate their condition about a second after they
/// start, even when it already holds: on a pool simulator an `exists` read took
/// 6 ms and a `waitForExistence` that held at once 1.07 s, and 98% of this suite's
/// waits hold at their first check. These read `exists` once and fall back to
/// XCTest's wait, with the same timeout, only when it does not hold yet.
///
/// Not for a claim that something stays, or happens once, after an action that
/// could still change it ("a swipe must not dismiss the dialog", "onDismiss runs
/// once"): read at once, it can pass before the change starts. `hold(for:)` first.
extension XCUIElement {
    /// `waitForExistence(timeout:)`, answered at once when the element already exists.
    func waitUntilExists(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }

    /// `waitForNonExistence(timeout:)`, answered at once when the element is already gone.
    func waitUntilGone(timeout: TimeInterval) -> Bool {
        !exists || waitForNonExistence(timeout: timeout)
    }
}

extension XCTestCase {
    /// Lets `seconds` pass with the run loop running, before a claim that
    /// something stays, or happened only once, after an action that could still
    /// change it: a delayed second dismissal, a late callback, a row that moves
    /// after its first layout. The claim then reads what is on screen after that
    /// time, not the instant its own wait returned. One second is the margin these
    /// claims had while XCTest's waits made their first check a second late.
    func hold(for seconds: TimeInterval = 1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

/// Queries shared by UI and E2E tests: controls found by their identifier, with
/// the label read only where the label is the state under test
/// (`dev/testing/ios-accessibility-testability.md`, "Identifier naming").
extension XCUIApplication {
    /// The system's … in the front screen's bar (`additionalOverflowItems`): a
    /// file reader's menu of turned-off buttons, Edit with Session, and
    /// Customize Bar…. UIKit sets no identifier on it, so it is found by the
    /// label iOS gives it; with several bars on screen the last is the
    /// frontmost.
    var barOverflowButton: XCUIElement {
        let all = buttons.matching(NSPredicate(format: "label IN %@", ["More", "Actions"]))
        return all.element(boundBy: max(all.count - 1, 0))
    }

    /// Fails the run when an iPad shows the app in a compact window. The iPad lane exists to prove
    /// regular-width layout, and a simulator slot can remember a small floating window from an
    /// earlier run: the tests that need regular width then skip, and the ones that branch on the
    /// size class take the phone path and pass without checking the iPad layout. `sim-pool.sh`
    /// forgets that window before it boots an iPad slot, so this firing means the run bypassed the
    /// pool or the window shrank during the run. The iPhone's window is compact by design.
    func requireNonCompactWindowOnPad(file: StaticString = #filePath, line: UInt = #line) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        // The app's window is the largest one: on the video viewer screen
        // `firstMatch` resolved to a 0 x 0 window, not the app's. One snapshot
        // reads every window at once: an element bound by index looks itself up
        // again on each read, so a window that goes in between (a transient one
        // the previous test's state left, torn down after a reused launch's
        // reset) failed the launch with "No matches found for Element at index N".
        let all: [XCUIElementSnapshot]
        do {
            all = try snapshot().children.filter { $0.elementType == .window }
        } catch {
            XCTFail("Could not read the app's windows: \(error)", file: file, line: line)
            return
        }
        guard let window = all.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            XCTFail("The app shows no window", file: file, line: line)
            return
        }
        XCTAssertNotEqual(
            window.horizontalSizeClass, .compact,
            "The iPad run opened the app in a compact window (\(window.frame.size) of \(all.map(\.frame))); its width-gated tests would skip or take the phone path. " +
                "Run through sim-pool.sh, which resets the slot's remembered window before booting it",
            file: file,
            line: line
        )
    }

    /// Drags the app's window by its bottom-trailing corner until that corner
    /// is at `corner`, in screen points. An iPad app cannot resize its own
    /// window (`requestGeometryUpdate` takes orientations only), but in
    /// windowed-apps mode the person, or this drag, can. SpringBoard remembers
    /// the size for later launches, so a test that shrinks the window drags it
    /// back to full size before it ends.
    func dragWindowCorner(to corner: CGPoint) {
        let window = windows.firstMatch.frame
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard").coordinate(withNormalizedOffset: .zero)
        let start = screen.withOffset(CGVector(dx: window.maxX - 4, dy: window.maxY - 4))
        let end = screen.withOffset(CGVector(dx: corner.x - 4, dy: corner.y - 4))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.3)
    }

    /// The server switcher whose label names `name` (`Current server: <name>`).
    /// Every switcher shares `server.switcher`; the label says which server is current.
    func serverSwitcher(named name: String) -> XCUIElement {
        buttons.matching(identifier: "server.switcher")
            .matching(NSPredicate(format: "label == %@", "Current server: \(name)"))
            .firstMatch
    }

    /// Closes a regular-width popover the way a person does: a tap on the window
    /// outside `content`. A popover has no grabber, so a swipe-down does not close
    /// it (compact width presents the same content as a sheet, which does). `content`
    /// is the element the caller can name, which may be only part of the popover (a
    /// navigation bar, not its whole body), so the tap goes to the window corner
    /// farthest from that element: the corner least likely to land on the rest of
    /// the popover or on the control that opened it. A software keyboard that is up
    /// sits in its own window above the popover's dismiss region and takes a tap
    /// on it, so corners under the keyboard are never chosen. The caller still
    /// asserts that the content went away.
    func tapOutsidePopover(_ content: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            otherElements["PopoverDismissRegion"].exists,
            "Only a popover closes with a tap outside it",
            file: file,
            line: line
        )
        let window = windows.firstMatch
        let bounds = window.frame
        let frame = content.frame
        let keyboard = keyboards.firstMatch
        let keyboardFrame = keyboard.exists ? keyboard.frame : .null
        func point(at corner: CGVector) -> CGPoint {
            CGPoint(x: bounds.minX + bounds.width * corner.dx, y: bounds.minY + bounds.height * corner.dy)
        }
        func distance(from corner: CGVector) -> CGFloat {
            let point = point(at: corner)
            return hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        let corners = [
            CGVector(dx: 0.05, dy: 0.95), CGVector(dx: 0.95, dy: 0.95),
            CGVector(dx: 0.05, dy: 0.05), CGVector(dx: 0.95, dy: 0.05),
        ].filter { !keyboardFrame.contains(point(at: $0)) }
        guard let farthest = corners.max(by: { distance(from: $0) < distance(from: $1) }), distance(from: farthest) > 0 else {
            XCTFail(
                "No window corner lies outside the popover content (\(frame)) and the keyboard (\(keyboardFrame))",
                file: file,
                line: line
            )
            return
        }
        window.coordinate(withNormalizedOffset: farthest).tap()
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
