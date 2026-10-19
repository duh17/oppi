import Foundation
import XCTest

/// Editing from a chat's Files panel (compact width: a router sheet). The
/// reader hides the sheet's navigation bar for its own floating chrome; Edit
/// must bring the bar back with the editor's controls, so the user can finish
/// with Done instead of swiping the sheet away.
@MainActor
final class WorkspaceFileEditorChatPanelE2ETests: E2ETestCase {
    nonisolated(unsafe) private var directoryName = ""

    nonisolated private static let filename = "notes.md"

    override var e2eStartsInAutoCreatedChat: Bool { true }

    override func seedE2EFixtures() throws {
        directoryName = "000-oppi-wfe-chat-\(UUID().uuidString.prefix(8).lowercased())"
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("# Notes\nfirst line\n".utf8).write(to: directory.appendingPathComponent(Self.filename))
    }

    override func tearDownWithError() throws {
        if !directoryName.isEmpty {
            try? FileManager.default.removeItem(atPath: "/tmp/\(directoryName)")
        }
        try super.tearDownWithError()
    }

    func testEditingFromChatFilesAllKeepsTheEditorControls() throws {
        dismissExtensionSheetIfNeeded(timeout: 3)
        tap(app.buttons.matching(identifier: "chat.toolbar.files").firstMatch, named: "chat Files", timeout: 10)
        tap(app.buttons["All"], named: "All tab", timeout: 5)
        tap(app.staticTexts[directoryName], named: "fixture directory row", timeout: 15)
        tap(app.staticTexts[Self.filename], named: "fixture file row", timeout: 15)
        tap(app.buttons["fullscreen-code.action.workspace-file-edit"], named: "Edit", timeout: 15)
        XCTAssertTrue(app.textViews["workspace-file-editor.text"].waitForExistence(timeout: 10), "editor did not open")

        let done = app.buttons["workspace-file-editor.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "editing in the chat Files panel has no Done")
        XCTAssertTrue(app.buttons["workspace-file-editor.preview-toggle"].exists, "editing in the chat Files panel has no Preview")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "chat-files-editor-bar"
        shot.lifetime = .keepAlways
        add(shot)

        done.tap()
        XCTAssertTrue(
            app.buttons["fullscreen-code.action.workspace-file-edit"].waitForExistence(timeout: 10),
            "Done did not return to the reader"
        )
    }
}
