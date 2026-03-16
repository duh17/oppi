import cmark_gfm
import cmark_gfm_extensions

/// Fast CommonMark parser using the C cmark-gfm library directly.
///
/// Bypasses the swift-markdown Swift AST layer for faster parsing.
/// Produces the same `[MarkdownBlock]` output as `parseCommonMark`.
///
/// Used for the non-streaming full-document parse path where source
/// positions are not needed.
nonisolated func parseCommonMarkFast(_ source: String) -> [MarkdownBlock] {
    // Register GFM extensions (tables, strikethrough).
    cmark_gfm_core_extensions_ensure_registered()

    let options = CMARK_OPT_DEFAULT | CMARK_OPT_SMART
    let parser = cmark_parser_new(options)
    defer { cmark_parser_free(parser) }

    // Attach table + strikethrough extensions.
    if let tableExt = cmark_find_syntax_extension("table") {
        cmark_parser_attach_syntax_extension(parser, tableExt)
    }
    if let strikeExt = cmark_find_syntax_extension("strikethrough") {
        cmark_parser_attach_syntax_extension(parser, strikeExt)
    }

    // Feed source text.
    source.withCString { ptr in
        cmark_parser_feed(parser, ptr, source.utf8.count)
    }

    guard let doc = cmark_parser_finish(parser) else { return [] }
    defer { cmark_node_free(doc) }

    var blocks: [MarkdownBlock] = []
    var child = cmark_node_first_child(doc)
    while let node = child {
        if let block = convertCMarkBlock(node) {
            blocks.append(block)
        }
        child = cmark_node_next(node)
    }
    return blocks
}

// MARK: - Block Conversion

private func convertCMarkBlock(_ node: UnsafeMutablePointer<cmark_node>) -> MarkdownBlock? {
    let nodeType = cmark_node_get_type(node)

    switch nodeType {
    case CMARK_NODE_PARAGRAPH:
        return .paragraph(convertCMarkInlines(node))

    case CMARK_NODE_HEADING:
        let level = Int(cmark_node_get_heading_level(node))
        return .heading(level: level, inlines: convertCMarkInlines(node))

    case CMARK_NODE_CODE_BLOCK:
        let rawCode = cmark_node_get_literal(node).flatMap { String(cString: $0) } ?? ""
        let code = rawCode.hasSuffix("\n") ? String(rawCode.dropLast()) : rawCode
        let lang = cmark_node_get_fence_info(node).flatMap { String(cString: $0) }
        let language = (lang?.isEmpty == false) ? lang : nil
        return .codeBlock(language: language, code: code)

    case CMARK_NODE_BLOCK_QUOTE:
        var children: [MarkdownBlock] = []
        var child = cmark_node_first_child(node)
        while let c = child {
            if let block = convertCMarkBlock(c) {
                children.append(block)
            }
            child = cmark_node_next(c)
        }
        return .blockQuote(children)

    case CMARK_NODE_LIST:
        let listType = cmark_node_get_list_type(node)
        var items: [[MarkdownBlock]] = []
        var item = cmark_node_first_child(node)
        while let itemNode = item {
            var itemBlocks: [MarkdownBlock] = []
            var itemChild = cmark_node_first_child(itemNode)
            while let c = itemChild {
                if let block = convertCMarkBlock(c) {
                    itemBlocks.append(block)
                }
                itemChild = cmark_node_next(c)
            }
            items.append(itemBlocks)
            item = cmark_node_next(itemNode)
        }
        if listType == CMARK_ORDERED_LIST {
            return .orderedList(start: 1, items)
        } else {
            return .unorderedList(items)
        }

    case CMARK_NODE_THEMATIC_BREAK:
        return .thematicBreak

    case CMARK_NODE_HTML_BLOCK:
        let html = cmark_node_get_literal(node).flatMap { String(cString: $0) } ?? ""
        return .htmlBlock(html)

    default:
        // Check for table extension node.
        if let typeStr = cmark_node_get_type_string(node) {
            let type = String(cString: typeStr)
            if type == "table" {
                return convertCMarkTable(node)
            }
        }
        return nil
    }
}

// MARK: - Table Conversion

private func convertCMarkTable(_ node: UnsafeMutablePointer<cmark_node>) -> MarkdownBlock {
    var headers: [String] = []
    var rows: [[String]] = []

    var rowNode = cmark_node_first_child(node)
    var isHeader = true
    while let row = rowNode {
        var cells: [String] = []
        var cellNode = cmark_node_first_child(row)
        while let cell = cellNode {
            cells.append(extractCMarkPlainText(cell))
            cellNode = cmark_node_next(cell)
        }
        if isHeader {
            headers = cells
            isHeader = false
        } else {
            rows.append(cells)
        }
        rowNode = cmark_node_next(row)
    }

    return .table(headers: headers, rows: rows)
}

private func extractCMarkPlainText(_ node: UnsafeMutablePointer<cmark_node>) -> String {
    var result = ""
    var child = cmark_node_first_child(node)
    while let c = child {
        let childType = cmark_node_get_type(c)
        if childType == CMARK_NODE_TEXT || childType == CMARK_NODE_CODE {
            if let literal = cmark_node_get_literal(c) {
                result += String(cString: literal)
            }
        } else if childType == CMARK_NODE_SOFTBREAK || childType == CMARK_NODE_LINEBREAK {
            result += "\n"
        } else {
            // Recurse into inline containers (emphasis, strong, link, etc.)
            result += extractCMarkPlainText(c)
        }
        child = cmark_node_next(c)
    }
    return result
}

// MARK: - Inline Conversion

private func convertCMarkInlines(_ parentNode: UnsafeMutablePointer<cmark_node>) -> [MarkdownInline] {
    var inlines: [MarkdownInline] = []
    var child = cmark_node_first_child(parentNode)
    while let node = child {
        if let inline = convertCMarkInline(node) {
            inlines.append(inline)
        }
        child = cmark_node_next(node)
    }
    return inlines
}

private func convertCMarkInline(_ node: UnsafeMutablePointer<cmark_node>) -> MarkdownInline? {
    let nodeType = cmark_node_get_type(node)

    switch nodeType {
    case CMARK_NODE_TEXT:
        guard let literal = cmark_node_get_literal(node) else { return nil }
        return .text(String(cString: literal))

    case CMARK_NODE_EMPH:
        return .emphasis(convertCMarkInlines(node))

    case CMARK_NODE_STRONG:
        return .strong(convertCMarkInlines(node))

    case CMARK_NODE_CODE:
        guard let literal = cmark_node_get_literal(node) else { return nil }
        return .code(String(cString: literal))

    case CMARK_NODE_LINK:
        let dest = cmark_node_get_url(node).flatMap { String(cString: $0) }
        return .link(children: convertCMarkInlines(node), destination: dest)

    case CMARK_NODE_IMAGE:
        let alt = extractCMarkPlainText(node)
        let source = cmark_node_get_url(node).flatMap { String(cString: $0) }
        return .image(alt: alt, source: source)

    case CMARK_NODE_SOFTBREAK:
        return .softBreak

    case CMARK_NODE_LINEBREAK:
        return .hardBreak

    case CMARK_NODE_HTML_INLINE:
        guard let literal = cmark_node_get_literal(node) else { return nil }
        return .html(String(cString: literal))

    default:
        // Check for strikethrough extension.
        if let typeStr = cmark_node_get_type_string(node) {
            let type = String(cString: typeStr)
            if type == "strikethrough" {
                return .strikethrough(convertCMarkInlines(node))
            }
        }
        return nil
    }
}
