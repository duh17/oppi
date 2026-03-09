import UIKit

@MainActor
struct ToolRowMarkdownRenderStrategy {
    static func render(
        text: String,
        isStreaming: Bool,
        expandedMarkdownView: AssistantMarkdownContentView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        wasExpandedVisible: Bool,
        isUsingMarkdownLayout: Bool,
        shouldAutoFollowOnFirstRender: Bool,
        selectedTextPiRouter: SelectedTextPiActionRouter?,
        selectedTextSourceContext: SelectedTextSourceContext?,
        textSelectionEnabled: Bool,
        showExpandedMarkdown: () -> Void,
        setModeText: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void,
        scheduleExpandedAutoScrollToBottomIfNeeded: () -> Void
    ) -> ToolRowRenderVisibility {
        let signature = ToolTimelineRowRenderMetrics.markdownSignature(text, isStreaming: isStreaming)
        let shouldRerender = signature != expandedRenderSignature
            || !isUsingMarkdownLayout
        let previousRenderedText = expandedRenderedText

        showExpandedMarkdown()

        expandedRenderedText = text
        updateExpandedLabelWidthIfNeeded()
        expandedMarkdownView.apply(configuration: .init(
            content: text,
            isStreaming: isStreaming,
            themeID: ThemeRuntimeState.currentThemeID(),
            textSelectionEnabled: textSelectionEnabled,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSourceContext: selectedTextSourceContext
        ))
        if shouldRerender {
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        setModeText()
        showExpandedViewport()

        let isStreamingContinuation = previousRenderedText.map { !$0.isEmpty && text.hasPrefix($0) } ?? false

        if !wasExpandedVisible {
            expandedShouldAutoFollow = shouldAutoFollowOnFirstRender
        } else if !shouldAutoFollowOnFirstRender,
                  shouldRerender,
                  !isStreamingContinuation {
            expandedShouldAutoFollow = false
        }

        if shouldRerender {
            if expandedShouldAutoFollow {
                scheduleExpandedAutoScrollToBottomIfNeeded()
            } else {
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
