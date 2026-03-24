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
        expandedScrollView _: UIScrollView,
        previousSignature: Int?,
        previousRenderedText: String?,
        previousAutoFollow: Bool,
        wasExpandedVisible: Bool,
        isCurrentModeText: Bool,
        isUsingMarkdownLayout: Bool,
        isUsingReadMediaLayout: Bool,
        sessionId: String? = nil
    ) -> ExpandedRenderOutput {
        let displayText = ToolTimelineRowRenderMetrics.displayOutputText(text)
        let signature = ToolTimelineRowRenderMetrics.textSignature(
            displayText: displayText,
            language: language,
            isError: isError,
            isStreaming: isStreaming
        )
        let shouldRerender = signature != previousSignature
            || !isCurrentModeText
            || isUsingMarkdownLayout
            || isUsingReadMediaLayout
            || (expandedLabel.attributedText == nil && expandedLabel.text == nil)

        var renderedText = previousRenderedText

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
                language: language?.displayName,
                sessionId: sessionId
            )

            ToolRowTextRenderer.applyANSIOutputPresentation(
                presentation,
                to: expandedLabel,
                plainTextColor: outputColor
            )
            renderedText = presentation.attributedText?.string ?? presentation.plainText ?? ""
        }

        let autoFollow = ToolTimelineRowUIHelpers.computeAutoFollow(
            isStreaming: isStreaming,
            shouldRerender: shouldRerender,
            wasExpandedVisible: wasExpandedVisible,
            previousRenderedText: previousRenderedText,
            currentDisplayText: displayText,
            currentAutoFollow: previousAutoFollow
        )

        let scrollBehavior: ExpandedRenderOutput.ScrollBehavior
        if shouldRerender {
            if autoFollow {
                scrollBehavior = .followTail
            } else if !isStreaming {
                scrollBehavior = .resetToTop
            } else {
                scrollBehavior = .preserve
            }
        } else {
            scrollBehavior = .preserve
        }

        return ExpandedRenderOutput(
            renderSignature: shouldRerender ? signature : previousSignature,
            renderedText: renderedText,
            shouldAutoFollow: autoFollow,
            surface: .label,
            viewportMode: .text,
            verticalLock: false,
            scrollBehavior: scrollBehavior,
            lineBreakMode: .byCharWrapping,
            horizontalScroll: false,
            deferredHighlight: nil,
            invalidateLayout: false,
            installAction: .none
        )
    }
}
