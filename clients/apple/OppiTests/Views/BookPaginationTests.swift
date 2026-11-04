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
                    offset: position.offset,
                    unit: .characters
                ) == start
            )
        }

        // Every character of the chapter round-trips, not only block starts.
        for character in stride(from: 0, to: pages.text.length, by: 7) {
            let position = pages.storedPosition(forCharacter: character)
            let back = pages.characterOffset(
                forBlockOrdinal: position.blockOrdinal,
                offset: position.offset,
                unit: .characters
            )
            #expect(back == character, "character \(character) came back as \(back)")
        }
    }

    /// A position the scrolling body saved carries a distance in points. Paged
    /// reading opens the page that holds that block, inside the block it names.
    @Test("a scroll position opens the page holding its block")
    func scrollingPositionOpensItsBlock() throws {
        let (pages, _) = try chapterPages()
        let stored = EPUBReadingPosition(
            chapterHref: "text/chapter-01.xhtml",
            blockOrdinal: 5,
            offset: 120,
            unit: .points
        )
        let character = pages.characterOffset(
            forBlockOrdinal: stored.blockOrdinal,
            offset: stored.offset,
            unit: stored.unit
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
            pages.characterOffset(
                forBlockOrdinal: written.blockOrdinal,
                offset: written.offset,
                unit: .characters
            ) == range.location
        )
    }

    /// A chapter of one long paragraph: every page break is mid-paragraph, and the
    /// block the distance is measured in spans many lines.
    private func oneParagraphPages(
        repetitions: Int = 80
    ) throws -> (pages: BookChapterPages, source: EPUBChapterSource) {
        let markdown = String(
            repeating: "The quiet morning says the same calm thing again and again. ",
            count: repetitions
        )
        let source = EPUBChapterSource(
            markdown: markdown,
            blocks: [EPUBChapterBlock(markdownStartLine: 1, kind: .text)],
            isRightToLeft: false
        )
        let pages = BookChapterPaginator.layout(source: source, style: Self.style(), pageSize: Self.pageSize)
        return (pages, source)
    }

    /// The two units count the same block, and each converts into the other
    /// through the block's own laid-out height: points are a distance down the
    /// page's type, characters a count into the same text.
    @Test("a distance in points and a count in characters name the same line")
    func unitsConvertThroughTheBlock() throws {
        let (pages, _) = try oneParagraphPages()
        #expect(pages.pageCount > 3, "the paragraph is too short to page: \(pages.pageCount)")
        let ordinal = 0
        let range = pages.blockRange(at: ordinal)
        // Most of the way down the paragraph: many lines below its first.
        let target = range.start + (range.end - range.start) * 3 / 4
        let points = pages.pointOffset(forBlockOrdinal: ordinal, character: target)
        #expect(
            points > 0,
            "the block's last quarter measured at its top: block \(range.start)..\(range.end), target \(target)"
        )

        let byPoints = pages.characterOffset(
            forBlockOrdinal: ordinal,
            offset: points,
            unit: .points
        )
        // The line that distance falls on, not a character count taken as points.
        #expect(byPoints > range.start, "the distance opened at the block's start: \(byPoints)")
        #expect(
            byPoints <= target,
            "the distance landed past the character it names: \(byPoints) for \(target)"
        )
        #expect(
            target - byPoints < 160,
            "the distance \(points) named character \(byPoints), \(target - byPoints) away from \(target)"
        )
        // The same number read as characters lands where a page would cut it.
        #expect(
            pages.characterOffset(forBlockOrdinal: ordinal, offset: points, unit: .characters)
                == range.start + Int(points),
            "the unit made no difference to where the position opened"
        )
    }

    /// TextKit justifies a line only inside a paragraph, and never the last line
    /// of a container. A page's last line is nearly always mid-paragraph, so the
    /// cell lays the page's text out with the rest of that paragraph in a
    /// container taller than the page and clips it: the line the person sees is
    /// set like the ones above it, and the clipped lines carry nothing new to
    /// read.
    @Test("a page that breaks mid-paragraph justifies its last line")
    func pageTextJustifiesItsLastLine() throws {
        let (pages, _) = try oneParagraphPages()
        #expect(pages.pageCount > 3, "the paragraph is too short to page: \(pages.pageCount)")

        for index in 1..<(pages.pageCount - 1) {
            let text = pages.pageText(at: index)
            let label = pages.pageLabel(at: index)
            #expect(text.length > label.count, "page \(index) was not continued past the page")
            #expect(text.string.hasPrefix(label), "page \(index) does not start with its own words")

            // The cell's text view: the page's area plus the slack it clips.
            let lines = pageLines(
                text,
                size: CGSize(width: pages.pageSize.width, height: pages.pageSize.height + 120)
            )
            // The lines inside the page's own area that draw something: an empty
            // fragment at the clip has no width and says nothing.
            let visible = lines.filter { $0.maxY <= pages.pageSize.height && $0.width > 0 }
            let last = try #require(visible.last, "page \(index) laid out no lines")
            #expect(
                last.width >= pages.pageSize.width - 1,
                "page \(index)'s last line is \(last.width) wide of \(pages.pageSize.width): \(lines.map(\.width))"
            )
        }

        // The chapter's own last page ends its paragraph: nothing to continue,
        // and nothing to set like the lines above it.
        let lastPage = pages.pageCount - 1
        #expect(
            pages.pageText(at: lastPage).string == pages.pageLabel(at: lastPage),
            "the chapter's last page grew a continuation"
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

    /// `original` is the app's own reader paper, so a page set on it keeps the
    /// app's heading and link ink: the scrolling chapter draws those runs in
    /// them, and switching layouts must not repaint the heading.
    @Test("a page on the app's own paper keeps the app's heading and link ink")
    func originalThemeKeepsAppInk() throws {
        let palette = ThemeID.dark.palette
        let appearance = BookReaderAppearance()
        let style = BookPageStyle(appearance: appearance, palette: palette, textScale: 1, traits: nil)
        try #require(appearance.theme == .original, "the default paper is no longer the app's own")
        #expect(style.color(for: .heading(level: 1)) == palette.ui.mdHeading)
        #expect(style.color(for: .heading(level: 3)) == palette.ui.mdHeading)
        #expect(style.color(for: .body) == appearance.textColor(in: palette))
        #expect(style.linkColor == palette.ui.mdLink)

        let markdown = """
        # A Heading

        A paragraph with a [link](https://example.com) inside it.
        """
        let blocks = [
            EPUBChapterBlock(markdownStartLine: 1, kind: .text),
            EPUBChapterBlock(markdownStartLine: 3, kind: .text),
        ]
        let source = EPUBChapterSource(markdown: markdown, blocks: blocks, isRightToLeft: false)
        let text = BookChapterPaginator.attributedText(source: source, style: style).text
        let heading = (text.string as NSString).range(of: "A Heading")
        let headingInk = text.attribute(.foregroundColor, at: heading.location, effectiveRange: nil) as? UIColor
        #expect(headingInk == palette.ui.mdHeading, "the heading is \(String(describing: headingInk))")
        let link = (text.string as NSString).range(of: "link")
        let linkInk = text.attribute(.foregroundColor, at: link.location, effectiveRange: nil) as? UIColor
        #expect(linkInk == palette.ui.mdLink, "the link is \(String(describing: linkInk))")
        let bodyRange = (text.string as NSString).range(of: "A paragraph")
        let bodyInk = text.attribute(.foregroundColor, at: bodyRange.location, effectiveRange: nil) as? UIColor
        #expect(bodyInk == appearance.textColor(in: palette))

        // A fixed paper paints its own ink, heading or not.
        var sepia = appearance
        sepia.theme = .sepia
        let sepiaStyle = BookPageStyle(appearance: sepia, palette: palette, textScale: 1, traits: nil)
        let sepiaText = BookChapterPaginator.attributedText(source: source, style: sepiaStyle).text
        let sepiaInk = sepiaText.attribute(.foregroundColor, at: heading.location, effectiveRange: nil) as? UIColor
        #expect(sepiaInk == BookReaderTheme.sepia.fixedColors?.ink, "the sepia heading is \(String(describing: sepiaInk))")
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

    /// The lines `text` lays out into in a container of `size`: each line's used
    /// width and the band it occupies.
    private func pageLines(
        _ text: NSAttributedString,
        size: CGSize
    ) -> [(width: CGFloat, minY: CGFloat, maxY: CGFloat)] {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        var lines: [(width: CGFloat, minY: CGFloat, maxY: CGFloat)] = []
        var glyph = 0
        while glyph < layoutManager.numberOfGlyphs {
            var lineGlyphs = NSRange(location: 0, length: 0)
            let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            lines.append((rect.width, rect.minY, rect.maxY))
            glyph = max(NSMaxRange(lineGlyphs), glyph + 1)
        }
        return lines
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
