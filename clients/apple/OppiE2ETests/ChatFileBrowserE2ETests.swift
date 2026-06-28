import XCTest

/// Regression coverage for the chat-attached file browser entry point.
///
/// The Files control must open the in-chat Changed/All file panel. A tap must
/// not push the workspace file-browser route or SwiftUI's missing-destination
/// fallback screen.
final class ChatFileBrowserE2ETests: E2ETestCase {
    override var e2eStartsInAutoCreatedChat: Bool { true }

    @MainActor
    func testChatToolbarFilesButtonOpensAttachedPanel() throws {
        dismissExtensionSheetIfNeeded(timeout: 3)

        let filesButtons = app.buttons.matching(identifier: "chat.toolbar.files")
        let filesButton = filesButtons.firstMatch
        XCTAssertTrue(
            filesButton.waitForExistence(timeout: 10),
            "Chat Files toolbar button did not appear"
        )
        XCTAssertTrue(filesButton.isHittable, "Chat Files toolbar button is not hittable")
        let backButton = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(backButton.exists, "Chat should use one leading pill with Back and Files")
        XCTAssertLessThan(
            filesButton.frame.midX,
            app.frame.midX,
            "Chat Files toolbar button should live on the leading side of the navigation bar"
        )
        XCTAssertLessThan(
            backButton.frame.maxX,
            filesButton.frame.minX + 2,
            "Back and Files controls should be adjacent in the leading pill"
        )
        XCTAssertFalse(
            app.collectionViews["workspace.list"].exists,
            "Workspace list should not be the active accessibility surface before tapping chat Files"
        )

        filesButton.tap()

        let panelTitle = app.staticTexts["Files"]
        XCTAssertTrue(
            panelTitle.waitForExistence(timeout: 2),
            "Tapping chat Files should open the attached file panel, not reveal Workspace Home or fallback navigation"
        )
        XCTAssertTrue(
            app.buttons["Changed"].waitForExistence(timeout: 3),
            "Changed tab did not appear in attached file panel"
        )
        XCTAssertTrue(
            app.buttons["All"].waitForExistence(timeout: 3),
            "All tab did not appear in attached file panel"
        )
        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 2),
            "File panel should use the shared sheet navigation container"
        )
        XCTAssertFalse(
            app.buttons["chat.files.fullscreen.expand"].exists,
            "File panel should rely on the native sheet detent instead of a custom expand button"
        )
    }
}
