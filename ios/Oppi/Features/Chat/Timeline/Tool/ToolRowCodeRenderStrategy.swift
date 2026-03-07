import SwiftUI
import UIKit

@MainActor
struct ToolRowCodeRenderStrategy {
    /// Thresholds for switching inline code rows to the cheap first paint path.
    /// We defer sooner than before because `read` output often contains medium-
    /// sized files that are still expensive to syntax highlight inline.
    static let deferredHighlightLineThreshold = 80
    static let deferredHighlightByteThreshold = 4 * 1024
    static let deferredHighlightLongLineByteThreshold = 160

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

    private struct HighlightProfile {
        let byteCount: Int
        let lineCount: Int
        let maxLineByteCount: Int
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
            if isStreaming {
                applyPlainText(displayText, to: expandedLabel)
            } else if let cached = ToolRowRenderCache.get(signature: signature) {
                expandedLabel.text = nil
                expandedLabel.attributedText = cached
            } else {
                let highlightProfile = highlightProfile(for: displayText)
                if shouldDeferHighlight(language: language, profile: highlightProfile) {
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

        let isStreamingContinuation = previousRenderedText.map {
            !$0.isEmpty && displayText.hasPrefix($0)
        } ?? false

        if isStreaming {
            if !wasExpandedVisible || previousRenderedText == nil {
                expandedShouldAutoFollow = true
            } else if !isStreamingContinuation {
                expandedShouldAutoFollow = false
            }
        } else {
            expandedShouldAutoFollow = false
        }

        if shouldRerender {
            if expandedShouldAutoFollow {
                scheduleExpandedAutoScrollToBottomIfNeeded()
            } else if !isStreaming {
                ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
            }
        }

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

    private static func shouldDeferHighlight(
        language: SyntaxLanguage?,
        profile: HighlightProfile
    ) -> Bool {
        guard let language else { return false }
        if language == .unknown {
            return profile.byteCount >= deferredHighlightByteThreshold * 2
                || profile.lineCount >= deferredHighlightLineThreshold * 2
                || profile.maxLineByteCount >= deferredHighlightLongLineByteThreshold * 2
        }

        return profile.lineCount >= deferredHighlightLineThreshold
            || profile.byteCount >= deferredHighlightByteThreshold
            || profile.maxLineByteCount >= deferredHighlightLongLineByteThreshold
    }

    private static func highlightProfile(for text: String) -> HighlightProfile {
        var byteCount = 0
        var lineCount = 1
        var currentLineByteCount = 0
        var maxLineByteCount = 0

        for byte in text.utf8 {
            byteCount += 1
            if byte == 0x0A {
                maxLineByteCount = max(maxLineByteCount, currentLineByteCount)
                currentLineByteCount = 0
                lineCount += 1
            } else {
                currentLineByteCount += 1
            }
        }

        maxLineByteCount = max(maxLineByteCount, currentLineByteCount)
        return HighlightProfile(
            byteCount: byteCount,
            lineCount: lineCount,
            maxLineByteCount: maxLineByteCount
        )
    }
}
