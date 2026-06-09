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
        hasAttachmentMediaSourceProvider: Bool,
        hasSessionFileDataFetcher: Bool,
        hasSessionFileMediaSourceProvider: Bool,
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
            hasAttachmentMediaSourceProvider: hasAttachmentMediaSourceProvider,
            hasSessionFileDataFetcher: hasSessionFileDataFetcher,
            hasSessionFileMediaSourceProvider: hasSessionFileMediaSourceProvider
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
