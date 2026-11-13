import UIKit

/// The one renderer for inline Markdown. Paragraphs, headings and table cells
/// all draw through `append`; they differ only by `Style`. Formulas arrive as
/// `.math` nodes from the parser and become baseline-aligned attachments here,
/// so math renders wherever inline text does.
enum MarkdownInlineRenderer {
    struct Style {
        var font: UIFont
        var color: UIColor
        var linkColor: UIColor
        var codeFont: UIFont
        var codeColor: UIColor
        var codeBackground: UIColor
        /// Image alt text, raw HTML, and embeds that have no link.
        var mutedColor: UIColor
        /// Formula ink, badges and file icons.
        var palette: ThemePalette
        var paragraph: NSParagraphStyle?
        /// Table cells, which CoreText measures: emphasis as the font's own
        /// faces and a line break as a space. Prose leaves emphasis to the
        /// presentation intent TextKit applies.
        var faces: TableInlineText.Fonts?
        /// Traits every run starts with (a header cell is bold).
        var traits: Traits = []
    }

    struct Traits: OptionSet {
        let rawValue: Int
        static let bold = Self(rawValue: 1 << 0)
        static let italic = Self(rawValue: 1 << 1)
        static let strikethrough = Self(rawValue: 1 << 2)
    }

    static func append(_ inlines: [MarkdownInline], to result: NSMutableAttributedString, style: Style) {
        Walker(style: style, result: result).append(inlines, Context(traits: style.traits))
    }

    static func attributedString(_ inlines: [MarkdownInline], style: Style) -> AttributedString {
        let result = NSMutableAttributedString()
        append(inlines, to: result, style: style)
        return AttributedString(result)
    }

    private struct Context {
        var traits: Traits
        /// Inside a link: its URL when it has one, and whether it is underlined.
        var isLink = false
        var url: URL?
        var underline = false

        func adding(_ trait: Traits) -> Self {
            var context = self
            context.traits.insert(trait)
            return context
        }
    }

    private struct Walker {
        let style: Style
        let result: NSMutableAttributedString

        func append(_ inlines: [MarkdownInline], _ context: Context) {
            // Badges written back to back join into one bar.
            var previousSegment: MarkdownBadge?
            for (index, inline) in inlines.enumerated() {
                guard style.faces == nil, case .html(let raw) = inline, let badge = MarkdownBadge(markup: raw) else {
                    previousSegment = nil
                    append(inline, context)
                    continue
                }
                let nextIsSegment: Bool = {
                    guard index + 1 < inlines.count, case .html(let next) = inlines[index + 1] else { return false }
                    return MarkdownBadge(markup: next)?.shape == .segment
                }()
                result.append(NSAttributedString(MarkdownBadgeAttachment.attributedString(
                    badge,
                    joiningAfter: badge.shape == .segment ? previousSegment : nil,
                    endsBar: badge.shape == .segment && !nextIsSegment,
                    palette: style.palette
                )))
                previousSegment = badge.shape == .segment ? badge : nil
            }
        }

        private func append(_ inline: MarkdownInline, _ context: Context) {
            switch inline {
            case .text(let text):
                appendText(text, context)
            case .emphasis(let children):
                append(children, context.adding(.italic))
            case .strong(let children):
                append(children, context.adding(.bold))
            case .strikethrough(let children):
                append(children, context.adding(.strikethrough))
            case .code(let code):
                var attributes = attributes(context)
                attributes[.font] = style.codeFont
                attributes[.foregroundColor] = style.codeColor
                attributes[.backgroundColor] = style.codeBackground
                attributes[.obliqueness] = nil
                result.append(NSAttributedString(string: code, attributes: attributes))
            case .link(let children, let destination):
                if let icon = MarkdownInlineRenderer.fileIcon(for: destination),
                   let attachment = iconAttachment(icon) {
                    result.append(attachment)
                    appendText(" ", context)
                }
                var link = context
                link.isLink = true
                link.url = destination.flatMap(URL.init(string:)).flatMap { $0.scheme == nil ? nil : $0 }
                link.underline = link.url.map { !ResourceReferenceURL.isReference($0) } ?? true
                append(children, link)
            case .image(let alt, _, _):
                let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
                appendText(trimmed.isEmpty ? "[image]" : "[\(trimmed)]", context, color: style.mutedColor)
            case .videoEmbed(let embed):
                appendEmbed(embed.displayLabel, embed.reference, context)
            case .audioEmbed(let embed):
                appendEmbed(embed.displayLabel, embed.reference, context)
            case .usdzEmbed(let embed):
                appendEmbed(embed.displayLabel, embed.reference, context)
            case .softBreak, .hardBreak:
                appendText(style.faces == nil ? "\n" : " ", context)
            case .html(let raw):
                appendText(raw, context, color: style.mutedColor)
            case .math(let math):
                if let formula = formulaAttachment(math) {
                    result.append(formula)
                } else {
                    appendText(math.source, context)
                }
            }
        }

        private func appendText(_ text: String, _ context: Context, color: UIColor? = nil) {
            result.append(NSAttributedString(string: text, attributes: attributes(context, color: color)))
        }

        private func appendEmbed(_ label: String, _ reference: ResourceReference, _ context: Context) {
            var embed = context
            embed.isLink = true
            embed.url = ResourceReferenceURL.make(reference)
            embed.underline = false
            appendText(label, embed, color: embed.url == nil ? style.mutedColor : nil)
        }

        private func attributes(_ context: Context, color: UIColor? = nil) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color ?? (context.isLink ? style.linkColor : style.color),
            ]
            if let paragraph = style.paragraph { attributes[.paragraphStyle] = paragraph }
            let traits = context.traits
            if let faces = style.faces {
                let face: UIFont? = switch (traits.contains(.bold), traits.contains(.italic)) {
                case (true, true): faces.boldItalic ?? faces.bold
                case (true, false): faces.bold
                case (false, true): faces.italic
                case (false, false): faces.body
                }
                attributes[.font] = face ?? faces.body
                // A family without an italic face slants the upright one.
                if traits.contains(.italic), (traits.contains(.bold) ? faces.boldItalic : faces.italic) == nil {
                    attributes[.obliqueness] = 0.2
                }
            } else {
                attributes[.font] = style.font
                var intent: InlinePresentationIntent = []
                if traits.contains(.bold) { intent.insert(.stronglyEmphasized) }
                if traits.contains(.italic) { intent.insert(.emphasized) }
                if !intent.isEmpty { attributes[.inlinePresentationIntent] = NSNumber(value: intent.rawValue) }
            }
            if traits.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if context.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let url = context.url { attributes[.link] = url }
            return attributes
        }

        /// No `.link` on an attachment: UIKit's long-press text drag removes an
        /// attachment inside a link twice and aborts with `NSRangeException`.
        private func formulaAttachment(_ math: MarkdownMath) -> NSAttributedString? {
            let font = style.faces?.body ?? style.font
            guard let rendered = DocumentRenderPipeline.renderInlineLatexImage(
                text: math.latex,
                config: RenderConfiguration(
                    fontSize: font.pointSize,
                    maxWidth: 1_000,
                    theme: style.palette.renderTheme,
                    displayMode: .inline
                )
            ) else { return nil }
            let attachment = InlineLatexTextAttachment(formulaLabel: FlatSegment.formulaAccessibilityLabel(for: math.latex))
            attachment.image = rendered.image
            attachment.bounds = CGRect(
                x: 0,
                y: -(rendered.size.height - rendered.baseline),
                width: rendered.size.width,
                height: rendered.size.height
            )
            return NSAttributedString(attachment: attachment)
        }

        /// A tinted SF Symbol centred on the cap height. An unknown symbol
        /// fails closed to no icon.
        private func iconAttachment(_ icon: FileIcon) -> NSAttributedString? {
            let font = style.faces?.body ?? style.font
            let side = round(font.capHeight * 1.25)
            guard side > 0,
                  let image = UIImage(
                      systemName: icon.symbolName,
                      withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.72, weight: .medium)
                  )?.withTintColor(icon.color, renderingMode: .alwaysOriginal) else { return nil }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
            return NSAttributedString(attachment: attachment)
        }
    }

    /// A link to a non-text file (image, audio, video, PDF, binary) leads with
    /// its file icon; text-like files stay icon-free.
    static func fileIcon(for destination: String?) -> FileIcon? {
        guard let destination,
              let url = URL(string: destination),
              let reference = ResourceReferenceURL.parse(url) else { return nil }
        let path = reference.fileCandidatePath ?? reference.target
        guard FileKind.detect(from: path).previewCategory != .text else { return nil }
        return FileIcon.forPath(path)
    }
}
