import UIKit

/// Everything a paged book draws its text with, read from the person's reading
/// appearance: a font per text role, the paragraph shape that role is set in,
/// and the paper and ink of the page.
///
/// The paged body builds one from `BookReaderAppearance` and hands it to
/// `BookChapterPaginator`, so a page and the scrolling chapter read the same
/// typography and neither reads a preference directly.
@MainActor
struct BookPageStyle {
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

        /// The reading appearance's own role. A page's heading level 4 and
        /// deeper is set as the smallest heading, because a book page has no
        /// sixth-size heading the person can tell apart.
        var textRole: BookTextRole {
            switch self {
            case .body: .body
            case .heading(let level):
                if level <= 1 { .heading1 } else if level == 2 { .heading2 } else { .heading3 }
            case .listItem: .listItem
            case .quote: .blockquote
            case .code, .table: .code
            case .caption: .caption
            }
        }
    }

    let appearance: BookReaderAppearance
    let palette: ThemePalette
    /// The reader's own text size, which composes with the appearance's step.
    let textScale: CGFloat
    /// The traits the page is drawn in: Dynamic Type's category comes from here.
    let traits: UITraitCollection?

    /// The page's paper, ink and quieter ink.
    var textColor: UIColor { appearance.textColor(in: palette) }
    var secondaryTextColor: UIColor { appearance.secondaryTextColor(in: palette) }
    var backgroundColor: UIColor { appearance.backgroundColor(in: palette) }

    func font(for role: Role) -> UIFont {
        appearance.font(for: role.textRole, scale: textScale, traits: traits)
    }

    /// A run's ink. On `original` the page is the app's own reader paper, and
    /// the scrolling chapter keeps the app's heading colour there: a page that
    /// set the heading in body ink would change colour when the person switched
    /// layouts.
    func color(for role: Role) -> UIColor {
        if case .heading = role, appearance.theme == .original {
            return palette.ui.mdHeading
        }
        return role.isSecondary ? secondaryTextColor : textColor
    }

    /// A link's ink: the paper's own, which `original` answers with the app's.
    var linkColor: UIColor { appearance.linkColor(in: palette) }

    /// One role's text attributes: the appearance's font and paragraph metrics,
    /// with the page's own indents and ink.
    func attributes(for role: Role) -> [NSAttributedString.Key: Any] {
        [
            .font: font(for: role),
            .foregroundColor: color(for: role),
            .paragraphStyle: paragraphStyle(for: role),
        ]
    }

    /// The paragraph shape for one block: the appearance's justification,
    /// hyphenation, line height and paragraph spacing, plus the structure a list
    /// needs to hang its marker (which the appearance does not carry).
    func paragraphStyle(for role: Role) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(appearance.paragraphStyle(for: role.textRole, scale: textScale, traits: traits))
        style.firstLineHeadIndent = 0
        style.tailIndent = 0
        switch role {
        case .body, .caption, .quote:
            break
        case .heading:
            style.alignment = .natural
        case .listItem(let depth):
            let indent = Self.listIndent * CGFloat(depth + 1)
            style.firstLineHeadIndent = indent - Self.listIndent
            style.headIndent = indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.defaultTabInterval = indent
        case .code, .table:
            style.alignment = .natural
        }
        return style
    }

    static let listIndent: CGFloat = 20
}
