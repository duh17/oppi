import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("ThinkingTimelineRowContentView")
struct ThinkingRowContentViewTests {
    @Test(arguments: [
        "See [App Store Connect](https://appstoreconnect.apple.com/business)",
        "See https://appstoreconnect.apple.com/business",
    ])
    func doneWebLinksAreInteractiveWithoutOwningVerticalPans(source: String) throws {
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: true, previewText: source, fullText: nil
        ))
        _ = fittedTimelineSize(for: view, width: 360)
        let textView = try #require(privateTextLabel(in: view))
        let scrollView = try #require(privateScrollView(in: view))
        var hasLink = false
        textView.attributedText.enumerateAttribute(.link, in: NSRange(location: 0, length: textView.attributedText.length)) { value, _, _ in
            if value != nil { hasLink = true }
        }
        #expect(hasLink || textView.dataDetectorTypes.contains(.link), "Bare URLs need the assistant's link detector if Foundation omits NSLink")
        #expect(textView.isSelectable, "UIKit requires selectable text for link taps")
        #expect(scrollView.isUserInteractionEnabled, "The link's ancestor must allow touches")
        #expect(!scrollView.isScrollEnabled)
        #expect(!textView.isScrollEnabled)
        #expect(!textView.gestureRecognizerShouldBegin(textView.panGestureRecognizer))
    }

    @Test(arguments: ["http://example.com/thinking", "https://example.com/thinking"])
    func doneWebLinkActionPostsNotification(urlString: String) throws {
        let url = testUnwrap(URL(string: urlString))
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: true, previewText: "See [details](\(urlString))", fullText: nil
        ))
        let textView = try #require(privateTextLabel(in: view))
        #expect(textView.delegate === view)
        #expect(view.responds(to: NSSelectorFromString("textView:primaryActionForTextItem:defaultAction:")))
        #expect(view.responds(to: NSSelectorFromString("textView:menuConfigurationForTextItem:defaultMenu:")))
        try expectContentWebLink(url) { defaultAction in
            view.primaryAction(for: url, defaultAction: defaultAction)
        }
    }

    @Test(arguments: ["mailto:thinking@example.com", "custom-thinking://item", "oppi://session/thinking"])
    func nonWebLinkActionKeepsSystemDefault(urlString: String) throws {
        let url = testUnwrap(URL(string: urlString))
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: true, previewText: "[Contact](\(urlString))", fullText: nil
        ))
        let defaultAction = UIAction { _ in }
        #expect(view.primaryAction(for: url, defaultAction: defaultAction) === defaultAction)
    }

    @Test func streamingOverflowKeepsInnerScrollDisabledAndAutoFollowsTail() throws {
        // Establish bounds first (mirrors real collection view lifecycle where
        // cells have valid frames before apply() runs on content updates).
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false, previewText: "seed", fullText: nil
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        // Now grow to overflow — apply() drives followTail synchronously.
        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: Array(repeating: "streaming thought line", count: 300).joined(separator: "\n"),
            fullText: nil
        )

        let scrollView = try #require(privateScrollView(in: view))
        #expect(!scrollView.isScrollEnabled)
        #expect(!scrollView.isUserInteractionEnabled)
        #expect(scrollView.contentOffset.y > 0, "Streaming overflow should tail-follow inside capped bubble")
    }

    @Test func streamingOverflowRespectsConfiguredBubbleCap() throws {
        let text = Array(repeating: "streaming thought line", count: 300).joined(separator: "\n")

        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: text,
            fullText: nil,
            maxBubbleHeight: ThinkingRowHeightPolicy.defaultMaxBubbleHeight
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        let bubbleHeight = try #require(privateBubbleHeightConstraintConstant(in: view))

        #expect(bubbleHeight == ThinkingRowHeightPolicy.defaultMaxBubbleHeight)
    }

    @Test func thinkingRowDoesNotInstallFloatingFullScreenButton() {
        let overflowConfig = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: Array(repeating: "reasoning", count: 320).joined(separator: "\n")
        )
        let shortConfig = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "Short thought",
            fullText: nil
        )

        let overflowView = ThinkingTimelineRowContentView(configuration: overflowConfig)
        _ = fittedTimelineSize(for: overflowView, width: 360)

        let shortView = ThinkingTimelineRowContentView(configuration: shortConfig)
        _ = fittedTimelineSize(for: shortView, width: 360)

        #expect(fullScreenButton(in: overflowView) == nil)
        #expect(fullScreenButton(in: shortView) == nil)
    }

    @Test func overflowContextMenuIncludesOpenFullScreenAndCopy() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: Array(repeating: "line", count: 320).joined(separator: "\n")
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        _ = try #require(privateBubbleView(in: view))
        let menu = try #require(view.contextMenuForTesting())

        #expect(timelineActionTitles(in: menu) == ["Open Full Screen", "Copy"])
    }

    @Test func overflowRegistersPinchAndDoubleTapGesturesButNoSingleTapActivation() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: Array(repeating: "line", count: 320).joined(separator: "\n")
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let bubbleView = try #require(privateBubbleView(in: view))
        let recognizers = bubbleView.gestureRecognizers ?? []
        let hasPinch = recognizers.contains { $0 is UIPinchGestureRecognizer }
        let hasDoubleTap = recognizers.contains {
            guard let tap = $0 as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired == 2
        }
        let hasSingleTap = recognizers.contains {
            guard let tap = $0 as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired == 1
        }

        #expect(hasPinch)
        #expect(hasDoubleTap)
        #expect(!hasSingleTap)
    }

    @Test func selectedTextEditMenuPrependsCommentAction() throws {
        let router = ReviewCommentSelectionRouter { _ in }
        let interactionCtx = TimelineInteractionContext()
        interactionCtx.reviewCommentSelectionRouter = router
        interactionCtx.sessionId = "session-1"
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: "Alpha beta gamma",
            interactionContext: interactionCtx
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        let copyAction = UIAction(title: "Copy") { _ in }
        let menu = try #require(view.textView(
            label,
            editMenuForTextIn: NSRange(location: 0, length: 5),
            suggestedActions: [copyAction]
        ))

        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
        let copyMenuAction = try #require(menu.children.dropFirst().first as? UIAction)
        #expect(copyMenuAction.title == "Copy")
    }

    @Test func customSourceLabelUpdatesAccessibilityWithoutVisibleHeader() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Analyzing the next step",
            fullText: nil,
            sourceLabel: "Private reasoning"
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        #expect(label.text == "Analyzing the next step")
        #expect(label.accessibilityLabel == "Private reasoning: Analyzing the next step")
        #expect(fullScreenButton(in: view) == nil)
    }

    @Test func selectedTextModeKeepsOverflowFullScreenGesturesAndDisablesInlineSelection() throws {
        let router = ReviewCommentSelectionRouter { _ in }
        let interactionCtx = TimelineInteractionContext()
        interactionCtx.reviewCommentSelectionRouter = router
        interactionCtx.sessionId = "session-1"
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: Array(repeating: "line", count: 320).joined(separator: "\n"),
            interactionContext: interactionCtx
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let recognizers = timelineAllGestureRecognizers(in: view)
        let pinchGesture = try #require(recognizers.first { $0 is UIPinchGestureRecognizer })
        let doubleTapGesture = try #require(recognizers.first {
            guard let tap = $0 as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired == 2
        })

        #expect(pinchGesture.isEnabled)
        #expect(doubleTapGesture.isEnabled)

        let scrollView = try #require(privateScrollView(in: view))
        #expect(!scrollView.isUserInteractionEnabled)

        let label = try #require(privateTextLabel(in: view))
        #expect(!label.isSelectable)
        #expect(fullScreenButton(in: view) == nil)
    }

    @Test func selectedTextModeAllowsInlineSelectionWhenThinkingFitsBubble() throws {
        let router = ReviewCommentSelectionRouter { _ in }
        let interactionCtx = TimelineInteractionContext()
        interactionCtx.reviewCommentSelectionRouter = router
        interactionCtx.sessionId = "session-1"
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "Short thought",
            fullText: nil,
            interactionContext: interactionCtx
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        #expect(label.isSelectable)

        let recognizers = timelineAllGestureRecognizers(in: view)
        let pinchGesture = try #require(recognizers.first { $0 is UIPinchGestureRecognizer })
        let doubleTapGesture = try #require(recognizers.first {
            guard let tap = $0 as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired == 2
        })

        #expect(!pinchGesture.isEnabled)
        #expect(!doubleTapGesture.isEnabled)
    }

    // MARK: - Streaming plain text optimization

    @Test func streamingPreservesRawMarkdownSyntax() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Thinking about **bold** and `code`",
            fullText: nil
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
            fullText: "Thinking about **bold** and `code`"
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
            fullText: nil
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        let firstText = label.text

        let sig1 = try #require(privateRenderSignature(in: view))
        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Initial thought",
            fullText: nil
        )
        let sig2 = try #require(privateRenderSignature(in: view))
        #expect(sig1 == sig2, "Render signature should not change for identical content")
        #expect(label.text == firstText)
    }

    @Test func renderSignatureChangesWhenTextGrows() throws {
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Short",
            fullText: nil
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        let sig1 = try #require(privateRenderSignature(in: view))

        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Short thought that grew longer",
            fullText: nil
        )
        let sig2 = try #require(privateRenderSignature(in: view))
        #expect(sig1 != sig2, "Render signature should change when text changes")
    }

    @Test func unchangedDoneTextUpdatesColorWhenThemeChanges() throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }

        let configuration = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: "Same reasoning text"
        )

        ThemeRuntimeState.setThemeID(.dark)
        let view = ThinkingTimelineRowContentView(configuration: configuration)
        _ = fittedTimelineSize(for: view, width: 360)
        let label = try #require(privateTextLabel(in: view))
        let darkColor = try #require(foregroundColor(in: label))

        ThemeRuntimeState.setThemeID(.light)
        view.configuration = configuration
        let lightColor = try #require(foregroundColor(in: label))

        #expect(darkColor == UIColor(ThemePalettes.dark.fg).withAlphaComponent(0.94))
        #expect(lightColor == UIColor(ThemePalettes.light.fg).withAlphaComponent(0.94))
        #expect(darkColor != lightColor)
    }

    @Test func transitionFromStreamingToDoneRendersMarkdown() throws {
        let text = "Thinking about **bold** patterns"
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: text,
            fullText: nil
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
            fullText: text
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
            fullText: nil
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        #expect(
            label.text?.contains("**patterns**") == true,
            "Large streaming text must skip markdown parsing"
        )
    }

    @Test func largeCompletedThinkingRendersOnlyBoundedHeadAndOpensFullSource() throws {
        let source = "HEAD_SENTINEL\n"
            + String(repeating: "completed reasoning line\n", count: 6_000)
            + "TAIL_SENTINEL"
        var opened: ChatReaderPayload?
        var configuration = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: source,
            fullText: nil
        )
        configuration.openFullScreen = { opened = $0 }
        let view = ThinkingTimelineRowContentView(configuration: configuration)
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        let rendered = try #require(label.text)
        #expect(rendered.contains("HEAD_SENTINEL"))
        #expect(!rendered.contains("TAIL_SENTINEL"))
        #expect(rendered.utf8.count <= ThinkingTimelineRowContentView.renderWindowUTF8ByteLimit)
        #expect(view.copyableText?.hasSuffix("TAIL_SENTINEL") == true)

        view.showFullScreen()
        let payload = try #require(opened)
        guard case .document(let readerContent, _) = payload.kind,
              case .thinking(let fullSource, let stream) = readerContent else {
            Issue.record("Expected full-screen thinking payload")
            return
        }
        #expect(fullSource == source)
        #expect(stream?.snapshot.text == source)
    }

    @Test func largeStreamingThinkingRendersOnlyBoundedTail() throws {
        let source = "HEAD_SENTINEL\n"
            + String(repeating: "streaming reasoning line\n", count: 6_000)
            + "TAIL_SENTINEL"
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: source,
            fullText: nil
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        let label = try #require(privateTextLabel(in: view))
        let rendered = try #require(label.text)
        #expect(!rendered.contains("HEAD_SENTINEL"))
        #expect(rendered.contains("TAIL_SENTINEL"))
        #expect(rendered.utf8.count <= ThinkingTimelineRowContentView.renderWindowUTF8ByteLimit)
        #expect(view.copyableText?.hasPrefix("HEAD_SENTINEL") == true)
        #expect(view.contentIsTruncated)
        #expect(view.isShowingTailForTesting, "An initially large live row must open on its newest lines")
    }

    @Test func initialStreamingTailWaitsForNonzeroViewportHeight() {
        let source = String(repeating: "streaming reasoning line\n", count: 6_000) + "TAIL_SENTINEL"
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: source,
            fullText: nil
        ))

        view.frame = CGRect(x: 0, y: 0, width: 360, height: 0)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(privateNeedsStreamingTailFollow(in: view) == true)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: ThinkingRowHeightPolicy.defaultMaxBubbleHeight)
        for _ in 0..<2 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }

        #expect(view.contentIsTruncated)
        #expect(view.isShowingTailForTesting, "Tail follow must remain pending until the viewport has height")
    }

    @Test func completionSwitchesBoundedTailToBoundedHead() throws {
        let source = "HEAD_SENTINEL\n"
            + String(repeating: "reasoning line\n", count: 6_000)
            + "TAIL_SENTINEL"
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: source,
            fullText: nil
        ))
        _ = fittedTimelineSize(for: view, width: 360)
        let label = try #require(privateTextLabel(in: view))
        #expect(label.text?.contains("TAIL_SENTINEL") == true)
        #expect(label.text?.contains("HEAD_SENTINEL") == false)

        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: source,
            fullText: nil
        )
        _ = fittedTimelineSize(for: view, width: 360)

        #expect(label.text?.contains("HEAD_SENTINEL") == true)
        #expect(label.text?.contains("TAIL_SENTINEL") == false)
        #expect(view.copyableText == source)
    }

    @Test func boundedWindowKeepsUnicodeValid() throws {
        let source = "HEAD_SENTINEL\n"
            + String(repeating: "👩🏽‍💻思考", count: 2_000)
            + "\nTAIL_SENTINEL"
        let completed = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: source,
            fullText: nil
        ))
        let streaming = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: source,
            fullText: nil
        ))
        _ = fittedTimelineSize(for: completed, width: 360)
        _ = fittedTimelineSize(for: streaming, width: 360)

        let completedText = try #require(privateTextLabel(in: completed)?.text)
        let streamingText = try #require(privateTextLabel(in: streaming)?.text)
        #expect(!completedText.contains("�"))
        #expect(!streamingText.contains("�"))
        #expect(completedText.utf8.count <= ThinkingTimelineRowContentView.renderWindowUTF8ByteLimit)
        #expect(streamingText.utf8.count <= ThinkingTimelineRowContentView.renderWindowUTF8ByteLimit)
        #expect(streamingText.contains("TAIL_SENTINEL"))
    }

    @Test func omittedSourceStillOffersFullScreenWhenRenderedWindowFits() throws {
        let source = String(repeating: "bounded reasoning line\n", count: 2_000)
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: source,
            fullText: nil,
            maxBubbleHeight: 100_000
        ))
        _ = fittedTimelineSize(for: view, width: 360)

        #expect(!view.contentIsTruncated)
        #expect(view.contextMenuForTesting() != nil)
    }

    @Test func repeatedFittingReusesBoundedTextMeasurement() {
        let source = String(repeating: "reasoning line\n", count: 6_000)
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: source,
            fullText: nil
        ))

        _ = fittedTimelineSize(for: view, width: 360)
        let firstPassCount = view.measurementPassCountForTesting
        _ = fittedTimelineSize(for: view, width: 360)
        view.layoutIfNeeded()
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.measurementPassCountForTesting == firstPassCount)

        _ = fittedTimelineSize(for: view, width: 320)
        #expect(view.measurementPassCountForTesting == firstPassCount + 1)
    }

    @Test func sameLengthEditInsideBoundedWindowRepaints() throws {
        let prefix = String(repeating: "x", count: 1_000)
        let suffix = String(repeating: "y", count: 6_000)
        let original = prefix + "AAAA" + suffix
        let updated = prefix + "BBBB" + suffix
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: original,
            fullText: nil
        ))
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(privateTextLabel(in: view)?.text?.contains("AAAA") == true)

        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: updated,
            fullText: nil
        )
        _ = fittedTimelineSize(for: view, width: 360)

        let rendered = try #require(privateTextLabel(in: view)?.text)
        #expect(!rendered.contains("AAAA"))
        #expect(rendered.contains("BBBB"))
    }
}

@MainActor
@Suite("User-content browser link routing")
struct UserContentBrowserLinkRoutingTests {
    @Test(arguments: ["https://example.com/user-content", "mailto:user@example.com"])
    func userMarkdownUsesBrowserRoutingOrSystemDefault(urlString: String) throws {
        let url = testUnwrap(URL(string: urlString))
        let context = TimelineInteractionContext()
        context.sessionId = "session-1"
        context.reviewCommentSelectionRouter = ReviewCommentSelectionRouter { _ in }
        let view = UserTimelineRowContentView(configuration: UserTimelineRowConfiguration(
            text: "[Link](\(urlString))", images: [], canFork: false, onFork: nil,
            interactionContext: context
        ))
        let textView = try #require(timelineAllTextViews(in: view).first)
        #expect(textView.delegate === view)
        #expect(textView.isSelectable)
        if url.scheme == "mailto" {
            let defaultAction = UIAction { _ in }
            #expect(view.primaryAction(for: url, defaultAction: defaultAction) === defaultAction)
        } else {
            try expectContentWebLink(url) { view.primaryAction(for: url, defaultAction: $0) }
        }
    }

    @Test(arguments: [false, true])
    func fullScreenWebLinkFallsThroughUnhandledReaderIntercept(installed: Bool) throws {
        let url = testUnwrap(URL(string: "https://example.com/reader"))
        let body = makeReader()
        let textView = UITextView()
        body.addSubview(textView)
        var intercepted = false
        if installed {
            ChatReaderLinkIntercept.install({ action in
                #expect(action == .webLink(url))
                intercepted = true
                return false
            }, on: body)
        }
        try expectContentWebLink(url) {
            body.primaryAction(for: url, from: textView, defaultAction: $0)
        }
        #expect(intercepted == installed)
    }

    @Test func fullScreenHandledLinkDoesNotAlsoPostWebLink() throws {
        let url = testUnwrap(URL(string: "https://example.com/handled-reader"))
        let body = makeReader()
        let textView = UITextView()
        body.addSubview(textView)
        var intercepted = false
        ChatReaderLinkIntercept.install({ _ in intercepted = true; return true }, on: body)
        var posted = false
        let observer = NotificationCenter.default.addObserver(forName: .webLinkTapped, object: nil, queue: .main) {
            if $0.object as? URL == url { posted = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var defaultUsed = false
        let action = try #require(body.primaryAction(
            for: url, from: textView, defaultAction: UIAction { _ in defaultUsed = true }
        ))
        action.performWithSender(nil, target: nil)
        #expect(intercepted)
        #expect(!posted)
        #expect(!defaultUsed)
    }

    @Test func fullScreenUnhandledMailtoKeepsSystemDefault() throws {
        let body = makeReader()
        let textView = UITextView()
        body.addSubview(textView)
        ChatReaderLinkIntercept.install({ _ in false }, on: body)
        let url = testUnwrap(URL(string: "mailto:reader@example.com"))
        var defaultUsed = false
        let action = try #require(body.primaryAction(
            for: url, from: textView, defaultAction: UIAction { _ in defaultUsed = true }
        ))
        action.performWithSender(nil, target: nil)
        #expect(defaultUsed)
    }

    @Test func assistantUnhandledExtensionWebLinkUsesBrowserRouting() throws {
        let url = testUnwrap(URL(string: "https://example.com/extension-markdown"))
        let view = AssistantMarkdownContentView()
        var hostCalled = false
        view.linkOpenHandler = { _ in hostCalled = true; return false }
        try expectContentWebLink(url) { view.primaryAction(for: url, defaultAction: $0) }
        #expect(hostCalled)
    }

    private func makeReader() -> NativeFullScreenMarkdownBody {
        NativeFullScreenMarkdownBody(
            content: "[Link](https://example.com/reader)", palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil
        )
    }
}

@MainActor
private func expectContentWebLink(_ url: URL, action: (UIAction) -> UIAction?) throws {
    var received: [URL] = []
    let observer = NotificationCenter.default.addObserver(forName: .webLinkTapped, object: nil, queue: .main) {
        if $0.object as? URL == url { received.append(url) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    var defaultUsed = false
    let routed = try #require(action(UIAction { _ in defaultUsed = true }))
    routed.performWithSender(nil, target: nil)
    #expect(received == [url])
    #expect(!defaultUsed)
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
private func privateTextLabel(in view: ThinkingTimelineRowContentView) -> UITextView? {
    Mirror(reflecting: view).children.first { $0.label == "textLabel" }?.value as? UITextView
}

@MainActor
private func privateNeedsStreamingTailFollow(in view: ThinkingTimelineRowContentView) -> Bool? {
    Mirror(reflecting: view).children.first { $0.label == "needsStreamingTailFollow" }?.value as? Bool
}

@MainActor
private func privateRenderSignature(in view: ThinkingTimelineRowContentView) -> Int? {
    Mirror(reflecting: view).children.first { $0.label == "renderSignature" }?.value as? Int
}

@MainActor
private func foregroundColor(in textView: UITextView) -> UIColor? {
    guard let attributedText = textView.attributedText, attributedText.length > 0 else { return nil }
    return attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
}

@MainActor
private func privateBubbleHeightConstraintConstant(in view: ThinkingTimelineRowContentView) -> CGFloat? {
    (Mirror(reflecting: view).children.first { $0.label == "bubbleHeightConstraint" }?.value as? NSLayoutConstraint)?.constant
}

@MainActor
private func fullScreenButton(in view: ThinkingTimelineRowContentView) -> UIButton? {
    timelineAllViews(in: view)
        .compactMap { $0 as? UIButton }
        .first { $0.accessibilityIdentifier == "thinking.expand-full-screen" }
}
