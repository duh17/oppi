import UIKit
import SwiftUI

/// NSTextStorage that applies live markdown syntax highlighting as you type.
///
/// Handles: headings, bold, italic, bold-italic, inline code, code fences,
/// YAML frontmatter, links, blockquotes, list markers, horizontal rules,
/// and strikethrough.
///
/// Uses the app's theme palette via `ThemeRuntimeState` so colors match
/// the current theme (Tokyo Night, Apple Dark, etc.).
///
/// Performance: only re-highlights the edited paragraph + neighbors
/// on each edit, not the full document.
final class MarkdownTextStorage: NSTextStorage {

    // MARK: - Backing store

    private let backing = NSMutableAttributedString()

    override var string: String { backing.string }

    override func attributes(
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: str.count - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    // MARK: - Highlighting

    /// Base font for body text.
    var bodyFont: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular) {
        didSet { rehighlightAll() }
    }

    /// Called after every edit — re-highlights affected lines.
    override func processEditing() {
        let editedRange = self.editedRange

        // Expand to full lines (markdown context is always line-based)
        let nsString = backing.string as NSString
        let lineRange = nsString.lineRange(for: editedRange)

        // Expand one more line in each direction for multi-line constructs
        let expandedStart = lineRange.location > 0
            ? nsString.lineRange(for: NSRange(location: lineRange.location - 1, length: 0)).location
            : lineRange.location
        let expandedEnd = NSMaxRange(lineRange) < nsString.length
            ? NSMaxRange(nsString.lineRange(for: NSRange(location: NSMaxRange(lineRange), length: 0)))
            : NSMaxRange(lineRange)
        let expandedRange = NSRange(location: expandedStart, length: expandedEnd - expandedStart)

        highlightRange(expandedRange)

        super.processEditing()
    }

    /// Re-highlight the entire document (e.g. after theme change).
    func rehighlightAll() {
        guard backing.length > 0 else { return }
        beginEditing()
        highlightRange(NSRange(location: 0, length: backing.length))
        edited(.editedAttributes, range: NSRange(location: 0, length: backing.length), changeInLength: 0)
        endEditing()
    }

    // MARK: - Core Highlighter

    private func highlightRange(_ range: NSRange) {
        let palette = ThemeRuntimeState.currentPalette()
        let text = backing.string as NSString
        let fullLength = text.length

        // Default attributes for the range
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor(palette.fg),
        ]
        backing.setAttributes(defaultAttrs, range: range)

        // Track fence state for the whole document up to our range
        // (needed to know if we're inside a code block)
        var inFence = false
        var inFrontmatter = false
        var fenceStart = 0
        var lineStart = 0

        // Pre-scan: determine fence/frontmatter state before our range
        if range.location > 0 {
            let prescanText = text.substring(with: NSRange(location: 0, length: range.location))
            var hasFrontmatter = false
            for (i, line) in prescanText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") {
                    inFence.toggle()
                } else if trimmed == "---" {
                    if i == 0 {
                        hasFrontmatter = true
                        inFrontmatter = true
                    } else if inFrontmatter {
                        inFrontmatter = false
                    }
                }
            }
            _ = hasFrontmatter // suppress warning
        }

        // Process each line in range
        var pos = range.location
        while pos < NSMaxRange(range) && pos < fullLength {
            let lineRange = text.lineRange(for: NSRange(location: pos, length: 0))
            let line = text.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // --- Frontmatter ---
            if trimmed == "---" {
                if pos == 0 {
                    inFrontmatter = true
                    styleLine(lineRange, color: palette.mdHr, font: bodyFont)
                    pos = NSMaxRange(lineRange)
                    continue
                } else if inFrontmatter {
                    inFrontmatter = false
                    styleLine(lineRange, color: palette.mdHr, font: bodyFont)
                    pos = NSMaxRange(lineRange)
                    continue
                }
            }

            if inFrontmatter {
                highlightFrontmatterLine(lineRange, line: line, palette: palette)
                pos = NSMaxRange(lineRange)
                continue
            }

            // --- Code fence ---
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                styleLine(lineRange, color: palette.mdCodeBlockBorder, font: bodyFont)
                pos = NSMaxRange(lineRange)
                continue
            }

            if inFence {
                styleLine(lineRange, color: palette.mdCodeBlock, font: bodyFont)
                pos = NSMaxRange(lineRange)
                continue
            }

            // --- Heading ---
            if let headingLevel = headingLevel(trimmed) {
                let headingFont = fontForHeading(headingLevel)
                styleLine(lineRange, color: palette.mdHeading, font: headingFont)
                pos = NSMaxRange(lineRange)
                continue
            }

            // --- Horizontal rule ---
            if isHorizontalRule(trimmed) {
                styleLine(lineRange, color: palette.mdHr, font: bodyFont)
                pos = NSMaxRange(lineRange)
                continue
            }

            // --- Blockquote ---
            if trimmed.hasPrefix(">") {
                styleLine(lineRange, color: palette.mdQuote, font: italicBodyFont())
                // Highlight the > marker
                if let markerRange = rangeOfPrefix(">", in: line, lineStart: lineRange.location) {
                    backing.addAttribute(.foregroundColor, value: UIColor(palette.mdQuoteBorder), range: markerRange)
                }
                pos = NSMaxRange(lineRange)
                continue
            }

            // --- List markers ---
            highlightListMarker(line: line, lineRange: lineRange, palette: palette)

            // --- Inline styles ---
            highlightInlineStyles(lineRange: lineRange, palette: palette)

            pos = NSMaxRange(lineRange)
        }
    }

    // MARK: - Inline Highlighting

    private func highlightInlineStyles(lineRange: NSRange, palette: ThemePalette) {
        let text = backing.string as NSString
        let line = text.substring(with: lineRange)

        // Inline code (`...`)
        highlightPattern(
            "`([^`]+)`",
            in: line,
            lineOffset: lineRange.location,
            fullMatchColor: UIColor(palette.mdCode),
            fullMatchFont: .monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular),
            fullMatchBg: UIColor(palette.bgHighlight)
        )

        // Bold-italic (***...***)
        highlightPattern(
            "\\*\\*\\*(.+?)\\*\\*\\*",
            in: line,
            lineOffset: lineRange.location,
            fullMatchColor: UIColor(palette.fg),
            fullMatchFont: boldItalicBodyFont(),
            fullMatchBg: nil
        )

        // Bold (**...**)
        highlightPattern(
            "\\*\\*(.+?)\\*\\*",
            in: line,
            lineOffset: lineRange.location,
            fullMatchColor: UIColor(palette.fg),
            fullMatchFont: boldBodyFont(),
            fullMatchBg: nil
        )

        // Italic (*...*)
        highlightPattern(
            "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)",
            in: line,
            lineOffset: lineRange.location,
            fullMatchColor: UIColor(palette.fgDim),
            fullMatchFont: italicBodyFont(),
            fullMatchBg: nil
        )

        // Strikethrough (~~...~~)
        highlightPattern(
            "~~(.+?)~~",
            in: line,
            lineOffset: lineRange.location,
            fullMatchColor: UIColor(palette.comment),
            fullMatchFont: nil,
            fullMatchBg: nil,
            extraAttrs: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        )

        // Links [text](url)
        highlightLinks(line: line, lineOffset: lineRange.location, palette: palette)

        // Image refs ![alt](url)
        highlightPattern(
            "!\\[([^\\]]*)\\]\\([^)]+\\)",
            in: line,
            lineOffset: lineRange.location,
            fullMatchColor: UIColor(palette.mdLink),
            fullMatchFont: nil,
            fullMatchBg: nil
        )
    }

    private func highlightLinks(line: String, lineOffset: Int, palette: ThemePalette) {
        // [text](url)
        guard let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)") else { return }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))

        for match in matches {
            let fullRange = NSRange(location: match.range.location + lineOffset, length: match.range.length)
            // Link text color
            backing.addAttribute(.foregroundColor, value: UIColor(palette.mdLink), range: fullRange)
            // Underline just the text part
            if match.numberOfRanges > 1 {
                let textRange = NSRange(
                    location: match.range(at: 1).location + lineOffset,
                    length: match.range(at: 1).length
                )
                backing.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
            }
            // URL part dimmer
            if match.numberOfRanges > 2 {
                let urlRange = NSRange(
                    location: match.range(at: 2).location + lineOffset,
                    length: match.range(at: 2).length
                )
                backing.addAttribute(.foregroundColor, value: UIColor(palette.mdLinkUrl), range: urlRange)
            }
        }
    }

    private func highlightPattern(
        _ pattern: String,
        in line: String,
        lineOffset: Int,
        fullMatchColor: UIColor?,
        fullMatchFont: UIFont?,
        fullMatchBg: UIColor?,
        extraAttrs: [NSAttributedString.Key: Any]? = nil
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))

        for match in matches {
            let range = NSRange(location: match.range.location + lineOffset, length: match.range.length)
            if let color = fullMatchColor {
                backing.addAttribute(.foregroundColor, value: color, range: range)
            }
            if let font = fullMatchFont {
                backing.addAttribute(.font, value: font, range: range)
            }
            if let bg = fullMatchBg {
                backing.addAttribute(.backgroundColor, value: bg, range: range)
            }
            if let extra = extraAttrs {
                for (key, value) in extra {
                    backing.addAttribute(key, value: value, range: range)
                }
            }
        }
    }

    // MARK: - Frontmatter

    private func highlightFrontmatterLine(_ lineRange: NSRange, line: String, palette: ThemePalette) {
        // YAML key: value — use syntax tokens (keys as types, values as strings)
        if let colonIdx = line.firstIndex(of: ":") {
            let keyLength = line.distance(from: line.startIndex, to: colonIdx)
            let keyRange = NSRange(location: lineRange.location, length: keyLength)
            let valueRange = NSRange(
                location: lineRange.location + keyLength,
                length: lineRange.length - keyLength
            )
            backing.addAttributes([
                .foregroundColor: UIColor(palette.syntaxType),
                .font: bodyFont,
            ], range: keyRange)
            backing.addAttributes([
                .foregroundColor: UIColor(palette.syntaxString),
                .font: bodyFont,
            ], range: valueRange)
        } else {
            styleLine(lineRange, color: palette.mdHr, font: bodyFont)
        }
    }

    // MARK: - Helpers

    private func styleLine(_ range: NSRange, color: Color, font: UIFont) {
        backing.addAttributes([
            .foregroundColor: UIColor(color),
            .font: font,
        ], range: range)
    }

    private func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else if ch == " " { break } else { return nil }
        }
        return (level >= 1 && level <= 6) ? level : nil
    }

    private func isHorizontalRule(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { !$0.isWhitespace }
        guard chars.count >= 3 else { return false }
        return chars.allSatisfy { $0 == "-" } ||
               chars.allSatisfy { $0 == "*" } ||
               chars.allSatisfy { $0 == "_" }
    }

    private func highlightListMarker(line: String, lineRange: NSRange, palette: ThemePalette) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Unordered: - or * or +
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            if let r = rangeOfListMarker(line, lineStart: lineRange.location) {
                backing.addAttribute(.foregroundColor, value: UIColor(palette.mdListBullet), range: r)
            }
            return
        }

        // Ordered: 1. 2. etc
        if let dotIdx = trimmed.firstIndex(of: "."),
           trimmed[trimmed.startIndex..<dotIdx].allSatisfy({ $0.isNumber }),
           trimmed.index(after: dotIdx) < trimmed.endIndex,
           trimmed[trimmed.index(after: dotIdx)] == " " {
            let prefixLen = trimmed.distance(from: trimmed.startIndex, to: trimmed.index(after: dotIdx))
            let leadingSpaces = line.prefix(while: { $0.isWhitespace }).count
            let markerRange = NSRange(location: lineRange.location + leadingSpaces, length: prefixLen)
            backing.addAttribute(.foregroundColor, value: UIColor(palette.mdListBullet), range: markerRange)
        }

        // Checkbox: - [ ] or - [x]
        if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
            let leadingSpaces = line.prefix(while: { $0.isWhitespace }).count
            let checkRange = NSRange(location: lineRange.location + leadingSpaces, length: 6)
            backing.addAttribute(.foregroundColor, value: UIColor(palette.mdListBullet), range: checkRange)
        }
    }

    private func rangeOfPrefix(_ prefix: String, in line: String, lineStart: Int) -> NSRange? {
        let leadingSpaces = line.prefix(while: { $0.isWhitespace }).count
        return NSRange(location: lineStart + leadingSpaces, length: prefix.count)
    }

    private func rangeOfListMarker(_ line: String, lineStart: Int) -> NSRange? {
        let leadingSpaces = line.prefix(while: { $0.isWhitespace }).count
        return NSRange(location: lineStart + leadingSpaces, length: 1)
    }

    // MARK: - Font Variants

    private func fontForHeading(_ level: Int) -> UIFont {
        let sizes: [CGFloat] = [22, 19, 16, 15, 14, 13]
        let size = level <= sizes.count ? sizes[level - 1] : bodyFont.pointSize
        return .monospacedSystemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
    }

    private func boldBodyFont() -> UIFont {
        .monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .bold)
    }

    private func italicBodyFont() -> UIFont {
        let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitItalic) ?? bodyFont.fontDescriptor
        return UIFont(descriptor: descriptor, size: bodyFont.pointSize)
    }

    private func boldItalicBodyFont() -> UIFont {
        let traits: UIFontDescriptor.SymbolicTraits = [.traitBold, .traitItalic]
        let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(traits) ?? bodyFont.fontDescriptor
        return UIFont(descriptor: descriptor, size: bodyFont.pointSize)
    }
}
