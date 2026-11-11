import CoreText
import UIKit

/// Draws one table cell's inline markdown into an attributed string, for both
/// the clip-mode text and a wrapping-grid cell, and measures it for the planner.
///
/// Cells read in the message body font, as the paragraphs around the table do,
/// so they follow Dynamic Type and Message Text Size. Inline `code` keeps the
/// paragraphs' inline-code style: the code font, color, and background. Headers
/// and bold are the bold body face, italic the italic face, strikethrough a
/// line, and links stay links. Nothing needs a fixed advance: columns are
/// measured from the text as drawn, and clip text aligns them with tab stops.
enum TableInlineText {
    /// The faces a table draws its cells in, from `AppFont`'s message roles.
    struct Fonts: Equatable, @unchecked Sendable {
        let body: UIFont
        let bold: UIFont
        /// Nil when the body family has no italic face: italic is slanted.
        let italic: UIFont?
        let boldItalic: UIFont?
        let code: UIFont

        init(body: UIFont, code: UIFont) {
            self.body = body
            bold = Self.face(body, .traitBold) ?? body
            italic = Self.face(body, .traitItalic)
            boldItalic = Self.face(body, [.traitBold, .traitItalic])
            self.code = code
        }

        static var current: Fonts {
            Fonts(body: AppFont.messageBody, code: AppFont.messageInlineCode)
        }

        private static func face(_ font: UIFont, _ traits: UIFontDescriptor.SymbolicTraits) -> UIFont? {
            let descriptor = font.fontDescriptor
            guard let styled = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(traits)) else { return nil }
            return UIFont(descriptor: styled, size: font.pointSize)
        }
    }

    /// How enclosing inline markup restyles a cell run.
    struct Traits: OptionSet {
        let rawValue: Int
        static let bold = Traits(rawValue: 1 << 0)
        static let italic = Traits(rawValue: 1 << 1)
        static let strikethrough = Traits(rawValue: 1 << 2)
    }

    /// The colors a cell is drawn in.
    struct Colors {
        let text: UIColor
        let link: UIColor
        let code: UIColor
        let codeBackground: UIColor

        /// For measuring only: colors do not change a width.
        static let measuring = Colors(text: .label, link: .label, code: .label, codeBackground: .clear)
    }

    /// Append a cell's inline content to the result, rendering links with `.link` attribute.
    static func appendCell(
        _ inlines: [MarkdownInline],
        to result: NSMutableAttributedString,
        fonts: Fonts,
        isHeader: Bool,
        colors: Colors,
        paragraph: NSParagraphStyle
    ) {
        let traits: Traits = isHeader ? .bold : []
        // Fast path: single plain text (most common table cell).
        if inlines.count == 1, case .text(let s) = inlines[0] {
            result.append(NSAttributedString(string: s, attributes: [
                .font: font(fonts, traits),
                .foregroundColor: colors.text,
                .paragraphStyle: paragraph,
            ]))
            return
        }
        for inline in inlines {
            appendInline(inline, to: result, fonts: fonts, colors: colors, paragraph: paragraph, traits: traits)
        }
    }

    /// A cell's single-line width and the width of its widest run that line
    /// breaking cannot split (`unbreakableRuns`), both as drawn.
    static func measure(_ inlines: [MarkdownInline], fonts: Fonts, isHeader: Bool) -> (natural: CGFloat, word: CGFloat) {
        let text = NSMutableAttributedString()
        appendCell(inlines, to: text, fonts: fonts, isHeader: isHeader, colors: .measuring, paragraph: NSParagraphStyle.default)
        guard text.length > 0 else { return (0, 0) }
        let line = CTLineCreateWithAttributedString(text)
        let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var word: CGFloat = 0
        for run in unbreakableRuns(in: text.string as NSString) {
            let start = CTLineGetOffsetForStringIndex(line, run.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, NSMaxRange(run), nil)
            word = max(word, abs(end - start))
        }
        return (ceil(natural), ceil(word))
    }

    /// The runs of `text` a wrapped cell cannot break inside: a run of ASCII
    /// letters, digits, and punctuation ends at a space, and after a `/` or
    /// `-`, where line breaking may split a path or a hyphenated word. Other
    /// scripts can break between characters, so they end a run too.
    static func unbreakableRuns(in text: NSString) -> [NSRange] {
        var runs: [NSRange] = []
        var start: Int?
        for index in 0 ..< text.length {
            let unit = text.character(at: index)
            guard unit > 0x20, unit < 0x7F else {
                if let begin = start { runs.append(NSRange(location: begin, length: index - begin)) }
                start = nil
                continue
            }
            if start == nil { start = index }
            if unit == 0x2F || unit == 0x2D, let begin = start {
                runs.append(NSRange(location: begin, length: index + 1 - begin))
                start = nil
            }
        }
        if let begin = start { runs.append(NSRange(location: begin, length: text.length - begin)) }
        return runs
    }

    private static func font(_ fonts: Fonts, _ traits: Traits) -> UIFont {
        switch (traits.contains(.bold), traits.contains(.italic)) {
        case (true, true): fonts.boldItalic ?? fonts.bold
        case (true, false): fonts.bold
        case (false, true): fonts.italic ?? fonts.body
        case (false, false): fonts.body
        }
    }

    private static func appendInline(
        _ inline: MarkdownInline,
        to result: NSMutableAttributedString,
        fonts: Fonts,
        colors: Colors,
        paragraph: NSParagraphStyle,
        traits: Traits
    ) {
        let font = font(fonts, traits)
        let defaultColor = colors.text
        let linkColor = colors.link
        // A family without an italic face slants the regular one.
        let slanted = traits.contains(.italic)
            && (traits.contains(.bold) ? fonts.boldItalic : fonts.italic) == nil
        func styled(_ color: UIColor) -> [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if slanted { attrs[.obliqueness] = 0.2 }
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
            // As in a paragraph (`MarkdownText`): code font, color, and background.
            var attrs = styled(colors.code)
            attrs[.font] = fonts.code
            attrs[.obliqueness] = nil
            attrs[.backgroundColor] = colors.codeBackground
            result.append(NSAttributedString(string: s, attributes: attrs))
        case .emphasis(let children):
            appendChildren(children, to: result, fonts: fonts, colors: colors, paragraph: paragraph, traits: traits.union(.italic))
        case .strong(let children):
            appendChildren(children, to: result, fonts: fonts, colors: colors, paragraph: paragraph, traits: traits.union(.bold))
        case .strikethrough(let children):
            appendChildren(children, to: result, fonts: fonts, colors: colors, paragraph: paragraph, traits: traits.union(.strikethrough))
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
        fonts: Fonts,
        colors: Colors,
        paragraph: NSParagraphStyle,
        traits: Traits
    ) {
        for child in children {
            appendInline(child, to: result, fonts: fonts, colors: colors, paragraph: paragraph, traits: traits)
        }
    }
}
