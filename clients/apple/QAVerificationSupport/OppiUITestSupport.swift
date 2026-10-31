import XCTest

/// A UI test class that drives one screenshot preview: the helpers below leave
/// the launched app in `app` for the test's steps, so every preview launch
/// (`--screenshot-preview`) and its readiness wait has one owner
/// (`dev/testing/README.md`, "UI and E2E launch state").
@MainActor
protocol PreviewUITestCase: AnyObject {
    /// The launched app the test's steps drive.
    var app: XCUIApplication! { get set }
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
    func launchPreview(
        screen: String,
        environment: [String: String] = [:],
        colorScheme: String? = nil,
        arguments: [String] = [],
        ready: String? = "screenshot.ready",
        readyTimeout: TimeInterval = 10
    ) {
        app?.terminate()
        let application = OppiTestLaunch.makeApp()
        application.launchArguments += ["--screenshot-preview"] + arguments
        application.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        if let colorScheme { application.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = colorScheme }
        for (key, value) in environment { application.launchEnvironment[key] = value }
        application.launch()
        app = application
        XCTAssertEqual(
            application.wait(for: .runningForeground, timeout: readyTimeout), true,
            "Preview \(screen) did not come up"
        )
        guard let ready else { return }
        XCTAssertTrue(
            application.descendants(matching: .any)[ready].waitForExistence(timeout: readyTimeout),
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
        XCTAssertTrue(lastWriteElement.waitForExistence(timeout: 10), "The sweep's write record did not appear")
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
    /// together. Prefer `waitForExistence` and `waitForNonExistence` when the
    /// claim is one element's presence.
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
