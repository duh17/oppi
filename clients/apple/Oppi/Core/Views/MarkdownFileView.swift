import SwiftUI

// MARK: - MarkdownFileView

/// Rendered markdown with source toggle and full-screen reader mode.
///
/// All chrome (header, source toggle, expand, copy, context menu) is handled by
/// ``RenderableDocumentView``. This file only provides the configuration and
/// the rendered content view factory.
///
/// Workspace context (`workspaceID`, `serverBaseURL`, `fetchWorkspaceFile`) is passed
/// as explicit parameters — not via `@Environment` — because environment values are
/// unreliable across `UIViewControllerRepresentable` bridges. The file browser hit
/// this exact bug: `@Environment(\.apiClient)` was nil when evaluated across the
/// SwiftUI→UIKit boundary, silently breaking image loading.
struct MarkdownFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation
    var workspaceID: String?
    var serverBaseURL: URL?
    var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?
    var makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider?
    var reviewCommentSelectionContext: ReviewCommentSelectionContext?

    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope

    private var effectiveReviewCommentSelectionContext: ReviewCommentSelectionContext? {
        let sourceLabel = reviewCommentSelectionContext?.sourceLabel
            ?? filePath?.lastPathComponentForDisplay
            ?? "Markdown"
        if let reviewCommentSelectionContext {
            return reviewCommentSelectionContext.overriding(
                sourceLabel: sourceLabel,
                filePath: filePath,
                languageHint: "markdown"
            )
        }
        return reviewCommentSelectionScope?.makeContext(
            sourceLabel: sourceLabel,
            filePath: filePath,
            languageHint: "markdown"
        )
    }

    /// Workspace context for fullscreen expansion. When the user taps expand,
    /// the fullscreen viewer needs the same workspace context to render images.
    private var fullScreenWorkspaceContext: FullScreenCodeContent.WorkspaceContext? {
        guard let workspaceID, let serverBaseURL, let fetchWorkspaceFile else { return nil }
        return .init(
            workspaceID: workspaceID,
            serverBaseURL: serverBaseURL,
            fetchWorkspaceFile: fetchWorkspaceFile,
            makeMarkdownVideoSource: makeMarkdownVideoSource
        )
    }

    var body: some View {
        let reviewContext = effectiveReviewCommentSelectionContext
        let reviewSourceContext = reviewContext?.sourceContext(
            surface: .fullScreenMarkdown,
            filePath: filePath,
            languageHint: "markdown"
        )

        RenderableDocumentWrapper(
            config: .markdown,
            content: content,
            filePath: filePath,
            presentation: presentation,
            fullScreenContent: .markdown(
                content: content,
                filePath: filePath,
                workspaceContext: fullScreenWorkspaceContext
            ),
            reviewCommentSelectionContext: reviewContext,
            renderedViewFactory: { [content, filePath, workspaceID, serverBaseURL, fetchWorkspaceFile, makeMarkdownVideoSource, presentation, reviewContext, reviewSourceContext] in
                let themeID = ThemeRuntimeState.currentThemeID()
                if presentation == .document {
                    return NativeFullScreenMarkdownBody(
                        content: content,
                        stream: nil,
                        themeID: themeID,
                        palette: themeID.palette,
                        reviewCommentSelectionRouter: reviewContext?.dispatcher,
                        reviewCommentSourceContext: reviewSourceContext,
                        workspaceID: workspaceID,
                        serverBaseURL: serverBaseURL,
                        sourceFilePath: filePath,
                        fetchWorkspaceFile: fetchWorkspaceFile,
                        makeMarkdownVideoSource: makeMarkdownVideoSource
                    )
                }

                let view = AssistantMarkdownContentView()
                view.backgroundColor = .clear
                view.fetchWorkspaceFile = fetchWorkspaceFile
                view.makeMarkdownVideoSource = makeMarkdownVideoSource
                view.apply(configuration: .make(
                    content: content,
                    isStreaming: false,
                    themeID: themeID,
                    textSelectionEnabled: true,
                    reviewCommentSelectionRouter: reviewContext?.dispatcher,
                    reviewCommentSourceContext: reviewSourceContext,
                    workspaceID: workspaceID,
                    serverBaseURL: serverBaseURL,
                    sourceFilePath: filePath
                ))
                return view
            }
        )
    }
}
