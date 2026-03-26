import UIKit

@MainActor
struct ToolRowMarkdownRenderStrategy {
    static func render(
        text: String,
        isStreaming: Bool,
        expandedMarkdownView: AssistantMarkdownContentView,
        expandedScrollView _: UIScrollView,
        previousSignature: Int?,
        previousRenderedText: String?,
        previousAutoFollow: Bool,
        wasExpandedVisible: Bool,
        isUsingMarkdownLayout: Bool,
        selectedTextPiRouter: SelectedTextPiActionRouter?,
        selectedTextSourceContext: SelectedTextSourceContext?,
        textSelectionEnabled: Bool
    ) -> ExpandedRenderOutput {
        let signature = ToolTimelineRowRenderMetrics.markdownSignature(text, isStreaming: isStreaming)
        let shouldRerender = signature != previousSignature
            || !isUsingMarkdownLayout

        expandedMarkdownView.apply(configuration: .init(
            content: text,
            isStreaming: isStreaming,
            themeID: ThemeRuntimeState.currentThemeID(),
            textSelectionEnabled: textSelectionEnabled,
            // Tool expanded content lives in a scrollable viewport, so there's
            // no risk of blocking the timeline layout with large markdown.
            // Disable the plain-text fallback threshold so write/read tools
            // always render formatted markdown regardless of content size.
            plainTextFallbackThreshold: nil,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSourceContext: selectedTextSourceContext,
            perfSurface: .toolExpanded
        ))

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
            surface: .markdown,
            viewportMode: .text,
            verticalLock: false,
            scrollBehavior: scrollBehavior,
            lineBreakMode: .byCharWrapping,
            horizontalScroll: false,
            deferredHighlight: nil,
            invalidateLayout: shouldRerender || !isUsingMarkdownLayout,
            installAction: .none
        )
    }
}
