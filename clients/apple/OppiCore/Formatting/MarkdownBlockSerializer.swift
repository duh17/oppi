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
                let content = blocks.map(serializeBlock).joined(separator: "\n")
                return "- \(content)"
            }.joined(separator: "\n")

        case .orderedList(let start, let items):
            return items.enumerated().map { i, blocks in
                let content = blocks.map(serializeBlock).joined(separator: "\n")
                return "\(start + i). \(content)"
            }.joined(separator: "\n")

        case .taskList(let items):
            return items.map { item in
                let check = item.checked ? "[x]" : "[ ]"
                let content = item.content.map(serializeBlock).joined(separator: "\n")
                return "- \(check) \(content)"
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

    /// Escapes the characters CommonMark would otherwise read as syntax in a
    /// plain text run: a backslash (so `\\` and `\(...\)` keep their
    /// backslashes instead of cmark eating them as escapes), `<` and `>` (so
    /// a literal `<tag>` and a stray `>` at the start of a line stay text
    /// instead of becoming raw HTML or a block quote), `*` (so a line Org's
    /// own parser decided was not a heading, such as an indented `  * item`,
    /// does not turn back into a Markdown bullet once serialized — Org
    /// already extracted every real `*bold*` span into its own node, so a
    /// literal `*` left in text is one Org itself read as plain), and `]`
    /// immediately before `(` (so `[x](y)` typed as prose does not become a
    /// link: escaping the closing bracket alone is enough to keep the `[`
    /// from ever finding a match, and, unlike escaping `[` itself, never
    /// writes the literal two bytes `\[` — the fast-path guard that skips
    /// `CMarkFastParser`'s math-protection scan for an ordinary document
    /// checks the whole source for exactly that sequence, so writing it
    /// anywhere turns every line of even an unrelated large file through that
    /// scan). A lone `[` or `]` is left alone: on its own, without a `(`
    /// right after, CommonMark never reads it as a link either. Backticks are
    /// left alone too: Org has no code-span syntax of its own, and this is
    /// the one Markdown feature Org prose gets "for free" that is worth
    /// keeping.
    private static func escapeText(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 == 0x5C || $0 == 0x3C || $0 == 0x3E || $0 == 0x2A })
            || text.contains("](") else {
            return text
        }
        var escaped = ""
        escaped.reserveCapacity(text.count + 4)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "\\", "<", ">", "*":
                escaped.append("\\")
                escaped.append(character)
            case "]":
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "(" {
                    escaped.append("\\]")
                } else {
                    escaped.append(character)
                }
            default:
                escaped.append(character)
            }
            index = text.index(after: index)
        }
        return escaped
    }
}
