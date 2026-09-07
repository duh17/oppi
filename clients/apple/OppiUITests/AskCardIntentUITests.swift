import XCTest

/// Wiring proof for inline Ask delayed auto-advance. Uses the lane-local
/// `ask-card-intent-regression` preview, not ScreenshotPreviewUITests.
///
/// Delay is the production `AskInlineAutoAdvanceController` with a parked wait.
/// Tests register pending, tap the real competing control, then release.
@MainActor
final class AskCardIntentUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Ask intent regression tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testSelectionThenImmediateIgnoreDoesNotSkip() {
        launchIntentPreview()
        tapOption("alpha")
        waitForDelayPending()

        let ignore = inCardIgnore
        XCTAssertTrue(ignore.waitForExistence(timeout: 2), "In-card Ignore → should stay available after a selection")
        ignore.tap()

        XCTAssertTrue(questionTwo.waitForExistence(timeout: 2), "In-card Ignore should move to question two immediately")
        releaseDelay()
        XCTAssertFalse(
            questionThree.waitForExistence(timeout: 1),
            "Releasing a cancelled delay must not skip past Ignore to question three"
        )
        saveScreenshot(name: "ask-intent-ignore")
    }

    func testSelectionThenCurrentPageDotDoesNotSkip() {
        launchIntentPreview()
        tapOption("alpha")
        waitForDelayPending()

        let currentDot = pageDot(1)
        XCTAssertTrue(currentDot.waitForExistence(timeout: 2), "Current page dot Question 1 of 3 should be tappable")
        currentDot.tap()

        XCTAssertTrue(questionOne.waitForExistence(timeout: 2), "Tapping the current page dot should keep question one")
        releaseDelay()
        XCTAssertFalse(
            questionTwo.waitForExistence(timeout: 1),
            "Releasing a cancelled delay must not advance after the current page dot"
        )
        saveScreenshot(name: "ask-intent-page-dot")
    }

    func testSelectionThenExpandDoesNotSkip() {
        launchIntentPreview()
        tapOption("alpha")
        waitForDelayPending()

        let expand = app.otherElements["Expand ask request"]
        XCTAssertTrue(expand.waitForExistence(timeout: 2), "Expand ask request should be visible")
        expand.tap()

        let sheet = app.descendants(matching: .any)["ask.approval.scroll"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "Expand ask request must open the expanded ask sheet")
        releaseDelay()
        XCTAssertFalse(
            questionTwo.waitForExistence(timeout: 1),
            "Releasing a cancelled delay must not change the expanded question"
        )
        saveScreenshot(name: "ask-intent-expand")
    }

    /// Composer X (`chat.askIgnore`) is the busy empty-ask control. Selecting an
    /// option sets a draft answer, `canSend` becomes true, and production replaces
    /// X with Send. Option-then-X is not a reachable race. This tests the reachable
    /// X path: ignore-all before any answer, which still marks submitted.
    func testComposerXIgnoresRequestBeforeSelection() {
        launchIntentPreview()
        XCTAssertTrue(delayIdle.waitForExistence(timeout: 2), "No delay should be pending before a selection")

        let composerIgnore = app.buttons["Ignore request"]
        XCTAssertTrue(
            composerIgnore.waitForExistence(timeout: 2),
            "Composer X (Ignore request) is reachable only before a selectable answer makes Send the primary action"
        )
        composerIgnore.tap()

        XCTAssertTrue(
            app.staticTexts["Ignored all"].waitForExistence(timeout: 2),
            "Composer X should ignore the whole request"
        )
        XCTAssertTrue(questionOne.waitForExistence(timeout: 2), "Composer X must not wait for store removal")
        XCTAssertFalse(composerIgnore.isEnabled, "Duplicate composer Ignore should be disabled while submit is in flight")
        saveScreenshot(name: "ask-intent-composer-x")
    }

    func testSameIdContentUpdateClampsPage() {
        launchIntentPreview()
        let lastDot = pageDot(3)
        XCTAssertTrue(lastDot.waitForExistence(timeout: 2), "Last page dot should be tappable")
        lastDot.tap()
        XCTAssertTrue(questionThree.waitForExistence(timeout: 2), "Page 3 should be reachable before replacement")

        let replace = app.buttons["Replace same-id content"]
        XCTAssertTrue(replace.waitForExistence(timeout: 2), "Same-id replacement control should be visible")
        replace.tap()

        XCTAssertTrue(
            replacementQuestion.waitForExistence(timeout: 2),
            "Same-id shorter content must clamp onto the replacement question"
        )
        XCTAssertFalse(questionThree.waitForExistence(timeout: 1), "Clamped page must not keep the old last question")
        saveScreenshot(name: "ask-intent-same-id")
    }

    func testIgnoreHitTargetOutsideGlyph() {
        launchIntentPreview()
        let ignore = inCardIgnore
        XCTAssertTrue(ignore.waitForExistence(timeout: 2), "In-card Ignore → should be visible")
        XCTAssertGreaterThanOrEqual(
            ignore.frame.height,
            44,
            "Ignore hit frame height must be at least 44pt, not the caption glyph"
        )
        XCTAssertGreaterThanOrEqual(
            ignore.frame.width,
            44,
            "Ignore hit frame width must be at least 44pt"
        )

        let outsideGlyph = ignore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        outsideGlyph.tap()
        XCTAssertTrue(
            questionTwo.waitForExistence(timeout: 2),
            "A tap in the Ignore padding, outside the caption glyph, must still Ignore"
        )
        saveScreenshot(name: "ask-intent-ignore-hit")
    }

    private var inCardIgnore: XCUIElement {
        app.buttons["Ignore \u{2192}"]
    }
    private var delayPending: XCUIElement {
        app.staticTexts["Delay pending"]
    }
    private var delayIdle: XCUIElement {
        app.staticTexts["Delay idle"]
    }
    private var questionOne: XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Intent question one")).firstMatch
    }
    private var questionTwo: XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Intent question two")).firstMatch
    }
    private var questionThree: XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Intent question three")).firstMatch
    }
    private var replacementQuestion: XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Intent replacement only")).firstMatch
    }

    private func tapOption(_ value: String) {
        let labels = ["alpha": "Alpha", "bravo": "Bravo"]
        let label = labels[value] ?? value.capitalized
        let option = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Missing option \(label)")
        option.tap()
    }

    private func pageDot(_ number: Int) -> XCUIElement {
        app.buttons["Question \(number) of 3"]
    }

    private func waitForDelayPending() {
        XCTAssertTrue(
            delayPending.waitForExistence(timeout: 2),
            "AskCard must register a pending auto-advance wait after the option tap"
        )
    }

    private func releaseDelay() {
        let release = app.buttons["Release delay"]
        XCTAssertTrue(release.waitForExistence(timeout: 2), "Release delay control should be visible")
        release.tap()
    }

    private func launchIntentPreview() {
        app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "ask-card-intent-regression"
        app.launch()

        let ready = app.descendants(matching: .any)["screenshot.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 8), "Ask intent regression preview did not become ready")
        XCTAssertTrue(questionOne.waitForExistence(timeout: 5), "Question one should be visible")
    }

    private func saveScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let dir = "/tmp/oppi-screenshots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(name).png"
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
    }
}
