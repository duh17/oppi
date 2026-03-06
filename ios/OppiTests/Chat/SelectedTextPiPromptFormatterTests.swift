import Testing
@testable import Oppi

@Suite("SelectedTextPiPromptFormatter")
struct SelectedTextPiPromptFormatterTests {
    @Test func addToPromptFormatsAssistantProseAsQuote() {
        let request = SelectedTextPiRequest(
            action: .addToPrompt,
            selectedText: "first line\nsecond line",
            source: .init(sessionId: "session-1", surface: .assistantProse)
        )

        let result = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
        #expect(result == "> first line\n> second line")
    }

    @Test func addToPromptFormatsCodeSurfaceAsFence() {
        let request = SelectedTextPiRequest(
            action: .addToPrompt,
            selectedText: "let answer = 42",
            source: .init(
                sessionId: "session-1",
                surface: .fullScreenCode,
                languageHint: "swift"
            )
        )

        let result = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
        #expect(result == "```swift\nlet answer = 42\n```")
    }

    @Test func explainAddsInstructionPrefix() {
        let request = SelectedTextPiRequest(
            action: .explain,
            selectedText: "some passage",
            source: .init(sessionId: "session-1", surface: .assistantProse)
        )

        let result = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
        #expect(result == "Explain this:\n\n> some passage")
    }

    @Test func codeFormattingUsesLongerFenceWhenSelectionContainsBackticks() {
        let request = SelectedTextPiRequest(
            action: .addToPrompt,
            selectedText: "````\ncode\n````",
            source: .init(
                sessionId: "session-1",
                surface: .toolOutput,
                languageHint: "markdown"
            )
        )

        let result = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
        #expect(result.hasPrefix("`````markdown\n"))
        #expect(result.hasSuffix("\n`````"))
    }
}
