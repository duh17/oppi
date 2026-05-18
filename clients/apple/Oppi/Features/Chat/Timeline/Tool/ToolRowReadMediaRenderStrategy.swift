import UIKit

@MainActor
struct ToolRowReadMediaRenderStrategy {
    static func render(
        output: String,
        filePath: String?,
        startLine: Int,
        attachments: [ToolPresentationBuilder.ToolMediaAttachment],
        isError: Bool,
        hasAttachmentFetcher: Bool,
        hasSessionFileDataFetcher: Bool,
        previousSignature: Int?,
        isUsingReadMediaLayout: Bool,
        hasExpandedReadMediaContentView: Bool
    ) -> ExpandedRenderOutput {
        let signature = ToolTimelineRowRenderMetrics.readMediaSignature(
            output: output,
            filePath: filePath,
            startLine: startLine,
            isError: isError,
            attachments: attachments,
            hasAttachmentFetcher: hasAttachmentFetcher,
            hasSessionFileDataFetcher: hasSessionFileDataFetcher
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
                ? .readMedia(output: output, isError: isError, filePath: filePath, startLine: startLine, attachments: attachments)
                : .none
        )
    }
}
