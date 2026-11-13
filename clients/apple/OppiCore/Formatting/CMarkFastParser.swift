import cmark_gfm
import cmark_gfm_extensions
/// Puts back the wiki-link bodies the pre-pass hid from cmark.
private struct CMarkRestoration {
    let wiki: MarkdownWikiLinkRewriter.Restoration
    /// Inside a table cell, where GFM turns `\|` into `|`: hidden bodies get the same.
    var inTableCell = false

    func restore(_ text: String) -> String {
        wiki.restore(text, unescapingPipes: inTableCell)
    }

    func restore(_ math: MarkdownMath) -> MarkdownMath {
        MarkdownMath(latex: restore(math.latex), source: restore(math.source), isDisplay: math.isDisplay)
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
    let restoration: CMarkRestoration
    /// What cmark parsed, after the pre-passes: line numbers in the tree count its lines.
    let input: String
    let hasReferenceDefinitions: Bool
}

/// Marks the document root when the text defines a link reference. cmark
/// empties its reference map when it finishes, so this reads it in the last
/// step before that (`postprocess`); the streaming driver needs the answer.
nonisolated(unsafe) private let referenceDefinitionProbe: UnsafeMutablePointer<cmark_syntax_extension> = {
    let ext = cmark_syntax_extension_new("oppi_reference_probe")!
    cmark_syntax_extension_set_postprocess_func(ext) { _, parser, root in
        if let parser, let root, parser.pointee.refmap?.pointee.refs != nil {
            cmark_node_set_user_data(root, UnsafeMutableRawPointer(bitPattern: 1))
        }
        return nil
    }
    return ext
}()

/// Shared parser setup: register GFM extensions, create parser, attach extensions, feed source.
private func cmarkParsedDocument(
    _ source: String,
    rewriteHTMLTables: Bool
) -> CMarkParsedDocument? {
    cmark_gfm_core_extensions_ensure_registered()

    // Only `~~x~~` strikes through. A single tilde is everyday text in agent
    // output (`~10~20ms`, `List~int~`, Org's `~code~`), and struck-through
    // text is visible, so the single-tilde form would cross out real content.
    // No smart punctuation: it rewrote `--flag` and wiki file names
    // (`it's--done.md`) along with prose.
    let options = CMARK_OPT_DEFAULT | CMARK_OPT_SOURCEPOS | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE
    guard let parser = cmark_parser_new(options) else { return nil }

    // Math first: its block extension has to be asked before `table`.
    MarkdownMathExtension.attach(to: parser)
    if let tableExt = cmark_find_syntax_extension("table") {
        cmark_parser_attach_syntax_extension(parser, tableExt)
    }
    if let strikeExt = cmark_find_syntax_extension("strikethrough") {
        cmark_parser_attach_syntax_extension(parser, strikeExt)
    }
    if let tasklistExt = cmark_find_syntax_extension("tasklist") {
        cmark_parser_attach_syntax_extension(parser, tasklistExt)
    }
    cmark_parser_attach_syntax_extension(parser, referenceDefinitionProbe)

    // Near-miss tables become GFM first so later wiki-pipe protection and
    // cmark-gfm see ordinary delimiter rows and cells.
    let tableSource = MarkdownTableMarkupRewriter.rewrite(
        source,
        rewriteHTMLTables: rewriteHTMLTables
    )
    let parserInput = MarkdownWikiLinkRewriter.parserInput(tableSource)
    parserInput.source.withCString { ptr in
        cmark_parser_feed(parser, ptr, parserInput.source.utf8.count)
    }

    let doc = cmark_parser_finish(parser)
    cmark_parser_free(parser)
    guard let doc else { return nil }
    let hasReferenceDefinitions = cmark_node_get_user_data(doc) != nil
    return CMarkParsedDocument(
        root: doc,
        restoration: CMarkRestoration(wiki: parserInput.restoration),
        input: parserInput.source,
        hasReferenceDefinitions: hasReferenceDefinitions
    )
}

nonisolated func parseCommonMarkFast(_ source: String) -> [MarkdownBlock] {
    guard let parsed = cmarkParsedDocument(source, rewriteHTMLTables: true) else { return [] }
    defer { cmark_node_free(parsed.root) }

    var blocks: [MarkdownBlock] = []
    var child = cmark_node_first_child(parsed.root)
    while let node = child {
        if let block = convertCMarkBlock(node, restoration: parsed.restoration) {
            blocks.append(block)
        }
        child = cmark_node_next(node)
    }
    return blocks
}

nonisolated func parseCommonMarkFastLocated(_ source: String) -> [LocatedMarkdownBlock] {
    guard let parsed = cmarkParsedDocument(source, rewriteHTMLTables: false) else { return [] }
    defer { cmark_node_free(parsed.root) }

    var blocks: [LocatedMarkdownBlock] = []
    var child = cmark_node_first_child(parsed.root)
    while let node = child {
        if let block = convertCMarkBlock(node, restoration: parsed.restoration) {
            blocks.append(LocatedMarkdownBlock(
                block: block,
                lineRange: sourceLineRange(for: node)
            ))
        }
        child = cmark_node_next(node)
    }
    return blocks
}

/// The streaming driver's parse: top-level blocks with the line each starts
/// on, and what cmark knows about the end of the text.
nonisolated func parseCommonMarkFastTail(_ source: String) -> CommonMarkTailParse {
    guard let parsed = cmarkParsedDocument(source, rewriteHTMLTables: false) else {
        return CommonMarkTailParse(
            blocks: [], blockStartLines: [], blockLineRanges: [], endsInOpenBlock: false, hasReferenceDefinitions: false
        )
    }
    defer { cmark_node_free(parsed.root) }

    var blocks: [MarkdownBlock] = []
    var startLines: [Int] = []
    var lineRanges: [ClosedRange<Int>?] = []
    var lastNode: UnsafeMutablePointer<cmark_node>?
    var child = cmark_node_first_child(parsed.root)
    while let node = child {
        if let block = convertCMarkBlock(node, restoration: parsed.restoration) {
            blocks.append(block)
            startLines.append(Int(cmark_node_get_start_line(node)))
            lineRanges.append(sourceLineRange(for: node))
            lastNode = node
        }
        child = cmark_node_next(node)
    }
    return CommonMarkTailParse(
        blocks: blocks,
        blockStartLines: startLines,
        blockLineRanges: lineRanges,
        endsInOpenBlock: lastNode.map { endsInOpenFence($0, input: parsed.input) } ?? false,
        hasReferenceDefinitions: parsed.hasReferenceDefinitions
    )
}

/// Whether the text ends inside a fenced code or math block whose closing
/// line has not arrived, following the last item of a trailing list as the
/// renderer does (a block quote's code renders as quoted text). cmark keeps no
/// "closed" flag for code, so a fence counts as closed when its last line is a
/// closing fence: an unclosed fence would have ended there.
private func endsInOpenFence(_ node: UnsafeMutablePointer<cmark_node>, input: String) -> Bool {
    if let isClosed = MarkdownMathExtension.blockIsClosed(node) { return !isClosed }
    switch cmark_node_get_type(node) {
    case CMARK_NODE_LIST:
        guard let item = cmark_node_last_child(node), let last = cmark_node_last_child(item) else { return false }
        return endsInOpenFence(last, input: input)
    case CMARK_NODE_CODE_BLOCK:
        var length: Int32 = 0
        var offset: Int32 = 0
        var character: CChar = 0
        cmark_node_get_fenced(node, &length, &offset, &character)
        guard length > 0 else { return false }
        let start = Int(cmark_node_get_start_line(node))
        let end = Int(cmark_node_get_end_line(node))
        guard end > start, let line = line(end, of: input) else { return true }
        let body = line.drop { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
        let fence = body.prefix { $0 == UInt8(bitPattern: character) }
        let isClosingFence = fence.count >= Int(length)
            && body.dropFirst(fence.count).allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") }
        return !isClosingFence
    default:
        return false
    }
}

/// Line `number` (1-based) of `text`, as bytes.
private func line(_ number: Int, of text: String) -> Substring.UTF8View? {
    let utf8 = text.utf8
    var start = utf8.startIndex
    var current = 1
    while current < number {
        guard let newline = utf8[start...].firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        start = utf8.index(after: newline)
        current += 1
    }
    let end = utf8[start...].firstIndex(of: UInt8(ascii: "\n")) ?? utf8.endIndex
    return Substring(text)[start ..< end].utf8
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
    restoration: CMarkRestoration
) -> MarkdownBlock? {
    let nodeType = cmark_node_get_type(node)

    if let (math, isClosed) = MarkdownMathExtension.blockMath(node) {
        return .math(restoration.restore(math), isClosed: isClosed)
    }

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
        var itemStartLines: [Int] = []

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
            itemStartLines.append(Int(cmark_node_get_start_line(itemNode)))

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
            let taskItems = zip(zip(itemCheckedStates, itemStartLines), items).map { entry, content in
                // A plain item in a list that has tasks has no box to toggle.
                var sourceLine = entry.0 == nil || entry.1 <= 0 ? nil : entry.1
                var content = content
                // Org's `[-]` has no GFM box of its own, so the converter marks
                // it apart from the ordinary unchecked box it serializes as.
                let isPartial = takePartialMarker(from: &content)
                // Org converts to Markdown that is parsed again, so the line this
                // parse sees is not the Org file's: the converter's marker is.
                if let marked = takeSourceLineMarker(from: &content) { sourceLine = marked > 0 ? marked : nil }
                return MarkdownBlock.TaskItem(checked: entry.0 ?? false, content: content, sourceLine: sourceLine, isPartial: isPartial)
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

/// Removes the `MarkdownPartialTaskMarker` that starts a task item, when
/// present, and reports whether it was there.
private func takePartialMarker(from content: inout [MarkdownBlock]) -> Bool {
    switch content.first {
    case .paragraph(var inlines)?:
        guard case .html(let raw)? = inlines.first, MarkdownPartialTaskMarker.isPartial(in: raw) else { return false }
        inlines.removeFirst()
        if inlines.isEmpty {
            content.removeFirst()
        } else {
            content[0] = .paragraph(inlines)
        }
        return true
    case .htmlBlock(let raw)?:
        guard MarkdownPartialTaskMarker.isPartial(in: raw) else { return false }
        content.removeFirst()
        return true
    default:
        return false
    }
}

/// Removes the `MarkdownSourceLineMarker` that starts a task item, and returns
/// the line it names.
private func takeSourceLineMarker(from content: inout [MarkdownBlock]) -> Int? {
    switch content.first {
    case .paragraph(var inlines)?:
        guard case .html(let raw)? = inlines.first, let line = MarkdownSourceLineMarker.line(in: raw) else { return nil }
        inlines.removeFirst()
        if inlines.isEmpty {
            content.removeFirst()
        } else {
            content[0] = .paragraph(inlines)
        }
        return line
    case .htmlBlock(let raw)?:
        // A marker with nothing after it on its line is an HTML block.
        guard let line = MarkdownSourceLineMarker.line(in: raw) else { return nil }
        content.removeFirst()
        return line
    default:
        return nil
    }
}

// MARK: - Table Conversion

private func convertCMarkTable(
    _ node: UnsafeMutablePointer<cmark_node>,
    restoration: CMarkRestoration
) -> MarkdownBlock {
    var headers: [[MarkdownInline]] = []
    var rows: [[[MarkdownInline]]] = []

    var rowNode = cmark_node_first_child(node)
    var isHeader = true
    while let row = rowNode {
        var cells: [[MarkdownInline]] = []
        var cellNode = cmark_node_first_child(row)
        var cellRestoration = restoration
        cellRestoration.inTableCell = true
        while let cell = cellNode {
            cells.append(convertCMarkInlines(cell, restoration: cellRestoration))
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
    restoration: CMarkRestoration
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
    restoration: CMarkRestoration
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
    restoration: CMarkRestoration
) -> MarkdownInline? {
    let nodeType = cmark_node_get_type(node)

    switch nodeType {
    case CMARK_NODE_TEXT:
        guard let literal = cmark_node_get_literal(node) else { return nil }
        return .text(restoration.restore(String(cString: literal)))

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
        if let math = MarkdownMathExtension.inlineMath(node) {
            return .math(restoration.restore(math))
        }
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
