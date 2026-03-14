import UIKit

@MainActor
struct ToolRowDiffRenderStrategy {
    static func render(
        lines: [DiffLine],
        path: String?,
        isStreaming: Bool,
        expandedLabel: UITextView,
        expandedScrollView: UIScrollView,
        previousSignature: Int?,
        previousRenderedText: String?,
        previousAutoFollow: Bool,
        isCurrentModeDiff: Bool,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderOutput {
        let signature = ToolTimelineRowRenderMetrics.diffSignature(
            lines: lines, path: path, isStreaming: isStreaming
        )
        let shouldRerender = signature != previousSignature
            || !isCurrentModeDiff
            || (expandedLabel.attributedText == nil && expandedLabel.text == nil)

        var renderedText = previousRenderedText

        if shouldRerender {
            let renderStartNs = ChatTimelinePerf.timestampNs()
            let inputBytes = lines.reduce(0) { $0 + $1.text.utf8.count }
            let tier = StreamingRenderPolicy.tier(
                isStreaming: isStreaming,
                contentKind: .diff,
                byteCount: inputBytes,
                lineCount: lines.count
            )

            if tier == .cheap {
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
                renderedText = plainDiff
            } else if let cached = ToolRowRenderCache.get(signature: signature) {
                expandedLabel.text = nil
                expandedLabel.attributedText = cached
                renderedText = cached.string
            } else {
                // Unified diff renderer: convert DiffLines → hunks with word spans → attributed string
                let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
                let diffText: NSAttributedString
                if hunks.isEmpty {
                    diffText = NSAttributedString(
                        string: "No textual changes",
                        attributes: [
                            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                            .foregroundColor: UIColor(.themeComment),
                        ]
                    )
                } else {
                    diffText = DiffAttributedStringBuilder.build(hunks: hunks, filePath: path ?? "diff.txt")
                }
                ToolRowRenderCache.set(signature: signature, attributed: diffText)
                expandedLabel.text = nil
                expandedLabel.attributedText = diffText
                renderedText = diffText.string
            }
            ChatTimelinePerf.recordRenderStrategy(
                mode: tier == .cheap ? "diff.stream" : "diff.highlight",
                durationMs: ChatTimelinePerf.elapsedMs(since: renderStartNs),
                inputBytes: inputBytes,
                language: path.flatMap { ToolRowTextRenderer.diffLanguage(for: $0)?.displayName }
            )
        }

        let autoFollow = ToolTimelineRowUIHelpers.computeAutoFollow(
            isStreaming: isStreaming,
            shouldRerender: shouldRerender,
            wasExpandedVisible: wasExpandedVisible,
            previousRenderedText: previousRenderedText,
            currentDisplayText: renderedText ?? "",
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
            viewportMode: .diff,
            verticalLock: !isStreaming,
            scrollBehavior: scrollBehavior,
            lineBreakMode: .byClipping,
            horizontalScroll: true,
            deferredHighlight: nil,
            invalidateLayout: false,
            installAction: .none
        )
    }
}
