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

    @Test func overflowShowsFloatingFullScreenButton() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: Array(repeating: "reasoning", count: 320).joined(separator: "\n"),
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let button = try #require(fullScreenButton(in: view))
        #expect(!button.isHidden)
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

    @Test func overflowRegistersPinchAndDoubleTapGestures() {
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
        let hasDoubleTap = recognizers.contains {
            guard let tap = $0 as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired == 2
        }

        #expect(hasPinch)
        #expect(hasDoubleTap)
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
private func fullScreenButton(in view: ThinkingTimelineRowContentView) -> UIButton? {
    timelineAllViews(in: view)
        .compactMap { $0 as? UIButton }
        .first { $0.accessibilityIdentifier == "thinking.expand-full-screen" }
}
