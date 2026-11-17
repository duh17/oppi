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
        assertNoPrevious()
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
        assertNoPrevious()
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
        let control = adjacentControl("fileViewer.next", label: "Next file")
        XCTAssertTrue(control.exists, "Next file control missing from the bar and its …")
        control.tap()
    }

    private func tapPrevious() {
        let control = adjacentControl("fileViewer.previous", label: "Previous file")
        XCTAssertTrue(control.exists, "Previous file control missing from the bar and its …")
        control.tap()
    }

    /// The previous or next file where the Reader Bar puts it: its button, or
    /// its row in the … when a narrow bar (the iPhone's tree pane) crowds it out.
    private func adjacentControl(_ identifier: String, label: String) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        if button.waitUntilExists(timeout: 4), button.isHittable { return button }
        return openMenu().buttons.matching(Self.row(identifier, label: label)).firstMatch
    }

    /// The first file offers no Previous, on the bar or in its ….
    private func assertNoPrevious() {
        XCTAssertFalse(app.buttons["fileViewer.previous"].exists, "The first file has no Previous button")
        let menu = openMenu()
        XCTAssertFalse(
            menu.buttons.matching(Self.row("fileViewer.previous", label: "Previous file")).firstMatch.exists,
            "The first file has no Previous row in the …"
        )
    }

    /// Opens the bar's … and returns its menu.
    private func openMenu() -> XCUIElement {
        app.barOverflowButton.tap()
        XCTAssertTrue(app.buttons["fileViewer.menu.customize"].waitUntilExists(timeout: 5), "the … opens with Customize Bar…")
        return app.collectionViews.containing(.button, identifier: "fileViewer.menu.customize").firstMatch
    }

    /// A crowded-out row is UIKit's, from the button's title: it may not keep
    /// the button's identifier.
    private static func row(_ identifier: String, label: String) -> NSPredicate {
        NSPredicate(format: "identifier == %@ OR label ==[c] %@", identifier, label)
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
