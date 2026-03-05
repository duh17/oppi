import UIKit

@MainActor
struct ToolRowDiffRenderStrategy: ToolTimelineRowExpandedRenderStrategy {
    static let mode: ToolTimelineRowExpandedRenderMode = .diff

    static func isApplicable(to input: ToolTimelineRowExpandedRenderInput) -> Bool {
        if case .diff = input.expandedContent {
            return true
        }
        return false
    }

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
        showExpandedLabel: () -> Void,
        setModeDiff: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void
    ) -> ToolTimelineRowExpandedRenderer.Visibility {
        let signature = ToolTimelineRowRenderMetrics.diffSignature(
            lines: lines, path: path, isStreaming: isStreaming
        )
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeDiff
            || expandedLabel.attributedText == nil

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
        expandedShouldAutoFollow = isStreaming
        if shouldRerender && !isStreaming { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

        return ToolTimelineRowExpandedRenderer.Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }
}
