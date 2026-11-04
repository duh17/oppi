import Testing
import UIKit
@testable import Oppi

/// The book reader in a real window: a chapter body under the reader's floating
/// chrome, plus the body's own header and footer.
///
/// Every assertion is geometry the person sees: which frames overlap, and where
/// the last line and the footer end up once the chapter is at rest.
@Suite("Book reader layout", .serialized)
@MainActor
struct BookReaderLayoutTests {
    /// A live text-size change re-flows one chapter in place. The rows must come
    /// out as one ordered stack: no row from the old size may stay drawn over the
    /// new layout.
    @Test("a live text-size change leaves one ordered stack of paragraphs")
    func liveTextSizeChangeKeepsParagraphsOrdered() async throws {
        let fixture = try BookReaderFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()

        let standard = fixture.paragraphFrames()
        #expect(standard.count >= 6, "the chapter body drew no paragraphs: \(standard.count)")
        assertRowsAreOrderedAndDisjoint(
            standard,
            stage: "standard text size",
            diagnostics: fixture.chapterHierarchyDump()
        )

        fixture.applyTextScale(FullScreenReaderPreferences.maximumTextScale)
        try await fixture.settle()

        let larger = fixture.paragraphFrames()
        #expect(larger.count >= 6, "the chapter body drew no paragraphs after the change")
        assertRowsAreOrderedAndDisjoint(
            larger,
            stage: "after the live text-size change",
            diagnostics: fixture.chapterHierarchyDump()
        )
        #expect(
            larger.map(\.frame) != standard.map(\.frame),
            "the chapter did not re-flow, so this is not the live text-size path"
        )
    }

    /// The chapter header is body chrome, not reader chrome: it must sit below the
    /// reader's floating close control, at every text size.
    @Test("the chapter header clears the reader's close control at every text size")
    func headerClearsCloseControl() async throws {
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let fixture = try BookReaderFixture(contentSizeCategory: category)
            defer { fixture.tearDown() }
            try await fixture.settle()

            let close = try #require(
                fixture.leadingBarControl(),
                "the reader has no leading bar control: \(fixture.navigationBarDump())"
            )
            let title = try #require(
                fixture.view(identifier: "fullScreen.book.title"),
                "the reader has no chapter header"
            )
            let closeFrame = close.convert(close.bounds, to: fixture.window)
            let titleFrame = title.convert(title.bounds, to: fixture.window)
            #expect(
                !closeFrame.intersects(titleFrame),
                "chapter header \(titleFrame) sits under the close control \(closeFrame) at \(category.rawValue)"
            )
            #expect(
                titleFrame.minY >= closeFrame.maxY - 1,
                "chapter header \(titleFrame) starts above the close control's bottom \(closeFrame.maxY) at \(category.rawValue)"
            )
        }
    }

    /// Scrolled to the end, the chapter's last line must be readable: above the
    /// footer's Previous/Next row and a gap clear of the floating
    /// viewing-options control.
    @Test("the last paragraph clears the footer and the floating control")
    func lastParagraphClearsFooterAndFloatingControl() async throws {
        let fixture = try BookReaderFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()
        fixture.scrollChapterToBottom()
        try await fixture.settle()

        let last = try #require(fixture.lowestParagraphFrame(), "the chapter body drew no paragraphs")
        let footer = try #require(
            fixture.view(identifier: "fullScreen.book.previous"),
            "the reader has no footer"
        )
        let footerFrame = footer.convert(footer.bounds, to: fixture.window)
        #expect(
            last.maxY <= footerFrame.minY + 1,
            "the last paragraph ends at \(last.maxY), under the footer at \(footerFrame.minY)"
        )

        let floating = try #require(
            fixture.view(identifier: "fullscreen.viewingOptions.button"),
            "the reader has no floating control"
        )
        let floatingFrame = floating.convert(floating.bounds, to: fixture.window)
        #expect(
            last.maxY <= floatingFrame.minY - 8,
            "the last paragraph ends at \(last.maxY), inside the 8pt gap above the floating control at \(floatingFrame.minY)"
        )
    }

    /// The reader's floating control is drawn over the foot of the scrolling
    /// body; the footer is in the flow there, so it has to sit above it.
    @Test("the scrolling footer clears the reader's floating control")
    func scrollingFooterClearsFloatingControl() async throws {
        let fixture = try BookReaderFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()

        let next = try #require(fixture.view(identifier: "fullScreen.book.next"), "the reader has no Next")
        let floating = try #require(
            fixture.view(identifier: "fullscreen.viewingOptions.button"),
            "the reader has no floating control"
        )
        let nextFrame = next.convert(next.bounds, to: fixture.window)
        let floatingFrame = floating.convert(floating.bounds, to: fixture.window)
        #expect(
            !nextFrame.intersects(floatingFrame),
            "Next \(nextFrame) is under the floating control \(floatingFrame)"
        )
        #expect(
            nextFrame.maxY <= floatingFrame.minY + 1,
            "Next ends at \(nextFrame.maxY), below the floating control's top \(floatingFrame.minY)"
        )
    }

    /// Previous and Next are one row: their titles share a baseline.
    @Test("Previous and Next share one baseline")
    func footerButtonsShareOneBaseline() async throws {
        let fixture = try BookReaderFixture()
        defer { fixture.tearDown() }
        try await fixture.settle()

        let previous = try #require(fixture.view(identifier: "fullScreen.book.previous"))
        let next = try #require(fixture.view(identifier: "fullScreen.book.next"))
        let previousFrame = previous.convert(previous.bounds, to: fixture.window)
        let nextFrame = next.convert(next.bounds, to: fixture.window)
        #expect(
            abs(previousFrame.minY - nextFrame.minY) <= 1,
            "Previous starts at \(previousFrame.minY) but Next starts at \(nextFrame.minY)"
        )
        #expect(
            abs(previousFrame.height - nextFrame.height) <= 1,
            "Previous is \(previousFrame.height) tall but Next is \(nextFrame.height)"
        )

        let previousBaseline = try #require(baseline(of: previous, in: fixture.window))
        let nextBaseline = try #require(baseline(of: next, in: fixture.window))
        #expect(
            abs(previousBaseline - nextBaseline) <= 1,
            "Previous's title sits on \(previousBaseline) but Next's sits on \(nextBaseline)"
        )
    }

    // MARK: - Assertions

    /// The condition the ghosted screenshot broke: every drawn paragraph has its
    /// own band of the page, in reading order.
    private func assertRowsAreOrderedAndDisjoint(
        _ frames: [(text: String, frame: CGRect)],
        stage: String,
        diagnostics: @autoclosure () -> String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let ordered = frames.sorted { $0.frame.minY < $1.frame.minY }
        var overlaps: [String] = []
        for (above, below) in zip(ordered, ordered.dropFirst()) where above.frame.maxY > below.frame.minY + 0.5 {
            overlaps.append(
                "\"\(above.text)\" ends at \(above.frame.maxY), over \"\(below.text)\" starting at \(below.frame.minY)"
            )
        }
        #expect(
            overlaps.isEmpty,
            "\(stage): \(overlaps)\n\(diagnostics())",
            sourceLocation: sourceLocation
        )
        // Two views drawing one paragraph is the same overlap seen from the data
        // side: a stale row from the old size is still in the body.
        let texts = ordered.map(\.text)
        #expect(
            Set(texts).count == texts.count,
            "\(stage): a paragraph is drawn twice: \(texts)\n\(diagnostics())",
            sourceLocation: sourceLocation
        )
    }

    /// The y a title's glyphs sit on, in `space`.
    private func baseline(of button: UIView, in space: UIView) -> CGFloat? {
        guard let label = timelineAllLabels(in: button).first(where: { !($0.text ?? "").isEmpty }) else {
            return nil
        }
        let frame = label.convert(label.bounds, to: space)
        return frame.minY + label.font.ascender
    }
}

/// One open book in a window, at the size the screenshots were taken.
@MainActor
private final class BookReaderFixture {
    /// 402 × 874 pt: the phone the layout bugs were reported on.
    static let size = CGSize(width: 402, height: 874)

    let window: UIWindow
    let reader: FullScreenCodeViewController
    private let positionKey: String
    /// Reader preferences are a shared store; a test that changes them puts the
    /// previous ones back.
    private let previousPreferences: FullScreenReaderPreferences
    /// This suite lays out the scrolling chapter body; the paged reader has its
    /// own suite. The reading appearance is a device preference, so it is put
    /// back too.
    private let previousAppearance: BookReaderAppearance

    init(contentSizeCategory: UIContentSizeCategory = .large) throws {
        let store = FullScreenReaderPreferencesStore.shared
        previousPreferences = store.preferences(for: .markdown)
        store.resetPreferences(for: .markdown)
        let appearanceStore = BookReaderAppearanceStore.shared
        previousAppearance = appearanceStore.appearance
        var scrolling = appearanceStore.appearance
        scrolling.layout = .scrolling
        appearanceStore.set(scrolling)
        let book = try EPUBBook.open(data: EPUBFixture.epub3(
            title: "A Quiet Book",
            chapterTitles: ["One", "Two", "Three"]
        ))
        positionKey = "book-reader-layout-test|\(UUID().uuidString)"
        let document = EPUBReaderDocument(
            book: book,
            positionKey: positionKey,
            filePath: "books/a-quiet-book.epub",
            title: book.title
        )
        reader = FullScreenCodeViewController.makeHarnessController(
            content: .book(document),
            reviewCommentSelectionContext: nil
        )
        window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        window.rootViewController = reader
        // A phone's home-indicator band: the chrome that floats over the page
        // sits 34pt higher than a window with no safe-area insets would put it,
        // and the chapter has to clear it there.
        reader.additionalSafeAreaInsets.bottom = 34
        window.traitOverrides.preferredContentSizeCategory = contentSizeCategory
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        FullScreenReaderPreferencesStore.shared.setPreferences(previousPreferences, for: .markdown)
        BookReaderAppearanceStore.shared.set(previousAppearance)
        EPUBReadingPositionStore().clear(positionKey)
    }

    /// Runs the layout passes a real reader runs: the body's own layout, the
    /// collection view's, and the main-queue work a re-flow defers.
    func settle() async throws {
        for _ in 0..<12 {
            window.layoutIfNeeded()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.layoutIfNeeded()
    }

    /// The reader's own Viewing Options path: the installed body takes the new
    /// preferences in place.
    func applyTextScale(_ scale: CGFloat) {
        var preferences = FullScreenReaderContentFamily.markdown.defaultPreferences
        preferences.textScale = FullScreenReaderPreferences.clampedTextScale(scale)
        installedBody?.applyReaderPreferences(preferences)
        window.layoutIfNeeded()
    }

    var installedBody: (any ReaderBody)? {
        reader.installedBodyViewForTesting as? any ReaderBody
    }

    /// The chapter body's scroll view: the Markdown body the book installs.
    var chapterScrollView: UIScrollView? {
        chapterBody.flatMap { timelineFirstView(ofType: UIScrollView.self, in: $0) }
    }

    var chapterBody: UIView? {
        view(identifier: "fullScreen.book.body")
    }

    /// Every paragraph the chapter is drawing right now, in the window's space.
    /// `clippedToPage` keeps only the part of a paragraph the body shows, which
    /// is what a person sees; the bottom check wants the whole frame.
    func paragraphFrames(clippedToPage: Bool = true) -> [(text: String, frame: CGRect)] {
        guard let chapterBody else { return [] }
        let contentArea = chapterBody.convert(chapterBody.bounds, to: window)
        return timelineAllTextViews(in: chapterBody)
            .filter { $0.isShown(in: window) && !$0.text.isEmpty }
            .compactMap { textView -> (text: String, frame: CGRect)? in
                let frame = textView.convert(textView.bounds, to: window)
                guard frame.height > 1 else { return nil }
                guard clippedToPage else { return (textView.text, frame) }
                let visible = frame.intersection(contentArea)
                guard !visible.isNull, visible.height > 1 else { return nil }
                return (textView.text, visible)
            }
    }

    func lowestParagraphFrame() -> CGRect? {
        paragraphFrames(clippedToPage: false).map(\.frame).max { $0.maxY < $1.maxY }
    }

    /// Scrolls the chapter to its end, the way a person reads the last line.
    func scrollChapterToBottom() {
        guard let scrollView = chapterScrollView else { return }
        scrollView.layoutIfNeeded()
        let bottom = scrollView.contentSize.height
            - scrollView.bounds.height
            + scrollView.adjustedContentInset.bottom
        scrollView.contentOffset = CGPoint(x: 0, y: max(-scrollView.adjustedContentInset.top, bottom))
        scrollView.layoutIfNeeded()
    }

    func view(identifier: String) -> UIView? {
        timelineAllViews(in: reader.view).first { $0.accessibilityIdentifier == identifier }
    }

    /// The reader's leading bar control: the dismiss chevron in the top leading
    /// corner. A bar button's view carries no accessibility identifier of its
    /// own in-process, so the test takes the leading control in the bar.
    func leadingBarControl() -> UIView? {
        guard let bar = timelineFirstView(ofType: UINavigationBar.self, in: reader.view) else { return nil }
        let controls = timelineAllViews(in: bar).filter {
            $0 is UIControl && !$0.isHidden && $0.bounds.width > 0 && $0.bounds.height > 0
        }
        return controls.min {
            $0.convert($0.bounds, to: window).minX < $1.convert($1.bounds, to: window).minX
        }
    }

    /// Which cell holds which paragraph right now, plus text views that belong
    /// to no cell. A failure message prints this.
    func chapterHierarchyDump() -> String {
        guard let chapterBody, let collection = chapterScrollView as? UICollectionView else {
            return "dump: no chapter body"
        }
        var lines = ["dump: \(collection.visibleCells.count) visible cells, \(collection.subviews.compactMap { $0 as? UICollectionViewCell }.count) cells in the hierarchy, \(collection.numberOfItems(inSection: 0)) items"]
        for view in collection.subviews {
            guard let cell = view as? UICollectionViewCell else { continue }
            let indexPath = collection.indexPath(for: cell)
            let frame = cell.convert(cell.bounds, to: window)
            let texts = timelineAllTextViews(in: cell).map { String($0.text.prefix(28)) }
            let visible = collection.visibleCells.contains(cell)
            lines.append("\(visible ? "visible" : "STALE") cell \(indexPath.map(String.init(describing:)) ?? "?"): \(frame) alpha \(cell.contentView.alpha) \(texts)")
        }
        let orphans = timelineAllTextViews(in: chapterBody).filter { view in
            var ancestor: UIView? = view.superview
            while let current = ancestor, !(current is UICollectionViewCell) {
                ancestor = current.superview
            }
            return ancestor == nil
        }
        for view in orphans {
            lines.append("orphan text: \(view.convert(view.bounds, to: window)) \(String((view.text ?? "").prefix(28)))")
        }
        return lines.joined(separator: "\n")
    }

    func navigationBarDump() -> String {
        guard let bar = timelineFirstView(ofType: UINavigationBar.self, in: reader.view) else {
            return "dump: no navigation bar"
        }
        let lines = timelineAllViews(in: bar).map { view in
            "\(type(of: view)) id=\(view.accessibilityIdentifier ?? "-") label=\(view.accessibilityLabel ?? "-") frame=\(view.convert(view.bounds, to: window))"
        }
        return (["dump: nav bar \(bar.convert(bar.bounds, to: window))"] + lines).joined(separator: "\n")
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
