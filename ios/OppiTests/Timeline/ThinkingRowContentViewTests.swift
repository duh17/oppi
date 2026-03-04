import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("ThinkingTimelineRowContentView")
struct ThinkingRowContentViewTests {
    @Test func streamingOverflowKeepsInnerScrollDisabledAndAutoFollowsTail() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: Array(repeating: "streaming thought line", count: 300).joined(separator: "\n"),
            fullText: nil,
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let scrollView = try #require(privateScrollView(in: view))
        #expect(!scrollView.isScrollEnabled)
        #expect(!scrollView.isUserInteractionEnabled)
        #expect(scrollView.contentOffset.y > 0, "Streaming overflow should tail-follow inside capped bubble")
    }

    @Test func overflowDoesNotShowFloatingFullScreenButton() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: Array(repeating: "reasoning", count: 320).joined(separator: "\n"),
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let button = try #require(fullScreenButton(in: view))
        #expect(button.isHidden)
    }

    @Test func shortThinkingHidesFloatingFullScreenButton() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "Short thought",
            fullText: nil,
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let button = try #require(fullScreenButton(in: view))
        #expect(button.isHidden)
    }

    @Test func overflowContextMenuIncludesOpenFullScreenAndCopy() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: Array(repeating: "line", count: 320).joined(separator: "\n"),
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        _ = try #require(privateBubbleView(in: view))
        let menu = try #require(view.contextMenuForTesting())

        #expect(timelineActionTitles(in: menu) == ["Open Full Screen", "Copy"])
    }

    @Test func overflowRegistersPinchAndSingleTapGestures() {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: Array(repeating: "line", count: 320).joined(separator: "\n"),
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let recognizers = timelineAllGestureRecognizers(in: view)
        let hasPinch = recognizers.contains { $0 is UIPinchGestureRecognizer }
        let hasSingleTap = recognizers.contains {
            guard let tap = $0 as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired == 1
        }

        #expect(hasPinch)
        #expect(hasSingleTap)
    }
    // MARK: - Streaming plain text optimization

    @Test func streamingPreservesRawMarkdownSyntax() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Thinking about **bold** and `code`",
            fullText: nil,
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        // Streaming skips markdown parsing, so raw ** and ` survive in the label.
        #expect(
            label.text?.contains("**bold**") == true,
            "Streaming should preserve raw markdown syntax (no parsing)"
        )
    }

    @Test func doneStripsMarkdownSyntax() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: "Thinking about **bold** and `code`",
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        // Done state parses markdown, so ** is stripped and "bold" rendered with font traits.
        #expect(
            label.text?.contains("**bold**") != true,
            "Done state should parse markdown (no raw ** in text)"
        )
    }

    @Test func renderSignatureSkipsRedundantStreamingUpdate() throws {
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Initial thought",
            fullText: nil,
            themeID: .dark
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        let firstText = label.text

        let sig1 = try #require(privateRenderSignature(in: view))
        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Initial thought",
            fullText: nil,
            themeID: .dark
        )
        let sig2 = try #require(privateRenderSignature(in: view))
        #expect(sig1 == sig2, "Render signature should not change for identical content")
        #expect(label.text == firstText)
    }

    @Test func renderSignatureChangesWhenTextGrows() throws {
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Short",
            fullText: nil,
            themeID: .dark
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        let sig1 = try #require(privateRenderSignature(in: view))

        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Short thought that grew longer",
            fullText: nil,
            themeID: .dark
        )
        let sig2 = try #require(privateRenderSignature(in: view))
        #expect(sig1 != sig2, "Render signature should change when text changes")
    }

    @Test func transitionFromStreamingToDoneRendersMarkdown() throws {
        let text = "Thinking about **bold** patterns"
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: text,
            fullText: nil,
            themeID: .dark
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        #expect(
            label.text?.contains("**bold**") == true,
            "Streaming should preserve raw markdown"
        )

        // Transition to done — markdown parsed, ** stripped.
        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: text,
            themeID: .dark
        )
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(
            label.text?.contains("**bold**") != true,
            "Done transition should parse markdown"
        )
    }

    @Test func streamingLargeTextSkipsMarkdownParsing() throws {
        // 200 lines — representative of a mid-stream thinking burst.
        // The key assertion: raw markdown survives (no parsing happened).
        let longText = (0..<200).map { "Line \($0): thinking about **patterns** and `design`" }.joined(separator: "\n")
        let config = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: longText,
            fullText: nil,
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        #expect(
            label.text?.contains("**patterns**") == true,
            "Large streaming text must skip markdown parsing"
        )
    }
}

@MainActor
private func privateScrollView(in view: ThinkingTimelineRowContentView) -> UIScrollView? {
    Mirror(reflecting: view).children.first { $0.label == "scrollView" }?.value as? UIScrollView
}

@MainActor
private func privateBubbleView(in view: ThinkingTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == "bubbleView" }?.value as? UIView
}

@MainActor
private func privateTextLabel(in view: ThinkingTimelineRowContentView) -> UILabel? {
    Mirror(reflecting: view).children.first { $0.label == "textLabel" }?.value as? UILabel
}

@MainActor
private func privateRenderSignature(in view: ThinkingTimelineRowContentView) -> Int? {
    Mirror(reflecting: view).children.first { $0.label == "renderSignature" }?.value as? Int
}

@MainActor
private func fullScreenButton(in view: ThinkingTimelineRowContentView) -> UIButton? {
    timelineAllViews(in: view)
        .compactMap { $0 as? UIButton }
        .first { $0.accessibilityIdentifier == "thinking.expand-full-screen" }
}
