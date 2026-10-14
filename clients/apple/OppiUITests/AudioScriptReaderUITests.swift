import XCTest

/// Script reader journey on the `audio-script-reader` preview: a silent clip paused
/// at 0:31, which is transcript line 2. Proves the UIKit transcript's follow,
/// unfollow, and tap-to-seek behavior against real `AudioPlayerService` playback.
final class AudioScriptReaderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDragStopsFollowingCurrentLineResumesAndTapSeeks() {
        app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "audio-script-reader"
        app.launch()
        dismissNotificationPrompt()

        let transcript = app.collectionViews["audioLyrics.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 8), "Script reader transcript did not appear")
        let playing = app.cells["audioLyrics.line.2"]
        XCTAssertTrue(waitUntil { playing.exists && playing.isSelected }, "Line 2 should be current at 0:31")

        let currentLine = app.buttons["Current Line"]
        XCTAssertFalse(currentLine.exists, "Following playback should not offer Current Line")
        transcript.swipeUp()
        XCTAssertTrue(currentLine.waitForExistence(timeout: 3), "Dragging the transcript should stop following")

        currentLine.tap()
        XCTAssertTrue(waitUntil { !currentLine.exists }, "Current Line should resume following and hide")
        XCTAssertTrue(waitUntil { playing.isHittable }, "Resuming should scroll the current line back into view")

        let target = app.cells["audioLyrics.line.4"]
        XCTAssertTrue(waitUntil { target.isHittable }, "Line 4 should be visible below the current line")
        target.tap()
        XCTAssertTrue(waitUntil { target.isSelected }, "Tapping a line should seek playback to it")
        XCTAssertFalse(playing.isSelected, "The previous line should no longer be current")
    }

    private func dismissNotificationPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons["Don’t Allow"]
        if dontAllow.waitForExistence(timeout: 5) {
            dontAllow.tap()
        }
    }

    private func waitUntil(timeout: TimeInterval = 4, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
