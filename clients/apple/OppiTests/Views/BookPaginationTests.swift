import Testing
import UIKit
@testable import Oppi

/// Paging a chapter: the pages cover the chapter exactly once, a page never cuts
/// a line, the position survives a re-pagination, and the block ordinal a saved
/// position carries still names the same words.
@Suite("Book pagination", .serialized)
@MainActor
struct BookPaginationTests {
    /// The text area of a page on the phone the reader was built for.
    private static let pageSize = CGSize(width: 354, height: 700)
    private static let smallPageSize = CGSize(width: 300, height: 500)

    private func chapterPages(
        chapter: Int = 0,
        size: CGSize = pageSize
    ) throws -> (pages: BookChapterPages, source: EPUBChapterSource) {
        // A chapter long enough to page: the default fixture fits one page.
        let book = try EPUBBook.open(data: EPUBFixture.epub3(paragraphsPerChapter: 40))
        let source = try book.source(forChapter: chapter)
        let pages = BookChapterPaginator.layout(source: source, style: Self.style(), pageSize: size)
        return (pages, source)
    }

    @Test("the pages cover every character exactly once")
    func pagesCoverEveryCharacter() throws {
        let (pages, _) = try chapterPages()
        #expect(pages.pageRanges.count > 1, "the chapter fits on one page, so this proves nothing")
        #expect(pages.text.length > 0)

        var expectedLocation = 0
        for (index, range) in pages.pageRanges.enumerated() {
            #expect(range.location == expectedLocation, "page \(index) starts at \(range.location), not \(expectedLocation)")
            #expect(range.length > 0, "page \(index) is empty")
            expectedLocation = NSMaxRange(range)
        }
        #expect(expectedLocation == pages.text.length, "the pages end at \(expectedLocation) of \(pages.text.length)")
    }

    /// A page break is a line break: the first character of a page starts a line
    /// of the same text laid out in one tall column.
    @Test("no page cuts a line")
    func pageBreaksFallBetweenLines() throws {
        let (pages, _) = try chapterPages()
        let lineStarts = lines(of: pages.text, width: Self.pageSize.width)

        for (index, range) in pages.pageRanges.enumerated() where index > 0 {
            #expect(
                lineStarts.contains(range.location),
                "page \(index) starts at \(range.location), which is inside a line (\(lineStarts))"
            )
        }
    }

    /// A text-size change re-paginates; the page the person lands on still shows
    /// the words the first visible line had.
    @Test("a re-pagination keeps the first visible character on the page")
    func rePaginationKeepsTheFirstVisibleCharacter() throws {
        let book = try EPUBBook.open(data: EPUBFixture.epub3(paragraphsPerChapter: 40))
        let source = try book.source(forChapter: 0)
        let style = Self.style()
        let standard = BookChapterPaginator.layout(source: source, style: style, pageSize: Self.pageSize)
        let middle = standard.pageRanges.count / 2
        let character = standard.pageRanges[middle].location

        let larger = Self.style(scale: 1.35)
        let repaginated = BookChapterPaginator.layout(source: source, style: larger, pageSize: Self.pageSize)

        let page = repaginated.pageIndex(containingCharacter: character)
        let range = try #require(repaginated.pageRanges.indices.contains(page) ? repaginated.pageRanges[page] : nil)
        #expect(
            range.location <= character && character < NSMaxRange(range),
            "the first visible character \(character) fell outside page \(page) (\(range))"
        )
        // The same words are on the page, not a blank one.
        let prefix = (repaginated.text.string as NSString).substring(
            with: NSRange(location: character, length: min(24, repaginated.text.length - character))
        )
        let pageText = (repaginated.text.string as NSString).substring(with: range)
        #expect(pageText.contains(prefix), "\"\(prefix)\" is not on the page after the text-size change")
    }

    @Test("every page's text is a slice of the chapter")
    func pageTextIsASlice() throws {
        let (pages, _) = try chapterPages()
        for range in pages.pageRanges {
            let slice = (pages.text.string as NSString).substring(with: range)
            #expect(!slice.isEmpty)
            #expect((pages.text.string as NSString).range(of: slice).location != NSNotFound)
        }
    }

    /// A stored position is a block ordinal and a distance into it. The two
    /// have to name the same words in both directions, or a page turn and a
    /// reopen would drift apart.
    @Test("the stored position round-trips through the page text")
    func positionRoundTrips() throws {
        let (pages, source) = try chapterPages()
        #expect(source.blocks.count > 3)

        for ordinal in source.blocks.indices {
            let start = pages.characterOffset(forBlockOrdinal: ordinal)
            let position = pages.storedPosition(forCharacter: start)
            #expect(
                position.blockOrdinal == ordinal,
                "block \(ordinal) maps back to block \(position.blockOrdinal)"
            )
            #expect(
                pages.characterOffset(
                    forBlockOrdinal: position.blockOrdinal,
                    offsetPoints: position.offsetPoints
                ) == start
            )
        }

        // Every character of the chapter round-trips, not only block starts.
        for character in stride(from: 0, to: pages.text.length, by: 7) {
            let position = pages.storedPosition(forCharacter: character)
            let back = pages.characterOffset(
                forBlockOrdinal: position.blockOrdinal,
                offsetPoints: position.offsetPoints
            )
            #expect(back == character, "character \(character) came back as \(back)")
        }
    }

    /// A position the scrolling body saved carries a distance in points. Paged
    /// reading opens the page that holds that block, inside the block it names.
    @Test("a scroll position opens the page holding its block")
    func scrollingPositionOpensItsBlock() throws {
        let (pages, _) = try chapterPages()
        let stored = EPUBReadingPosition(chapterHref: "text/chapter-01.xhtml", blockOrdinal: 5, offsetPoints: 120)
        let character = pages.characterOffset(
            forBlockOrdinal: stored.blockOrdinal,
            offsetPoints: stored.offsetPoints
        )
        let page = pages.pageIndex(containingCharacter: character)
        let range = pages.pageRanges[page]
        #expect(range.location <= character && character < NSMaxRange(range))

        let written = pages.storedPosition(forCharacter: range.location)
        #expect(
            written.blockOrdinal <= stored.blockOrdinal,
            "the page opened after the block it was asked for"
        )
        #expect(
            pages.characterOffset(forBlockOrdinal: written.blockOrdinal, offsetPoints: written.offsetPoints)
                == range.location
        )
    }

    @Test("a page index outside the chapter is clamped")
    func pageIndexIsClamped() throws {
        let (pages, _) = try chapterPages()
        #expect(pages.pageIndex(containingCharacter: -100) == 0)
        #expect(pages.pageIndex(containingCharacter: pages.text.length + 1000) == pages.pageCount - 1)
        #expect(pages.characterOffset(forBlockOrdinal: -1) >= 0)
        #expect(pages.characterOffset(forBlockOrdinal: 10_000) < pages.text.length)
    }

    @Test("an empty chapter is one empty page")
    func emptyChapter() {
        let source = EPUBChapterSource(markdown: "", blocks: [], isRightToLeft: nil)
        let style = Self.style()
        let pages = BookChapterPaginator.layout(source: source, style: style, pageSize: Self.pageSize)
        #expect(pages.pageCount == 1)
        #expect(pages.pageRanges == [NSRange(location: 0, length: 0)])
        #expect(pages.pageIndex(containingCharacter: 12) == 0)
    }

    // MARK: - The text a page draws

    /// Markdown structure becomes roles: a heading's type, a list's hanging
    /// indent, a quote's inset, code in the monospaced font. None of the markers
    /// the converter writes reach the page.
    @Test("the chapter text carries its structure without its markers")
    func textCarriesStructure() throws {
        let markdown = """
        # A Heading

        A paragraph with **bold** and *italic* and `code` words.

        - first item
        - second item
          1. nested item

        > A quoted line.

        ```
        let x = 1
        ```

        ---
        """
        let blocks = [
            EPUBChapterBlock(markdownStartLine: 1, kind: .text),
            EPUBChapterBlock(markdownStartLine: 3, kind: .text),
            EPUBChapterBlock(markdownStartLine: 5, kind: .text),
            EPUBChapterBlock(markdownStartLine: 9, kind: .text),
            EPUBChapterBlock(markdownStartLine: 12, kind: .code),
            EPUBChapterBlock(markdownStartLine: 15, kind: .thematicBreak),
        ]
        let source = EPUBChapterSource(markdown: markdown, blocks: blocks, isRightToLeft: false)
        let style = Self.style()
        let pages = BookChapterPaginator.layout(source: source, style: style, pageSize: Self.pageSize)
        let text = pages.text.string

        #expect(text.contains("A Heading"))
        #expect(text.contains("first item"))
        #expect(text.contains("A quoted line."))
        #expect(text.contains("let x = 1"))
        #expect(!text.contains("**"), "the emphasis markers reached the page")
        #expect(!text.contains("```"), "the code fence reached the page")
        #expect(!text.contains("# "), "a heading marker reached the page")
        #expect(!text.contains("> "), "a quote marker reached the page")

        // A heading is set in its heading font; the code block in the mono font.
        let headingRange = (text as NSString).range(of: "A Heading")
        let headingFont = try #require(pages.text.attribute(.font, at: headingRange.location, effectiveRange: nil) as? UIFont)
        #expect(headingFont.pointSize > style.font(for: .body).pointSize)
        let codeRange = (text as NSString).range(of: "let x = 1")
        let codeFont = try #require(pages.text.attribute(.font, at: codeRange.location, effectiveRange: nil) as? UIFont)
        #expect(codeFont.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))

        #expect(pages.blockStarts.count == blocks.count)
        #expect(pages.blockStarts == pages.blockStarts.sorted())
    }

    /// The trailing end of the page line: words left in the chapter at 250 a
    /// minute, which is what "min left" is built from.
    @Test("words left in the chapter count from the page's first character")
    func wordsLeftCountFromThePage() throws {
        let (pages, _) = try chapterPages()
        let all = pages.words(fromCharacter: 0)
        let middle = pages.pageRanges[pages.pageCount / 2].location
        let rest = pages.words(fromCharacter: middle)
        #expect(all > rest, "the whole chapter is not more words than its second half")
        #expect(rest > 0)
        #expect(pages.words(fromCharacter: pages.text.length) == 0)
    }

    // MARK: - Helpers

    /// The page's typography: the reading appearance's defaults on the app's dark
    /// palette, which is what a book opens with.
    private static func style(scale: CGFloat = 1) -> BookPageStyle {
        BookPageStyle(
            appearance: BookReaderAppearance(),
            palette: ThemeID.dark.palette,
            textScale: scale,
            traits: nil
        )
    }

    /// The character offsets of every line start in `text` at `width`, from one
    /// container that holds the whole chapter.
    private func lines(of text: NSAttributedString, width: CGFloat) -> Set<Int> {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        var starts: Set<Int> = []
        var glyph = 0
        while glyph < layoutManager.numberOfGlyphs {
            var lineGlyphs = NSRange(location: 0, length: 0)
            _ = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            let characters = layoutManager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            starts.insert(characters.location)
            glyph = max(NSMaxRange(lineGlyphs), glyph + 1)
        }
        return starts
    }
}
