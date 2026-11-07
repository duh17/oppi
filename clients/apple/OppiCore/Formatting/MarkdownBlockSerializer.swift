import Foundation

/// Serialize a `[MarkdownBlock]` AST back to markdown text.
///
/// Used by `OrgToMarkdownConverter` to produce markdown text that can be fed
/// into the existing `AssistantMarkdownContentView` rendering pipeline. The output
/// doesn't need to be perfectly formatted — it just needs to parse back to the
/// same AST through CommonMark.
enum MarkdownBlockSerializer {

    static func serialize(_ blocks: [MarkdownBlock]) -> String {
        blocks.map(serializeBlock).joined(separator: "\n\n")
    }

    // MARK: - Block serialization

    private static func serializeBlock(_ block: MarkdownBlock) -> String {
        switch block {
        case .heading(let level, let inlines):
            let prefix = String(repeating: "#", count: level)
            return "\(prefix) \(serializeInlines(inlines))"

        case .paragraph(let inlines):
            return serializeInlines(inlines)

        case .blockQuote(let children):
            return children
                .map { serializeBlock($0) }
                .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" } }
                .joined(separator: "\n")

        case .codeBlock(let language, let code):
            let fence = "```"
            let lang = language ?? ""
            // Trim trailing newline from code to avoid blank line before closing fence.
            let trimmed = code.hasSuffix("\n") ? String(code.dropLast()) : code
            return "\(fence)\(lang)\n\(trimmed)\n\(fence)"

        case .unorderedList(let items):
            return items.map { blocks in
                let content = blocks.map(serializeBlock).joined(separator: "\n\n")
                return indentContinuation(content, firstLinePrefix: "- ")
            }.joined(separator: "\n")

        case .orderedList(let start, let items):
            return items.enumerated().map { i, blocks in
                let content = blocks.map(serializeBlock).joined(separator: "\n\n")
                return indentContinuation(content, firstLinePrefix: "\(start + i). ")
            }.joined(separator: "\n")

        case .taskList(let items):
            return items.map { item in
                // GFM's task-list extension only recognizes `[ ]`/`[x]`: Org's
                // `[-]` (partial) goes out as an ordinary unchecked box, with
                // `isPartial` carried by a marker inline (`OrgToMarkdownConverter`),
                // not by the box character.
                let check = item.checked ? "[x]" : "[ ]"
                let content = item.content.map(serializeBlock).joined(separator: "\n\n")
                // CommonMark measures a list item's continuation indent from its
                // marker (`- `), not from the checkbox text that follows: the
                // checkbox is ordinary paragraph content to the block parser,
                // which only looks for it after structure is already decided.
                // Indenting to the checkbox's own width over-indents by 4+
                // spaces, turning a nested list into an indented code block.
                return indentContinuation(content, firstLinePrefix: "- \(check) ", indentWidth: 2)
            }.joined(separator: "\n")

        case .thematicBreak:
            return "---"

        case .table(let headers, let rows):
            guard !headers.isEmpty else { return "" }
            let headerRow = "| " + headers.map { serializeInlines($0) }.joined(separator: " | ") + " |"
            let separator = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
            let dataRows = rows.map { row in
                "| " + row.map { serializeInlines($0) }.joined(separator: " | ") + " |"
            }
            return ([headerRow, separator] + dataRows).joined(separator: "\n")

        case .htmlBlock(let html):
            return html
        }
    }

    /// Prefixes a list item's serialized content with its marker, indenting
    /// every line after the first by the marker's width: a line that is not
    /// indented to its item's content column reads as a sibling block, not
    /// part of the item, once CommonMark parses it — the one thing a nested
    /// list or a continuation paragraph inside an item needs to round-trip.
    private static func indentContinuation(_ content: String, firstLinePrefix prefix: String, indentWidth: Int? = nil) -> String {
        // Fast path: a single-block, single-line item (the overwhelming
        // majority) needs no per-line work at all.
        guard content.contains("\n") else { return prefix + content }
        let indent = String(repeating: " ", count: indentWidth ?? prefix.count)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().map { index, line in
            index == 0 ? "\(prefix)\(line)" : (line.isEmpty ? "" : "\(indent)\(line)")
        }.joined(separator: "\n")
    }

    // MARK: - Inline serialization

    static func serializeInlines(_ inlines: [MarkdownInline]) -> String {
        inlines.map(serializeInline).joined()
    }

    private static func serializeInline(_ inline: MarkdownInline) -> String {
        switch inline {
        case .text(let string):
            return escapeText(string)
        case .emphasis(let children):
            return "*\(serializeInlines(children))*"
        case .strong(let children):
            return "**\(serializeInlines(children))**"
        case .code(let code):
            // Use double backticks if code contains a backtick.
            if code.contains("`") {
                return "`` \(code) ``"
            }
            return "`\(code)`"
        case .link(let children, let destination):
            let text = serializeInlines(children)
            if let dest = destination {
                // A path with spaces or parentheses only parses as one
                // destination inside angle brackets, where `<` and `>` need
                // a backslash.
                guard dest.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) else {
                    return "[\(text)](\(dest))"
                }
                let bracketed = dest
                    .replacingOccurrences(of: "<", with: "\\<")
                    .replacingOccurrences(of: ">", with: "\\>")
                return "[\(text)](<\(bracketed)>)"
            }
            return text
        case .image(let alt, let source):
            return "![\(alt)](\(source ?? ""))"
        case .videoEmbed(let embed):
            if let label = embed.reference.visibleLabel, label != embed.reference.target {
                return "![[\(embed.reference.target)|\(label)]]"
            }
            return "![[\(embed.reference.target)]]"
        case .audioEmbed(let embed):
            if let label = embed.reference.visibleLabel, label != embed.reference.target {
                return "![[\(embed.reference.target)|\(label)]]"
            }
            return "![[\(embed.reference.target)]]"
        case .usdzEmbed(let embed):
            if let label = embed.reference.visibleLabel, label != embed.reference.target {
                return "![[\(embed.reference.target)|\(label)]]"
            }
            return "![[\(embed.reference.target)]]"
        case .softBreak:
            return "\n"
        case .hardBreak:
            return "  \n"
        case .html(let raw):
            return raw
        case .strikethrough(let children):
            return "~~\(serializeInlines(children))~~"
        }
    }

    /// Escapes what CommonMark would otherwise read as syntax in a plain text
    /// run, so the text renders as the characters it holds:
    ///
    /// - A backslash, `<`, `>` and `*` get a backslash: `\\` keeps both
    ///   backslashes, a literal `<tag>` or a leading `>` stays text instead of
    ///   raw HTML or a block quote, and a `*` Org already read as plain (it
    ///   pulled every real `*bold*` span into its own node) never turns back
    ///   into emphasis or a bullet.
    /// - `]` right before `(` or `:` becomes the entity `&#93;`, so `[x](y)`
    ///   typed as prose is no link and a `[x]: y` line no link definition that
    ///   cmark would swallow. A backslash would not do: the reader's math
    ///   support reads `\]` as a display-math delimiter and shows it.
    /// - Math goes out untouched: `\(…\)`, `\[…\]`, `$…$` and `$$…$$` are
    ///   Org's LaTeX fragments and the reader's math syntax alike, and an
    ///   escape inside one would change the TeX.
    ///
    /// Backticks are left alone: Org has no code-span syntax of its own, and a
    /// Markdown code span is worth keeping in Org prose.
    private static func escapeText(_ text: String) -> String {
        // Fast path, without copying the text: most runs hold nothing to escape.
        var previous: UInt8 = 0
        let hasEscape = text.utf8.contains { byte in
            defer { previous = byte }
            switch byte {
            case 0x5C, 0x3C, 0x3E, 0x2A: return true
            case 0x28, 0x3A: return previous == 0x5D
            default: return false
            }
        }
        guard hasEscape else { return text }
        let bytes = Array(text.utf8)
        var escaped: [UInt8] = []
        escaped.reserveCapacity(bytes.count + 8)
        var index = 0
        while index < bytes.count {
            if let end = mathEnd(bytes, at: index) {
                escaped.append(contentsOf: bytes[index..<end])
                index = end
                continue
            }
            if needsEscape(bytes, at: index) {
                if bytes[index] == 0x5D {
                    escaped.append(contentsOf: "&#93;".utf8)
                } else {
                    escaped.append(0x5C)
                    escaped.append(bytes[index])
                }
            } else {
                escaped.append(bytes[index])
            }
            index += 1
        }
        return String(decoding: escaped, as: UTF8.self)
    }

    /// Whether the byte at `index` is one `escapeText` rewrites, math aside.
    @inline(__always)
    private static func needsEscape(_ bytes: [UInt8], at index: Int) -> Bool {
        switch bytes[index] {
        case 0x5C, 0x3C, 0x3E, 0x2A: // \ < > *
            return true
        case 0x5D: // ]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            return next == 0x28 || next == 0x3A // ( :
        default:
            return false
        }
    }

    /// The end of the math fragment starting at `index` (`\(…\)`, `\[…\]`,
    /// `$$…$$`, `$…$`), or nil when none starts there or it never closes. A
    /// single `$` pair needs non-space text just inside both signs, as Org and
    /// TeX require, so prose such as "$5 and $10" is not read as math.
    private static func mathEnd(_ bytes: [UInt8], at index: Int) -> Int? {
        func find(_ closer: [UInt8], from start: Int) -> Int? {
            var cursor = start
            while cursor + closer.count <= bytes.count {
                if bytes[cursor] == closer[0], bytes[cursor..<(cursor + closer.count)].elementsEqual(closer) {
                    return cursor
                }
                cursor += 1
            }
            return nil
        }
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

        let next = index + 1 < bytes.count ? bytes[index + 1] : 0
        switch bytes[index] {
        case 0x5C where next == 0x28: // \(
            return find([0x5C, 0x29], from: index + 2).map { $0 + 2 }
        case 0x5C where next == 0x5B: // \[
            return find([0x5C, 0x5D], from: index + 2).map { $0 + 2 }
        case 0x24 where next == 0x24: // $$
            return find([0x24, 0x24], from: index + 2).map { $0 + 2 }
        case 0x24: // $
            guard next != 0, !isSpace(next), let close = find([0x24], from: index + 2),
                  !isSpace(bytes[close - 1]) else { return nil }
            return close + 1
        default:
            return nil
        }
    }
}
