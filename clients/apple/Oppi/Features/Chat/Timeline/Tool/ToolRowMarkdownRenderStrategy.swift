import UIKit

@MainActor
struct ToolRowMarkdownRenderStrategy {
    static func render(
        text: String,
        isStreaming: Bool,
        expandedScrollView _: UIScrollView,
        previousSignature: Int?,
        previousRenderedText: String?,
        previousAutoFollow: Bool,
        wasExpandedVisible: Bool,
        isUsingMarkdownViewportLayout: Bool,
        isThemeChanged: Bool = false,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        textSelectionEnabled: Bool,
        viewportPolicy: ToolRowViewportPolicy
    ) -> ExpandedRenderOutput {
        let signature = ToolTimelineRowRenderMetrics.markdownSignature(text, isStreaming: isStreaming)
        let contentChanged = signature != previousSignature
        let shouldRerender = contentChanged || !isUsingMarkdownViewportLayout

        var follow = LiveStreamingPresentation.ViewportPolicy(followsTail: previousAutoFollow)
        _ = follow.applyStreamTick(
            isStreaming: isStreaming,
            shouldRerender: shouldRerender,
            wasVisible: wasExpandedVisible,
            previousText: previousRenderedText,
            currentText: text
        )
        let autoFollow = follow.followsTail

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
            renderedText: text,
            shouldAutoFollow: autoFollow,
            viewportPolicy: viewportPolicy,
            verticalLock: false,
            scrollBehavior: scrollBehavior,
            lineBreakMode: .byCharWrapping,
            horizontalScroll: false,
            deferredHighlight: nil,
            // The inline Markdown body has a fixed-height streaming viewport.
            // Content changes update only the nested renderer. Completed rows
            // invalidate only when their signature changes; installation and
            // theme/geometry transitions remain real outer changes.
            invalidateLayout: !isUsingMarkdownViewportLayout
                || (contentChanged && !isStreaming)
                || isThemeChanged,
            installAction: .markdownViewport(
                text: text,
                isStreaming: isStreaming,
                reviewCommentSelectionRouter: reviewCommentSelectionRouter,
                reviewCommentSourceContext: reviewCommentSourceContext,
                textSelectionEnabled: textSelectionEnabled
            )
        )
    }
}
