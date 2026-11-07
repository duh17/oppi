import UIKit

/// Draws one table cell's inline markdown into an attributed string, for both
/// the clip-mode text and a wrapping-grid cell.
///
/// Cells are monospaced, so bold changes the weight and every style keeps the
/// glyph advance, which keeps the measured column widths and tab stops right.
/// Bold is the bold mono font, `code` takes the inline-code color, italic is a
/// slant, strikethrough a line, and links stay links.
enum TableInlineText {
    /// How enclosing inline markup restyles a cell run.
    struct Traits: OptionSet {
        let rawValue: Int
        static let bold = Traits(rawValue: 1 << 0)
        static let italic = Traits(rawValue: 1 << 1)
        static let strikethrough = Traits(rawValue: 1 << 2)
    }

    /// Append a cell's inline content to the result, rendering links with `.link` attribute.
    static func appendCell(
        _ inlines: [MarkdownInline],
        to result: NSMutableAttributedString,
        font: UIFont,
        defaultColor: UIColor,
        linkColor: UIColor,
        codeColor: UIColor,
        paragraph: NSParagraphStyle
    ) {
        // Fast path: single plain text (most common table cell).
        if inlines.count == 1, case .text(let s) = inlines[0] {
            result.append(NSAttributedString(string: s, attributes: [
                .font: font,
                .foregroundColor: defaultColor,
                .paragraphStyle: paragraph,
            ]))
            return
        }
        for inline in inlines {
            appendInline(
                inline, to: result, font: font,
                defaultColor: defaultColor, linkColor: linkColor, codeColor: codeColor,
                paragraph: paragraph, traits: []
            )
        }
    }

    private static func appendInline(
        _ inline: MarkdownInline,
        to result: NSMutableAttributedString,
        font baseFont: UIFont,
        defaultColor: UIColor,
        linkColor: UIColor,
        codeColor: UIColor,
        paragraph: NSParagraphStyle,
        traits: Traits
    ) {
        let font = traits.contains(.bold) ? AppFont.monoMediumBold : baseFont
        func styled(_ color: UIColor) -> [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if traits.contains(.italic) { attrs[.obliqueness] = 0.2 }
            if traits.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return attrs
        }
        func embedAttributes(_ reference: ResourceReference) -> [NSAttributedString.Key: Any] {
            var attrs = styled(linkColor)
            if let url = ResourceReferenceURL.make(reference) {
                attrs[.link] = url
            } else {
                attrs[.foregroundColor] = defaultColor
            }
            return attrs
        }

        switch inline {
        case .text(let s):
            result.append(NSAttributedString(string: s, attributes: styled(defaultColor)))
        case .link(let children, let destination):
            let text = plainText(from: children)
            var attrs = styled(linkColor)
            if let dest = destination, let url = URL(string: dest), url.scheme != nil {
                attrs[.link] = url
                // File links skip the underline; it breaks around `_` glyphs.
                if !ResourceReferenceURL.isReference(url) {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            result.append(NSAttributedString(string: text, attributes: attrs))
        case .code(let s):
            result.append(NSAttributedString(string: s, attributes: styled(codeColor)))
        case .emphasis(let children):
            appendChildren(
                children, to: result, font: baseFont, defaultColor: defaultColor,
                linkColor: linkColor, codeColor: codeColor, paragraph: paragraph,
                traits: traits.union(.italic)
            )
        case .strong(let children):
            appendChildren(
                children, to: result, font: baseFont, defaultColor: defaultColor,
                linkColor: linkColor, codeColor: codeColor, paragraph: paragraph,
                traits: traits.union(.bold)
            )
        case .strikethrough(let children):
            appendChildren(
                children, to: result, font: baseFont, defaultColor: defaultColor,
                linkColor: linkColor, codeColor: codeColor, paragraph: paragraph,
                traits: traits.union(.strikethrough)
            )
        case .softBreak, .hardBreak:
            result.append(NSAttributedString(string: " ", attributes: [
                .font: font, .paragraphStyle: paragraph,
            ]))
        case .html(let raw):
            result.append(NSAttributedString(string: raw, attributes: styled(defaultColor)))
        case .image(let alt, _):
            if !alt.isEmpty {
                result.append(NSAttributedString(string: "[\(alt)]", attributes: styled(defaultColor)))
            }
        case .videoEmbed(let embed):
            result.append(NSAttributedString(string: embed.displayLabel, attributes: embedAttributes(embed.reference)))
        case .audioEmbed(let embed):
            result.append(NSAttributedString(string: embed.displayLabel, attributes: embedAttributes(embed.reference)))
        case .usdzEmbed(let embed):
            result.append(NSAttributedString(string: embed.displayLabel, attributes: embedAttributes(embed.reference)))
        }
    }

    private static func appendChildren(
        _ children: [MarkdownInline],
        to result: NSMutableAttributedString,
        font: UIFont,
        defaultColor: UIColor,
        linkColor: UIColor,
        codeColor: UIColor,
        paragraph: NSParagraphStyle,
        traits: Traits
    ) {
        for child in children {
            appendInline(
                child, to: result, font: font,
                defaultColor: defaultColor, linkColor: linkColor, codeColor: codeColor,
                paragraph: paragraph, traits: traits
            )
        }
    }
}
