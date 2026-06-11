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
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        textSelectionEnabled: Bool,
        viewportPolicy: ToolRowViewportPolicy
    ) -> ExpandedRenderOutput {
        let signature = ToolTimelineRowRenderMetrics.markdownSignature(text, isStreaming: isStreaming)
        let shouldRerender = signature != previousSignature
            || !isUsingMarkdownViewportLayout

        let autoFollow = ToolTimelineRowUIHelpers.computeAutoFollow(
            isStreaming: isStreaming,
            shouldRerender: shouldRerender,
            wasExpandedVisible: wasExpandedVisible,
            previousRenderedText: previousRenderedText,
            currentDisplayText: text,
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
            renderedText: text,
            shouldAutoFollow: autoFollow,
            viewportPolicy: viewportPolicy,
            verticalLock: false,
            scrollBehavior: scrollBehavior,
            lineBreakMode: .byCharWrapping,
            horizontalScroll: false,
            deferredHighlight: nil,
            invalidateLayout: shouldRerender || !isUsingMarkdownViewportLayout,
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
