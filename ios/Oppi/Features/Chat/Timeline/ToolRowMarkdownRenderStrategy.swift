import UIKit

@MainActor
struct ToolRowMarkdownRenderStrategy: ToolTimelineRowExpandedRenderStrategy {
    static let mode: ToolTimelineRowExpandedRenderMode = .markdown

    static func isApplicable(to input: ToolTimelineRowExpandedRenderInput) -> Bool {
        if case .markdown = input.expandedContent {
            return true
        }
        return false
    }

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
        showExpandedMarkdown: () -> Void,
        setModeText: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void,
        scheduleExpandedAutoScrollToBottomIfNeeded: () -> Void
    ) -> ToolTimelineRowExpandedRenderer.Visibility {
        let signature = ToolTimelineRowRenderMetrics.markdownSignature(text)
        let shouldRerender = signature != expandedRenderSignature
            || !isUsingMarkdownLayout
        let previousRenderedText = expandedRenderedText

        showExpandedMarkdown()

        expandedRenderedText = text
        updateExpandedLabelWidthIfNeeded()
        if shouldRerender {
            expandedMarkdownView.apply(configuration: .init(
                content: text,
                isStreaming: isStreaming,
                themeID: ThemeRuntimeState.currentThemeID()
            ))
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

        return ToolTimelineRowExpandedRenderer.Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }
}
