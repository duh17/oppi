import Testing
import UIKit
@testable import Oppi

/// The "Aa" sheet and the chapter behind it, in a real window: what a person
/// taps, what the store ends up holding, and what the page looks like after.
@Suite("Book reader appearance in the reader")
@MainActor
struct BookReaderAppearanceReaderTests {
    // MARK: - The sheet

    @Test("each control in the Aa sheet writes the store and applies live")
    func controlsWriteTheStore() async throws {
        let fixture = try ReaderFixture(appearance: BookReaderAppearance())
        defer { fixture.tearDown() }
        try await fixture.settle()

        let menu = try await fixture.presentAppearanceMenu()
        try await fixture.settle()

        let smaller = try #require(fixture.view("fullScreen.book.appearance.sizeDecrease", in: menu.view))
        let larger = try #require(fixture.view("fullScreen.book.appearance.sizeIncrease", in: menu.view))
        let startStep = fixture.store.appearance.sizeStep
        tap(larger)
        #expect(fixture.store.appearance.sizeStep == startStep + 1)
        tap(smaller)
        tap(smaller)
        #expect(fixture.store.appearance.sizeStep == startStep - 1)

        let sepia = try #require(fixture.view("fullScreen.book.appearance.theme.sepia", in: menu.view))
        tap(sepia)
        #expect(fixture.store.appearance.theme == .sepia)

        let georgia = try #require(fixture.view("fullScreen.book.appearance.font.georgia", in: menu.view))
        tap(georgia)
        #expect(fixture.store.appearance.fontFamily == .georgia)

        let spacing = try #require(fixture.view("fullScreen.book.appearance.spacing", in: menu.view) as? UISegmentedControl)
        spacing.selectedSegmentIndex = BookLineSpacing.allCases.firstIndex(of: .compact) ?? 0
        spacing.sendActions(for: .valueChanged)
        #expect(fixture.store.appearance.lineSpacing == .compact)

        let margins = try #require(fixture.view("fullScreen.book.appearance.margins", in: menu.view) as? UISegmentedControl)
        margins.selectedSegmentIndex = BookMargins.allCases.firstIndex(of: .wide) ?? 0
        margins.sendActions(for: .valueChanged)
        #expect(fixture.store.appearance.margins == .wide)

        let layout = try #require(fixture.view("fullScreen.book.appearance.layout", in: menu.view) as? UISegmentedControl)
        layout.selectedSegmentIndex = BookReadingLayout.allCases.firstIndex(of: .scrolling) ?? 1
        layout.sendActions(for: .valueChanged)
        #expect(fixture.store.appearance.layout == .scrolling)

        let justify = try #require(fixture.view("fullScreen.book.appearance.justify", in: menu.view) as? UISwitch)
        let wasJustified = fixture.store.appearance.justified
        justify.isOn = !wasJustified
        justify.sendActions(for: .valueChanged)
        #expect(fixture.store.appearance.justified == !wasJustified)
    }

    @Test("the chosen theme and typeface carry the selected trait for VoiceOver")
    func selectedTraits() async throws {
        var appearance = BookReaderAppearance()
        appearance.theme = .gray
        appearance.fontFamily = .palatino
        let fixture = try ReaderFixture(appearance: appearance)
        defer { fixture.tearDown() }
        try await fixture.settle()

        let menu = try await fixture.presentAppearanceMenu()
        try await fixture.settle()

        for theme in BookReaderTheme.allCases {
            let button = try #require(
                fixture.view("fullScreen.book.appearance.theme.\(theme.rawValue)", in: menu.view) as? UIButton
            )
            #expect(button.accessibilityLabel == theme.displayName)
            #expect(button.accessibilityTraits.contains(.selected) == (theme == .gray))
        }
        for family in BookFontFamily.allCases {
            let button = try #require(
                fixture.view("fullScreen.book.appearance.font.\(family.rawValue)", in: menu.view) as? UIButton
            )
            #expect(button.accessibilityTraits.contains(.selected) == (family == .palatino))
        }

        let spacing = try #require(fixture.view("fullScreen.book.appearance.spacing", in: menu.view) as? UISegmentedControl)
        #expect(spacing.accessibilityLabel == String(localized: "Line Spacing"))
        let margins = try #require(fixture.view("fullScreen.book.appearance.margins", in: menu.view) as? UISegmentedControl)
        #expect(margins.accessibilityLabel == String(localized: "Margins"))
        let layout = try #require(fixture.view("fullScreen.book.appearance.layout", in: menu.view) as? UISegmentedControl)
        #expect(layout.accessibilityLabel == String(localized: "Layout"))
    }

    @Test("at the largest text size on a 320 pt screen every control still draws and stays tappable")
    func accessibilitySizeOnANarrowScreen() async throws {
        let fixture = try ReaderFixture(
            appearance: BookReaderAppearance(),
            size: CGSize(width: 320, height: 568),
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        defer { fixture.tearDown() }
        try await fixture.settle()

        let menu = try await fixture.presentAppearanceMenu()
        try await fixture.settle()

        let scrollView = try #require(fixture.firstView(ofType: UIScrollView.self, in: menu.view))
        let contentHeight = scrollView.contentSize.height
        #expect(contentHeight > 0)

        let controls = fixture.allViews(in: menu.view).compactMap { view -> UIControl? in
            guard let control = view as? UIControl, !(view is UIScrollView), !control.isHidden else { return nil }
            return control
        }
        #expect(controls.count >= 14, "the sheet drew \(controls.count) controls")
        for control in controls {
            let frame = control.convert(control.bounds, to: scrollView)
            #expect(!frame.isNull)
            #expect(frame.width > 0, "\(type(of: control)) has no width")
            #expect(frame.height >= 28, "\(type(of: control)) is \(frame.height) tall")
            #expect(
                frame.maxY <= contentHeight + 1,
                "\(type(of: control)) at \(frame) falls past the sheet's content \(contentHeight)"
            )
            #expect(
                frame.maxX <= scrollView.bounds.width + 1,
                "\(type(of: control)) at \(frame) runs past the \(scrollView.bounds.width) pt sheet"
            )
        }
        #expect(menu.view.bounds.height <= 568, "the sheet covered the whole \(menu.view.bounds) page")
    }

    // MARK: - The page

    /// The page is set in the chosen paper and typeface, and a theme change
    /// re-sets it without reopening the book.
    @Test("the page takes the chosen paper and serif type, and re-sets when the theme changes")
    func chapterTakesTheAppearance() async throws {
        var appearance = BookReaderAppearance()
        appearance.theme = .sepia
        let fixture = try ReaderFixture(appearance: appearance)
        defer { fixture.tearDown() }
        try await fixture.settle()

        let sepia = try #require(BookReaderTheme.sepia.fixedColors)
        let body = try #require(fixture.body, "the reader installed no book body")
        let paged = try #require(fixture.pagedView, "the reader drew no page view")
        let text = paged.pages.text
        try #require(text.length > 0, "the page holds no text")
        #expect(sameColor(body.backgroundColor, sepia.paper), "body paper \(String(describing: body.backgroundColor))")

        let ink = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(sameColor(ink, sepia.ink), "page ink \(String(describing: ink))")
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(
            font.familyName != UIFont.systemFont(ofSize: font.pointSize).familyName,
            "page text is still the system font: \(font.fontName)"
        )
        fixture.writeScreenshot("epub-books-sepia-page.png")

        // The same page with the chrome back: the header band takes the paper,
        // not the app's dark chrome.
        fixture.pagedView?.onChromeToggle?()
        try await fixture.settle()
        // The chrome fades in over 0.22 s; a capture has to see it at rest.
        try await Task.sleep(for: .milliseconds(300))
        fixture.window.layoutIfNeeded()
        let band = try #require(
            fixture.view("fullScreen.book.headerBand", in: fixture.reader.view),
            "the reader has no header band"
        )
        #expect(sameColor(band.backgroundColor, sepia.paper), "header band \(String(describing: band.backgroundColor))")
        let progress = try #require(fixture.view("fullScreen.book.progress", in: fixture.reader.view))
        #expect(sameColor(progress.backgroundColor, sepia.paper), "progress band \(String(describing: progress.backgroundColor))")
        let title = try #require(fixture.view("fullScreen.book.title", in: fixture.reader.view) as? UILabel)
        #expect(sameColor(title.textColor, sepia.ink), "chapter title ink \(String(describing: title.textColor))")
        fixture.writeScreenshot("epub-books-sepia-chrome.png")

        // Dark paper: the page is set again, in the dark theme's ink.
        var dark = fixture.store.appearance
        dark.theme = .dark
        fixture.store.set(dark)
        try await fixture.settle()

        let darkColors = try #require(BookReaderTheme.dark.fixedColors)
        #expect(sameColor(body.backgroundColor, darkColors.paper))
        let darkText = try #require(fixture.pagedView).pages.text
        let darkInk = darkText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(sameColor(darkInk, darkColors.ink), "page ink after the change \(String(describing: darkInk))")
        fixture.pagedView?.onChromeToggle?()
        try await fixture.settle()
        try await Task.sleep(for: .milliseconds(300))
        fixture.window.layoutIfNeeded()
        fixture.writeScreenshot("epub-books-dark-page.png")
    }

    /// The reader floats its own bar and pills over the page. On a light reading
    /// paper they take that paper and ink, because light glyphs on cream cannot
    /// be read; the theme's own ink holds 11.7:1 on sepia.
    @Test("the reader's floating controls are inked for the page's paper")
    func readerChromeTakesThePaper() async throws {
        var appearance = BookReaderAppearance()
        appearance.theme = .sepia
        let fixture = try ReaderFixture(appearance: appearance)
        defer { fixture.tearDown() }
        try await fixture.settle()

        let sepia = try #require(BookReaderTheme.sepia.fixedColors)
        let options = try #require(
            fixture.view("fullscreen.viewingOptions.button", in: fixture.reader.view) as? UIButton,
            "the reader drew no floating control"
        )
        let pill = try #require(options.configuration)
        #expect(sameColor(pill.baseForegroundColor, sepia.ink), "the pill's glyph is still the app's")
        #expect(
            sameColor(pill.background.backgroundColor, sepia.paper.withAlphaComponent(0.94)),
            "the pill's fill is \(String(describing: pill.background.backgroundColor))"
        )

        // The app's own paper: the chrome goes back to the theme's glass.
        fixture.store.set(BookReaderAppearance())
        try await fixture.settle()
        let restored = try #require(options.configuration)
        #expect(!sameColor(restored.baseForegroundColor, sepia.ink), "the pill stayed on the book's ink")
        #expect(!sameColor(restored.background.backgroundColor, sepia.paper.withAlphaComponent(0.94)))
    }

    /// The sheets a book opens belong to the page it is on: cream paper and the
    /// page's link ink, not a slab of app chrome with a system-green switch.
    @Test("the Aa sheet and the table of contents take the page's paper and ink")
    func sheetsTakeThePageColors() async throws {
        var appearance = BookReaderAppearance()
        appearance.theme = .sepia
        let fixture = try ReaderFixture(appearance: appearance)
        defer { fixture.tearDown() }
        try await fixture.settle()
        try #require(fixture.pagedView, "the reader drew no page view").onChromeToggle?()
        try await fixture.settle()

        let sepia = try #require(BookReaderTheme.sepia.fixedColors)
        let menu = try await fixture.presentAppearanceMenu()
        #expect(
            sameColor(menu.view.backgroundColor, sepia.paper),
            "the Aa sheet is \(String(describing: menu.view.backgroundColor))"
        )
        #expect(menu.overrideUserInterfaceStyle == .light, "the sheet kept the app's dark cast")
        let justify = try #require(
            fixture.view("fullScreen.book.appearance.justify", in: menu.view) as? UISwitch
        )
        #expect(
            sameColor(justify.onTintColor, sepia.link),
            "the justify switch is \(String(describing: justify.onTintColor))"
        )
        menu.dismiss(animated: false)
        try await fixture.settle()

        let tocButton = try #require(
            fixture.view("fullScreen.book.toc", in: fixture.reader.view) as? UIButton
        )
        tocButton.sendActions(for: .touchUpInside)
        try await fixture.settle()
        let sheet = try #require(
            fixture.reader.presentedViewController as? BookTableOfContentsViewController,
            "the table of contents sheet did not open"
        )
        #expect(
            sameColor(sheet.view.backgroundColor, sepia.paper),
            "the table of contents is \(String(describing: sheet.view.backgroundColor))"
        )
    }

    @Test("the Aa control sits beside the table of contents and opens the sheet")
    func appearanceControlOpensTheSheet() async throws {
        let fixture = try ReaderFixture(appearance: BookReaderAppearance())
        defer { fixture.tearDown() }
        try await fixture.settle()

        let toc = try #require(fixture.view("fullScreen.book.toc", in: fixture.reader.view))
        let appearanceButton = try #require(
            fixture.view("fullScreen.book.aa", in: fixture.reader.view) as? UIButton
        )
        #expect(appearanceButton.accessibilityLabel == String(localized: "Appearance"))
        let tocFrame = toc.convert(toc.bounds, to: fixture.window)
        let buttonFrame = appearanceButton.convert(appearanceButton.bounds, to: fixture.window)
        // The book's own order: the chapter name, the table of contents, then Aa.
        #expect(tocFrame.maxX <= buttonFrame.minX)
        #expect(buttonFrame.height >= 44)
        #expect(!tocFrame.intersects(buttonFrame))

        _ = try await fixture.presentAppearanceMenu()
        try await fixture.settle()
    }

    @Test("the appearance sheet's own content, laid out at sheet width, draws every control")
    func appearanceSheetContent() async throws {
        var appearance = BookReaderAppearance()
        appearance.theme = .sepia
        let fixture = try ReaderFixture(appearance: appearance)
        defer { fixture.tearDown() }
        try await fixture.settle()

        // A presented sheet's content belongs to UIKit's presentation window,
        // which a unit-test host never renders; the same content in a plain
        // container is the sheet as it draws.
        let menu = BookReaderAppearanceMenuViewController(store: fixture.store)
        menu.loadViewIfNeeded()
        let size = CGSize(width: 402, height: 700)
        menu.view.frame = CGRect(origin: .zero, size: size)
        menu.view.layoutIfNeeded()

        let container = UIView(frame: CGRect(origin: .zero, size: size))
        container.backgroundColor = .secondarySystemBackground
        container.overrideUserInterfaceStyle = .light
        menu.view.overrideUserInterfaceStyle = .light
        container.addSubview(menu.view)
        let host = UIWindow(frame: CGRect(origin: .zero, size: size))
        host.overrideUserInterfaceStyle = .light
        host.addSubview(container)
        host.isHidden = false
        host.layoutIfNeeded()

        fixture.writeScreenshot(of: container, named: "epub-aa-menu.png")

        let scrollView = try #require(fixture.firstView(ofType: UIScrollView.self, in: menu.view))
        #expect(scrollView.contentSize.height > 0)
    }

    // MARK: - Helpers

    private func tap(_ view: UIView) {
        (view as? UIControl)?.sendActions(for: .touchUpInside)
    }

    private func sameColor(_ first: UIColor?, _ second: UIColor?) -> Bool {
        guard let first, let second else { return false }
        var firstRed: CGFloat = 0
        var firstGreen: CGFloat = 0
        var firstBlue: CGFloat = 0
        var firstAlpha: CGFloat = 0
        var secondRed: CGFloat = 0
        var secondGreen: CGFloat = 0
        var secondBlue: CGFloat = 0
        var secondAlpha: CGFloat = 0
        guard first.getRed(&firstRed, green: &firstGreen, blue: &firstBlue, alpha: &firstAlpha),
              second.getRed(&secondRed, green: &secondGreen, blue: &secondBlue, alpha: &secondAlpha)
        else { return false }
        let tolerance: CGFloat = 0.01
        return abs(firstRed - secondRed) < tolerance
            && abs(firstGreen - secondGreen) < tolerance
            && abs(firstBlue - secondBlue) < tolerance
            && abs(firstAlpha - secondAlpha) < tolerance
    }
}

// MARK: - Fixture

/// A book reader in a real window. It drives the reader's own appearance store
/// (which is what the Aa sheet writes) and puts the device's value back after.
@MainActor
private final class ReaderFixture {
    let window: UIWindow
    let reader: FullScreenCodeViewController
    let store = BookReaderAppearanceStore.shared
    private let previousAppearance: BookReaderAppearance
    private let positionKey: String

    init(
        appearance: BookReaderAppearance,
        size: CGSize = CGSize(width: 402, height: 874),
        contentSizeCategory: UIContentSizeCategory = .large
    ) throws {
        previousAppearance = store.appearance
        store.set(appearance)

        let book = try EPUBBook.open(data: EPUBFixture.epub3(
            title: "A Quiet Book",
            chapterTitles: ["One", "Two", "Three"]
        ))
        positionKey = "book-appearance-reader|\(UUID().uuidString)"
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
        window = Self.makeWindow(size: size)
        window.rootViewController = reader
        window.traitOverrides.preferredContentSizeCategory = contentSizeCategory
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        store.set(previousAppearance)
        EPUBReadingPositionStore().clear(positionKey)
    }

    /// A window on the host app's scene. Text is only drawn for a window that
    /// has a screen, so the screenshot path needs a scene even though the
    /// layout assertions do not.
    private static func makeWindow(size: CGSize) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window: UIWindow = if let scene {
            UIWindow(windowScene: scene)
        } else {
            UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.frame = CGRect(origin: .zero, size: size)
        return window
    }

    func settle() async throws {
        for _ in 0..<10 {
            window.layoutIfNeeded()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.layoutIfNeeded()
    }

    var body: BookReaderBody? {
        reader.installedBodyViewForTesting as? BookReaderBody
    }

    var pagedView: BookPagedView? {
        view("fullScreen.book.pages", in: reader.view) as? BookPagedView
    }

    /// Taps the reader's Aa control and waits for its sheet to be on screen and
    /// at rest, so a capture is of the settled sheet and not of the transition.
    func presentAppearanceMenu() async throws -> BookReaderAppearanceMenuViewController {
        let button = try #require(view("fullScreen.book.aa", in: reader.view) as? UIButton)
        button.sendActions(for: .touchUpInside)
        for _ in 0..<40 {
            if let menu = reader.presentedViewController as? BookReaderAppearanceMenuViewController,
               menu.view.window != nil,
               menu.view.bounds.height > 0 {
                try await Task.sleep(for: .milliseconds(700))
                window.layoutIfNeeded()
                return menu
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
            window.layoutIfNeeded()
        }
        throw AppearanceMenuError.neverPresented(reader.presentedViewController.map { String(describing: type(of: $0)) })
    }

    func view(_ identifier: String, in root: UIView) -> UIView? {
        allViews(in: root).first { $0.accessibilityIdentifier == identifier }
    }

    func allViews(in root: UIView) -> [UIView] {
        timelineAllViews(in: root)
    }

    func firstView<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
        timelineFirstView(ofType: T.self, in: root)
    }

    // MARK: Screenshots

    enum AppearanceMenuError: Error {
        case neverPresented(String?)
    }

    private var screenshotsDirectory: URL {
        URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
    }

    /// PNGs for the build report. A reader test never fails over a screenshot.
    func writeScreenshot(_ name: String) {
        writeScreenshot(of: window, named: name)
    }

    func writeScreenshot(of view: UIView, named name: String) {
        guard let data = renderedPNG(of: view) else { return }
        try? FileManager.default.createDirectory(
            at: screenshotsDirectory,
            withIntermediateDirectories: true
        )
        try? data.write(to: screenshotsDirectory.appendingPathComponent(name))
    }

    private func renderedPNG(of view: UIView) -> Data? {
        view.layoutIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { context in
            if view.window?.windowScene == nil {
                // No screen to draw from: layer contents are all this can get.
                view.layer.render(in: context.cgContext)
            } else {
                // Already on screen, so the backing stores hold the settled
                // text; asking for a new screen update mid-transition would
                // capture the sheet while UIKit is still animating it.
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
            }
        }
        return image.pngData()
    }
}
