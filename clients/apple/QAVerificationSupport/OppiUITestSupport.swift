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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Polls `condition` until it holds or `timeout` passes, for a claim XCTest
    /// cannot ask as one element's existence: a value, an order, or two elements
    /// together. Prefer `waitUntilExists` and `waitUntilGone` when the claim is
    /// one element's presence.
    ///
    /// 5 s is the budget most of the suite's classes used. A sheet-heavy class
    /// (`RouterSettingsModalsUITests`, `ModelProvidersUITests`,
    /// `ServerSkillsUITests`) passes 10 s itself: a loaded pool simulator can take
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
/// Not for a claim that something stays after an action that could remove it ("a
/// swipe must not dismiss the dialog"): read at once, it can pass before the
/// dismissal starts. Such a claim keeps XCTest's wait, or a wait that holds for a
/// set time.
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
