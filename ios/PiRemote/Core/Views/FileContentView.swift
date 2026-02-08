import SwiftUI

// MARK: - FileType

/// Detected file type for content-aware rendering.
enum FileType: Equatable {
    case markdown
    case code(language: SyntaxLanguage)
    case json
    case image
    case plain

    /// Detect from file path extension (or well-known filenames).
    static func detect(from path: String?) -> FileType {
        guard let path else { return .plain }

        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()

        // Well-known filenames without extension
        switch filename {
        case "dockerfile", "containerfile", "makefile", "gnumakefile":
            return .code(language: .shell)
        default:
            break
        }

        guard !ext.isEmpty else { return .plain }

        switch ext {
        case "md", "mdx", "markdown":
            return .markdown
        case "jpg", "jpeg", "png", "gif", "webp", "svg", "ico", "bmp", "tiff":
            return .image
        default:
            let lang = SyntaxLanguage.detect(ext)
            if lang == .json { return .json }
            if lang != .unknown { return .code(language: lang) }
            return .plain
        }
    }

    var displayLabel: String {
        switch self {
        case .markdown: return "Markdown"
        case .code(let lang): return lang.displayName
        case .json: return "JSON"
        case .image: return "Image"
        case .plain: return "Text"
        }
    }
}

// MARK: - FileContentView

/// Renders file content with type-appropriate formatting.
///
/// Dispatches to specialized sub-views based on detected file type:
/// - Code: line numbers + syntax highlighting + horizontal scroll
/// - Markdown: rendered prose with raw toggle
/// - JSON: pretty-printed with colored keys/values
/// - Images: inline preview with tap-to-zoom
/// - Plain text: monospaced with line numbers
struct FileContentView: View {
    let content: String
    let filePath: String?
    let startLine: Int
    let isError: Bool

    /// Maximum lines to render (performance bound).
    static let maxDisplayLines = 300

    init(content: String, filePath: String? = nil, startLine: Int = 1, isError: Bool = false) {
        self.content = content
        self.filePath = filePath
        self.startLine = max(1, startLine)
        self.isError = isError
    }

    var body: some View {
        if isError {
            errorView
        } else if content.isEmpty {
            emptyView
        } else {
            contentView(for: FileType.detect(from: filePath))
        }
    }

    @ViewBuilder
    private func contentView(for fileType: FileType) -> some View {
        switch fileType {
        case .markdown:
            MarkdownFileView(content: content)
        case .code(let language):
            CodeFileView(content: content, language: language, startLine: startLine)
        case .json:
            JSONFileView(content: content, startLine: startLine)
        case .image:
            ImageOutputView(content: content)
        case .plain:
            PlainTextView(content: content, startLine: startLine)
        }
    }

    private var errorView: some View {
        Text(content.prefix(2000))
            .font(.caption.monospaced())
            .foregroundStyle(.tokyoRed)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyView: some View {
        Text("Empty file")
            .font(.caption)
            .foregroundStyle(.tokyoComment)
            .italic()
            .padding(8)
    }
}

// MARK: - CodeFileView

/// Source code with line numbers and syntax highlighting.
private struct CodeFileView: View {
    let content: String
    let language: SyntaxLanguage
    let startLine: Int

    @State private var highlighted: AttributedString?

    private var displayContent: String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, FileContentView.maxDisplayLines)
        return lines.prefix(lineCount).joined(separator: "\n")
    }

    var body: some View {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, FileContentView.maxDisplayLines)
        let isTruncated = lines.count > FileContentView.maxDisplayLines

        VStack(alignment: .leading, spacing: 0) {
            FileHeader(
                label: language.displayName,
                lineCount: lines.count,
                copyContent: content
            )

            codeArea(
                highlighted: highlighted ?? AttributedString(displayContent),
                lineCount: lineCount,
                startLine: startLine
            )

            if isTruncated {
                TruncationNotice(showing: lineCount, total: lines.count)
            }
        }
        .codeBlockChrome()
        .contextMenu {
            Button("Copy File Content", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = content
            }
        }
        .task(id: content.count) {
            let lang = language
            let text = displayContent
            let result = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlight(text, language: lang)
            }.value
            highlighted = result
        }
    }
}

// MARK: - MarkdownFileView

/// Rendered markdown with raw/rendered toggle.
private struct MarkdownFileView: View {
    let content: String

    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "doc.richtext")
                    .font(.caption)
                    .foregroundStyle(.tokyoCyan)
                Text("Markdown")
                    .font(.caption2.bold())
                    .foregroundStyle(.tokyoFgDim)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showRaw.toggle() }
                } label: {
                    Text(showRaw ? "Rendered" : "Source")
                        .font(.caption2)
                        .foregroundStyle(.tokyoBlue)
                }
                .buttonStyle(.plain)

                CopyButton(content: content)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.tokyoBgHighlight)

            // Content
            ScrollView(.vertical) {
                Group {
                    if showRaw {
                        Text(content)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tokyoFg)
                    } else {
                        MarkdownText(content)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 500)
        }
        .codeBlockChrome()
        .contextMenu {
            Button("Copy Content", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = content
            }
        }
    }
}

// MARK: - JSONFileView

/// Pretty-printed JSON with colored keys and values.
private struct JSONFileView: View {
    let content: String
    let startLine: Int

    @State private var highlighted: AttributedString?

    private var prettyContent: String {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: json,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let result = String(data: pretty, encoding: .utf8)
        else {
            return content
        }
        return result
    }

    private var displayLines: (text: String, lineCount: Int, totalLines: Int) {
        let lines = prettyContent.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, FileContentView.maxDisplayLines)
        let text = lines.prefix(lineCount).joined(separator: "\n")
        return (text, lineCount, lines.count)
    }

    var body: some View {
        let info = displayLines
        let isTruncated = info.totalLines > FileContentView.maxDisplayLines

        VStack(alignment: .leading, spacing: 0) {
            FileHeader(
                label: "JSON",
                lineCount: info.totalLines,
                copyContent: content
            )

            codeArea(
                highlighted: highlighted ?? AttributedString(info.text),
                lineCount: info.lineCount,
                startLine: startLine
            )

            if isTruncated {
                TruncationNotice(showing: info.lineCount, total: info.totalLines)
            }
        }
        .codeBlockChrome()
        .contextMenu {
            Button("Copy JSON", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = content
            }
        }
        .task(id: content.count) {
            let text = info.text
            let result = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlight(text, language: .json)
            }.value
            highlighted = result
        }
    }
}

// MARK: - PlainTextView

/// Monospaced text with line numbers.
private struct PlainTextView: View {
    let content: String
    let startLine: Int

    var body: some View {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, FileContentView.maxDisplayLines)
        let displayText = lines.prefix(lineCount).joined(separator: "\n")
        let isTruncated = lines.count > FileContentView.maxDisplayLines

        VStack(alignment: .leading, spacing: 0) {
            codeArea(
                text: displayText,
                lineCount: lineCount,
                startLine: startLine
            )

            if isTruncated {
                TruncationNotice(showing: lineCount, total: lines.count)
            }
        }
        .codeBlockChrome()
        .contextMenu {
            Button("Copy Content", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = content
            }
        }
    }
}

// MARK: - ImageOutputView

/// Renders image content via ImageExtractor.
private struct ImageOutputView: View {
    let content: String

    var body: some View {
        let images = ImageExtractor.extract(from: content)

        if images.isEmpty {
            Text("Image file (binary content not displayable)")
                .font(.caption)
                .foregroundStyle(.tokyoComment)
                .italic()
                .padding(8)
        } else {
            VStack(spacing: 8) {
                ForEach(images) { image in
                    ImageBlobView(base64: image.base64, mimeType: image.mimeType)
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Shared Components

/// Header bar with language label, line count, and copy button.
private struct FileHeader: View {
    let label: String
    let lineCount: Int
    let copyContent: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.tokyoCyan)
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.tokyoFgDim)
            Text("\(lineCount) lines")
                .font(.caption2)
                .foregroundStyle(.tokyoComment)

            Spacer()

            CopyButton(content: copyContent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.tokyoBgHighlight)
    }
}

/// Small copy button with "Copied" feedback.
private struct CopyButton: View {
    let content: String
    @State private var isCopied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = content
            isCopied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                isCopied = false
            }
        } label: {
            Label(
                isCopied ? "Copied" : "Copy",
                systemImage: isCopied ? "checkmark" : "doc.on.doc"
            )
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tokyoFgDim)
    }
}

/// "Showing X of Y lines" indicator.
private struct TruncationNotice: View {
    let showing: Int
    let total: Int

    var body: some View {
        Text("Showing \(showing) of \(total) lines")
            .font(.caption2)
            .foregroundStyle(.tokyoComment)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color.tokyoBgHighlight.opacity(0.5))
    }
}

// MARK: - Code Area Builder

/// Two-column code area: line number gutter + horizontally-scrollable code.
///
/// Used by `codeArea(highlighted:...)` and `codeArea(text:...)` below.
/// Line numbers stay fixed while code scrolls horizontally.
private struct CodeArea: View {
    let lineNumbers: String
    let gutterWidth: CGFloat
    let codeContent: AnyView

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                // Gutter
                Text(lineNumbers)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tokyoComment)
                    .multilineTextAlignment(.trailing)
                    .frame(width: gutterWidth, alignment: .trailing)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)

                // Separator
                Rectangle()
                    .fill(Color.tokyoComment.opacity(0.2))
                    .frame(width: 1)

                // Code
                ScrollView(.horizontal, showsIndicators: false) {
                    codeContent
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: 500)
    }
}

/// Build a code area with syntax-highlighted `AttributedString`.
@MainActor @ViewBuilder
private func codeArea(
    highlighted: AttributedString,
    lineCount: Int,
    startLine: Int
) -> some View {
    let (numbers, width) = lineNumberInfo(lineCount: lineCount, startLine: startLine)
    CodeArea(
        lineNumbers: numbers,
        gutterWidth: width,
        codeContent: AnyView(
            Text(highlighted)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        )
    )
}

/// Build a code area with plain (unhighlighted) text.
@MainActor @ViewBuilder
private func codeArea(
    text: String,
    lineCount: Int,
    startLine: Int
) -> some View {
    let (numbers, width) = lineNumberInfo(lineCount: lineCount, startLine: startLine)
    CodeArea(
        lineNumbers: numbers,
        gutterWidth: width,
        codeContent: AnyView(
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tokyoFg)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        )
    )
}

/// Generate line number string and compute gutter width.
func lineNumberInfo(lineCount: Int, startLine: Int) -> (numbers: String, width: CGFloat) {
    let endLine = startLine + lineCount - 1
    let numbers = (startLine...endLine).map(String.init).joined(separator: "\n")
    let digits = max(String(endLine).count, 2)
    let width = CGFloat(digits) * 7.5
    return (numbers, width)
}

// MARK: - View Modifiers

private extension View {
    /// Standard chrome for code block containers (dark bg, rounded corners, border).
    func codeBlockChrome() -> some View {
        self
            .background(Color.tokyoBgDark)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.tokyoComment.opacity(0.35), lineWidth: 1)
            )
    }
}
