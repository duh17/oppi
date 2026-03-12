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

    private func render(
        text: String,
        language: SyntaxLanguage?
    ) -> (
        deferredHighlight: ToolRowCodeRenderStrategy.DeferredHighlight?,
        label: UITextView
    ) {
        let label = UITextView()
        let scrollView = UIScrollView()

        let output = ToolRowCodeRenderStrategy.render(
            text: text,
            language: language,
            startLine: 1,
            isStreaming: false,
            expandedLabel: label,
            expandedScrollView: scrollView,
            previousSignature: nil,
            previousRenderedText: nil,
            previousAutoFollow: false,
            isCurrentModeCode: false,
            wasExpandedVisible: false
        )

        return (output.deferredHighlight, label)
    }
}
