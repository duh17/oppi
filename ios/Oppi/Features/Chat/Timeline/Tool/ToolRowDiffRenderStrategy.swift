import UIKit

@MainActor
struct ToolRowDiffRenderStrategy {
    static func render(
        lines: [DiffLine],
        path: String?,
        isStreaming: Bool,
        expandedLabel: UITextView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        isCurrentModeDiff: Bool,
        wasExpandedVisible: Bool,
        showExpandedLabel: () -> Void,
        setModeDiff: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void,
        scheduleExpandedAutoScrollToBottomIfNeeded: () -> Void
    ) -> ToolRowRenderVisibility {
        let signature = ToolTimelineRowRenderMetrics.diffSignature(
            lines: lines, path: path, isStreaming: isStreaming
        )
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeDiff
            || (expandedLabel.attributedText == nil && expandedLabel.text == nil)
        let previousRenderedText = expandedRenderedText

        showExpandedLabel()
        if shouldRerender {
            let renderStartNs = ChatTimelinePerf.timestampNs()
            let inputBytes = lines.reduce(0) { $0 + $1.text.utf8.count }
            if isStreaming {
                let plainDiff = lines.map { line in
                    switch line.kind {
                    case .added: "+ \(line.text)"
                    case .removed: "- \(line.text)"
                    case .context: "  \(line.text)"
                    }
                }.joined(separator: "\n")
                expandedLabel.attributedText = nil
                expandedLabel.text = plainDiff
                expandedLabel.textColor = UIColor(.themeFg)
                expandedLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                expandedRenderedText = plainDiff
            } else if let cached = ToolRowRenderCache.get(signature: signature) {
                expandedLabel.text = nil
                expandedLabel.attributedText = cached
                expandedRenderedText = cached.string
            } else {
                let diffText = ToolRowTextRenderer.makeDiffAttributedText(lines: lines, filePath: path)
                ToolRowRenderCache.set(signature: signature, attributed: diffText)
                expandedLabel.text = nil
                expandedLabel.attributedText = diffText
                expandedRenderedText = diffText.string
            }
            ChatTimelinePerf.recordRenderStrategy(
                mode: isStreaming ? "diff.stream" : "diff.highlight",
                durationMs: ChatTimelinePerf.elapsedMs(since: renderStartNs),
                inputBytes: inputBytes,
                language: path.flatMap { ToolRowTextRenderer.diffLanguage(for: $0)?.displayName }
            )
            expandedRenderSignature = signature
        }

        expandedLabel.textContainer.lineBreakMode = .byClipping
        expandedScrollView.alwaysBounceHorizontal = true
        expandedScrollView.showsHorizontalScrollIndicator = true
        setModeDiff()
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()

        let currentRenderedText = expandedRenderedText ?? ""
        let isStreamingContinuation = previousRenderedText.map {
            !$0.isEmpty && currentRenderedText.hasPrefix($0)
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

        return ToolRowRenderVisibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }
}
