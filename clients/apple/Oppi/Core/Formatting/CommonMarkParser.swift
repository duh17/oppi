/// Parse a CommonMark string into renderable block nodes.
///
/// Delegates to CMarkFastParser. Intentionally nonisolated so callers can
/// run it off the main thread via `Task.detached`.
nonisolated func parseCommonMark(_ source: String) -> [MarkdownBlock] {
    return parseCommonMarkFast(source)
}

/// Parse a CommonMark string and also return the 1-based start line of the
/// last top-level block.
///
/// Used by the streaming incremental parse path to locate the stable prefix
/// boundary without a second full parse.
///
/// - Returns: `(blocks, lastBlockStartLine)` where `lastBlockStartLine` is the
///   1-based line number of the last block, or 1 if the document has fewer
///   than 2 blocks.
nonisolated func parseCommonMarkWithLastLine(_ source: String) -> (blocks: [MarkdownBlock], lastBlockStartLine: Int) {
    return parseCommonMarkFastWithLastLine(source)
}
