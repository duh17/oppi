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
        _ deferredHighlight: ToolRowCodeRenderStrategy.DeferredHighlight
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
                    language: deferredHighlight.language.displayName
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

    func renderExpandedCodeMode(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int?,
        isStreaming: Bool,
        wasExpandedVisible: Bool
    ) -> ToolRowRenderVisibility {
        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let result = ToolRowCodeRenderStrategy.render(
            text: text,
            language: language,
            startLine: startLine,
            isStreaming: isStreaming,
            expandedLabel: expandedLabel,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &localExpandedRenderSignature,
            expandedRenderedText: &localExpandedRenderedText,
            expandedShouldAutoFollow: &localExpandedShouldAutoFollow,
            isCurrentModeCode: expandedViewportMode == .code,
            wasExpandedVisible: wasExpandedVisible,
            showExpandedLabel: showExpandedLabel,
            setModeCode: { self.expandedViewportMode = .code },
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport,
            scheduleExpandedAutoScrollToBottomIfNeeded: { self.scheduleExpandedAutoScrollToBottomIfNeeded() }
        )

        expandedRenderSignature = localExpandedRenderSignature
        expandedRenderedText = localExpandedRenderedText
        expandedShouldAutoFollow = localExpandedShouldAutoFollow

        if let deferredHighlight = result.deferredHighlight {
            scheduleDeferredCodeHighlightIfNeeded(deferredHighlight)
        } else {
            cancelDeferredCodeHighlight()
        }

        if result.visibility.showExpandedContainer {
            // During streaming, don't lock label height to the viewport.
            // The label must grow beyond the viewport so followTail() can
            // scroll the inner scroll view to show the latest content.
            // On done, re-enable the lock for horizontal-scroll-only mode.
            setExpandedVerticalLockEnabled(!isStreaming)
            updateExpandedLabelWidthIfNeeded()
        }

        return result.visibility
    }
}
