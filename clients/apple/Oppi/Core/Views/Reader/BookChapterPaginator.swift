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
    /// The text area each page was cut at. A distance saved in points is read
    /// back through its block at this measure.
    let pageSize: CGSize
    /// How tall each page's own text is. A page rarely fills its area exactly,
    /// and the cell clips here so the paragraph a page continues draws nothing
    /// in the gap below its last line.
    let pageHeights: [CGFloat]
    /// True when the chapter runs past the page cap: the pages stop where the
    /// cap stopped them, and the last one is not the chapter's end.
    let continues: Bool

    init(
        text: NSAttributedString,
        pageRanges: [NSRange],
        blockStarts: [Int],
        pageSize: CGSize,
        pageHeights: [CGFloat] = [],
        continues: Bool = false
    ) {
        self.text = text
        self.pageRanges = pageRanges
        self.blockStarts = blockStarts
        self.pageSize = pageSize
        self.pageHeights = pageHeights
        self.continues = continues
    }
}

extension BookChapterPages {
    var pageCount: Int { max(pageRanges.count, 1) }

    var isEmpty: Bool { text.length == 0 }

    /// The text one page draws: the page's own characters, with the whitespace
    /// the previous page ended on removed, and then the rest of the paragraph the
    /// page breaks in.
    ///
    /// TextKit never justifies the last line of a container. A page's last line
    /// is nearly always mid-paragraph, and it used to end the container, so every
    /// page bottom came out ragged. The cell lays this text out in a container
    /// taller than the page and clips the overflow, which puts the page's last
    /// line inside the paragraph where it is justified like the lines above it.
    /// Only the paragraph is continued, so a page that really does end a
    /// paragraph is left alone.
    func pageText(at index: Int) -> NSAttributedString {
        let slice = NSMutableAttributedString(attributedString: pageSlice(at: index))
        let range = pageRanges.indices.contains(index) ? pageRanges[index] : NSRange(location: 0, length: 0)
        let end = NSMaxRange(range)
        guard slice.length > 0, end > range.location, end < text.length else { return slice }
        let string = text.string as NSString
        // A page that ends a paragraph is left alone: there is nothing after its
        // last line to set it apart. TextKit can stop the page either side of the
        // paragraph's own line break, so both ends are checked.
        guard string.substring(with: NSRange(location: end - 1, length: 1)) != "\n",
              string.substring(with: NSRange(location: end, length: 1)) != "\n"
        else { return slice }
        var stop = end
        while stop < text.length,
              string.substring(with: NSRange(location: stop, length: 1)) != "\n",
              stop - end < Self.pageContinuationLength {
            stop += 1
        }
        guard stop > end else { return slice }
        slice.append(text.attributedSubstring(from: NSRange(location: end, length: stop - end)))
        return slice
    }

    /// The characters the page itself shows: what a screen reader reads, and what
    /// the page's position is measured in.
    func pageLabel(at index: Int) -> String {
        pageSlice(at: index).string
    }

    /// How tall the page's own text is, when the pages were cut at it.
    func contentHeight(at index: Int) -> CGFloat? {
        guard pageHeights.indices.contains(index), pageHeights[index] > 0 else { return nil }
        return pageHeights[index]
    }

    /// How much of the paragraph after a page is laid out behind the clip. A
    /// phone's line is about 40 characters, so this fills several lines with room
    /// to spare and costs one paragraph's layout per visible page.
    private static let pageContinuationLength = 400

    /// The page's own characters, without the whitespace the previous page ended
    /// on.
    private func pageSlice(at index: Int) -> NSAttributedString {
        guard pageRanges.indices.contains(index) else { return NSAttributedString() }
        let range = pageRanges[index]
        guard range.length > 0, NSMaxRange(range) <= text.length else { return NSAttributedString() }
        let slice = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        let whitespace = CharacterSet(charactersIn: " \t\n")
        while slice.length > 0 {
            let first = (slice.string as NSString).substring(with: NSRange(location: 0, length: 1))
            guard first.rangeOfCharacter(from: whitespace) != nil else { break }
            slice.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        return slice
    }

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
    func storedPosition(forCharacter offset: Int) -> (blockOrdinal: Int, offset: Double) {
        guard !blockStarts.isEmpty else { return (0, 0) }
        var ordinal = 0
        for (index, start) in blockStarts.enumerated() where start <= offset {
            ordinal = index
        }
        return (ordinal, Double(max(offset - blockStarts[ordinal], 0)))
    }

    /// The character a stored position names, in whichever unit it was saved.
    /// A distance in points is the scrolling chapter's y inside the block, so it
    /// is measured back through the block's own laid-out height: the position
    /// lands on the line it was reading, not on a character count that happens
    /// to be smaller than the block.
    @MainActor
    func characterOffset(
        forBlockOrdinal ordinal: Int,
        offset: Double = 0,
        unit: EPUBReadingPosition.Unit = .characters
    ) -> Int {
        guard !blockStarts.isEmpty else { return 0 }
        let (start, end) = blockRange(at: ordinal)
        switch unit {
        case .characters:
            let advance = max(0, Int(offset.rounded(.down)))
            return min(start + advance, end)
        case .points:
            guard let block = BookBlockMeasure.measure(self, at: ordinal) else { return start }
            return min(start + block.character(atPoint: CGFloat(offset)), end)
        }
    }

    /// The point distance the scrolling chapter needs for a character inside a
    /// block: the top of the line that character is on, measured in the block.
    @MainActor
    func pointOffset(forBlockOrdinal ordinal: Int, character: Int) -> Double {
        let (start, end) = blockRange(at: ordinal)
        guard let block = BookBlockMeasure.measure(self, at: ordinal) else { return 0 }
        return Double(block.point(atCharacter: min(max(character, start), end) - start))
    }

    /// The characters a block spans: its start, and the exclusive end. A block
    /// with no text of its own ends where it starts.
    func blockRange(at ordinal: Int) -> (start: Int, end: Int) {
        guard !blockStarts.isEmpty else { return (0, 0) }
        let clamped = min(max(ordinal, 0), blockStarts.count - 1)
        let start = min(max(blockStarts[clamped], 0), max(text.length - 1, 0))
        let end = clamped + 1 < blockStarts.count
            ? min(max(blockStarts[clamped + 1], start), max(text.length - 1, start))
            : max(text.length - 1, start)
        return (start, end)
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
@MainActor
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
        let cut = pageRanges(text: built.text, pageSize: pageSize)
        return BookChapterPages(
            text: built.text,
            pageRanges: cut.ranges,
            blockStarts: built.blockStarts,
            pageSize: pageSize,
            pageHeights: cut.heights,
            continues: cut.continues
        )
    }

    /// A paper-only change re-inks the pages instead of re-cutting them: the type
    /// did not move, so the ranges still stand and nothing is laid out twice.
    static func reink(
        _ pages: BookChapterPages,
        source: EPUBChapterSource,
        style: BookPageStyle
    ) -> BookChapterPages {
        let built = attributedText(source: source, style: style)
        guard built.text.length == pages.text.length else { return pages }
        return BookChapterPages(
            text: built.text,
            pageRanges: pages.pageRanges,
            blockStarts: built.blockStarts,
            pageSize: pages.pageSize,
            pageHeights: pages.pageHeights,
            continues: pages.continues
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
            let blockLines = blockLines(at: index, of: source, lines: lines)
            guard !blockLines.isEmpty else { continue }
            append(kind: block.kind, lines: Array(blockLines), style: style, to: text)
        }
        trimTrailingBlankLines(text)
        return (text, blockStarts.map { min($0, text.length) })
    }

    /// One top-level block's text in the page's typography. A position saved in
    /// characters converts into points through the block it names, and this is
    /// the type that measurement is made in.
    static func styledBlockText(
        source: EPUBChapterSource,
        ordinal: Int,
        style: BookPageStyle
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        guard source.blocks.indices.contains(ordinal) else { return text }
        let lines = blockLines(at: ordinal, of: source, lines: source.markdown.components(separatedBy: "\n"))
        guard !lines.isEmpty else { return text }
        append(kind: source.blocks[ordinal].kind, lines: Array(lines), style: style, to: text)
        trimTrailingBlankLines(text)
        return text
    }

    /// The Markdown lines one top-level block spans: its first line through the
    /// line before the next block's.
    private static func blockLines(
        at index: Int,
        of source: EPUBChapterSource,
        lines: [String]
    ) -> ArraySlice<String> {
        guard source.blocks.indices.contains(index) else { return [] }
        let start = max(source.blocks[index].markdownStartLine - 1, 0)
        let end = index + 1 < source.blocks.count
            ? min(max(source.blocks[index + 1].markdownStartLine - 1, start), lines.count)
            : lines.count
        guard start < end, start < lines.count else { return [] }
        return lines[start..<end]
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
        text.addAttributes(
            [
                .paragraphStyle: style.paragraphStyle(for: role),
                .font: style.font(for: role),
            ],
            range: range
        )
        // A run that named its own ink keeps it: a link on the page carries the
        // paper's link colour instead of the paragraph's body ink.
        let ink = style.color(for: role)
        text.enumerateAttribute(.foregroundColor, in: range, options: []) { value, runRange, _ in
            guard value == nil else { return }
            text.addAttribute(.foregroundColor, value: ink, range: runRange)
        }
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
            if isLink { attributes[.foregroundColor] = style.linkColor }
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
    ///
    /// A chapter that runs past `maximumPages` stops there. The rest is not
    /// folded into the last page: a page holding megabytes of text is one cell
    /// and one VoiceOver label, and the caller says the chapter continues.
    static func pageRanges(
        text: NSAttributedString,
        pageSize: CGSize,
        maximumPages: Int = maximumPages
    ) -> (ranges: [NSRange], heights: [CGFloat], continues: Bool) {
        guard text.length > 0 else { return ([NSRange(location: 0, length: 0)], [pageSize.height], false) }
        let size = CGSize(width: max(pageSize.width, 1), height: max(pageSize.height, 1))
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var ranges: [NSRange] = []
        var heights: [CGFloat] = []
        var location = 0
        while location < text.length, ranges.count < maximumPages {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
            container.lineBreakMode = .byWordWrapping
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            // Where the page's own text ends: the cell clips here, so a page whose
            // last line stops short of its area shows no gap.
            let used = layoutManager.usedRect(for: container).height
            heights.append(used > 0 ? min(used, size.height) : size.height)
            let glyphRange = layoutManager.glyphRange(for: container)
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            // A container narrower than one line reports nothing; one character
            // per page still ends, where a loop on the layout would not.
            let end = min(max(characters.location + characters.length, location + 1), text.length)
            ranges.append(NSRange(location: location, length: end - location))
            location = end
        }
        return (ranges, heights, location < text.length)
    }
}

/// One block laid out on its own at the pages' measure: the height a distance in
/// points is measured against, and the line a character sits on. The scrolling
/// chapter and the pages count the same block's distance in different units, and
/// this is what turns one into the other.
@MainActor
struct BookBlockMeasure {
    /// TextKit's layout manager does not keep its text storage alive: without
    /// this the block's layout is thrown away with the storage and every glyph
    /// index is invalid.
    private let storage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let container: NSTextContainer
    private let characterCount: Int
    let height: CGFloat

    /// One block of a chapter, at the width its pages were cut at.
    static func measure(_ pages: BookChapterPages, at ordinal: Int) -> Self? {
        let (start, end) = pages.blockRange(at: ordinal)
        guard end > start else { return nil }
        let slice = pages.text.attributedSubstring(from: NSRange(location: start, length: end - start))
        return measure(slice, width: pages.pageSize.width)
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> Self? {
        guard text.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        // A finite, very tall container: TextKit's layout manager miscounts
        // glyphs in a container whose height is unbounded.
        let container = NSTextContainer(size: CGSize(width: max(width, 1), height: 100_000))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: text.length))
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        // The block's height is the bottom of its last line. A container this
        // tall answers its own size for `usedRect(for:)`, which would put every
        // distance past the end of the text.
        var lastLine = NSRange(location: 0, length: 0)
        let height = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.numberOfGlyphs - 1,
            effectiveRange: &lastLine
        ).maxY
        guard height > 0 else { return nil }
        return Self(
            storage: storage,
            layoutManager: layoutManager,
            container: container,
            characterCount: text.length,
            height: height
        )
    }

    /// The character at a distance down the block: the first character of the
    /// line that distance falls in.
    func character(atPoint y: CGFloat) -> Int {
        let clamped = min(max(y, 0), max(height - 1, 0))
        let glyph = layoutManager.glyphIndex(for: CGPoint(x: 0, y: clamped), in: container)
        let safeGlyph = min(glyph, layoutManager.numberOfGlyphs - 1)
        return layoutManager.characterIndexForGlyph(at: safeGlyph)
    }

    /// The top of the line a character is on, in points down the block.
    func point(atCharacter character: Int) -> CGFloat {
        let clamped = min(max(character, 0), max(characterCount - 1, 0))
        let glyph = min(
            layoutManager.glyphIndexForCharacter(at: clamped),
            layoutManager.numberOfGlyphs - 1
        )
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }
}
