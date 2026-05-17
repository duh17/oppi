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

    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @Environment(\.piQuickActionStore) private var piQuickActionStore

    var body: some View {
        RenderableDocumentWrapper(
            config: .html,
            content: content,
            filePath: filePath,
            presentation: presentation,
            fullScreenContent: .html(content: content, filePath: filePath),
            renderedViewFactory: { [content, filePath, piRouter, piQuickActionStore] in
                let sourceContext = SelectedTextSourceContext(
                    sessionId: "",
                    surface: .fullScreenSource,
                    filePath: filePath
                )
                let piHandler: ((String, PiQuickAction, UIViewController?) -> Void)? = piRouter.map { router in
                    { text, action, presentingViewController in
                        router.dispatch(
                            SelectedTextPiRequest(
                                action: action,
                                selectedText: text,
                                source: sourceContext
                            ),
                            presentingViewController: presentingViewController
                        )
                    }
                }
                return HTMLRenderView(
                    htmlString: content,
                    piActionHandler: piHandler,
                    piActionStore: piQuickActionStore
                )
            }
        )
    }
}
