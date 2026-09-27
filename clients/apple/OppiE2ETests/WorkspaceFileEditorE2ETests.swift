import Foundation
import XCTest

/// Paired-server journeys for the workspace file editor: open → Edit → type →
/// idle autosave to disk; an external write → 412 conflict → Review → Replace;
/// deletion is never recreated; a conflicted draft survives app termination.
///
/// The fixture file lives on the host, so the runner reads and writes the
/// same bytes the server sees.
@MainActor
final class WorkspaceFileEditorE2ETests: E2ETestCase {
    nonisolated(unsafe) private var directoryName = ""
    nonisolated(unsafe) private var filePath = ""
    nonisolated(unsafe) private var skipSeed = false

    nonisolated private static let filename = "notes.md"
    nonisolated private static let original = "# Notes\r\nfirst line\r\nlast line without newline"

    /// The harness's standard launch: auto-open `e2e-workspace` (host mount
    /// `/tmp`) without creating a chat session. The fixture is a directory
    /// under `/tmp` that sorts first in the file list.
    override var e2eRequiresFreshLaunch: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    override func seedE2EFixtures() throws {
        guard !skipSeed else { return }
        directoryName = "000-oppi-wfe-\(UUID().uuidString.prefix(8).lowercased())"
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        filePath = directory.appendingPathComponent(Self.filename).path
        try Data(Self.original.utf8).write(to: URL(fileURLWithPath: filePath))
    }

    override func tearDownWithError() throws {
        if !directoryName.isEmpty {
            try? FileManager.default.removeItem(atPath: "/tmp/\(directoryName)")
        }
        try super.tearDownWithError()
    }

    // MARK: Journeys

    func testEditAutosavesExactBytesAndPreviewShowsDraft() throws {
        try openFileInEditor()
        let textView = editorTextView
        textView.tap()
        textView.typeText("TYPED")
        XCTAssertTrue(waitForDisk(timeout: 15) { $0.contains("TYPED") }, "idle autosave did not reach disk")
        XCTAssertTrue(waitForStatus("Saved", timeout: 10), "status did not settle on Saved")

        let disk = try diskBytes()
        let text = String(decoding: disk, as: UTF8.self)
        XCTAssertTrue(text.contains("TYPED"), "typed text is not on disk: \(text.debugDescription)")
        XCTAssertEqual(
            text.replacingOccurrences(of: "TYPED", with: ""),
            Self.original,
            "untouched bytes changed (CRLF, missing trailing newline)"
        )

        tap(app.buttons["workspace-file-editor.preview-toggle"], named: "Preview")
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace-file-editor.preview"].waitForExistence(timeout: 5),
            "Preview did not appear"
        )
        tap(app.buttons["workspace-file-editor.preview-toggle"], named: "Source")
        XCTAssertTrue(editorTextView.waitForExistence(timeout: 5))
        XCTAssertTrue((editorTextView.value as? String)?.contains("TYPED") == true, "text view lost the buffer")

        tap(app.buttons["workspace-file-editor.done"], named: "Done")
        XCTAssertTrue(
            app.buttons["fullscreen-code.action.workspace-file-edit"].waitForExistence(timeout: 10),
            "Done did not return to the reader"
        )
    }

    /// The keyboard's Return reaches the Markdown list hook and the save.
    func testMarkdownReturnContinuesListOnDisk() throws {
        try openFileInEditor()
        let textView = editorTextView
        // The fixture is short; a tap below it puts the caret at the end.
        textView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        textView.typeText("\n- one\ntwo")
        XCTAssertTrue(
            waitForDisk(timeout: 15) { $0.contains("two") },
            "idle autosave did not reach disk"
        )
        XCTAssertTrue(waitForStatus("Saved", timeout: 10), "status did not settle on Saved")
        XCTAssertEqual(
            try diskString(),
            Self.original + "\n- one\n- two",
            "Return in a list item did not continue the list"
        )
    }

    func testExternalWriteStopsAutosaveAndReplaceUsesReviewedVersion() throws {
        try openFileInEditor()
        let external = "# Notes\r\nagent wrote this\r\n"
        try Data(external.utf8).write(to: URL(fileURLWithPath: filePath))

        editorTextView.tap()
        editorTextView.typeText("MINE")
        XCTAssertTrue(waitForStatus("Conflict", timeout: 15), "412 did not surface as conflict")
        XCTAssertTrue(app.descendants(matching: .any)["workspace-file-editor.banner"].exists)
        XCTAssertEqual(try diskString(), external, "conflict clobbered the external write")

        // Typing continues; autosave stays stopped.
        editorTextView.typeText("MORE")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(try diskString(), external, "autosave ran after 412")

        tap(app.buttons["workspace-file-editor.review"], named: "Review Changes")
        XCTAssertTrue(
            app.buttons["workspace-file-review.close"].waitForExistence(timeout: 10),
            "Review Changes sheet did not open"
        )
        let replace = app.buttons["workspace-file-review.replace"]
        tap(replace, named: "Replace Disk Version", timeout: 15)
        XCTAssertTrue(waitForStatus("Saved", timeout: 15), "Replace did not save")
        let text = try diskString()
        XCTAssertTrue(text.contains("MINE") && text.contains("MORE"), "replace did not write the draft: \(text.debugDescription)")
        XCTAssertFalse(text.contains("agent wrote this"), "replace kept the external content")
    }

    func testDeletedFileIsNotRecreatedAndUseDiskLeavesEditor() throws {
        try openFileInEditor()
        try FileManager.default.removeItem(atPath: filePath)
        editorTextView.tap()
        editorTextView.typeText("GONE")
        XCTAssertTrue(waitForStatus("Deleted", timeout: 15), "404 did not surface as deleted")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath), "the editor recreated a deleted file")

        tap(app.buttons["workspace-file-editor.use-disk"], named: "Use Disk Version")
        let confirmAlert = app.alerts["Use Disk Version?"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 10), "Use Disk confirmation did not appear")
        // UIAlertController exposes each action as a button nested in a button
        // with the same identifier, so bind the outer node by identifier.
        let confirm = confirmAlert.buttons
            .matching(identifier: "workspace-file-editor.use-disk.confirm")
            .element(boundBy: 0)
        tap(confirm, named: "Discard My Edits")
        XCTAssertFalse(
            editorTextView.waitForExistence(timeout: 2) && editorTextView.isHittable,
            "editor stayed open after the file was gone"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath))
    }

    func testConflictedDraftSurvivesTerminationAndReopensInConflict() throws {
        try openFileInEditor()
        let external = "# Notes\r\nagent again\r\n"
        try Data(external.utf8).write(to: URL(fileURLWithPath: filePath))
        editorTextView.tap()
        editorTextView.typeText("KEEPME")
        XCTAssertTrue(waitForStatus("Conflict", timeout: 15))

        terminateSharedApp()
        skipSeed = true
        try setUpWithError()
        try openFile()
        XCTAssertTrue(editorTextView.waitForExistence(timeout: 15), "recovered draft did not reopen the editor")
        XCTAssertTrue(waitForStatus("Conflict", timeout: 10), "recovered draft did not open in conflict")
        XCTAssertTrue((editorTextView.value as? String)?.contains("KEEPME") == true, "draft text was lost")
        XCTAssertEqual(try diskString(), external, "recovery wrote over the external change")
    }

    /// iPad landscape shows the file tree beside a tree-pane reader. That pane
    /// hides the reader's UIKit bar, so Edit lives in the SwiftUI toolbar.
    func testIPadLandscapeTreePaneEditAutosaves() throws {
        try XCTSkipUnless(
            min(app.frame.width, app.frame.height) >= 700,
            "iPad tree-pane editing needs an iPad simulator"
        )
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let rotated = Date().addingTimeInterval(5)
        while Date() < rotated, app.frame.width < app.frame.height {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "iPad did not rotate to landscape")

        try openFile()
        XCTAssertTrue(
            app.descendants(matching: .any)["fileBrowser.tree"].waitForExistence(timeout: 10),
            "landscape Files did not show the file tree"
        )
        tap(app.buttons["workspace-file-editor.edit"], named: "tree-pane Edit", timeout: 15)
        XCTAssertTrue(editorTextView.waitForExistence(timeout: 10), "editor text view did not appear")
        XCTAssertTrue(
            app.descendants(matching: .any)["fileBrowser.tree"].exists,
            "editing replaced the tree layout"
        )

        editorTextView.tap()
        editorTextView.typeText("IPAD")
        XCTAssertTrue(waitForDisk(timeout: 15) { $0.contains("IPAD") }, "idle autosave did not reach disk")
        XCTAssertTrue(waitForStatus("Saved", timeout: 10), "status did not settle on Saved")
        XCTAssertEqual(
            try diskString().replacingOccurrences(of: "IPAD", with: ""),
            Self.original,
            "untouched bytes changed (CRLF, missing trailing newline)"
        )

        tap(app.buttons["workspace-file-editor.done"], named: "Done")
        XCTAssertTrue(
            app.buttons["workspace-file-editor.edit"].waitForExistence(timeout: 10),
            "Done did not return to the tree-pane reader"
        )
    }

    // MARK: Helpers

    private var editorTextView: XCUIElement {
        app.textViews["workspace-file-editor.text"]
    }

    private func diskBytes() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: filePath))
    }

    private func diskString() throws -> String {
        String(decoding: try diskBytes(), as: UTF8.self)
    }

    private func waitForDisk(timeout: TimeInterval, _ condition: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? diskString(), condition(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (try? diskString()).map(condition) ?? false
    }

    private func waitForStatus(_ label: String, timeout: TimeInterval) -> Bool {
        let status = app.staticTexts["workspace-file-editor.status"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status.exists, status.label == label { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return status.exists && status.label == label
    }

    private func openFile() throws {
        tap(app.buttons["workspace.files.open"], named: "workspace files button", timeout: 15)
        XCTAssertTrue(
            app.navigationBars["Files"].waitForExistence(timeout: 10),
            "Files opened a scope other than the workspace"
        )
        let directory = app.staticTexts[directoryName]
        XCTAssertTrue(directory.waitForExistence(timeout: 15), "fixture directory did not appear")
        tap(directory, named: "fixture directory row")
        let row = app.staticTexts[Self.filename]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "fixture file did not appear")
        tap(row, named: "fixture file row")
    }

    private func openFileInEditor() throws {
        try openFile()
        tap(app.buttons["fullscreen-code.action.workspace-file-edit"], named: "Edit", timeout: 15)
        XCTAssertTrue(editorTextView.waitForExistence(timeout: 10), "editor text view did not appear")
    }
}
