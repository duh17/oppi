import Foundation

/// Serialize a `[MarkdownBlock]` AST back to markdown text.
///
/// Used by `OrgToMarkdownConverter` to produce markdown text that can be fed
/// into the existing `MarkdownContentViewWrapper` rendering pipeline. The output
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

    private static func serializeInlines(_ inlines: [MarkdownInline]) -> String {
        inlines.map(serializeInline).joined()
    }

    private static func serializeInline(_ inline: MarkdownInline) -> String {
        switch inline {
        case .text(let string):
            return string
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
                return "[\(text)](\(dest))"
            }
            return text
        case .image(let alt, let source):
            return "![\(alt)](\(source ?? ""))"
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
}
