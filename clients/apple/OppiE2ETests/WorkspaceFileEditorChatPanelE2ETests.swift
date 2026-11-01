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

    func testEditingFromChatFilesKeepsTheEditorControls() throws {
        dismissExtensionSheetIfNeeded(timeout: 3)
        tap(app.buttons.matching(identifier: "chat.toolbar.files").firstMatch, named: "chat Files", timeout: 10)
        // The panel is the checkout's file browser, and this harness mounts the
        // workspace at /tmp: one listing of it is truncated and lists entries in
        // filesystem order, so the browser's search — fed by the whole file index
        // — is what finds the fixture whatever else the mount holds. The fixture
        // directory's name is unique, so its file is the only result.
        let search = app.searchFields["Search files"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the chat Files panel has no file search")
        search.tap()
        search.typeText(directoryName)
        let fixtureRow = app.buttons["fileBrowser.row.\(directoryName)/\(Self.filename)"]
        XCTAssertTrue(
            fixtureRow.waitForExistence(timeout: 15),
            "the browser did not find the fixture file in the checkout"
        )
        tap(fixtureRow, named: "fixture file row", timeout: 5)
        tap(app.buttons["workspace-file-editor.edit"], named: "Edit", timeout: 15)
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
            app.buttons["workspace-file-editor.edit"].waitForExistence(timeout: 10),
            "Done did not return to the reader"
        )
    }
}
