import Foundation
import Testing
@testable import Oppi

/// Find in a reader's whole document: what matches, which section a match sits
/// in, and which folds a match needs opened.
@Suite("Reader find index")
struct ReaderFindIndexTests {
    private func index(_ texts: [String?], sections: [Int?]? = nil) -> ReaderFindIndex {
        ReaderFindIndex(texts: texts, sections: sections ?? Array(repeating: nil, count: texts.count))
    }

    @Test func matchesAreFoundInReadingOrderAcrossSegments() {
        let found = index(["alpha beta", nil, "Beta again, beta"]).matches(for: "beta")
        #expect(found.map(\.segment) == [0, 2, 2])
        #expect(found.map(\.range) == [NSRange(location: 6, length: 4), NSRange(location: 0, length: 4), NSRange(location: 12, length: 4)])
    }

    @Test func caseAndDiacriticsFollowTheOptions() {
        let texts: [String?] = ["Café cafe CAFE"]
        #expect(index(texts).matches(for: "cafe").count == 3, "insensitive by default, accents folded")
        #expect(index(texts).matches(for: "cafe", options: .init(caseSensitive: true)).count == 1)
    }

    @Test func wordOptionsRespectWordEdges() {
        let texts: [String?] = ["plan planning replan plan."]
        func count(_ words: ReaderFindIndex.Options.Words) -> Int {
            index(texts).matches(for: "plan", options: .init(words: words)).count
        }
        #expect(count(.contains) == 4, "plan, planning, replan, plan.")
        #expect(count(.startsWith) == 3, "plan, planning, plan.")
        #expect(count(.fullWord) == 2, "plan, plan.")
    }

    @Test func nothingMatchesAnEmptyQueryOrAMissingWord() {
        #expect(index(["words"]).matches(for: "").isEmpty)
        #expect(index(["words"]).matches(for: "zzz").isEmpty)
        #expect(index([]).matches(for: "a").isEmpty)
    }

    @Test func aMatchNamesTheSectionItIsIn() {
        let found = index(["intro", "alpha body", "beta body"], sections: [nil, 1, 2]).matches(for: "body")
        #expect(found.map(\.section) == [1, 2])
    }

    // MARK: - Sections

    @Test func sectionsRunFromEachHeadingsSegmentToTheNextAndMatchOrgOrdinals() {
        // Segments: 0 preface, 1 heading A, 2 its code, 3 heading B. Block 0 is a
        // #+TITLE (no ordinal); A and B are ordinals 1 and 2.
        let sections = ReaderFindIndex.sections(
            segmentCount: 5,
            headingSegments: [0, 1, 3],
            headingOrdinals: [nil, 1, 2]
        )
        #expect(sections == [nil, 1, 1, 2, 2])
    }

    @Test func aMarkdownDocumentNamesTheKthHeadingK() {
        let sections = ReaderFindIndex.sections(segmentCount: 4, headingSegments: [0, 2], headingOrdinals: nil)
        #expect(sections == [1, 1, 2, 2])
    }

    @Test func aSectionOpensAtItsFirstSegment() {
        let index = index(["a", "b", "c"], sections: [nil, 4, 4])
        #expect(index.firstSegment(ofSection: 4) == 1)
        #expect(index.firstSegment(ofSection: 9) == nil)
    }

    // MARK: - Folds

    @Test func aMatchOpensEveryClosedSectionAroundIt() {
        let outline = ReaderOutline(headings: [
            ReaderHeading(ordinal: 1, line: 1, level: 1, title: "A"),
            ReaderHeading(ordinal: 2, line: 5, level: 2, title: "B"),
            ReaderHeading(ordinal: 3, line: 9, level: 3, title: "C"),
            ReaderHeading(ordinal: 4, line: 12, level: 1, title: "D"),
        ])
        #expect(outline.sectionsToOpen(forMatchIn: 3, folded: [1, 3, 4]) == [1, 3], "its parents and its own body, not D")
        #expect(outline.sectionsToOpen(forMatchIn: 3, folded: []).isEmpty)
        #expect(outline.sectionsToOpen(forMatchIn: nil, folded: [1]).isEmpty, "text before the first heading is never folded")
    }

    @Test func aMatchInAFoldedOrgSectionIsFoundFromTheWholeDocument() throws {
        let source = "* Open\nvisible words\n* Closed\n** Inner\nneedle in a fold\n"
        let located = OrgParser().parseLocated(source)
        let converted = DocumentRenderPipeline.orgToMarkdown(
            located: located, foldingHeadings: .init(folded: [2]), cancellationCheck: { false }
        )
        let shown = try #require(converted)
        #expect(!shown.contains("needle"), "folded away from the reader's own text")

        let unfolded = DocumentRenderPipeline.orgToMarkdown(located: located, cancellationCheck: { false })
        let full = try #require(unfolded)
        let build = FlatSegment.buildWithSourceLineRanges(
            from: parseCommonMarkLocated(full), themeID: .dark, mergeAdjacentTextSegments: true, splitsAtHeadings: true
        )
        let texts = build.segments.map { segment -> String? in
            if case .text(let text) = segment { return String(text.characters) }
            return nil
        }
        let sections = ReaderFindIndex.sections(
            segmentCount: texts.count, headingSegments: build.headingSegments,
            headingOrdinals: OrgFolding.ordinals(of: located).sorted { $0.key < $1.key }.map { $0.value }
        )
        let found = ReaderFindIndex(texts: texts, sections: sections).matches(for: "needle")
        #expect(found.count == 1)
        #expect(found.first?.section == 3, "Inner is the third heading")
        let outline = ReaderOutline.org(located)
        #expect(outline.sectionsToOpen(forMatchIn: found.first?.section, folded: [2, 3]) == [2, 3])
    }

    // MARK: - Cursor

    @Test func theCursorWrapsInBothDirections() {
        var cursor = ReaderFindCursor(count: 3)
        cursor.step(forward: false)
        #expect(cursor.index == 2)
        cursor.step(forward: true)
        cursor.step(forward: true)
        #expect(cursor.index == 1)
        var none = ReaderFindCursor(count: 0)
        none.step(forward: true)
        #expect(none.isEmpty && none.index == 0)
    }

    @Test func aNewQueryStartsAtTheFirstMatchOnOrAfterTheReadingPlace() {
        let matches = [0, 2, 5].map { ReaderFindMatch(segment: $0, range: NSRange(location: 0, length: 1), section: nil) }
        #expect(ReaderFindCursor.firstIndex(in: matches, atOrAfterSegment: 1) == 1)
        #expect(ReaderFindCursor.firstIndex(in: matches, atOrAfterSegment: 9) == 0, "past the last: wrap to the first")
    }
}
