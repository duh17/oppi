import UIKit

/// Thin facade that keeps `ToolTimelineRowContentView` call sites stable while
/// delegating actual rendering work to per-mode strategy implementations.
@MainActor
enum ToolTimelineRowExpandedRenderer {
    struct Visibility {
        let showExpandedContainer: Bool
        let showCommandContainer: Bool
        let showOutputContainer: Bool
    }

    struct CodeResult {
        let visibility: Visibility
        let deferredHighlight: ToolRowCodeRenderStrategy.DeferredHighlight?
    }

    static func renderBashMode(
        command: String?,
        output: String?,
        unwrapped: Bool,
        isError: Bool,
        isStreaming: Bool,
        outputColor: UIColor,
        commandTextColor: UIColor,
        wasOutputVisible: Bool,
        commandLabel: UITextView,
        outputLabel: UITextView,
        outputScrollView: UIScrollView,
        commandRenderSignature: inout Int?,
        outputRenderSignature: inout Int?,
        outputRenderedText: inout String?,
        outputUsesUnwrappedLayout: inout Bool,
        outputUsesViewport: inout Bool,
        outputShouldAutoFollow: inout Bool,
        outputDidTextChange: inout Bool,
        outputViewportHeightConstraint: NSLayoutConstraint?,
        hideExpandedContainer: () -> Void
    ) -> Visibility {
        ToolRowBashRenderStrategy.render(
            command: command,
            output: output,
            unwrapped: unwrapped,
            isError: isError,
            isStreaming: isStreaming,
            outputColor: outputColor,
            commandTextColor: commandTextColor,
            wasOutputVisible: wasOutputVisible,
            commandLabel: commandLabel,
            outputLabel: outputLabel,
            outputScrollView: outputScrollView,
            commandRenderSignature: &commandRenderSignature,
            outputRenderSignature: &outputRenderSignature,
            outputRenderedText: &outputRenderedText,
            outputUsesUnwrappedLayout: &outputUsesUnwrappedLayout,
            outputUsesViewport: &outputUsesViewport,
            outputShouldAutoFollow: &outputShouldAutoFollow,
            outputDidTextChange: &outputDidTextChange,
            outputViewportHeightConstraint: outputViewportHeightConstraint,
            hideExpandedContainer: hideExpandedContainer
        )
    }

    static func renderDiffMode(
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
    ) -> Visibility {
        ToolRowDiffRenderStrategy.render(
            lines: lines,
            path: path,
            isStreaming: isStreaming,
            expandedLabel: expandedLabel,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &expandedRenderSignature,
            expandedRenderedText: &expandedRenderedText,
            expandedShouldAutoFollow: &expandedShouldAutoFollow,
            isCurrentModeDiff: isCurrentModeDiff,
            showExpandedLabel: showExpandedLabel,
            setModeDiff: setModeDiff,
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport
        )
    }

    static func renderCodeMode(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int?,
        isStreaming: Bool,
        expandedLabel: UITextView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        isCurrentModeCode: Bool,
        showExpandedLabel: () -> Void,
        setModeCode: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void
    ) -> CodeResult {
        let result = ToolRowCodeRenderStrategy.render(
            text: text,
            language: language,
            startLine: startLine,
            isStreaming: isStreaming,
            expandedLabel: expandedLabel,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &expandedRenderSignature,
            expandedRenderedText: &expandedRenderedText,
            expandedShouldAutoFollow: &expandedShouldAutoFollow,
            isCurrentModeCode: isCurrentModeCode,
            showExpandedLabel: showExpandedLabel,
            setModeCode: setModeCode,
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport
        )

        return CodeResult(
            visibility: result.visibility,
            deferredHighlight: result.deferredHighlight
        )
    }

    static func renderMarkdownMode(
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
        showExpandedMarkdown: () -> Void,
        setModeText: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void,
        scheduleExpandedAutoScrollToBottomIfNeeded: () -> Void
    ) -> Visibility {
        ToolRowMarkdownRenderStrategy.render(
            text: text,
            isStreaming: isStreaming,
            expandedMarkdownView: expandedMarkdownView,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &expandedRenderSignature,
            expandedRenderedText: &expandedRenderedText,
            expandedShouldAutoFollow: &expandedShouldAutoFollow,
            wasExpandedVisible: wasExpandedVisible,
            isUsingMarkdownLayout: isUsingMarkdownLayout,
            shouldAutoFollowOnFirstRender: shouldAutoFollowOnFirstRender,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSourceContext: selectedTextSourceContext,
            showExpandedMarkdown: showExpandedMarkdown,
            setModeText: setModeText,
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport,
            scheduleExpandedAutoScrollToBottomIfNeeded: scheduleExpandedAutoScrollToBottomIfNeeded
        )
    }

    static func renderPlotMode(
        spec: PlotChartSpec,
        fallbackText: String?,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        isUsingReadMediaLayout: Bool,
        hasExpandedPlotContentView: Bool,
        showExpandedHostedView: () -> Void,
        installExpandedPlotView: (_ spec: PlotChartSpec, _ fallbackText: String?) -> Void,
        setModeText: () -> Void,
        showExpandedViewport: () -> Void
    ) -> Visibility {
        ToolRowPlotRenderStrategy.render(
            spec: spec,
            fallbackText: fallbackText,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &expandedRenderSignature,
            expandedRenderedText: &expandedRenderedText,
            expandedShouldAutoFollow: &expandedShouldAutoFollow,
            isUsingReadMediaLayout: isUsingReadMediaLayout,
            hasExpandedPlotContentView: hasExpandedPlotContentView,
            showExpandedHostedView: showExpandedHostedView,
            installExpandedPlotView: installExpandedPlotView,
            setModeText: setModeText,
            showExpandedViewport: showExpandedViewport
        )
    }

    static func renderReadMediaMode(
        output: String,
        filePath: String?,
        startLine: Int,
        isError: Bool,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        isUsingReadMediaLayout: Bool,
        hasExpandedReadMediaContentView: Bool,
        showExpandedHostedView: () -> Void,
        installExpandedReadMediaView: (_ output: String, _ isError: Bool, _ filePath: String?, _ startLine: Int) -> Void,
        setModeText: () -> Void,
        showExpandedViewport: () -> Void
    ) -> Visibility {
        ToolRowReadMediaRenderStrategy.render(
            output: output,
            filePath: filePath,
            startLine: startLine,
            isError: isError,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &expandedRenderSignature,
            expandedRenderedText: &expandedRenderedText,
            expandedShouldAutoFollow: &expandedShouldAutoFollow,
            isUsingReadMediaLayout: isUsingReadMediaLayout,
            hasExpandedReadMediaContentView: hasExpandedReadMediaContentView,
            showExpandedHostedView: showExpandedHostedView,
            installExpandedReadMediaView: installExpandedReadMediaView,
            setModeText: setModeText,
            showExpandedViewport: showExpandedViewport
        )
    }

    static func renderTextMode(
        text: String,
        language: SyntaxLanguage?,
        isError: Bool,
        isStreaming: Bool,
        outputColor: UIColor,
        expandedLabel: UITextView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        wasExpandedVisible: Bool,
        isCurrentModeText: Bool,
        isUsingMarkdownLayout: Bool,
        isUsingReadMediaLayout: Bool,
        shouldAutoFollowOnFirstRender: Bool,
        showExpandedLabel: () -> Void,
        setModeText: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void,
        scheduleExpandedAutoScrollToBottomIfNeeded: () -> Void
    ) -> Visibility {
        ToolRowTextRenderStrategy.render(
            text: text,
            language: language,
            isError: isError,
            isStreaming: isStreaming,
            outputColor: outputColor,
            expandedLabel: expandedLabel,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &expandedRenderSignature,
            expandedRenderedText: &expandedRenderedText,
            expandedShouldAutoFollow: &expandedShouldAutoFollow,
            wasExpandedVisible: wasExpandedVisible,
            isCurrentModeText: isCurrentModeText,
            isUsingMarkdownLayout: isUsingMarkdownLayout,
            isUsingReadMediaLayout: isUsingReadMediaLayout,
            shouldAutoFollowOnFirstRender: shouldAutoFollowOnFirstRender,
            showExpandedLabel: showExpandedLabel,
            setModeText: setModeText,
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport,
            scheduleExpandedAutoScrollToBottomIfNeeded: scheduleExpandedAutoScrollToBottomIfNeeded
        )
    }
}
