import Foundation

/// Normalizes a few near-miss table markups into GFM before cmark-gfm runs.
///
/// Kept small on purpose: delimiter rows with org `+` or unicode dashes, and
/// simple HTML tables. Fenced code is left untouched. Colspan/rowspan and
/// nested tables stay raw HTML.
enum MarkdownTableMarkupRewriter {
    private static let dashLike: Set<Character> = ["-", "–", "—", "─", "−"]
    private static let maxHTMLTableBytes = 32 * 1024

    static func rewrite(_ source: String, rewriteHTMLTables: Bool = true) -> String {
        let delimited = normalizeDelimiterRows(source)
        // HTML conversion changes line count. Located/streaming parses skip it
        // so review-comment anchors stay mapped to the original source.
        guard rewriteHTMLTables else { return delimited }
        return replaceHTMLTables(inUnfencedRegionsOf: delimited)
    }

    // MARK: - Delimiter rows

    private static func normalizeDelimiterRows(_ source: String) -> String {
        guard source.contains("|") else { return source }

        var openFence: (character: Character, count: Int)?
        var awaitingDelimiter = false
        var inTable = false
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices {
            let line = lines[index]
            if let fence = openFence {
                if isClosingFence(line, matching: fence) {
                    openFence = nil
                }
                awaitingDelimiter = false
                inTable = false
                continue
            }
            if let fence = openingFence(in: line) {
                openFence = fence
                awaitingDelimiter = false
                inTable = false
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                awaitingDelimiter = false
                inTable = false
                continue
            }
            // Only the delimiter immediately under a header is rewritten.
            // Later dash-only or org `+` rows stay literal body cells.
            if !inTable, awaitingDelimiter, let rewritten = normalizedDelimiterRow(line) {
                lines[index] = rewritten
                awaitingDelimiter = false
                inTable = true
                continue
            }
            if inTable {
                continue
            }
            awaitingDelimiter = line.contains("|") && normalizedDelimiterRow(line) == nil
        }
        return lines.joined(separator: "\n")
    }

    private static func normalizedDelimiterRow(_ line: String) -> String? {
        guard line.contains("|") else { return nil }
        let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cells.isEmpty, cells.allSatisfy(isDelimiterCell) else { return nil }

        return String(line.map { character in
            if character == "+" { return "|" }
            if dashLike.contains(character) { return "-" }
            return character
        })
    }

    private static func isDelimiterCell(_ cell: String) -> Bool {
        guard !cell.isEmpty else { return false }
        var sawDash = false
        for character in cell {
            if dashLike.contains(character) || character == "+" {
                sawDash = true
                continue
            }
            if character == ":" { continue }
            return false
        }
        return sawDash
    }

    // MARK: - HTML tables

    private static func replaceHTMLTables(inUnfencedRegionsOf source: String) -> String {
        guard source.range(of: "<table", options: .caseInsensitive) != nil else {
            return source
        }

        var result = ""
        result.reserveCapacity(source.utf8.count)
        var openFence: (character: Character, count: Int)?
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
                if isClosingFence(text, matching: fence) {
                    flush(transform: false)
                    openFence = nil
                }
                continue
            }
            if let fence = openingFence(in: text) {
                flush(transform: true)
                openFence = fence
                buffer += text + suffix
                continue
            }
            buffer += text + suffix
        }
        flush(transform: openFence == nil)
        return result
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

    private static func cellMarkdown(_ html: String) -> String {
        var text = html
        text = replace(tag: "br", in: text, with: " ")
        text = wrapSimpleTag("code", in: text, with: "`")
        text = wrapSimpleTag("strong", in: text, with: "**")
        text = wrapSimpleTag("b", in: text, with: "**")
        text = wrapSimpleTag("em", in: text, with: "*")
        text = wrapSimpleTag("i", in: text, with: "*")
        text = replaceAnchors(in: text)
        text = stripTags(text)
        text = unescapeHTMLEntities(text)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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

    private static func replace(tag: String, in html: String, with replacement: String) -> String {
        var remaining = html[...]
        var result = ""
        while let open = rangeOfOpenTag(tag, in: remaining) {
            result += remaining[..<open.lowerBound]
            let afterOpen = remaining[open.upperBound...]
            guard let tagEnd = afterOpen.firstIndex(of: ">") else {
                result += remaining[open.lowerBound...]
                return result
            }
            result += replacement
            remaining = afterOpen[afterOpen.index(after: tagEnd)...]
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

    private static func stripTags(_ html: String) -> String {
        var result = ""
        var skipping = false
        for character in html {
            if character == "<" {
                skipping = true
                continue
            }
            if character == ">" {
                skipping = false
                continue
            }
            if !skipping {
                result.append(character)
            }
        }
        return result
    }

    private static func unescapeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    // MARK: - Fences

    private static func openingFence(in line: String) -> (character: Character, count: Int)? {
        let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        return (first, count)
    }

    private static func isClosingFence(
        _ line: String,
        matching fence: (character: Character, count: Int)
    ) -> Bool {
        let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        let count = trimmed.prefix(while: { $0 == fence.character }).count
        guard count >= fence.count else { return false }
        return trimmed.dropFirst(count).allSatisfy { $0.isWhitespace }
    }
}
