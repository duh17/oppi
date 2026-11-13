/// One parse for the streaming driver (`CommonMarkStreamingParser`): the
/// blocks, where each starts, and what cmark knows about the end of the text,
/// so the driver never scans the bytes again for structure. The parsers
/// themselves (`parseCommonMark`, `parseCommonMarkLocated`,
/// `parseCommonMarkTail`) live in `CMarkFastParser.swift`.
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
