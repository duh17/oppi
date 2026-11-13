/// Parse a CommonMark string into renderable block nodes.
///
/// Delegates to CMarkFastParser. Intentionally nonisolated so callers can
/// run it off the main thread via `Task.detached`.
nonisolated func parseCommonMark(_ source: String) -> [MarkdownBlock] {
    return parseCommonMarkFast(source)
}

/// One parse for the streaming driver (`CommonMarkStreamingParser`): the
/// blocks, where each starts, and what cmark knows about the end of the text,
/// so the driver never scans the bytes again for structure.
struct CommonMarkTailParse: Sendable {
    let blocks: [MarkdownBlock]
    /// The 1-based line each block starts on.
    let blockStartLines: [Int]
    /// Each block's source lines, as `parseCommonMarkLocated` reports them.
    let blockLineRanges: [ClosedRange<Int>?]
    /// The text ends inside a fenced code or math block whose closing line has
    /// not arrived.
    let endsInOpenBlock: Bool
    /// A link-reference definition can change how earlier blocks read.
    let hasReferenceDefinitions: Bool

    /// Where the last block starts, or 1 when there are fewer than two blocks:
    /// the boundary of a stable prefix.
    var lastBlockStartLine: Int {
        blockStartLines.count >= 2 ? blockStartLines[blockStartLines.count - 1] : 1
    }
}

nonisolated func parseCommonMarkTail(_ source: String) -> CommonMarkTailParse {
    parseCommonMarkFastTail(source)
}

/// Parse CommonMark and retain top-level source line ranges.
nonisolated func parseCommonMarkLocated(_ source: String) -> [LocatedMarkdownBlock] {
    parseCommonMarkFastLocated(source)
}
