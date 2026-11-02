import XCTest

/// Real previous/next interaction on the approved screenshot-preview fixtures.
/// Not a screenshot-only test.
///
/// The wrapper publishes `reduce-motion-off` in a default run: the simulator host
/// default is `com.apple.Accessibility ReduceMotionEnabled` off, and
/// `-UIAccessibilityReduceMotion` does not change it.
@MainActor
final class FileBrowserMotionUITests: XCTestCase, PreviewUITestCase {
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
        XCTAssertFalse(app.buttons["fileViewer.previous"].exists)
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
        XCTAssertFalse(app.buttons["fileViewer.previous"].exists)
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

    /// The motion previews publish `FILE_MOTION_*` markers in this overlay, on
    /// top of the preview every launch shares.
    private func launchPreview(screen: String) {
        launchPreview(screen: screen, environment: ["OPPI_FILE_MOTION_MARKER": "1"], readyTimeout: 8)
    }

    private func assertReduceMotion(_ expected: Bool) {
        let expectedLabel = expected ? "reduce-motion-on" : "reduce-motion-off"
        let unexpectedLabel = expected ? "reduce-motion-off" : "reduce-motion-on"
        let labeled = app.staticTexts[expectedLabel]
        XCTAssertTrue(
            labeled.waitUntilExists(timeout: 4),
            "DEBUG wrapper @Environment accessibilityReduceMotion was not \(expectedLabel) before interaction"
        )
        XCTAssertFalse(
            app.staticTexts[unexpectedLabel].exists,
            "Wrapper showed \(unexpectedLabel) but expected \(expectedLabel)"
        )
    }

    private func tapNext() {
        let button = app.buttons["fileViewer.next"]
        XCTAssertTrue(button.waitUntilExists(timeout: 4), "Next file control missing")
        button.tap()
    }

    private func tapPrevious() {
        let button = app.buttons["fileViewer.previous"]
        XCTAssertTrue(button.waitUntilExists(timeout: 4), "Previous file control missing")
        button.tap()
    }

    private func assertMarker(_ marker: String) {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", marker, marker))
            .firstMatch
        XCTAssertTrue(
            match.waitUntilExists(timeout: 8),
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
