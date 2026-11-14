import cmark_gfm
import cmark_gfm_extensions
/// Puts back the wiki-link bodies the pre-pass hid from cmark.
private struct CMarkRestoration {
    /// Nil in a block that holds no hidden body: literals pass through.
    let wiki: MarkdownWikiLinkRewriter.Restoration?
    /// Inside a table cell, where GFM turns `\|` into `|`: hidden bodies get the same.
    var inTableCell = false

    func restore(_ text: String) -> String {
        wiki?.restore(text, unescapingPipes: inTableCell) ?? text
    }

    func restore(_ math: MarkdownMath) -> MarkdownMath {
        MarkdownMath(latex: restore(math.latex), source: restore(math.source), isDisplay: math.isDisplay)
    }
}

/// cmark-gfm's tree for one parse, before conversion to `[MarkdownBlock]`.
private struct CMarkParsedDocument {
    let root: UnsafeMutablePointer<cmark_node>
    let wiki: MarkdownWikiLinkRewriter.Restoration?
    /// The text cmark parsed, before wiki bodies were hidden (that keeps lines
    /// and fences): line numbers in the tree count its lines.
    let input: String
    let hasReferenceDefinitions: Bool

    /// The restoration for top-level block `node`: none unless a hidden body
    /// sits on its lines.
    func restoration(for node: UnsafeMutablePointer<cmark_node>) -> CMarkRestoration {
        guard let wiki else { return CMarkRestoration(wiki: nil) }
        let start = Int(cmark_node_get_start_line(node))
        let end = Int(cmark_node_get_end_line(node))
        guard start > 0, end >= start else { return CMarkRestoration(wiki: wiki) }
        return CMarkRestoration(wiki: wiki.hidesText(onLines: start ... end) ? wiki : nil)
    }
}

/// The GFM extensions the parser attaches, found once (they are process-wide
/// and built into swift-cmark). The converter tells their nodes apart by
/// extension pointer: a node's type name would be a C string to copy and
/// compare for every list item, table and unknown inline.
private struct GFMExtensions: @unchecked Sendable {
    let table: UnsafeMutablePointer<cmark_syntax_extension>
    let strikethrough: UnsafeMutablePointer<cmark_syntax_extension>
    let tasklist: UnsafeMutablePointer<cmark_syntax_extension>

    static let shared: GFMExtensions = {
        cmark_gfm_core_extensions_ensure_registered()
        return GFMExtensions(
            table: cmark_find_syntax_extension("table")!,
            strikethrough: cmark_find_syntax_extension("strikethrough")!,
            tasklist: cmark_find_syntax_extension("tasklist")!
        )
    }()
}

/// A literal as a `String`, read from the node's own chunk: the public
/// getters (`cmark_node_get_literal`, `_url`, `_fence_info`) first copy a
/// chunk that points into its paragraph into a new NUL-terminated buffer.
/// Reads `cmark_node.as`, which is not stable API; swift-cmark is pinned by
/// revision, as `MarkdownMathExtension` notes.
private func string(_ chunk: cmark_chunk) -> String {
    guard chunk.len > 0, let data = chunk.data else { return "" }
    return String(decoding: UnsafeBufferPointer(start: data, count: Int(chunk.len)), as: UTF8.self)
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
    let gfm = GFMExtensions.shared
    // Only `~~x~~` strikes through. A single tilde is everyday text in agent
    // output (`~10~20ms`, `List~int~`, Org's `~code~`), and struck-through
    // text is visible, so the single-tilde form would cross out real content.
    // No smart punctuation: it rewrote `--flag` and wiki file names
    // (`it's--done.md`) along with prose.
    let options = CMARK_OPT_DEFAULT | CMARK_OPT_SOURCEPOS | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE
    guard let parser = cmark_parser_new(options) else { return nil }

    // Math first: its block extension has to be asked before `table`.
    MarkdownMathExtension.attach(to: parser)
    for ext in [gfm.table, gfm.strikethrough, gfm.tasklist] {
        cmark_parser_attach_syntax_extension(parser, ext)
    }
    cmark_parser_attach_syntax_extension(parser, referenceDefinitionProbe)

    // Near-miss tables become GFM first so later wiki-pipe protection and
    // cmark-gfm see ordinary delimiter rows and cells.
    let tableSource = MarkdownTableMarkupRewriter.rewrite(
        source,
        rewriteHTMLTables: rewriteHTMLTables
    )
    // cmark takes a document in pieces (a line may span two), so each hidden
    // wiki body is fed as its frame between pieces of the text, uncopied.
    let wikiInput = MarkdownWikiLinkRewriter.parserInput(tableSource)
    UTF8Search.withBytes(of: tableSource) { bytes in
        func feed(_ piece: UnsafeBufferPointer<UInt8>) {
            guard let base = piece.baseAddress, !piece.isEmpty else { return }
            base.withMemoryRebound(to: CChar.self, capacity: piece.count) { cmark_parser_feed(parser, $0, piece.count) }
        }
        var fed = 0
        if let wiki = wikiInput.restoration {
            for (index, hidden) in wikiInput.hiddenRanges.enumerated() {
                feed(UnsafeBufferPointer(rebasing: bytes[fed ..< hidden.lowerBound]))
                var frame = wiki.frame(index)
                frame.withUTF8(feed)
                fed = hidden.upperBound
            }
        }
        feed(UnsafeBufferPointer(rebasing: bytes[fed...]))
    }

    let doc = cmark_parser_finish(parser)
    cmark_parser_free(parser)
    guard let doc else { return nil }
    let hasReferenceDefinitions = cmark_node_get_user_data(doc) != nil
    return CMarkParsedDocument(
        root: doc,
        wiki: wikiInput.restoration,
        input: tableSource,
        hasReferenceDefinitions: hasReferenceDefinitions
    )
}

/// Parse a CommonMark string into renderable block nodes. Nonisolated so
/// callers can run it off the main actor.
nonisolated func parseCommonMark(_ source: String) -> [MarkdownBlock] {
    guard let parsed = cmarkParsedDocument(source, rewriteHTMLTables: true) else { return [] }
    defer { cmark_node_free(parsed.root) }

    var blocks: [MarkdownBlock] = []
    var child = cmark_node_first_child(parsed.root)
    while let node = child {
        if let block = convertCMarkBlock(node, restoration: parsed.restoration(for: node)) {
            blocks.append(block)
        }
        child = cmark_node_next(node)
    }
    return blocks
}

/// Parse CommonMark and keep each top-level block's source lines. HTML tables
/// stay HTML here: converting them would move the lines after them.
nonisolated func parseCommonMarkLocated(_ source: String) -> [LocatedMarkdownBlock] {
    let parsed = parseCommonMarkTail(source)
    return zip(parsed.blocks, parsed.blockLineRanges).map { LocatedMarkdownBlock(block: $0, lineRange: $1) }
}

/// The streaming driver's parse: top-level blocks with the line each starts
/// on, and what cmark knows about the end of the text.
nonisolated func parseCommonMarkTail(_ source: String) -> CommonMarkTailParse {
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
        if let block = convertCMarkBlock(node, restoration: parsed.restoration(for: node)) {
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
        return !MarkdownFence.closes(line, byte: UInt8(bitPattern: character), count: Int(length))
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

    if cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK, node.pointee.as.code.fence_length > 0 {
        // The code's own lines, without the fences: one per newline, the
        // last one's newline aside.
        let literal = node.pointee.as.code.literal
        let code = UnsafeBufferPointer(start: literal.data, count: Int(literal.len))
        var newlines = code.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        if code.last == 0x0A { newlines -= 1 }
        let codeStart = start + 1
        return codeStart...(codeStart + newlines)
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
        let restoredCode = restoration.restore(string(node.pointee.as.code.literal))
        var code = restoredCode.hasSuffix("\n") ? String(restoredCode.dropLast()) : restoredCode
        let info = restoration.restore(string(node.pointee.as.code.info))
        // Strip trailing inner fences from 4+ backtick code blocks.
        if node.pointee.as.code.fence_length > 3 { code = stripTrailingInnerFence(code) }
        return .codeBlock(language: info.isEmpty ? nil : info, code: code)

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
            let isTask = cmark_node_get_syntax_extension(itemNode) == GFMExtensions.shared.tasklist
            hasTaskItems = hasTaskItems || isTask
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
        let html = restoration.restore(string(node.pointee.as.literal))
        switch MarkdownInlineHTML.block(html) {
        case .hidden?: return nil
        case .thematicBreak?: return .thematicBreak
        case .paragraph(let inlines)?: return .paragraph(inlines)
        case nil: return .htmlBlock(html)
        }

    default:
        // A table is the only other block the attached extensions make.
        if cmark_node_get_syntax_extension(node) == GFMExtensions.shared.table {
            return convertCMarkTable(node, restoration: restoration)
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

    return .table(headers: headers, rows: rows, alignments: tableAlignments(node, columns: headers.count))
}

/// The delimiter row's alignments, or none when no column sets one.
private func tableAlignments(_ node: UnsafeMutablePointer<cmark_node>, columns: Int) -> [MarkdownTableAlignment?] {
    let count = min(columns, Int(cmark_gfm_extensions_get_table_columns(node)))
    guard count > 0, let raw = cmark_gfm_extensions_get_table_alignments(node) else { return [] }
    let alignments = (0 ..< count).map { index -> MarkdownTableAlignment? in
        switch UInt8(raw[index]) {
        case UInt8(ascii: "l"): .left
        case UInt8(ascii: "c"): .center
        case UInt8(ascii: "r"): .right
        default: nil
        }
    }
    return alignments.contains { $0 != nil } ? alignments : []
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
            result += restoration.restore(string(c.pointee.as.literal))
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
    var hasHTML = false
    var child = cmark_node_first_child(parentNode)
    while let node = child {
        if let inline = convertCMarkInline(node, restoration: restoration) {
            if case .html = inline { hasHTML = true }
            inlines.append(inline)
        }
        child = cmark_node_next(node)
    }
    // Raw HTML of Oppi's subset pairs within its own run, so a tag opened in
    // one emphasis never closes in another.
    return hasHTML ? MarkdownInlineHTML.pair(inlines) : inlines
}

private func convertCMarkInline(
    _ node: UnsafeMutablePointer<cmark_node>,
    restoration: CMarkRestoration
) -> MarkdownInline? {
    let nodeType = cmark_node_get_type(node)

    switch nodeType {
    case CMARK_NODE_TEXT:
        return .text(restoration.restore(string(node.pointee.as.literal)))

    case CMARK_NODE_EMPH:
        return .emphasis(convertCMarkInlines(node, restoration: restoration))

    case CMARK_NODE_STRONG:
        return .strong(convertCMarkInlines(node, restoration: restoration))

    case CMARK_NODE_CODE:
        return .code(restoration.restore(string(node.pointee.as.literal)))

    case CMARK_NODE_LINK:
        return .link(
            children: convertCMarkInlines(node, restoration: restoration),
            destination: restoration.restore(string(node.pointee.as.link.url))
        )

    case CMARK_NODE_IMAGE:
        return .image(
            alt: extractCMarkPlainText(node, restoration: restoration),
            source: restoration.restore(string(node.pointee.as.link.url))
        )

    case CMARK_NODE_SOFTBREAK:
        return .softBreak

    case CMARK_NODE_LINEBREAK:
        return .hardBreak

    case CMARK_NODE_HTML_INLINE:
        return .html(restoration.restore(string(node.pointee.as.literal)))

    default:
        if let math = MarkdownMathExtension.inlineMath(node) {
            return .math(restoration.restore(math))
        }
        if cmark_node_get_syntax_extension(node) == GFMExtensions.shared.strikethrough {
            return .strikethrough(convertCMarkInlines(node, restoration: restoration))
        }
        return nil
    }
}

// MARK: - Inner Fence Cleanup

/// Strip a trailing fence-like line from code block content produced by 4+
/// backtick/tilde fences. Preserves the trailing fence when there's a matching
/// opening fence elsewhere in the content (e.g., markdown tutorials).
private func stripTrailingInnerFence(_ code: String) -> String {
    /// A line of only a 3+ fence and blanks.
    func isFenceLine(_ line: Substring) -> Bool {
        guard let fence = MarkdownFence.opening(line.utf8) else { return false }
        return MarkdownFence.closes(line.utf8, byte: fence.byte, count: 3)
    }
    guard let lastNewline = code.lastIndex(of: "\n") else {
        return isFenceLine(code[...]) ? "" : code
    }
    let lastLine = code[code.index(after: lastNewline)...]
    guard isFenceLine(lastLine) else { return code }

    // An earlier line that opens a fence ("```python") pairs with the
    // trailing one: it is content, as in a Markdown tutorial. Keep it.
    let prefix = code[..<lastNewline]
    for line in prefix.split(separator: "\n", omittingEmptySubsequences: false)
        where MarkdownFence.opening(line.utf8) != nil {
        return code
    }

    return String(prefix)
}
