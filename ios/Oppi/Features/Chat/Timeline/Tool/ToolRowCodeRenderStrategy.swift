import SwiftUI
import UIKit

@MainActor
struct ToolRowCodeRenderStrategy {
    /// Result of a render call. `deferredHighlight` is non-nil when the strategy
    /// showed plain text and needs the caller to schedule async highlighting.
    struct RenderResult {
        let visibility: ToolRowRenderVisibility
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
        wasExpandedVisible: Bool,
        showExpandedLabel: () -> Void,
        setModeCode: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void,
        scheduleExpandedAutoScrollToBottomIfNeeded: () -> Void
    ) -> RenderResult {
        let displayText = ToolTimelineRowRenderMetrics.displayOutputText(text)
        let resolvedStartLine = startLine ?? 1
        let signature = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: displayText,
            language: language,
            startLine: resolvedStartLine,
            isStreaming: isStreaming
        )
        // If a deferred highlight task cached the final attributed result but
        // couldn't apply it due to a transient mode/signature mismatch, the
        // label can be left showing the raw source text for the same signature.
        // UITextView may synthesize a plain attributedText even when we set
        // only `.text`, so detect the cheap first-paint state by comparing the
        // currently rendered string with the raw display text.
        let currentRenderedString = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
        let needsNonStreamingUpgrade = !isStreaming && currentRenderedString == displayText
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeCode
            || needsNonStreamingUpgrade
        let previousRenderedText = expandedRenderedText

        var deferred: DeferredHighlight?

        showExpandedLabel()
        if shouldRerender {
            let renderStartNs = ChatTimelinePerf.timestampNs()
            let profile = StreamingRenderPolicy.ContentProfile.from(text: displayText)
            let languageCategory = Self.languageCategory(for: language)
            let tier = StreamingRenderPolicy.tier(
                isStreaming: isStreaming,
                contentKind: .code(language: languageCategory),
                byteCount: profile.byteCount,
                lineCount: profile.lineCount,
                maxLineByteCount: profile.maxLineByteCount
            )

            switch tier {
            case .cheap:
                applyPlainText(displayText, to: expandedLabel)

            case .deferred, .full:
                if let cached = ToolRowRenderCache.get(signature: signature) {
                    expandedLabel.text = nil
                    expandedLabel.attributedText = cached
                } else if tier == .deferred {
                    // Large uncached file: show the cheapest possible first paint
                    // (plain monospace text, no line-number gutter), then upgrade
                    // to highlighted + numbered code asynchronously.
                    applyPlainText(displayText, to: expandedLabel)
                    deferred = DeferredHighlight(
                        text: displayText,
                        language: language ?? .unknown,
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
                mode: tier == .cheap ? "code.stream" : (deferred != nil ? "code.deferred" : "code.highlight"),
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

        ToolTimelineRowUIHelpers.applyExpandedAutoFollow(
            isStreaming: isStreaming,
            shouldRerender: shouldRerender,
            wasExpandedVisible: wasExpandedVisible,
            previousRenderedText: previousRenderedText,
            currentDisplayText: displayText,
            expandedShouldAutoFollow: &expandedShouldAutoFollow,
            expandedScrollView: expandedScrollView,
            scheduleFollowTail: scheduleExpandedAutoScrollToBottomIfNeeded
        )

        return RenderResult(
            visibility: ToolRowRenderVisibility(
                showExpandedContainer: true,
                showCommandContainer: false,
                showOutputContainer: false
            ),
            deferredHighlight: deferred
        )
    }

    private static func applyPlainText(_ text: String, to label: UITextView) {
        label.attributedText = nil
        label.text = text
        label.textColor = UIColor(.themeFg)
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    }

    static func languageCategory(
        for language: SyntaxLanguage?
    ) -> StreamingRenderPolicy.CodeLanguageCategory {
        guard let language else { return .none }
        return language == .unknown ? .unknown : .known
    }
}
