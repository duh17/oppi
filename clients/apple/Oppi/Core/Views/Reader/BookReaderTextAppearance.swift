import UIKit

/// Sets rendered chapter text in a book's appearance.
///
/// Markdown for a chapter is built with the app's chat typography, then handed
/// here: this pass replaces each run's font, ink and paragraph metrics with the
/// reader's chosen book typography, keeping the structure the renderer already
/// decided (which run is a heading, a quote, inline code, a link). It runs at
/// segment build time, so the chapter's heights are measured from the styled
/// text rather than restyled afterwards.
@MainActor
enum BookReaderTextAppearance {
    /// The marker the markdown renderer puts in front of a quoted block.
    private static let quoteMarker = "\u{258E}"

    static func apply(
        _ appearance: BookReaderAppearance,
        scale: CGFloat,
        traits: UITraitCollection? = nil,
        to segments: [FlatSegment]
    ) -> [FlatSegment] {
        segments.map { segment in
            guard case .text(let text) = segment else { return segment }
            return .text(apply(appearance, scale: scale, traits: traits, to: text))
        }
    }

    static func apply(
        _ appearance: BookReaderAppearance,
        scale: CGFloat,
        traits: UITraitCollection? = nil,
        to text: AttributedString
    ) -> AttributedString {
        let mutable = NSMutableAttributedString(text)
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return text }

        // Typeset sizes of the text being replaced, so a run can be recognised
        // as a heading or inline code whatever text size produced it. The traits
        // are the reader's own: a chapter set at a non-default text size must be
        // set at that size, whatever the current context happens to be.
        let referencePointSize = AppFont.messageBody.pointSize * max(scale, 0.1)
        let isQuote = mutable.string.contains(quoteMarker)

        mutable.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            let originalFont = attributes[.font] as? UIFont
            let role = role(
                for: originalFont,
                referencePointSize: referencePointSize,
                isQuote: isQuote
            )
            let symbolicTraits = originalFont?.fontDescriptor.symbolicTraits ?? []
            // A heading's weight comes from its role; inline emphasis inside
            // prose has to survive the font swap.
            let emphasisApplies = role != .heading1 && role != .heading2 && role != .heading3
            let bold = emphasisApplies && symbolicTraits.contains(.traitBold)
            let italic = role != .blockquote && symbolicTraits.contains(.traitItalic)

            let font = appearance.font(
                for: role,
                bold: bold,
                italic: italic,
                scale: scale,
                traits: traits
            )
            mutable.addAttribute(.font, value: font, range: range)
            mutable.addAttribute(
                .paragraphStyle,
                value: appearance.paragraphStyle(for: role, scale: scale, traits: traits),
                range: range
            )

            // `original` keeps the app's reader colours, which the run already
            // carries; a paper theme replaces them run by run.
            guard appearance.theme != .original else { return }
            if attributes[.link] != nil {
                mutable.addAttribute(.foregroundColor, value: appearance.linkColor(), range: range)
                return
            }
            let ink: UIColor
            switch role {
            case .blockquote, .caption:
                ink = appearance.secondaryTextColor()
            default:
                ink = appearance.textColor()
            }
            mutable.addAttribute(.foregroundColor, value: ink, range: range)
            if role == .code, attributes[.backgroundColor] != nil {
                mutable.addAttribute(
                    .backgroundColor,
                    value: appearance.codeBackgroundColor(),
                    range: range
                )
            }
        }

        return AttributedString(mutable)
    }

    /// Which role a rendered run belongs to. The markdown renderer builds
    /// headings larger than body text, inline code in the monospaced font, and
    /// quotes below a `▎` marker; nothing else is needed to tell them apart.
    static func role(
        for font: UIFont?,
        referencePointSize: CGFloat,
        isQuote: Bool
    ) -> BookTextRole {
        guard let font else { return isQuote ? .blockquote : .body }
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.traitMonoSpace) { return .code }
        guard referencePointSize > 0 else { return .body }
        let ratio = font.pointSize / referencePointSize
        if ratio >= 1.2 { return .heading1 }
        if ratio >= 1.1 { return .heading2 }
        if ratio >= 0.98, font.fontDescriptor.symbolicTraits.contains(.traitBold) {
            return .heading3
        }
        return isQuote ? .blockquote : .body
    }
}
