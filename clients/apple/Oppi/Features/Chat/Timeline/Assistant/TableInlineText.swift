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

        /// Digits in `body` and its faces are tabular, all one width, so the numbers
        /// in a column line up by place value.
        init(body: UIFont, code: UIFont) {
            let body = Self.tabularDigits(body)
            self.body = body
            bold = Self.face(body, .traitBold) ?? body
            italic = Self.face(body, .traitItalic)
            boldItalic = Self.face(body, [.traitBold, .traitItalic])
            self.code = code
        }

        static var current: Self {
            Self(body: AppFont.messageBody, code: AppFont.messageInlineCode)
        }

        /// The message faces at `scale` times their size (the reader's text size).
        static func current(scale: CGFloat) -> Self {
            guard scale != 1 else { return current }
            return Self(
                body: FullScreenCodeTypography.scaledFont(AppFont.messageBody, scale: scale),
                code: FullScreenCodeTypography.scaledFont(AppFont.messageInlineCode, scale: scale)
            )
        }

        /// A digit's advance in the body face: the planner's unit.
        var digitWidth: CGFloat {
            ("0" as NSString).size(withAttributes: [.font: body]).width
        }

        private static func tabularDigits(_ font: UIFont) -> UIFont {
            let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
            ]]])
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }

        private static func face(_ font: UIFont, _ traits: UIFontDescriptor.SymbolicTraits) -> UIFont? {
            let descriptor = font.fontDescriptor
            guard let styled = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(traits)) else { return nil }
            return UIFont(descriptor: styled, size: font.pointSize)
        }
    }

    /// The colors a cell is drawn in. Formulas take their ink from `palette`.
    struct Colors {
        let text: UIColor
        let link: UIColor
        let code: UIColor
        let codeBackground: UIColor
        let palette: ThemePalette

        /// For measuring only: colors do not change a width.
        static let measuring = Self(
            text: .label, link: .label, code: .label, codeBackground: .clear, palette: ThemeID.dark.palette
        )
    }

    /// Append a cell's inline content to the result, through the one inline
    /// renderer (`MarkdownInlineRenderer`): emphasis as font faces, formulas
    /// as attachments, links with the `.link` attribute.
    static func appendCell(
        _ inlines: [MarkdownInline],
        to result: NSMutableAttributedString,
        fonts: Fonts,
        isHeader: Bool,
        colors: Colors,
        paragraph: NSParagraphStyle
    ) {
        // Fast path: single plain text (most common table cell).
        if inlines.count == 1, case .text(let s) = inlines[0] {
            result.append(NSAttributedString(string: s, attributes: [
                .font: isHeader ? fonts.bold : fonts.body,
                .foregroundColor: colors.text,
                .paragraphStyle: paragraph,
            ]))
            return
        }
        MarkdownInlineRenderer.append(inlines, to: result, style: MarkdownInlineRenderer.Style(
            font: fonts.body,
            color: colors.text,
            linkColor: colors.link,
            codeFont: fonts.code,
            codeColor: colors.code,
            codeBackground: colors.codeBackground,
            mutedColor: colors.text,
            palette: colors.palette,
            paragraph: paragraph,
            faces: fonts,
            traits: isHeader ? .bold : []
        ))
    }

    /// A cell's width on one line (its widest line, when a `<br>` breaks it),
    /// the width of its widest run that line breaking cannot split
    /// (`unbreakableRuns`), both as drawn, and whether it breaks into lines.
    /// CoreText gives an attachment (a formula, a file icon) no width of its
    /// own, so its bounds stand in for the replacement character's advance,
    /// and an attachment is an unbreakable run by itself.
    static func measure(
        _ inlines: [MarkdownInline],
        fonts: Fonts,
        isHeader: Bool
    ) -> (natural: CGFloat, word: CGFloat, breaksLines: Bool) {
        let text = NSMutableAttributedString()
        appendCell(inlines, to: text, fonts: fonts, isHeader: isHeader, colors: .measuring, paragraph: NSParagraphStyle.default)
        guard text.length > 0 else { return (0, 0, false) }
        let string = text.string as NSString
        guard string.range(of: "\n").location != NSNotFound else {
            let measured = measureLine(text)
            return (ceil(measured.natural), ceil(measured.word), false)
        }
        var natural: CGFloat = 0
        var word: CGFloat = 0
        var lineStart = 0
        while lineStart <= string.length {
            let newline = string.range(of: "\n", range: NSRange(location: lineStart, length: string.length - lineStart))
            let lineEnd = newline.location == NSNotFound ? string.length : newline.location
            let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            let measured = measureLine(text.attributedSubstring(from: lineRange))
            natural = max(natural, measured.natural)
            word = max(word, measured.word)
            lineStart = lineEnd + 1
        }
        return (ceil(natural), ceil(word), true)
    }

    private static func measureLine(_ text: NSAttributedString) -> (natural: CGFloat, word: CGFloat) {
        guard text.length > 0 else { return (0, 0) }
        let line = CTLineCreateWithAttributedString(text)
        var natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var word: CGFloat = 0
        for run in unbreakableRuns(in: text.string as NSString) {
            let start = CTLineGetOffsetForStringIndex(line, run.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, NSMaxRange(run), nil)
            word = max(word, abs(end - start))
        }
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let start = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, NSMaxRange(range), nil)
            natural += attachment.bounds.width * CGFloat(range.length) - abs(end - start)
            word = max(word, attachment.bounds.width)
        }
        return (natural, word)
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
}
