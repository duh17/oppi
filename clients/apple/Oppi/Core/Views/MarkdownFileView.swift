import SwiftUI

// MARK: - MarkdownFileView

/// Rendered markdown with source toggle and full-screen reader mode.
///
/// All chrome (header, source toggle, expand, copy, context menu) is handled by
/// ``RenderableDocumentView``. This file only provides the configuration and
/// the rendered content view factory.
struct MarkdownFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation
    var workspaceID: String?
    var serverBaseURL: URL?
    var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?

    var body: some View {
        RenderableDocumentWrapper(
            config: .markdown,
            content: content,
            filePath: filePath,
            presentation: presentation,
            fullScreenContent: .markdown(content: content, filePath: filePath),
            renderedViewFactory: { [content, workspaceID, serverBaseURL, fetchWorkspaceFile] in
                let view = AssistantMarkdownContentView()
                view.backgroundColor = .clear
                view.fetchWorkspaceFile = fetchWorkspaceFile
                view.apply(configuration: .init(
                    content: content,
                    isStreaming: false,
                    themeID: ThemeRuntimeState.currentThemeID(),
                    textSelectionEnabled: true,
                    plainTextFallbackThreshold: presentation == .document ? nil : AssistantMarkdownContentView.Configuration.defaultPlainTextFallbackThreshold,
                    workspaceID: workspaceID,
                    serverBaseURL: serverBaseURL
                ))
                return view
            }
        )
    }
}
