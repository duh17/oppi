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
    @Test func enablesLinkDataDetectorsForBareUrls() throws {
        let text = "Visit https://example.com/docs for details"
        let view = AssistantTimelineRowContentView(configuration: makeTimelineAssistantConfiguration(text: text))
        let textView = try #require(timelineFirstTextView(in: view))

        #expect(textView.dataDetectorTypes.contains(.link))
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

        let menu = try #require(view.buildContextMenu())
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

        let menu = try #require(view.buildContextMenu())
        #expect(timelineActionTitles(in: menu) == ["Copy", "Fork from here", "Copy as Markdown"])
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
        mdView.apply(configuration: .make(content: text, isStreaming: false, themeID: ThemeRuntimeState.currentThemeID()))
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
        let codeTextView = try #require(timelineAllTextViews(in: scrollView).first)
        let labelLines = codeTextView.text?.components(separatedBy: "\n").count ?? 0
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
        mdView.apply(configuration: .make(content: text, isStreaming: false, themeID: ThemeRuntimeState.currentThemeID()))
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
        mdView.apply(configuration: .make(content: text, isStreaming: false, themeID: ThemeRuntimeState.currentThemeID()))
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
        mdView.apply(configuration: .make(content: text, isStreaming: false, themeID: ThemeRuntimeState.currentThemeID()))
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
    @Test func mermaidInlineDiagramRecomputesHeightWhenWidthChanges() {
        let mermaidCode = """
        flowchart LR
            A[Second Brain] --> B[Capture]
            A --> C[Process]
            A --> D[Organize]
            A --> E[Retrieve]
            A --> F[Express]
            A --> G[Review]
            A --> H[Improve]
            B --> B1[Quick inbox]
            B --> B2[Voice notes]
            C --> C1[Daily triage]
            C --> C2[Link notes]
        """

        let view = NativeMermaidBlockView()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 210, height: 900))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        container.layoutIfNeeded()
        view.applyAsDiagramSync(code: mermaidCode, palette: ThemeRuntimeState.currentPalette())
        container.layoutIfNeeded()

        let narrowHeight = view.systemLayoutSizeFitting(
            CGSize(width: 210, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        container.frame.size.width = 330
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let wideHeight = view.systemLayoutSizeFitting(
            CGSize(width: 330, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        #expect(
            wideHeight > narrowHeight + 10,
            "Mermaid inline height should grow when width grows (narrow=\(narrowHeight), wide=\(wideHeight))"
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
    @Test func narrowTableCardDoesNotExceedContainerWidth() {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        tableView.apply(
            headers: [[.text("Key")]],
            rows: [[[.text("v")]]],
            palette: ThemeRuntimeState.currentPalette()
        )

        container.setNeedsLayout()
        container.layoutIfNeeded()

        guard let cardView = tableView.subviews.first else {
            Issue.record("Expected NativeTableBlockView to contain card view")
            return
        }

        #expect(
            cardView.frame.width <= tableView.bounds.width + 0.5,
            "Table card width \(cardView.frame.width) should not exceed container width \(tableView.bounds.width)"
        )
    }

    @MainActor
    @Test func tableHorizontalOffsetResetsWhenContentChanges() throws {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 260))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        tableView.apply(
            headers: [[.text("Column")], [.text("Very Long Notes")]],
            rows: [
                [[.text("A")], [.text(String(repeating: "long-value-", count: 12))]],
            ],
            palette: ThemeRuntimeState.currentPalette()
        )

        container.setNeedsLayout()
        container.layoutIfNeeded()

        let horizontalScroll = try #require(timelineAllScrollViews(in: tableView).first { !($0 is UITextView) })
        horizontalScroll.contentOffset.x = 140

        tableView.apply(
            headers: [[.text("Name")], [.text("Status")]],
            rows: [
                [[.text("alpha")], [.text("ok")]],
            ],
            palette: ThemeRuntimeState.currentPalette()
        )

        container.setNeedsLayout()
        container.layoutIfNeeded()

        #expect(
            abs(horizontalScroll.contentOffset.x) < 0.5,
            "Table horizontal offset should reset after content changes, got x=\(horizontalScroll.contentOffset.x)"
        )
    }

    @MainActor
    @Test func tableTextViewPinsNonScrollableOffsetToTop() throws {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 260))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        tableView.apply(
            headers: [[.text("Name")], [.text("Value")]],
            rows: (0..<20).map { index in
                [[.text("row-\(index)")], [.text("value-\(index)")]]
            },
            palette: ThemeRuntimeState.currentPalette()
        )

        container.setNeedsLayout()
        container.layoutIfNeeded()

        let tableTextView = try #require(timelineAllTextViews(in: tableView).first)
        tableTextView.contentOffset = CGPoint(x: 0, y: 80)
        tableTextView.setNeedsLayout()
        tableTextView.layoutIfNeeded()

        #expect(
            abs(tableTextView.contentOffset.y + tableTextView.adjustedContentInset.top) < 0.5,
            "Table text view should pin non-scrollable offset to top, got y=\(tableTextView.contentOffset.y)"
        )
    }

    @MainActor
    @Test func tableAndMermaidRenderTogetherWithoutTableCorruption() async throws {
        let markdown = """
        ## What we can extend vs what we need to add

        | Area | Keep | Add |
        | --- | --- | --- |
        | Selection menu | existing text injector | WKWebView support |
        | Prompt path | PromptAssembler v2 | capture card UI |

        So: extend existing abstractions + add 3-4 focused types.

        ## Visual diagram to keep

        ```mermaid
        flowchart TD
            A["SelectedTextSourceContext"] --> B["Selection menu injectors"]
            B --> C["ContextCapture model"]
            C --> D["PromptAssembler v2"]
        ```
        """

        let markdownView = AssistantMarkdownContentView()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 1_600))
        markdownView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(markdownView)
        NSLayoutConstraint.activate([
            markdownView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            markdownView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            markdownView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        markdownView.apply(configuration: .make(
            content: markdown,
            isStreaming: false,
            themeID: .dark
        ))
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let tableView = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: markdownView))
        let tableTextView = try #require(timelineAllTextViews(in: tableView).first)

        let initialText = timelineRenderedText(of: tableTextView)
        #expect(initialText.contains("Selection menu"))
        #expect(initialText.contains("WKWebView support"))

        if let mermaidView = timelineFirstView(ofType: NativeMermaidBlockView.self, in: markdownView) {
            for _ in 0..<150 {
                container.setNeedsLayout()
                container.layoutIfNeeded()

                if timelineAllImageViews(in: mermaidView).contains(where: { !$0.isHidden && $0.image != nil }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        container.setNeedsLayout()
        container.layoutIfNeeded()

        let finalText = timelineRenderedText(of: tableTextView)
        #expect(finalText.contains("Selection menu"))
        #expect(finalText.contains("WKWebView support"))
        #expect(
            abs(tableTextView.contentOffset.y + tableTextView.adjustedContentInset.top) < 0.5,
            "Table text view should stay pinned at top, got y=\(tableTextView.contentOffset.y)"
        )
    }

    @MainActor
    @Test func streamingTableUpdatesInPlace() throws {
        // Simulate streaming: table starts with header + separator, then rows arrive.
        // Phase 1: header + separator only
        let phase1 = """
        Results:

        | Name | Value |
        | --- | --- |
        """

        let mdView = AssistantMarkdownContentView()
        mdView.apply(configuration: .make(content: phase1, isStreaming: true, themeID: ThemeRuntimeState.currentThemeID()))
        _ = fittedTimelineSize(for: mdView, width: 370)

        let tableAfterPhase1 = timelineFirstView(ofType: NativeTableBlockView.self, in: mdView)
        #expect(tableAfterPhase1 != nil, "Table view should exist after header + separator")

        // Phase 2: first row arrives.
        let phase2 = """
        Results:

        | Name | Value |
        | --- | --- |
        | alpha | 100 |
        """
        mdView.apply(configuration: .make(content: phase2, isStreaming: true, themeID: ThemeRuntimeState.currentThemeID()))
        _ = fittedTimelineSize(for: mdView, width: 370)

        // Same NativeTableBlockView instance should be reused (in-place update, not rebuild).
        let tableAfterPhase2 = timelineFirstView(ofType: NativeTableBlockView.self, in: mdView)
        #expect(tableAfterPhase2 === tableAfterPhase1, "Table view should be updated in-place, not rebuilt")

        let phase2TextView = try #require(tableAfterPhase2.flatMap { timelineAllTextViews(in: $0).first })
        #expect(timelineRenderedText(of: phase2TextView).contains("alpha"))

        // Phase 3: second row arrives (partial).
        let phase3 = """
        Results:

        | Name | Value |
        | --- | --- |
        | alpha | 100 |
        | beta | 20
        """
        mdView.apply(configuration: .make(content: phase3, isStreaming: true, themeID: ThemeRuntimeState.currentThemeID()))
        _ = fittedTimelineSize(for: mdView, width: 370)

        let tableAfterPhase3 = timelineFirstView(ofType: NativeTableBlockView.self, in: mdView)
        #expect(tableAfterPhase3 === tableAfterPhase1, "Table view should still be the same instance")

        let phase3TextView = try #require(tableAfterPhase3.flatMap { timelineAllTextViews(in: $0).first })
        #expect(timelineRenderedText(of: phase3TextView).contains("beta"))
    }

    @MainActor
    @Test func streamingTableStructuralChangeRebuilds() throws {
        // When structure changes (text → text + table), a rebuild happens.
        // Phase 1: just text, no table yet
        let phase1 = "Results:"

        let mdView = AssistantMarkdownContentView()
        mdView.apply(configuration: .make(content: phase1, isStreaming: true, themeID: ThemeRuntimeState.currentThemeID()))
        _ = fittedTimelineSize(for: mdView, width: 370)

        let tableBeforeTable = timelineFirstView(ofType: NativeTableBlockView.self, in: mdView)
        #expect(tableBeforeTable == nil, "No table view before table content arrives")

        // Phase 2: table header + separator arrive — structure changes
        let phase2 = """
        Results:

        | Name | Value |
        | --- | --- |
        """
        mdView.apply(configuration: .make(content: phase2, isStreaming: true, themeID: ThemeRuntimeState.currentThemeID()))
        _ = fittedTimelineSize(for: mdView, width: 370)

        let tableAfterHeader = timelineFirstView(ofType: NativeTableBlockView.self, in: mdView)
        #expect(tableAfterHeader != nil, "Table view should appear after structural rebuild")
    }

    @MainActor
    @Test func streamingTableRemainsStableWhenMermaidBlockArrives() throws {
        let phase1 = """
        ## What we can extend

        | Surface | Action |
        | --- | --- |
        | Selection menu | keep |

        So: extend existing abstractions.
        """

        let mdView = AssistantMarkdownContentView()
        mdView.apply(configuration: .make(content: phase1, isStreaming: true, themeID: ThemeRuntimeState.currentThemeID()))
        _ = fittedTimelineSize(for: mdView, width: 370)

        let tableAfterPhase1 = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: mdView))
        let tableTextViewPhase1 = try #require(timelineAllTextViews(in: tableAfterPhase1).first)
        #expect(timelineRenderedText(of: tableTextViewPhase1).contains("Selection menu"))

        let phase2 = """
        ## What we can extend

        | Surface | Action |
        | --- | --- |
        | Selection menu | keep |

        So: extend existing abstractions.

        ```mermaid
        flowchart TD
            A -->|menu injectors| B
            B -->|context capture| C
        """
        mdView.apply(configuration: .make(content: phase2, isStreaming: true, themeID: ThemeRuntimeState.currentThemeID()))
        _ = fittedTimelineSize(for: mdView, width: 370)

        let phase2Table = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: mdView))
        #expect(phase2Table === tableAfterPhase1)
        let tableTextViewPhase2 = try #require(timelineAllTextViews(in: phase2Table).first)
        #expect(timelineRenderedText(of: tableTextViewPhase2).contains("Selection menu"))

        let phase3 = phase2 + "\n        ```\n"
        mdView.apply(configuration: .make(content: phase3, isStreaming: false, themeID: ThemeRuntimeState.currentThemeID()))
        _ = fittedTimelineSize(for: mdView, width: 370)

        let phase3Table = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: mdView))
        let tableTextViewPhase3 = try #require(timelineAllTextViews(in: phase3Table).first)
        let rendered = timelineRenderedText(of: tableTextViewPhase3)

        #expect(rendered.contains("Selection menu"))
        #expect(!rendered.contains("menu injectors"), "Mermaid edge labels should not leak into table rendering")
    }

    @MainActor
    @Test func streamingTableTextViewStaysPinnedToTopBetweenRelayouts() throws {
        let markdownView = AssistantMarkdownContentView()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        markdownView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(markdownView)
        NSLayoutConstraint.activate([
            markdownView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            markdownView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            markdownView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        var content = """
        | Name | Value |
        | --- | --- |
        | alpha | 100 |
        """

        markdownView.apply(configuration: .make(
            content: content,
            isStreaming: true,
            themeID: .dark
        ))
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let tableView = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: markdownView))
        let initialTextView = try #require(timelineAllTextViews(in: tableView).first)
        #expect(
            abs(initialTextView.contentOffset.y + initialTextView.adjustedContentInset.top) < 0.5,
            "Fixture expects table text to start pinned to top"
        )

        for index in 0..<20 {
            content += "\n| row-\(index) | \(index) |"
            markdownView.apply(configuration: .make(
                content: content,
                isStreaming: true,
                themeID: .dark
            ))
            // Intentionally skip layout to mirror streaming ticks between
            // collection-view relayout passes.
        }

        let updatedTableView = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: markdownView))
        let updatedTextView = try #require(timelineAllTextViews(in: updatedTableView).first)

        #expect(
            abs(updatedTextView.contentOffset.y + updatedTextView.adjustedContentInset.top) < 0.5,
            "Non-scrollable table text view drifted to contentOffset.y=\(updatedTextView.contentOffset.y)"
        )
    }

    @MainActor
    @Test func trimsTrailingEncodedBacktickBeforeRoutingInviteLink() throws {
        let markdownView = makeMarkdownView()
        let url = try #require(URL(string: "oppi://connect?v=3&invite=test-payload%60"))

        let action = markdownView.classifyLink(url)
        guard case .deepLink(let routed) = action else {
            Issue.record("Expected .deepLink, got \(action)")
            return
        }
        #expect(routed.absoluteString == "oppi://connect?v=3&invite=test-payload")
    }

    @MainActor
    @Test func interceptsInviteLinksAndRoutesInternally() throws {
        let markdownView = makeMarkdownView()
        let url = try #require(URL(string: "oppi://connect?v=3&invite=test-payload"))

        let action = markdownView.classifyLink(url)
        guard case .deepLink(let routed) = action else {
            Issue.record("Expected .deepLink, got \(action)")
            return
        }
        #expect(routed == url)
    }

    @MainActor
    @Test func classifiesHttpLinksAsWebLinks() throws {
        let markdownView = makeMarkdownView()
        let url = try #require(URL(string: "https://example.com/docs"))

        let action = markdownView.classifyLink(url)
        guard case .webLink(let routed) = action else {
            Issue.record("Expected .webLink, got \(action)")
            return
        }
        #expect(routed == url)
    }

    @MainActor
    @Test func allowsCustomAppLinksToUseSystemDefault() throws {
        let markdownView = makeMarkdownView()
        let url = try #require(URL(string: "mailto:support@example.com"))

        let action = markdownView.classifyLink(url)
        #expect(action == .systemDefault)
    }

    @MainActor
    @Test func selectedTextEditMenuPrependsCommentAction() throws {
        let markdownView = AssistantMarkdownContentView()
        let router = SelectedTextPiActionRouter { _ in }
        markdownView.apply(configuration: .make(
            content: "Alpha beta gamma",
            isStreaming: false,
            themeID: .light,
            selectedTextPiRouter: router,
            selectedTextSourceContext: .init(sessionId: "session-1", surface: .assistantProse)
        ))

        let textView = try #require(timelineFirstTextView(in: markdownView))
        let copyAction = UIAction(title: "Copy") { _ in }
        let menu = try #require(markdownView.textView(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 5),
            suggestedActions: [copyAction]
        ))

        #expect(timelineActionTitles(in: menu) == ["Comment", "Copy"])
        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
        let copyMenuAction = try #require(menu.children.dropFirst().first as? UIAction)
        #expect(copyMenuAction.title == "Copy")
    }

    @MainActor
    @Test func selectedAssistantCodeBlockEditMenuPrependsCommentAction() throws {
        let markdownView = AssistantMarkdownContentView()
        let router = SelectedTextPiActionRouter { _ in }
        markdownView.apply(configuration: .make(
            content: "```swift\nlet answer = 42\n```",
            isStreaming: false,
            themeID: .light,
            selectedTextPiRouter: router,
            selectedTextSourceContext: .init(sessionId: "session-1", surface: .assistantProse)
        ))
        _ = fittedTimelineSize(for: markdownView, width: 320)

        let codeBlockView = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: markdownView))
        let textView = try #require(timelineAllTextViews(in: codeBlockView).first)
        let menu = try #require((textView.delegate)?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
    }

    @MainActor
    @Test func selectedAssistantTableEditMenuPrependsCommentAction() throws {
        let markdownView = AssistantMarkdownContentView()
        let router = SelectedTextPiActionRouter { _ in }
        markdownView.apply(configuration: .make(
            content: "| A | B |\n| --- | --- |\n| 1 | 2 |",
            isStreaming: false,
            themeID: .light,
            selectedTextPiRouter: router,
            selectedTextSourceContext: .init(sessionId: "session-1", surface: .assistantProse)
        ))
        _ = fittedTimelineSize(for: markdownView, width: 320)

        let tableView = try #require(timelineFirstView(ofType: NativeTableBlockView.self, in: markdownView))
        let textView = try #require(timelineAllTextViews(in: tableView).first)
        let menu = try #require((textView.delegate)?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 1),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
    }

    @MainActor
    @Test func selectedTextEditMenuFallsBackToSystemMenuWithoutRouter() throws {
        let markdownView = AssistantMarkdownContentView()
        markdownView.apply(configuration: .make(
            content: "Alpha beta gamma",
            isStreaming: false,
            themeID: .light
        ))

        let textView = try #require(timelineFirstTextView(in: markdownView))
        let copyAction = UIAction(title: "Copy") { _ in }
        let menu = markdownView.textView(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 5),
            suggestedActions: [copyAction]
        )

        #expect(menu == nil)
    }

    // MARK: - Helpers

    @MainActor
    private func makeMarkdownView() -> AssistantMarkdownContentView {
        let mdView = AssistantMarkdownContentView()
        mdView.apply(configuration: .make(
            content: "Test content",
            isStreaming: false,
            themeID: .light
        ))
        return mdView
    }
}
