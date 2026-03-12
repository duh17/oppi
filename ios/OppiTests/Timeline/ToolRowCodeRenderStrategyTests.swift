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

        #expect(result.deferredHighlightSignature != nil)
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

        #expect(result.deferredHighlightSignature != nil)
        #expect(result.label.text == text)
    }

    @Test("keeps small snippets synchronous")
    func keepsSmallSnippetSynchronous() {
        ToolRowRenderCache.evictAll()

        let text = "struct App {\n    let name: String\n}"
        let result = render(text: text, language: .swift)

        #expect(result.deferredHighlightSignature == nil)
        let attributed = result.label.attributedText
        #expect(attributed != nil)
        #expect(attributed?.string.contains("│") == true)
    }

    private func render(
        text: String,
        language: SyntaxLanguage?
    ) -> (
        deferredHighlightSignature: Int?,
        label: UITextView
    ) {
        let view = ExpandedToolRowView()
        let input = ExpandedRenderInput(
            mode: .code(text: text, language: language, startLine: 1),
            isStreaming: false,
            outputColor: .white
        )
        _ = view.apply(input: input, wasExpandedVisible: false)

        return (view.expandedCodeDeferredHighlightSignature, view.expandedLabel)
    }
}
