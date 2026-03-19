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

// MARK: - CodeFileView

/// Source code with line numbers and syntax highlighting.
///
/// Uses ``NativeCodeBodyView`` (UIKit `UITextView` + gutter) for all
/// presentation modes. Inline wraps with SwiftUI chrome (header,
/// truncation notice, code block border).
private struct CodeFileView: View {
    let content: String
    let language: SyntaxLanguage
    let startLine: Int
    let presentation: FileContentPresentation
    let filePath: String?

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @State private var showFullScreen = false

    private var sourceContext: SelectedTextSourceContext {
        SelectedTextSourceContext(
            sessionId: "",
            surface: .fullScreenCode,
            filePath: filePath,
            languageHint: language.displayName
        )
    }

    var body: some View {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, FileContentView.maxDisplayLines)
        let isTruncated = lines.count > FileContentView.maxDisplayLines
        let displayContent = isTruncated
            ? lines.prefix(lineCount).joined(separator: "\n")
            : content
        let hasFullScreenAffordance = presentation.allowsExpansionAffordance && allowsFullScreenExpansion

        Group {
            if presentation.usesInlineChrome {
                VStack(alignment: .leading, spacing: 0) {
                    FileHeader(
                        label: language.displayName,
                        lineCount: lines.count,
                        copyContent: content,
                        showCopy: false,
                        onExpand: hasFullScreenAffordance ? { showFullScreen = true } : nil
                    )

                    NativeCodeBodyView(
                        content: displayContent,
                        language: language.displayName,
                        startLine: startLine,
                        maxHeight: presentation.viewportMaxHeight
                    )

                    if isTruncated {
                        TruncationNotice(showing: lineCount, total: lines.count)
                    }
                }
                .codeBlockChrome(showBorder: false)
            } else {
                NativeCodeBodyView(
                    content: content,
                    language: language.displayName,
                    startLine: startLine,
                    selectedTextSourceContext: piRouter != nil ? sourceContext : nil
                )
            }
        }
        .sheet(isPresented: $showFullScreen) {
            FullScreenCodeView(
                content: .code(
                    content: content, language: language.displayName, filePath: filePath, startLine: startLine
                ),
                selectedTextPiRouter: piRouter
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
    @Environment(\.selectedTextPiActionRouter) private var piRouter
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
            FullScreenCodeView(
                content: .markdown(content: content, filePath: filePath),
                selectedTextPiRouter: piRouter
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var inlineBody: some View {
        let hasFullScreenAffordance = presentation.allowsExpansionAffordance && allowsFullScreenExpansion
        let inlineSelectionEnabled = ExpandableInlineTextSelectionPolicy.allowsInlineSelection(
            hasFullScreenAffordance: hasFullScreenAffordance
        )

        return VStack(alignment: .leading, spacing: 0) {
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

                if hasFullScreenAffordance {
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
                            .applyInlineTextSelectionPolicy(inlineSelectionEnabled)
                    } else {
                        MarkdownContentViewWrapper(
                            content: content,
                            textSelectionEnabled: inlineSelectionEnabled
                        )
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: presentation.viewportMaxHeight)
        }
        .codeBlockChrome()
        .contextMenu {
            if hasFullScreenAffordance {
                Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    showFullScreen = true
                }
            }
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = content
            }
        }
    }

    private var markdownSourceContext: SelectedTextSourceContext {
        SelectedTextSourceContext(
            sessionId: "",
            surface: .fullScreenCode,
            filePath: filePath,
            languageHint: "markdown"
        )
    }

    private var documentBody: some View {
        Group {
            if showRaw {
                NativeCodeBodyView(
                    content: content,
                    language: "markdown",
                    startLine: 1,
                    selectedTextSourceContext: piRouter != nil ? markdownSourceContext : nil
                )
            } else {
                ScrollView(.vertical) {
                    MarkdownContentViewWrapper(
                        content: content,
                        plainTextFallbackThreshold: nil
                    )
                    .allowsFullScreenExpansion(false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
    @Environment(\.selectedTextPiActionRouter) private var piRouter

    init(content: String, filePath: String?, showSource: Bool = false) {
        self.content = content
        self.filePath = filePath
        _showSource = State(initialValue: showSource)
    }

    private var sourceContext: SelectedTextSourceContext {
        SelectedTextSourceContext(
            sessionId: "",
            surface: .fullScreenCode,
            filePath: filePath,
            languageHint: "markdown"
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if showSource {
                    NativeCodeBodyView(
                        content: content,
                        language: "markdown",
                        startLine: 1,
                        selectedTextSourceContext: piRouter != nil ? sourceContext : nil
                    )
                } else {
                    ScrollView(.vertical) {
                        MarkdownContentViewWrapper(
                            content: content,
                            plainTextFallbackThreshold: nil
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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

// MARK: - HTMLFileView

/// Rendered HTML with source toggle and full-screen support.
///
/// - Document mode: renders WebKit by default with a floating Source/Preview toggle
/// - Inline mode: shows UIKit syntax-highlighted source with a "Preview" button
///   that opens full-screen rendered view (avoids heavy WebKit views inline in
///   the timeline)
private struct HTMLFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @State private var showSource = false
    @State private var showFullScreen = false

    private var lineCount: Int {
        content.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Pi action handler for WKWebView text selection.
    /// Routes through the environment router when available, falls back to clipboard.
    private var piWebViewHandler: (String, SelectedTextPiActionKind) -> Void {
        let path = filePath
        let router = piRouter
        return { text, actionKind in
            let request = SelectedTextPiRequest(
                action: actionKind,
                selectedText: text,
                source: SelectedTextSourceContext(
                    sessionId: "",
                    surface: .fullScreenSource,
                    filePath: path
                )
            )
            if let router {
                router.dispatch(request)
            } else {
                UIPasteboard.general.string = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            }
        }
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
            FullScreenCodeView(
                content: .html(content: content, filePath: filePath),
                selectedTextPiRouter: piRouter
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Inline body (tool output context)

    private var inlineBody: some View {
        let hasFullScreenAffordance = presentation.allowsExpansionAffordance && allowsFullScreenExpansion
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let displayLineCount = min(lines.count, FileContentView.maxDisplayLines)
        let isTruncated = lines.count > FileContentView.maxDisplayLines
        let displayContent = lines.prefix(displayLineCount).joined(separator: "\n")

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(.themeCyan)
                Text("HTML")
                    .font(.caption2.bold())
                    .foregroundStyle(.themeFgDim)
                Text("\(lineCount) lines")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)

                Spacer()

                if hasFullScreenAffordance {
                    Button {
                        showFullScreen = true
                    } label: {
                        Label("Preview", systemImage: "eye")
                            .font(.caption2)
                            .foregroundStyle(.themeBlue)
                    }
                    .buttonStyle(.plain)

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

            // Source code (always source in inline mode for performance)
            NativeCodeBodyView(
                content: displayContent,
                language: "html",
                startLine: 1,
                maxHeight: presentation.viewportMaxHeight
            )

            if isTruncated {
                TruncationNotice(showing: displayLineCount, total: lines.count)
            }
        }
        .codeBlockChrome()
        .contextMenu {
            if hasFullScreenAffordance {
                Button("Preview HTML", systemImage: "eye") {
                    showFullScreen = true
                }
                Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    showFullScreen = true
                }
            }
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = content
            }
        }
    }

    // MARK: - Document body (file browser, remote file)

    private var sourceContext: SelectedTextSourceContext {
        SelectedTextSourceContext(
            sessionId: "",
            surface: .fullScreenCode,
            filePath: filePath,
            languageHint: "html"
        )
    }

    private var documentBody: some View {
        ZStack(alignment: .topTrailing) {
            if showSource {
                NativeCodeBodyView(
                    content: content,
                    language: "html",
                    startLine: 1,
                    selectedTextSourceContext: piRouter != nil ? sourceContext : nil
                )
            } else {
                HTMLWebView(
                    htmlString: content,
                    baseFileName: filePath ?? "preview.html",
                    piActionHandler: piWebViewHandler
                )
                .ignoresSafeArea(edges: .bottom)
            }

            // Floating toggle
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showSource.toggle() }
            } label: {
                Label(
                    showSource ? "Preview" : "Source",
                    systemImage: showSource ? "eye" : "curlybraces"
                )
                .font(.caption2.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .padding(.top, 8)
        }
    }
}

// MARK: - JSONFileView

/// Pretty-printed JSON with colored keys and values.
///
/// Pretty-printing runs off the main thread. The UIKit code body
/// handles syntax highlighting internally.
private struct JSONFileView: View {
    let content: String
    let startLine: Int
    let presentation: FileContentPresentation
    let filePath: String?

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @State private var prettyContent: String?
    @State private var showFullScreen = false

    private var sourceContext: SelectedTextSourceContext {
        SelectedTextSourceContext(
            sessionId: "",
            surface: .fullScreenCode,
            filePath: filePath,
            languageHint: "json"
        )
    }

    var body: some View {
        let effectiveContent = prettyContent ?? content
        let lines = effectiveContent.split(separator: "\n", omittingEmptySubsequences: false)
        let hasFullScreenAffordance = presentation.allowsExpansionAffordance && allowsFullScreenExpansion

        Group {
            if presentation.usesInlineChrome {
                let lineCount = min(lines.count, FileContentView.maxDisplayLines)
                let isTruncated = lines.count > FileContentView.maxDisplayLines
                let displayContent = isTruncated
                    ? lines.prefix(lineCount).joined(separator: "\n")
                    : effectiveContent

                VStack(alignment: .leading, spacing: 0) {
                    FileHeader(
                        label: "JSON",
                        lineCount: lines.count,
                        copyContent: content,
                        onExpand: hasFullScreenAffordance ? { showFullScreen = true } : nil
                    )

                    NativeCodeBodyView(
                        content: displayContent,
                        language: "json",
                        startLine: startLine,
                        maxHeight: presentation.viewportMaxHeight
                    )

                    if isTruncated {
                        TruncationNotice(showing: lineCount, total: lines.count)
                    }
                }
                .codeBlockChrome()
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = content
                    }
                }
            } else {
                NativeCodeBodyView(
                    content: effectiveContent,
                    language: "json",
                    startLine: startLine,
                    selectedTextSourceContext: piRouter != nil ? sourceContext : nil
                )
            }
        }
        .id(prettyContent != nil ? 1 : 0)
        .sheet(isPresented: $showFullScreen) {
            FullScreenCodeView(
                content: .code(
                    content: content, language: "json", filePath: filePath, startLine: startLine
                ),
                selectedTextPiRouter: piRouter
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task(id: content.count) {
            let raw = content
            prettyContent = await Task.detached(priority: .userInitiated) {
                Self.prettyPrint(raw)
            }.value
        }
    }

    /// Pretty-print JSON, returning the original if parsing fails.
    nonisolated private static func prettyPrint(_ content: String) -> String {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
              ),
              let result = String(data: prettyData, encoding: .utf8) else {
            return content
        }
        return result
    }
}

// MARK: - PlainTextView

/// Monospaced text with line numbers (no syntax highlighting).
private struct PlainTextView: View {
    let content: String
    let startLine: Int
    let presentation: FileContentPresentation
    let filePath: String?

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @State private var showFullScreen = false

    private var sourceContext: SelectedTextSourceContext {
        SelectedTextSourceContext(
            sessionId: "",
            surface: .fullScreenSource,
            filePath: filePath
        )
    }

    var body: some View {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let hasFullScreenAffordance = presentation.allowsExpansionAffordance && allowsFullScreenExpansion

        Group {
            if presentation.usesInlineChrome {
                let lineCount = min(lines.count, FileContentView.maxDisplayLines)
                let isTruncated = lines.count > FileContentView.maxDisplayLines
                let displayContent = isTruncated
                    ? lines.prefix(lineCount).joined(separator: "\n")
                    : content

                VStack(alignment: .leading, spacing: 0) {
                    NativeCodeBodyView(
                        content: displayContent,
                        language: nil,
                        startLine: startLine,
                        maxHeight: presentation.viewportMaxHeight
                    )

                    if isTruncated {
                        TruncationNotice(showing: lineCount, total: lines.count)
                    }
                }
                .codeBlockChrome()
                .contextMenu {
                    if hasFullScreenAffordance {
                        Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                            showFullScreen = true
                        }
                    }
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = content
                    }
                }
            } else {
                NativeCodeBodyView(
                    content: content,
                    language: nil,
                    startLine: startLine,
                    selectedTextSourceContext: piRouter != nil ? sourceContext : nil
                )
            }
        }
        .sheet(isPresented: $showFullScreen) {
            FullScreenCodeView(
                content: .plainText(content: content, filePath: filePath),
                selectedTextPiRouter: piRouter
            )
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

// MARK: - Native Code Body (UIKit-backed)

/// UIKit-backed code renderer wrapping ``NativeFullScreenCodeBody``.
///
/// Used by all code/JSON/plain-text views for both inline and document
/// presentation. Provides gutter line numbers, syntax highlighting
/// (off main thread), and bidirectional scrolling via `UITextView`.
///
/// When `maxHeight` is set (inline mode), reports estimated content
/// height via `sizeThatFits` so the view shrinks for short snippets.
/// Vertical bounce is disabled in inline mode.
private struct NativeCodeBodyView: UIViewRepresentable {
    let content: String
    let language: String?
    let startLine: Int
    var maxHeight: CGFloat? = nil
    var selectedTextSourceContext: SelectedTextSourceContext? = nil

    @Environment(\.selectedTextPiActionRouter) private var selectedTextPiRouter

    /// Approximate line height for FullScreenCodeTypography.codeFont (12pt mono).
    private static let estimatedLineHeight: CGFloat = 15.0
    /// textContainerInset top + bottom (8 + 8).
    private static let estimatedVerticalPadding: CGFloat = 16.0

    func makeUIView(context: Context) -> NativeFullScreenCodeBody {
        NativeFullScreenCodeBody(
            content: content,
            language: language,
            startLine: startLine,
            palette: ThemeRuntimeState.currentThemeID().palette,
            alwaysBounceVertical: maxHeight == nil,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSourceContext: selectedTextSourceContext
        )
    }

    func updateUIView(_ uiView: NativeFullScreenCodeBody, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: NativeFullScreenCodeBody,
        context: Context
    ) -> CGSize? {
        guard let maxHeight else { return nil }
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let naturalHeight = CGFloat(lineCount) * Self.estimatedLineHeight + Self.estimatedVerticalPadding
        let width = proposal.width ?? UIScreen.main.bounds.width
        return CGSize(width: width, height: min(naturalHeight, maxHeight))
    }
}
