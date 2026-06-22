import Darwin
import Testing
import UIKit
@testable import Oppi

@Suite("Tool row code render strategy")
@MainActor
struct ToolRowCodeRenderStrategyTests {
    @Test("defers medium known-language files by byte size")
    func defersKnownLanguageByByteSize() {
        ToolRowRenderCache.evictAll()

        let text = (1...24)
            .map { index in
                "let line\(index) = \"" + String(repeating: "abcdefghij", count: 18) + "\""
            }
            .joined(separator: "\n")

        let result = render(text: text, language: .swift)

        #expect(result.deferredHighlight != nil)
        #expect(result.label.text == text)
        #expect(!(result.label.text ?? "").contains("│"))
    }

    @Test("defers known-language files with very long lines")
    func defersKnownLanguageByLongLine() {
        ToolRowRenderCache.evictAll()

        let text = [
            "func short() {}",
            "let payload = \"" + String(repeating: "x", count: 220) + "\"",
            "print(payload)",
        ].joined(separator: "\n")

        let result = render(text: text, language: .swift)

        #expect(result.deferredHighlight != nil)
        #expect(result.label.text == text)
    }

    @Test("keeps small snippets synchronous")
    func keepsSmallSnippetSynchronous() {
        ToolRowRenderCache.evictAll()

        let text = "struct App {\n    let name: String\n}"
        let result = render(text: text, language: .swift)

        #expect(result.deferredHighlight == nil)
        let attributed = result.label.attributedText
        #expect(attributed != nil)
        #expect(attributed?.string.contains("│") == true)
    }

    @Test("streaming prefix growth appends without replacing existing storage")
    func streamingPrefixGrowthAppendsWithoutReplacingExistingStorage() {
        ToolRowRenderCache.evictAll()

        let sentinel = NSAttributedString.Key("oppi.sentinel")
        let previous = "let first = 1\n"
        let next = previous + "let second = 2\n"
        let label = UITextView()
        label.attributedText = NSAttributedString(
            string: previous,
            attributes: [sentinel: "kept", .font: ToolFont.regular]
        )

        let result = render(
            text: next,
            language: .swift,
            isStreaming: true,
            label: label,
            previousSignature: streamingSignature(for: previous, startLine: 1),
            previousRenderedText: previous,
            isCurrentModeCode: true,
            wasExpandedVisible: true
        )

        #expect(label.text == next)
        #expect(result.output.renderedText == next)
        #expect(label.textStorage.attribute(sentinel, at: 0, effectiveRange: nil) as? String == "kept")
    }

    @Test("streaming final render upgrades to highlighted code")
    func streamingFinalRenderUpgradesToHighlightedCode() {
        ToolRowRenderCache.evictAll()

        let text = "let answer = 42\nprint(answer)"
        let streaming = render(
            text: text,
            language: .swift,
            isStreaming: true
        )

        #expect(streaming.label.text == text)
        #expect(streaming.label.attributedText == nil || streaming.label.attributedText.string == text)

        let final = render(
            text: text,
            language: .swift,
            isStreaming: false,
            label: streaming.label,
            previousSignature: streaming.output.renderSignature,
            previousRenderedText: streaming.output.renderedText,
            isCurrentModeCode: true,
            wasExpandedVisible: true
        )

        #expect(final.deferredHighlight == nil)
        #expect(final.label.attributedText?.string.contains("│") == true)
        #expect(final.label.attributedText?.string.contains("let answer = 42") == true)
    }

    @Test("streaming non-prefix replacement does not append stale text")
    func streamingNonPrefixReplacementDoesNotAppendStaleText() {
        ToolRowRenderCache.evictAll()

        let sentinel = NSAttributedString.Key("oppi.sentinel")
        let previous = "let first = 1\n"
        let next = "let other = 2\n"
        let label = UITextView()
        label.attributedText = NSAttributedString(
            string: previous,
            attributes: [sentinel: "removed", .font: ToolFont.regular]
        )

        let result = render(
            text: next,
            language: .swift,
            isStreaming: true,
            label: label,
            previousSignature: streamingSignature(for: previous, startLine: 1),
            previousRenderedText: previous,
            isCurrentModeCode: true,
            wasExpandedVisible: true
        )

        #expect(label.text == next)
        #expect(result.output.renderedText == next)
        #expect(label.textStorage.attribute(sentinel, at: 0, effectiveRange: nil) == nil)
    }

    @Test("full replace debug mode keeps old streaming behavior available")
    func fullReplaceDebugModeKeepsOldStreamingBehaviorAvailable() {
        ToolRowRenderCache.evictAll()

        setenv("OPPI_STREAMING_CODE_RENDER_MODE", "fullReplace", 1)
        defer { unsetenv("OPPI_STREAMING_CODE_RENDER_MODE") }

        let sentinel = NSAttributedString.Key("oppi.sentinel")
        let previous = "let first = 1\n"
        let next = previous + "let second = 2\n"
        let label = UITextView()
        label.attributedText = NSAttributedString(
            string: previous,
            attributes: [sentinel: "replaced", .font: ToolFont.regular]
        )

        let result = render(
            text: next,
            language: .swift,
            isStreaming: true,
            label: label,
            previousSignature: streamingSignature(for: previous, startLine: 1),
            previousRenderedText: previous,
            isCurrentModeCode: true,
            wasExpandedVisible: true
        )

        #expect(label.text == next)
        #expect(result.output.renderedText == next)
        #expect(label.textStorage.attribute(sentinel, at: 0, effectiveRange: nil) == nil)
    }

    @Test("streaming render preserves full content")
    func streamingRenderPreservesFullContent() {
        ToolRowRenderCache.evictAll()

        let previous = String(repeating: "let oldValue = 1\n", count: 512)
        let suffix = String(repeating: "let newValue = 2\n", count: 512)
        let next = previous + suffix
        let label = UITextView()
        label.text = previous

        let result = render(
            text: next,
            language: .swift,
            isStreaming: true,
            label: label,
            previousSignature: streamingSignature(for: previous, startLine: 1),
            previousRenderedText: previous,
            isCurrentModeCode: true,
            wasExpandedVisible: true
        )

        #expect(label.text == next)
        #expect(result.output.renderedText == next)
        #expect(label.text.count == previous.count + suffix.count)
    }

    private func render(
        text: String,
        language: SyntaxLanguage?,
        isStreaming: Bool = false,
        label: UITextView = UITextView(),
        previousSignature: Int? = nil,
        previousRenderedText: String? = nil,
        isCurrentModeCode: Bool = false,
        wasExpandedVisible: Bool = false
    ) -> (
        deferredHighlight: ToolRowCodeRenderStrategy.DeferredHighlight?,
        label: UITextView,
        output: ExpandedRenderOutput
    ) {
        let scrollView = UIScrollView()

        let output = ToolRowCodeRenderStrategy.render(
            text: text,
            language: language,
            startLine: 1,
            isStreaming: isStreaming,
            expandedLabel: label,
            expandedScrollView: scrollView,
            previousSignature: previousSignature,
            previousRenderedText: previousRenderedText,
            previousAutoFollow: false,
            isCurrentModeCode: isCurrentModeCode,
            wasExpandedVisible: wasExpandedVisible
        )

        return (output.deferredHighlight, label, output)
    }

    private func streamingSignature(for text: String, startLine: Int) -> Int {
        text.utf8.count ^ (startLine &* 31)
    }
}
