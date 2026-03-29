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

    private func firstTextView(in stackView: UIStackView) -> UITextView? {
        stackView.arrangedSubviews.first { $0 is UITextView } as? UITextView
    }

    private func countHiddenCharacters(in textView: UITextView) -> Int {
        let storage = textView.textStorage
        var hidden = 0
        storage.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if let color = value as? UIColor, color == .clear {
                hidden += range.length
            }
        }
        return hidden
    }

    private func extractRevealer(from applier: AssistantMarkdownSegmentApplier) throws -> StreamingTextRevealer {
        let mirror = Mirror(reflecting: applier)
        guard let revealer = mirror.children.first(where: { $0.label == "textRevealer" })?.value as? StreamingTextRevealer else {
            throw NSError(domain: "StreamingInlineReparseTests", code: 1)
        }
        return revealer
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

    @Test func boldClosureWithSameRenderedLengthStillUpdates() {
        let (stackView, applier) = makeApplier()

        // Tick 1 plain text length: "A **bo" == 6
        streamTick(applier: applier, content: "A **bo")
        let text1 = extractPlainText(from: stackView)
        #expect(text1 == "A **bo")

        // Tick 2 rendered plain text length is also 6: "A bold"
        // The streaming fast path must not treat equal length as "no change".
        streamTick(applier: applier, content: "A **bold**")
        let text2 = extractPlainText(from: stackView)
        #expect(text2 == "A bold")
        #expect(!text2.contains("**"))
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

    @Test func inlineCodeClosureWithSameRenderedLengthStillUpdates() {
        let (stackView, applier) = makeApplier()

        streamTick(applier: applier, content: "A `cod")
        let text1 = extractPlainText(from: stackView)
        #expect(text1 == "A `cod")

        streamTick(applier: applier, content: "A `code`")
        let text2 = extractPlainText(from: stackView)
        #expect(text2 == "A code")
        #expect(!text2.contains("`"))
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

    @Test func overlappingRevealContinuesFromCurrentVisibleBoundary() throws {
        let (stackView, applier) = makeApplier()

        // Initial content is fully visible.
        streamTick(applier: applier, content: "Hello")

        // Tick 2 starts revealing the appended tail. No display-link frame has
        // fired yet in this test, so only the original 5 chars are visible.
        streamTick(applier: applier, content: "Hello world")

        // Tick 3 arrives before tick 2 finished revealing.
        streamTick(applier: applier, content: "Hello world again")

        let textView = try #require(firstTextView(in: stackView))
        #expect(countHiddenCharacters(in: textView) > 0, "Tail should still be mid-reveal")

        let revealer = try extractRevealer(from: applier)
        #expect(
            revealer.currentVisibleCount == 5,
            "Overlapping reveals must continue from the true visible boundary, not the previous full text length"
        )
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
