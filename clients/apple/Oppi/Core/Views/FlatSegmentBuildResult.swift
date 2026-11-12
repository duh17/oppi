import Foundation

extension FlatSegment {
    /// The segments a document builds to, with where each came from.
    struct BuildResult: Sendable {
        let segments: [FlatSegment]
        let sourceLineRanges: [ClosedRange<Int>?]
        let identities: [MarkdownReaderSegmentID]
        /// The segment each top-level heading block opens, in order; nil for a
        /// heading with no text, and for every heading unless the build split
        /// at headings or kept every block apart.
        let headingSegments: [Int?]

        init(
            segments: [FlatSegment],
            sourceLineRanges: [ClosedRange<Int>?],
            identities: [MarkdownReaderSegmentID]? = nil,
            headingSegments: [Int?] = []
        ) {
            self.segments = segments
            self.headingSegments = headingSegments
            self.sourceLineRanges = sourceLineRanges
            self.identities = identities ?? FlatSegment.readerSegmentIDs(
                segments: segments,
                sourceLineRanges: sourceLineRanges
            )
        }
    }
}

extension FlatSegment.BuildResult {
    /// The most characters one text segment of the located (reader) build
    /// holds. A reader cell is as tall as its text, and a text view tens of
    /// thousands of points tall costs hundreds of megabytes to lay out and draw:
    /// opening a 180 KB run of prose, or one huge paragraph, took the app past
    /// 1 GB and froze it.
    static let textSegmentCharacterLimit = 8_000

    /// This build with every longer text segment cut into pieces under `limit`.
    /// Each piece keeps its run's source lines; a heading still names the
    /// segment it opens.
    func boundingTextSegments(limit: Int = textSegmentCharacterLimit) -> Self {
        var firstPiece: [Int] = []
        firstPiece.reserveCapacity(segments.count)
        var bounded: [FlatSegment] = []
        var boundedLineRanges: [ClosedRange<Int>?] = []
        for (index, segment) in segments.enumerated() {
            firstPiece.append(bounded.count)
            let lineRange = sourceLineRanges.indices.contains(index) ? sourceLineRanges[index] : nil
            guard case .text(let text) = segment, text.characters.count > limit else {
                bounded.append(segment)
                boundedLineRanges.append(lineRange)
                continue
            }
            for piece in FlatSegment.textPieces(text, limit: limit) {
                bounded.append(.text(piece))
                boundedLineRanges.append(lineRange)
            }
        }
        guard bounded.count != segments.count else { return self }
        return Self(
            segments: bounded,
            sourceLineRanges: sourceLineRanges.isEmpty ? [] : boundedLineRanges,
            headingSegments: headingSegments.map { $0.map { firstPiece[$0] } }
        )
    }
}

extension FlatSegment {
    /// `text` in pieces of at most `limit` characters. A cut takes the last
    /// line break in the window (dropped with its neighbours, so no piece
    /// starts or ends on an empty line), else follows the last space, else
    /// falls at the limit.
    static func textPieces(_ text: AttributedString, limit: Int) -> [AttributedString] {
        precondition(limit > 0)
        let characters = text.characters
        var pieces: [AttributedString] = []
        var start = characters.startIndex
        while start < characters.endIndex {
            if !pieces.isEmpty, characters[start].isNewline {
                start = characters.index(after: start)
                continue
            }
            var end = start
            var count = 0
            var lastNewline: AttributedString.Index?
            var afterLastSpace: AttributedString.Index?
            while end < characters.endIndex, count < limit {
                let character = characters[end]
                if character.isNewline {
                    lastNewline = end
                } else if character.isWhitespace {
                    afterLastSpace = characters.index(after: end)
                }
                end = characters.index(after: end)
                count += 1
            }
            guard end < characters.endIndex else {
                pieces.append(AttributedString(text[start..<end]))
                break
            }
            if let lastNewline, lastNewline > start {
                var pieceEnd = lastNewline
                while pieceEnd > start, characters[characters.index(before: pieceEnd)].isNewline {
                    pieceEnd = characters.index(before: pieceEnd)
                }
                if pieceEnd > start { pieces.append(AttributedString(text[start..<pieceEnd])) }
                start = characters.index(after: lastNewline)
            } else {
                let cut = afterLastSpace ?? end
                pieces.append(AttributedString(text[start..<cut]))
                start = cut
            }
        }
        return pieces
    }
}
