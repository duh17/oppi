import XCTest

/// Real previous/next interaction on the approved screenshot-preview fixtures.
/// Not a screenshot-only test.
///
/// SwiftUI `@Environment(\.accessibilityReduceMotion)` follows the simulator
/// host default `com.apple.Accessibility ReduceMotionEnabled`, not
/// `-UIAccessibilityReduceMotion`. A default `OppiUITests` run must stay green
/// with Reduce Motion off: the six `WithoutReduceMotion` tests execute, and the
/// four `WithReduceMotion` tests `XCTSkip` unless the wrapper already shows
/// `reduce-motion-on` (or `OPPI_SIM_REDUCE_MOTION=1` after the host write).
///
/// Reduce Motion on (owned simulator, then restore `false`):
/// `xcrun simctl spawn <udid> defaults write com.apple.Accessibility ReduceMotionEnabled -bool true`
/// `-only-testing:OppiUITests/FileBrowserMotionUITests/testOrdinaryPreviousNextWithReduceMotion`
/// `-only-testing:OppiUITests/FileBrowserMotionUITests/testReviewPreviousNextWithReduceMotion`
/// `-only-testing:OppiUITests/FileBrowserMotionUITests/testOrdinaryNextTravelCaptureWithReduceMotion`
/// `-only-testing:OppiUITests/FileBrowserMotionUITests/testReviewNextTravelCaptureWithReduceMotion`
@MainActor
final class FileBrowserMotionUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("File motion UI tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testOrdinaryPreviousNextWithoutReduceMotion() {
        launchPreview(screen: "file-browser-motion")
        assertReduceMotion(false)
        assertMarker("FILE_MOTION_BETA")
        tapNext()
        assertMarker("FILE_MOTION_GAMMA")
        tapPrevious()
        assertMarker("FILE_MOTION_BETA")
        tapPrevious()
        assertMarker("FILE_MOTION_ALPHA")
        XCTAssertFalse(app.buttons["Previous file"].exists)
    }

    func testOrdinaryPreviousNextWithReduceMotion() throws {
        launchPreview(screen: "file-browser-motion")
        try skipUnlessHostReduceMotionEnabled()
        assertReduceMotion(true)
        assertMarker("FILE_MOTION_BETA")
        tapNext()
        assertMarker("FILE_MOTION_GAMMA")
        tapPrevious()
        assertMarker("FILE_MOTION_BETA")
    }

    func testOrdinaryNextThenPreviousWithoutReduceMotion() {
        launchPreview(screen: "file-browser-motion")
        assertReduceMotion(false)
        assertMarker("FILE_MOTION_BETA")
        tapNext()
        assertMarker("FILE_MOTION_GAMMA")
        XCTAssertFalse(
            markerExists("FILE_MOTION_BETA"),
            "BETA must leave before Previous; Next was a no-op if BETA is still first"
        )
        tapPrevious()
        assertMarker("FILE_MOTION_BETA")
    }

    func testReviewPreviousNextWithoutReduceMotion() {
        launchPreview(screen: "review-file-motion")
        assertReduceMotion(false)
        assertMarker("FILE_MOTION_BETA")
        tapNext()
        assertMarker("FILE_MOTION_GAMMA")
        tapPrevious()
        assertMarker("FILE_MOTION_BETA")
        tapPrevious()
        assertMarker("FILE_MOTION_ALPHA")
        XCTAssertFalse(app.buttons["Previous file"].exists)
    }

    func testReviewPreviousNextWithReduceMotion() throws {
        launchPreview(screen: "review-file-motion")
        try skipUnlessHostReduceMotionEnabled()
        assertReduceMotion(true)
        assertMarker("FILE_MOTION_BETA")
        tapNext()
        assertMarker("FILE_MOTION_GAMMA")
        tapPrevious()
        assertMarker("FILE_MOTION_BETA")
    }

    func testReviewNextThenPreviousWithoutReduceMotion() {
        launchPreview(screen: "review-file-motion")
        assertReduceMotion(false)
        assertMarker("FILE_MOTION_BETA")
        tapNext()
        assertMarker("FILE_MOTION_GAMMA")
        XCTAssertFalse(
            markerExists("FILE_MOTION_BETA"),
            "BETA must leave before Previous; Next was a no-op if BETA is still first"
        )
        tapPrevious()
        assertMarker("FILE_MOTION_BETA")
    }

    func testOrdinaryNextTravelCaptureWithoutReduceMotion() {
        launchPreview(screen: "file-browser-motion")
        assertReduceMotion(false)
        assertMarker("FILE_MOTION_BETA")
        tapNextAndCaptureBurst(label: "ordinary-off")
        assertMarker("FILE_MOTION_GAMMA")
    }

    func testOrdinaryNextTravelCaptureWithReduceMotion() throws {
        launchPreview(screen: "file-browser-motion")
        try skipUnlessHostReduceMotionEnabled()
        assertReduceMotion(true)
        assertMarker("FILE_MOTION_BETA")
        tapNextAndCaptureBurst(label: "ordinary-on")
        assertMarker("FILE_MOTION_GAMMA")
    }

    func testReviewNextTravelCaptureWithoutReduceMotion() {
        launchPreview(screen: "review-file-motion")
        assertReduceMotion(false)
        assertMarker("FILE_MOTION_BETA")
        tapNextAndCaptureBurst(label: "review-off")
        assertMarker("FILE_MOTION_GAMMA")
    }

    func testReviewNextTravelCaptureWithReduceMotion() throws {
        launchPreview(screen: "review-file-motion")
        try skipUnlessHostReduceMotionEnabled()
        assertReduceMotion(true)
        assertMarker("FILE_MOTION_BETA")
        tapNextAndCaptureBurst(label: "review-on")
        assertMarker("FILE_MOTION_GAMMA")
    }

    private func launchPreview(screen: String) {
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--screenshot-preview",
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        app.launchEnvironment["OPPI_FILE_MOTION_MARKER"] = "1"
        app.launch()

        let ready = app.descendants(matching: .any)["screenshot.ready"]
        XCTAssertTrue(
            ready.waitForExistence(timeout: 8),
            "Preview \(screen) did not become ready"
        )
    }

    private func skipUnlessHostReduceMotionEnabled() throws {
        if ProcessInfo.processInfo.environment["OPPI_SIM_REDUCE_MOTION"] == "1" {
            return
        }
        if app.staticTexts["reduce-motion-on"].waitForExistence(timeout: 2) {
            return
        }
        throw XCTSkip(
            "Host ReduceMotionEnabled is off. Default UI runs skip WithReduceMotion tests. Enable with: xcrun simctl spawn <udid> defaults write com.apple.Accessibility ReduceMotionEnabled -bool true, then OPPI_SIM_REDUCE_MOTION=1. Restore to false after."
        )
    }

    private func assertReduceMotion(_ expected: Bool) {
        let expectedLabel = expected ? "reduce-motion-on" : "reduce-motion-off"
        let unexpectedLabel = expected ? "reduce-motion-off" : "reduce-motion-on"
        let labeled = app.staticTexts[expectedLabel]
        XCTAssertTrue(
            labeled.waitForExistence(timeout: 4),
            "DEBUG wrapper @Environment accessibilityReduceMotion was not \(expectedLabel) before interaction"
        )
        XCTAssertFalse(
            app.staticTexts[unexpectedLabel].exists,
            "Wrapper showed \(unexpectedLabel) but expected \(expectedLabel)"
        )
    }

    private func tapNext() {
        let button = app.buttons["Next file"]
        XCTAssertTrue(button.waitForExistence(timeout: 4), "Next file control missing")
        button.tap()
    }

    private func tapPrevious() {
        let button = app.buttons["Previous file"]
        XCTAssertTrue(button.waitForExistence(timeout: 4), "Previous file control missing")
        button.tap()
    }

    private func tapNextAndCaptureBurst(label: String) {
        guard let root = ProcessInfo.processInfo.environment["MOTION_CAPTURE_DIR"], !root.isEmpty else {
            tapNext()
            return
        }
        let folder = URL(fileURLWithPath: root).appendingPathComponent(label, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var frames: [Data] = [app.screenshot().pngRepresentation]
        tapNext()
        let started = Date()
        while Date().timeIntervalSince(started) < 0.40 {
            frames.append(app.screenshot().pngRepresentation)
        }
        for (index, png) in frames.enumerated() {
            let url = folder.appendingPathComponent(String(format: "frame-%03d.png", index))
            try? png.write(to: url)
        }
        let elapsed = Date().timeIntervalSince(started)
        let fps = elapsed > 0 ? Double(frames.count - 1) / elapsed : 0
        let payload = """
        {"label":"\(label)","frames":\(frames.count),"seconds":\(elapsed),"fps":\(fps)}
        """
        try? payload.data(using: .utf8)?.write(to: folder.appendingPathComponent("capture.json"))
    }

    private func assertMarker(_ marker: String) {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", marker, marker))
            .firstMatch
        XCTAssertTrue(
            match.waitForExistence(timeout: 8),
            "Expected visible page marker \(marker)"
        )
    }

    private func markerExists(_ marker: String) -> Bool {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", marker, marker))
            .firstMatch
        return match.exists
    }
}
