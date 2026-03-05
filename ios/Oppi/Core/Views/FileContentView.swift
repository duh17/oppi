import SwiftUI

// MARK: - FileContentView

/// Renders file content with type-appropriate formatting.
///
/// Dispatches to specialized sub-views based on detected file type:
/// - Code: line numbers + syntax highlighting + horizontal scroll
/// - Markdown: rendered prose with raw toggle
/// - JSON: pretty-printed with colored keys/values
/// - Images: inline preview with tap-to-zoom
/// - Audio: inline playback rows for extracted data URIs
/// - Plain text: monospaced with line numbers
struct FileContentView: View {
    let content: String
    let filePath: String?
    let startLine: Int
    let isError: Bool
    let presentation: FileContentPresentation

    /// Maximum lines to render (performance bound).
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
        case .code(let language):
            CodeFileView(content: content, language: language, startLine: startLine, presentation: presentation)
        case .json:
            JSONFileView(content: content, startLine: startLine, presentation: presentation)
        case .image:
            ImageOutputView(content: content)
        case .audio:
            AudioOutputView(content: content)
        case .plain:
            PlainTextView(content: content, startLine: startLine, presentation: presentation)
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

// MARK: - CodeFileView

/// Source code with line numbers and syntax highlighting.
private struct CodeFileView: View {
    let content: String
    let language: SyntaxLanguage
    let startLine: Int
    let presentation: FileContentPresentation

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @State private var highlighted: AttributedString?
    @State private var showFullScreen = false

    private var displayContent: String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, FileContentView.maxDisplayLines)
        return lines.prefix(lineCount).joined(separator: "\n")
    }

    var body: some View {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, FileContentView.maxDisplayLines)
        let isTruncated = lines.count > FileContentView.maxDisplayLines

        let codeBody = codeArea(
            highlighted: highlighted ?? AttributedString(displayContent),
            lineCount: lineCount,
            startLine: startLine,
            maxHeight: presentation.viewportMaxHeight
        )

        Group {
            if presentation.usesInlineChrome {
                VStack(alignment: .leading, spacing: 0) {
                    FileHeader(
                        label: language.displayName,
                        lineCount: lines.count,
                        copyContent: content,
                        showCopy: false,
                        onExpand: (presentation.allowsExpansionAffordance && allowsFullScreenExpansion) ? { showFullScreen = true } : nil
                    )

                    codeBody

                    if isTruncated {
                        TruncationNotice(showing: lineCount, total: lines.count)
                    }
                }
                .codeBlockChrome(showBorder: false)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    codeBody

                    if isTruncated {
                        TruncationNotice(showing: lineCount, total: lines.count)
                    }
                }
            }
        }
        .sheet(isPresented: $showFullScreen) {
            FullScreenCodeView(content: .code(
                content: content, language: language.displayName, filePath: nil, startLine: startLine
            ))
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task(id: content.count) {
            let lang = language
            let text = displayContent
            let result = await Task.detached(priority: .userInitiated) {
                AttributedString(SyntaxHighlighter.highlight(text, language: lang))
            }.value
            highlighted = result
        }
    }
}

// MARK: - MarkdownFileView

/// Rendered markdown with source toggle and full-screen reader mode.
private struct MarkdownFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @State private var showRaw = false
    @State private var showFullScreen = false

    private var lineCount: Int {
        content.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        Group {
            if presentation.usesInlineChrome {
                inlineBody
            } else {
                documentBody
            }
        }
        .sheet(isPresented: $showFullScreen) {
            FullScreenMarkdownView(content: content, filePath: filePath, showSource: showRaw)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "doc.richtext")
                    .font(.caption)
                    .foregroundStyle(.themeCyan)
                Text("Markdown")
                    .font(.caption2.bold())
                    .foregroundStyle(.themeFgDim)
                Text("\(lineCount) lines")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showRaw.toggle() }
                } label: {
                    Text(showRaw ? "Reader" : "Source")
                        .font(.caption2)
                        .foregroundStyle(.themeBlue)
                }
                .buttonStyle(.plain)

                if allowsFullScreenExpansion {
                    Button {
                        showFullScreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .foregroundStyle(.themeFgDim)
                    }
                    .buttonStyle(.plain)
                }

                CopyButton(content: content)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.themeBgHighlight)

            // Content
            ScrollView(.vertical) {
                Group {
                    if showRaw {
                        Text(content)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.themeFg)
                    } else {
                        MarkdownText(content)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: presentation.viewportMaxHeight)
        }
        .codeBlockChrome()
        .contextMenu {
            if allowsFullScreenExpansion {
                Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    showFullScreen = true
                }
            }
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = content
            }
        }
    }

    private var documentBody: some View {
        ScrollView(.vertical) {
            Group {
                if showRaw {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.themeFg)
                } else {
                    MarkdownText(content)
                        .allowsFullScreenExpansion(false)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Full Screen Markdown View

/// Full-screen markdown reader with source toggle.
private struct FullScreenMarkdownView: View {
    let content: String
    let filePath: String?

    @State private var showSource: Bool
    @Environment(\.dismiss) private var dismiss

    init(content: String, filePath: String?, showSource: Bool = false) {
        self.content = content
        self.filePath = filePath
        _showSource = State(initialValue: showSource)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                Group {
                    if showSource {
                        Text(content)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.themeFg)
                    } else {
                        MarkdownText(content)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.themeBg)
            .allowsFullScreenExpansion(false)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.themeCyan)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        if let path = filePath {
                            Text(path.shortenedPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.themeFg)
                                .lineLimit(1)
                        }
                        Text("Markdown")
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(showSource ? "Reader" : "Source") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showSource.toggle()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.themeBlue)

                    Button {
                        UIPasteboard.general.string = content
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.themeFgDim)
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.themeBgHighlight, for: .navigationBar)
        }
    }
}

// MARK: - JSONFileView

/// Pretty-printed JSON with colored keys and values.
///
/// Both pretty-printing (JSONSerialization) and syntax highlighting run
/// off the main thread to avoid blocking scrolling on large JSON files.
private struct JSONFileView: View {
    let content: String
    let startLine: Int
    let presentation: FileContentPresentation

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion

    /// Combined pretty-print + highlight result, computed off main thread.
    @State private var prepared: JSONPrepared?
    @State private var showFullScreen = false

    var body: some View {
        let info = prepared ?? JSONPrepared.placeholder(from: content)
        let isTruncated = info.totalLines > FileContentView.maxDisplayLines

        Group {
            if presentation.usesInlineChrome {
                VStack(alignment: .leading, spacing: 0) {
                    FileHeader(
                        label: "JSON",
                        lineCount: info.totalLines,
                        copyContent: content,
                        onExpand: (presentation.allowsExpansionAffordance && allowsFullScreenExpansion) ? { showFullScreen = true } : nil
                    )

                    codeArea(
                        highlighted: info.highlighted ?? AttributedString(info.displayText),
                        lineCount: info.displayLineCount,
                        startLine: startLine,
                        maxHeight: presentation.viewportMaxHeight
                    )

                    if isTruncated {
                        TruncationNotice(showing: info.displayLineCount, total: info.totalLines)
                    }
                }
                .codeBlockChrome()
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = content
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    codeArea(
                        highlighted: info.highlighted ?? AttributedString(info.displayText),
                        lineCount: info.displayLineCount,
                        startLine: startLine,
                        maxHeight: nil
                    )

                    if isTruncated {
                        TruncationNotice(showing: info.displayLineCount, total: info.totalLines)
                    }
                }
            }
        }
        .sheet(isPresented: $showFullScreen) {
            FullScreenCodeView(content: .code(
                content: content, language: "json", filePath: nil, startLine: startLine
            ))
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task(id: content.count) {
            let raw = content
            prepared = await Task.detached(priority: .userInitiated) {
                JSONPrepared.prepare(raw)
            }.value
        }
    }
}

/// Pre-computed JSON display data — all expensive work done off main thread.
private struct JSONPrepared: Sendable {
    let displayText: String
    let displayLineCount: Int
    let totalLines: Int
    let highlighted: AttributedString?

    /// Quick placeholder from raw content (no parsing, no highlighting).
    static func placeholder(from content: String) -> Self {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, FileContentView.maxDisplayLines)
        let text = lines.prefix(lineCount).joined(separator: "\n")
        return Self(displayText: text, displayLineCount: lineCount, totalLines: lines.count, highlighted: nil)
    }

    /// Full preparation: pretty-print + syntax highlight.
    static func prepare(_ content: String) -> Self {
        let pretty: String
        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let result = String(data: prettyData, encoding: .utf8) {
            pretty = result
        } else {
            pretty = content
        }

        let lines = pretty.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, FileContentView.maxDisplayLines)
        let displayText = lines.prefix(lineCount).joined(separator: "\n")
        let highlighted = AttributedString(SyntaxHighlighter.highlight(displayText, language: .json))

        return Self(displayText: displayText, displayLineCount: lineCount, totalLines: lines.count, highlighted: highlighted)
    }
}

// MARK: - PlainTextView

/// Monospaced text with line numbers.
private struct PlainTextView: View {
    let content: String
    let startLine: Int
    let presentation: FileContentPresentation

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @State private var showFullScreen = false

    var body: some View {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, FileContentView.maxDisplayLines)
        let displayText = lines.prefix(lineCount).joined(separator: "\n")
        let isTruncated = lines.count > FileContentView.maxDisplayLines

        Group {
            if presentation.usesInlineChrome {
                VStack(alignment: .leading, spacing: 0) {
                    codeArea(
                        text: displayText,
                        lineCount: lineCount,
                        startLine: startLine,
                        maxHeight: presentation.viewportMaxHeight
                    )

                    if isTruncated {
                        TruncationNotice(showing: lineCount, total: lines.count)
                    }
                }
                .codeBlockChrome()
                .contextMenu {
                    if allowsFullScreenExpansion {
                        Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                            showFullScreen = true
                        }
                    }
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = content
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    codeArea(
                        text: displayText,
                        lineCount: lineCount,
                        startLine: startLine,
                        maxHeight: nil
                    )

                    if isTruncated {
                        TruncationNotice(showing: lineCount, total: lines.count)
                    }
                }
            }
        }
        .sheet(isPresented: $showFullScreen) {
            FullScreenCodeView(content: .code(
                content: content, language: nil, filePath: nil, startLine: startLine
            ))
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - ImageOutputView

/// Renders image content via ImageExtractor.
///
/// Runs regex extraction off main thread to avoid blocking on large
/// base64 blobs during scroll.
private struct ImageOutputView: View {
    let content: String

    @State private var images: [ImageExtractor.ExtractedImage]?

    var body: some View {
        if let images {
            if images.isEmpty {
                Text("Image file (binary content not displayable)")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
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
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .task {
                    let text = content
                    images = await Task.detached(priority: .userInitiated) {
                        ImageExtractor.extract(from: text)
                    }.value
                }
        }
    }
}

// MARK: - AudioOutputView

/// Renders audio content via AudioExtractor.
private struct AudioOutputView: View {
    let content: String

    @State private var clips: [AudioExtractor.ExtractedAudio]?

    var body: some View {
        if let clips {
            if clips.isEmpty {
                Text("Audio file (binary content not displayable)")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .italic()
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(clips.enumerated()), id: \.offset) { index, clip in
                        AsyncAudioBlob(
                            id: "file-audio-\(index)-\(clip.base64.prefix(24))",
                            base64: clip.base64,
                            mimeType: clip.mimeType
                        )
                    }
                }
                .padding(8)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .task {
                    let text = content
                    clips = await Task.detached(priority: .userInitiated) {
                        AudioExtractor.extract(from: text)
                    }.value
                }
        }
    }
}

// MARK: - Shared Components

/// Header bar with language label, line count, and copy button.
private struct FileHeader: View {
    let label: String
    let lineCount: Int
    let copyContent: String
    var showCopy = true
    var onExpand: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.themeCyan)
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.themeFgDim)
            Text("\(lineCount) lines")
                .font(.caption2)
                .foregroundStyle(.themeComment)

            Spacer()

            if let onExpand {
                Button { onExpand() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeFgDim)
            }

            if showCopy {
                CopyButton(content: copyContent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.themeBgHighlight)
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
        .foregroundStyle(.themeFgDim)
    }
}

/// "Showing X of Y lines" indicator.
private struct TruncationNotice: View {
    let showing: Int
    let total: Int

    var body: some View {
        Text("Showing \(showing) of \(total) lines")
            .font(.caption2)
            .foregroundStyle(.themeComment)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color.themeBgHighlight.opacity(0.5))
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
    let maxHeight: CGFloat?

    var body: some View {
        Group {
            if let maxHeight {
                codeScrollView
                    .frame(maxHeight: maxHeight)
            } else {
                codeScrollView
            }
        }
    }

    private var codeScrollView: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                // Gutter
                Text(lineNumbers)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.themeComment)
                    .multilineTextAlignment(.trailing)
                    .frame(width: gutterWidth, alignment: .trailing)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)

                // Separator
                Rectangle()
                    .fill(Color.themeComment.opacity(0.2))
                    .frame(width: 1)

                // Code
                ScrollView(.horizontal, showsIndicators: false) {
                    codeContent
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}

/// Build a code area with syntax-highlighted `AttributedString`.
@MainActor @ViewBuilder
private func codeArea(
    highlighted: AttributedString,
    lineCount: Int,
    startLine: Int,
    maxHeight: CGFloat?
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
        ),
        maxHeight: maxHeight
    )
}

/// Build a code area with plain (unhighlighted) text.
@MainActor @ViewBuilder
private func codeArea(
    text: String,
    lineCount: Int,
    startLine: Int,
    maxHeight: CGFloat?
) -> some View {
    let (numbers, width) = lineNumberInfo(lineCount: lineCount, startLine: startLine)
    CodeArea(
        lineNumbers: numbers,
        gutterWidth: width,
        codeContent: AnyView(
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        ),
        maxHeight: maxHeight
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
    /// Standard chrome for code block containers (dark bg, rounded corners).
    /// Border is optional for cleaner reader-style presentation.
    func codeBlockChrome(showBorder: Bool = true) -> some View {
        self
            .background(Color.themeBgDark)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if showBorder {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.themeComment.opacity(0.35), lineWidth: 1)
                }
            }
    }
}
