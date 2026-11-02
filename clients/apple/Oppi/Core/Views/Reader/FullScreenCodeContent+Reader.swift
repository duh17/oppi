import UIKit

/// Everything the full-screen reader asks about its content, answered per kind
/// in this one file: the body, what Source shows and its toggle title, the
/// Viewing Options family, Copy, Share, the file path, the text a line anchor
/// resolves against, and the kind's name. This is `DocumentFamily`'s shape for
/// every `FullScreenCodeContent` case: `FullScreenCodeViewController` asks and
/// keeps no `switch` over the content, and a new case makes the compiler point
/// at each answer here.
extension FullScreenCodeContent {
    /// The file the content was read from, when it names one. A reader uses it to
    /// find the live document behind the bytes.
    var filePath: String? {
        switch self {
        case .code(_, _, let filePath, _),
             .plainText(_, let filePath),
             .html(_, let filePath),
             .latex(_, let filePath),
             .orgMode(_, let filePath),
             .mermaid(_, let filePath),
             .graphviz(_, let filePath):
            return filePath
        case .markdown(_, let filePath, _, _, _):
            return filePath
        case .diff(let document):
            return document.filePath
        case .document(let family):
            return family.filePath
        case .thinking, .terminal, .liveSource, .notebook:
            return nil
        }
    }

    /// Stable label for change detection (a live source whose final kind changes).
    var kindName: String {
        switch self {
        case .code: return "code"
        case .plainText: return "plainText"
        case .diff: return "diff"
        case .markdown: return "markdown"
        case .html: return "html"
        case .thinking: return "thinking"
        case .terminal: return "terminal"
        case .liveSource: return "liveSource"
        case .latex: return "latex"
        case .orgMode: return "orgMode"
        case .mermaid: return "mermaid"
        case .graphviz: return "graphviz"
        case .document(let family): return family.kindName
        case .notebook: return "notebook"
        }
    }

    /// Viewing Options family of the body this content shows; nil when the body
    /// ignores reader preferences, so the reader offers no Viewing Options.
    var readerFamily: FullScreenReaderContentFamily? {
        switch self {
        case .markdown, .thinking, .orgMode:
            return .markdown
        case .code, .graphviz:
            return .code
        case .plainText:
            return .source
        case .diff:
            return .diff
        case .terminal:
            return .terminal
        case .html:
            return .html
        case .latex:
            return .renderedDocument
        case .mermaid:
            // Rendered diagrams ignore reader preferences; Source uses `.code`.
            return nil
        case .document(let family):
            return family.readerFamily
        case .notebook:
            // A code cell and its printed output read like code.
            return .code
        case .liveSource(let snapshot, _):
            return snapshot.readerContent.readerFamily
        }
    }

    /// The stored preferences of `readerFamily`, or the defaults.
    @MainActor
    var readerPreferences: FullScreenReaderPreferences {
        guard let readerFamily else { return FullScreenReaderPreferences() }
        return FullScreenReaderPreferencesStore.shared.preferences(for: readerFamily)
    }

    /// What the reader shows when the person toggles to Source; nil when the
    /// content has no Source toggle. `completeRaw` is a Markdown tool output's
    /// whole raw text once its sidecar has loaded.
    func sourceContent(completeRaw: String?) -> FullScreenCodeContent? {
        switch self {
        case .markdown(let text, let filePath, _, let rawText, _):
            return .plainText(content: completeRaw ?? rawText ?? text, filePath: filePath)
        case .html(let text, let filePath):
            return .code(content: text, language: "html", filePath: filePath, startLine: 1)
        case .diff(let document):
            guard Self.isHTMLFilePath(document.filePath) else { return nil }
            return .html(content: document.reconstructedNewSideText, filePath: document.filePath)
        case .latex(let text, let filePath):
            return .code(content: text, language: "latex", filePath: filePath, startLine: 1)
        case .orgMode(let text, let filePath):
            return .code(content: text, language: "org", filePath: filePath, startLine: 1)
        case .mermaid(let text, let filePath):
            return .code(content: text, language: "mermaid", filePath: filePath, startLine: 1)
        case .document(let family):
            return family.sourceContent
        case .code, .plainText, .thinking, .terminal, .liveSource, .graphviz, .notebook:
            return nil
        }
    }

    /// The Source toggle's title: the mode it switches to. Nil exactly when
    /// `sourceContent` is.
    func sourceToggleTitle(showingSource: Bool) -> String? {
        switch self {
        case .markdown(_, _, _, let rawText, _):
            if rawText != nil { return showingSource ? String(localized: "Rendered") : String(localized: "Raw") }
            return showingSource ? String(localized: "Reader") : String(localized: "Source")
        case .html:
            return showingSource ? String(localized: "Preview") : String(localized: "Source")
        case .diff(let document):
            guard Self.isHTMLFilePath(document.filePath) else { return nil }
            return showingSource ? String(localized: "Diff") : String(localized: "Render")
        case .latex, .orgMode, .mermaid:
            return showingSource ? String(localized: "Rendered") : String(localized: "Source")
        case .document(let family):
            return family.sourceToggleTitle(showingSource: showingSource)
        case .code, .plainText, .thinking, .terminal, .liveSource, .graphviz, .notebook:
            return nil
        }
    }

    /// Copy's text. A diff copies its named copy text (often a unified patch),
    /// never the reconstructed new side; terminal output copies without ANSI.
    @MainActor
    func copyText(showingSource: Bool, completeRaw: String?) -> String {
        switch self {
        case .code(let text, _, _, _), .plainText(let text, _), .html(let text, _),
             .latex(let text, _), .orgMode(let text, _), .mermaid(let text, _), .graphviz(let text, _):
            return text
        case .diff(let document):
            return document.copyText
        case .markdown(let text, _, _, let rawText, _):
            return showingSource ? (completeRaw ?? rawText ?? text) : text
        case .thinking(let text, let stream):
            return stream?.snapshot.text ?? text
        case .terminal(let text, _, let stream, _):
            return ANSIParser.strip(stream?.snapshot.output ?? text)
        case .liveSource(let snapshot, _):
            return snapshot.readerContent.copyText(showingSource: showingSource, completeRaw: completeRaw)
        case .document(let family):
            return family.text
        case .notebook(let plan):
            return plan.readerText
        }
    }

    /// Share's payload.
    @MainActor
    func shareableContent(showingSource: Bool, completeRaw: String?) -> FileShareService.ShareableContent {
        switch self {
        case .mermaid(let text, let filePath): return .mermaid(text, fileName: filePath)
        case .latex(let text, let filePath): return .latex(text, fileName: filePath)
        case .markdown(let text, let filePath, _, let rawText, _):
            if showingSource, let raw = completeRaw ?? rawText { return .plainText(raw, fileName: filePath) }
            return .markdown(text, fileName: filePath)
        case .orgMode(let text, let filePath): return .orgMode(text, fileName: filePath)
        case .html(let text, let filePath): return .html(text, fileName: filePath)
        case .graphviz(let text, let filePath): return .code(text, language: "dot", fileName: filePath)
        case .document(let family): return family.shareableContent(fileName: family.filePath)
        case .code(let text, let lang, let filePath, _): return .code(text, language: lang, fileName: filePath)
        case .plainText(let text, let filePath): return .plainText(text, fileName: filePath)
        case .thinking(let text, let stream):
            return .plainText(stream?.snapshot.text ?? text)
        case .terminal(let text, _, let stream, _):
            return .plainText(stream?.snapshot.output ?? text)
        case .diff(let document):
            // Copy text is a unified patch, not the source file. Never keep
            // the original suffix (Foo.swift) or Save to Files can overwrite it.
            guard let path = document.filePath, !path.isEmpty else {
                return .plainText(document.copyText)
            }
            let diffName = FileShareService.exportFileName(
                originalFileName: path,
                genericBase: "diff",
                ext: "diff"
            )
            return .plainText(document.copyText, fileName: diffName)
        case .liveSource(let snapshot, _):
            return .plainText(snapshot.text, fileName: snapshot.filePath)
        case .notebook(let plan):
            return .plainText(plan.readerText)
        }
    }

    /// Where `anchor` lands in this content. A diff resolves against its
    /// reconstructed new side, never its copy text.
    func lineAnchorResolution(for anchor: SourceLineAnchor) -> SourceLineAnchorResolution {
        let text: String
        var firstLine = 1
        switch self {
        case .code(let content, _, _, let startLine):
            text = content
            firstLine = startLine
        case .plainText(let content, _),
             .markdown(let content, _, _, _, _),
             .html(let content, _),
             .latex(let content, _),
             .orgMode(let content, _),
             .mermaid(let content, _),
             .graphviz(let content, _),
             .thinking(let content, _),
             .terminal(let content, _, _, _):
            text = content
        case .document(let family):
            text = family.text
        case .notebook(let plan):
            text = plan.readerText
        case .diff(let document):
            text = document.reconstructedNewSideText
        case .liveSource(let snapshot, _):
            return snapshot.readerContent.lineAnchorResolution(for: anchor)
        }
        return anchor.resolution(fileContent: text, firstFileLine: firstLine)
    }

    private static func isHTMLFilePath(_ filePath: String?) -> Bool {
        guard let filePath else { return false }
        let ext = (filePath as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    // MARK: - Body

    /// The body the reader installs for this content.
    @MainActor
    func makeFullScreenBody(_ context: ReaderBodyContext) -> any ReaderBody {
        let themeID = context.themeID
        let palette = themeID.palette
        let router = context.selection?.dispatcher
        switch self {
        case .code(let text, let language, let filePath, let startLine):
            return NativeFullScreenCodeBody(
                content: text,
                language: language,
                startLine: startLine,
                palette: palette,
                readerPreferences: readerPreferences,
                themeID: themeID,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: context.sourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: language
                ),
                lineAnchor: context.lineAnchor,
                focusLineAnchor: context.focusLineAnchor
            )
        case .plainText(let text, let filePath):
            return NativeFullScreenSourceBody(
                content: text,
                isStreaming: false,
                palette: palette,
                readerPreferences: readerPreferences,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: context.sourceContext(
                    surface: .fullScreenSource,
                    filePath: filePath
                ),
                lineAnchor: context.lineAnchor,
                focusLineAnchor: context.focusLineAnchor
            )
        case .diff(let document):
            return NativeFullScreenDiffBody(
                document: document,
                palette: palette,
                readerPreferences: readerPreferences,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: context.sourceContext(
                    surface: .fullScreenDiff,
                    filePath: document.filePath
                )
            )
        case .markdown(let text, let filePath, let resourceAccess, _, _):
            let body = NativeFullScreenMarkdownBody(
                content: text,
                themeID: themeID,
                palette: palette,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: context.sourceContext(
                    surface: .fullScreenMarkdown,
                    filePath: filePath
                ),
                resourceAccess: resourceAccess,
                sourceFilePath: filePath,
                lineAnchor: context.lineAnchor,
                focusLineAnchor: context.focusLineAnchor,
                readerPreferences: readerPreferences,
                perfSurface: .fullScreenMarkdown
            )
            body.accessibilityIdentifier = "full-screen.markdown.body"
            return body
        case .html(let text, let filePath):
            let view = HTMLRenderView(
                htmlString: text,
                reviewCommentRouter: router,
                sourceContext: context.sourceContext(surface: .fullScreenSource, filePath: filePath)
            )
            view.backgroundColor = palette.ui.bgDark
            view.applyReaderPreferences(readerPreferences)
            return view
        case .thinking(let text, let stream):
            let snapshot = stream?.snapshot
            let displayedText = snapshot?.text ?? text
            guard snapshot?.isDone == false else {
                // The completed trace reads as Markdown.
                return NativeFullScreenMarkdownBody(
                    content: displayedText,
                    themeID: themeID,
                    palette: palette,
                    reviewCommentSelectionRouter: router,
                    reviewCommentSourceContext: context.sourceContext(
                        surface: .fullScreenThinking,
                        fallbackSourceLabel: String(localized: "Thinking")
                    ),
                    readerPreferences: readerPreferences,
                    perfSurface: .fullScreenThinking
                )
            }
            let completeThinking = context.completeThinking
            return NativeFullScreenThinkingBody(
                content: displayedText,
                stream: stream,
                palette: palette,
                readerPreferences: readerPreferences,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: context.sourceContext(
                    surface: .fullScreenThinking,
                    fallbackSourceLabel: String(localized: "Thinking")
                ),
                onCompletion: { body, finalText, viewportIntent in
                    completeThinking(body, finalText, viewportIntent)
                }
            )
        case .terminal(let text, let command, let stream, let sidecarSource):
            return NativeFullScreenTerminalBody(
                content: text,
                command: command,
                stream: stream,
                palette: palette,
                readerPreferences: readerPreferences,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: context.sourceContext(
                    surface: .fullScreenTerminal,
                    fallbackSourceLabel: command
                ),
                sidecarSource: sidecarSource
            )
        case .liveSource(let snapshot, _):
            return snapshot.readerContent.makeFullScreenBody(context)
        case .latex(let text, let filePath):
            return NativeFullScreenRenderedDocumentBody(
                content: .latex(text),
                themeID: themeID,
                palette: palette,
                readerPreferences: readerPreferences,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: context.sourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: "latex"
                )
            )
        case .orgMode(let text, let filePath):
            let body = NativeFullScreenMarkdownBody(
                content: text,
                sourceFormat: .orgMode,
                themeID: themeID,
                palette: palette,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: context.sourceContext(
                    surface: .fullScreenMarkdown,
                    filePath: filePath,
                    languageHint: "org"
                ),
                sourceFilePath: filePath,
                readerPreferences: readerPreferences,
                perfSurface: .fullScreenMarkdown
            )
            body.accessibilityIdentifier = "full-screen.org-mode.body"
            return body
        case .mermaid(let text, let filePath):
            return NativeFullScreenRenderedDocumentBody(
                content: .mermaid(text),
                themeID: themeID,
                palette: palette,
                readerPreferences: readerPreferences,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: context.sourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: "mermaid"
                )
            )
        case .graphviz(let text, let filePath):
            return NativeFullScreenCodeBody(
                content: text,
                language: "dot",
                startLine: 1,
                palette: palette,
                readerPreferences: readerPreferences,
                themeID: themeID,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: context.sourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: "dot"
                ),
                lineAnchor: context.lineAnchor,
                focusLineAnchor: context.focusLineAnchor
            )
        case .document(let family):
            return family.makeFullScreenBody(palette: palette, readerPreferences: readerPreferences)
        case .notebook(let plan):
            return NotebookReaderBody(
                plan: plan,
                selection: .init(
                    router: router,
                    code: context.sourceContext(surface: .fullScreenCode, languageHint: plan.sources.first?.language),
                    output: context.sourceContext(surface: .fullScreenSource),
                    markdown: context.sourceContext(surface: .fullScreenMarkdown)
                ),
                palette: palette,
                readerPreferences: readerPreferences
            )
        }
    }
}

/// What a body needs from the reader that is not in its content.
@MainActor
struct ReaderBodyContext {
    let themeID: ThemeID
    let selection: ReviewCommentSelectionContext?
    let lineAnchor: SourceLineAnchor?
    /// False when a restored reading position outranks the line anchor.
    let focusLineAnchor: Bool
    /// A live thinking body that finished hands over its final text and reading
    /// position; the reader installs `.thinking(content: finalText)` in its place.
    let completeThinking: (_ body: any ReaderBody, _ finalText: String, _ intent: FullScreenMarkdownViewportIntent) -> Void

    /// The comment source for a selection in the body, or nil without a
    /// comment route.
    func sourceContext(
        surface: ReviewCommentSurfaceKind,
        filePath: String? = nil,
        languageHint: String? = nil,
        fallbackSourceLabel: String? = nil
    ) -> ReviewCommentSourceContext? {
        guard let selection else { return nil }
        return selection.sourceContextIgnoringSurfaceOverride(
            surface: surface,
            sourceLabel: selection.sourceLabel ?? fallbackSourceLabel,
            filePath: filePath,
            languageHint: languageHint
        )
    }
}

extension SourceTraceStream.Snapshot {
    /// What a live source shows now: its final content once done; while it
    /// streams, the final kind (Markdown, HTML) over the text so far; otherwise
    /// plain text.
    var readerContent: FullScreenCodeContent {
        guard let finalContent else {
            return .plainText(content: text, filePath: filePath)
        }
        if isDone {
            return finalContent
        }
        switch finalContent {
        case .markdown(_, let finalPath, let resourceAccess, let rawText, let sidecarSource):
            return .markdown(
                content: text,
                filePath: finalPath ?? filePath,
                resourceAccess: resourceAccess, rawText: rawText, sidecarSource: sidecarSource
            )
        case .html(_, let finalPath):
            return .html(content: text, filePath: finalPath ?? filePath)
        default:
            return .plainText(content: text, filePath: filePath)
        }
    }
}
