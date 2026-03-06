import UIKit

@MainActor
struct ToolRowPlotRenderStrategy {
    static func render(
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
    ) -> ToolTimelineRowExpandedRenderer.Visibility {
        let signature = ToolTimelineRowRenderMetrics.plotSignature(
            spec: spec,
            fallbackText: fallbackText
        )
        let shouldReinstall = signature != expandedRenderSignature
            || !isUsingReadMediaLayout
            || !hasExpandedPlotContentView

        showExpandedHostedView()
        expandedRenderedText = fallbackText
        if shouldReinstall {
            installExpandedPlotView(spec, fallbackText)
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
