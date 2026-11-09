import XCTest

/// The Dismiss button on the transient notices, driven as a person would: the
/// real "Dictation stopped" notice (a failed take published by a real
/// `VoiceInputManager`) and the real message queue error. The timer's own
/// behaviour is unit-tested; these preview screens never let it expire.
@MainActor
final class NoticeDismissUITests: XCTestCase {
    private func launch(_ screen: String, contentSize: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = OppiTestLaunch.makeApp()
        app.launchArguments.append("--screenshot-preview")
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["screenshot.ready"].waitUntilExists(timeout: 10),
            "\(screen) preview did not become ready"
        )
        return app
    }

    func testDictationNoticeDismissLeavesTheComposerAndRetryGone() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI harness tests are simulator-only")
#endif
        let app = launch("notice-dismiss-dictation")
        let notice = app.descendants(matching: .any)["composer.dictationFailure"]
        let dismiss = app.buttons["composer.dictationFailure.dismiss"]
        XCTAssertTrue(notice.waitUntilExists(timeout: 6), "The failed take should show its notice")
        XCTAssertEqual(dismiss.label, "Dismiss")
        XCTAssertTrue(app.buttons["composer.dictationFailure.retry"].isHittable)

        dismiss.tap()
        XCTAssertTrue(notice.waitUntilGone(timeout: 6), "Dismiss should remove the notice")
        XCTAssertFalse(app.buttons["composer.dictationFailure.retry"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].exists, "The composer stays")
    }

    func testDictationNoticeKeepsDismissAndRetryReachableAtTheLargestTextSize() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI harness tests are simulator-only")
#endif
        let app = launch("notice-dismiss-dictation", contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let dismiss = app.buttons["composer.dictationFailure.dismiss"]
        XCTAssertTrue(dismiss.waitUntilExists(timeout: 6))
        XCTAssertTrue(dismiss.isHittable, "A long message must not push Dismiss out of reach")
        XCTAssertTrue(app.buttons["composer.dictationFailure.retry"].isHittable)
        dismiss.tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.dictationFailure"].waitUntilGone(timeout: 6))
    }

    func testMessageQueueErrorDismiss() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI harness tests are simulator-only")
#endif
        let app = launch("notice-dismiss-queue", contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let error = app.descendants(matching: .any)["chat.messageQueue.error"]
        let dismiss = app.buttons["chat.messageQueue.error.dismiss"]
        XCTAssertTrue(error.waitUntilExists(timeout: 6))
        XCTAssertTrue(dismiss.isHittable)

        dismiss.tap()
        XCTAssertTrue(dismiss.waitUntilGone(timeout: 6), "Dismiss should remove the queue error")
    }
}
