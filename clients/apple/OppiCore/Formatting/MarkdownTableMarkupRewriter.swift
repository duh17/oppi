import Foundation

/// Normalizes a few near-miss table markups into GFM before cmark-gfm runs.
///
/// Kept small on purpose: delimiter rows with org `+` or unicode dashes, and
/// simple HTML tables. Fenced code is left untouched. Colspan/rowspan and
/// nested tables stay raw HTML.
enum MarkdownTableMarkupRewriter {
    private static let maxHTMLTableBytes = 32 * 1024

    static func rewrite(_ source: String, rewriteHTMLTables: Bool = true) -> String {
        let delimited = normalizeDelimiterRows(source)
        // HTML conversion changes line count. Located/streaming parses skip it
        // so review-comment anchors stay mapped to the original source.
        guard rewriteHTMLTables else { return delimited }
        return replaceHTMLTables(inUnfencedRegionsOf: delimited)
    }

    // MARK: - Delimiter rows

    /// Rewrites the delimiter row right under a header row when it uses an org
    /// `+` or a Unicode dash (`–`, `—`, `─`, `−`). Later dash-only or `+` rows
    /// stay literal body cells, and fenced code is left alone.
    ///
    /// Works on bytes, a line at a time: a line is read past its first
    /// non-blank byte only when that byte can start a delimiter row (`|`, `+`,
    /// `-`, `:`, or `E2`, the lead byte of every dash above) or a fence, and the
    /// line above only for such a row. Returns `source` itself when no row
    /// changes.
    private static func normalizeDelimiterRows(_ source: String) -> String {
        var edits: [(range: Range<Int>, replacement: [UInt8])] = []
        UTF8Search.withBytes(of: source) { bytes in
            guard let base = bytes.baseAddress else { return }
            var openFence: (byte: UInt8, count: Int)?
            // The non-blank line above in this run of lines, and whether it was
            // a delimiter row; nil after a blank line or a fence.
            var previous: (range: Range<Int>, isDelimiterRow: Bool)?
            var inTable = false
            var lineStart = 0
            while lineStart < bytes.count {
                let newline = memchr(base + lineStart, 0x0A, bytes.count - lineStart)
                    .map { UnsafeRawPointer(base).distance(to: $0) } ?? bytes.count
                defer { lineStart = newline + 1 }
                var end = newline
                if end > lineStart, bytes[end - 1] == 0x0D { end -= 1 }
                var first = lineStart
                while first < end, bytes[first] == 0x20 || bytes[first] == 0x09 { first += 1 }
                let line = UnsafeBufferPointer(rebasing: bytes[first ..< end])

                if let fence = openFence {
                    if MarkdownFence.closes(line, byte: fence.byte, count: fence.count) { openFence = nil }
                    previous = nil
                    inTable = false
                    continue
                }
                if let fence = MarkdownFence.opening(line) {
                    openFence = (fence.byte, fence.count)
                    previous = nil
                    inTable = false
                    continue
                }
                guard let lead = line.first else {
                    previous = nil
                    inTable = false
                    continue
                }
                if inTable { continue }
                let needsRewrite = isDelimiterRowLead(lead) ? delimiterRowNeedsRewrite(line) : nil
                if let needsRewrite, let above = previous, !above.isDelimiterRow,
                   memchr(base + above.range.lowerBound, 0x7C, above.range.count) != nil {
                    if needsRewrite { edits.append((first ..< end, rewrittenDelimiterRow(line))) }
                    inTable = true
                    continue
                }
                previous = (lineStart ..< end, needsRewrite != nil)
            }
        }
        guard !edits.isEmpty else { return source }
        return UTF8Search.withBytes(of: source) { bytes in
            var result: [UInt8] = []
            result.reserveCapacity(bytes.count)
            var copied = 0
            for edit in edits {
                result.append(contentsOf: bytes[copied ..< edit.range.lowerBound])
                result.append(contentsOf: edit.replacement)
                copied = edit.range.upperBound
            }
            result.append(contentsOf: bytes[copied...])
            return String(decoding: result, as: UTF8.self)
        }
    }

    private static func isDelimiterRowLead(_ byte: UInt8) -> Bool {
        byte == 0x7C || byte == 0x2B || byte == 0x2D || byte == 0x3A || byte == 0xE2
    }

    /// The length of the dash at `index`: 1 for `-`, 3 for `–`, `—`, `─` or
    /// `−`, nil for anything else.
    private static func dashLength(_ line: UnsafeBufferPointer<UInt8>, at index: Int) -> Int? {
        if line[index] == 0x2D { return 1 }
        guard line[index] == 0xE2, index + 2 < line.count else { return nil }
        switch (line[index + 1], line[index + 2]) {
        case (0x80, 0x93), (0x80, 0x94), (0x94, 0x80), (0x88, 0x92): return 3
        default: return nil
        }
    }

    /// Nil unless `line` is a delimiter row: cells split by `|`, at least one
    /// not blank, each of those only dashes, `+` and `:` (blanks around them,
    /// not between) with at least one dash or `+`. Otherwise whether it holds a
    /// `+` or a Unicode dash.
    private static func delimiterRowNeedsRewrite(_ line: UnsafeBufferPointer<UInt8>) -> Bool? {
        var hasPipe = false
        var hasCell = false
        var cellHasContent = false
        var cellHasDash = false
        var cellHasTrailingBlank = false
        var needsRewrite = false
        var index = 0
        while index < line.count {
            let byte = line[index]
            if byte == 0x7C {
                if cellHasContent, !cellHasDash { return nil }
                hasCell = hasCell || cellHasContent
                hasPipe = true
                cellHasContent = false
                cellHasDash = false
                cellHasTrailingBlank = false
            } else if byte == 0x20 || byte == 0x09 {
                cellHasTrailingBlank = cellHasContent
            } else {
                if cellHasTrailingBlank { return nil }
                cellHasContent = true
                if byte == 0x2B {
                    cellHasDash = true
                    needsRewrite = true
                } else if byte != 0x3A {
                    guard let length = dashLength(line, at: index) else { return nil }
                    cellHasDash = true
                    needsRewrite = needsRewrite || length > 1
                    index += length - 1
                }
            }
            index += 1
        }
        if cellHasContent, !cellHasDash { return nil }
        guard hasPipe, hasCell || cellHasContent else { return nil }
        return needsRewrite
    }

    /// `line` with each `+` as `|` and each dash as `-`.
    private static func rewrittenDelimiterRow(_ line: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(line.count)
        var index = 0
        while index < line.count {
            if line[index] == 0x2B {
                result.append(0x7C)
            } else if let length = dashLength(line, at: index) {
                result.append(0x2D)
                index += length - 1
            } else {
                result.append(line[index])
            }
            index += 1
        }
        return result
    }

    // MARK: - HTML tables

    private static func replaceHTMLTables(inUnfencedRegionsOf source: String) -> String {
        guard containsTableTag(source) else { return source }

        var result = ""
        result.reserveCapacity(source.utf8.count)
        var openFence: (byte: UInt8, count: Int)?
        var buffer = ""
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        func flush(transform: Bool) {
            guard !buffer.isEmpty else { return }
            result += transform ? replaceSimpleHTMLTables(in: buffer) : buffer
            buffer.removeAll(keepingCapacity: true)
        }

        for (index, line) in lines.enumerated() {
            let text = String(line)
            let suffix = index < lines.count - 1 || source.hasSuffix("\n") ? "\n" : ""
            if let fence = openFence {
                buffer += text + suffix
                if MarkdownFence.closes(text.utf8, byte: fence.byte, count: fence.count) {
                    flush(transform: false)
                    openFence = nil
                }
                continue
            }
            if let fence = MarkdownFence.opening(text.utf8) {
                flush(transform: true)
                openFence = (fence.byte, fence.count)
                buffer += text + suffix
                continue
            }
            buffer += text + suffix
        }
        flush(transform: openFence == nil)
        return result
    }

    /// `<table` in any letter case, by bytes: a case-insensitive Foundation
    /// search cost more than parsing the whole document.
    private static func containsTableTag(_ source: String) -> Bool {
        UTF8Search.withBytes(of: source) { bytes in
            let tag: [UInt8] = Array("table".utf8)
            var index = 0
            while index < bytes.count, let base = bytes.baseAddress,
                  let open = memchr(base + index, Int32(UInt8(ascii: "<")), bytes.count - index) {
                index = UnsafeRawPointer(base).distance(to: open) + 1
                if bytes[index...].starts(with: tag, by: { $0 | 0x20 == $1 }) { return true }
            }
            return false
        }
    }

    private static func replaceSimpleHTMLTables(in source: String) -> String {
        var result = ""
        var remaining = source[...]
        while let start = remaining.range(of: "<table", options: .caseInsensitive) {
            result += remaining[..<start.lowerBound]
            let fromStart = remaining[start.lowerBound...]
            guard let end = fromStart.range(of: "</table>", options: .caseInsensitive) else {
                result += fromStart
                return result
            }
            let html = String(fromStart[..<end.upperBound])
            if html.utf8.count <= maxHTMLTableBytes, let gfm = convertHTMLTable(html) {
                appendConvertedTable(gfm, to: &result)
            } else {
                result += html
            }
            remaining = fromStart[end.upperBound...]
        }
        result += remaining
        return result
    }

    private static func convertHTMLTable(_ html: String) -> String? {
        let afterOpen = html.drop(while: { $0 != ">" }).dropFirst()
        if afterOpen.range(of: "<table", options: .caseInsensitive) != nil {
            return nil
        }
        guard let rows = taggedContents(html, tag: "tr"), !rows.isEmpty else {
            return nil
        }

        var grid: [[String]] = []
        grid.reserveCapacity(rows.count)
        for row in rows {
            guard let cells = cells(in: row), !cells.isEmpty else { return nil }
            grid.append(cells)
        }

        let columnCount = grid.map(\.count).max() ?? 0
        guard columnCount > 0 else { return nil }
        let padded = grid.map { row -> [String] in
            if row.count >= columnCount { return Array(row.prefix(columnCount)) }
            return row + Array(repeating: "", count: columnCount - row.count)
        }

        let headers = padded[0]
        let body = Array(padded.dropFirst())
        var lines = [
            "| " + headers.joined(separator: " | ") + " |",
            "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |",
        ]
        lines.append(contentsOf: body.map { row in
            "| " + row.joined(separator: " | ") + " |"
        })
        return lines.joined(separator: "\n")
    }

    /// GFM tables only start a block at a line boundary. Keep converted HTML
    /// from gluing onto the previous paragraph.
    private static func appendConvertedTable(_ gfm: String, to result: inout String) {
        if !result.isEmpty, !result.hasSuffix("\n") {
            result += "\n\n"
        } else if result.hasSuffix("\n"), !result.hasSuffix("\n\n") {
            result += "\n"
        }
        result += gfm
        if !result.hasSuffix("\n") {
            result += "\n"
        }
    }

    private static func cells(in row: String) -> [String]? {
        var cells: [String] = []
        var remaining = row[...]
        while true {
            let th = rangeOfOpenTag("th", in: remaining)
            let td = rangeOfOpenTag("td", in: remaining)
            let next: (tag: String, range: Range<String.Index>)?
            switch (th, td) {
            case (let th?, let td?):
                next = th.lowerBound <= td.lowerBound ? ("th", th) : ("td", td)
            case (let th?, nil):
                next = ("th", th)
            case (nil, let td?):
                next = ("td", td)
            case (nil, nil):
                next = nil
            }
            guard let next else { break }
            remaining = remaining[next.range.lowerBound...]
            guard let content = firstTaggedContent(&remaining, tag: next.tag) else {
                return nil
            }
            cells.append(cellMarkdown(content))
        }
        return cells
    }

    private static func taggedContents(_ html: String, tag: String) -> [String]? {
        var remaining = html[...]
        var result: [String] = []
        while rangeOfOpenTag(tag, in: remaining) != nil {
            guard let content = firstTaggedContent(&remaining, tag: tag) else {
                return nil
            }
            result.append(content)
        }
        return result
    }

    private static func firstTaggedContent(
        _ remaining: inout Substring,
        tag: String
    ) -> String? {
        guard let open = rangeOfOpenTag(tag, in: remaining) else {
            return nil
        }
        let afterOpen = remaining[open.upperBound...]
        guard let tagEnd = afterOpen.firstIndex(of: ">") else { return nil }
        let attributes = afterOpen[..<tagEnd]
        if attributes.range(of: "colspan", options: .caseInsensitive) != nil
            || attributes.range(of: "rowspan", options: .caseInsensitive) != nil {
            return nil
        }
        let innerStart = afterOpen.index(after: tagEnd)
        let close = "</\(tag)>"
        guard let closeRange = remaining[innerStart...].range(of: close, options: .caseInsensitive) else {
            return nil
        }
        let content = String(remaining[innerStart..<closeRange.lowerBound])
        remaining = remaining[closeRange.upperBound...]
        return content
    }

    /// One HTML cell as GFM cell text. `<b>`, `<i>`, `<code>` and `<a href>`
    /// become Markdown; `<br>` and the other tags of the inline-HTML subset
    /// (`MarkdownInlineHTML`) stay tags, which the parser pairs like any raw
    /// HTML, so a cell keeps its line breaks. Other tags are dropped, text kept.
    private static func cellMarkdown(_ html: String) -> String {
        var text = html
        text = wrapSimpleTag("code", in: text, with: "`")
        text = wrapSimpleTag("strong", in: text, with: "**")
        text = wrapSimpleTag("b", in: text, with: "**")
        text = wrapSimpleTag("em", in: text, with: "*")
        text = wrapSimpleTag("i", in: text, with: "*")
        text = replaceAnchors(in: text)
        text = stripTags(text)
        text = unescapeHTMLEntities(text)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // A line break ends the line: no blank on either side of it.
        text = text.replacingOccurrences(of: " ?<br ?/?> ?", with: "<br>", options: [.regularExpression, .caseInsensitive])
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func wrapSimpleTag(_ tag: String, in html: String, with wrap: String) -> String {
        var remaining = html[...]
        var result = ""
        while let open = rangeOfOpenTag(tag, in: remaining) {
            result += remaining[..<open.lowerBound]
            var slice = remaining[open.lowerBound...]
            guard let inner = firstTaggedContent(&slice, tag: tag) else {
                result += remaining[open.lowerBound...]
                return result
            }
            result += wrap
            result += inner
            result += wrap
            remaining = slice
        }
        result += remaining
        return result
    }

    private static func replaceAnchors(in html: String) -> String {
        var remaining = html[...]
        var result = ""
        while let open = rangeOfOpenTag("a", in: remaining) {
            result += remaining[..<open.lowerBound]
            var slice = remaining[open.lowerBound...]
            guard let tagEnd = slice.firstIndex(of: ">") else {
                result += remaining[open.lowerBound...]
                return result
            }
            let attributes = String(slice[slice.index(after: slice.startIndex)..<tagEnd])
            guard let inner = firstTaggedContent(&slice, tag: "a") else {
                result += remaining[open.lowerBound...]
                return result
            }
            if let href = hrefAttribute(in: attributes), !href.isEmpty {
                result += "[\(inner)](\(href))"
            } else {
                result += inner
            }
            remaining = slice
        }
        result += remaining
        return result
    }

    private static func hrefAttribute(in attributes: String) -> String? {
        guard let href = attributes.range(of: "href", options: .caseInsensitive),
              let equals = attributes[href.upperBound...].firstIndex(of: "=") else {
            return nil
        }
        var cursor = attributes.index(after: equals)
        while cursor < attributes.endIndex, attributes[cursor].isWhitespace {
            cursor = attributes.index(after: cursor)
        }
        guard cursor < attributes.endIndex else { return nil }
        let quote = attributes[cursor]
        if quote == "\"" || quote == "'" {
            let start = attributes.index(after: cursor)
            guard let end = attributes[start...].firstIndex(of: quote) else { return nil }
            return String(attributes[start..<end])
        }
        let end = attributes[cursor...].firstIndex(where: { $0.isWhitespace }) ?? attributes.endIndex
        return String(attributes[cursor..<end])
    }

    private static func rangeOfOpenTag(_ tag: String, in text: Substring) -> Range<String.Index>? {
        let prefix = "<\(tag)"
        var search = text
        while let range = search.range(of: prefix, options: .caseInsensitive) {
            let afterTag = search[range.upperBound...]
            if let next = afterTag.first, next == ">" || next == "/" || next.isWhitespace {
                return range
            }
            search = afterTag
        }
        return nil
    }

    /// Drops every tag but the inline-HTML subset's styles and line breaks;
    /// the text between tags stays.
    private static func stripTags(_ html: String) -> String {
        var result = ""
        var remaining = html[...]
        while let open = remaining.firstIndex(of: "<") {
            result += remaining[..<open]
            guard let close = remaining[open...].firstIndex(of: ">") else {
                remaining = remaining[remaining.endIndex...]
                break
            }
            let tag = remaining[open ... close]
            switch MarkdownInlineHTML.tag(String(tag))?.element {
            case .lineBreak?, .styled?, .strikethrough?: result += tag
            default: break
            }
            remaining = remaining[remaining.index(after: close)...]
        }
        result += remaining
        return result
    }

    /// Decodes a cell's character references in one pass. Outside a code span
    /// `&lt;`, `&gt;` and `&amp;` stay references, which cmark decodes into
    /// text: decoded here, `&lt;b&gt;` would read as a tag. Inside one, where
    /// cmark decodes nothing, they become the characters.
    private static func unescapeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var inCode = false
        var rest = text[...]
        while let index = rest.firstIndex(where: { $0 == "&" || $0 == "`" }) {
            result += rest[..<index]
            rest = rest[index...]
            if rest.first == "`" {
                inCode.toggle()
                result += "`"
                rest = rest.dropFirst()
                continue
            }
            let entities: [(String, String, Bool)] = [
                ("&nbsp;", " ", true), ("&quot;", "\"", true), ("&#39;", "'", true), ("&apos;", "'", true),
                ("&amp;", "&", inCode), ("&lt;", "<", inCode), ("&gt;", ">", inCode),
            ]
            if let (entity, character, decodes) = entities.first(where: { rest.hasPrefix($0.0) }) {
                result += decodes ? character : entity
                rest = rest.dropFirst(entity.count)
            } else {
                result += "&"
                rest = rest.dropFirst()
            }
        }
        return result + rest
    }
}
