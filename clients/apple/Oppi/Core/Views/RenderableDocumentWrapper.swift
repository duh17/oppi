import SwiftUI

// MARK: - RenderableDocumentWrapper

/// SwiftUI bridge for ``RenderableDocumentView``.
///
/// Reads SwiftUI environment (review comment selection scope, allowsFullScreenExpansion),
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
    let reviewCommentSelectionContext: ReviewCommentSelectionContext?

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope
    @State private var showFullScreen = false

    init(
        config: RenderableDocumentView.Config,
        content: String,
        filePath: String?,
        presentation: FileContentPresentation,
        fullScreenContent: FullScreenCodeContent,
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil,
        renderedViewFactory: @escaping @MainActor () -> UIView
    ) {
        self.config = config
        self.content = content
        self.filePath = filePath
        self.presentation = presentation
        self.fullScreenContent = fullScreenContent
        self.reviewCommentSelectionContext = reviewCommentSelectionContext
        self.renderedViewFactory = renderedViewFactory
    }

    private var effectiveReviewCommentSelectionContext: ReviewCommentSelectionContext? {
        reviewCommentSelectionContext ?? reviewCommentSelectionScope?.makeContext(
            sourceLabel: config.label,
            filePath: filePath,
            languageHint: config.sourceLanguage
        )
    }

    var body: some View {
        _RenderableDocumentRepresentable(
            config: config,
            content: content,
            filePath: filePath,
            presentation: presentation,
            renderedViewFactory: renderedViewFactory,
            allowsFullScreenExpansion: allowsFullScreenExpansion,
            reviewCommentSelectionContext: effectiveReviewCommentSelectionContext,
            onExpandFullScreen: { showFullScreen = true }
        )
        .fullScreenViewer(
            isPresented: $showFullScreen,
            content: fullScreenContent,
            reviewCommentSelectionContext: effectiveReviewCommentSelectionContext
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
    let reviewCommentSelectionContext: ReviewCommentSelectionContext?
    let onExpandFullScreen: () -> Void

    func makeUIView(context: Context) -> RenderableDocumentView {
        let view = RenderableDocumentView(
            config: config,
            content: content,
            filePath: filePath,
            presentation: presentation,
            renderedContentView: renderedViewFactory(),
            allowsFullScreenExpansion: allowsFullScreenExpansion,
            reviewCommentSelectionContext: reviewCommentSelectionContext
        )
        view.onExpandFullScreen = onExpandFullScreen
        return view
    }

    func updateUIView(_ uiView: RenderableDocumentView, context: Context) {
        uiView.onExpandFullScreen = onExpandFullScreen
    }
}
