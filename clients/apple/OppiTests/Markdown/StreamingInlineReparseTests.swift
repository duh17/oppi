import Foundation
import Testing
import UIKit

@testable import Oppi

/// Tests that the streaming delta-append path in AssistantMarkdownSegmentApplier
/// handles CommonMark inline syntax closure correctly.
///
/// When markdown inline syntax closes mid-stream (e.g., **bold**, `code`,
/// [link](url)), the rendered plain text changes at earlier positions (syntax
/// markers are consumed). The delta-append optimization must detect this and
/// fall back to full replacement instead of appending a wrong delta.
@Suite("Streaming markdown inline reparse")
@MainActor
struct StreamingInlineReparseTests {

    // MARK: - Helpers

    private func makeApplier() -> (UIStackView, AssistantMarkdownSegmentApplier) {
        let stackView = UIStackView()
        stackView.axis = .vertical
        let delegate = NoOpDelegate()
        let applier = AssistantMarkdownSegmentApplier(
            stackView: stackView,
            textViewDelegate: delegate
        )
        return (stackView, applier)
    }

    private func streamTick(
        applier: AssistantMarkdownSegmentApplier,
        content: String,
        isStreaming: Bool = true
    ) {
        let blocks = parseCommonMark(content)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        let config = AssistantMarkdownContentView.Configuration(
            content: content,
            isStreaming: isStreaming,
            themeID: .dark
        )
        applier.apply(segments: segments, config: config)
    }

    private func extractPlainText(from stackView: UIStackView) -> String {
        stackView.arrangedSubviews.compactMap { view -> String? in
            (view as? UITextView)?.textStorage.string
        }.joined(separator: "\n---\n")
    }

    // MARK: - Bold closure

    @Test func boldClosureFallsBackToFullReplacement() {
        let (stackView, applier) = makeApplier()

        // Tick 1: unclosed bold — rendered as literal "Here is **bold text and"
        streamTick(applier: applier, content: "Here is **bold text and")
        let text1 = extractPlainText(from: stackView)
        #expect(text1.contains("**bold"), "Unclosed bold should render literal **")

        // Tick 2: bold closes — "**" markers consumed, text shifts
        streamTick(applier: applier, content: "Here is **bold text** and more")
        let text2 = extractPlainText(from: stackView)

        // The fix: text should be correct, not garbled
        #expect(text2.contains("bold text"), "Bold text should be present")
        #expect(text2.contains("and more"), "Continuation text should be present")
        #expect(!text2.contains("**"), "Literal ** should be gone after bold closes")
    }

    // MARK: - Inline code closure

    @Test func inlineCodeClosureFallsBackToFullReplacement() {
        let (stackView, applier) = makeApplier()

        // Tick 1: unclosed backtick
        streamTick(applier: applier, content: "Use `some_function and")
        let text1 = extractPlainText(from: stackView)
        #expect(text1.contains("`some_function"), "Unclosed code should render literal backtick")

        // Tick 2: backtick closes
        streamTick(applier: applier, content: "Use `some_function` and more")
        let text2 = extractPlainText(from: stackView)
        #expect(text2.contains("some_function"), "Code text should be present")
        #expect(text2.contains("and more"), "Continuation should be present")
    }

    // MARK: - Link closure

    @Test func linkClosureFallsBackToFullReplacement() {
        let (stackView, applier) = makeApplier()

        // Tick 1: unclosed link
        streamTick(applier: applier, content: "See [docs](https://example.com")
        let text1 = extractPlainText(from: stackView)
        // Unclosed link renders as literal text including brackets
        #expect(!text1.isEmpty)

        // Tick 2: link closes
        streamTick(applier: applier, content: "See [docs](https://example.com) for details")
        let text2 = extractPlainText(from: stackView)
        #expect(text2.contains("docs"), "Link text should be present")
        #expect(text2.contains("for details"), "Continuation should be present")
    }

    // MARK: - Plain text append (fast path still works)

    @Test func plainTextAppendUsesIncrementalPath() {
        let (stackView, applier) = makeApplier()

        // Tick 1: plain text
        streamTick(applier: applier, content: "Hello world")
        let text1 = extractPlainText(from: stackView)
        #expect(text1 == "Hello world")

        // Tick 2: more plain text appended
        streamTick(applier: applier, content: "Hello world and more")
        let text2 = extractPlainText(from: stackView)
        #expect(text2 == "Hello world and more")
    }

    // MARK: - Stream finish renders correctly

    @Test func streamFinishProducesCorrectOutput() {
        let (stackView, applier) = makeApplier()

        // Stream with unclosed bold
        streamTick(applier: applier, content: "Here is **bold")

        // More text with bold still open
        streamTick(applier: applier, content: "Here is **bold text** and done")

        // Finish streaming
        streamTick(applier: applier, content: "Here is **bold text** and done", isStreaming: false)
        let finalText = extractPlainText(from: stackView)
        #expect(finalText.contains("bold text"), "Final text should have bold text")
        #expect(finalText.contains("and done"), "Final text should have continuation")
        #expect(!finalText.contains("**"), "No literal ** in final output")
    }

    // MARK: - Multiple reparse cycles

    @Test func multipleInlineClosuresHandledCorrectly() {
        let (stackView, applier) = makeApplier()

        // Tick 1: two unclosed bolds
        streamTick(applier: applier, content: "First **bold and second **also")

        // Tick 2: first bold closes
        streamTick(applier: applier, content: "First **bold** and second **also")

        // Tick 3: second bold closes
        streamTick(applier: applier, content: "First **bold** and second **also bold** end")
        let text = extractPlainText(from: stackView)
        #expect(text.contains("bold"), "Should have bold text")
        #expect(text.contains("end"), "Should have end text")
    }
}

private final class NoOpDelegate: NSObject, UITextViewDelegate {}
