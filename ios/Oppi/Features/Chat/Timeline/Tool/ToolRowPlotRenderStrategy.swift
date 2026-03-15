import UIKit

@MainActor
struct ToolRowPlotRenderStrategy {
    static func render(
        spec: PlotChartSpec,
        fallbackText: String?,
        previousSignature: Int?,
        isUsingReadMediaLayout: Bool,
        hasExpandedPlotContentView: Bool
    ) -> ExpandedRenderOutput {
        let signature = ToolTimelineRowRenderMetrics.plotSignature(
            spec: spec,
            fallbackText: fallbackText
        )
        let shouldReinstall = signature != previousSignature
            || !isUsingReadMediaLayout
            || !hasExpandedPlotContentView

        return ExpandedRenderOutput(
            renderSignature: shouldReinstall ? signature : previousSignature,
            renderedText: fallbackText,
            shouldAutoFollow: false,
            surface: .hostedView,
            viewportMode: .text,
            verticalLock: false,
            scrollBehavior: shouldReinstall ? .resetToTop : .preserve,
            lineBreakMode: .byCharWrapping,
            horizontalScroll: false,
            deferredHighlight: nil,
            invalidateLayout: false,
            installAction: shouldReinstall ? .plot(spec: spec, fallbackText: fallbackText) : .none
        )
    }
}
