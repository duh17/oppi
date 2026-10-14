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
        assertAnchored(playing, in: transcript)

        let currentLine = app.buttons["Current Line"]
        XCTAssertFalse(currentLine.exists, "Following playback should not offer Current Line")
        transcript.swipeUp()
        XCTAssertTrue(currentLine.waitForExistence(timeout: 3), "Dragging the transcript should stop following")

        currentLine.tap()
        XCTAssertTrue(waitUntil { !currentLine.exists }, "Current Line should resume following and hide")
        XCTAssertTrue(waitUntil { playing.isHittable }, "Resuming should scroll the current line back into view")
        assertAnchored(playing, in: transcript)

        let target = app.cells["audioLyrics.line.4"]
        XCTAssertTrue(waitUntil { target.isHittable }, "Line 4 should be visible below the current line")
        target.tap()
        XCTAssertTrue(waitUntil { target.isSelected }, "Tapping a line should seek playback to it")
        let current = app.cells.matching(NSPredicate(format: "selected == true"))
        XCTAssertEqual(current.count, 1, "Only the tapped line should be current; the previous line no longer is")
    }

    func testSpeedAndSleepTimerControls() {
        app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "audio-script-reader"
        app.launch()
        dismissNotificationPrompt()
        XCTAssertTrue(app.cells["audioLyrics.line.2"].waitForExistence(timeout: 8))

        let speed = app.buttons["Playback Speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 3))
        speed.tap()
        app.buttons["1.5\u{00D7}"].firstMatch.tap()
        XCTAssertTrue(waitUntil { (speed.value as? String) == "1.5\u{00D7}" }, "Speed should read 1.5\u{00D7}")
        // Speed is a saved preference; leave the simulator at normal speed.
        speed.tap()
        app.buttons["1\u{00D7}"].firstMatch.tap()
        XCTAssertTrue(waitUntil { (speed.value as? String) == "1\u{00D7}" })

        let sleep = app.buttons["Sleep Timer"]
        XCTAssertEqual(sleep.value as? String, "Off")
        sleep.tap()
        app.buttons["15 Minutes"].tap()
        // Playback is paused, so the full listening time remains.
        XCTAssertTrue(waitUntil { (sleep.value as? String) == "15:00" }, "Sleep timer should show 15:00 left")
        sleep.tap()
        app.buttons["Turn Off Timer"].tap()
        XCTAssertTrue(waitUntil { (sleep.value as? String) == "Off" })
    }

    /// Script mode keeps the current paragraph about a third of the way down the transcript.
    private func assertAnchored(_ row: XCUIElement, in transcript: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var position: CGFloat = -1
        let settled = waitUntil {
            let pane = transcript.frame
            guard pane.height > 0 else { return false }
            position = (row.frame.midY - pane.minY) / pane.height
            return abs(position - 0.35) < 0.06
        }
        XCTAssertTrue(
            settled,
            "Current row center sits at \(position) of the transcript height, expected about 0.35",
            file: file,
            line: line
        )
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
