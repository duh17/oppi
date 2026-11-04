import Testing
import UIKit
@testable import Oppi

/// The paged book reader in a real window: pages instead of a scrolling column,
/// the chrome out of the way until a tap in the middle of the page, a quiet
/// progress line, and a table of contents sheet.
@Suite("Book paged reader", .serialized)
@MainActor
struct BookPagedReaderTests {
    /// A phone's size: the one the reader's page geometry was built for.
    private static let size = CGSize(width: 402, height: 874)

    @Test("a book opens as pages, with the chrome out of the way")
    func opensAsPages() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()

        #expect(fixture.body.isPaged, "the book did not open as pages")
        let pages = try #require(fixture.pagedView, "the reader drew no page view")
        #expect(pages.isShown(in: fixture.window), "the page view is not on screen")
        #expect(pages.pageCount > 1, "the chapter is one page, so paging proves nothing")
        #expect(pages.pageIndex == 0)
        #expect(
            fixture.view(identifier: "fullScreen.book.previous")?.isShown(in: fixture.window) != true,
            "the scrolling footer is still in the paged reader"
        )
        #expect(
            !fixture.chromeIsVisible,
            "the chrome is showing while the person is reading"
        )
        #expect(
            !fixture.readerChromeIsVisible,
            "the reader's own controls are still over the page while reading"
        )
    }

    /// The floating header shares the top band with the reader's bar: its
    /// controls must not sit under the bar's items, or neither can be tapped.
    @Test("the floating header clears the reader's bar")
    func headerClearsTheReaderBar() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()
        fixture.pagedView?.onChromeToggle?()
        try await fixture.settle()

        let header = try #require(fixture.view(identifier: "fullScreen.book.toc"))
        let bar = try #require(timelineFirstView(ofType: UINavigationBar.self, in: fixture.window))
        let headerFrame = header.convert(header.bounds, to: fixture.window)
        let barFrame = bar.convert(bar.bounds, to: fixture.window)
        #expect(
            headerFrame.minY >= barFrame.maxY - 1,
            "the table of contents \(headerFrame) sits under the reader's bar \(barFrame); safe area \(fixture.body.safeAreaInsets)"
        )
    }

    @Test("the progress line names the page and the time left")
    func progressLineReads() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()

        let progress = try #require(fixture.view(identifier: "fullScreen.book.progress"))
        let label = try #require(progress.accessibilityLabel)
        let count = try #require(fixture.pagedView?.pageCount)
        #expect(label.contains("Page 1 of \(count)"), "the progress line says \"\(label)\"")
        #expect(label.contains("left in chapter"), "the progress line says \"\(label)\"")

        // A page turn moves the line; the whole page is one VoiceOver stop.
        fixture.pagedView?.accessibilityScroll(.left)
        try await fixture.settle()
        #expect(
            progress.accessibilityLabel?.contains("Page 2 of \(count)") == true,
            "the progress line says \"\(progress.accessibilityLabel ?? "nil")\" after a page turn"
        )
        #expect(progress.isAccessibilityElement)
    }

    @Test("a turn past the first page goes back a chapter, and forward again")
    func chapterCrossing() async throws {
        let fixture = try PagedBookFixture(chapter: 1)
        defer { fixture.tearDown() }
        try await fixture.settle()

        // Backwards from the first page: the previous chapter's last page.
        fixture.pagedView?.accessibilityScroll(.right)
        try await fixture.settle()
        #expect(fixture.body.chapterIndex == 0, "a turn before the first page left the chapter alone")
        #expect(fixture.pagedView?.pageIndex == (fixture.pagedView?.pageCount ?? 1) - 1)

        // Forwards past the last page: the next chapter's first page.
        var guardCount = 0
        while fixture.body.chapterIndex == 0, guardCount < 12 {
            fixture.pagedView?.accessibilityScroll(.left)
            try await fixture.settle()
            guardCount += 1
        }
        #expect(
            fixture.body.chapterIndex == 1,
            "turning past the last page of chapter one did not open chapter two"
        )
        #expect(
            fixture.chapterTitle == "Two",
            "the chapter after the first is \(fixture.chapterTitle), not Two"
        )
        #expect(fixture.pagedView?.pageIndex == 0, "the next chapter did not open on its first page")
    }

    @Test("a tap in the middle third shows the chrome, and again hides it")
    func middleTapTogglesChrome() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()
        #expect(!fixture.chromeIsVisible)

        // The gesture's own wiring: the page view asks its body to toggle.
        fixture.pagedView?.onChromeToggle?()
        try await fixture.settle()
        #expect(fixture.chromeIsVisible, "the middle tap did not show the chrome")
        #expect(
            fixture.view(identifier: "fullScreen.book.toc")?.isShown(in: fixture.window) == true,
            "the table of contents control is not on screen with the chrome"
        )

        fixture.pagedView?.onChromeToggle?()
        try await fixture.settle()
        #expect(!fixture.chromeIsVisible, "the second middle tap did not hide the chrome")
    }

    @Test("the page's thirds send a tap to the page or to the chrome")
    func tapZones() {
        let width: CGFloat = 402
        #expect(BookPagedView.tapZone(atX: 10, width: width, isRightToLeft: false) == .previousPage)
        #expect(BookPagedView.tapZone(atX: 390, width: width, isRightToLeft: false) == .nextPage)
        #expect(BookPagedView.tapZone(atX: 201, width: width, isRightToLeft: false) == .chrome)
        // A right-to-left page turns the other way round.
        #expect(BookPagedView.tapZone(atX: 10, width: width, isRightToLeft: true) == .nextPage)
        #expect(BookPagedView.tapZone(atX: 390, width: width, isRightToLeft: true) == .previousPage)
    }

    /// A text-size change re-paginates; the person stays on the words they were
    /// reading, and the page they land on is a page of the new layout.
    @Test("a text-size change keeps the page's first character")
    func textSizeChangeKeepsThePosition() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()

        fixture.pagedView?.accessibilityScroll(.left)
        fixture.pagedView?.accessibilityScroll(.left)
        try await fixture.settle()
        let beforeRanges = try #require(fixture.pagedView?.pages.pageRanges)
        let beforeIndex = try #require(fixture.pagedView?.pageIndex)
        let anchor = try #require(beforeRanges.indices.contains(beforeIndex) ? beforeRanges[beforeIndex].location : nil)

        fixture.applyTextScale(FullScreenReaderPreferences.maximumTextScale)
        try await fixture.settle()

        let pages = try #require(fixture.pagedView?.pages)
        let page = try #require(fixture.pagedView?.pageIndex)
        let range = try #require(pages.pageRanges.indices.contains(page) ? pages.pageRanges[page] : nil)
        #expect(
            range.location <= anchor && anchor < NSMaxRange(range),
            "the first visible character \(anchor) is not on page \(page) (\(range)) after the change: before \(beforeRanges), after \(pages.pageRanges), page \(page), range \(range)"
        )
        #expect(
            pages.pageRanges.count > beforeRanges.count,
            "larger text did not need more pages (\(pages.pageRanges.count) from \(beforeRanges.count))"
        )
    }

    /// The reading theme, the typeface and the text size all re-paginate from
    /// the appearance store; the page the person is on keeps its first word.
    @Test("a theme, typeface or size change re-paginates and keeps the page's first character")
    func appearanceChangesKeepThePage() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()
        fixture.pagedView?.accessibilityScroll(.left)
        fixture.pagedView?.accessibilityScroll(.left)
        try await fixture.settle()
        let anchor = try #require(fixture.firstVisibleCharacter())
        let pagesBefore = try #require(fixture.pagedView?.pageCount)

        var appearance = fixture.appearanceStore.appearance
        appearance.theme = .sepia
        fixture.appearanceStore.set(appearance)
        try await fixture.settle()
        try fixture.expectPageHolds(anchor, "after a theme change")

        appearance.fontFamily = .georgia
        appearance.sizeStep = 4
        fixture.appearanceStore.set(appearance)
        try await fixture.settle()
        try fixture.expectPageHolds(anchor, "after a typeface and size change")
        let pagesAfter = try #require(fixture.pagedView?.pageCount)
        #expect(
            pagesAfter > pagesBefore,
            "larger type did not need more pages (\(pagesAfter) from \(pagesBefore))"
        )
        let font = try #require(
            fixture.pagedView?.pages.text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        )
        #expect(
            font.familyName == UIFont(name: "Georgia", size: font.pointSize)?.familyName ?? font.familyName,
            "the page is not set in Georgia: \(font.fontName)"
        )
    }

    /// Switching Pages → Scrolling from the Aa sheet replaces the page with the
    /// chapter's scroll view, and the words the person was on stay put.
    @Test("the Aa sheet's Scrolling choice switches the body and keeps the position")
    func layoutChoiceSwitchesTheBody() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()
        fixture.pagedView?.accessibilityScroll(.left)
        fixture.pagedView?.accessibilityScroll(.left)
        try await fixture.settle()
        let anchor = try #require(fixture.firstVisibleCharacter())

        fixture.pagedView?.onChromeToggle?()
        try await fixture.settle()
        let menu = try await fixture.presentAppearanceMenu()
        let layout = try #require(
            fixture.view("fullScreen.book.appearance.layout", in: menu.view) as? UISegmentedControl
        )
        layout.selectedSegmentIndex = BookReadingLayout.allCases.firstIndex(of: .scrolling) ?? 1
        layout.sendActions(for: .valueChanged)
        try await fixture.settle()

        #expect(!fixture.body.isPaged, "the sheet's Scrolling choice did not leave the pages")
        #expect(fixture.pagedView?.isShown(in: fixture.window) != true, "the page view is still on screen")
        #expect(
            fixture.view(identifier: "fullScreen.book.body")?.isShown(in: fixture.window) == true,
            "the scrolling chapter did not appear"
        )
        #expect(
            fixture.view(identifier: "fullScreen.book.previous")?.isShown(in: fixture.window) == true,
            "the scrolling footer did not come back"
        )
        // The words the person was reading are on screen in the scrolling chapter.
        let anchorWord = try #require(fixture.word(at: anchor), "the page has no word at \(anchor)")
        #expect(
            fixture.visibleChapterText().contains(anchorWord),
            "the scrolling chapter opened elsewhere: \(anchorWord) is not on screen"
        )

        // And back: the sheet closes on the switch, so ask again.
        let again = try await fixture.presentAppearanceMenu()
        let pagesLayout = try #require(
            fixture.view("fullScreen.book.appearance.layout", in: again.view) as? UISegmentedControl
        )
        pagesLayout.selectedSegmentIndex = BookReadingLayout.allCases.firstIndex(of: .pages) ?? 0
        pagesLayout.sendActions(for: .valueChanged)
        try await fixture.settle()
        #expect(fixture.body.isPaged, "the sheet's Pages choice did not bring the pages back")
        #expect(
            fixture.pageText().contains(anchorWord),
            "the page came back without \(anchorWord): \(fixture.pageText().prefix(120))"
        )
    }

    /// The page does not reserve the chrome's band. While the chrome is shown the
    /// opaque header covers the first lines; the page itself starts at the top,
    /// so with the chrome hidden the text is where the eye expects it.
    @Test("with the chrome hidden the page's text starts at the top of the page")
    func pageTextStartsAtTheTop() async throws {
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let fixture = try PagedBookFixture(contentSizeCategory: category)
            defer { fixture.tearDown() }
            try await fixture.settle()
            #expect(!fixture.chromeIsVisible, "the chrome is showing at \(category.rawValue)")

            let page = try #require(fixture.pagedView)
            let pageFrame = page.convert(page.bounds, to: fixture.window)
            let firstLine = try #require(
                fixture.firstPageTextFrame(),
                "the page drew no text at \(category.rawValue)"
            )
            // The measure's own top inset, not a band's height: a phone would
            // otherwise start its page a sixth of the way down.
            #expect(
                firstLine.minY - pageFrame.minY <= 24,
                "the page's first line starts \(firstLine.minY - pageFrame.minY)pt below the page at \(category.rawValue)"
            )
        }
    }

    /// A landscape page is a short page: reserving the top chrome would take
    /// nearly half of it, so the text area keeps the page it was given.
    @Test("a landscape page keeps its text area")
    func landscapePageKeepsItsTextArea() async throws {
        let fixture = try PagedBookFixture(size: CGSize(width: 874, height: 402))
        defer { fixture.tearDown() }
        try await fixture.settle()

        let page = try #require(fixture.pagedView)
        let pageFrame = page.convert(page.bounds, to: fixture.window)
        let insets = page.contentInsets
        let textHeight = pageFrame.height - insets.top - insets.bottom
        #expect(
            textHeight >= pageFrame.height * 0.7,
            "the text area is \(textHeight) of a \(pageFrame.height)pt landscape page"
        )
        let firstLine = try #require(fixture.firstPageTextFrame(), "the landscape page drew no text")
        #expect(
            firstLine.minY - pageFrame.minY <= 24,
            "the landscape page's first line starts \(firstLine.minY - pageFrame.minY)pt below the page"
        )
    }

    /// The first pagination typesets with the body's own traits. It used to be
    /// laid out with none, which resolves Dynamic Type against whatever context
    /// the layout pass happened to be in.
    @Test("the first page is typeset at the body's text size")
    func firstPaginationUsesTheBodysTraits() async throws {
        let fixture = try PagedBookFixture(contentSizeCategory: .accessibilityLarge)
        defer { fixture.tearDown() }
        try await fixture.settle()

        let pages = try #require(fixture.pagedView?.pages)
        let secondPage = try #require(pages.pageRanges.indices.contains(1) ? pages.pageRanges[1].location : nil)
        let font = try #require(
            pages.text.attribute(.font, at: secondPage, effectiveRange: nil) as? UIFont,
            "the page's text carries no font"
        )
        let scale = FullScreenReaderContentFamily.markdown.defaultPreferences.textScale
        let expected = fixture.appearanceStore.appearance.bodyPointSize(
            scale: scale,
            traits: fixture.window.traitCollection
        )
        #expect(
            abs(font.pointSize - expected) < 0.51,
            "the page is set at \(font.pointSize)pt, not the body's \(expected)pt"
        )
        let standard = fixture.appearanceStore.appearance.bodyPointSize(
            scale: scale,
            traits: UITraitCollection(preferredContentSizeCategory: .large)
        )
        #expect(
            expected > standard,
            "the fixture's text size is not larger than standard, so this proves nothing"
        )
    }

    /// A screen reader turned on beside a page needs the chrome the page hid.
    /// Both owners listen for the status change; with VoiceOver off the same
    /// resolution leaves a reading page alone.
    @Test("a VoiceOver status change re-resolves the reader's chrome")
    func voiceOverStatusChangeReResolvesChrome() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()
        #expect(!fixture.chromeIsVisible)

        NotificationCenter.default.post(
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil
        )
        try await fixture.settle()
        #expect(!fixture.chromeIsVisible, "a reader with no screen reader lost its page")

        // The chrome showing stays showing.
        fixture.pagedView?.activateChromeToggle()
        try await fixture.settle()
        #expect(fixture.chromeIsVisible)
        NotificationCenter.default.post(
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil
        )
        try await fixture.settle()
        #expect(fixture.chromeIsVisible, "the chrome went away beside a screen reader")
    }

    /// What a screen reader can do to a page is what a tap in its middle does.
    @Test("activating the page toggles the chrome")
    func activatingThePageTogglesTheChrome() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()
        #expect(!fixture.chromeIsVisible)

        let cell = try #require(fixture.pageCell, "the reader drew no page to activate")
        #expect(cell.accessibilityActivate(), "the page did not take the activation")
        try await fixture.settle()
        #expect(fixture.chromeIsVisible, "activating the page did not show the chrome")
        #expect(fixture.readerChromeIsVisible, "the reader's own controls stayed away")

        #expect(cell.accessibilityActivate())
        try await fixture.settle()
        #expect(!fixture.chromeIsVisible, "activating the page again did not hide the chrome")
    }

    /// The band is the paper the header sits on: while the chrome is shown the
    /// first lines of the page are under it, not beside it.
    @Test("the header band covers the top of the page while the chrome is shown")
    func headerBandCoversThePage() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()
        fixture.pagedView?.activateChromeToggle()
        try await fixture.settle()

        let band = try #require(
            fixture.view(identifier: "fullScreen.book.headerBand"),
            "the reader has no header band"
        )
        let bandFrame = band.convert(band.bounds, to: fixture.window)
        #expect(bandFrame.height > 40, "the header band is \(bandFrame.height) tall")
        let background = try #require(band.backgroundColor)
        var alpha: CGFloat = 0
        background.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        #expect(alpha >= 0.99, "the header band is see-through (\(alpha))")

        let page = try #require(fixture.pagedView)
        let pageFrame = page.convert(page.bounds, to: fixture.window)
        #expect(bandFrame.intersects(pageFrame), "the header band is not over the page")
        let firstLine = try #require(fixture.firstPageTextFrame(), "the page drew no text")
        #expect(
            firstLine.minY < bandFrame.maxY,
            "the page's text \(firstLine) is not under the header band \(bandFrame)"
        )

        // Hidden chrome takes the band with it, and the first line is readable.
        fixture.pagedView?.activateChromeToggle()
        try await fixture.settle()
        #expect(band.isHidden || band.alpha < 0.01, "the header band stayed over the reading page")
    }

    /// The Aa sheet names the size the page is set in, and a size that makes the
    /// content taller than the sheet's own stop can still be reached.
    @Test("the Aa sheet matches the page's size and reaches every row")
    func appearanceSheetMatchesThePage() async throws {
        let fixture = try PagedBookFixture(contentSizeCategory: .accessibilityLarge)
        defer { fixture.tearDown() }
        try await fixture.settle()
        fixture.pagedView?.activateChromeToggle()
        try await fixture.settle()

        let menu = try await fixture.presentAppearanceMenu()
        let label = try #require(
            fixture.view("fullScreen.book.appearance.sizeValue", in: menu.view) as? UILabel,
            "the sheet has no size label"
        )
        let expected = fixture.appearanceStore.appearance.bodyPointSize(
            scale: FullScreenReaderContentFamily.markdown.defaultPreferences.textScale,
            traits: fixture.window.traitCollection
        )
        #expect(
            label.text == "\(Int(expected.rounded())) pt",
            "the sheet says \(label.text ?? "nil"), the page is set at \(expected)pt"
        )

        // The Justify row is at the bottom of the sheet's content; the sheet must
        // offer a stop that shows it.
        let justify = try #require(
            fixture.view("fullScreen.book.appearance.justify", in: menu.view),
            "the sheet has no justification row"
        )
        let sheet = try #require(menu.sheetPresentationController, "the sheet has no presentation")
        #expect(sheet.detents.count >= 2, "the sheet has only its content-sized stop")
        #expect(
            sheet.detents.contains { $0.identifier == UISheetPresentationController.Detent.Identifier.large },
            "the sheet cannot be raised to show its last row"
        )
        let scroll = try #require(
            timelineFirstView(ofType: UIScrollView.self, in: menu.view),
            "the sheet's content does not scroll"
        )
        let rowFrame = justify.convert(justify.bounds, to: scroll)
        #expect(
            rowFrame.maxY <= scroll.contentSize.height + 1,
            "the justification row \(rowFrame.maxY) is outside the sheet's \(scroll.contentSize.height)pt of content"
        )
    }

    /// Paper alone does not move the type: a theme change re-inks the pages
    /// instead of cutting them again, and the person stays on their page.
    @Test("a theme change re-inks the page without cutting it again")
    func themeChangeReinksThePage() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()
        let before = try #require(fixture.pagedView?.pages)
        let page = try #require(fixture.pagedView?.pageIndex)

        var appearance = fixture.appearanceStore.appearance
        appearance.theme = .sepia
        fixture.appearanceStore.set(appearance)
        try await fixture.settle()

        let after = try #require(fixture.pagedView?.pages)
        #expect(after.pageRanges == before.pageRanges, "the paper change cut the chapter again")
        #expect(fixture.pagedView?.pageIndex == page, "the paper change moved the page")
        let ink = after.text.attribute(
            .foregroundColor,
            at: after.pageRanges[page].location,
            effectiveRange: nil
        ) as? UIColor
        #expect(ink == BookReaderTheme.sepia.fixedColors?.ink, "the page is still inked \(String(describing: ink))")
    }

    /// A position written before the store kept a unit counts points. It still
    /// opens the block it names rather than the chapter's first page.
    @Test("a position saved before the unit opens its block")
    func legacyPositionOpensItsBlock() async throws {
        let document = try PagedBookFixture.document()
        let defaults = UserDefaults.standard
        let original = defaults.data(forKey: EPUBReadingPositionStore.preferenceKey)
        defer {
            if let original {
                defaults.set(original, forKey: EPUBReadingPositionStore.preferenceKey)
            } else {
                defaults.removeObject(forKey: EPUBReadingPositionStore.preferenceKey)
            }
        }
        var entries = original
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        entries[document.positionKey] = [
            "href": document.book.chapters[1].href,
            "block": 5,
            "offset": 30,
            "at": 1_700_000_000,
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: entries),
            forKey: EPUBReadingPositionStore.preferenceKey
        )
        #expect(EPUBReadingPositionStore().position(for: document.positionKey)?.unit == .points)

        let fixture = try PagedBookFixture(document: document)
        defer { fixture.tearDown() }
        try await fixture.settle()

        #expect(fixture.body.chapterIndex == 1, "the stored chapter did not open")
        let pages = try #require(fixture.pagedView?.pages)
        let index = try #require(fixture.pagedView?.pageIndex)
        let range = try #require(pages.pageRanges.indices.contains(index) ? pages.pageRanges[index] : nil)
        let blockStart = try #require(pages.blockStarts.indices.contains(5) ? pages.blockStarts[5] : nil)
        #expect(
            range.location <= blockStart && blockStart < NSMaxRange(range),
            "the page \(range) does not hold block 5, which starts at \(blockStart)"
        )
    }

    @Test("the table of contents sheet marks the chapter on screen")
    func tableOfContentsMarksTheChapter() async throws {
        let fixture = try PagedBookFixture(chapter: 2)
        defer { fixture.tearDown() }
        try await fixture.settle()

        let toc = try #require(fixture.view(identifier: "fullScreen.book.toc") as? UIButton)
        toc.sendActions(for: .touchUpInside)
        try await fixture.settle()

        let sheet = try #require(
            fixture.view(identifier: "fullScreen.book.tocSheet"),
            "the table of contents sheet did not present"
        )
        #expect(fixture.view(identifier: "fullScreen.book.tocSheet.title") != nil, "the sheet has no book title")
        let rows = fixture.tableRows(in: sheet)
        #expect(rows.count == 3, "the sheet lists \(rows.count) chapters, not the book's three")
        let current = rows.first { ($0.accessibilityLabel ?? "").contains("current chapter") }
        #expect(current != nil, "no row is marked current")
        #expect(
            (current?.accessibilityLabel ?? "").hasPrefix("Three"),
            "the marked row is \(current?.accessibilityLabel ?? "none")"
        )
        #expect(current?.accessoryType == .checkmark, "the current chapter has no checkmark")
    }

    @Test("choosing a chapter in the sheet opens its first page")
    func tableOfContentsNavigates() async throws {
        let fixture = try PagedBookFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()

        let toc = try #require(fixture.view(identifier: "fullScreen.book.toc") as? UIButton)
        toc.sendActions(for: .touchUpInside)
        try await fixture.settle()

        let sheet = try #require(fixture.view(identifier: "fullScreen.book.tocSheet"))
        let table = try #require(fixture.tableView(in: sheet))
        let row = try #require(fixture.tableRows(in: sheet).firstIndex { ($0.accessibilityLabel ?? "").hasPrefix("Two") })
        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: row, section: 0))
        try await fixture.settle()

        #expect(fixture.body.chapterIndex == 1, "the sheet's second chapter did not open")
        #expect(fixture.pagedView?.pageIndex == 0, "the chosen chapter did not open on its first page")
        #expect(
            fixture.pagedView?.pages.text.string.contains("Chapter 2 paragraph") == true,
            "the page shows another chapter's words"
        )
    }

    /// Leave and come back: the page, not only the chapter, is remembered.
    @Test("reopening the book lands on the page the person left")
    func reopeningKeepsThePage() async throws {
        let document = try PagedBookFixture.document()
        let first = try PagedBookFixture(document: document)
        try await first.settle()
        let pageCount = try #require(first.pagedView?.pageCount)
        #expect(pageCount > 2, "the chapter is too short to prove a page is kept")
        // Two turns, so the page is not the first one a restore could stumble on.
        for expected in 1...2 {
            first.pagedView?.accessibilityScroll(.left)
            try await first.settle()
            #expect(
                first.pagedView?.pageIndex == expected,
                "page turn \(expected) landed on \(first.pagedView?.pageIndex ?? -1) of \(pageCount)"
            )
        }
        let page = try #require(first.pagedView?.pageIndex)
        let pageText = try #require(first.pagedView?.pageText(page))
        let firstRanges = try #require(first.pagedView?.pages.pageRanges)
        let firstStart = firstRanges[page].location
        // The reader asks the body for its position when it leaves; that write
        // is what the next open restores.
        _ = first.installedBody?.viewportIntent
        let saved = EPUBReadingPositionStore().position(for: document.positionKey)
        first.tearDown()

        let second = try PagedBookFixture(document: document)
        defer { second.tearDown() }
        try await second.settle()
        let secondRanges = try #require(second.pagedView?.pages.pageRanges)
        #expect(
            secondRanges == firstRanges,
            "the same chapter paginated differently after reopening: \(secondRanges.count) pages against \(firstRanges.count)"
        )
        let secondIndex = second.pagedView?.pageIndex ?? -1
        let secondRange = secondRanges.indices.contains(secondIndex) ? secondRanges[secondIndex] : NSRange()
        #expect(
            secondIndex == page,
            "reopening landed on page \(secondIndex) \(secondRanges.indices.contains(secondIndex) ? secondRanges[secondIndex] : NSRange()) of \(secondRanges.count), not \(page); saved \(String(describing: saved)), the page started at \(firstStart)"
        )
        let reopened = try #require(second.pagedView?.pageText(page))
        #expect(reopened.string.hasPrefix(String(pageText.string.prefix(20))))
    }
}

// MARK: - Fixture

/// One paged book in a window, at the size the reader was built for.
@MainActor
private final class PagedBookFixture {
    let window: UIWindow
    let reader: FullScreenCodeViewController
    let document: EPUBReaderDocument
    private let previousPreferences: FullScreenReaderPreferences
    private let previousAppearance: BookReaderAppearance

    static func document() throws -> EPUBReaderDocument {
        let book = try EPUBBook.open(data: EPUBFixture.epub3(paragraphsPerChapter: 40))
        return EPUBReaderDocument(
            book: book,
            positionKey: "book-paged-test|\(UUID().uuidString)",
            filePath: "books/a-quiet-book.epub",
            title: book.title
        )
    }

    init(
        document: EPUBReaderDocument? = nil,
        chapter: Int = 0,
        size: CGSize = CGSize(width: 402, height: 874),
        contentSizeCategory: UIContentSizeCategory = .large
    ) throws {
        let document = try document ?? Self.document()
        self.document = document
        let store = FullScreenReaderPreferencesStore.shared
        previousPreferences = store.preferences(for: .markdown)
        store.resetPreferences(for: .markdown)
        let appearanceStore = BookReaderAppearanceStore.shared
        previousAppearance = appearanceStore.appearance
        appearanceStore.set(BookReaderAppearance())
        if chapter > 0 {
            EPUBReadingPositionStore().save(
                EPUBReadingPosition(
                    chapterHref: document.book.chapters[chapter].href,
                    blockOrdinal: 0,
                    offset: 0,
                    unit: .characters
                ),
                for: document.positionKey
            )
        }

        reader = FullScreenCodeViewController.makeHarnessController(
            content: .book(document),
            reviewCommentSelectionContext: nil
        )
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = reader
        window.traitOverrides.preferredContentSizeCategory = contentSizeCategory
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func tearDown() {
        if let presented = reader.presentedViewController {
            presented.dismiss(animated: false)
        }
        window.isHidden = true
        window.rootViewController = nil
        FullScreenReaderPreferencesStore.shared.setPreferences(previousPreferences, for: .markdown)
        BookReaderAppearanceStore.shared.set(previousAppearance)
    }

    /// Runs the layout passes a real reader runs: the body's own layout, the
    /// page view's, the pagination it defers, and the presentation animations.
    func settle() async throws {
        for _ in 0..<16 {
            window.layoutIfNeeded()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.layoutIfNeeded()
    }

    var body: BookReaderBody {
        guard let body = installedBody as? BookReaderBody else {
            fatalError("the reader installed no book body")
        }
        return body
    }

    var installedBody: (any ReaderBody)? {
        reader.installedBodyViewForTesting as? any ReaderBody
    }

    var pagedView: BookPagedView? {
        view(identifier: "fullScreen.book.pages") as? BookPagedView
    }

    /// The page's drawn text, top first: the first line of the page on screen.
    func firstPageTextFrame() -> CGRect? {
        guard let paged = pagedView else { return nil }
        return timelineAllTextViews(in: paged)
            .filter { !$0.text.isEmpty && $0.isShown(in: window) }
            .map { $0.convert($0.bounds, to: window) }
            .filter { $0.height > 1 }
            .min { $0.minY < $1.minY }
    }

    /// The page the person is reading, as the accessibility element VoiceOver
    /// stops on.
    var pageCell: UIView? {
        guard let paged = pagedView else { return nil }
        return timelineAllViews(in: paged).first {
            $0.accessibilityIdentifier == "fullScreen.book.page" && $0.isShown(in: window)
        }
    }

    var chapterTitle: String {
        document.book.chapters[body.chapterIndex].title
    }

    /// The chrome is the body's header plus the reader's own controls. The header
    /// hides first, so its title is the answer.
    var chromeIsVisible: Bool {
        view(identifier: "fullScreen.book.title")?.isShown(in: window) == true
    }

    /// The reader's bar and its floating pills, which a paged book fades.
    var readerChromeIsVisible: Bool {
        guard let bar = timelineFirstView(ofType: UINavigationBar.self, in: window) else { return false }
        return bar.isShown(in: window)
    }

    func applyTextScale(_ scale: CGFloat) {
        var preferences = FullScreenReaderContentFamily.markdown.defaultPreferences
        preferences.textScale = FullScreenReaderPreferences.clampedTextScale(scale)
        installedBody?.applyReaderPreferences(preferences)
        window.layoutIfNeeded()
    }

    let appearanceStore = BookReaderAppearanceStore.shared

    /// The first character of the page on screen.
    func firstVisibleCharacter() -> Int? {
        guard let paged = pagedView,
              paged.pages.pageRanges.indices.contains(paged.pageIndex) else { return nil }
        return paged.pages.pageRanges[paged.pageIndex].location
    }

    /// The words around `character` on the page: what the person can read there.
    func word(at character: Int) -> String? {
        guard let pages = pagedView?.pages else { return nil }
        let text = pages.text.string as NSString
        guard character >= 0, character < text.length else { return nil }
        let rest = text.substring(from: character)
        let words = rest.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, first.count >= 4 else { return nil }
        return String(first)
    }

    /// The chapter's text as the scrolling body is showing it: every text view
    /// that sits inside the content area.
    func visibleChapterText() -> String {
        guard let chapterBody = view(identifier: "fullScreen.book.body") else { return "" }
        let area = chapterBody.convert(chapterBody.bounds, to: window)
        return timelineAllTextViews(in: chapterBody)
            .filter { text in
                let frame = text.convert(text.bounds, to: window)
                return !text.text.isEmpty && frame.minY >= area.minY - 1 && frame.maxY <= area.maxY + 1
            }
            .map(\.text)
            .joined(separator: "\n")
    }

    /// The words the page on screen shows: what is inside its text area, not the
    /// paragraph it continues past the clip.
    func pageText() -> String {
        guard let paged = pagedView else { return "" }
        return paged.pages.pageLabel(at: paged.pageIndex)
    }

    /// The page on screen holds `character`.
    func expectPageHolds(_ character: Int, _ what: String) throws {
        let paged = try #require(pagedView)
        let page = paged.pageIndex
        let range = try #require(
            paged.pages.pageRanges.indices.contains(page) ? paged.pages.pageRanges[page] : nil
        )
        #expect(
            range.location <= character && character < NSMaxRange(range),
            "the first visible character \(character) is not on page \(page) (\(range)) \(what)"
        )
    }

    /// Taps the Aa control and waits for its sheet to be on screen and at rest.
    func presentAppearanceMenu() async throws -> BookReaderAppearanceMenuViewController {
        let button = try #require(view(identifier: "fullScreen.book.aa") as? UIButton)
        button.sendActions(for: .touchUpInside)
        for _ in 0..<40 {
            if let menu = reader.presentedViewController as? BookReaderAppearanceMenuViewController,
               menu.view.window != nil,
               menu.view.bounds.height > 0 {
                try await Task.sleep(for: .milliseconds(700))
                window.layoutIfNeeded()
                return menu
            }
            try await Task.sleep(for: .milliseconds(25))
            window.layoutIfNeeded()
        }
        throw AppearanceMenuError.neverPresented(
            reader.presentedViewController.map { String(describing: type(of: $0)) }
        )
    }

    enum AppearanceMenuError: Error {
        case neverPresented(String?)
    }

    /// A view by identifier inside one view tree (a presented sheet has its own
    /// window, so `view(identifier:)` cannot see into it).
    func view(_ identifier: String, in root: UIView) -> UIView? {
        timelineAllViews(in: root).first { $0.accessibilityIdentifier == identifier }
    }

    /// A view by identifier, wherever the reader put it: the body's own views
    /// are in the reader, a presented sheet is in the window above it.
    func view(identifier: String) -> UIView? {
        timelineAllViews(in: window).first { $0.accessibilityIdentifier == identifier }
    }

    func tableView(in view: UIView) -> UITableView? {
        timelineFirstView(ofType: UITableView.self, in: view)
    }

    func tableRows(in view: UIView) -> [UITableViewCell] {
        guard let table = tableView(in: view) else { return [] }
        table.layoutIfNeeded()
        return (0..<table.numberOfRows(inSection: 0)).compactMap { row in
            table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: row, section: 0))
        }
    }
}

private extension BookPagedView {
    var pageCount: Int { pages.pageCount }
    func pageText(_ index: Int) -> NSAttributedString {
        NSAttributedString(string: pages.pageLabel(at: index))
    }
}

private extension UIView {
    /// Visible the way the person sees it: on screen, with no hidden or
    /// transparent ancestor.
    func isShown(in window: UIWindow) -> Bool {
        guard self.window === window else { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return false }
            view = current.superview
        }
        return true
    }
}
