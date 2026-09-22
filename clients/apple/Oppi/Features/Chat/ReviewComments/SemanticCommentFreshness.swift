import Foundation

/// Detects a changed diagram source when the send path can still see the
/// timeline item that owned the comment. Does not re-anchor the object.
enum SemanticCommentFreshness {
    static func currentRevision(for comment: ReviewComment, timelineItems: [ChatItem]) -> String? {
        guard let anchor = comment.reference.semanticAnchor,
              let itemID = comment.reference.timelineItemId,
              let item = timelineItems.first(where: { $0.id == itemID }) else {
            return nil
        }
        let text: String
        switch item {
        case .assistantMessage(_, let message, _), .userMessage(_, let message, _, _):
            text = message
        default:
            return nil
        }
        if SemanticSourceRevision.hash(of: text) == anchor.sourceRevision {
            return anchor.sourceRevision
        }
        let sources = mermaidSources(in: text)
        if sources.contains(where: { SemanticSourceRevision.hash(of: $0) == anchor.sourceRevision }) {
            return anchor.sourceRevision
        }
        if let only = sources.first, sources.count == 1 {
            return SemanticSourceRevision.hash(of: only)
        }
        return SemanticSourceRevision.hash(of: text)
    }

    static func mermaidSources(in text: String) -> [String] {
        var sources: [String] = []
        func walk(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .codeBlock(let language, let code) where language?.lowercased() == "mermaid":
                    sources.append(code)
                case .blockQuote(let children):
                    walk(children)
                case .unorderedList(let items), .orderedList(_, let items):
                    items.forEach(walk)
                case .taskList(let items):
                    items.forEach { walk($0.content) }
                default:
                    break
                }
            }
        }
        walk(parseCommonMark(text))
        return sources
    }
}
