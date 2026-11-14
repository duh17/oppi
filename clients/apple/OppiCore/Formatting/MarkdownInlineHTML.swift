import Foundation

/// Oppi's native subset of the raw HTML GitHub renders in Markdown.
///
/// cmark keeps raw HTML as nodes: one `.html` inline per tag, one `.htmlBlock`
/// per HTML block. The parser hands each inline run (a paragraph, a heading, a
/// table cell, or the children of one emphasis or link) to `pair`, which turns
/// an open and a close tag of the subset into the inline the renderers already
/// draw. The tree changes, the source does not, so every block keeps its
/// source lines for review comments and task controls.
///
/// The subset: `<b> <strong> <i> <em> <code> <s> <del> <strike> <u> <ins> <sub>
/// <sup> <kbd> <mark> <a href>`, `<br>`, a `<hr>` block, and comments, which
/// are hidden. Attributes are never read, except a link's `href`. An HTML
/// block made only of subset tags and text reads as a paragraph (`block`).
/// The parser's own pairing and `MarkdownTableMarkupRewriter`'s HTML cells use
/// the same `tag` reader.
///
/// Everything else stays literal text: any other tag (`<script>`, `<details>`,
/// `<img>`), an open tag that never closes in its run, a close tag with no open
/// one, a self-closing `<b/>`, `</br>`, an unclosed comment. Literal text hides
/// nothing; an unknown tag dropped the way a browser drops it could hide what
/// an agent wrote. A streamed run whose close tag has not arrived shows its
/// open tag literally until it does, which a full parse of the same prefix
/// shows too.
enum MarkdownInlineHTML {
    /// One tag of the subset, read from a raw HTML node.
    struct Tag: Equatable {
        enum Kind: Equatable {
            case open
            case close
            /// `<br>`, `<br/>`, `<hr>`: an element with no content.
            case void
        }

        enum Element: Equatable {
            case strong
            case emphasis
            case code
            case strikethrough
            case styled(MarkdownInlineStyle)
            case link
            case lineBreak
            case thematicBreak
        }

        /// The tag's name in lowercase: a close tag pairs with an open tag of
        /// the same name only (`</b>` does not close `<strong>`).
        let name: String
        let element: Element
        let kind: Kind
        /// `<a href="…">`'s value with entities decoded; nil for any other tag
        /// and for an `<a>` without one.
        let href: String?
    }

    /// How an HTML block reads, when it is more than literal text.
    enum BlockReading: Equatable {
        /// Only comments and `<br>`s: nothing to show. Blocks already stand
        /// apart, so a `<br>` between them (README spacing) adds nothing.
        case hidden
        /// One `<hr>`.
        case thematicBreak
        /// Text and subset tags only: the paragraph a browser shows. CommonMark
        /// starts an HTML block at a line that is one complete tag alone
        /// (`<br>`, `<kbd>`, `<a href=…>`), and runs it to a blank line.
        case paragraph([MarkdownInline])
    }

    // MARK: - Inline runs

    /// `inlines` with each pair of subset tags made into its element, `<br>`
    /// into a hard break, and comments removed. Anything else is kept as is.
    static func pair(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var output: [MarkdownInline] = []
        output.reserveCapacity(inlines.count)
        /// Open tags not yet closed, with their position in `output`.
        var open: [(tag: Tag, index: Int)] = []
        /// Just after a `<br>`, where HTML collapses the blanks that start a
        /// line. A source line break after the tag stays a second break, as on
        /// GitHub, where a comment's line breaks show too.
        var atLineStart = false

        for inline in inlines {
            if atLineStart {
                atLineStart = false
                if case .text(let text) = inline {
                    let trimmed = text.drop(while: { $0 == " " || $0 == "\t" })
                    if trimmed.isEmpty { continue }
                    if trimmed.startIndex != text.startIndex {
                        output.append(.text(String(trimmed)))
                        continue
                    }
                }
            }
            guard case .html(let raw) = inline else {
                output.append(inline)
                continue
            }
            if isComment(raw) { continue }
            guard let tag = tag(raw) else {
                output.append(inline)
                continue
            }
            switch tag.kind {
            case .void:
                guard tag.element == .lineBreak else {
                    output.append(inline)
                    continue
                }
                output.append(.hardBreak)
                atLineStart = true
            case .open:
                open.append((tag, output.count))
                output.append(inline)
            case .close:
                guard let match = open.lastIndex(where: { $0.tag.name == tag.name }) else {
                    output.append(inline)
                    continue
                }
                // Tags opened inside it and never closed stay literal inside it.
                let start = open[match].index
                let children = Array(output[(start + 1)...])
                output.removeSubrange(start...)
                output.append(contentsOf: element(open[match].tag, children: children))
                open.removeSubrange(match...)
            }
        }
        return output
    }

    private static func element(_ tag: Tag, children: [MarkdownInline]) -> [MarkdownInline] {
        switch tag.element {
        case .strong: [.strong(children)]
        case .emphasis: [.emphasis(children)]
        case .strikethrough: [.strikethrough(children)]
        case .styled(let style): [.styled(style, children)]
        // Code is one run of text: Markdown inside it reads as its text.
        case .code: [.code(plainText(from: children))]
        // An anchor without `href` (`<a name="x">`) is its text alone.
        case .link: tag.href.map { [.link(children: children, destination: $0)] } ?? children
        case .lineBreak, .thematicBreak: children
        }
    }

    /// A complete comment, which cmark only makes an inline of when it closes.
    static func isComment(_ raw: String) -> Bool {
        raw.utf8.starts(with: "<!--".utf8) && raw.utf8.reversed().starts(with: ">--".utf8)
    }

    // MARK: - Blocks

    /// How an HTML block reads, when every tag in it is of the subset and
    /// every comment closes: a rule when it is one `<hr>` (comments and `<br>`s
    /// beside it add nothing), hidden when it holds only comments and `<br>`s,
    /// and otherwise the paragraph of its text and tags. The text is HTML, not
    /// Markdown: `*x*` stays as written, character references are decoded, and
    /// white space collapses to single spaces. Nil, literal text, for a block
    /// with any other tag or declaration, an unclosed comment, or an `<hr>`
    /// beside text.
    static func block(_ html: String) -> BlockReading? {
        UTF8Search.withBytes(of: html) { bytes -> BlockReading? in
            guard let base = bytes.baseAddress else { return nil }
            var inlines: [MarkdownInline] = []
            var hasRule = false
            var hasContent = false
            var index = 0
            var textStart = 0
            func endText(at end: Int) {
                guard end > textStart else { return }
                let text = bytes[textStart ..< end]
                hasContent = hasContent || text.contains { !isWhitespace($0) }
                inlines.append(.text(String(decoding: text, as: UTF8.self)))
            }
            while index < bytes.count {
                // A `<` before anything but a tag name, `/` or `!` is text (`a < b`).
                guard bytes[index] == UInt8(ascii: "<"), index + 1 < bytes.count,
                      isLetter(bytes[index + 1]) || bytes[index + 1] == UInt8(ascii: "/")
                      || bytes[index + 1] == UInt8(ascii: "!") else {
                    index += 1
                    continue
                }
                let end: Int
                if bytes[index...].starts(with: "<!--".utf8) {
                    guard let close = memmem(base + index + 4, bytes.count - index - 4, "-->", 3) else { return nil }
                    end = UnsafeRawPointer(base).distance(to: close) + 3
                } else {
                    guard let close = memchr(base + index, Int32(UInt8(ascii: ">")), bytes.count - index),
                          let tag = tag(UnsafeBufferPointer(rebasing: bytes[index ... UnsafeRawPointer(base).distance(to: close)]))
                    else { return nil }
                    end = UnsafeRawPointer(base).distance(to: close) + 1
                    switch tag.element {
                    case .lineBreak: break
                    case .thematicBreak:
                        guard !hasRule else { return nil }
                        hasRule = true
                    default: hasContent = true
                    }
                }
                endText(at: index)
                inlines.append(.html(String(decoding: bytes[index ..< end], as: UTF8.self)))
                index = end
                textStart = end
            }
            endText(at: bytes.count)
            guard !inlines.isEmpty else { return nil }
            if hasRule { return hasContent ? nil : .thematicBreak }
            guard hasContent else { return .hidden }
            return .paragraph(pair(htmlText(inlines)))
        }
    }

    /// A block's text runs as HTML shows them: references decoded, white
    /// space collapsed, none at the block's two ends.
    private static func htmlText(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var result = inlines.map { inline -> MarkdownInline in
            guard case .text(let text) = inline else { return inline }
            let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let edges = (text.first?.isWhitespace == true ? " " : "") + collapsed
                + (text.last?.isWhitespace == true && !collapsed.isEmpty ? " " : "")
            return .text(decodeEntities(edges))
        }
        if case .text(let first)? = result.first { result[0] = .text(String(first.drop(while: { $0 == " " }))) }
        if case .text(var last)? = result.last {
            while last.hasSuffix(" ") { last.removeLast() }
            result[result.count - 1] = .text(last)
        }
        return result.filter { $0 != .text("") }
    }

    // MARK: - Tags

    /// The subset tag `raw` is, or nil for any other HTML.
    static func tag(_ raw: String) -> Tag? {
        UTF8Search.withBytes(of: raw) { tag($0) }
    }

    /// Reads one whole tag with CommonMark's raw-HTML grammar: `<name`, then
    /// attributes each after a blank (`name`, `name=value`, `name='value'`,
    /// `name="value"`), then `>` or `/>`; or `</name>`.
    private static func tag(_ bytes: UnsafeBufferPointer<UInt8>) -> Tag? {
        let count = bytes.count
        guard count >= 3, bytes[0] == UInt8(ascii: "<") else { return nil }
        var index = 1
        let isClose = bytes[index] == UInt8(ascii: "/")
        if isClose { index += 1 }
        let nameStart = index
        guard index < count, isLetter(bytes[index]) else { return nil }
        while index < count, isLetter(bytes[index]) || isDigit(bytes[index]) || bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        let name = String(decoding: bytes[nameStart ..< index].map { $0 | 0x20 }, as: UTF8.self)
        guard let element = element(named: name) else { return nil }
        let isVoid = element == .lineBreak || element == .thematicBreak

        if isClose {
            while index < count, isWhitespace(bytes[index]) { index += 1 }
            guard index == count - 1, bytes[index] == UInt8(ascii: ">"), !isVoid else { return nil }
            return Tag(name: name, element: element, kind: .close, href: nil)
        }

        var href: String?
        var selfClosing = false
        while true {
            let blankStart = index
            while index < count, isWhitespace(bytes[index]) { index += 1 }
            guard index < count else { return nil }
            if bytes[index] == UInt8(ascii: ">") {
                guard index == count - 1 else { return nil }
                break
            }
            if bytes[index] == UInt8(ascii: "/") {
                guard index == count - 2, bytes[index + 1] == UInt8(ascii: ">") else { return nil }
                selfClosing = true
                break
            }
            guard index > blankStart, isAttributeNameStart(bytes[index]) else { return nil }
            let attributeStart = index
            while index < count, isAttributeName(bytes[index]) { index += 1 }
            let attributeName = bytes[attributeStart ..< index]
            var valueRange: Range<Int>?
            var lookahead = index
            while lookahead < count, isWhitespace(bytes[lookahead]) { lookahead += 1 }
            if lookahead < count, bytes[lookahead] == UInt8(ascii: "=") {
                index = lookahead + 1
                while index < count, isWhitespace(bytes[index]) { index += 1 }
                guard index < count else { return nil }
                let quote = bytes[index]
                if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                    let valueStart = index + 1
                    index = valueStart
                    while index < count, bytes[index] != quote { index += 1 }
                    guard index < count else { return nil }
                    valueRange = valueStart ..< index
                    index += 1
                } else {
                    let valueStart = index
                    while index < count, isUnquotedValue(bytes[index]) { index += 1 }
                    guard index > valueStart else { return nil }
                    valueRange = valueStart ..< index
                }
            }
            if element == .link, href == nil,
               attributeName.elementsEqual("href".utf8, by: { $0 | 0x20 == $1 }) {
                href = valueRange.map { decodeEntities(String(decoding: bytes[$0], as: UTF8.self)) } ?? ""
            }
        }

        // `<b/>` opens nothing in HTML and closes nothing here: literal.
        if isVoid { return Tag(name: name, element: element, kind: .void, href: nil) }
        guard !selfClosing else { return nil }
        return Tag(name: name, element: element, kind: .open, href: href)
    }

    private static func element(named name: String) -> Tag.Element? {
        switch name {
        case "b", "strong": .strong
        case "i", "em": .emphasis
        case "code": .code
        case "s", "del", "strike": .strikethrough
        case "u", "ins": .styled(.underline)
        case "sub": .styled(.subscript)
        case "sup": .styled(.superscript)
        case "kbd": .styled(.keyboard)
        case "mark": .styled(.highlight)
        case "a": .link
        case "br": .lineBreak
        case "hr": .thematicBreak
        default: nil
        }
    }

    // MARK: - Bytes

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private static func isAttributeNameStart(_ byte: UInt8) -> Bool {
        isLetter(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ":")
    }

    private static func isAttributeName(_ byte: UInt8) -> Bool {
        isAttributeNameStart(byte) || isDigit(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
    }

    private static func isUnquotedValue(_ byte: UInt8) -> Bool {
        !isWhitespace(byte) && byte != UInt8(ascii: "\"") && byte != UInt8(ascii: "'") && byte != UInt8(ascii: "=")
            && byte != UInt8(ascii: "<") && byte != UInt8(ascii: ">") && byte != UInt8(ascii: "`")
    }

    /// HTML text or an attribute value with its character references decoded:
    /// the five XML names, `&nbsp;`, and numeric ones. Others stay as written.
    private static func decodeEntities(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "&")) else { return text }
        var result = ""
        var rest = text[...]
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let afterAmpersand = rest.index(after: ampersand)
            guard let semicolon = rest[afterAmpersand...].prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = rest[afterAmpersand...]
                continue
            }
            let name = rest[afterAmpersand ..< semicolon]
            if let decoded = decodeEntity(name) {
                result += decoded
            } else {
                result += rest[ampersand ... semicolon]
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        return result + rest
    }

    private static func decodeEntity(_ name: Substring) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{A0}"
        default:
            guard name.first == "#" else { return nil }
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            return value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
        }
    }
}
