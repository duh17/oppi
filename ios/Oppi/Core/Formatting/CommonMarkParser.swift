import Markdown

/// Parse a CommonMark string into renderable block nodes.
///
/// Uses apple/swift-markdown for parsing. Supports all CommonMark
/// block and inline elements plus GFM tables and strikethrough.
///
/// This function is intentionally nonisolated so callers can run it
/// off the main thread via `Task.detached`.
nonisolated func parseCommonMark(_ source: String) -> [MarkdownBlock] {
    let doc = Document(parsing: source)
    return doc.children.compactMap { convertBlock($0) }
}

/// Parse a CommonMark string and also return the 1-based start line of the
/// last top-level block.
///
/// Used by the streaming incremental parse path to locate the stable prefix
/// boundary without a second full parse.
///
/// - Returns: `(blocks, lastBlockStartLine)` where `lastBlockStartLine` is the
///   1-based line number of the last block, or 1 if the document has fewer
///   than 2 blocks.
nonisolated func parseCommonMarkWithLastLine(_ source: String) -> (blocks: [MarkdownBlock], lastBlockStartLine: Int) {
    let doc = Document(parsing: source)
    let children = Array(doc.children)
    let blocks = children.compactMap { convertBlock($0) }
    // Need at least 2 top-level blocks to have a finalized prefix.
    let lastLine: Int
    if children.count >= 2, let lastChild = children.last {
        lastLine = lastChild.range?.lowerBound.line ?? 1
    } else {
        lastLine = 1
    }
    return (blocks: blocks, lastBlockStartLine: lastLine)
}

// MARK: - Block Conversion

private func convertBlock(_ markup: any Markup) -> MarkdownBlock? {
    if let heading = markup as? Heading {
        return .heading(level: heading.level, inlines: convertInlines(heading))
    }
    if let paragraph = markup as? Paragraph {
        return .paragraph(convertInlines(paragraph))
    }
    if let blockQuote = markup as? BlockQuote {
        let blocks = blockQuote.children.compactMap { convertBlock($0) }
        return .blockQuote(blocks)
    }
    if let codeBlock = markup as? CodeBlock {
        // CodeBlock.code includes a trailing newline; strip it for rendering.
        let code = codeBlock.code.hasSuffix("\n")
            ? String(codeBlock.code.dropLast())
            : codeBlock.code
        let language = (codeBlock.language?.isEmpty == false) ? codeBlock.language : nil
        return .codeBlock(language: language, code: code)
    }
    if let list = markup as? UnorderedList {
        return .unorderedList(convertListItems(list))
    }
    if let list = markup as? OrderedList {
        return .orderedList(start: 1, convertListItems(list))
    }
    if markup is ThematicBreak {
        return .thematicBreak
    }
    if let table = markup as? Table {
        return convertTable(table)
    }
    if let htmlBlock = markup as? HTMLBlock {
        return .htmlBlock(htmlBlock.rawHTML)
    }
    return nil
}

/// Convert list children (ListItem nodes) into arrays of blocks.
private func convertListItems(_ list: some Markup) -> [[MarkdownBlock]] {
    list.children.compactMap { child -> [MarkdownBlock]? in
        guard let item = child as? ListItem else { return nil }
        return item.children.compactMap { convertBlock($0) }
    }
}

// MARK: - Table Conversion

private func convertTable(_ table: Table) -> MarkdownBlock {
    let headers = table.head.children.map { extractCellPlainText($0) }
    let rows: [[String]] = table.body.children.map { row in
        row.children.map { extractCellPlainText($0) }
    }
    return .table(headers: headers, rows: rows)
}

/// Recursively extract plain text from a table cell or any markup node.
private func extractCellPlainText(_ markup: any Markup) -> String {
    if let text = markup as? Text {
        return text.string
    }
    if let code = markup as? InlineCode {
        return code.code
    }
    if markup is SoftBreak || markup is LineBreak {
        return "\n"
    }
    if let link = markup as? Link {
        let label = link.children.map { extractCellPlainText($0) }.joined()
        return label.isEmpty ? link.destination ?? "" : label
    }
    if let html = markup as? InlineHTML {
        return html.rawHTML
    }
    return markup.children.map { extractCellPlainText($0) }.joined()
}

// MARK: - Inline Conversion

private func convertInlines(_ parent: some Markup) -> [MarkdownInline] {
    parent.children.compactMap { convertInline($0) }
}

private func convertInline(_ markup: any Markup) -> MarkdownInline? {
    if let text = markup as? Text {
        return .text(text.string)
    }
    if let emphasis = markup as? Emphasis {
        return .emphasis(convertInlines(emphasis))
    }
    if let strong = markup as? Strong {
        return .strong(convertInlines(strong))
    }
    if let code = markup as? InlineCode {
        return .code(code.code)
    }
    if let link = markup as? Link {
        return .link(children: convertInlines(link), destination: link.destination)
    }
    if let image = markup as? Image {
        return .image(alt: extractCellPlainText(image), source: image.source)
    }
    if markup is SoftBreak {
        return .softBreak
    }
    if markup is LineBreak {
        return .hardBreak
    }
    if let html = markup as? InlineHTML {
        return .html(html.rawHTML)
    }
    if let strike = markup as? Strikethrough {
        return .strikethrough(convertInlines(strike))
    }
    return nil
}
