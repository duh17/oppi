import Foundation

/// One place a message carries from a pane: today a staged review comment. The server
/// (`server/src/prompt-context.ts`) renders the items into a block the model reads before the
/// typed text, and the transcript keeps them, without `quote` and `anchor`, for the chips
/// under the user's message. Limits are the server's; a message over them is refused.
struct PromptContextItem: Codable, Equatable, Sendable {
    /// The staged comment's id. Never rendered.
    var id: String?
    var source: ReviewCommentReferenceSource
    var label: String?
    var path: String?
    var side: String?
    var startLine: Int?
    var endLine: Int?
    var startPage: Int?
    var endPage: Int?
    var url: String?
    /// Fence language of `quote`; empty for none. Nil: the server reads the path's extension.
    var language: String?
    var quote: String?
    /// Markdown lines that locate the selection further (a rendered element, a diagram object).
    var anchor: String?
    var note: String?
}

extension PromptContextItem {
    /// The server's limit for a quote, an anchor, or a note (`PROMPT_CONTEXT_MAX_TEXT` in
    /// `server/src/prompt-context.ts`), in UTF-16 units as JavaScript counts them.
    static let maxTextLength = 4000
    /// The server's caps on one message (`PROMPT_CONTEXT_MAX_ITEMS`, `..._MAX_BLOCK_BYTES`).
    static let maxItems = 20
    static let maxBlockBytes = 32 * 1024

    /// What the server's rendered block costs for `items`, a little over the real size: each
    /// item's text plus the headings and fences around it. An estimate, so the app never asks
    /// for a send the server would refuse; the server measures exactly.
    static func estimatedBlockBytes(_ items: some Collection<PromptContextItem>) -> Int {
        items.reduce(160) { total, item in
            let texts = [item.path, item.label, item.side, item.url, item.language, item.quote, item.anchor, item.note]
            let noteLines = item.note?.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count ?? 0
            return total + 220 + 2 * noteLines + texts.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        }
    }

    /// Why `items` cannot go with one message, naming how many to remove; nil when they fit.
    static func sendLimitRefusal(_ items: [PromptContextItem]) -> String? {
        if let long = items.firstIndex(where: { ($0.note?.utf16.count ?? 0) > maxTextLength }) {
            return String(localized: "Comment \(long + 1) is longer than \(maxTextLength.formatted()) characters. Shorten it to send; your comments stay staged.")
        }
        var fitting = min(items.count, maxItems)
        while fitting > 0, estimatedBlockBytes(items.prefix(fitting)) > maxBlockBytes { fitting -= 1 }
        let remove = items.count - fitting
        guard remove > 0 else { return nil }
        let comments = remove == 1 ? String(localized: "1 comment") : String(localized: "\(remove) comments")
        return fitting == min(items.count, maxItems)
            ? String(localized: "A message can carry \(maxItems) comments. Remove \(comments) to send; the rest stay staged.")
            : String(localized: "These comments are too long to send together. Remove \(comments) to send; the rest stay staged.")
    }

    /// A selection as a comment keeps it: whole when it fits the server's limit, else its
    /// start and a visible note of how long it was, so a send never fails on its length.
    static func capturedQuote(_ text: String) -> String {
        guard text.utf16.count > maxTextLength else { return text }
        let note = "\n… trimmed, \(text.count.formatted()) characters"
        var budget = maxTextLength - note.utf16.count
        var kept = ""
        for character in text {
            budget -= character.utf16.count
            guard budget >= 0 else { break }
            kept.append(character)
        }
        return kept + note
    }

    /// A staged comment as the server takes it. `currentSourceRevision` marks a diagram
    /// anchor stale when its source changed since the comment was made.
    init(
        comment: ReviewComment,
        pathFormatting: ReviewCommentPathFormatting = .normalizedDisplay,
        currentSourceRevision: String? = nil
    ) {
        let reference = comment.reference
        let path = switch pathFormatting {
        case .normalizedDisplay: reference.displayPath
        case .verbatim: reference.path
        }
        var anchorLines: [String] = []
        if let element = reference.htmlDOMAnchor {
            anchorLines += element.promptLines()
        }
        if let semantic = reference.semanticAnchor {
            let resolved = currentSourceRevision.map { semantic.markedStaleAgainst(currentRevision: $0) } ?? semantic
            anchorLines += resolved.promptLines
        }
        // Comments staged before capture trimmed are trimmed here, so none fails a send.
        let quote = reference.selectedText.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Self.capturedQuote($0)
        }
        self.init(
            id: comment.id,
            source: reference.source,
            label: reference.label.flatMap { $0.isEmpty ? nil : $0 },
            path: path.flatMap { $0.isEmpty ? nil : $0 },
            side: reference.side,
            startLine: reference.startLine,
            endLine: reference.endLine,
            startPage: reference.startPage,
            endPage: reference.endPage,
            url: reference.url,
            // A rendered element's text is not code in the file's language.
            language: reference.htmlDOMAnchor == nil ? reference.languageHint : "",
            quote: quote,
            anchor: anchorLines.isEmpty ? nil : anchorLines.joined(separator: "\n"),
            note: comment.body
        )
    }

    /// The item as a staged comment's reference again (Stop bringing a queued input back).
    var reviewReference: ReviewCommentReference {
        ReviewCommentReference(
            source: source,
            label: label,
            path: path,
            side: side,
            startLine: startLine,
            endLine: endLine,
            selectedText: quote,
            languageHint: language.flatMap { $0.isEmpty ? nil : $0 },
            url: url,
            startPage: startPage,
            endPage: endPage
        )
    }

    /// Whether the chip opens a place: a file the selection came from, or a web page.
    var opensPlace: Bool {
        switch source {
        case .file, .gitDiff, .image:
            if let path, !path.isEmpty { return true }
        case .timelineText, .toolOutput, .terminalOutput, .unknown:
            break
        }
        guard let url, let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The chip's text: the place, as short as it reads ("App.swift:12–14", "guide.pdf p. 2").
    var chipTitle: String {
        if let path, !path.isEmpty {
            var title = (path as NSString).lastPathComponent
            if let startLine {
                title += ":\(startLine)"
                if let endLine, endLine != startLine { title += "–\(endLine)" }
            }
            if let startPage {
                if let endPage, endPage != startPage {
                    title += " pp. \(startPage)–\(endPage)"
                } else {
                    title += " p. \(startPage)"
                }
            }
            return title
        }
        if let label, !label.isEmpty { return label }
        if let url, let host = URL(string: url)?.host() { return host }
        return sourceName
    }

    /// The chip's leading word: what the person attached.
    var chipPrefix: String {
        note?.isEmpty == false ? String(localized: "Comment") : String(localized: "Reference")
    }

    var chipSymbolName: String {
        if startPage != nil { return "doc.richtext" }
        switch source {
        case .gitDiff: return "plusminus"
        case .file: return "doc.text"
        case .timelineText: return "text.bubble"
        case .toolOutput, .terminalOutput: return "terminal"
        case .image: return "photo"
        case .unknown: return url == nil ? "text.quote" : "globe"
        }
    }

    private var sourceName: String {
        switch source {
        case .gitDiff: String(localized: "Diff")
        case .file: String(localized: "File")
        case .timelineText: String(localized: "Chat")
        case .toolOutput: String(localized: "Tool output")
        case .terminalOutput: String(localized: "Terminal")
        case .image: String(localized: "Image")
        case .unknown: String(localized: "Selection")
        }
    }
}

extension ReviewCommentStore {
    /// The staged comments, oldest first, as the context items a message sends.
    func contextItems(
        pathFormatting: ReviewCommentPathFormatting = .normalizedDisplay,
        currentSourceRevision: ((ReviewComment) -> String?)? = nil
    ) -> [PromptContextItem] {
        stagedComments.map { comment in
            PromptContextItem(
                comment: comment,
                pathFormatting: pathFormatting,
                currentSourceRevision: currentSourceRevision?(comment)
            )
        }
    }
}
