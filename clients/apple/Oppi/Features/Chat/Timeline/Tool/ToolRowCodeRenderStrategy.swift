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
        expandedScrollView _: UIScrollView,
        previousSignature: Int?,
        previousRenderedText: String?,
        previousAutoFollow: Bool,
        isCurrentModeCode: Bool,
        wasExpandedVisible: Bool,
        sessionId: String? = nil,
        viewportPolicy: ToolRowViewportPolicy = .code
    ) -> ExpandedRenderOutput {
        let displayText = ToolTimelineRowRenderMetrics.displayOutputText(text)
        let resolvedStartLine = startLine ?? 1

        // During streaming, skip the full-text hash for the signature.
        // Use byte count as a cheap proxy — if the text grew, re-render.
        let signature: Int
        let shouldRerender: Bool
        if isStreaming {
            signature = ToolTimelineRowRenderMetrics.streamingCodeSignature(
                byteCount: displayText.utf8.count,
                startLine: resolvedStartLine
            )
            shouldRerender = signature != previousSignature
                || !isCurrentModeCode
                || previousRenderedText != displayText
        } else {
            signature = ToolTimelineRowRenderMetrics.codeSignature(
                displayText: displayText,
                language: language,
                startLine: resolvedStartLine,
                isStreaming: false
            )
            let currentRenderedString = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
            let needsNonStreamingUpgrade = currentRenderedString == displayText
            shouldRerender = signature != previousSignature
                || !isCurrentModeCode
                || needsNonStreamingUpgrade
        }

        var deferred: DeferredHighlight?
        var renderedText = previousRenderedText

        if shouldRerender {
            let renderStartNs = ChatTimelinePerf.timestampNs()
            let languageCategory = Self.languageCategory(for: language)

            // Fast path: streaming always uses .cheap tier, skip the
            // content profile scan (avoids iterating entire text UTF-8).
            let tier: StreamingRenderPolicy.RenderTier
            if isStreaming {
                tier = .cheap
            } else {
                let profile = StreamingRenderPolicy.ContentProfile.from(text: displayText)
                tier = StreamingRenderPolicy.tier(
                    isStreaming: false,
                    contentKind: .code(language: languageCategory),
                    byteCount: profile.byteCount,
                    lineCount: profile.lineCount,
                    maxLineByteCount: profile.maxLineByteCount
                )
            }

            switch tier {
            case .cheap:
                if isStreaming && usesFullReplaceStreamingRender {
                    applyPlainText(displayText, to: expandedLabel)
                } else if isCurrentModeCode {
                    applyStreamingPlainText(
                        displayText,
                        previousRenderedText: previousRenderedText,
                        to: expandedLabel
                    )
                } else {
                    applyPlainText(displayText, to: expandedLabel)
                }

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
                language: language?.displayName,
                sessionId: sessionId
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
            viewportPolicy: viewportPolicy,
            verticalLock: !isStreaming,
            scrollBehavior: scrollBehavior,
            lineBreakMode: .byClipping,
            horizontalScroll: !isStreaming,
            deferredHighlight: deferred,
            invalidateLayout: false,
            installAction: .none
        )
    }

    private static var usesFullReplaceStreamingRender: Bool {
        ProcessInfo.processInfo.environment["OPPI_STREAMING_CODE_RENDER_MODE"] == "fullReplace"
    }

    private static func applyStreamingPlainText(
        _ text: String,
        previousRenderedText: String?,
        to label: UITextView
    ) {
        guard let previousRenderedText,
              !previousRenderedText.isEmpty,
              text.hasPrefix(previousRenderedText) else {
            applyPlainText(text, to: label)
            return
        }

        let previousUTF16Length = (previousRenderedText as NSString).length
        guard label.textStorage.length == previousUTF16Length else {
            applyPlainText(text, to: label)
            return
        }

        let nsText = text as NSString
        guard nsText.length >= previousUTF16Length else {
            applyPlainText(text, to: label)
            return
        }

        let suffix = nsText.substring(from: previousUTF16Length)
        guard !suffix.isEmpty else {
            // A theme change invalidates the render signature even when the
            // streaming text is unchanged. Repaint the existing text instead
            // of treating that invalidation as an empty append.
            applyPlainText(text, to: label)
            return
        }

        label.textStorage.append(NSAttributedString(
            string: suffix,
            attributes: [
                .font: ToolFont.regular,
                .foregroundColor: UIColor(.themeFg),
            ]
        ))
        label.textColor = UIColor(.themeFg)
        label.font = ToolFont.regular
    }

    private static func applyPlainText(_ text: String, to label: UITextView) {
        label.attributedText = nil
        label.text = text
        label.textColor = UIColor(.themeFg)
        label.font = ToolFont.regular
    }

    static func languageCategory(
        for language: SyntaxLanguage?
    ) -> StreamingRenderPolicy.CodeLanguageCategory {
        guard let language else { return .none }
        return language == .unknown ? .unknown : .known
    }
}
