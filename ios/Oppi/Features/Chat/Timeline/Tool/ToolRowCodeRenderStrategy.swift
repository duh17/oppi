import SwiftUI
import UIKit

@MainActor
struct ToolRowCodeRenderStrategy {
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
        previousSignature: Int?,
        previousRenderedText: String?,
        previousAutoFollow: Bool,
        isCurrentModeCode: Bool,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderOutput {
        let displayText = ToolTimelineRowRenderMetrics.displayOutputText(text)
        let resolvedStartLine = startLine ?? 1
        let signature = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: displayText,
            language: language,
            startLine: resolvedStartLine,
            isStreaming: isStreaming
        )
        let currentRenderedString = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
        let needsNonStreamingUpgrade = !isStreaming && currentRenderedString == displayText
        let shouldRerender = signature != previousSignature
            || !isCurrentModeCode
            || needsNonStreamingUpgrade

        var deferred: DeferredHighlight?
        var renderedText = previousRenderedText

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
            renderedText = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
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
            viewportMode: .code,
            verticalLock: !isStreaming,
            scrollBehavior: scrollBehavior,
            lineBreakMode: .byClipping,
            horizontalScroll: true,
            deferredHighlight: deferred,
            invalidateLayout: false
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
