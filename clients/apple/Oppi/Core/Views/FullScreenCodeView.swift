import UIKit

/// Lines-first payload for a completed full-screen tool diff.
///
/// `lines` are the only diff authority. `copyText` is clipboard, share, and
/// initial selectable text (often a unified patch). HTML render and line-anchor
/// notices use `reconstructedNewSideText`, never `copyText`.
struct ToolDiffDocument: Sendable {
    let lines: [DiffLine]
    let filePath: String?
    let copyText: String

    var reconstructedNewSideText: String {
        lines
            .filter { $0.kind != .removed }
            .map { $0.text }
            .joined(separator: "\n")
    }
}

/// What the full-screen reader shows. Each case's answers to the reader's
/// questions (body, Source, Copy, Share, Viewing Options) live in
/// `Reader/FullScreenCodeContent+Reader.swift`.
indirect enum FullScreenCodeContent {
    case code(content: String, language: String?, filePath: String?, startLine: Int)
    case plainText(content: String, filePath: String?)
    case diff(ToolDiffDocument)
    case markdown(content: String, filePath: String?, resourceAccess: MarkdownResourceAccess = .empty, rawText: String? = nil, sidecarSource: ToolOutputSidecarWindowSource? = nil)
    case html(content: String, filePath: String?)
    case thinking(content: String, trace: ReaderTrace<ThinkingSnapshot>? = nil)
    case terminal(
        content: String,
        command: String?,
        trace: ReaderTrace<TerminalSnapshot>? = nil,
        sidecarSource: ToolOutputSidecarWindowSource? = nil
    )
    /// A file a running tool is still writing. `showsSource` is the reader's
    /// Source toggle while it streams: the text so far, whatever its final kind.
    case liveSource(ReaderTrace<SourceSnapshot>, showsSource: Bool = false)

    // Document renderers
    case latex(content: String, filePath: String?)
    case orgMode(content: String, filePath: String?)
    case mermaid(content: String, filePath: String?)
    case graphviz(content: String, filePath: String?)
    /// CSV/TSV table or GeoJSON/TopoJSON map; `DocumentFamily` owns the per-kind behavior.
    case document(DocumentFamily)
    /// Notebook cell. The reader wraps the same view.
    case notebook(NotebookCellPlan)

    /// Build content from raw text and a file path by detecting the file type.
    static func fromText(_ text: String, filePath: String?) -> Self {
        let fileType = FileType.detect(from: filePath, content: text)
        if let document = DocumentFamily(fileType: fileType, text: text, filePath: filePath) {
            return .document(document)
        }
        switch fileType {
        case .markdown: return .markdown(content: text, filePath: filePath)
        case .html: return .html(content: text, filePath: filePath)
        case .latex: return .latex(content: text, filePath: filePath)
        case .orgMode: return .orgMode(content: text, filePath: filePath)
        case .mermaid: return .mermaid(content: text, filePath: filePath)
        case .graphviz: return .graphviz(content: text, filePath: filePath)
        case .json:
            return .code(content: text, language: "json", filePath: filePath, startLine: 1)
        case .code(let lang):
            return .code(content: text, language: lang.displayName, filePath: filePath, startLine: 1)
        case .plain:
            return .plainText(content: text, filePath: filePath)
        default:
            return .plainText(content: text, filePath: filePath)
        }
    }

    /// Build content from raw text with resource access for markdown image and media resolution.
    /// The access is only used for `.markdown` — other file types ignore it.
    static func fromText(
        _ text: String,
        filePath: String?,
        resourceAccess: MarkdownResourceAccess
    ) -> Self {
        let base = fromText(text, filePath: filePath)
        if case .markdown(let content, let path, _, let rawText, let sidecarSource) = base {
            return .markdown(content: content, filePath: path, resourceAccess: resourceAccess, rawText: rawText, sidecarSource: sidecarSource)
        }
        return base
    }
}
