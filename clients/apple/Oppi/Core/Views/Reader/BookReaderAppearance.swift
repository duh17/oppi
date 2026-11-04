import UIKit

// MARK: - Themes

/// A book's paper. `original` keeps the app's reader colours (the selected app
/// theme); the rest are fixed reading papers, each checked to hold WCAG AA
/// contrast (≥ 4.5:1) between ink and paper.
enum BookReaderTheme: String, Codable, CaseIterable, Equatable {
    case original
    case sepia
    case gray
    case dark

    var displayName: String {
        switch self {
        case .original: return String(localized: "Original")
        case .sepia: return String(localized: "Sepia")
        case .gray: return String(localized: "Gray")
        case .dark: return String(localized: "Dark")
        }
    }

    /// Paper and ink for the fixed themes. Nil for `original`, which reads the
    /// app's palette instead.
    var fixedColors: BookThemeColors? {
        switch self {
        // Warm paper with dark brown ink: 11.7:1, secondary 5.9:1.
        case .sepia:
            return BookThemeColors(
                paper: UIColor(hex: 0xF8F1E3),
                ink: UIColor(hex: 0x3B2E23),
                secondaryInk: UIColor(hex: 0x6B5A48),
                link: UIColor(hex: 0x7A4A12),
                codeFill: UIColor(hex: 0xEFE4CE)
            )
        // Mid-dark slate with light ink: 11.3:1, secondary 6.4:1.
        case .gray:
            return BookThemeColors(
                paper: UIColor(hex: 0x303030),
                ink: UIColor(hex: 0xEDEDED),
                secondaryInk: UIColor(hex: 0xB4B4B4),
                link: UIColor(hex: 0x8FC0FF),
                codeFill: UIColor(hex: 0x3C3C3C)
            )
        // True black with soft white ink: 17.1:1, secondary 9.6:1.
        case .dark:
            return BookThemeColors(
                paper: UIColor(hex: 0x000000),
                ink: UIColor(hex: 0xE8E8E8),
                secondaryInk: UIColor(hex: 0xAFAFAF),
                link: UIColor(hex: 0x7FB4FF),
                codeFill: UIColor(hex: 0x171717)
            )
        case .original:
            return nil
        }
    }
}

/// One fixed theme's colours.
struct BookThemeColors: Equatable {
    let paper: UIColor
    let ink: UIColor
    let secondaryInk: UIColor
    let link: UIColor
    let codeFill: UIColor
}

// MARK: - Type

enum BookFontFamily: String, Codable, CaseIterable, Equatable {
    /// New York, Apple's serif. Books' own default.
    case newYork
    case system
    case georgia
    case palatino

    var displayName: String {
        switch self {
        case .newYork: return String(localized: "New York")
        case .system: return String(localized: "System")
        case .georgia: return String(localized: "Georgia")
        case .palatino: return String(localized: "Palatino")
        }
    }

    /// The family at `size`. A named face that this device does not ship falls
    /// back to New York, then to the system font, so a page always draws.
    func font(size: CGFloat, weight: UIFont.Weight, italic: Bool) -> UIFont {
        switch self {
        case .system:
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard italic,
                  let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic)
            else { return base }
            return UIFont(descriptor: descriptor, size: size)
        case .newYork:
            return Self.serif(size: size, weight: weight, italic: italic)
        case .georgia:
            return Self.named(
                ["Georgia", "Georgia-Bold", "Georgia-Italic", "Georgia-BoldItalic"],
                bold: weight >= .semibold,
                italic: italic,
                size: size
            ) ?? Self.serif(size: size, weight: weight, italic: italic)
        case .palatino:
            return Self.named(
                ["Palatino-Roman", "Palatino-Bold", "Palatino-Italic", "Palatino-BoldItalic"],
                bold: weight >= .semibold,
                italic: italic,
                size: size
            ) ?? Self.serif(size: size, weight: weight, italic: italic)
        }
    }

    /// New York: the system font with the serif design.
    static func serif(size: CGFloat, weight: UIFont.Weight, italic: Bool) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard var descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        if italic, let italicized = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            descriptor = italicized
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func named(
        _ postScriptNames: [String],
        bold: Bool,
        italic: Bool,
        size: CGFloat
    ) -> UIFont? {
        // Roman, bold, italic, bold italic.
        let index = bold ? (italic ? 3 : 1) : (italic ? 2 : 0)
        for name in [postScriptNames[index], postScriptNames[0], "Georgia", "Palatino-Roman"] {
            if let font = UIFont(name: name, size: size) { return font }
        }
        return nil
    }
}

enum BookLineSpacing: String, Codable, CaseIterable, Equatable {
    case compact
    case normal
    case relaxed

    var displayName: String {
        switch self {
        case .compact: return String(localized: "Compact")
        case .normal: return String(localized: "Normal")
        case .relaxed: return String(localized: "Relaxed")
        }
    }

    var lineHeightMultiple: CGFloat {
        switch self {
        case .compact: return 1.25
        case .normal: return 1.4
        case .relaxed: return 1.6
        }
    }
}

enum BookMargins: String, Codable, CaseIterable, Equatable {
    case narrow
    case normal
    case wide

    var displayName: String {
        switch self {
        case .narrow: return String(localized: "Narrow")
        case .normal: return String(localized: "Normal")
        case .wide: return String(localized: "Wide")
        }
    }

    /// Side margin in points at phone width. Wide screens keep this as the
    /// floor and add measure limiting on top.
    var sideInset: CGFloat {
        switch self {
        case .narrow: return 16
        case .normal: return 24
        case .wide: return 36
        }
    }
}

enum BookReadingLayout: String, Codable, CaseIterable, Equatable {
    case pages
    case scrolling

    var displayName: String {
        switch self {
        case .pages: return String(localized: "Pages")
        case .scrolling: return String(localized: "Scrolling")
        }
    }
}

// MARK: - Text roles

/// The kinds of book text a renderer asks typography for.
enum BookTextRole: String, Codable, CaseIterable, Equatable {
    case body
    case heading1
    case heading2
    case heading3
    case blockquote
    case code
    case listItem
    case caption

    /// Role size as a multiple of the body size.
    var sizeMultiplier: CGFloat {
        switch self {
        case .body, .listItem: return 1.0
        case .heading1: return 1.55
        case .heading2: return 1.3
        case .heading3: return 1.12
        case .blockquote: return 1.0
        case .code: return 0.86
        case .caption: return 0.8
        }
    }

    var weight: UIFont.Weight {
        switch self {
        case .heading1: return .bold
        case .heading2, .heading3: return .semibold
        case .body, .blockquote, .code, .listItem, .caption: return .regular
        }
    }

    /// Code keeps the monospaced family, whatever the book's typeface is.
    var isMonospaced: Bool { self == .code }

    /// Space above the role, in ems of the body size.
    var spaceBefore: CGFloat {
        switch self {
        case .heading1: return 1.4
        case .heading2: return 1.1
        case .heading3: return 0.9
        default: return 0
        }
    }

    /// Space below the role, in ems of the body size.
    var spaceAfter: CGFloat {
        switch self {
        case .heading1, .heading2: return 0.5
        case .heading3: return 0.4
        case .caption: return 0.8
        default: return 0.6
        }
    }

    /// Quote and caption text is set in the secondary ink.
    var usesSecondaryInk: Bool {
        self == .caption
    }
}

// MARK: - Appearance

/// Reading appearance for a book: paper, type, size, spacing and layout.
///
/// Book text is set in the reader's own typography, not the app's chat
/// typography. Everything a book page needs to draw itself comes from here:
/// `attributes(for:)` for text, `pageInsets(for:)` for the measure, and the
/// theme colours for the page behind it. The value is persisted per device by
/// `BookReaderAppearanceStore`, and every renderer that shows book text reads
/// it from there.
///
/// Sizes are expressed against Apple's body text style, so a page still follows
/// Dynamic Type: `sizeStep` moves the reader up or down from the current body
/// size instead of pinning a point size.
struct BookReaderAppearance: Equatable, Codable {
    /// Body size steps the reader offers around Dynamic Type's body size.
    static let sizeStepRange = -2...6
    /// Each step is 10% of the body size.
    static let sizeStepRatio: CGFloat = 1.1
    /// Dynamic Type's body size at the default content size category.
    static let referenceBodyPointSize: CGFloat = 17
    /// Books' own measure: a line never runs much past this many characters.
    static let measureLimit: CGFloat = 68

    var theme: BookReaderTheme
    var fontFamily: BookFontFamily
    var sizeStep: Int
    var lineSpacing: BookLineSpacing
    var margins: BookMargins
    var justified: Bool
    /// Pages is Apple Books; scrolling is the app's chapter scroll view. Stored
    /// here because the reading body reads it.
    var layout: BookReadingLayout

    init(
        theme: BookReaderTheme = .original,
        fontFamily: BookFontFamily = .newYork,
        sizeStep: Int = 1,
        lineSpacing: BookLineSpacing = .normal,
        margins: BookMargins = .normal,
        justified: Bool = true,
        layout: BookReadingLayout = .pages
    ) {
        self.theme = theme
        self.fontFamily = fontFamily
        self.sizeStep = Self.clampedSizeStep(sizeStep)
        self.lineSpacing = lineSpacing
        self.margins = margins
        self.justified = justified
        self.layout = layout
    }

    static func clampedSizeStep(_ step: Int) -> Int {
        min(sizeStepRange.upperBound, max(sizeStepRange.lowerBound, step))
    }

    /// A stored appearance can outlive a build that knew fewer fields, so every
    /// field is optional on decode and clamped on the way in.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(BookReaderTheme.self, forKey: .theme) ?? .original
        fontFamily = try container.decodeIfPresent(BookFontFamily.self, forKey: .fontFamily) ?? .newYork
        sizeStep = Self.clampedSizeStep(try container.decodeIfPresent(Int.self, forKey: .sizeStep) ?? 1)
        lineSpacing = try container.decodeIfPresent(BookLineSpacing.self, forKey: .lineSpacing) ?? .normal
        margins = try container.decodeIfPresent(BookMargins.self, forKey: .margins) ?? .normal
        justified = try container.decodeIfPresent(Bool.self, forKey: .justified) ?? true
        layout = try container.decodeIfPresent(BookReadingLayout.self, forKey: .layout) ?? .pages
    }

    // MARK: Colours

    /// Book ink. `original` answers with the app palette's foreground so the
    /// page matches the reader's chrome.
    @MainActor
    func textColor(in palette: ThemePalette? = nil) -> UIColor {
        theme.fixedColors?.ink ?? (palette ?? BookReaderPalette.current).ui.fg
    }

    /// The paper behind the page. `original` answers with the palette's reader
    /// background, which is what the chapter body already paints.
    @MainActor
    func backgroundColor(in palette: ThemePalette? = nil) -> UIColor {
        theme.fixedColors?.paper ?? (palette ?? BookReaderPalette.current).ui.bgDark
    }

    @MainActor
    func secondaryTextColor(in palette: ThemePalette? = nil) -> UIColor {
        theme.fixedColors?.secondaryInk ?? (palette ?? BookReaderPalette.current).ui.fgDim
    }

    @MainActor
    func linkColor(in palette: ThemePalette? = nil) -> UIColor {
        theme.fixedColors?.link ?? (palette ?? BookReaderPalette.current).ui.mdLink
    }

    @MainActor
    func codeBackgroundColor(in palette: ThemePalette? = nil) -> UIColor {
        theme.fixedColors?.codeFill ?? (palette ?? BookReaderPalette.current).ui.bgHighlight
    }

    // MARK: Type

    /// The body size the appearance asks for, already scaled for Dynamic Type.
    /// `scale` is the reader's own text size, which composes with the book's
    /// size step rather than replacing it.
    @MainActor
    func bodyPointSize(scale: CGFloat = 1, traits: UITraitCollection? = nil) -> CGFloat {
        let stepped = Self.referenceBodyPointSize
            * pow(Self.sizeStepRatio, CGFloat(sizeStep))
            * max(scale, 0.1)
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: stepped, compatibleWith: traits)
    }

    /// The font for a role. `bold` and `italic` carry inline emphasis from the
    /// markdown the role font replaces.
    @MainActor
    func font(
        for role: BookTextRole,
        bold: Bool = false,
        italic: Bool = false,
        scale: CGFloat = 1,
        traits: UITraitCollection? = nil
    ) -> UIFont {
        let size = bodyPointSize(scale: scale, traits: traits) * role.sizeMultiplier
        let weight = bold ? Self.bolder(role.weight) : role.weight
        return role.isMonospaced
            ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : fontFamily.font(size: size, weight: weight, italic: italic)
    }

    /// One role's text attributes: ink, font and paragraph metrics.
    @MainActor
    func attributes(
        for role: BookTextRole,
        scale: CGFloat = 1,
        palette: ThemePalette? = nil,
        traits: UITraitCollection? = nil
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font(for: role, scale: scale, traits: traits),
            .foregroundColor: role.usesSecondaryInk
                ? secondaryTextColor(in: palette)
                : textColor(in: palette),
            .paragraphStyle: paragraphStyle(for: role, scale: scale, traits: traits),
        ]
    }

    /// Paragraph metrics for a role.
    ///
    /// Books separates paragraphs with space and keeps the first line flush:
    /// an indent is only legible when the measure is generous, and a flush first
    /// line survives the narrow columns a phone actually gets. The space below a
    /// paragraph is 0.6 em of body text.
    @MainActor
    func paragraphStyle(
        for role: BookTextRole,
        scale: CGFloat = 1,
        traits: UITraitCollection? = nil
    ) -> NSMutableParagraphStyle {
        let bodySize = bodyPointSize(scale: scale, traits: traits)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineSpacing.lineHeightMultiple
        style.paragraphSpacingBefore = role.spaceBefore * bodySize
        style.paragraphSpacing = role.spaceAfter * bodySize
        style.firstLineHeadIndent = 0
        switch role {
        case .body, .listItem:
            style.alignment = justified ? .justified : .natural
            style.hyphenationFactor = justified ? 1 : 0
        case .heading1, .heading2, .heading3:
            // Headings are set flush left; justifying two words looks wrong.
            style.alignment = .natural
            style.hyphenationFactor = 0
        case .blockquote:
            style.firstLineHeadIndent = bodySize * 1.2
            style.headIndent = bodySize * 1.2
            style.alignment = .natural
            style.hyphenationFactor = 0
        case .code:
            style.lineHeightMultiple = 1.15
            style.alignment = .natural
            style.hyphenationFactor = 0
        case .caption:
            style.alignment = .natural
            style.hyphenationFactor = 0
        }
        return style
    }

    /// The page's text insets: the chosen margin, widened on a screen that
    /// would otherwise run a line past `measureLimit` characters.
    @MainActor
    func pageInsets(
        for width: CGFloat,
        scale: CGFloat = 1,
        traits: UITraitCollection? = nil
    ) -> UIEdgeInsets {
        let side = max(margins.sideInset, measureInset(for: width, scale: scale, traits: traits))
        return UIEdgeInsets(top: 12, left: side, bottom: 32, right: side)
    }

    /// Half the leftover width once the measure cap is taken out.
    @MainActor
    func measureInset(for width: CGFloat, scale: CGFloat = 1, traits: UITraitCollection? = nil) -> CGFloat {
        // A serif body averages about half an em per character.
        let measure = Self.measureLimit * bodyPointSize(scale: scale, traits: traits) * 0.5
        return max(0, (width - measure) / 2)
    }

    private static func bolder(_ weight: UIFont.Weight) -> UIFont.Weight {
        switch weight {
        case .regular: return .semibold
        case .medium: return .semibold
        case .semibold: return .bold
        default: return weight
        }
    }
}

/// The app palette a reader resolves `original` against.
enum BookReaderPalette {
    @MainActor
    static var current: ThemePalette { ThemeRuntimeState.currentThemeID().palette }
}

// MARK: - Store

/// Per-device book appearance. The value is small, so it is cached in memory
/// and written whole to `UserDefaults` when it changes.
@MainActor
final class BookReaderAppearanceStore {
    static let shared = BookReaderAppearanceStore()

    nonisolated static let storageKey = "oppi.bookReaderAppearance"
    /// Posted on the main thread after the store changed.
    nonisolated static let didChangeNotification = Notification.Name("BookReaderAppearanceDidChange")

    private let defaults: UserDefaults
    private var cached: BookReaderAppearance?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var appearance: BookReaderAppearance {
        if let cached { return cached }
        let loaded = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(BookReaderAppearance.self, from: $0) }
            ?? BookReaderAppearance()
        cached = loaded
        return loaded
    }

    func set(_ appearance: BookReaderAppearance) {
        let normalized = BookReaderAppearance(
            theme: appearance.theme,
            fontFamily: appearance.fontFamily,
            sizeStep: appearance.sizeStep,
            lineSpacing: appearance.lineSpacing,
            margins: appearance.margins,
            justified: appearance.justified,
            layout: appearance.layout
        )
        guard normalized != cached ?? self.appearance else { return }
        cached = normalized
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: Self.storageKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Clears the stored value, so the reader falls back to the defaults.
    func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        cached = nil
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

// MARK: - Hex

private extension UIColor {
    /// A colour from 0xRRGGBB, in sRGB.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
