import Foundation

enum CommonMarkStreamingParseStrategy: Equatable, Sendable {
    case full
    case tailOnly
}

struct CommonMarkStreamingParseResult: Equatable, Sendable {
    let blocks: [MarkdownBlock]
    let prefixBlocks: [MarkdownBlock]
    let tailBlocks: [MarkdownBlock]
    let strategy: CommonMarkStreamingParseStrategy
    /// UTF-8 byte offset where the open tail starts. The frozen prefix ends at a
    /// top-level block boundary, so tail-only work (fence parity, line counts)
    /// can start here instead of re-reading the whole answer. Zero when the
    /// whole document was the tail.
    let tailUTF8Offset: Int
}

/// Incrementally parses a monotonically growing CommonMark document.
///
/// The parser keeps finalized top-level blocks and reparses only the open tail
/// while the frozen UTF-8 prefix still belongs to this content. It also owns the
/// single "was this tick an append?" verdict for the streaming path: an append is
/// proved from the last bytes of the previous content, never from the whole
/// document, so a tick costs O(appended bytes). Anything else is a replacement:
/// the frozen state is dropped and the canonical full-document parser runs.
struct CommonMarkStreamingParser: Sendable {
    /// Bytes kept from the end of the previous content. Longer content is an
    /// append only when it repeats them at the same offset.
    private static let appendSampleByteCount = 64

    private struct State: Sendable {
        var prefixUTF8ByteCount: Int
        var prefixBlocks: [MarkdownBlock]
    }

    private struct SuffixScanState: Sendable {
        var scannedUTF8ByteCount: Int
        var hasCanonicalTrigger: Bool
    }

    private var state: State?
    private var suffixScanState: SuffixScanState?
    private var trailingSample: [UInt8] = []
    private var lastContentUTF8ByteCount: Int?

    mutating func reset() {
        state = nil
        suffixScanState = nil
        trailingSample = []
        lastContentUTF8ByteCount = nil
    }

    mutating func parse(_ content: String) -> CommonMarkStreamingParseResult {
        let contentUTF8 = content.utf8
        let appended = appendedRange(in: contentUTF8)
        defer { recordTrailingSample(contentUTF8) }

        if appended == nil {
            state = nil
        }

        // Display-math delimiters can combine earlier CommonMark blocks, and
        // link-reference definitions can resolve links in finalized blocks.
        // False positives intentionally choose the slower canonical path.
        if requiresCanonicalFullParse(contentUTF8, appendedRange: appended) {
            state = nil
            let blocks = parseCommonMark(content)
            return CommonMarkStreamingParseResult(
                blocks: blocks,
                prefixBlocks: [],
                tailBlocks: blocks,
                strategy: .full,
                tailUTF8Offset: 0
            )
        }

        if let current = state,
           appended != nil,
           current.prefixUTF8ByteCount > 0,
           current.prefixUTF8ByteCount < contentUTF8.count {
            let boundary = contentUTF8.index(
                contentUTF8.startIndex,
                offsetBy: current.prefixUTF8ByteCount
            )
            let tailContent = String(content[boundary...])
            let (tailBlocks, tailLastBlockLine) = tailContent.isEmpty
                ? ([], 1)
                : parseCommonMarkWithLastLine(tailContent)
            let blocks = current.prefixBlocks + tailBlocks

            advanceState(
                contentUTF8: contentUTF8,
                previousState: current,
                tailContent: tailContent,
                tailBlocks: tailBlocks,
                tailLastBlockLine: tailLastBlockLine
            )

            return CommonMarkStreamingParseResult(
                blocks: blocks,
                prefixBlocks: current.prefixBlocks,
                tailBlocks: tailBlocks,
                strategy: .tailOnly,
                tailUTF8Offset: current.prefixUTF8ByteCount
            )
        }

        let (blocks, lastBlockLine) = parseCommonMarkWithLastLine(content)
        let split = splitStablePrefix(
            content: content,
            contentUTF8: contentUTF8,
            blocks: blocks,
            lastBlockLine: lastBlockLine
        )
        state = split.state

        return CommonMarkStreamingParseResult(
            blocks: blocks,
            prefixBlocks: split.prefixBlocks,
            tailBlocks: split.tailBlocks,
            strategy: .full,
            tailUTF8Offset: split.state?.prefixUTF8ByteCount ?? 0
        )
    }

    private mutating func advanceState(
        contentUTF8: String.UTF8View,
        previousState: State,
        tailContent: String,
        tailBlocks: [MarkdownBlock],
        tailLastBlockLine: Int
    ) {
        guard tailBlocks.count >= 2, tailLastBlockLine > 1 else {
            state = previousState
            return
        }
        if Self.shouldHoldTableOpen(
            blocks: tailBlocks,
            content: tailContent,
            lastBlockLine: tailLastBlockLine
        ) || Self.shouldHoldOrderedListOpen(
            blocks: tailBlocks,
            content: tailContent,
            lastBlockLine: tailLastBlockLine
        ) {
            state = previousState
            return
        }

        let tailPrefixByteCount = Self.utf8ByteOffset(
            forLine: tailLastBlockLine,
            in: tailContent
        )
        let newPrefixByteCount = previousState.prefixUTF8ByteCount + tailPrefixByteCount
        guard newPrefixByteCount > previousState.prefixUTF8ByteCount,
              newPrefixByteCount < contentUTF8.count else {
            state = nil
            return
        }

        state = State(
            prefixUTF8ByteCount: newPrefixByteCount,
            prefixBlocks: previousState.prefixBlocks + tailBlocks.dropLast()
        )
    }

    private func splitStablePrefix(
        content: String,
        contentUTF8: String.UTF8View,
        blocks: [MarkdownBlock],
        lastBlockLine: Int
    ) -> (state: State?, prefixBlocks: [MarkdownBlock], tailBlocks: [MarkdownBlock]) {
        guard blocks.count >= 2, lastBlockLine > 1 else {
            return (nil, [], blocks)
        }
        if Self.shouldHoldTableOpen(
            blocks: blocks,
            content: content,
            lastBlockLine: lastBlockLine
        ) || Self.shouldHoldOrderedListOpen(
            blocks: blocks,
            content: content,
            lastBlockLine: lastBlockLine
        ) {
            return (nil, [], blocks)
        }

        let byteOffset = Self.utf8ByteOffset(forLine: lastBlockLine, in: content)
        guard byteOffset > 0, byteOffset < contentUTF8.count else {
            return (nil, [], blocks)
        }

        let prefixBlocks = Array(blocks.dropLast())
        return (
            State(
                prefixUTF8ByteCount: byteOffset,
                prefixBlocks: prefixBlocks
            ),
            prefixBlocks,
            Array(blocks.suffix(1))
        )
    }

    /// Append verdict for this tick, in O(1) index work: the previous content's
    /// last bytes must repeat at the same offset. A shrink or a mismatch is a
    /// replacement, which drops the frozen prefix. A replacement that happens to
    /// repeat those bytes reads as an append by design; callers that can reuse a
    /// parser across unrelated documents reset it instead (`reset()`).
    private func appendedRange(in contentUTF8: String.UTF8View) -> Range<Int>? {
        guard let lastContentUTF8ByteCount,
              contentUTF8.count >= lastContentUTF8ByteCount else {
            return nil
        }
        let sampleEnd = contentUTF8.index(
            contentUTF8.endIndex,
            offsetBy: lastContentUTF8ByteCount - contentUTF8.count
        )
        let sampleStart = contentUTF8.index(sampleEnd, offsetBy: -trailingSample.count)
        guard contentUTF8[sampleStart..<sampleEnd].elementsEqual(trailingSample) else {
            return nil
        }
        return lastContentUTF8ByteCount..<contentUTF8.count
    }

    private mutating func recordTrailingSample(_ contentUTF8: String.UTF8View) {
        lastContentUTF8ByteCount = contentUTF8.count
        trailingSample = Array(contentUTF8.suffix(Self.appendSampleByteCount))
    }

    /// One pass over the appended UTF-8 bytes for every delimiter that can make
    /// an earlier block stale: display math, LaTeX delimiters, and link-reference
    /// definitions. One overlap byte catches a pair split across ticks, and the
    /// trigger is sticky because content only grows while streaming. A
    /// replacement rescans from the start.
    private mutating func requiresCanonicalFullParse(
        _ contentUTF8: String.UTF8View,
        appendedRange: Range<Int>?
    ) -> Bool {
        // Sticky only while the document grows: a replacement rescans from the
        // start, so an earlier delimiter no longer forces the canonical path.
        if appendedRange != nil, suffixScanState?.hasCanonicalTrigger == true {
            return true
        }

        let resumedByteCount = appendedRange == nil ? 0 : suffixScanState?.scannedUTF8ByteCount ?? 0
        let scanStartOffset = max(0, resumedByteCount - 1)
        let start = contentUTF8.index(
            contentUTF8.endIndex,
            offsetBy: scanStartOffset - contentUTF8.count
        )

        var previousByte: UInt8?
        for byte in contentUTF8[start...] {
            if let previousByte, Self.isCanonicalTriggerPair(previousByte, byte) {
                suffixScanState = SuffixScanState(
                    scannedUTF8ByteCount: contentUTF8.count,
                    hasCanonicalTrigger: true
                )
                return true
            }
            previousByte = byte
        }

        suffixScanState = SuffixScanState(
            scannedUTF8ByteCount: contentUTF8.count,
            hasCanonicalTrigger: false
        )
        return false
    }

    private static func isCanonicalTriggerPair(_ previous: UInt8, _ byte: UInt8) -> Bool {
        let dollar = UInt8(ascii: "$")
        let backslash = UInt8(ascii: "\\")
        let openBracket = UInt8(ascii: "[")
        let closeBracket = UInt8(ascii: "]")
        let colon = UInt8(ascii: ":")
        return (previous == dollar && byte == dollar)
            || (previous == backslash && (byte == openBracket || byte == closeBracket))
            || (previous == closeBracket && byte == colon)
    }

    /// A mid-row chunk can make cmark emit a short table plus a pipe paragraph.
    /// Freezing that table permanently parses later `|` rows without a header.
    /// Hold the table in the open tail until a blank line or a non-row follows.
    private static func shouldHoldTableOpen(
        blocks: [MarkdownBlock],
        content: String,
        lastBlockLine: Int
    ) -> Bool {
        guard blocks.count >= 2,
              case .table = blocks[blocks.count - 2],
              case .paragraph = blocks.last else {
            return false
        }
        let offset = utf8ByteOffset(forLine: lastBlockLine, in: content)
        guard offset < content.utf8.count else { return false }
        let start = content.utf8.index(content.utf8.startIndex, offsetBy: offset)
        return looksLikeGFMTableContinuation(String(content[start...]))
    }

    private static func looksLikeGFMTableContinuation(_ tail: String) -> Bool {
        for line in tail.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            return trimmed.hasPrefix("|")
        }
        return false
    }

    /// `1. First step\n\n2` parses as an ordered list followed by the paragraph
    /// `2`. Freezing the list here is wrong: the next tick's `2.` rejoins the list
    /// cmark already had, so the streamed render shows a second list and a blank
    /// line a canonical build does not. Hold the tail open while its last block is
    /// a lone list ordinal — 1–9 digits on one line, indented up to 3 spaces —
    /// which the next byte can turn into a marker. O(last line).
    private static func shouldHoldOrderedListOpen(
        blocks: [MarkdownBlock],
        content: String,
        lastBlockLine: Int
    ) -> Bool {
        guard blocks.count >= 2,
              case .orderedList = blocks[blocks.count - 2],
              case .paragraph = blocks.last else {
            return false
        }
        let offset = utf8ByteOffset(forLine: lastBlockLine, in: content)
        var line = content.utf8[
            content.utf8.index(content.utf8.startIndex, offsetBy: offset)...
        ]
        // The last block's source; a multi-line paragraph is not an ordinal.
        while line.last == UInt8(ascii: "\n") { line = line.dropLast() }
        guard !line.contains(UInt8(ascii: "\n")) else { return false }

        let space = UInt8(ascii: " ")
        var index = line.startIndex
        while index < line.endIndex, line[index] == space {
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return false }

        let zero = UInt8(ascii: "0")
        let nine = UInt8(ascii: "9")
        var digits = 0
        while index < line.endIndex, line[index] >= zero, line[index] <= nine {
            digits += 1
            index = line.index(after: index)
        }
        guard digits >= 1, digits <= 9 else { return false }
        // Trailing spaces are allowed; anything else means this is prose.
        return line[index...].allSatisfy { $0 == space }
    }

    private static func utf8ByteOffset(forLine targetLine: Int, in content: String) -> Int {
        guard targetLine > 1 else { return 0 }
        var currentLine = 1
        var byteOffset = 0
        for byte in content.utf8 {
            byteOffset += 1
            if byte == UInt8(ascii: "\n") {
                currentLine += 1
                if currentLine == targetLine {
                    return byteOffset
                }
            }
        }
        return content.utf8.count
    }
}
