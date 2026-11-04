import Testing
import UIKit
@testable import Oppi

/// The reader's appearance value, its store, and the typography it hands a
/// book page.
@Suite("Book reader appearance")
@MainActor
struct BookReaderAppearanceTests {
    // MARK: - Defaults

    @Test("the default page is New York, one step above body, justified")
    func defaults() {
        let appearance = BookReaderAppearance()
        #expect(appearance.theme == .original)
        #expect(appearance.fontFamily == .newYork)
        #expect(appearance.sizeStep == 1)
        #expect(appearance.lineSpacing == .normal)
        #expect(appearance.margins == .normal)
        #expect(appearance.justified)
        #expect(appearance.layout == .pages)
        // One step above Dynamic Type's body size, still following it.
        let body = appearance.bodyPointSize()
        let plain = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: BookReaderAppearance.referenceBodyPointSize
        )
        #expect(body > plain)
        // `UIFontMetrics` rounds a scaled size to the device's points, so the
        // step is proportional to within a fraction of a point.
        #expect(abs(body / plain - BookReaderAppearance.sizeStepRatio) < 0.01)
    }

    @Test("a size step outside the offered range is clamped")
    func sizeStepClamps() {
        #expect(BookReaderAppearance(sizeStep: 99).sizeStep == 6)
        #expect(BookReaderAppearance(sizeStep: -99).sizeStep == -2)
        #expect(BookReaderAppearance.clampedSizeStep(1) == 1)
    }

    @Test("body text scales with Dynamic Type, not just the step")
    func followsDynamicType() {
        let appearance = BookReaderAppearance()
        let large = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibility = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        #expect(appearance.bodyPointSize(traits: accessibility) > appearance.bodyPointSize(traits: large))
    }

    @Test("the reader's own text size composes with the book's size step")
    func readerScaleComposes() {
        let appearance = BookReaderAppearance()
        let base = appearance.bodyPointSize()
        #expect(appearance.bodyPointSize(scale: 1.3) > base)
        #expect(appearance.bodyPointSize(scale: 0.8) < base)
        // Rounded to device points by `UIFontMetrics`, so sub-point, not exact.
        #expect(abs(appearance.bodyPointSize(scale: 1.3) - base * 1.3) < 0.5)
    }

    // MARK: - Store

    private func makeStore() -> (BookReaderAppearanceStore, UserDefaults, String) {
        let suite = "book-appearance-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return (BookReaderAppearanceStore(defaults: defaults), defaults, suite)
    }

    @Test("an appearance persists across stores and comes back whole")
    func persists() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var appearance = BookReaderAppearance()
        appearance.theme = .sepia
        appearance.fontFamily = .georgia
        appearance.sizeStep = 3
        appearance.lineSpacing = .relaxed
        appearance.margins = .wide
        appearance.justified = false
        appearance.layout = .scrolling

        store.set(appearance)

        let reopened = BookReaderAppearanceStore(defaults: defaults)
        #expect(reopened.appearance == appearance)
    }

    @Test("an unset store answers the defaults")
    func emptyStoreUsesDefaults() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.appearance == BookReaderAppearance())
    }

    @Test("corrupt or partial stored data falls back to the defaults per field")
    func corruptDataFallsBack() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("not json".utf8), forKey: BookReaderAppearanceStore.storageKey)
        #expect(store.appearance == BookReaderAppearance())

        // A partial record keeps what it names and defaults the rest.
        let partial = Data(#"{"theme":"dark","sizeStep":99}"#.utf8)
        defaults.set(partial, forKey: BookReaderAppearanceStore.storageKey)
        let reopened = BookReaderAppearanceStore(defaults: defaults)
        #expect(reopened.appearance.theme == .dark)
        #expect(reopened.appearance.sizeStep == 6)
        #expect(reopened.appearance.fontFamily == .newYork)
        #expect(reopened.appearance.justified)
    }

    @Test("a change posts once, and re-setting the same value posts nothing")
    func changeNotification() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: BookReaderAppearanceStore.didChangeNotification,
            object: store,
            queue: .main
        ) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        var appearance = store.appearance
        appearance.theme = .dark
        store.set(appearance)
        store.set(store.appearance)
        await Task.yield()
        #expect(changes == 1)
        #expect(store.appearance.theme == .dark)
    }

    @Test("reset clears the stored appearance")
    func reset() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var appearance = BookReaderAppearance()
        appearance.theme = .gray
        store.set(appearance)
        store.reset()
        #expect(store.appearance == BookReaderAppearance())
    }

    // MARK: - Contrast

    /// WCAG 2.1 relative luminance and contrast, computed from the colours the
    /// page actually draws.
    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func channel(_ value: CGFloat) -> CGFloat {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }
        let firstLuminance = luminance(first)
        let secondLuminance = luminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    @Test("every reading paper holds WCAG AA contrast in its ink, secondary ink and links")
    func themeContrast() throws {
        for theme in [BookReaderTheme.sepia, .gray, .dark] {
            let colors = try #require(theme.fixedColors, "\(theme) has no fixed colours")
            #expect(contrastRatio(colors.ink, colors.paper) >= 4.5, "\(theme) body ink")
            #expect(contrastRatio(colors.secondaryInk, colors.paper) >= 4.5, "\(theme) secondary ink")
            #expect(contrastRatio(colors.link, colors.paper) >= 4.5, "\(theme) link ink")
            #expect(contrastRatio(colors.ink, colors.codeFill) >= 4.5, "\(theme) ink on code fill")
        }
    }

    // MARK: - Attributes

    @Test("each role's attributes carry a font, an ink and paragraph metrics")
    func attributesPerRole() throws {
        var appearance = BookReaderAppearance()
        appearance.theme = .sepia

        for role in BookTextRole.allCases {
            let attributes = appearance.attributes(for: role)
            let font = try #require(attributes[.font] as? UIFont, "\(role) has no font")
            let ink = try #require(attributes[.foregroundColor] as? UIColor, "\(role) has no ink")
            let style = try #require(attributes[.paragraphStyle] as? NSParagraphStyle, "\(role) has no style")
            #expect(font.pointSize > 0)
            #expect(ink == appearance.textColor() || ink == appearance.secondaryTextColor())
            #expect(style.lineHeightMultiple > 0)
            #expect(style.firstLineHeadIndent == 0 || role == .blockquote)
        }
    }

    @Test("the roles form a reading hierarchy: headings above body, captions and code below")
    func roleHierarchy() {
        let appearance = BookReaderAppearance()
        func size(_ role: BookTextRole) -> CGFloat { appearance.font(for: role).pointSize }
        #expect(size(.heading1) > size(.heading2))
        #expect(size(.heading2) > size(.heading3))
        #expect(size(.heading3) > size(.body))
        #expect(size(.body) > size(.code))
        #expect(size(.code) > size(.caption))
        #expect(size(.body) == size(.listItem))
    }

    @Test("body text is serif, code is monospaced")
    func families() throws {
        let appearance = BookReaderAppearance()
        let body = appearance.font(for: .body)
        #expect(!body.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #expect(body.familyName != UIFont.systemFont(ofSize: 17).familyName)
        #expect(appearance.font(for: .code).fontDescriptor.symbolicTraits.contains(.traitMonoSpace))

        var georgia = appearance
        georgia.fontFamily = .georgia
        #expect(georgia.font(for: .body).familyName.lowercased().contains("georgia"))

        var palatino = appearance
        palatino.fontFamily = .palatino
        #expect(palatino.font(for: .body).familyName.lowercased().contains("palatino"))
    }

    @Test("justified body paragraphs hyphenate, and switching justification off stops both")
    func justification() throws {
        var appearance = BookReaderAppearance()
        let justified = appearance.paragraphStyle(for: .body)
        #expect(justified.alignment == .justified)
        #expect(justified.hyphenationFactor == 1)

        appearance.justified = false
        let ragged = appearance.paragraphStyle(for: .body)
        #expect(ragged.alignment == .natural)
        #expect(ragged.hyphenationFactor == 0)
    }

    @Test("paragraphs are separated by space, never by a first-line indent")
    func paragraphSpacing() {
        let appearance = BookReaderAppearance()
        let body = appearance.paragraphStyle(for: .body)
        #expect(body.firstLineHeadIndent == 0)
        #expect(body.paragraphSpacing > 0)
        // About 0.6 em of the body text.
        #expect(abs(body.paragraphSpacing / appearance.bodyPointSize() - 0.6) < 0.01)
        #expect(appearance.paragraphStyle(for: .heading1).paragraphSpacingBefore > 0)
    }

    @Test("line spacing follows the setting and the body font is line height ~1.4")
    func lineSpacing() {
        var appearance = BookReaderAppearance()
        #expect(appearance.paragraphStyle(for: .body).lineHeightMultiple == 1.4)
        appearance.lineSpacing = .compact
        #expect(appearance.paragraphStyle(for: .body).lineHeightMultiple == 1.25)
        appearance.lineSpacing = .relaxed
        #expect(appearance.paragraphStyle(for: .body).lineHeightMultiple == 1.6)
    }

    @Test("margins are comfortable on a phone and cap the measure on a wide page")
    func margins() {
        let appearance = BookReaderAppearance()
        let phone = appearance.pageInsets(for: 402)
        #expect(phone.left == 24)
        #expect(phone.right == 24)

        var wide = appearance
        wide.margins = .wide
        #expect(wide.pageInsets(for: 402).left == 36)

        // An iPad page gets margins wide enough to keep a readable measure.
        let tablet = appearance.pageInsets(for: 1024)
        #expect(tablet.left > 24)
        let measure = 1024 - tablet.left - tablet.right
        #expect(measure <= 68 * appearance.bodyPointSize() * 0.5 + 0.5)
    }

    @Test("a themed page reports its own paper, and original keeps the app's")
    func pageColours() {
        let palette = ThemePalettes.dark
        var appearance = BookReaderAppearance()
        #expect(appearance.backgroundColor(in: palette) == palette.ui.bgDark)
        #expect(appearance.textColor(in: palette) == palette.ui.fg)

        appearance.theme = .sepia
        let sepia = appearance.theme.fixedColors
        #expect(appearance.backgroundColor(in: palette) == sepia?.paper)
        #expect(appearance.textColor(in: palette) == sepia?.ink)
    }
}
