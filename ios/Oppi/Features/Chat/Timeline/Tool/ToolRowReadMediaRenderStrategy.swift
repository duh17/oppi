import UIKit

@MainActor
struct ToolRowReadMediaRenderStrategy {
    static func render(
        output: String,
        filePath: String?,
        startLine: Int,
        isError: Bool,
        previousSignature: Int?,
        isUsingReadMediaLayout: Bool,
        hasExpandedReadMediaContentView: Bool
    ) -> ExpandedRenderOutput {
        let signature = ToolTimelineRowRenderMetrics.readMediaSignature(
            output: output,
            filePath: filePath,
            startLine: startLine,
            isError: isError
        )
        let shouldReinstall = signature != previousSignature
            || !isUsingReadMediaLayout
            || !hasExpandedReadMediaContentView

        return ExpandedRenderOutput(
            renderSignature: shouldReinstall ? signature : previousSignature,
            renderedText: output,
            shouldAutoFollow: false,
            surface: .hostedView,
            viewportMode: .text,
            verticalLock: false,
            scrollBehavior: shouldReinstall ? .resetToTop : .preserve,
            lineBreakMode: .byCharWrapping,
            horizontalScroll: false,
            deferredHighlight: nil,
            invalidateLayout: false,
            installAction: shouldReinstall
                ? .readMedia(output: output, isError: isError, filePath: filePath, startLine: startLine)
                : .none
        )
    }
}
