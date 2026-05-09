import SwiftUI

// MARK: - RenderableDocumentWrapper

/// SwiftUI bridge for ``RenderableDocumentView``.
///
/// Reads SwiftUI environment (selected-text action scope, allowsFullScreenExpansion),
/// owns the `@State showFullScreen` + `.fullScreenViewer()` modifier,
/// and passes everything to the UIKit view.
///
/// Usage in `FileContentView`:
/// ```swift
/// case .markdown:
///     RenderableDocumentWrapper(
///         config: .markdown,
///         content: content,
///         filePath: filePath,
///         presentation: presentation,
///         fullScreenContent: .markdown(content: content, filePath: filePath),
///         renderedView: { makeMarkdownRenderedView(content, filePath) }
///     )
/// ```
struct RenderableDocumentWrapper: View {
    let config: RenderableDocumentView.Config
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation
    let fullScreenContent: FullScreenCodeContent
    let renderedViewFactory: @MainActor () -> UIView

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @Environment(\.selectedTextActionScope) private var selectedTextActionScope
    @State private var showFullScreen = false

    init(
        config: RenderableDocumentView.Config,
        content: String,
        filePath: String?,
        presentation: FileContentPresentation,
        fullScreenContent: FullScreenCodeContent,
        renderedViewFactory: @escaping @MainActor () -> UIView
    ) {
        self.config = config
        self.content = content
        self.filePath = filePath
        self.presentation = presentation
        self.fullScreenContent = fullScreenContent
        self.renderedViewFactory = renderedViewFactory
    }

    private var effectiveActionContext: SelectedTextActionContext? {
        selectedTextActionScope?.makeActionContext()
    }

    var body: some View {
        _RenderableDocumentRepresentable(
            config: config,
            content: content,
            filePath: filePath,
            presentation: presentation,
            renderedViewFactory: renderedViewFactory,
            allowsFullScreenExpansion: allowsFullScreenExpansion,
            piRouter: piRouter,
            onExpandFullScreen: { showFullScreen = true }
        )
        .fullScreenViewer(
            isPresented: $showFullScreen,
            content: fullScreenContent,
            selectedTextActionContext: effectiveActionContext
        )
    }
}

// MARK: - UIViewRepresentable Bridge

private struct _RenderableDocumentRepresentable: UIViewRepresentable {
    let config: RenderableDocumentView.Config
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation
    let renderedViewFactory: @MainActor () -> UIView
    let allowsFullScreenExpansion: Bool
    let piRouter: SelectedTextPiActionRouter?
    let onExpandFullScreen: () -> Void

    func makeUIView(context: Context) -> RenderableDocumentView {
        let view = RenderableDocumentView(
            config: config,
            content: content,
            filePath: filePath,
            presentation: presentation,
            renderedContentView: renderedViewFactory(),
            allowsFullScreenExpansion: allowsFullScreenExpansion,
            piRouter: piRouter
        )
        view.onExpandFullScreen = onExpandFullScreen
        return view
    }

    func updateUIView(_ uiView: RenderableDocumentView, context: Context) {
        uiView.onExpandFullScreen = onExpandFullScreen
    }
}
