import Foundation

/// One `CommonMarkStreamingParser` per timeline message, keyed by `ChatItem.id`.
///
/// Appends reuse the stored prefix. Rewrites reset inside the parser via its
/// prefix hash. Wiki rewrite still happens after parse, same as `parsedBlocks`.
@MainActor
final class MacMarkdownStreamingParserStore {
    static let shared = MacMarkdownStreamingParserStore()

    private var parsers: [String: CommonMarkStreamingParser] = [:]

    func parsedBlocks(
        itemID: String,
        markdown: String,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        sourceDirectory: String? = nil
    ) -> [MarkdownBlock] {
        parse(
            itemID: itemID,
            markdown: markdown,
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: sourceDirectory
        ).blocks
    }

    func parse(
        itemID: String,
        markdown: String,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        sourceDirectory: String? = nil
    ) -> (blocks: [MarkdownBlock], strategy: CommonMarkStreamingParseStrategy) {
        var parser = parsers[itemID] ?? CommonMarkStreamingParser()
        let result = MacMarkdownPaintDispatch.parseStreaming(
            markdown,
            parser: &parser,
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: sourceDirectory
        )
        parsers[itemID] = parser
        return result
    }

    func retain(itemIDs: Set<String>) {
        parsers = parsers.filter { itemIDs.contains($0.key) }
    }
}
