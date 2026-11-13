import cmark_gfm

/// TeX math as cmark-gfm syntax extensions, so math is a parser node and block
/// structure, code spans, escapes, emphasis and table cells all come from
/// cmark. Where a formula starts and ends is `MathDelimiterRules`.
///
/// - Inline: `$…$` and `$$…$$` match at `$`, a registered special character.
///   `\(…\)` needs the parser to stop treating `(` and `)` as escapable: cmark
///   then leaves the backslash as its own text node and asks the extensions at
///   the `(`, where this one removes that node and makes the formula, or the
///   bare character a CommonMark escape would have produced.
/// - Block: a `$$` or `\[` fence, like a fenced code block. It must be attached
///   before `table`, which answers for every line it is asked about. Each
///   callback consumes its line up to (not past) the line ending; past it,
///   cmark would open a paragraph and close the block.
///
/// Reads `cmark_parser.mem` and `cmark_node.content`, which are not stable API:
/// swift-cmark is pinned by revision (`project.yml`), and the Markdown golden
/// corpus catches a change on upgrade.
enum MarkdownMathExtension {
    /// Attach both extensions and the escape rule to a new parser, before any
    /// other extension.
    static func attach(to parser: UnsafeMutablePointer<cmark_parser>) {
        cmark_parser_set_backslash_ispunct_func(parser) { character in
            character == MathDelimiterRules.openParen || character == MathDelimiterRules.closeParen
                ? 0 : cmark_ispunct(character)
        }
        cmark_parser_attach_syntax_extension(parser, registered.block)
        cmark_parser_attach_syntax_extension(parser, registered.inline)
    }

    /// The formula an inline node holds, or nil when it is not a math node.
    static func inlineMath(_ node: UnsafeMutablePointer<cmark_node>) -> MarkdownMath? {
        guard cmark_node_get_type(node) == registered.inlineType,
              let kind = InlineKind(rawValue: Int(bitPattern: cmark_node_get_user_data(node))) else { return nil }
        let latex = content(of: node)
        let delimiters = kind.delimiters
        return MarkdownMath(
            latex: latex,
            source: delimiters.opener + latex + delimiters.closer,
            isDisplay: kind == .displayDollar
        )
    }

    /// The formula a block node holds, and whether its closing line arrived.
    static func blockMath(_ node: UnsafeMutablePointer<cmark_node>) -> (math: MarkdownMath, isClosed: Bool)? {
        guard cmark_node_get_type(node) == registered.blockType else { return nil }
        let state = BlockState(node)
        let latex = content(of: node)
        let fence = state.fence
        return (
            MarkdownMath(
                latex: latex,
                source: fence.opener + (state.isOneLine ? "" : "\n") + latex
                    + (state.isClosed ? (state.isOneLine ? "" : "\n") + fence.closer : ""),
                isDisplay: true
            ),
            state.isClosed
        )
    }

    /// Whether a math block's closing line arrived; nil when `node` is not one.
    static func blockIsClosed(_ node: UnsafeMutablePointer<cmark_node>) -> Bool? {
        guard cmark_node_get_type(node) == registered.blockType else { return nil }
        return BlockState(node).isClosed
    }

    private static func content(of node: UnsafeMutablePointer<cmark_node>) -> String {
        String(cString: cmark_node_get_string_content(node))
    }

    // MARK: - Registration

    private struct Registered: @unchecked Sendable {
        let inline: UnsafeMutablePointer<cmark_syntax_extension>
        let block: UnsafeMutablePointer<cmark_syntax_extension>
        let inlineType: cmark_node_type
        let blockType: cmark_node_type
    }

    /// Created once per process: node types are process-wide.
    private static let registered: Registered = {
        let inline = cmark_syntax_extension_new("oppi_math")!
        let block = cmark_syntax_extension_new("oppi_math_block")!
        let registered = Registered(
            inline: inline,
            block: block,
            inlineType: cmark_syntax_extension_add_node(1),
            blockType: cmark_syntax_extension_add_node(0)
        )
        cmark_syntax_extension_set_match_inline_func(inline, matchInline)
        cmark_syntax_extension_set_special_inline_chars(
            inline,
            cmark_llist_append(
                cmark_get_default_mem_allocator(),
                nil,
                UnsafeMutableRawPointer(bitPattern: Int(MathDelimiterRules.dollar))
            )
        )
        cmark_syntax_extension_set_open_block_func(block, openBlock)
        cmark_syntax_extension_set_match_block_func(block, matchBlock)
        return registered
    }()

    // MARK: - Inline

    private enum InlineKind: Int {
        case dollar = 1
        case displayDollar
        case paren

        init(_ kind: MathDelimiterRules.InlineKind) {
            switch kind {
            case .dollar: self = .dollar
            case .displayDollar: self = .displayDollar
            case .paren: self = .paren
            }
        }

        var delimiters: (opener: String, closer: String) {
            switch self {
            case .dollar: ("$", "$")
            case .displayDollar: ("$$", "$$")
            case .paren: (#"\("#, #"\)"#)
            }
        }
    }

    private static let matchInline: cmark_match_inline_func = { ext, parser, parent, character, inlineParser in
        guard let ext, let parser, let inlineParser,
              let chunk = cmark_inline_parser_get_chunk(inlineParser),
              let data = chunk.pointee.data else { return nil }
        let bytes = UnsafeBufferPointer(start: data, count: Int(chunk.pointee.len))
        let position = Int(cmark_inline_parser_get_offset(inlineParser))
        let mem = parser.pointee.mem

        let match: MathDelimiterRules.InlineMatch?
        switch character {
        case MathDelimiterRules.dollar:
            match = MathDelimiterRules.dollarMath(in: bytes, open: position)
        case MathDelimiterRules.openParen, MathDelimiterRules.closeParen:
            // Only right after a backslash that escapes this character.
            guard position > 0, MathDelimiterRules.isUnescapedBackslash(bytes, at: position - 1),
                  let parent, let backslash = cmark_node_last_child(parent),
                  cmark_node_get_type(backslash) == CMARK_NODE_TEXT,
                  let literal = cmark_node_get_literal(backslash),
                  literal.pointee == CChar(bitPattern: MathDelimiterRules.backslash),
                  literal.advanced(by: 1).pointee == 0 else { return nil }
            cmark_node_free(backslash)
            match = character == MathDelimiterRules.openParen
                ? MathDelimiterRules.parenMath(in: bytes, open: position)
                : nil
            if match == nil {
                // `\(` or `\)` that opens nothing: the character, as an escape.
                let text = cmark_node_new_with_mem(CMARK_NODE_TEXT, mem)
                cmark_node_set_literal(text, character == MathDelimiterRules.openParen ? "(" : ")")
                cmark_inline_parser_set_offset(inlineParser, Int32(position + 1))
                return text
            }
        default:
            return nil
        }
        guard let match, let node = cmark_node_new_with_mem_and_ext(registered.inlineType, mem, ext) else { return nil }
        cmark_strbuf_put(&node.pointee.content, data + match.contentStart, Int32(match.contentEnd - match.contentStart))
        cmark_node_set_user_data(node, UnsafeMutableRawPointer(bitPattern: InlineKind(match.kind).rawValue))
        cmark_inline_parser_set_offset(inlineParser, Int32(match.end))
        return node
    }

    // MARK: - Block

    /// Kept in the node's `user_data` as bits: no allocation to free.
    private struct BlockState {
        var fence: MathDelimiterRules.BlockFence
        var isClosed = false
        var isOneLine = false
        var hasLine = false
        /// Columns the opener sat right of its container (0...3): each later
        /// line loses up to as many leading spaces, as fenced code does.
        var indent = 0

        init(fence: MathDelimiterRules.BlockFence) {
            self.fence = fence
        }

        init(_ node: UnsafeMutablePointer<cmark_node>) {
            let bits = Int(bitPattern: cmark_node_get_user_data(node))
            fence = bits & 1 == 0 ? .dollars : .brackets
            isClosed = bits & 2 != 0
            isOneLine = bits & 4 != 0
            hasLine = bits & 8 != 0
            indent = (bits >> 5) & 3
        }

        func store(in node: UnsafeMutablePointer<cmark_node>) {
            let bits = (fence == .brackets ? 1 : 0) | (isClosed ? 2 : 0) | (isOneLine ? 4 : 0) | (hasLine ? 8 : 0)
                | (min(indent, 3) << 5)
            // A null pointer would read back as "dollars, open": bit 16 keeps it non-null.
            cmark_node_set_user_data(node, UnsafeMutableRawPointer(bitPattern: bits | 16))
        }
    }

    private static let openBlock: cmark_open_block_func = { ext, indented, parser, parent, input, length in
        guard indented == 0, let ext, let parser, let parent, let input else { return nil }
        let start = Int(cmark_parser_get_first_nonspace(parser))
        let end = lineEnd(input, Int(length))
        guard start < end,
              let opening = MathDelimiterRules.blockOpening(UnsafeBufferPointer(start: input + start, count: end - start)),
              let node = cmark_parser_add_child(parser, parent, registered.blockType, cmark_parser_get_first_nonspace_column(parser))
        else { return nil }
        cmark_node_set_syntax_extension(node, ext)
        var state = BlockState(fence: opening.fence)
        state.indent = start - Int(cmark_parser_get_offset(parser))
        if let content = opening.oneLine {
            cmark_strbuf_put(&node.pointee.content, input + start + content.lowerBound, Int32(content.count))
            state.isClosed = true
            state.isOneLine = true
        }
        state.store(in: node)
        advance(parser, input, to: end)
        return node
    }

    private static let matchBlock: cmark_match_block_func = { _, parser, input, length, node in
        guard let parser, let input, let node else { return 0 }
        var state = BlockState(node)
        guard !state.isClosed else { return 0 }
        let end = lineEnd(input, Int(length))
        var start = Int(cmark_parser_get_offset(parser))
        for _ in 0 ..< state.indent where start < end && input[start] == 0x20 { start += 1 }
        start = min(start, end)
        let line = MathDelimiterRules.blockLine(UnsafeBufferPointer(start: input + start, count: end - start), fence: state.fence)
        let isBareCloser = line.closes && line.content.isEmpty
        if !isBareCloser {
            if state.hasLine { cmark_strbuf_putc(&node.pointee.content, 0x0A) }
            cmark_strbuf_put(&node.pointee.content, input + start + line.content.lowerBound, Int32(line.content.count))
            state.hasLine = true
        }
        state.isClosed = line.closes
        state.store(in: node)
        advance(parser, input, to: end)
        return 1
    }

    private static func lineEnd(_ input: UnsafeMutablePointer<UInt8>, _ length: Int) -> Int {
        var end = length
        while end > 0, input[end - 1] == 0x0A || input[end - 1] == 0x0D { end -= 1 }
        return end
    }

    private static func advance(_ parser: UnsafeMutablePointer<cmark_parser>, _ input: UnsafeMutablePointer<UInt8>, to end: Int) {
        let count = Int32(end) - cmark_parser_get_offset(parser)
        guard count > 0 else { return }
        input.withMemoryRebound(to: CChar.self, capacity: end) { cmark_parser_advance_offset(parser, $0, count, 0) }
    }
}
