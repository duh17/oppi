import cmark_gfm
import cmark_gfm_extensions

/// Protects assistant-style inline math delimiters from CommonMark backslash
/// escaping. cmark-gfm treats `\(` as an escaped `(`, which erases the only
/// signal the timeline renderer has that the parenthesized text is LaTeX.
private enum MarkdownMathDelimiterRewriter {
    private static let inlineOpenSentinel = "\u{E000}"
    private static let inlineCloseSentinel = "\u{E001}"

    static func sourceForCommonMarkParsing(_ source: String) -> String {
        guard source.contains(#"\("#), source.contains(#"\)"#) else { return source }

        var result = ""
        result.reserveCapacity(source.utf8.count)
        var inFence = false
        var lineStart = source.startIndex

        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            let includesNewline = lineEnd < source.endIndex
            let line = String(source[lineStart ..< lineEnd])
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isFenceLine(trimmed) {
                result += line
                inFence.toggle()
            } else if !inFence, !isIndentedCodeLine(line) {
                result += replacingInlineMathDelimitersOutsideCodeSpans(in: line)
            } else {
                result += line
            }

            if includesNewline {
                result += "\n"
                lineStart = source.index(after: lineEnd)
            } else {
                lineStart = lineEnd
            }
        }

        return result
    }

    static func restoreCommonMarkText(_ text: String) -> String {
        text
            .replacingOccurrences(of: inlineOpenSentinel, with: #"\("#)
            .replacingOccurrences(of: inlineCloseSentinel, with: #"\)"#)
    }

    private static func replacingInlineMathDelimitersOutsideCodeSpans(in line: String) -> String {
        var result = ""
        result.reserveCapacity(line.utf8.count)
        var cursor = line.startIndex
        var inCode = false

        while cursor < line.endIndex {
            if line[cursor] == "`", !isEscaped(at: cursor, in: line) {
                inCode.toggle()
                result.append(line[cursor])
                cursor = line.index(after: cursor)
                continue
            }

            if !inCode, matches(#"\("#, in: line, at: cursor) {
                result += inlineOpenSentinel
                cursor = line.index(cursor, offsetBy: 2)
                continue
            }

            if !inCode, matches(#"\)"#, in: line, at: cursor) {
                result += inlineCloseSentinel
                cursor = line.index(cursor, offsetBy: 2)
                continue
            }

            result.append(line[cursor])
            cursor = line.index(after: cursor)
        }

        return result
    }

    private static func matches(_ needle: String, in source: String, at index: String.Index) -> Bool {
        source[index...].hasPrefix(needle)
    }

    private static func isEscaped(at index: String.Index, in source: String) -> Bool {
        guard index > source.startIndex else { return false }
        var slashCount = 0
        var cursor = source.index(before: index)
        while source[cursor] == "\\" {
            slashCount += 1
            guard cursor > source.startIndex else { break }
            cursor = source.index(before: cursor)
        }
        return slashCount % 2 == 1
    }

    private static func isFenceLine(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }
}

/// Fast CommonMark parser using the C cmark-gfm library directly.
///
/// Parses directly through cmark-gfm and converts to `[MarkdownBlock]`.
///
/// Used for the non-streaming full-document parse path where source
/// positions are not needed.
private struct CMarkParsedDocument {
    let root: UnsafeMutablePointer<cmark_node>
    let wikiLinkRestoration: MarkdownWikiLinkRewriter.Restoration
}

/// Shared parser setup: register GFM extensions, create parser, attach extensions, feed source.
private func cmarkParsedDocument(_ source: String) -> CMarkParsedDocument? {
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

    // Math owns its sentinels independently. Wiki-link protection then
    // carries per-parse restoration context through CMark conversion.
    let mathSource = MarkdownMathDelimiterRewriter.sourceForCommonMarkParsing(source)
    let parserInput = MarkdownWikiLinkRewriter.parserInput(mathSource)
    parserInput.source.withCString { ptr in
        cmark_parser_feed(parser, ptr, parserInput.source.utf8.count)
    }

    let doc = cmark_parser_finish(parser)
    cmark_parser_free(parser)
    guard let doc else { return nil }
    return CMarkParsedDocument(root: doc, wikiLinkRestoration: parserInput.restoration)
}

nonisolated func parseCommonMarkFast(_ source: String) -> [MarkdownBlock] {
    guard let parsed = cmarkParsedDocument(source) else { return [] }
    defer { cmark_node_free(parsed.root) }

    var blocks: [MarkdownBlock] = []
    var child = cmark_node_first_child(parsed.root)
    while let node = child {
        if let block = convertCMarkBlock(node, restoration: parsed.wikiLinkRestoration) {
            blocks.append(block)
        }
        child = cmark_node_next(node)
    }
    return blocks
}

nonisolated func parseCommonMarkFastLocated(_ source: String) -> [LocatedMarkdownBlock] {
    guard let parsed = cmarkParsedDocument(source) else { return [] }
    defer { cmark_node_free(parsed.root) }

    var blocks: [LocatedMarkdownBlock] = []
    var child = cmark_node_first_child(parsed.root)
    while let node = child {
        if let block = convertCMarkBlock(node, restoration: parsed.wikiLinkRestoration) {
            blocks.append(LocatedMarkdownBlock(
                block: block,
                lineRange: sourceLineRange(for: node)
            ))
        }
        child = cmark_node_next(node)
    }
    return blocks
}

/// Fast parse with last block start line — used by the streaming incremental path.
nonisolated func parseCommonMarkFastWithLastLine(_ source: String) -> (blocks: [MarkdownBlock], lastBlockStartLine: Int) {
    guard let parsed = cmarkParsedDocument(source) else { return ([], 1) }
    defer { cmark_node_free(parsed.root) }

    var blocks: [MarkdownBlock] = []
    var childCount = 0
    var lastNode: UnsafeMutablePointer<cmark_node>?
    var child = cmark_node_first_child(parsed.root)
    while let node = child {
        if let block = convertCMarkBlock(node, restoration: parsed.wikiLinkRestoration) {
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

private func sourceLineRange(for node: UnsafeMutablePointer<cmark_node>) -> ClosedRange<Int>? {
    let start = Int(cmark_node_get_start_line(node))
    let end = Int(cmark_node_get_end_line(node))
    guard start > 0 else { return nil }

    if cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK {
        var fenceLength: Int32 = 0
        var fenceOffset: Int32 = 0
        var fenceCharacter: CChar = 0
        cmark_node_get_fenced(node, &fenceLength, &fenceOffset, &fenceCharacter)
        if fenceLength > 0 {
            let rawCode = cmark_node_get_literal(node).flatMap { String(cString: $0) } ?? ""
            let code = rawCode.hasSuffix("\n") ? String(rawCode.dropLast()) : rawCode
            let lineCount = max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count)
            let codeStart = start + 1
            return codeStart...(codeStart + lineCount - 1)
        }
    }

    return start...max(start, end)
}

private func convertCMarkBlock(
    _ node: UnsafeMutablePointer<cmark_node>,
    restoration: MarkdownWikiLinkRewriter.Restoration
) -> MarkdownBlock? {
    let nodeType = cmark_node_get_type(node)

    switch nodeType {
    case CMARK_NODE_PARAGRAPH:
        return .paragraph(convertCMarkInlines(node, restoration: restoration))

    case CMARK_NODE_HEADING:
        let level = Int(cmark_node_get_heading_level(node))
        return .heading(level: level, inlines: convertCMarkInlines(node, restoration: restoration))

    case CMARK_NODE_CODE_BLOCK:
        let rawCode = cmark_node_get_literal(node).flatMap { String(cString: $0) } ?? ""
        let restoredCode = restoration.restore(rawCode)
        var code = restoredCode.hasSuffix("\n") ? String(restoredCode.dropLast()) : restoredCode
        let rawInfo = cmark_node_get_fence_info(node).flatMap { String(cString: $0) }
        let restoredInfo = rawInfo.map(restoration.restore)
        let language = (restoredInfo?.isEmpty == false) ? restoredInfo : nil
        // Strip trailing inner fences from 4+ backtick code blocks.
        var fl: Int32 = 0; var fo: Int32 = 0; var fc: CChar = 0
        cmark_node_get_fenced(node, &fl, &fo, &fc)
        if fl > 3 { code = stripTrailingInnerFence(code) }
        return .codeBlock(language: language, code: code)

    case CMARK_NODE_BLOCK_QUOTE:
        var children: [MarkdownBlock] = []
        var child = cmark_node_first_child(node)
        while let c = child {
            if let block = convertCMarkBlock(c, restoration: restoration) {
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
                if let block = convertCMarkBlock(c, restoration: restoration) {
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
            return .orderedList(start: Int(cmark_node_get_list_start(node)), items)
        } else {
            return .unorderedList(items)
        }

    case CMARK_NODE_THEMATIC_BREAK:
        return .thematicBreak

    case CMARK_NODE_HTML_BLOCK:
        let html = cmark_node_get_literal(node).flatMap { String(cString: $0) } ?? ""
        return .htmlBlock(restoration.restore(html))

    default:
        // Check for table extension node.
        if let typeStr = cmark_node_get_type_string(node) {
            let type = String(cString: typeStr)
            if type == "table" {
                return convertCMarkTable(node, restoration: restoration)
            }
        }
        return nil
    }
}

// MARK: - Table Conversion

private func convertCMarkTable(
    _ node: UnsafeMutablePointer<cmark_node>,
    restoration: MarkdownWikiLinkRewriter.Restoration
) -> MarkdownBlock {
    var headers: [[MarkdownInline]] = []
    var rows: [[[MarkdownInline]]] = []

    var rowNode = cmark_node_first_child(node)
    var isHeader = true
    while let row = rowNode {
        var cells: [[MarkdownInline]] = []
        var cellNode = cmark_node_first_child(row)
        while let cell = cellNode {
            cells.append(convertCMarkInlines(cell, restoration: restoration))
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

private func extractCMarkPlainText(
    _ node: UnsafeMutablePointer<cmark_node>,
    restoration: MarkdownWikiLinkRewriter.Restoration
) -> String {
    var result = ""
    var child = cmark_node_first_child(node)
    while let c = child {
        let childType = cmark_node_get_type(c)
        if childType == CMARK_NODE_TEXT || childType == CMARK_NODE_CODE {
            if let literal = cmark_node_get_literal(c) {
                result += restoration.restore(String(cString: literal))
            }
        } else if childType == CMARK_NODE_SOFTBREAK || childType == CMARK_NODE_LINEBREAK {
            result += "\n"
        } else {
            // Recurse into inline containers (emphasis, strong, link, etc.)
            result += extractCMarkPlainText(c, restoration: restoration)
        }
        child = cmark_node_next(c)
    }
    return result
}

// MARK: - Inline Conversion

private func convertCMarkInlines(
    _ parentNode: UnsafeMutablePointer<cmark_node>,
    restoration: MarkdownWikiLinkRewriter.Restoration
) -> [MarkdownInline] {
    var inlines: [MarkdownInline] = []
    var child = cmark_node_first_child(parentNode)
    while let node = child {
        if let inline = convertCMarkInline(node, restoration: restoration) {
            inlines.append(inline)
        }
        child = cmark_node_next(node)
    }
    return inlines
}

private func convertCMarkInline(
    _ node: UnsafeMutablePointer<cmark_node>,
    restoration: MarkdownWikiLinkRewriter.Restoration
) -> MarkdownInline? {
    let nodeType = cmark_node_get_type(node)

    switch nodeType {
    case CMARK_NODE_TEXT:
        guard let literal = cmark_node_get_literal(node) else { return nil }
        let mathRestored = MarkdownMathDelimiterRewriter.restoreCommonMarkText(String(cString: literal))
        return .text(restoration.restore(mathRestored))

    case CMARK_NODE_EMPH:
        return .emphasis(convertCMarkInlines(node, restoration: restoration))

    case CMARK_NODE_STRONG:
        return .strong(convertCMarkInlines(node, restoration: restoration))

    case CMARK_NODE_CODE:
        guard let literal = cmark_node_get_literal(node) else { return nil }
        return .code(restoration.restore(String(cString: literal)))

    case CMARK_NODE_LINK:
        let rawDestination = cmark_node_get_url(node).flatMap { String(cString: $0) }
        let destination = rawDestination.map { restoration.restore($0) }
        return .link(
            children: convertCMarkInlines(node, restoration: restoration),
            destination: destination
        )

    case CMARK_NODE_IMAGE:
        let alt = extractCMarkPlainText(node, restoration: restoration)
        let rawSource = cmark_node_get_url(node).flatMap { String(cString: $0) }
        let source = rawSource.map { restoration.restore($0) }
        return .image(alt: alt, source: source)

    case CMARK_NODE_SOFTBREAK:
        return .softBreak

    case CMARK_NODE_LINEBREAK:
        return .hardBreak

    case CMARK_NODE_HTML_INLINE:
        guard let literal = cmark_node_get_literal(node) else { return nil }
        return .html(restoration.restore(String(cString: literal)))

    default:
        // Check for strikethrough extension.
        if let typeStr = cmark_node_get_type_string(node) {
            let type = String(cString: typeStr)
            if type == "strikethrough" {
                return .strikethrough(convertCMarkInlines(node, restoration: restoration))
            }
        }
        return nil
    }
}

// MARK: - Inner Fence Cleanup

/// Strip a trailing fence-like line from code block content produced by 4+
/// backtick/tilde fences. Preserves the trailing fence when there's a matching
/// opening fence elsewhere in the content (e.g., markdown tutorials).
private func stripTrailingInnerFence(_ code: String) -> String {
    guard let lastNewline = code.lastIndex(of: "\n") else {
        return isFenceLine(code) ? "" : code
    }
    let lastLine = code[code.index(after: lastNewline)...]
    guard isFenceLine(lastLine) else { return code }

    // Check if any earlier line starts with 3+ backticks/tildes (an opening
    // fence). If so, the trailing fence is paired content — preserve it.
    let prefix = code[..<lastNewline]
    for line in prefix.split(separator: "\n", omittingEmptySubsequences: false) {
        if startsWithFenceChars(line) { return code }
    }

    return String(prefix)
}

/// True if `line` starts with 3+ backticks or tildes (may have info string after).
/// Used to detect opening fences like "```python" inside code content.
private func startsWithFenceChars<S: StringProtocol>(_ line: S) -> Bool {
    let trimmed = line.drop(while: { $0 == " " })
    guard let fenceChar = trimmed.first,
          fenceChar == "`" || fenceChar == "~" else { return false }
    var count = 0
    for char in trimmed {
        if char == fenceChar { count += 1 }
        else { break }
    }
    return count >= 3
}

/// True if `line` consists ONLY of 3+ backticks or tildes (optional whitespace).
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
