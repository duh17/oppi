import Foundation
import Testing
import UIKit
@testable import Oppi

/// Wrap Lines off: long lines stay on one row and scroll sideways. UITextView
/// refits its container to the view on layout and never widens its content on
/// its own, so both regress silently.
@Suite("Code editor line wrapping")
@MainActor
struct CodeEditorLineWrapTests {
    private static let longLine = String(repeating: "abcdefghij ", count: 30)
    private static let text = (0..<40).map { "\($0) " + longLine }.joined(separator: "\n")

    private func makeEditor(
        wrapsLines: Bool,
        showsLineNumbers: Bool = true
    ) throws -> (WorkspaceFileEditorViewController, CodeEditorPreferences, UIWindow) {
        let defaults = try #require(UserDefaults(suiteName: "editor-wrap-\(UUID().uuidString)"))
        let preferences = CodeEditorPreferences(defaults: defaults)
        preferences.keybindings = .vim
        preferences.wrapsLines = wrapsLines
        preferences.showsLineNumbers = showsLineNumbers
        let session = try #require(WorkspaceFileEditSession(
            identity: WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md"),
            disk: WorkspaceFileDiskSnapshot(bytes: Data(Self.text.utf8), etag: "\"sha256-\(String(repeating: "a", count: 64))\""),
            maxBytes: 100_000,
            transport: WorkspaceFileEditTransport(read: { _ in .failed }, write: { _, _, _ in .notSent }),
            draftStore: WorkspaceFileDraftStore(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("editor-wrap-\(UUID().uuidString)")
            ),
            idleDelay: .seconds(60)
        ))
        let controller = WorkspaceFileEditorViewController(session: session, themeID: .dark, preferences: preferences) { _ in UIViewController() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.updatePropertiesIfNeeded()
        window.layoutIfNeeded()
        return (controller, preferences, window)
    }

    private func firstLineFrame(_ textView: CodeEditorTextView) throws -> CGRect {
        try #require(textView.fragmentFrame(containing: 0))
    }

    @Test func openedUnwrappedKeepsLongLinesOnOneRowAndScrollsToTheCaret() throws {
        let (controller, _, window) = try makeEditor(wrapsLines: false)
        defer { window.isHidden = true }
        let textView = controller.textView
        let rowHeight = try #require(textView.font).lineHeight

        let opened = try firstLineFrame(textView)
        #expect(opened.width > textView.bounds.width * 3, "the long line is one wide row after the first layout")
        #expect(opened.height < rowHeight * 1.5)
        #expect(textView.contentSize.width > opened.width, "content is as wide as the line, so it scrolls sideways")

        #expect(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: 0, length: 0)
        // Vim `$`: the caret jumps to the end of the long line.
        textView.insertText("$")
        window.layoutIfNeeded()

        let moved = try firstLineFrame(textView)
        #expect(moved.width == opened.width, "a caret move never rewraps the line")
        #expect(textView.contentOffset.x > textView.bounds.width, "the view follows the caret sideways")
        #expect(textView.contentOffset.x + textView.bounds.width <= textView.contentSize.width + 1)
    }

    /// True when the caret at `offset` sits inside the viewport, right of the gutter.
    private func caretIsVisible(_ textView: CodeEditorTextView, at offset: Int) throws -> Bool {
        let position = try #require(textView.position(from: textView.beginningOfDocument, offset: offset))
        let caret = textView.caretRect(for: position)
        return caret.minX >= textView.contentOffset.x && caret.maxX <= textView.contentOffset.x + textView.bounds.width
    }

    @Test func caretStaysInViewAcrossRotationVisualModeAndLineStart() throws {
        // No gutter: the caret at column 0 sits within one margin of the edge.
        let (controller, _, window) = try makeEditor(wrapsLines: false, showsLineNumbers: false)
        defer { window.isHidden = true }
        let textView = controller.textView
        #expect(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.insertText("$")
        window.layoutIfNeeded()
        let lineEnd = textView.selectedRange.location
        #expect(try caretIsVisible(textView, at: lineEnd))

        // Rotation resizes the view, which resets the sideways offset.
        window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        window.layoutIfNeeded()
        #expect(try caretIsVisible(textView, at: lineEnd), "landscape keeps the caret in view")
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.layoutIfNeeded()
        #expect(try caretIsVisible(textView, at: lineEnd), "portrait again keeps the caret in view")

        // Back to column 0 scrolls all the way back, not to a sliver short of it.
        textView.insertText("0")
        window.layoutIfNeeded()
        #expect(textView.contentOffset.x == -textView.adjustedContentInset.left)

        // Visual `v$`: the moving end of the selection is followed.
        textView.insertText("v")
        textView.insertText("$")
        window.layoutIfNeeded()
        #expect(textView.selectedRange.length > 0)
        #expect(try caretIsVisible(textView, at: controller.vim.cursorOffset), "Visual mode follows its cursor end")
    }

    @Test func keyboardHeightChangesKeepTheUsersSidewaysScroll() throws {
        let (controller, _, window) = try makeEditor(wrapsLines: false)
        defer { window.isHidden = true }
        let textView = controller.textView
        #expect(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: 0, length: 0)
        window.layoutIfNeeded()

        // Pan away from the caret, then the keyboard shows and hides.
        textView.contentOffset.x = 1_500
        let height = textView.frame.height
        for keyboardHeight: CGFloat in [300, 180, 0] {
            textView.frame.size.height = height - keyboardHeight
            textView.layoutIfNeeded()
            #expect(textView.contentOffset.x == 1_500)
        }
    }

    @Test func wrappingAgainFitsLinesToTheViewAndDropsSidewaysScroll() throws {
        let (controller, preferences, window) = try makeEditor(wrapsLines: false)
        defer { window.isHidden = true }
        let textView = controller.textView
        textView.contentOffset.x = 500

        preferences.wrapsLines = true
        controller.updatePropertiesIfNeeded()
        window.layoutIfNeeded()

        #expect(try firstLineFrame(textView).width <= textView.bounds.width)
        #expect(textView.contentSize.width == textView.bounds.width)
        #expect(textView.contentOffset.x == -textView.adjustedContentInset.left)
    }
}
