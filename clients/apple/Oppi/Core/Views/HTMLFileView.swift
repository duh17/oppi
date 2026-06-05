import SwiftUI
import UIKit

/// Rendered HTML with source toggle and full-screen support.
///
/// All chrome handled by ``RenderableDocumentView``.
/// Delegates to ``HTMLRenderView`` for WKWebView management —
/// deferred loading, navigation interception, popup blocking,
/// and process-termination recovery.
struct HTMLFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope

    var body: some View {
        RenderableDocumentWrapper(
            config: .html,
            content: content,
            filePath: filePath,
            presentation: presentation,
            fullScreenContent: .html(content: content, filePath: filePath),
            renderedViewFactory: { [content, filePath, reviewCommentSelectionScope] in
                let selectionContext = reviewCommentSelectionScope?.makeContext(filePath: filePath)
                return HTMLRenderView(
                    htmlString: content,
                    reviewCommentRouter: selectionContext?.dispatcher,
                    sourceContext: selectionContext?.sourceContextIgnoringSurfaceOverride(
                        surface: .fullScreenSource,
                        filePath: filePath
                    )
                )
            }
        )
    }
}
