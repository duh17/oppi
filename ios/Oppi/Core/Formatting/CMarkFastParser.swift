import cmark_gfm
import cmark_gfm_extensions

/// Fast CommonMark parser using the C cmark-gfm library directly.
///
/// Bypasses the swift-markdown Swift AST layer for faster parsing.
/// Produces the same `[MarkdownBlock]` output as `parseCommonMark`.
///
/// Used for the non-streaming full-document parse path where source
/// positions are not needed.
/// Shared parser setup: register GFM extensions, create parser, attach extensions, feed source.
private func cmarkParsedDocument(_ source: String) -> UnsafeMutablePointer<cmark_node>? {
    cmark_gfm_core_extensions_ensure_registered()

    let options = CMARK_OPT_DEFAULT | CMARK_OPT_SMART | CMARK_OPT_SOURCEPOS
    let parser = cmark_parser_new(options)

    // Attach table + strikethrough extensions.
    if let tableExt = cmark_find_syntax_extension("table") {
        cmark_parser_attach_syntax_extension(parser, tableExt)
    }
    if let strikeExt = cmark_find_syntax_extension("strikethrough") {
        cmark_parser_attach_syntax_extension(parser, strikeExt)
    }
    if let tasklistExt = cmark_find_syntax_extension("tasklist") {
        cmark_parser_attach_syntax_extension(parser, tasklistExt)
    }

    // Feed source text.
    source.withCString { ptr in
        cmark_parser_feed(parser, ptr, source.utf8.count)
    }

    let doc = cmark_parser_finish(parser)
    cmark_parser_free(parser)
    return doc
}

nonisolated func parseCommonMarkFast(_ source: String) -> [MarkdownBlock] {
    guard let doc = cmarkParsedDocument(source) else { return [] }
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

/// Fast parse with last block start line — used by the streaming incremental path.
nonisolated func parseCommonMarkFastWithLastLine(_ source: String) -> (blocks: [MarkdownBlock], lastBlockStartLine: Int) {
    guard let doc = cmarkParsedDocument(source) else { return ([], 1) }
    defer { cmark_node_free(doc) }

    var blocks: [MarkdownBlock] = []
    var childCount = 0
    var lastNode: UnsafeMutablePointer<cmark_node>?
    var child = cmark_node_first_child(doc)
    while let node = child {
        if let block = convertCMarkBlock(node) {
            blocks.append(block)
        }
        lastNode = node
        childCount += 1
        child = cmark_node_next(node)
    }

    let lastLine: Int
    if childCount >= 2, let last = lastNode {
        lastLine = Int(cmark_node_get_start_line(last))
    } else {
        lastLine = 1
    }
    return (blocks: blocks, lastBlockStartLine: lastLine)
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
        var code = rawCode.hasSuffix("\n") ? String(rawCode.dropLast()) : rawCode
        let lang = cmark_node_get_fence_info(node).flatMap { String(cString: $0) }
        let language = (lang?.isEmpty == false) ? lang : nil
        // Strip trailing inner fences from 4+ backtick code blocks.
        var fl: Int32 = 0; var fo: Int32 = 0; var fc: CChar = 0
        cmark_node_get_fenced(node, &fl, &fo, &fc)
        if fl > 3 { code = stripTrailingInnerFence(code) }
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
        var hasTaskItems = false
        var itemCheckedStates: [Bool?] = []

        var item = cmark_node_first_child(node)
        while let itemNode = item {
            // Check if this item is a task list item via the tasklist extension.
            var isTask = false
            if let typeStr = cmark_node_get_type_string(itemNode) {
                if String(cString: typeStr) == "tasklist" {
                    isTask = true
                    hasTaskItems = true
                }
            }
            let checked = isTask && cmark_gfm_extensions_get_tasklist_item_checked(itemNode)
            itemCheckedStates.append(isTask ? checked : nil)

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

        if hasTaskItems {
            let taskItems = zip(itemCheckedStates, items).map { state, content in
                MarkdownBlock.TaskItem(checked: state ?? false, content: content)
            }
            return .taskList(taskItems)
        } else if listType == CMARK_ORDERED_LIST {
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
    var headers: [[MarkdownInline]] = []
    var rows: [[[MarkdownInline]]] = []

    var rowNode = cmark_node_first_child(node)
    var isHeader = true
    while let row = rowNode {
        var cells: [[MarkdownInline]] = []
        var cellNode = cmark_node_first_child(row)
        while let cell = cellNode {
            cells.append(convertCMarkInlines(cell))
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

// MARK: - Inner Fence Cleanup

/// Strip a trailing fence-like line from code block content produced by 4+
/// backtick/tilde fences. Uses parity: if fence-like lines appear in pairs
/// (even count), they're legitimate content (e.g., markdown tutorials showing
/// code fences). If odd, the trailing one is a stray — strip it.
private func stripTrailingInnerFence(_ code: String) -> String {
    guard let lastNewline = code.lastIndex(of: "\n") else {
        return isFenceLine(code) ? "" : code
    }
    let lastLine = code[code.index(after: lastNewline)...]
    guard isFenceLine(lastLine) else { return code }

    // Count all fence-like lines. Even = paired content, odd = stray trailing.
    var fenceLineCount = 0
    for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
        if isFenceLine(line) { fenceLineCount += 1 }
    }
    guard fenceLineCount % 2 == 1 else { return code }

    return String(code[..<lastNewline])
}

/// True if `line` consists only of 3+ backticks or tildes (optional whitespace).
private func isFenceLine<S: StringProtocol>(_ line: S) -> Bool {
    let trimmed = line.drop(while: { $0 == " " })
    guard let fenceChar = trimmed.first,
          fenceChar == "`" || fenceChar == "~" else { return false }
    var count = 0
    for char in trimmed {
        if char == fenceChar { count += 1 }
        else if char == " " { break }
        else { return false }
    }
    return count >= 3
}
