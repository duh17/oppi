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
    private let previousMode: BookReaderPageMode

    static func document() throws -> EPUBReaderDocument {
        let book = try EPUBBook.open(data: EPUBFixture.epub3(paragraphsPerChapter: 40))
        return EPUBReaderDocument(
            book: book,
            positionKey: "book-paged-test|\(UUID().uuidString)",
            filePath: "books/a-quiet-book.epub",
            title: book.title
        )
    }

    init(document: EPUBReaderDocument? = nil, chapter: Int = 0) throws {
        let document = try document ?? Self.document()
        self.document = document
        let store = FullScreenReaderPreferencesStore.shared
        previousPreferences = store.preferences(for: .markdown)
        store.resetPreferences(for: .markdown)
        var modeStore = BookReaderPageModeStore()
        previousMode = modeStore.mode
        modeStore.mode = .pages
        if chapter > 0 {
            EPUBReadingPositionStore().save(
                EPUBReadingPosition(
                    chapterHref: document.book.chapters[chapter].href,
                    blockOrdinal: 0,
                    offsetPoints: 0
                ),
                for: document.positionKey
            )
        }

        reader = FullScreenCodeViewController.makeHarnessController(
            content: .book(document),
            reviewCommentSelectionContext: nil
        )
        window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 402, height: 874)))
        window.rootViewController = reader
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
        var modeStore = BookReaderPageModeStore()
        modeStore.mode = previousMode
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
    func pageText(_ index: Int) -> NSAttributedString { text(forPage: index) }
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
