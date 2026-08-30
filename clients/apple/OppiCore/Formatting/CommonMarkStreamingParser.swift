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
}

/// Incrementally parses a monotonically growing CommonMark document.
///
/// The parser keeps finalized top-level blocks and reparses only the open tail
/// while their UTF-8 prefix remains unchanged. Inputs that can retroactively
/// rewrite earlier blocks deliberately use the canonical full-document parser.
struct CommonMarkStreamingParser: Sendable {
    private struct State: Sendable {
        var prefixUTF8ByteCount: Int
        var prefixContentHash: UInt64
        var prefixBlocks: [MarkdownBlock]
        var lastContentUTF8ByteCount: Int
    }

    private struct ReferenceDefinitionScanState: Sendable {
        var contentUTF8ByteCount: Int
        var hasPotentialDefinition: Bool
    }

    private var state: State?
    private var referenceDefinitionScanState: ReferenceDefinitionScanState?

    mutating func reset() {
        state = nil
        referenceDefinitionScanState = nil
    }

    mutating func parse(_ content: String) -> CommonMarkStreamingParseResult {
        let contentUTF8 = content.utf8

        if let current = state {
            let prefixStillMatches = current.prefixUTF8ByteCount <= contentUTF8.count
                && Self.fnv1a64(bytes: contentUTF8, count: current.prefixUTF8ByteCount) == current.prefixContentHash
            if !prefixStillMatches {
                state = nil
                referenceDefinitionScanState = nil
            }
        }

        // Link-reference definitions can resolve links in finalized blocks, and
        // display-math delimiters can combine earlier CommonMark blocks. False
        // positives intentionally choose the slower canonical path.
        if requiresCanonicalFullParse(content) {
            state = nil
            let blocks = parseCommonMark(content)
            return CommonMarkStreamingParseResult(
                blocks: blocks,
                prefixBlocks: [],
                tailBlocks: blocks,
                strategy: .full
            )
        }

        if let current = state,
           current.prefixUTF8ByteCount > 0,
           current.prefixUTF8ByteCount < contentUTF8.count,
           Self.prefixIsUnchanged(contentUTF8: contentUTF8, state: current) {
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
                strategy: .tailOnly
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
            strategy: .full
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
            prefixContentHash: Self.fnv1a64(bytes: contentUTF8, count: newPrefixByteCount),
            prefixBlocks: previousState.prefixBlocks + tailBlocks.dropLast(),
            lastContentUTF8ByteCount: contentUTF8.count
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

        let byteOffset = Self.utf8ByteOffset(forLine: lastBlockLine, in: content)
        guard byteOffset > 0, byteOffset < contentUTF8.count else {
            return (nil, [], blocks)
        }

        let prefixBlocks = Array(blocks.dropLast())
        return (
            State(
                prefixUTF8ByteCount: byteOffset,
                prefixContentHash: Self.fnv1a64(bytes: contentUTF8, count: byteOffset),
                prefixBlocks: prefixBlocks,
                lastContentUTF8ByteCount: contentUTF8.count
            ),
            prefixBlocks,
            Array(blocks.suffix(1))
        )
    }

    private mutating func requiresCanonicalFullParse(_ content: String) -> Bool {
        containsPotentialLinkReferenceDefinition(content)
            || content.contains("$$")
            || content.contains(#"\["#)
            || content.contains(#"\]"#)
    }

    /// Streaming source is append-only. Scan only the appended UTF-8 suffix,
    /// retaining one overlap byte so a delimiter split across ticks is found.
    private mutating func containsPotentialLinkReferenceDefinition(_ content: String) -> Bool {
        if referenceDefinitionScanState?.hasPotentialDefinition == true {
            return true
        }

        let bytes = content.utf8
        let previousByteCount = referenceDefinitionScanState?.contentUTF8ByteCount ?? 0
        let isAppend = bytes.count >= previousByteCount
        let startOffset = isAppend ? max(0, previousByteCount - 1) : 0
        let start = bytes.index(bytes.startIndex, offsetBy: startOffset)

        var previousByte: UInt8?
        var found = false
        for byte in bytes[start...] {
            if previousByte == UInt8(ascii: "]"), byte == UInt8(ascii: ":") {
                found = true
                break
            }
            previousByte = byte
        }

        referenceDefinitionScanState = ReferenceDefinitionScanState(
            contentUTF8ByteCount: bytes.count,
            hasPotentialDefinition: found
        )
        return found
    }

    /// Skip FNV-1a when content only grew. Streaming appends leave the prefix
    /// bytes unchanged; shrinking or replacement still needs a hash check.
    private static func prefixIsUnchanged(contentUTF8: String.UTF8View, state: State) -> Bool {
        if contentUTF8.count >= state.lastContentUTF8ByteCount {
            return true
        }
        return fnv1a64(bytes: contentUTF8, count: state.prefixUTF8ByteCount) == state.prefixContentHash
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

    private static func fnv1a64(bytes: String.UTF8View, count: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let end = bytes.index(bytes.startIndex, offsetBy: count)
        for byte in bytes[..<end] {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
