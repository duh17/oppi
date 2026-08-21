import SwiftUI

/// Rendered Mermaid diagram with source toggle.
///
/// All chrome handled by ``RenderableDocumentView``.
struct MermaidFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    var body: some View {
        RenderableDocumentWrapper(
            config: .mermaid,
            content: content,
            filePath: filePath,
            presentation: presentation,
            fullScreenContent: .mermaid(content: content, filePath: filePath),
            renderedViewFactory: { [content] in
                let layout = DocumentRenderPipeline.layoutGraphical(
                    parser: MermaidParser(),
                    renderer: MermaidRenderer(),
                    text: content,
                    config: RenderConfiguration(
                        fontSize: 14,
                        maxWidth: 600,
                        theme: ThemeRuntimeState.currentRenderTheme(),
                        displayMode: .document
                    )
                )
                return ZoomableGraphicalView(size: layout.size, draw: layout.draw)
            }
        )
    }
}
