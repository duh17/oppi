import Testing
@testable import PiRemote

@Suite("AssistantMarkdownFallbackHeuristics")
struct AssistantMarkdownFallbackHeuristicsTests {
    @Test func plainTextDoesNotFallback() {
        #expect(!AssistantMarkdownFallbackHeuristics.shouldFallbackToSwiftUI(
            "This is a plain assistant response.",
            isStreaming: false
        ))
    }

    @Test func streamingNeverFallsBack() {
        #expect(!AssistantMarkdownFallbackHeuristics.shouldFallbackToSwiftUI(
            "# Heading while streaming",
            isStreaming: true
        ))
    }

    @Test func headingFallsBack() {
        #expect(AssistantMarkdownFallbackHeuristics.shouldFallbackToSwiftUI(
            "# Title\n\nBody",
            isStreaming: false
        ))
    }

    @Test func unorderedListFallsBack() {
        #expect(AssistantMarkdownFallbackHeuristics.shouldFallbackToSwiftUI(
            "- one\n- two",
            isStreaming: false
        ))
    }

    @Test func orderedListFallsBack() {
        #expect(AssistantMarkdownFallbackHeuristics.shouldFallbackToSwiftUI(
            "1. first\n2. second",
            isStreaming: false
        ))
    }

    @Test func fencedCodeFallsBack() {
        #expect(AssistantMarkdownFallbackHeuristics.shouldFallbackToSwiftUI(
            "```swift\nprint(\"hi\")\n```",
            isStreaming: false
        ))
    }

    @Test func markdownTableFallsBack() {
        #expect(AssistantMarkdownFallbackHeuristics.shouldFallbackToSwiftUI(
            "| Name | Value |\n| --- | --- |\n| A | 1 |",
            isStreaming: false
        ))
    }
}
