import UIKit

/// The system find bar's session over a whole reader document, folded sections
/// included. UIKit's own sessions search the text views that exist, and a
/// reader keeps only the visible part of a long document in views, so this one
/// searches the document (`ReaderFindIndex`) and asks its body to show each match.
@MainActor
final class ReaderFindSession: UIFindSession {
    private weak var body: NativeFullScreenMarkdownBody?
    private(set) var matches: [ReaderFindMatch] = []
    private(set) var cursor = ReaderFindCursor(count: 0)
    private var query = ""
    private var options = ReaderFindIndex.Options()
    /// Bumped by each search, so an index that lands late answers only the latest.
    private var generation = 0

    init(body: NativeFullScreenMarkdownBody) {
        self.body = body
        super.init()
        searchResultDisplayStyle = .currentAndTotal
    }

    override var resultCount: Int { matches.count }

    override var highlightedResultIndex: Int { matches.isEmpty ? NSNotFound : cursor.index }

    override var supportsReplacement: Bool { false }

    override var allowsReplacementForCurrentlyHighlightedResult: Bool { false }

    override func performSearch(query: String, options: UITextSearchOptions?) {
        self.query = query
        self.options = Self.options(from: options)
        generation += 1
        let mine = generation
        guard !query.isEmpty else {
            finish([], generation: mine)
            return
        }
        body?.findIndex { [weak self] index in
            guard let self, mine == self.generation else { return }
            self.finish(index.matches(for: self.query, options: self.options), generation: mine)
        }
    }

    override func highlightNextResult(in direction: UITextStorageDirection) {
        guard !matches.isEmpty else { return }
        cursor.step(forward: direction == .forward)
        showCurrent()
    }

    override func invalidateFoundResults() {
        generation += 1
        matches = []
        cursor = ReaderFindCursor(count: 0)
        body?.clearFindHighlight()
    }

    private func finish(_ found: [ReaderFindMatch], generation: Int) {
        matches = found
        cursor = ReaderFindCursor(count: found.count)
        if found.isEmpty { body?.clearFindHighlight() } else { showCurrent() }
        body?.updateFindResultCount()
    }

    private func showCurrent() {
        guard matches.indices.contains(cursor.index) else { return }
        body?.revealFindMatch(matches[cursor.index])
        body?.updateFindResultCount()
    }

    private static func options(from options: UITextSearchOptions?) -> ReaderFindIndex.Options {
        guard let options else { return ReaderFindIndex.Options() }
        let words: ReaderFindIndex.Options.Words = switch options.wordMatchMethod {
        case .startsWith: .startsWith
        case .fullWord: .fullWord
        default: .contains
        }
        return ReaderFindIndex.Options(
            caseSensitive: !options.stringCompareOptions.contains(.caseInsensitive),
            words: words
        )
    }
}
