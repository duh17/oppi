import UIKit

/// Everything a paged book draws with: a font per text role, the paragraph
/// shape, the colours, and the margins a page gives its text.
///
/// The paged reader builds one from the reading theme and text size today. The
/// appearance menu will build one from the person's own choices, so pagination
/// and the page views read this value and never a preference directly.
struct BookPageStyle: Equatable {
    /// What a run of the page's text is: the role decides its font, its
    /// paragraph shape, and (for secondary text) its colour.
    enum Role: Hashable {
        case body
        case heading(level: Int)
        case listItem(depth: Int)
        case quote
        case code
        case table
        case caption

        /// Secondary roles are drawn in the quieter colour: a caption, a table
        /// of numbers.
        var isSecondary: Bool {
            switch self {
            case .caption, .table: true
            case .body, .heading, .listItem, .quote, .code: false
            }
        }
    }

    /// Font per role. A role with no entry uses `body`, so a style may name only
    /// what it changes.
    var fonts: [Role: UIFont]
    var textColor: UIColor
    var secondaryTextColor: UIColor
    var backgroundColor: UIColor
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat
    /// The gap above a heading, which separates it from the paragraph before.
    var headingSpacingBefore: CGFloat
    /// Content margins inside a page, before the safe area.
    var pageInsets: UIEdgeInsets
    var textAlignment: NSTextAlignment
    /// 0 disables hyphenation; 1 hyphenates wherever the line breaker wants to.
    var hyphenationFactor: Float

    func font(for role: Role) -> UIFont {
        fonts[role] ?? fonts[.body] ?? .preferredFont(forTextStyle: .body)
    }

    func color(for role: Role) -> UIColor {
        role.isSecondary ? secondaryTextColor : textColor
    }

    /// Today's reading appearance: the reader palette, its text size and
    /// spacing, book-sized margins, and the theme's heading ramp.
    static func readerDefaults(
        palette: ThemePalette,
        textScale: CGFloat = FullScreenReaderPreferences.standardTextScale,
        spacing: FullScreenReaderSpacing = .standard
    ) -> Self {
        let ui = palette.ui
        func scaled(_ font: UIFont) -> UIFont {
            FullScreenCodeTypography.scaledFont(font, scale: textScale)
        }
        var fonts: [Role: UIFont] = [
            .body: scaled(AppFont.messageBody),
            .quote: scaled(AppFont.messageBody),
            .code: scaled(AppFont.monoMedium),
            .table: scaled(AppFont.monoSmall),
            .caption: scaled(UIFont.preferredFont(forTextStyle: .footnote)),
        ]
        for level in 1...6 {
            fonts[.heading(level: level)] = scaled(AppFont.messageHeading(level: level))
        }
        for depth in 0..<4 {
            fonts[.listItem(depth: depth)] = scaled(AppFont.messageBody)
        }
        return Self(
            fonts: fonts,
            textColor: ui.fg,
            secondaryTextColor: ui.fgDim,
            backgroundColor: ui.bgDark,
            lineSpacing: spacing.markdownLineSpacing,
            paragraphSpacing: spacing.markdownStackSpacing,
            headingSpacingBefore: spacing.markdownStackSpacing * 1.5,
            pageInsets: UIEdgeInsets(top: 44, left: 24, bottom: 16, right: 24),
            // A printed page is justified only when the person asks for it; a
            // ragged right edge is the reading default.
            textAlignment: .natural,
            hyphenationFactor: 0
        )
    }

    /// The paragraph shape for one block, with its indents and the spacing that
    /// follows it on the page.
    func paragraphStyle(for role: Role) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = textAlignment
        style.lineSpacing = lineSpacing
        style.hyphenationFactor = hyphenationFactor
        style.paragraphSpacing = paragraphSpacing
        switch role {
        case .body, .caption:
            break
        case .heading:
            style.paragraphSpacingBefore = headingSpacingBefore
            style.paragraphSpacing = paragraphSpacing * 0.5
            style.alignment = .natural
        case .listItem(let depth):
            let indent = Self.listIndent * CGFloat(depth + 1)
            style.firstLineHeadIndent = indent - Self.listIndent
            style.headIndent = indent
            style.paragraphSpacing = paragraphSpacing * 0.35
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.defaultTabInterval = indent
        case .quote:
            style.firstLineHeadIndent = Self.quoteIndent
            style.headIndent = Self.quoteIndent
            style.tailIndent = -Self.quoteIndent
        case .code, .table:
            style.lineSpacing = 2
            style.paragraphSpacing = paragraphSpacing * 0.5
            style.alignment = .natural
        }
        return style
    }

    static let listIndent: CGFloat = 20
    static let quoteIndent: CGFloat = 16
}
