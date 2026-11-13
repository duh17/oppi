import Foundation

enum CommonMarkStreamingParseStrategy: Equatable, Sendable {
    case full
    case tailOnly
}

struct CommonMarkStreamingParseResult: Equatable, Sendable {
    let blocks: [MarkdownBlock]
    /// Each block's identity: the UTF-8 offset where it starts. An append never
    /// moves it, so a block keeps its identity while it grows, and also when it
    /// changes kind (a paragraph that becomes a setext heading or a table).
    let blockIDs: [Int]
    let prefixBlocks: [MarkdownBlock]
    let tailBlocks: [MarkdownBlock]
    let strategy: CommonMarkStreamingParseStrategy
    /// UTF-8 byte offset where the open tail starts. The frozen prefix ends at a
    /// top-level block boundary, so tail-only work (line counts) can start here
    /// instead of re-reading the whole answer. Zero when the whole document was
    /// the tail.
    let tailUTF8Offset: Int
    /// The text ends inside a fenced code or math block whose closing line has
    /// not arrived, as cmark parsed it.
    let endsInOpenBlock: Bool
    /// Leading rows of the open table at the end that the previous tick
    /// already had, unchanged: a row is final once its line ends. Zero unless
    /// this tick resumed that table from its last finished row.
    var openTableUnchangedRows = 0
}

/// Incrementally parses a monotonically growing CommonMark document.
///
/// A top-level block is frozen once a later top-level block has started; each
/// tick reparses only the open tail from the first unfrozen block, while the
/// frozen UTF-8 prefix still belongs to this content. The parser also owns the
/// single "was this tick an append?" verdict for the streaming path: an append
/// is proved from the last bytes of the previous content, never from the whole
/// document, so a tick costs O(appended bytes). Anything else is a replacement:
/// the frozen state is dropped and the whole document is parsed.
///
/// Unclosed inline syntax (`**bold`, `$x`) stays text until it closes; the
/// parser never guesses a closer.
struct CommonMarkStreamingParser: Sendable {
    /// Bytes kept from the end of the previous content. Longer content is an
    /// append only when it repeats them at the same offset.
    private static let appendSampleByteCount = 64

    private struct State: Sendable {
        var prefixUTF8ByteCount: Int
        var prefixBlocks: [MarkdownBlock]
        var prefixBlockIDs: [Int]
    }

    private var state: State?
    private var trailingSample: [UInt8] = []
    private var lastContentUTF8ByteCount: Int?
    /// A link-reference definition (`[label]: url`) can change blocks before
    /// it. The offset of the newest `]:` the stream added keeps whole-document
    /// parses running until the block holding it is frozen, so a definition
    /// that completes over several ticks is still seen.
    private var referenceMarkerOffset: Int?
    /// The document holds a definition, so a frozen prefix would hide it from
    /// references after it: every tick parses the whole document.
    private var holdsReferenceDefinitions = false

    /// A table that is the open tail, parsed up to its last finished row (a
    /// row is one line, final once the line ends). Each tick parses only the
    /// rows after it, under the table's own header and delimiter rows, so a
    /// streamed table costs O(new rows) per tick instead of O(table).
    private struct OpenTable: Sendable {
        /// UTF-8 offset of the header row: the table's identity and the tail start.
        let start: Int
        /// The header and delimiter rows, newline included.
        let head: String
        let headers: [[MarkdownInline]]
        /// The delimiter row's alignments, which `head` holds: every resumed
        /// tick's table keeps them.
        let alignments: [MarkdownTableAlignment?]
        /// Rows whose line has ended.
        var finishedRows: [[[MarkdownInline]]]
        /// UTF-8 offset just past the last finished row.
        var finishedEnd: Int
    }

    private var openTable: OpenTable?

    mutating func reset() {
        state = nil
        trailingSample = []
        lastContentUTF8ByteCount = nil
        referenceMarkerOffset = nil
        holdsReferenceDefinitions = false
        openTable = nil
    }

    mutating func parse(_ content: String) -> CommonMarkStreamingParseResult {
        let contentUTF8 = content.utf8
        let appended = appendedRange(in: contentUTF8)
        defer { recordTrailingSample(contentUTF8) }

        if let appended {
            if let marker = Self.lastReferenceMarker(in: contentUTF8, appended: appended) {
                referenceMarkerOffset = marker
            }
        } else {
            state = nil
            openTable = nil
            referenceMarkerOffset = Self.lastReferenceMarker(in: contentUTF8, appended: 0 ..< contentUTF8.count)
            holdsReferenceDefinitions = false
        }

        if appended != nil, referenceMarkerOffset == nil, !holdsReferenceDefinitions,
           let resumed = resumeOpenTable(content: content, contentUTF8: contentUTF8) {
            return resumed
        }
        defer { checkpointOpenTable(content: content) }

        if let current = state,
           appended != nil,
           referenceMarkerOffset == nil,
           !holdsReferenceDefinitions,
           current.prefixUTF8ByteCount > 0,
           current.prefixUTF8ByteCount < contentUTF8.count {
            let boundary = contentUTF8.index(
                contentUTF8.startIndex,
                offsetBy: current.prefixUTF8ByteCount
            )
            let tailContent = String(content[boundary...])
            let tail = parseCommonMarkTail(tailContent)
            let tailIDs = Self.byteOffsets(ofLines: tail.blockStartLines, in: tailContent)
                .map { $0 + current.prefixUTF8ByteCount }

            advanceState(
                contentUTF8: contentUTF8,
                previousState: current,
                tailContent: tailContent,
                tail: tail,
                tailIDs: tailIDs
            )
            lastBlock = (tail.blocks.last, tailIDs.last)

            return CommonMarkStreamingParseResult(
                blocks: current.prefixBlocks + tail.blocks,
                blockIDs: current.prefixBlockIDs + tailIDs,
                prefixBlocks: current.prefixBlocks,
                tailBlocks: tail.blocks,
                strategy: .tailOnly,
                tailUTF8Offset: current.prefixUTF8ByteCount,
                endsInOpenBlock: tail.endsInOpenBlock
            )
        }

        let parsed = parseCommonMarkTail(content)
        let ids = Self.byteOffsets(ofLines: parsed.blockStartLines, in: content)
        holdsReferenceDefinitions = parsed.hasReferenceDefinitions
        let split: (state: State?, prefixBlocks: [MarkdownBlock], tailBlocks: [MarkdownBlock])
        if holdsReferenceDefinitions {
            split = (nil, [], parsed.blocks)
        } else {
            split = splitStablePrefix(
                content: content,
                contentUTF8: contentUTF8,
                blocks: parsed.blocks,
                ids: ids,
                lastBlockLine: parsed.lastBlockStartLine
            )
        }
        state = split.state
        lastBlock = (parsed.blocks.last, ids.last)
        // A `]:` in a frozen block that defined nothing can no longer start a
        // definition.
        if let marker = referenceMarkerOffset, let frozen = split.state?.prefixUTF8ByteCount, marker < frozen {
            referenceMarkerOffset = nil
        }

        return CommonMarkStreamingParseResult(
            blocks: parsed.blocks,
            blockIDs: ids,
            prefixBlocks: split.prefixBlocks,
            tailBlocks: split.tailBlocks,
            strategy: .full,
            tailUTF8Offset: split.state?.prefixUTF8ByteCount ?? 0,
            endsInOpenBlock: parsed.endsInOpenBlock
        )
    }

    /// The last block this tick parsed and its identity, for `checkpointOpenTable`.
    private var lastBlock: (block: MarkdownBlock?, id: Int?) = (nil, nil)

    /// This tick's result when the open tail is the table `openTable` holds and
    /// the new text only adds rows to it; nil when anything else may have
    /// changed, which drops the checkpoint and parses as usual.
    private mutating func resumeOpenTable(
        content: String,
        contentUTF8: String.UTF8View
    ) -> CommonMarkStreamingParseResult? {
        guard var table = openTable else { return nil }
        openTable = nil
        let tailStart = state?.prefixUTF8ByteCount ?? 0
        guard table.start == tailStart, table.finishedEnd <= contentUTF8.count else { return nil }

        let rest = String(content[contentUTF8.index(contentUTF8.startIndex, offsetBy: table.finishedEnd)...])
        let restUTF8 = rest.utf8
        let finishedLines = restUTF8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        let lastNewline = restUTF8.lastIndex(of: 0x0A)
        let hasOpenLine = (lastNewline.map { restUTF8.index(after: $0) } ?? restUTF8.startIndex) != restUTF8.endIndex
        let parsed = parseCommonMarkTail(table.head + rest)
        // Every new line must still be a row of this one table: a blank line,
        // a new block or a definition ends the fast path.
        guard parsed.blocks.count == 1, !parsed.hasReferenceDefinitions,
              case .table(_, let newRows, _) = parsed.blocks[0],
              newRows.count == finishedLines + (hasOpenLine ? 1 : 0) else { return nil }

        let unchangedRows = table.finishedRows.count
        let block = MarkdownBlock.table(headers: table.headers, rows: table.finishedRows + newRows, alignments: table.alignments)
        if let lastNewline {
            table.finishedRows += newRows.prefix(finishedLines)
            table.finishedEnd += restUTF8.distance(from: restUTF8.startIndex, to: lastNewline) + 1
        }
        openTable = table
        let prefixBlocks = state?.prefixBlocks ?? []
        return CommonMarkStreamingParseResult(
            blocks: prefixBlocks + [block],
            blockIDs: (state?.prefixBlockIDs ?? []) + [tailStart],
            prefixBlocks: prefixBlocks,
            tailBlocks: [block],
            strategy: .tailOnly,
            tailUTF8Offset: tailStart,
            endsInOpenBlock: false,
            openTableUnchangedRows: unchangedRows
        )
    }

    /// Keeps a checkpoint when this tick's open tail is one table that starts
    /// it: its header and delimiter rows have ended, and each line after them
    /// is one of its rows.
    private mutating func checkpointOpenTable(content: String) {
        defer { lastBlock = (nil, nil) }
        openTable = nil
        let tailStart = state?.prefixUTF8ByteCount ?? 0
        guard referenceMarkerOffset == nil, !holdsReferenceDefinitions,
              lastBlock.id == tailStart,
              case .table(let headers, let rows, let alignments)? = lastBlock.block else { return }
        let utf8 = content.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: tailStart)
        guard let headerEnd = utf8[start...].firstIndex(of: 0x0A),
              let delimiterEnd = utf8[utf8.index(after: headerEnd)...].firstIndex(of: 0x0A) else { return }
        let rowsStart = utf8.index(after: delimiterEnd)
        let rowText = utf8[rowsStart...]
        let finishedLines = rowText.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        let lastNewline = rowText.lastIndex(of: 0x0A)
        let hasOpenLine = (lastNewline.map { utf8.index(after: $0) } ?? rowsStart) != utf8.endIndex
        guard rows.count == finishedLines + (hasOpenLine ? 1 : 0) else { return }
        let head = String(content[start ..< rowsStart])
        // The rows must read the same under the header alone: a table whose
        // header came off the end of a paragraph would not.
        guard parseCommonMarkTail(head).blocks == [.table(headers: headers, rows: [], alignments: alignments)] else { return }
        let finishedEnd = lastNewline.map { utf8.index(after: $0) } ?? rowsStart
        openTable = OpenTable(
            start: tailStart,
            head: head,
            headers: headers,
            alignments: alignments,
            finishedRows: Array(rows.prefix(finishedLines)),
            finishedEnd: utf8.distance(from: utf8.startIndex, to: finishedEnd)
        )
    }

    private mutating func advanceState(
        contentUTF8: String.UTF8View,
        previousState: State,
        tailContent: String,
        tail: CommonMarkTailParse,
        tailIDs: [Int]
    ) {
        let tailLastBlockLine = tail.lastBlockStartLine
        guard tail.blocks.count >= 2, tailLastBlockLine > 1 else {
            state = previousState
            return
        }
        if Self.shouldHoldTableOpen(
            blocks: tail.blocks,
            content: tailContent,
            lastBlockLine: tailLastBlockLine
        ) || Self.shouldHoldOrderedListOpen(
            blocks: tail.blocks,
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
            prefixBlocks: previousState.prefixBlocks + tail.blocks.dropLast(),
            prefixBlockIDs: previousState.prefixBlockIDs + tailIDs.dropLast()
        )
    }

    private func splitStablePrefix(
        content: String,
        contentUTF8: String.UTF8View,
        blocks: [MarkdownBlock],
        ids: [Int],
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
                prefixBlocks: prefixBlocks,
                prefixBlockIDs: Array(ids.dropLast())
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

    /// The offset of the last `]:` in `appended`, one byte of overlap included
    /// so a pair split across ticks is found. O(appended bytes).
    private static func lastReferenceMarker(in contentUTF8: String.UTF8View, appended: Range<Int>) -> Int? {
        let scanStart = max(0, appended.lowerBound - 1)
        var offset = scanStart
        var previous: UInt8?
        var marker: Int?
        for byte in contentUTF8[contentUTF8.index(contentUTF8.startIndex, offsetBy: scanStart)...] {
            if previous == UInt8(ascii: "]"), byte == UInt8(ascii: ":") { marker = offset }
            previous = byte
            offset += 1
        }
        return marker
    }

    /// UTF-8 offsets of the 1-based `lines` (ascending) in `text`, in one pass.
    private static func byteOffsets(ofLines lines: [Int], in text: String) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(lines.count)
        var next = lines.makeIterator()
        var wanted = next.next()
        var line = 1
        var offset = 0
        while let target = wanted, target <= line {
            offsets.append(offset)
            wanted = next.next()
        }
        for byte in text.utf8 {
            offset += 1
            guard byte == UInt8(ascii: "\n") else { continue }
            line += 1
            while let target = wanted, target <= line {
                offsets.append(offset)
                wanted = next.next()
            }
            if wanted == nil { break }
        }
        while wanted != nil {
            offsets.append(offset)
            wanted = next.next()
        }
        return offsets
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
