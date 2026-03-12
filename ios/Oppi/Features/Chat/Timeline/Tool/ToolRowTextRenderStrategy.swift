import UIKit

@MainActor
struct ToolRowTextRenderStrategy {
    static func render(
        text: String,
        language: SyntaxLanguage?,
        isError: Bool,
        isStreaming: Bool,
        outputColor: UIColor,
        expandedLabel: UITextView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        wasExpandedVisible: Bool,
        isCurrentModeText: Bool,
        isUsingMarkdownLayout: Bool,
        isUsingReadMediaLayout: Bool,
        shouldAutoFollowOnFirstRender: Bool,
        showExpandedLabel: () -> Void,
        setModeText: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void,
        scheduleExpandedAutoScrollToBottomIfNeeded: () -> Void
    ) -> ToolRowRenderVisibility {
        let displayText = ToolTimelineRowRenderMetrics.displayOutputText(text)
        let signature = ToolTimelineRowRenderMetrics.textSignature(
            displayText: displayText,
            language: language,
            isError: isError,
            isStreaming: isStreaming
        )
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeText
            || isUsingMarkdownLayout
            || isUsingReadMediaLayout
            || (expandedLabel.attributedText == nil && expandedLabel.text == nil)
        let previousRenderedText = expandedRenderedText

        showExpandedLabel()
        if shouldRerender {
            let renderStartNs = ChatTimelinePerf.timestampNs()
            let tier = StreamingRenderPolicy.tier(
                isStreaming: isStreaming,
                contentKind: .plainText,
                byteCount: displayText.utf8.count,
                lineCount: 0
            )

            let presentation: ToolRowTextRenderer.ANSIOutputPresentation
            if tier == .cheap {
                presentation = ToolRowTextRenderer.ANSIOutputPresentation(
                    attributedText: nil,
                    plainText: ANSIParser.strip(displayText)
                )
            } else if let cached = ToolRowRenderCache.get(signature: signature) {
                presentation = ToolRowTextRenderer.ANSIOutputPresentation(
                    attributedText: cached,
                    plainText: nil
                )
            } else if let language, !isError {
                let p = ToolRowTextRenderer.makeSyntaxOutputPresentation(
                    displayText,
                    language: language
                )
                if let attr = p.attributedText {
                    ToolRowRenderCache.set(signature: signature, attributed: attr)
                }
                presentation = p
            } else {
                let p = ToolRowTextRenderer.makeANSIOutputPresentation(
                    displayText,
                    isError: isError
                )
                if let attr = p.attributedText {
                    ToolRowRenderCache.set(signature: signature, attributed: attr)
                }
                presentation = p
            }
            ChatTimelinePerf.recordRenderStrategy(
                mode: tier == .cheap ? "text.stream" : (language != nil ? "text.syntax" : "text.ansi"),
                durationMs: ChatTimelinePerf.elapsedMs(since: renderStartNs),
                inputBytes: displayText.utf8.count,
                language: language?.displayName
            )

            ToolRowTextRenderer.applyANSIOutputPresentation(
                presentation,
                to: expandedLabel,
                plainTextColor: outputColor
            )
            expandedRenderedText = presentation.attributedText?.string ?? presentation.plainText ?? ""
            expandedRenderSignature = signature
        }

        expandedLabel.textContainer.lineBreakMode = .byCharWrapping
        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        setModeText()
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()

        let isStreamingContinuation = previousRenderedText.map { !$0.isEmpty && displayText.hasPrefix($0) } ?? false

        if !wasExpandedVisible {
            expandedShouldAutoFollow = shouldAutoFollowOnFirstRender
        } else if shouldAutoFollowOnFirstRender,
                  shouldRerender,
                  !isStreamingContinuation {
            // Streaming but content isn't a continuation — cell reuse.
            expandedShouldAutoFollow = true
        } else if !shouldAutoFollowOnFirstRender {
            // Streaming finished — stop following.
            expandedShouldAutoFollow = false
        }

        if shouldRerender {
            if expandedShouldAutoFollow {
                scheduleExpandedAutoScrollToBottomIfNeeded()
            } else {
                ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
            }
        }

        return ToolRowRenderVisibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }
}
