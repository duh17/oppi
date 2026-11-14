import Testing
import UIKit
@testable import Oppi

/// A file too large to format opens as plain text, says so, and formats on
/// request. Formatting a 10 MB Markdown file took 6 s and 125 MB; plain text
/// paints 100 MB in a quarter second.
@MainActor
@Suite("Large file reader")
struct LargeFileReaderTests {
    private static func text(bytes: Int) -> String {
        String(repeating: "a", count: bytes)
    }

    @Test func formatsUpToItsLimitAndOpensPlainOneByteOver() {
        let markdownLimit = FullScreenCodeContent.formattedTextByteLimit
        let codeLimit = FullScreenCodeContent.highlightedCodeByteLimit
        let cases: [(FullScreenCodeContent, Bool, String)] = [
            (.fromText(Self.text(bytes: markdownLimit), filePath: "notes.md"), false, "Markdown at the limit"),
            (.fromText(Self.text(bytes: markdownLimit + 1), filePath: "notes.md"), true, "Markdown over it"),
            (.fromText(Self.text(bytes: markdownLimit + 1), filePath: "plan.org"), true, "Org over it"),
            (.fromText(Self.text(bytes: codeLimit), filePath: "events.jsonl"), false, "code at its own limit"),
            (.fromText(Self.text(bytes: codeLimit + 1), filePath: "events.jsonl"), true, "code over it"),
            (.fromText(Self.text(bytes: codeLimit + 1), filePath: "server.log"), false, "plain text is never limited"),
        ]
        for (content, opensPlain, label) in cases {
            #expect(content.opensPlain == opensPlain, "\(label)")
        }
    }

    @Test func largeMarkdownOpensPlainWithANoteThatFormatsIt() async throws {
        let text = "# Notes\n\n" + Self.text(bytes: FullScreenCodeContent.formattedTextByteLimit)
        let controller = FullScreenCodeViewController(
            content: .fromText(text, filePath: "notes.md"),
            presentationMode: .embedded(onDismiss: {})
        )
        let window = makeSceneWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            hideTestWindow(window)
            window.rootViewController = nil
        }

        let opened = await waitForMainActorCondition(timeout: .seconds(10)) {
            window.layoutIfNeeded()
            return Self.find(NativeFullScreenSourceBody.self, in: window) != nil
        }
        #expect(opened, "a large Markdown file opens as plain text")
        #expect(Self.find(NativeFullScreenMarkdownBody.self, in: window) == nil)
        let format = try #require(
            Self.find(UIButton.self, in: window) { $0.accessibilityIdentifier == "reader.largeFileNote.format" },
            "the note offers to format the file"
        )
        #expect(format.configuration?.title == "Format Anyway")

        format.sendActions(for: .primaryActionTriggered)
        let formatted = await waitForMainActorCondition(timeout: .seconds(10)) {
            window.layoutIfNeeded()
            return Self.find(NativeFullScreenMarkdownBody.self, in: window) != nil
        }
        #expect(formatted, "Format Anyway renders the Markdown")
        #expect(Self.find(LargeFileNoteView.self, in: window) == nil, "the note goes with the plain text")
    }

    private static func find<View: UIView>(
        _ type: View.Type,
        in root: UIView,
        where predicate: (View) -> Bool = { _ in true }
    ) -> View? {
        if let match = root as? View, predicate(match) { return match }
        for subview in root.subviews {
            if let match = find(type, in: subview, where: predicate) { return match }
        }
        return nil
    }
}
