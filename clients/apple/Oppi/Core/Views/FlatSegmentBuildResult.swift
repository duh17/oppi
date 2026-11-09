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
