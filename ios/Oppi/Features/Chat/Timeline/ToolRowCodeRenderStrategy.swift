import SwiftUI
import UIKit

@MainActor
struct ToolRowCodeRenderStrategy: ToolTimelineRowExpandedRenderStrategy {
    static let mode: ToolTimelineRowExpandedRenderMode = .code

    /// Threshold in lines above which the first render is deferred to a background task.
    /// Below this, synchronous highlighting is fast enough (<16ms on A18).
    static let deferredHighlightLineThreshold = 100

    static func isApplicable(to input: ToolTimelineRowExpandedRenderInput) -> Bool {
        if case .code = input.expandedContent {
            return true
        }
        return false
    }

    /// Result of a render call. `deferredHighlight` is non-nil when the strategy
    /// showed plain text and needs the caller to schedule async highlighting.
    struct RenderResult {
        let visibility: ToolTimelineRowExpandedRenderer.Visibility
        let deferredHighlight: DeferredHighlight?
    }

    struct DeferredHighlight: Sendable {
        let text: String
        let language: SyntaxLanguage
        let startLine: Int
        let signature: Int
    }

    static func render(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int?,
        isStreaming: Bool,
        expandedLabel: UITextView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        isCurrentModeCode: Bool,
        showExpandedLabel: () -> Void,
        setModeCode: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void
    ) -> RenderResult {
        let displayText = ToolTimelineRowRenderMetrics.displayOutputText(text)
        let resolvedStartLine = startLine ?? 1
        let signature = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: displayText,
            language: language,
            startLine: resolvedStartLine,
            isStreaming: isStreaming
        )
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeCode
            || expandedLabel.attributedText == nil

        var deferred: DeferredHighlight?

        showExpandedLabel()
        if shouldRerender {
            let renderStartNs = ChatTimelinePerf.timestampNs()
            if isStreaming {
                expandedLabel.attributedText = nil
                expandedLabel.text = displayText
                expandedLabel.textColor = UIColor(.themeFg)
                expandedLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            } else if let cached = ToolRowRenderCache.get(signature: signature) {
                expandedLabel.text = nil
                expandedLabel.attributedText = cached
            } else {
                let lineCount = displayText.split(separator: "\n", omittingEmptySubsequences: false).count
                if let language, language != .unknown,
                   lineCount >= deferredHighlightLineThreshold {
                    // Large uncached file: show plain text with line numbers immediately,
                    // schedule async highlight to swap in later.
                    let plainText = ToolRowTextRenderer.makeCodeAttributedText(
                        text: displayText,
                        language: nil,
                        startLine: resolvedStartLine
                    )
                    expandedLabel.text = nil
                    expandedLabel.attributedText = plainText
                    deferred = DeferredHighlight(
                        text: displayText,
                        language: language,
                        startLine: resolvedStartLine,
                        signature: signature
                    )
                } else {
                    let codeText = ToolRowTextRenderer.makeCodeAttributedText(
                        text: displayText,
                        language: language,
                        startLine: resolvedStartLine
                    )
                    ToolRowRenderCache.set(signature: signature, attributed: codeText)
                    expandedLabel.text = nil
                    expandedLabel.attributedText = codeText
                }
            }
            ChatTimelinePerf.recordRenderStrategy(
                mode: isStreaming ? "code.stream" : (deferred != nil ? "code.deferred" : "code.highlight"),
                durationMs: ChatTimelinePerf.elapsedMs(since: renderStartNs),
                inputBytes: displayText.utf8.count,
                language: language?.displayName
            )
            expandedRenderedText = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
            expandedRenderSignature = signature
        }

        expandedLabel.textContainer.lineBreakMode = .byClipping
        expandedScrollView.alwaysBounceHorizontal = true
        expandedScrollView.showsHorizontalScrollIndicator = true
        setModeCode()
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()
        expandedShouldAutoFollow = isStreaming
        if shouldRerender && !isStreaming { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

        return RenderResult(
            visibility: ToolTimelineRowExpandedRenderer.Visibility(
                showExpandedContainer: true,
                showCommandContainer: false,
                showOutputContainer: false
            ),
            deferredHighlight: deferred
        )
    }
}
