import SwiftUI

// MARK: - FileContentView

/// Renders file content with type-appropriate formatting.
///
/// Dispatches to specialized sub-views based on detected file type:
/// - Code: UIKit-backed line numbers + syntax highlighting (NativeFullScreenCodeBody)
/// - Markdown: rendered prose with raw toggle
/// - JSON: pretty-printed with UIKit-backed colored keys/values
/// - Images: inline preview with tap-to-zoom
/// - Audio: inline playback rows for extracted data URIs
/// - Plain text: UIKit-backed monospaced with line numbers
struct FileContentView: View {
    let content: String
    let filePath: String?
    let startLine: Int
    let isError: Bool
    let presentation: FileContentPresentation

    /// Maximum lines to render inline (performance bound).
    nonisolated static let maxDisplayLines = 300

    init(
        content: String,
        filePath: String? = nil,
        startLine: Int = 1,
        isError: Bool = false,
        presentation: FileContentPresentation = .inline
    ) {
        self.content = content
        self.filePath = filePath
        self.startLine = max(1, startLine)
        self.isError = isError
        self.presentation = presentation
    }

    var body: some View {
        if isError {
            errorView
        } else if content.isEmpty {
            emptyView
        } else {
            contentView(for: FileType.detect(from: filePath, content: content))
        }
    }

    @ViewBuilder
    private func contentView(for fileType: FileType) -> some View {
        switch fileType {
        case .markdown:
            MarkdownFileView(content: content, filePath: filePath, presentation: presentation)
        case .html:
            HTMLFileView(content: content, filePath: filePath, presentation: presentation)
        case .code(let language):
            CodeFileView(content: content, language: language, startLine: startLine, presentation: presentation, filePath: filePath)
        case .json:
            JSONFileView(content: content, startLine: startLine, presentation: presentation, filePath: filePath)
        case .image:
            ImageOutputView(content: content)
        case .audio:
            AudioOutputView(content: content)
        case .plain:
            PlainTextView(content: content, startLine: startLine, presentation: presentation, filePath: filePath)
        }
    }

    private var errorView: some View {
        Text(content.prefix(2000))
            .font(.caption.monospaced())
            .foregroundStyle(.themeRed)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyView: some View {
        Text("Empty file")
            .font(.caption)
            .foregroundStyle(.themeComment)
            .italic()
            .padding(8)
    }
}
