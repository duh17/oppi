import Foundation

/// One place a find query matches in a document, whether or not that part of
/// the document is showing.
struct ReaderFindMatch: Equatable, Sendable {
    /// The segment of the fully unfolded document the match is in.
    let segment: Int
    /// The match inside that segment's text (UTF-16, as TextKit counts).
    let range: NSRange
    /// The heading whose section holds the segment (an ordinal, `OrgFolding`),
    /// or nil before the document's first heading.
    let section: Int?
}

/// Searches a whole document for a query, across the sections a reader has
/// folded away. The document is described as the segments it would draw with
/// every heading open: each segment's searchable text (nil for an image, a
/// diagram) and the section it belongs to.
struct ReaderFindIndex: Sendable {
    struct Options: Sendable, Equatable {
        enum Words: Sendable { case contains, startsWith, fullWord }
        var caseSensitive = false
        var words: Words = .contains
    }

    let texts: [String?]
    let sections: [Int?]

    init(texts: [String?], sections: [Int?]) {
        self.texts = texts
        self.sections = sections
    }

    /// Every match, in reading order.
    func matches(for query: String, options: Options = Options()) -> [ReaderFindMatch] {
        guard !query.isEmpty else { return [] }
        let compare: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        var found: [ReaderFindMatch] = []
        for (segment, text) in texts.enumerated() {
            guard let text, !text.isEmpty else { continue }
            let string = text as NSString
            var cursor = 0
            while cursor < string.length {
                let range = string.range(of: query, options: compare, range: NSRange(location: cursor, length: string.length - cursor))
                guard range.location != NSNotFound else { break }
                cursor = range.upperBound
                if Self.accepts(range, in: string, words: options.words) {
                    found.append(ReaderFindMatch(segment: segment, range: range, section: sections[segment]))
                }
            }
        }
        return found
    }

    private static func accepts(_ range: NSRange, in string: NSString, words: Options.Words) -> Bool {
        func isWordCharacter(at index: Int) -> Bool {
            guard index >= 0, index < string.length,
                  let scalar = Unicode.Scalar(string.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        switch words {
        case .contains: return true
        case .startsWith: return !isWordCharacter(at: range.location - 1)
        case .fullWord: return !isWordCharacter(at: range.location - 1) && !isWordCharacter(at: range.upperBound)
        }
    }

    /// Each segment's section, from where the headings begin: `headingSegments`
    /// holds, for each heading block in order, the segment it opens (nil when it
    /// opens none), and `headingOrdinals` that block's heading ordinal. A
    /// document with no ordinals (Markdown) names the k-th heading k.
    static func sections(
        segmentCount: Int,
        headingSegments: [Int?],
        headingOrdinals: [Int?]?
    ) -> [Int?] {
        var starts: [(segment: Int, ordinal: Int)] = []
        for (block, segment) in headingSegments.enumerated() {
            guard let segment else { continue }
            let ordinal: Int?
            if let headingOrdinals {
                ordinal = headingOrdinals.indices.contains(block) ? headingOrdinals[block] : nil
            } else {
                ordinal = block + 1
            }
            if let ordinal { starts.append((segment: segment, ordinal: ordinal)) }
        }
        var result: [Int?] = []
        var next = 0
        var current: Int?
        for segment in 0..<segmentCount {
            while next < starts.count, starts[next].segment <= segment {
                current = starts[next].ordinal
                next += 1
            }
            result.append(current)
        }
        return result
    }

    /// The segment a section opens in the fully unfolded document, to count
    /// from when the section sits among folded ones.
    func firstSegment(ofSection section: Int) -> Int? {
        sections.firstIndex { $0 == section }
    }
}

/// Which match is highlighted, and the step to the next or previous one,
/// wrapping at the ends.
struct ReaderFindCursor: Equatable, Sendable {
    private(set) var count: Int
    private(set) var index: Int

    init(count: Int, index: Int = 0) {
        self.count = count
        self.index = count == 0 ? 0 : min(max(0, index), count - 1)
    }

    var isEmpty: Bool { count == 0 }

    mutating func step(forward: Bool) {
        guard count > 0 else { return }
        index = (index + (forward ? 1 : count - 1)) % count
    }

    /// The match nearest at or after `segment`, so a new query starts from
    /// where the person is reading: the first match at or after `from`, else the first.
    static func firstIndex(in matches: [ReaderFindMatch], atOrAfterSegment from: Int) -> Int {
        matches.firstIndex { $0.segment >= from } ?? 0
    }
}

extension ReaderOutline {
    /// The sections to open so `section`'s own text shows: those above it and
    /// its own, whichever of them `folded` holds closed.
    func sectionsToOpen(forMatchIn section: Int?, folded: Set<Int>) -> [Int] {
        guard let section else { return [] }
        return (ancestors(of: section) + [section]).filter { folded.contains($0) }
    }
}
