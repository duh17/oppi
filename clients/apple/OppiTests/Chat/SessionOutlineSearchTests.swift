import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Session outline search", .serialized)
@MainActor
struct SessionOutlineSearchTests {
    /// Rows are keyed by entry id, so a row that matches both an earlier and
    /// a later query stays in the list. It must show the later query's
    /// highlights, not the ones it was first configured with.
    @Test func refiningTheQueryRehighlightsRowsThatStay() async throws {
        let reducer = TimelineReducer()
        reducer.appendUserMessage("session search setup notes")
        reducer.appendUserMessage("search the timeline")
        reducer.appendUserMessage("unrelated row")
        let outline = SessionOutlineViewController(
            items: reducer.items,
            toolArgsStore: reducer.toolArgsStore,
            onSelect: { _ in },
            onClose: {}
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = RouterNavigationController(rootViewController: outline)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        let search = try #require(outline.navigationItem.searchController)

        try await type("se", into: search, outline: outline)
        let first = visibleHighlights(in: outline)
        #expect(first.count == 2, "Both search rows match \"se\": \(first)")
        #expect(first.allSatisfy { $0.value == expectedHighlights(summary: $0.key, query: "se") })

        try await type("search", into: search, outline: outline)
        let refined = visibleHighlights(in: outline)
        #expect(Set(refined.keys) == Set(first.keys), "The same rows match \"search\"")
        for (summary, ranges) in refined {
            #expect(
                ranges == expectedHighlights(summary: summary, query: "search"),
                "\(summary) shows stale highlights \(ranges)"
            )
        }
        #expect(refined["session search setup notes"] != first["session search setup notes"])

        try await type("", into: search, outline: outline)
        let cleared = visibleHighlights(in: outline)
        #expect(cleared.count == 3 && cleared.values.allSatisfy { $0.isEmpty }, "Clearing search clears highlights: \(cleared)")
    }

    private func type(_ text: String, into search: UISearchController, outline: SessionOutlineViewController) async throws {
        search.searchBar.text = text
        search.searchResultsUpdater?.updateSearchResults(for: search)
        let applied = await waitForTimelineCondition(timeoutMs: 2_000) {
            await MainActor.run { outline.query == text }
        }
        try #require(applied, "The debounced query never reached \"\(text)\"")
        outline.view.layoutIfNeeded()
    }

    private func expectedHighlights(summary: String, query: String) -> [NSRange] {
        let positions = FuzzyMatch.rank(query: query, fields: [[summary]]).first?.positions ?? []
        return OutlineHighlight.ranges(in: summary, scalarPositions: positions)
    }

    /// Bold runs of each visible row's summary, keyed by summary text.
    private func visibleHighlights(in outline: SessionOutlineViewController) -> [String: [NSRange]] {
        var result: [String: [NSRange]] = [:]
        for cell in entryCells(in: outline.view) {
            guard let text = cell.summaryLabel.attributedText else { continue }
            var bold: [NSRange] = []
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if let font = value as? UIFont, font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                    bold.append(range)
                }
            }
            result[text.string] = bold
        }
        return result
    }

    private func entryCells(in root: UIView) -> [SessionOutlineEntryCell] {
        if let collection = root as? UICollectionView {
            collection.layoutIfNeeded()
            return collection.visibleCells.compactMap { $0 as? SessionOutlineEntryCell }
        }
        return root.subviews.flatMap { entryCells(in: $0) }
    }
}
