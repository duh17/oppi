import UIKit

/// Find in terminal output: the system find bar over the displayed text, the
/// same text Copy copies. A match is searched within one virtualized chunk, so
/// one that spans two chunks' boundary is not found.
extension NativeFullScreenTerminalBody: UIFindInteractionDelegate {
    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        TerminalFindSession(body: self)
    }

    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        markFindMatch(nil)
    }

    override var canBecomeFirstResponder: Bool { true }

    override func find(_ sender: Any?) { presentFind() }

    override func findNext(_ sender: Any?) { findInteraction?.findNext() }

    override func findPrevious(_ sender: Any?) { findInteraction?.findPrevious() }
}

/// One search of a terminal body: its matches, as ranges of the whole output,
/// and the one shown.
final class TerminalFindSession: UIFindSession {
    private weak var body: NativeFullScreenTerminalBody?
    private var matches: [NSRange] = []
    private var current = 0

    init(body: NativeFullScreenTerminalBody) {
        self.body = body
        super.init()
        searchResultDisplayStyle = .currentAndTotal
    }

    override var resultCount: Int { matches.count }

    override var highlightedResultIndex: Int { matches.isEmpty ? NSNotFound : current }

    override var supportsReplacement: Bool { false }

    override var allowsReplacementForCurrentlyHighlightedResult: Bool { false }

    override func performSearch(query: String, options: UITextSearchOptions?) {
        matches = query.isEmpty ? [] : Self.matches(of: query, in: body?.findSegments ?? [], options: options)
        current = 0
        body?.markFindMatch(matches.first)
        body?.findInteraction?.updateResultCount()
    }

    override func highlightNextResult(in direction: UITextStorageDirection) {
        guard !matches.isEmpty else { return }
        current = (current + (direction == .forward ? 1 : matches.count - 1)) % matches.count
        body?.markFindMatch(matches[current])
        body?.findInteraction?.updateResultCount()
    }

    override func invalidateFoundResults() {
        matches = []
        current = 0
        body?.markFindMatch(nil)
    }

    /// Every match of `query` in `segments`, in order, as ranges of the whole output.
    static func matches(
        of query: String,
        in segments: [(start: Int, text: NSString)],
        options: UITextSearchOptions?
    ) -> [NSRange] {
        var compare: NSString.CompareOptions = []
        if options?.stringCompareOptions.contains(.caseInsensitive) ?? true { compare.insert(.caseInsensitive) }
        if options?.stringCompareOptions.contains(.diacriticInsensitive) == true { compare.insert(.diacriticInsensitive) }
        var found: [NSRange] = []
        for segment in segments {
            var searchRange = NSRange(location: 0, length: segment.text.length)
            while searchRange.length > 0 {
                let hit = segment.text.range(of: query, options: compare, range: searchRange)
                guard hit.location != NSNotFound, hit.length > 0 else { break }
                found.append(NSRange(location: segment.start + hit.location, length: hit.length))
                searchRange = NSRange(location: NSMaxRange(hit), length: segment.text.length - NSMaxRange(hit))
            }
        }
        return found
    }
}
