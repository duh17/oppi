import UIKit

@MainActor
struct ToolRowReadMediaRenderStrategy {
    static func render(
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
    ) -> ToolTimelineRowExpandedRenderer.Visibility {
        let signature = ToolTimelineRowRenderMetrics.readMediaSignature(
            output: output,
            filePath: filePath,
            startLine: startLine,
            isError: isError
        )
        let shouldReinstall = signature != expandedRenderSignature
            || !isUsingReadMediaLayout
            || !hasExpandedReadMediaContentView

        showExpandedHostedView()
        expandedRenderedText = output
        if shouldReinstall {
            installExpandedReadMediaView(output, isError, filePath, startLine)
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        setModeText()
        showExpandedViewport()
        expandedShouldAutoFollow = false
        if shouldReinstall { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

        return ToolTimelineRowExpandedRenderer.Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }
}
