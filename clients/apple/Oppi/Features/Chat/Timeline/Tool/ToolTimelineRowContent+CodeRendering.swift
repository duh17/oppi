import UIKit

extension ToolTimelineRowContentView {
    struct DeferredHighlightedCode: @unchecked Sendable {
        let attributed: NSAttributedString
    }

    #if DEBUG
    nonisolated(unsafe) static var deferredCodeHighlightDelayForTesting: Duration?
    #endif

    func cancelDeferredCodeHighlight() {
        expandedCodeDeferredHighlightTask?.cancel()
        expandedCodeDeferredHighlightTask = nil
        expandedCodeDeferredHighlightSignature = nil
    }

    func scheduleDeferredCodeHighlightIfNeeded(
        _ deferredHighlight: ToolRowCodeRenderStrategy.DeferredHighlight,
        sessionId: String? = nil
    ) {
        if expandedCodeDeferredHighlightSignature == deferredHighlight.signature,
           let task = expandedCodeDeferredHighlightTask,
           !task.isCancelled {
            return
        }

        cancelDeferredCodeHighlight()
        expandedCodeDeferredHighlightSignature = deferredHighlight.signature

        expandedCodeDeferredHighlightTask = Task.detached(priority: .utility) { [weak self] in
            #if DEBUG
            if let artificialDelay = Self.deferredCodeHighlightDelayForTesting {
                try? await Task.sleep(for: artificialDelay)
            }
            #endif

            let renderStart = ContinuousClock.now
            let highlighted = DeferredHighlightedCode(attributed: ToolRowTextRenderer.makeCodeAttributedText(
                text: deferredHighlight.text,
                language: deferredHighlight.language,
                startLine: deferredHighlight.startLine
            ))
            let durationMs = Int((ContinuousClock.now - renderStart) / .milliseconds(1))

            await MainActor.run { [weak self] in
                ToolRowRenderCache.set(
                    signature: deferredHighlight.signature,
                    attributed: highlighted.attributed
                )
                ChatTimelinePerf.recordRenderStrategy(
                    mode: "code.deferred.highlight",
                    durationMs: durationMs,
                    inputBytes: deferredHighlight.text.utf8.count,
                    language: deferredHighlight.language.displayName,
                    sessionId: sessionId
                )

                guard let self,
                      self.expandedCodeDeferredHighlightSignature == deferredHighlight.signature else {
                    return
                }

                defer {
                    self.expandedCodeDeferredHighlightTask = nil
                    self.expandedCodeDeferredHighlightSignature = nil
                }

                guard self.expandedRenderSignature == deferredHighlight.signature,
                      self.expandedViewportMode == .code,
                      !self.expandedUsesMarkdownLayout,
                      !self.expandedUsesReadMediaLayout else {
                    return
                }

                self.expandedLabel.text = nil
                self.expandedLabel.attributedText = highlighted.attributed
                self.expandedRenderedText = highlighted.attributed.string
                self.updateExpandedLabelWidthIfNeeded()
                self.setNeedsLayout()
            }
        }
    }
}
