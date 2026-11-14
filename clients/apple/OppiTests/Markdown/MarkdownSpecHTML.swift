import Foundation
@testable import Oppi

/// Writes Oppi's Markdown tree as HTML the way cmark-gfm's renderer does, so
/// the CommonMark and GFM spec examples can be checked against the tree the
/// renderers draw, not against cmark's own output.
///
/// The tree does not keep a list's tightness or a link's or image's title, so
/// lists always render tight and titles never appear: a spec example that
/// differs only there is a gap of the tree (`MarkdownSpecHTML.Relaxed`), not a
/// parse error. Math has no spec HTML; it renders as a `span`/`div` with
/// class `math` around its source.
enum MarkdownSpecHTML {
    static func render(_ blocks: [MarkdownBlock]) -> String {
        var out = ""
        for block in blocks { render(block, tight: false, into: &out) }
        return out
    }

    private static func render(_ block: MarkdownBlock, tight: Bool, into out: inout String) {
        switch block {
        case .heading(let level, let inlines):
            out += "<h\(level)>\(render(inlines))</h\(level)>\n"
        case .paragraph(let inlines):
            out += tight ? render(inlines) : "<p>\(render(inlines))</p>\n"
        case .blockQuote(let children):
            out += "<blockquote>\n"
            for child in children { render(child, tight: false, into: &out) }
            out += "</blockquote>\n"
        case .codeBlock(let language, let code):
            let word = language?.split(separator: " ", maxSplits: 1).first.map(String.init)
            out += word.map { "<pre><code class=\"language-\(escape($0))\">" } ?? "<pre><code>"
            // The tree drops the newline cmark keeps after the last line.
            out += escape(code.isEmpty ? code : code + "\n") + "</code></pre>\n"
        case .unorderedList(let items):
            out += "<ul>\n"
            for item in items { renderItem(item, prefix: "", into: &out) }
            out += "</ul>\n"
        case .orderedList(let start, let items):
            out += start == 1 ? "<ol>\n" : "<ol start=\"\(start)\">\n"
            for item in items { renderItem(item, prefix: "", into: &out) }
            out += "</ol>\n"
        case .taskList(let items):
            out += "<ul>\n"
            for item in items {
                let box = item.checked
                    ? "<input type=\"checkbox\" checked=\"\" disabled=\"\" /> "
                    : "<input type=\"checkbox\" disabled=\"\" /> "
                renderItem(item.content, prefix: box, into: &out)
            }
            out += "</ul>\n"
        case .thematicBreak:
            out += "<hr />\n"
        case .table(let headers, let rows, let alignments):
            func align(_ column: Int) -> String {
                guard column < alignments.count, let alignment = alignments[column] else { return "" }
                switch alignment {
                case .left: return " align=\"left\""
                case .center: return " align=\"center\""
                case .right: return " align=\"right\""
                }
            }
            out += "<table>\n<thead>\n<tr>\n"
            for (column, cell) in headers.enumerated() { out += "<th\(align(column))>\(render(cell))</th>\n" }
            out += "</tr>\n</thead>\n"
            if !rows.isEmpty {
                out += "<tbody>\n"
                for row in rows {
                    out += "<tr>\n"
                    for (column, cell) in row.enumerated() { out += "<td\(align(column))>\(render(cell))</td>\n" }
                    out += "</tr>\n"
                }
                out += "</tbody>\n"
            }
            out += "</table>\n"
        case .htmlBlock(let raw):
            out += raw
        case .math(let math, _):
            out += "<div class=\"math\">\(escape(math.source))</div>\n"
        }
    }

    private static func renderItem(_ blocks: [MarkdownBlock], prefix: String, into out: inout String) {
        out += "<li>" + prefix
        for (index, block) in blocks.enumerated() {
            if index > 0 || !isParagraph(block), !out.hasSuffix("\n") { out += "\n" }
            render(block, tight: true, into: &out)
        }
        out += "</li>\n"
    }

    private static func isParagraph(_ block: MarkdownBlock) -> Bool {
        if case .paragraph = block { return true }
        return false
    }

    static func render(_ inlines: [MarkdownInline]) -> String {
        inlines.map(render).joined()
    }

    private static func render(_ inline: MarkdownInline) -> String {
        switch inline {
        case .text(let text): escape(text)
        case .emphasis(let children): "<em>\(render(children))</em>"
        case .strong(let children): "<strong>\(render(children))</strong>"
        case .strikethrough(let children): "<del>\(render(children))</del>"
        case .styled(let style, let children): "<\(style.tag)>\(render(children))</\(style.tag)>"
        case .code(let code): "<code>\(escape(code))</code>"
        case .link(let children, let destination):
            "<a href=\"\(escapeHref(destination ?? ""))\">\(render(children))</a>"
        case .image(let alt, let source, _):
            "<img src=\"\(escapeHref(source ?? ""))\" alt=\"\(escape(alt))\" />"
        case .videoEmbed(let embed): "<video src=\"\(escape(embed.reference.target))\"></video>"
        case .audioEmbed(let embed): "<audio src=\"\(escape(embed.reference.target))\"></audio>"
        case .usdzEmbed(let embed): "<model src=\"\(escape(embed.reference.target))\"></model>"
        case .softBreak: "\n"
        case .hardBreak: "<br />\n"
        case .html(let raw): raw
        case .math(let math): "<span class=\"math\">\(escape(math.source))</span>"
        }
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text.unicodeScalars {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(character)
            }
        }
        return out
    }

    /// cmark's `houdini_escape_href`: URL-safe ASCII stays, `&` and `'` become
    /// entities, every other byte is percent-encoded.
    static func escapeHref(_ url: String) -> String {
        var out = ""
        for byte in url.utf8 {
            switch byte {
            case UInt8(ascii: "&"): out += "&amp;"
            case UInt8(ascii: "'"): out += "&#x27;"
            case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                if "-_.+!*(),%#@?=;:/$~".utf8.contains(byte) {
                    out.unicodeScalars.append(Unicode.Scalar(byte))
                } else {
                    out += String(format: "%%%02X", byte)
                }
            }
        }
        return out
    }
}

// MARK: - Normalization

extension MarkdownSpecHTML {
    /// The comparison the spec's own runner (`test/normalize.py`) makes:
    /// whitespace collapsed and dropped next to block tags (kept inside
    /// `pre`), attributes sorted, `<br />` and `<br>` alike, character
    /// references decoded and re-escaped.
    static func normalize(_ html: String) -> String {
        let tokens = tokenize(html)
        var out = ""
        var preDepth = 0
        for (index, token) in tokens.enumerated() {
            switch token {
            case .tag(let name, let isClose, _):
                if name == "pre" { preDepth += isClose ? -1 : 1 }
                out += token.normalized
            case .raw(let text):
                out += text
            case .text(let text):
                var decoded = escape(decodeReferences(text))
                guard preDepth == 0 else {
                    out += decoded
                    continue
                }
                decoded = collapseWhitespace(decoded)
                if index == 0 || tokens[index - 1].isBlockTag { decoded = String(decoded.drop { $0 == " " }) }
                if index == tokens.count - 1 || tokens[index + 1].isBlockTag {
                    while decoded.hasSuffix(" ") { decoded.removeLast() }
                }
                out += decoded
            }
        }
        return out
    }

    /// A gap of the tree, not of the parse: list tightness and link and image
    /// titles. Both sides compare equal here when that is all they differ by.
    static func relaxed(_ normalized: String) -> String {
        // Paragraphs a tight item runs together read as one, a space apart.
        var text = normalized.replacingOccurrences(of: "</p><p>", with: " ")
        for pattern in [#"</?p>"#, #" title="[^"]*""#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }

    private static let blockTags: Set<String> = [
        "article", "header", "aside", "hgroup", "blockquote", "hr", "iframe", "body", "li", "map", "button",
        "object", "canvas", "ol", "caption", "output", "col", "p", "colgroup", "pre", "dd", "progress", "div",
        "section", "dl", "table", "td", "dt", "tbody", "embed", "textarea", "fieldset", "tfoot", "figcaption",
        "th", "figure", "thead", "footer", "tr", "form", "ul", "h1", "h2", "h3", "h4", "h5", "h6", "video",
        "script", "style",
    ]

    private enum Token {
        case text(String)
        /// A comment, declaration, processing instruction or CDATA, as written.
        case raw(String)
        case tag(name: String, isClose: Bool, attributes: [(String, String?)])

        var isBlockTag: Bool {
            if case .tag(let name, _, _) = self { return MarkdownSpecHTML.blockTags.contains(name) }
            return false
        }

        var normalized: String {
            guard case .tag(let name, let isClose, let attributes) = self else { return "" }
            if isClose { return "</\(name)>" }
            let sorted = attributes.sorted { $0.0 < $1.0 }
            let rendered = sorted.map { name, value in
                " \(name)=\"\(MarkdownSpecHTML.escape(MarkdownSpecHTML.decodeReferences(value ?? "")))\""
            }
            return "<\(name)\(rendered.joined())>"
        }
    }

    private static func tokenize(_ html: String) -> [Token] {
        let chars = Array(html.unicodeScalars)
        var tokens: [Token] = []
        var text = String.UnicodeScalarView()
        var index = 0

        func flushText() {
            if !text.isEmpty { tokens.append(.text(String(text))) }
            text = String.UnicodeScalarView()
        }
        func starts(_ prefix: String, at position: Int) -> Bool {
            let p = Array(prefix.unicodeScalars)
            return position + p.count <= chars.count && Array(chars[position ..< position + p.count]) == p
        }
        func find(_ terminator: String, from position: Int) -> Int? {
            var cursor = position
            while cursor < chars.count {
                if starts(terminator, at: cursor) { return cursor + terminator.unicodeScalars.count }
                cursor += 1
            }
            return nil
        }

        while index < chars.count {
            guard chars[index] == "<" else {
                text.append(chars[index])
                index += 1
                continue
            }
            let rawEnd: Int? = if starts("<!--", at: index) {
                find("-->", from: index + 4)
            } else if starts("<![CDATA[", at: index) {
                find("]]>", from: index + 9)
            } else if starts("<?", at: index) {
                find("?>", from: index + 2)
            } else if starts("<!", at: index) {
                find(">", from: index + 2)
            } else {
                nil
            }
            if let rawEnd {
                flushText()
                tokens.append(.raw(String(String.UnicodeScalarView(chars[index ..< rawEnd]))))
                index = rawEnd
                continue
            }
            if let (token, end) = parseTag(chars, at: index) {
                flushText()
                tokens.append(token)
                index = end
                continue
            }
            text.append(chars[index])
            index += 1
        }
        flushText()
        return tokens
    }

    /// A start or end tag at `start` (`<`), or nil when the text there is not
    /// one, which leaves the `<` as text.
    private static func parseTag(_ chars: [Unicode.Scalar], at start: Int) -> (Token, Int)? {
        var index = start + 1
        let isClose = index < chars.count && chars[index] == "/"
        if isClose { index += 1 }
        guard index < chars.count, chars[index].properties.isAlphabetic, chars[index].isASCII else { return nil }
        var name = ""
        while index < chars.count, chars[index].isASCII,
              chars[index].properties.isAlphabetic || ("0" ... "9").contains(chars[index]) || chars[index] == "-" {
            name.unicodeScalars.append(chars[index])
            index += 1
        }
        var attributes: [(String, String?)] = []
        func skipSpace() { while index < chars.count, chars[index].properties.isWhitespace { index += 1 } }
        while true {
            skipSpace()
            guard index < chars.count else { return nil }
            if chars[index] == ">" { return (.tag(name: name.lowercased(), isClose: isClose, attributes: attributes), index + 1) }
            if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == ">" {
                return (.tag(name: name.lowercased(), isClose: isClose, attributes: attributes), index + 2)
            }
            guard !isClose else { return nil }
            var attribute = ""
            while index < chars.count, !chars[index].properties.isWhitespace, !"=>/\"'<".unicodeScalars.contains(chars[index]) {
                attribute.unicodeScalars.append(chars[index])
                index += 1
            }
            guard !attribute.isEmpty else { return nil }
            skipSpace()
            guard index < chars.count, chars[index] == "=" else {
                attributes.append((attribute.lowercased(), nil))
                continue
            }
            index += 1
            skipSpace()
            guard index < chars.count else { return nil }
            var value = ""
            if chars[index] == "\"" || chars[index] == "'" {
                let quote = chars[index]
                index += 1
                while index < chars.count, chars[index] != quote {
                    value.unicodeScalars.append(chars[index])
                    index += 1
                }
                guard index < chars.count else { return nil }
                index += 1
            } else {
                while index < chars.count, !chars[index].properties.isWhitespace, !"\"'=<>`".unicodeScalars.contains(chars[index]) {
                    value.unicodeScalars.append(chars[index])
                    index += 1
                }
            }
            attributes.append((attribute.lowercased(), value))
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var out = ""
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" {
                if !lastWasSpace { out += " " }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return out
    }

    /// Numeric references and the named ones the renderer writes. Other named
    /// references appear only inside raw HTML, the same on both sides.
    static func decodeReferences(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}"]
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semicolon = after.prefix(32).firstIndex(of: ";") {
                let body = after[..<semicolon]
                var decoded: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if body.hasPrefix("#") {
                    decoded = UInt32(body.dropFirst(), radix: 10).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    decoded = named[String(body)]
                }
                if let decoded {
                    out += decoded
                    rest = after[after.index(after: semicolon)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }
}
