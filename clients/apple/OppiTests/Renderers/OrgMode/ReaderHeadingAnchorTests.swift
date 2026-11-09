import Foundation
import Testing
import UIKit
@testable import Oppi

/// Finding a heading: what each way of naming one resolves to, which sections
/// a heading sits under, and the reader scrolling there.
@Suite("Reader heading anchors")
struct ReaderHeadingAnchorTests {
    private static let notebook = """
    #+TITLE: Notebook
    * Alpha
    :PROPERTIES:
    :ID: 11111111-aaaa
    :END:
    alpha body
    ** Alpha one
    :PROPERTIES:
    :CUSTOM_ID: one-id
    :END:
    one body
    *** Deep :tag:
    deep body
    * TODO Beta [1/2]
    beta body
    * Alpha
    duplicate body
    """

    // The headings above, by ordinal, and the lines they start on.
    private let alpha = 1, alphaOne = 2, deep = 3, beta = 4, alphaAgain = 5

    private func orgOutline() -> ReaderOutline {
        ReaderOutline.org(OrgParser().parseLocated(Self.notebook))
    }

    // MARK: - Resolution

    @Test func eachWayOfNamingAHeadingFindsIt() {
        let outline = orgOutline()
        #expect(outline.headings.map(\.title) == ["Alpha", "Alpha one", "Deep", "Beta", "Alpha"])
        #expect(outline.resolve(.ordinal(deep))?.title == "Deep")
        #expect(outline.resolve(.title("Alpha"))?.ordinal == alpha, "the first of two headings with a title")
        #expect(outline.resolve(.title("Beta"))?.ordinal == beta, "a state and a cookie are not the title")
        #expect(outline.resolve(.id("11111111-aaaa"))?.ordinal == alpha)
        #expect(outline.resolve(.customID("one-id"))?.ordinal == alphaOne)
        #expect(outline.resolve(.slug("one-id"))?.ordinal == alphaOne, "a #custom-id is also a bare anchor")
    }

    @Test func aSourceLineFindsTheSectionItIsIn() {
        let outline = orgOutline()
        #expect(outline.resolve(.line(12))?.ordinal == deep, "the heading's own line")
        #expect(outline.resolve(.line(13))?.ordinal == deep, "a line in its body")
        #expect(outline.resolve(.line(6))?.ordinal == alpha)
        #expect(outline.resolve(.line(1)) == nil, "before the first heading")
    }

    @Test func unknownAnchorsResolveToNothing() {
        let outline = orgOutline()
        #expect(outline.resolve(.ordinal(0)) == nil)
        #expect(outline.resolve(.ordinal(99)) == nil)
        #expect(outline.resolve(.title("Missing")) == nil)
        #expect(outline.resolve(.id("nope")) == nil)
        #expect(outline.resolve(.customID("nope")) == nil)
        #expect(ReaderOutline(headings: []).resolve(.ordinal(1)) == nil)
    }

    @Test func aHeadingKnowsTheSectionsAboveIt() {
        let outline = orgOutline()
        #expect(outline.ancestors(of: deep) == [alpha, alphaOne], "outermost first")
        #expect(outline.ancestors(of: alphaOne) == [alpha])
        #expect(outline.ancestors(of: beta).isEmpty)
        #expect(outline.ancestors(of: alphaAgain).isEmpty, "a sibling is not an ancestor")
    }

    @Test func aHeadingKeepsItsStateAndIds() throws {
        let outline = orgOutline()
        let beta = try #require(outline.heading(ordinal: beta))
        #expect(beta.keyword == "TODO" && !beta.isDone)
        #expect(outline.heading(ordinal: alpha)?.id == "11111111-aaaa")
        #expect(outline.heading(ordinal: alpha)?.line == 2)
    }

    @Test func markdownAnchorsAreGitHubSlugs() throws {
        let located = parseCommonMarkLocated("""
        # Intro

        ## Setup & Run

        text

        ## Setup & Run

        ### `Code` and *emphasis*
        """)
        let outline = ReaderOutline.markdown(located)
        #expect(outline.headings.map(\.title) == ["Intro", "Setup & Run", "Setup & Run", "Code and emphasis"])
        #expect(outline.resolve(.slug("intro"))?.ordinal == 1)
        #expect(outline.resolve(.slug("setup--run"))?.ordinal == 2)
        #expect(outline.resolve(.slug("setup--run-1"))?.ordinal == 3, "a repeat takes -1")
        #expect(outline.resolve(.slug("code-and-emphasis"))?.ordinal == 4)
        #expect(try #require(outline.resolve(.ordinal(2))).line == 3)
        #expect(outline.ancestors(of: 4) == [1, 3])
    }

    @Test func aFragmentRoundTripsToItsAnchor() {
        let anchors: [ReaderHeadingAnchor] = [
            .ordinal(7), .line(42), .title("Ship (the) reader / 100% → done"), .id("3f2a-9c1e"),
            .customID("release notes"), .slug("setup--run"),
        ]
        for anchor in anchors {
            #expect(ReaderHeadingAnchor(fragment: anchor.fragment) == anchor)
        }
        #expect(!ReaderHeadingAnchor.title("a b").fragment.contains(" "))
        #expect(ReaderHeadingAnchor(fragment: "") == nil)
        #expect(ReaderHeadingAnchor(fragment: "ordinal=0") == .slug("ordinal=0"), "not a heading number, so a slug")
    }

    // MARK: - Links

    /// The heading a link in `body` jumps to, as the reader resolves it: the
    /// link's destination, read back as an anchor, against the document's outline.
    private func markdown(of source: String) throws -> String {
        let converted = DocumentRenderPipeline.orgToMarkdown(
            source, documentPath: "/notes/book.org", cancellationCheck: { false }
        )
        return try #require(converted)
    }

    private func jump(_ link: String) throws -> ReaderHeading? {
        let source = Self.notebook + "\nSee \(link)."
        let markdown = try markdown(of: source)
        let destinations = parseCommonMark(markdown).flatMap { block -> [String] in
            guard case .paragraph(let inlines) = block else { return [] }
            return inlines.compactMap { inline in
                if case .link(_, let destination) = inline { return destination }
                return nil
            }
        }
        let destination = try #require(destinations.first, "\(link) is a link")
        let url = try #require(URL(string: destination))
        let anchor = try #require(ReaderHeadingAnchor(linkURL: url), "\(link) stays in the reader")
        return orgOutline().resolve(anchor)
    }

    private static func anchor(in url: URL?) -> ReaderHeadingAnchor? {
        url.flatMap { ReaderHeadingAnchor(linkURL: $0) }
    }

    @Test func eachOrgLinkFormJumpsToItsHeading() throws {
        #expect(try jump("[[*Alpha one]]")?.ordinal == alphaOne)
        #expect(try jump("[[*Deep][down]]")?.ordinal == deep)
        #expect(try jump("[[id:11111111-aaaa]]")?.ordinal == alpha)
        #expect(try jump("[[#one-id]]")?.ordinal == alphaOne)
    }

    @Test func aTitleWithPunctuationSurvivesTheLinkAndMatches() throws {
        let source = "* Ship (the) 100% reader / v2 & more\nSee [[*Ship (the) 100% reader / v2 & more]]."
        let markdown = try markdown(of: source)
        guard case .paragraph(let inlines) = parseCommonMark(markdown)[1],
              case .link(_, let destination?) = inlines[1] else {
            Issue.record("expected a link in \(markdown)")
            return
        }
        let anchor = try #require(Self.anchor(in: URL(string: destination)))
        let outline = ReaderOutline.org(OrgParser().parseLocated(source))
        #expect(outline.resolve(anchor)?.ordinal == 1)
    }

    @Test func aLinkToAHeadingOfTheOpenFileSurvivesRendering() throws {
        let markdown = try markdown(of: "* Target\n- [[*Target][Go to target]]\nSee [[*Target][again]].")
        let segments = FlatSegment.build(
            from: parseCommonMark(markdown), themeID: .dark, serverID: "s", workspaceID: "w", sourceDirectory: "/notes"
        )
        let anchors = segments.flatMap { segment -> [ReaderHeadingAnchor] in
            guard case .text(let text) = segment else { return [] }
            return text.runs.compactMap(\.link).compactMap { ReaderHeadingAnchor(linkURL: $0) }
        }
        #expect(anchors == [.title("Target"), .title("Target")], "markdown: \(markdown)")
    }

    @Test func aLinkToAnotherFileCarriesItsHeadingToTheOpenRequest() throws {
        let markdown = try markdown(
            of: "See [[file:other.org::*Checklist][list]], [[file:other.org::#cid][id]] and [[file:other.org::7][line]]."
        )
        let segments = FlatSegment.build(
            from: parseCommonMark(markdown), themeID: .dark, serverID: "s", workspaceID: "w", sourceDirectory: "/notes"
        )
        let references = segments.flatMap { segment -> [ResourceReference] in
            guard case .text(let text) = segment else { return [] }
            return text.runs.compactMap(\.link).compactMap(ResourceReferenceURL.parse)
        }
        #expect(references.map(\.headingAnchor) == [.title("Checklist"), .customID("cid"), nil])
        #expect(Set(references.compactMap(\.fileCandidatePath)) == ["/notes/other.org"])
    }

    @Test func aMarkdownFileLinkCarriesItsFragmentAsASlug() throws {
        let segments = FlatSegment.build(
            from: parseCommonMark("See [setup](docs/guide.md#install-steps) and [line](docs/guide.md#L4)."),
            themeID: .dark, serverID: "s", workspaceID: "w", sourceDirectory: nil
        )
        let references = segments.flatMap { segment -> [ResourceReference] in
            guard case .text(let text) = segment else { return [] }
            return text.runs.compactMap(\.link).compactMap(ResourceReferenceURL.parse)
        }
        #expect(references.map(\.headingAnchor) == [.slug("install-steps"), nil])
        #expect(references.map { $0.lineAnchor?.fragment } == [nil, "#L4"])
    }

    // MARK: - Segments

    @Test func eachHeadingOpensItsOwnSegmentWhenTheBuildSplits() {
        let located = parseCommonMarkLocated("""
        # A

        prose a

        ## B

        prose b

        ```swift
        let x = 1
        ```

        # C
        """)
        func headingSegments(merge: Bool, split: Bool) -> [Int?] {
            FlatSegment.buildWithSourceLineRanges(
                from: located, mergeAdjacentTextSegments: merge, splitsAtHeadings: split
            ).headingSegments
        }
        // A and its prose, B and its prose, the code, C.
        #expect(headingSegments(merge: true, split: true) == [0, 1, 3])
        // Every block apart: each heading is a segment of its own.
        #expect(headingSegments(merge: false, split: false) == [0, 2, 5])
        // Merged text has no place for a heading.
        #expect(headingSegments(merge: true, split: false) == [nil, nil, nil])
    }

    // MARK: - The reader

    @MainActor
    private final class Mounted {
        let body: NativeFullScreenMarkdownBody
        let window: UIWindow
        private let start: Set<Int>
        /// The folds the reader last reported to its owner.
        var folded: Set<Int> { box.folded ?? start }

        init(source: String, folded: Set<Int> = [], format: MarkdownReaderSourceFormat = .orgMode, path: String = "notes.org") {
            start = folded
            let box = FoldBox()
            let memory = OrgFoldMemory(folded: folded) { box.folded = $0 }
            self.box = box
            body = NativeFullScreenMarkdownBody(
                content: source,
                sourceFormat: format,
                palette: ThemeID.dark.palette,
                reviewCommentSelectionRouter: nil,
                reviewCommentSourceContext: nil,
                sourceFilePath: path,
                orgFolds: memory
            )
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.addSubview(body)
            body.frame = window.bounds
            window.makeKeyAndVisible()
        }

        private final class FoldBox { var folded: Set<Int>? }
        private let box: FoldBox

        /// Runs the main loop until `condition` holds, a turn at a time.
        func settle(_ what: String, until condition: () -> Bool) async throws {
            for _ in 0..<600 {
                body.layoutIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("never settled: \(what)")
        }

        var offset: CGFloat { body.collectionView.contentOffset.y }

        /// How far below the top of the screen the item sits.
        func topOfItem(_ item: Int) -> CGFloat? {
            body.collectionView.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: item, section: 0))
                .map { $0.frame.minY - offset - body.collectionView.adjustedContentInset.top }
        }
    }

    private static let long: String = {
        func section(_ n: Int) -> String {
            "* Section \(n)\n" + (1...6).map { "Paragraph \($0) of section \(n), long enough to make the section tall on a phone screen." }
                .joined(separator: "\n\n") + "\n"
        }
        return (1...12).map(section).joined(separator: "\n")
            + "** Nested\n\nNested body.\n*** Deep target\n\nTarget body.\n"
    }()

    @MainActor
    @Test func scrollingToAHeadingPutsItAtTheTop() async throws {
        let reader = Mounted(source: Self.long)
        try await reader.settle("first draw") { !reader.body.renderedSegments.isEmpty }
        #expect(reader.body.scrollToHeading(.title("Section 9")))
        try await reader.settle("the scroll") { reader.offset > 100 }
        let item = try #require(reader.body.headingPlacement.segment(forOrdinal: 9))
        let top = try #require(reader.topOfItem(item))
        #expect(abs(top) < 24, "Section 9 sits at the top of the screen, not \(top) below it")
        #expect(!reader.body.scrollToHeading(.title("Missing")), "an unknown heading is refused")
    }

    @MainActor
    @Test func aHeadingInAFoldedSectionOpensItsAncestorsFirst() async throws {
        // Section 12 is ordinal 12; Nested and Deep target follow it.
        let reader = Mounted(source: Self.long, folded: [12, 13, 5])
        try await reader.settle("first draw") { !reader.body.renderedSegments.isEmpty }
        #expect(reader.body.scrollToHeading(.title("Deep target")))
        try await reader.settle("the scroll") { reader.offset > 100 }
        #expect(reader.folded == [5], "its sections are open, an unrelated fold is left alone: \(reader.folded)")
        let item = try #require(reader.body.headingPlacement.segment(forOrdinal: 14))
        // The last heading of the file cannot reach the top; it is on screen.
        let top = try #require(reader.topOfItem(item))
        #expect(top >= 0 && top < 844, "Deep target is on screen, at \(top)")
    }

    @MainActor
    @Test func tappingALinkToAHeadingRunsTheReadersOwnAction() async throws {
        let reader = Mounted(source: Self.long)
        try await reader.settle("first draw") { !reader.body.renderedSegments.isEmpty }
        let link = try #require(URL(string: ReaderHeadingAnchor.title("Section 7").linkDestination))
        let fallback = UIAction { _ in Issue.record("the default action ran") }
        let action = try #require(reader.body.primaryAction(for: link, from: UITextView(), defaultAction: fallback))
        action.performWithSender(nil, target: nil)
        try await reader.settle("the scroll") { reader.offset > 100 }
        let item = try #require(reader.body.headingPlacement.segment(forOrdinal: 7))
        #expect(abs(try #require(reader.topOfItem(item))) < 24)
    }

    @MainActor
    @Test func aMarkdownReaderScrollsToASlug() async throws {
        let source = (1...10).map { n in
            "## Part \(n)\n\n" + (1...6).map { _ in "Filler prose for part \(n), long enough to make the part tall on a phone." }
                .joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        let reader = Mounted(source: source, format: .markdown, path: "notes.md")
        try await reader.settle("first draw") { !reader.body.renderedSegments.isEmpty }
        let own = try #require(URL(string: ReaderHeadingAnchor.slug("part-8").linkDestination))
        #expect(reader.body.headingAction(for: own) != nil)
        #expect(reader.body.headingAction(for: try #require(URL(string: "https://example.com/#part-8"))) == nil)
        #expect(reader.body.headingAction(for: try #require(URL(string: "notes.md#part-8"))) == nil)
        #expect(reader.body.scrollToHeading(.slug("part-8")))
        try await reader.settle("the scroll") { reader.offset > 100 }
        let item = try #require(reader.body.headingPlacement.segment(forOrdinal: 8))
        #expect(abs(try #require(reader.topOfItem(item))) < 24)
    }
}
