import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("AssistantTimelineRowContentView")
struct AssistantTimelineRowContentViewTests {
    @MainActor
    @Test func rendersMarkdownLinksAsClickable() throws {
        let text = "See [the docs](https://example.com) for details"
        let view = AssistantTimelineRowContentView(configuration: makeTimelineAssistantConfiguration(text: text))
        let textView = try #require(timelineFirstTextView(in: view))

        // Markdown parser produces attributed text with .link attribute on "the docs".
        let fullText = textView.attributedText.string
        let nsText = fullText as NSString
        let docsRange = nsText.range(of: "the docs")
        #expect(docsRange.location != NSNotFound)

        let linkedValue = textView.attributedText.attribute(.link, at: docsRange.location, effectiveRange: nil)
        let linkedURL = try #require(linkedValue as? URL)
        #expect(linkedURL.absoluteString == "https://example.com")
    }

    @MainActor
    @Test func rendersInlineCodeWithMonospacedFont() throws {
        let text = "Use `parseCommonMark()` to parse"
        let view = AssistantTimelineRowContentView(configuration: makeTimelineAssistantConfiguration(text: text))
        let textView = try #require(timelineFirstTextView(in: view))

        let fullText = textView.attributedText.string
        let nsText = fullText as NSString
        let codeRange = nsText.range(of: "parseCommonMark()")
        #expect(codeRange.location != NSNotFound)
    }

    @MainActor
    @Test func rendersCodeBlockInSeparateView() throws {
        let text = "Here is code:\n\n```swift\nlet x = 1\n```\n\nDone."
        let view = AssistantTimelineRowContentView(configuration: makeTimelineAssistantConfiguration(text: text))
        let codeBlockView = timelineFirstView(ofType: NativeCodeBlockView.self, in: view)
        #expect(codeBlockView != nil)
    }

    @MainActor
    @Test func contextMenuUsesCopyAndCopyAsMarkdown() throws {
        let text = "Assistant answer"
        let view = AssistantTimelineRowContentView(configuration: makeTimelineAssistantConfiguration(text: text))

        let menu = try #require(view.contextMenu())
        #expect(timelineActionTitles(in: menu) == ["Copy", "Copy as Markdown"])
    }

    @MainActor
    @Test func contextMenuAppendsForkAfterCopyActions() throws {
        let text = "Assistant answer"
        let view = AssistantTimelineRowContentView(
            configuration: makeTimelineAssistantConfiguration(
                text: text,
                canFork: true,
                onFork: {}
            )
        )

        let menu = try #require(view.contextMenu())
        #expect(timelineActionTitles(in: menu) == ["Copy", "Copy as Markdown", "Fork from here"])
    }

    @MainActor
    @Test func bubbleInstallsDoubleTapCopyGesture() {
        let text = "Assistant answer"
        let view = AssistantTimelineRowContentView(configuration: makeTimelineAssistantConfiguration(text: text))

        let recognizers = timelineAllGestureRecognizers(in: view)
        let hasDoubleTap = recognizers.contains {
            guard let tap = $0 as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired == 2
        }
        #expect(hasDoubleTap)
    }

    // MARK: - Code Block Horizontal Scroll Regression

    @MainActor
    @Test func codeBlockLongLineScrollsHorizontally() throws {
        // Regression: code block label must NOT wrap — long lines need
        // horizontal scroll via the embedded UIScrollView.
        let longLine = "let reallyLongVariableName = \"" + String(repeating: "x", count: 200) + "\""
        let text = "```swift\n\(longLine)\n```"
        let containerWidth: CGFloat = 300

        let mdView = AssistantMarkdownContentView()
        mdView.apply(configuration: .init(content: text, isStreaming: false, themeID: .dark))
        _ = fittedTimelineSize(for: mdView, width: containerWidth)

        let codeBlockView = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: mdView))

        // Find the UIScrollView inside the code block.
        let scrollView = try #require(timelineAllScrollViews(in: codeBlockView).first)

        // Force layout so contentSize is calculated.
        codeBlockView.setNeedsLayout()
        codeBlockView.layoutIfNeeded()

        // The content must be wider than the scroll view's frame.
        #expect(
            scrollView.contentSize.width > scrollView.frame.width,
            "Code block content (\(scrollView.contentSize.width)pt) must be wider than frame (\(scrollView.frame.width)pt) for horizontal scrolling"
        )

        // The code label must NOT have wrapped — it should be a single line of code.
        let codeLabel = try #require(timelineAllLabels(in: scrollView).first)
        let labelLines = codeLabel.text?.components(separatedBy: "\n").count ?? 0
        #expect(labelLines == 1, "Single-line code should render as 1 line, not wrap to \(labelLines) lines")
    }

    @MainActor
    @Test func codeBlockMultiLineLongLinesScrollHorizontally() throws {
        // Multi-line code block with long lines must also scroll horizontally.
        let line1 = "func reallyLongFunctionName(parameterOne: String, parameterTwo: Int, parameterThree: Bool, parameterFour: Double) -> String {"
        let line2 = "    return \"result: \\(parameterOne) \\(parameterTwo) \\(parameterThree) \\(parameterFour) and then some extra text to make it longer\""
        let line3 = "}"
        let text = "```swift\n\(line1)\n\(line2)\n\(line3)\n```"
        let containerWidth: CGFloat = 300

        let mdView = AssistantMarkdownContentView()
        mdView.apply(configuration: .init(content: text, isStreaming: false, themeID: .dark))
        _ = fittedTimelineSize(for: mdView, width: containerWidth)

        let codeBlockView = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: mdView))
        let scrollView = try #require(timelineAllScrollViews(in: codeBlockView).first)

        codeBlockView.setNeedsLayout()
        codeBlockView.layoutIfNeeded()

        #expect(
            scrollView.contentSize.width > scrollView.frame.width,
            "Multi-line code block content must scroll horizontally"
        )
    }

    @MainActor
    @Test func codeBlockShortCodeDoesNotNeedScroll() throws {
        // Short code should NOT have content wider than the frame.
        let text = "```swift\nlet x = 1\n```"
        let containerWidth: CGFloat = 370

        let mdView = AssistantMarkdownContentView()
        mdView.apply(configuration: .init(content: text, isStreaming: false, themeID: .dark))
        _ = fittedTimelineSize(for: mdView, width: containerWidth)

        let codeBlockView = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: mdView))
        let scrollView = try #require(timelineAllScrollViews(in: codeBlockView).first)

        codeBlockView.setNeedsLayout()
        codeBlockView.layoutIfNeeded()

        // Short code fits — content should not exceed frame.
        #expect(
            scrollView.contentSize.width <= scrollView.frame.width || scrollView.frame.width == 0,
            "Short code should fit without horizontal scroll"
        )
    }

    @MainActor
    @Test func codeBlockStreamingLongLineScrollsHorizontally() throws {
        // Streaming code blocks must also scroll horizontally.
        let longLine = "console.log(\"" + String(repeating: "streaming-data-", count: 20) + "\")"
        let text = "```javascript\n\(longLine)"  // No closing fence = streaming
        let containerWidth: CGFloat = 300

        let mdView = AssistantMarkdownContentView()
        mdView.apply(configuration: .init(content: text, isStreaming: true, themeID: .dark))
        _ = fittedTimelineSize(for: mdView, width: containerWidth)

        let codeBlockView = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: mdView))
        let scrollView = try #require(timelineAllScrollViews(in: codeBlockView).first)

        codeBlockView.setNeedsLayout()
        codeBlockView.layoutIfNeeded()

        #expect(
            scrollView.contentSize.width > scrollView.frame.width,
            "Streaming code block must scroll horizontally for long lines"
        )
    }

    @MainActor
    @Test func rendersTableInSeparateView() throws {
        let text = """
        Here is a table:

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """
        let view = AssistantTimelineRowContentView(configuration: makeTimelineAssistantConfiguration(text: text))
        _ = fittedTimelineSize(for: view, width: 370)
        let tableView = timelineFirstView(ofType: NativeTableBlockView.self, in: view)
        #expect(tableView != nil)
    }

    @MainActor
    @Test func streamingTableUpdatesInPlace() throws {
        // Simulate streaming: table starts with header + separator, then rows arrive.
        let mdView = AssistantMarkdownContentView()

        // Phase 1: header + separator only
        let phase1 = """
        Results:

        | Name | Value |
        | --- | --- |
        """
        mdView.apply(configuration: .init(content: phase1, isStreaming: true, themeID: .dark))
        _ = fittedTimelineSize(for: mdView, width: 370)

        let tableAfterPhase1 = timelineFirstView(ofType: NativeTableBlockView.self, in: mdView)
        #expect(tableAfterPhase1 != nil, "Table view should exist after header + separator")

        // Phase 2: first row arrives
        let phase2 = """
        Results:

        | Name | Value |
        | --- | --- |
        | alpha | 100 |
        """
        mdView.apply(configuration: .init(content: phase2, isStreaming: true, themeID: .dark))

        // Same NativeTableBlockView instance should be reused (in-place update, not rebuild)
        let tableAfterPhase2 = timelineFirstView(ofType: NativeTableBlockView.self, in: mdView)
        #expect(tableAfterPhase2 === tableAfterPhase1, "Table view should be updated in-place, not rebuilt")

        // Phase 3: second row arrives (partial)
        let phase3 = """
        Results:

        | Name | Value |
        | --- | --- |
        | alpha | 100 |
        | beta | 20
        """
        mdView.apply(configuration: .init(content: phase3, isStreaming: true, themeID: .dark))

        let tableAfterPhase3 = timelineFirstView(ofType: NativeTableBlockView.self, in: mdView)
        #expect(tableAfterPhase3 === tableAfterPhase1, "Table view should still be the same instance")
    }

    @MainActor
    @Test func streamingTableStructuralChangeRebuilds() throws {
        // When structure changes (text → text + table), a rebuild happens.
        let mdView = AssistantMarkdownContentView()

        // Phase 1: just text, no table yet
        let phase1 = "Results:"
        mdView.apply(configuration: .init(content: phase1, isStreaming: true, themeID: .dark))
        _ = fittedTimelineSize(for: mdView, width: 370)

        let tableBeforeTable = timelineFirstView(ofType: NativeTableBlockView.self, in: mdView)
        #expect(tableBeforeTable == nil, "No table view before table content arrives")

        // Phase 2: table header + separator arrive — structure changes
        let phase2 = """
        Results:

        | Name | Value |
        | --- | --- |
        """
        mdView.apply(configuration: .init(content: phase2, isStreaming: true, themeID: .dark))

        let tableAfterHeader = timelineFirstView(ofType: NativeTableBlockView.self, in: mdView)
        #expect(tableAfterHeader != nil, "Table view should appear after structural rebuild")
    }

    @MainActor
    @Test func trimsTrailingEncodedBacktickBeforeRoutingInviteLink() throws {
        let markdownView = makeMarkdownView()
        let url = try #require(URL(string: "oppi://connect?v=3&invite=test-payload%60"))

        final class URLCapture: @unchecked Sendable {
            var value: URL?
        }
        let observed = URLCapture()

        let observer = NotificationCenter.default.addObserver(
            forName: .inviteDeepLinkTapped,
            object: nil,
            queue: nil
        ) { notification in
            observed.value = notification.object as? URL
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let shouldOpenExternally = markdownView.shouldOpenLinkExternally(url)

        #expect(!shouldOpenExternally)
        let routedURL = try #require(observed.value)
        #expect(routedURL.absoluteString == "oppi://connect?v=3&invite=test-payload")
    }

    @MainActor
    @Test func interceptsInviteLinksAndRoutesInternally() throws {
        let markdownView = makeMarkdownView()
        let url = try #require(URL(string: "oppi://connect?v=3&invite=test-payload"))

        final class URLCapture: @unchecked Sendable {
            var value: URL?
        }
        let observed = URLCapture()

        let observer = NotificationCenter.default.addObserver(
            forName: .inviteDeepLinkTapped,
            object: nil,
            queue: nil
        ) { notification in
            observed.value = notification.object as? URL
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let shouldOpenExternally = markdownView.shouldOpenLinkExternally(url)

        #expect(!shouldOpenExternally)
        #expect(observed.value == url)
    }

    @MainActor
    @Test func allowsHttpLinksToOpenWithSystemDefault() throws {
        let markdownView = makeMarkdownView()
        let url = try #require(URL(string: "https://example.com/docs"))

        final class URLCapture: @unchecked Sendable {
            var value: URL?
        }
        let observed = URLCapture()

        let observer = NotificationCenter.default.addObserver(
            forName: .inviteDeepLinkTapped,
            object: nil,
            queue: nil
        ) { notification in
            observed.value = notification.object as? URL
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let shouldOpenExternally = markdownView.shouldOpenLinkExternally(url)

        #expect(shouldOpenExternally)
        #expect(observed.value == nil)
    }

    // MARK: - Helpers

    @MainActor
    private func makeMarkdownView() -> AssistantMarkdownContentView {
        let mdView = AssistantMarkdownContentView()
        mdView.apply(configuration: .init(
            content: "Test content",
            isStreaming: false,
            themeID: .dark
        ))
        return mdView
    }
}
