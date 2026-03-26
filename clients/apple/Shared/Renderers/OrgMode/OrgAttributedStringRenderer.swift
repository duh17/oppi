import CoreGraphics
import CoreText
import Foundation

#if canImport(UIKit)
import UIKit
private typealias PlatformFont = UIFont
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformFont = NSFont
private typealias PlatformColor = NSColor
#endif

/// Renders an org mode AST (`[OrgBlock]`) into a styled `NSAttributedString`.
///
/// Conforms to `AttributedStringDocumentRenderer` so it plugs into the
/// notebook render pipeline alongside the markdown renderer.
///
/// Platform-agnostic: uses `#if canImport(UIKit/AppKit)` for font/color types.
/// Theme colors arrive as `CGColor` via `RenderTheme` and are bridged to
/// platform colors at render time.
struct OrgAttributedStringRenderer: AttributedStringDocumentRenderer, Sendable {
    typealias Document = [OrgBlock]

    nonisolated func renderAttributedString(
        _ document: [OrgBlock],
        configuration: RenderConfiguration
    ) -> NSAttributedString {
        let ctx = RenderContext(configuration: configuration)
        let result = NSMutableAttributedString()

        for (index, block) in document.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(ctx.renderBlock(block))
        }

        return result
    }
}

// MARK: - Render Context

/// Internal rendering state — holds resolved fonts and colors for the current
/// configuration. Created once per `renderAttributedString` call.
private struct RenderContext: Sendable {
    let configuration: RenderConfiguration

    // Resolved platform colors from theme CGColors.
    let foreground: PlatformColor
    let foregroundDim: PlatformColor
    let background: PlatformColor
    let linkColor: PlatformColor
    let headingColor: PlatformColor
    let keywordColor: PlatformColor
    let commentColor: PlatformColor
    let codeBackground: PlatformColor
    let stringColor: PlatformColor

    // Base fonts at the configured size.
    let bodyFont: PlatformFont
    let monoFont: PlatformFont

    init(configuration: RenderConfiguration) {
        self.configuration = configuration
        let theme = configuration.theme
        let size = configuration.fontSize

        foreground = PlatformColor(cgColor: theme.foreground) ?? PlatformColor.white
        foregroundDim = PlatformColor(cgColor: theme.foregroundDim) ?? PlatformColor.gray
        background = PlatformColor(cgColor: theme.background) ?? PlatformColor.black
        linkColor = PlatformColor(cgColor: theme.link) ?? PlatformColor.systemBlue
        headingColor = PlatformColor(cgColor: theme.heading) ?? PlatformColor.white
        keywordColor = PlatformColor(cgColor: theme.keyword) ?? PlatformColor.purple
        commentColor = PlatformColor(cgColor: theme.comment) ?? PlatformColor.gray
        stringColor = PlatformColor(cgColor: theme.string) ?? PlatformColor.green

        // Subtle code background — slightly lighter/darker than main background.
        let codeBg = CGColor(
            red: min(1, theme.background.components?[0] ?? 0.12 + 0.06),
            green: min(1, (theme.background.components?.count ?? 0) > 1
                ? (theme.background.components?[1] ?? 0.12) + 0.06
                : (theme.background.components?[0] ?? 0.12) + 0.06),
            blue: min(1, (theme.background.components?.count ?? 0) > 2
                ? (theme.background.components?[2] ?? 0.12) + 0.06
                : (theme.background.components?[0] ?? 0.12) + 0.06),
            alpha: 1
        )
        codeBackground = PlatformColor(cgColor: codeBg) ?? PlatformColor.darkGray

        #if canImport(UIKit)
        bodyFont = PlatformFont.systemFont(ofSize: size)
        monoFont = PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #elseif canImport(AppKit)
        bodyFont = PlatformFont.systemFont(ofSize: size)
        monoFont = PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #endif
    }

    // MARK: - Font Helpers

    func boldFont(size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        PlatformFont.systemFont(ofSize: size, weight: .bold)
        #elseif canImport(AppKit)
        PlatformFont.boldSystemFont(ofSize: size)
        #endif
    }

    func italicFont(size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        PlatformFont.italicSystemFont(ofSize: size)
        #elseif canImport(AppKit)
        let font = PlatformFont.systemFont(ofSize: size)
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        #endif
    }

    func monoFontAt(size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #elseif canImport(AppKit)
        PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #endif
    }

    func fontWithTraits(_ font: PlatformFont, bold: Bool, italic: Bool) -> PlatformFont {
        #if canImport(UIKit)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if traits.isEmpty { return font }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return PlatformFont(descriptor: descriptor, size: 0)
        #elseif canImport(AppKit)
        var result = font
        if bold { result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask) }
        if italic { result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) }
        return result
        #endif
    }

    // MARK: - Block Rendering

    func renderBlock(_ block: OrgBlock) -> NSAttributedString {
        switch block {
        case let .heading(level, keyword, priority, title, tags):
            return renderHeading(level: level, keyword: keyword, priority: priority, title: title, tags: tags)

        case let .paragraph(inlines):
            return renderInlines(inlines, baseFont: bodyFont, baseColor: foreground)

        case let .list(kind, items):
            return renderList(kind: kind, items: items)

        case let .codeBlock(language, code):
            return renderCodeBlock(language: language, code: code)

        case let .quote(blocks):
            return renderQuote(blocks)

        case let .keyword(key, value):
            return renderKeyword(key: key, value: value)

        case .horizontalRule:
            return renderHorizontalRule()

        case let .comment(text):
            return renderComment(text)
        }
    }

    // MARK: - Heading

    func renderHeading(
        level: Int,
        keyword: String?,
        priority: Character?,
        title: [OrgInline],
        tags: [String]
    ) -> NSAttributedString {
        let fontSize: CGFloat = switch level {
        case 1: 24
        case 2: 20
        case 3: 17
        default: configuration.fontSize
        }

        let headingFont = boldFont(size: fontSize)
        let result = NSMutableAttributedString()

        // TODO/DONE keyword badge
        if let kw = keyword {
            let badgeColor: PlatformColor = switch kw {
            case "DONE", "CANCELLED": stringColor
            default: keywordColor
            }
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: boldFont(size: fontSize * 0.75),
                .foregroundColor: badgeColor,
            ]
            result.append(NSAttributedString(string: kw + " ", attributes: badgeAttrs))
        }

        // Priority cookie
        if let pri = priority {
            let priAttrs: [NSAttributedString.Key: Any] = [
                .font: headingFont,
                .foregroundColor: foregroundDim,
            ]
            result.append(NSAttributedString(string: "[#\(pri)] ", attributes: priAttrs))
        }

        // Title inlines
        result.append(renderInlines(title, baseFont: headingFont, baseColor: headingColor))

        // Tags — right-aligned gray text
        if !tags.isEmpty {
            let tagStr = "  :" + tags.joined(separator: ":") + ":"
            let tagAttrs: [NSAttributedString.Key: Any] = [
                .font: monoFontAt(size: fontSize * 0.7),
                .foregroundColor: foregroundDim,
            ]
            result.append(NSAttributedString(string: tagStr, attributes: tagAttrs))
        }

        return result
    }

    // MARK: - List

    func renderList(kind: OrgListKind, items: [OrgListItem]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for (index, item) in items.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            // Bullet or number prefix
            let bullet: String
            switch kind {
            case .unordered:
                let depth = 0 // Flat lists for now; nesting would come from recursive OrgBlock.list
                let bulletChars = ["•", "◦", "▪"]
                bullet = bulletChars[depth % bulletChars.count]
            case .ordered:
                bullet = "\(index + 1)."
            }

            // Checkbox symbol
            let checkbox: String
            switch item.checkbox {
            case .checked: checkbox = "☑ "
            case .unchecked: checkbox = "☐ "
            case .partial: checkbox = "☒ "
            case nil: checkbox = ""
            }

            // Paragraph style with indent
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.headIndent = 20
            paraStyle.firstLineHeadIndent = 0
            paraStyle.tabStops = [NSTextTab(textAlignment: .left, location: 20)]

            let prefixStr = "\(bullet)\t\(checkbox)"
            let prefixAttrs: [NSAttributedString.Key: Any] = [
                .font: bodyFont,
                .foregroundColor: foregroundDim,
                .paragraphStyle: paraStyle,
            ]
            result.append(NSAttributedString(string: prefixStr, attributes: prefixAttrs))

            // Item content
            let content = renderInlines(item.content, baseFont: bodyFont, baseColor: foreground)
            let mutableContent = NSMutableAttributedString(attributedString: content)
            mutableContent.addAttribute(
                .paragraphStyle,
                value: paraStyle,
                range: NSRange(location: 0, length: mutableContent.length)
            )
            result.append(mutableContent)
        }

        return result
    }

    // MARK: - Code Block

    func renderCodeBlock(language: String?, code: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let codeFont = monoFontAt(size: configuration.fontSize * 0.9)

        // Language label
        if let lang = language, !lang.isEmpty {
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: monoFontAt(size: configuration.fontSize * 0.75),
                .foregroundColor: foregroundDim,
            ]
            result.append(NSAttributedString(string: lang + "\n", attributes: labelAttrs))
        }

        // Code content with indentation and background
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.headIndent = 8
        paraStyle.firstLineHeadIndent = 8
        paraStyle.tailIndent = -8

        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: codeFont,
            .foregroundColor: foreground,
            .backgroundColor: codeBackground,
            .paragraphStyle: paraStyle,
        ]
        result.append(NSAttributedString(string: code, attributes: codeAttrs))

        return result
    }

    // MARK: - Block Quote

    func renderQuote(_ blocks: [OrgBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let paraStyle = NSMutableParagraphStyle()
        paraStyle.headIndent = 16
        paraStyle.firstLineHeadIndent = 16

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            let blockStr = renderBlock(block)
            let mutable = NSMutableAttributedString(attributedString: blockStr)

            // Apply italic + indent + dimmed color across the whole block
            let range = NSRange(location: 0, length: mutable.length)
            mutable.addAttribute(.paragraphStyle, value: paraStyle, range: range)
            mutable.addAttribute(.foregroundColor, value: foregroundDim, range: range)

            // Make text italic
            mutable.enumerateAttribute(.font, in: range) { value, subRange, _ in
                guard let font = value as? PlatformFont else { return }
                let italicized = fontWithTraits(font, bold: false, italic: true)
                mutable.addAttribute(.font, value: italicized, range: subRange)
            }

            result.append(mutable)
        }

        return result
    }

    // MARK: - Keyword

    func renderKeyword(key: String, value: String) -> NSAttributedString {
        let smallFont = monoFontAt(size: configuration.fontSize * 0.85)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: smallFont,
            .foregroundColor: foregroundDim,
        ]
        let text = "#+\(key): \(value)"
        return NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: - Horizontal Rule

    func renderHorizontalRule() -> NSAttributedString {
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: foregroundDim,
            .paragraphStyle: paraStyle,
        ]
        return NSAttributedString(string: "───────────", attributes: attrs)
    }

    // MARK: - Comment

    func renderComment(_ text: String) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: monoFontAt(size: configuration.fontSize * 0.85),
            .foregroundColor: commentColor,
        ]
        let commentText = text.isEmpty ? "# " : "# \(text)"
        return NSAttributedString(string: commentText, attributes: attrs)
    }

    // MARK: - Inline Rendering

    func renderInlines(
        _ inlines: [OrgInline],
        baseFont: PlatformFont,
        baseColor: PlatformColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for inline in inlines {
            result.append(renderInline(inline, baseFont: baseFont, baseColor: baseColor))
        }

        return result
    }

    func renderInline(
        _ inline: OrgInline,
        baseFont: PlatformFont,
        baseColor: PlatformColor
    ) -> NSAttributedString {
        switch inline {
        case let .text(str):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: baseColor,
            ]
            return NSAttributedString(string: str, attributes: attrs)

        case let .bold(children):
            let boldedFont = fontWithTraits(baseFont, bold: true, italic: false)
            return renderInlines(children, baseFont: boldedFont, baseColor: baseColor)

        case let .italic(children):
            let italicizedFont = fontWithTraits(baseFont, bold: false, italic: true)
            return renderInlines(children, baseFont: italicizedFont, baseColor: baseColor)

        case let .underline(children):
            let inner = renderInlines(children, baseFont: baseFont, baseColor: baseColor)
            let mutable = NSMutableAttributedString(attributedString: inner)
            mutable.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: mutable.length)
            )
            return mutable

        case let .strikethrough(children):
            let inner = renderInlines(children, baseFont: baseFont, baseColor: baseColor)
            let mutable = NSMutableAttributedString(attributedString: inner)
            mutable.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: mutable.length)
            )
            return mutable

        case let .code(str):
            let codeFont = monoFontAt(size: baseFont.pointSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: baseColor,
                .backgroundColor: codeBackground,
            ]
            return NSAttributedString(string: str, attributes: attrs)

        case let .verbatim(str):
            let codeFont = monoFontAt(size: baseFont.pointSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: baseColor,
                .backgroundColor: codeBackground,
            ]
            return NSAttributedString(string: str, attributes: attrs)

        case let .link(url, description):
            let result = NSMutableAttributedString()
            if let desc = description {
                let inner = renderInlines(desc, baseFont: baseFont, baseColor: linkColor)
                let mutable = NSMutableAttributedString(attributedString: inner)
                if let linkURL = URL(string: url) {
                    mutable.addAttribute(
                        .link,
                        value: linkURL,
                        range: NSRange(location: 0, length: mutable.length)
                    )
                }
                result.append(mutable)
            } else {
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: baseFont,
                    .foregroundColor: linkColor,
                ]
                if let linkURL = URL(string: url) {
                    attrs[.link] = linkURL
                }
                result.append(NSAttributedString(string: url, attributes: attrs))
            }
            return result
        }
    }
}
