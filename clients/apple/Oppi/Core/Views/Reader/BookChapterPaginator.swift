import UIKit

/// One chapter laid out as pages: the chapter's text as a single attributed
/// string, the character range each page shows, and where each of the chapter's
/// top-level blocks starts in that string.
///
/// The string is the one authority for reading order: a page range and a block
/// start both index it, so a saved position, a page turn, and a text-size change
/// all mean the same character.
struct BookChapterPages {
    let text: NSAttributedString
    /// One range per page, in reading order, covering every character once.
    let pageRanges: [NSRange]
    /// Where each top-level block starts, in `EPUBChapterSource.blocks` order.
    let blockStarts: [Int]
}

extension BookChapterPages {
    var pageCount: Int { max(pageRanges.count, 1) }

    var isEmpty: Bool { text.length == 0 }

    /// The page showing `offset`, clamped into the chapter. The last page whose
    /// range starts at or before the character owns it.
    func pageIndex(containingCharacter offset: Int) -> Int {
        guard !pageRanges.isEmpty else { return 0 }
        let clamped = min(max(offset, 0), max(text.length - 1, 0))
        var index = 0
        for (page, range) in pageRanges.enumerated() where range.location <= clamped {
            index = page
        }
        return index
    }

    /// Where the person is, in the chart the store keeps: the block the
    /// character falls in, and how far into that block it sits, in characters.
    /// Characters are what a page can be cut at, and they survive a
    /// re-pagination, which a measured scroll offset does not.
    func storedPosition(forCharacter offset: Int) -> (blockOrdinal: Int, offsetPoints: Double) {
        guard !blockStarts.isEmpty else { return (0, 0) }
        var ordinal = 0
        for (index, start) in blockStarts.enumerated() where start <= offset {
            ordinal = index
        }
        return (ordinal, Double(max(offset - blockStarts[ordinal], 0)))
    }

    /// The character a stored position names. The distance into the block is
    /// clamped to the block, so a position the scrolling body saved in points
    /// opens inside the block it named rather than in the next one.
    func characterOffset(forBlockOrdinal ordinal: Int, offsetPoints: Double = 0) -> Int {
        guard !blockStarts.isEmpty else { return 0 }
        let clamped = min(max(ordinal, 0), blockStarts.count - 1)
        let start = min(max(blockStarts[clamped], 0), max(text.length - 1, 0))
        let end = clamped + 1 < blockStarts.count
            ? min(max(blockStarts[clamped + 1], start), max(text.length - 1, start))
            : max(text.length - 1, start)
        let advance = max(0, Int(offsetPoints.rounded(.down)))
        return min(start + advance, end)
    }

    /// Words from `offset` to the end of the chapter: the reading-time estimate.
    func words(fromCharacter offset: Int) -> Int {
        let string = text.string as NSString
        let start = min(max(offset, 0), string.length)
        let rest = string.substring(from: start)
        return rest.split(whereSeparator: \.isWhitespace).count
    }
}

/// EPUB chapter blocks → one attributed string → screen pages.
///
/// Pagination is TextKit 1's multi-container layout: one text storage and one
/// layout manager, with a container per page of the page's own size. The layout
/// manager fills each container in turn, so a page range never splits a line and
/// the ranges meet exactly.
enum BookChapterPaginator {
    /// A page count no real chapter reaches; a page size that fits no line would
    /// otherwise turn one page per character.
    static let maximumPages = 4000

    static func layout(
        source: EPUBChapterSource,
        style: BookPageStyle,
        pageSize: CGSize
    ) -> BookChapterPages {
        let built = attributedText(source: source, style: style)
        return BookChapterPages(
            text: built.text,
            pageRanges: pageRanges(text: built.text, pageSize: pageSize),
            blockStarts: built.blockStarts
        )
    }

    // MARK: - Text

    /// The chapter as one attributed string, with each top-level block's start.
    /// Markdown structure the EPUB converter emits (headings, list items, quotes,
    /// fences, tables) becomes role-styled paragraphs; inline emphasis keeps its
    /// emphasis but loses its markers.
    static func attributedText(
        source: EPUBChapterSource,
        style: BookPageStyle
    ) -> (text: NSAttributedString, blockStarts: [Int]) {
        let text = NSMutableAttributedString()
        let lines = source.markdown.components(separatedBy: "\n")
        var blockStarts: [Int] = []
        blockStarts.reserveCapacity(source.blocks.count)
        for (index, block) in source.blocks.enumerated() {
            blockStarts.append(text.length)
            let start = max(block.markdownStartLine - 1, 0)
            let end = index + 1 < source.blocks.count
                ? min(max(source.blocks[index + 1].markdownStartLine - 1, start), lines.count)
                : lines.count
            guard start < end else { continue }
            append(kind: block.kind, lines: Array(lines[start..<end]), style: style, to: text)
        }
        trimTrailingBlankLines(text)
        return (text, blockStarts.map { min($0, text.length) })
    }

    private static func append(
        kind: EPUBChapterBlock.Kind,
        lines: [String],
        style: BookPageStyle,
        to text: NSMutableAttributedString
    ) {
        switch kind {
        case .code:
            appendCode(lines, style: style, to: text)
        case .table:
            appendTable(lines, style: style, to: text)
        case .thematicBreak:
            appendParagraph(
                inline("", font: style.font(for: .caption), style: style),
                role: .caption,
                style: style,
                to: text
            )
            appendRule(style: style, to: text)
        case .text:
            appendText(lines, style: style, to: text)
        }
    }

    /// `text` blocks carry headings, list items, quotes and paragraphs, one per
    /// line: the EPUB converter writes each `<p>` as its own line.
    private static func appendText(_ lines: [String], style: BookPageStyle, to text: NSMutableAttributedString) {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let heading = headingLine(trimmed) {
                let font = style.font(for: .heading(level: heading.level))
                appendParagraph(
                    inline(heading.text, font: font, style: style),
                    role: .heading(level: heading.level),
                    style: style,
                    to: text
                )
                continue
            }
            if trimmed.hasPrefix(">") {
                var content = Substring(trimmed)
                while content.hasPrefix(">") {
                    content = content.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                }
                guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                appendParagraph(
                    inline(String(content), font: style.font(for: .quote), style: style),
                    role: .quote,
                    style: style,
                    to: text
                )
                continue
            }
            if let item = listItemLine(line) {
                let font = style.font(for: .listItem(depth: item.depth))
                let content = NSMutableAttributedString(string: "\(item.marker)\t")
                content.append(inline(item.text, font: font, style: style))
                appendParagraph(content, role: .listItem(depth: item.depth), style: style, to: text)
                continue
            }
            appendParagraph(
                inline(trimmed, font: style.font(for: .body), style: style),
                role: .body,
                style: style,
                to: text
            )
        }
    }

    private static func appendCode(_ lines: [String], style: BookPageStyle, to text: NSMutableAttributedString) {
        let font = style.font(for: .code)
        for line in lines {
            // The block starts on its first code line; the fences around it are
            // the only lines that are not code.
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { continue }
            appendParagraph(
                NSAttributedString(string: line, attributes: [
                    .font: font,
                    .foregroundColor: style.textColor,
                ]),
                role: .code,
                style: style,
                to: text
            )
        }
    }

    /// A table keeps its rows and drops its pipes and the alignment row: the
    /// page shows the cells, monospaced, one row per line.
    private static func appendTable(_ lines: [String], style: BookPageStyle, to text: NSMutableAttributedString) {
        let font = style.font(for: .table)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let cells = trimmed
                .split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
            guard cells.contains(where: { !$0.isEmpty }) else { continue }
            if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) { continue }
            appendParagraph(
                NSAttributedString(string: cells.joined(separator: "   "), attributes: [
                    .font: font,
                    .foregroundColor: style.textColor,
                ]),
                role: .table,
                style: style,
                to: text
            )
        }
    }

    private static func appendRule(style: BookPageStyle, to text: NSMutableAttributedString) {
        appendParagraph(
            NSAttributedString(string: "· · ·", attributes: [
                .font: style.font(for: .caption),
                .foregroundColor: style.secondaryTextColor,
            ]),
            role: .caption,
            style: style,
            to: text
        )
    }

    private static func appendParagraph(
        _ content: NSAttributedString,
        role: BookPageStyle.Role,
        style: BookPageStyle,
        to text: NSMutableAttributedString
    ) {
        let start = text.length
        text.append(content)
        text.append(NSAttributedString(string: "\n"))
        let range = NSRange(location: start, length: text.length - start)
        let attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: style.paragraphStyle(for: role),
            .font: style.font(for: role),
            .foregroundColor: style.color(for: role),
        ]
        text.addAttributes(attributes, range: range)
    }

    private static func trimTrailingBlankLines(_ text: NSMutableAttributedString) {
        while text.length > 0 {
            let last = (text.string as NSString).substring(from: text.length - 1)
            guard last == "\n" || last == " " else { return }
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
    }

    // MARK: - Lines

    private static func headingLine(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (hashes.count, title)
    }

    /// `- item`, `1. item`, indented two spaces per level by the converter.
    private static func listItemLine(_ line: String) -> (depth: Int, marker: String, text: String)? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }
        let depth = min(indent / 2, 3)
        if first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            guard after.hasPrefix(" ") else { return nil }
            let body = after.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return nil }
            return (depth, "•", body)
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(".") || rest.dropFirst(digits.count).hasPrefix(")") else {
            return nil
        }
        let afterMarker = rest.dropFirst(digits.count + 1)
        guard afterMarker.hasPrefix(" ") else { return nil }
        let body = afterMarker.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return (depth, "\(digits).", body)
    }

    // MARK: - Inline

    /// Markdown emphasis, code spans, strikethrough and link text without their
    /// markers. A link keeps its words and its colour; opening a book's own links
    /// is a later slice.
    static func inline(_ source: String, font: UIFont, style: BookPageStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var literal = ""
        var isBold = false
        var isItalic = false
        var isCode = false
        var isStrike = false
        var isLink = false

        func currentAttributes() -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: inlineFont(font, bold: isBold, italic: isItalic, code: isCode, style: style),
            ]
            if isLink { attributes[.foregroundColor] = style.secondaryTextColor }
            if isStrike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return attributes
        }

        func flush() {
            guard !literal.isEmpty else { return }
            result.append(NSAttributedString(string: literal, attributes: currentAttributes()))
            literal = ""
        }

        var index = source.startIndex
        while index < source.endIndex {
            let rest = source[index...]
            let character = source[index]
            if character == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex {
                    literal.append(source[next])
                    index = source.index(after: next)
                    continue
                }
                literal.append(character)
                index = next
                continue
            }
            if rest.hasPrefix("**") {
                flush()
                isBold.toggle()
                index = source.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("~~") {
                flush()
                isStrike.toggle()
                index = source.index(index, offsetBy: 2)
                continue
            }
            if character == "*" || character == "_" {
                flush()
                isItalic.toggle()
                index = source.index(after: index)
                continue
            }
            if character == "`" {
                flush()
                isCode.toggle()
                index = source.index(after: index)
                continue
            }
            if character == "[", let link = linkText(in: rest) {
                flush()
                isLink = true
                literal = link.text
                flush()
                isLink = false
                index = source.index(index, offsetBy: link.length)
                continue
            }
            literal.append(character)
            index = source.index(after: index)
        }
        flush()
        return result
    }

    /// `[text](target)` at the start of `source`: the words, and how many
    /// characters the whole link spans.
    private static func linkText(in source: Substring) -> (text: String, length: Int)? {
        guard source.hasPrefix("["),
              let close = source.firstIndex(of: "]") else { return nil }
        let afterBracket = source.index(after: close)
        guard afterBracket < source.endIndex, source[afterBracket] == "(",
              let paren = source[afterBracket...].firstIndex(of: ")") else { return nil }
        let text = String(source[source.index(after: source.startIndex)..<close])
        guard !text.isEmpty else { return nil }
        let length = source.distance(from: source.startIndex, to: source.index(after: paren))
        return (text, length)
    }

    private static func inlineFont(
        _ base: UIFont,
        bold: Bool,
        italic: Bool,
        code: Bool,
        style: BookPageStyle
    ) -> UIFont {
        if code { return style.font(for: .code) }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    // MARK: - Pages

    /// Slices `text` into page-sized containers. TextKit fills each container
    /// from where the last one stopped, so the ranges are contiguous and a break
    /// always falls between two lines.
    static func pageRanges(text: NSAttributedString, pageSize: CGSize) -> [NSRange] {
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }
        let size = CGSize(width: max(pageSize.width, 1), height: max(pageSize.height, 1))
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var ranges: [NSRange] = []
        var location = 0
        while location < text.length, ranges.count < maximumPages {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
            container.lineBreakMode = .byWordWrapping
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            let glyphRange = layoutManager.glyphRange(for: container)
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            // A container narrower than one line reports nothing; one character
            // per page still ends, where a loop on the layout would not.
            let end = min(max(characters.location + characters.length, location + 1), text.length)
            ranges.append(NSRange(location: location, length: end - location))
            location = end
        }
        if location < text.length, let last = ranges.popLast() {
            ranges.append(NSRange(location: last.location, length: text.length - last.location))
        }
        return ranges
    }
}
