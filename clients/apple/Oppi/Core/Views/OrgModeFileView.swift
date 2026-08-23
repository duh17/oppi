import SwiftUI

/// Rendered org mode with source toggle.
///
/// Uses the shared Markdown reader for visual output. Org conversion is
/// cancellable and off-main, then completed content enters the same virtualized
/// render-ahead pipeline as Markdown. All chrome is handled by
/// ``RenderableDocumentView``.
struct OrgModeFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    var body: some View {
        RenderableDocumentWrapper(
            config: .orgMode,
            content: content,
            filePath: filePath,
            presentation: presentation,
            fullScreenContent: .orgMode(content: content, filePath: filePath),
            renderedViewFactory: { [content, filePath, presentation] in
                let themeID = ThemeRuntimeState.currentThemeID()
                return NativeFullScreenMarkdownBody(
                    content: content,
                    stream: nil,
                    sourceFormat: .orgMode,
                    themeID: themeID,
                    palette: themeID.palette,
                    reviewCommentSelectionRouter: nil,
                    reviewCommentSourceContext: nil,
                    sourceFilePath: filePath,
                    maximumViewportHeight: presentation.viewportMaxHeight,
                    allowsVerticalBounce: presentation == .document,
                    allowsVerticalScrolling: presentation == .document
                )
            }
        )
    }
}
