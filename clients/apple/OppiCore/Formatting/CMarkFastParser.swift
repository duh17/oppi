import cmark_gfm
import cmark_gfm_extensions

/// Protects recognized inline math as an opaque token while cmark-gfm parses
/// the surrounding Markdown. This keeps TeX backslashes and underscores intact
/// and, crucially, distinguishes real delimiters from escaped dollars before
/// CommonMark consumes the escape.
struct MarkdownMathScannerDiagnostics: Equatable {
    var indexedBacktickRuns = 0
    var suffixLineVisits = 0
}

private enum MarkdownMathDelimiterRewriter {
    struct Restoration {
        struct DisplayBlock {
            let latexSource: String
            let exactSource: String
            let lineRange: ClosedRange<Int>
            let rendersAsLatex: Bool
        }

        fileprivate let replacements: [String: String]
        fileprivate let displayBlocks: [String: DisplayBlock]

        func restore(_ text: String) -> String {
            guard !replacements.isEmpty else { return text }
            var restored = text
            for (token, source) in replacements {
                restored = restored.replacingOccurrences(of: token, with: source)
            }
            return restored
        }

        func displayBlock(for token: String) -> DisplayBlock? {
            displayBlocks[token]
        }
    }

    struct ParserInput {
        let source: String
        let restoration: Restoration
    }

    private static let tokenBaseCandidates = [
        "opmathaz", "opmathbz", "opmathcz", "opmathdz",
        "opmathez", "opmathfz", "opmathgz", "opmathhz",
    ]
    /// Restoration currently performs one bounded replacement per token.
    /// Fail closed to ordinary CommonMark above this cap rather than permit a
    /// hostile delimiter stream to amplify work quadratically.
    private static let maxProtectedMathTokens = 1_024

    private enum HTMLBlockState {
        case untilMarker(String, caseInsensitive: Bool)
        case untilBlankLine

        func ends(on line: String) -> Bool {
            switch self {
            case .untilMarker(let marker, let caseInsensitive):
                if caseInsensitive {
                    return line.range(of: marker, options: .caseInsensitive) != nil
                }
                return line.contains(marker)
            case .untilBlankLine:
                return line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    private struct DisplayCandidate {
        let latexSource: String
        let exactSource: String
        let endLineIndex: Int
    }

    /// A code-span opener on a line is relevant only when a same-sized run
    /// appears later. This index preserves that decision without rescanning a
    /// suffix for every differently sized backtick run.
    private struct CodeSpanOpenerIndex {
        let matchedLengthAfterLine: [Int?]

        func matchedLength(after lineIndex: Int) -> Int? {
            guard matchedLengthAfterLine.indices.contains(lineIndex) else { return nil }
            return matchedLengthAfterLine[lineIndex]
        }
    }

    /// Nearest usable closer after each line. Building this once prevents each
    /// unmatched opener from rescanning the remaining document.
    private struct DisplayCloserIndex {
        let dollarAfterLine: [Int?]
        let bracketAfterLine: [Int?]

        func closerLine(_ closer: String, after lineIndex: Int) -> Int? {
            guard dollarAfterLine.indices.contains(lineIndex) else { return nil }
            return closer == "$$" ? dollarAfterLine[lineIndex] : bracketAfterLine[lineIndex]
        }
    }

    static func parserInput(_ source: String) -> ParserInput {
        var diagnostics = MarkdownMathScannerDiagnostics()
        return parserInput(source, diagnostics: &diagnostics)
    }

    fileprivate static func parserInput(
        _ source: String,
        diagnostics: inout MarkdownMathScannerDiagnostics
    ) -> ParserInput {
        guard source.contains("$") || source.contains(#"\["#)
                || (source.contains(#"\("#) && source.contains(#"\)"#)),
              potentialMathDelimiterCount(in: source) <= maxProtectedMathTokens,
              let tokenBase = tokenBaseCandidates.first(where: { !source.contains($0) }) else {
            return ParserInput(
                source: source,
                restoration: Restoration(replacements: [:], displayBlocks: [:])
            )
        }

        var lines = source.components(separatedBy: "\n")
        let codeSpanOpenerIndex = codeSpanOpenerIndex(
            in: lines,
            diagnostics: &diagnostics
        )
        let closerIndex = displayCloserIndex(
            in: lines,
            codeSpanOpenerIndex: codeSpanOpenerIndex
        )
        var replacements: [String: String] = [:]
        var displayBlocks: [String: Restoration.DisplayBlock] = [:]
        var openFence: (character: Character, count: Int)?
        var openCodeSpanLength: Int?
        var openHTMLBlock: HTMLBlockState?
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]

            if let fence = openFence {
                if isClosingFence(line, matching: fence) {
                    openFence = nil
                }
                lineIndex += 1
                continue
            }

            if let htmlBlock = openHTMLBlock {
                if htmlBlock.ends(on: line) {
                    openHTMLBlock = nil
                }
                lineIndex += 1
                continue
            }

            if let codeSpanLength = openCodeSpanLength {
                if containsCodeSpanRun(length: codeSpanLength, in: line) {
                    openCodeSpanLength = nil
                }
                lineIndex += 1
                continue
            }

            if let fence = openingFence(in: line) {
                openFence = fence
                lineIndex += 1
                continue
            }

            if let htmlBlock = openingHTMLBlock(in: line) {
                if !htmlBlock.ends(on: line) {
                    openHTMLBlock = htmlBlock
                }
                lineIndex += 1
                continue
            }

            if let display = displayCandidate(
                in: lines,
                openingLineIndex: lineIndex,
                closerIndex: closerIndex
            ) {
                let validation = TeXMathParser().parseValidated(display.latexSource)
                let token = "\(tokenBase)d\(displayBlocks.count)z"
                displayBlocks[token] = Restoration.DisplayBlock(
                    latexSource: display.latexSource,
                    exactSource: display.exactSource,
                    lineRange: (lineIndex + 1)...(display.endLineIndex + 1),
                    rendersAsLatex: validation.isRenderable
                )
                // Display tokens are opaque too. If cmark places one in HTML,
                // code, or any fallback literal instead of a plain paragraph,
                // ordinary restoration must still recover the exact source.
                replacements[token] = display.exactSource
                lines[lineIndex] = token
                if display.endLineIndex > lineIndex {
                    for consumedIndex in (lineIndex + 1)...display.endLineIndex {
                        lines[consumedIndex] = ""
                    }
                }
                lineIndex = display.endLineIndex + 1
                continue
            }

            lines[lineIndex] = replacingInlineMath(
                in: line,
                tokenBase: tokenBase,
                replacements: &replacements
            )
            openCodeSpanLength = codeSpanOpenerIndex.matchedLength(after: lineIndex)
            lineIndex += 1
        }

        return ParserInput(
            source: lines.joined(separator: "\n"),
            restoration: Restoration(
                replacements: replacements,
                displayBlocks: displayBlocks
            )
        )
    }

    private static func potentialMathDelimiterCount(in source: String) -> Int {
        var count = 0
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "$" {
                count += 1
            } else if character == "\\" {
                let next = source.index(after: cursor)
                if next < source.endIndex, "[]()$".contains(source[next]) {
                    count += 1
                }
            }
            if count > maxProtectedMathTokens { return count }
            cursor = source.index(after: cursor)
        }
        return count
    }

    private static func codeSpanOpenerIndex(
        in lines: [String],
        diagnostics: inout MarkdownMathScannerDiagnostics
    ) -> CodeSpanOpenerIndex {
        var runsByLine = [[Int]]()
        runsByLine.reserveCapacity(lines.count)

        for line in lines {
            var runs = [Int]()
            var cursor = line.startIndex
            while cursor < line.endIndex {
                if line[cursor] == "`", !isEscaped(at: cursor, in: line) {
                    let length = repeatedCharacterCount(in: line, from: cursor)
                    runs.append(length)
                    diagnostics.indexedBacktickRuns += 1
                    cursor = line.index(cursor, offsetBy: length)
                } else {
                    cursor = line.index(after: cursor)
                }
            }
            runsByLine.append(runs)
        }

        var matchedLengthAfterLine = [Int?](repeating: nil, count: lines.count)
        var lengthsInLaterLines = Set<Int>()
        for lineIndex in runsByLine.indices.reversed() {
            let runs = runsByLine[lineIndex]
            var remainingOnLine = Dictionary(runs.map { ($0, 1) },
                                             uniquingKeysWith: +)
            for length in runs {
                remainingOnLine[length, default: 0] -= 1
                if remainingOnLine[length, default: 0] > 0 { continue }
                if lengthsInLaterLines.contains(length) {
                    matchedLengthAfterLine[lineIndex] = length
                    break
                }
            }
            lengthsInLaterLines.formUnion(runs)
        }

        return CodeSpanOpenerIndex(matchedLengthAfterLine: matchedLengthAfterLine)
    }

    private static func displayCloserIndex(
        in lines: [String],
        codeSpanOpenerIndex: CodeSpanOpenerIndex
    ) -> DisplayCloserIndex {
        var dollarAfterLine = [Int?](repeating: nil, count: lines.count)
        var bracketAfterLine = [Int?](repeating: nil, count: lines.count)
        var nextDollar: Int?
        var nextBracket: Int?

        for index in lines.indices.reversed() {
            dollarAfterLine[index] = nextDollar
            bracketAfterLine[index] = nextBracket

            let line = lines[index]
            let trimmed = contentAfterCommonMarkIndent(in: line)?
                .trimmingCharacters(in: .whitespaces)
            let isOpaqueOrMarkdownBoundary = openingFence(in: line) != nil
                || openingHTMLBlock(in: line) != nil
                || (trimmed.map(isOrdinaryBlockBoundary) ?? false)
                || codeSpanOpenerIndex.matchedLength(after: index) != nil

            if isOpaqueOrMarkdownBoundary {
                nextDollar = nil
                nextBracket = nil
                continue
            }
            if trimmed == "$$" { nextDollar = index }
            if trimmed == #"\]"# { nextBracket = index }
        }
        return DisplayCloserIndex(
            dollarAfterLine: dollarAfterLine,
            bracketAfterLine: bracketAfterLine
        )
    }

    private static func displayCandidate(
        in lines: [String],
        openingLineIndex: Int,
        closerIndex: DisplayCloserIndex
    ) -> DisplayCandidate? {
        let line = lines[openingLineIndex]
        guard let content = contentAfterCommonMarkIndent(in: line) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespaces)

        for (opener, closer) in [("$$", "$$"), (#"\["#, #"\]"#)] {
            if trimmed.hasPrefix(opener), trimmed.hasSuffix(closer),
               trimmed.count > opener.count + closer.count {
                let start = trimmed.index(trimmed.startIndex, offsetBy: opener.count)
                let end = trimmed.index(trimmed.endIndex, offsetBy: -closer.count)
                let latex = trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !latex.isEmpty else { return nil }
                return DisplayCandidate(
                    latexSource: latex,
                    exactSource: line,
                    endLineIndex: openingLineIndex
                )
            }

            guard trimmed == opener,
                  let closingIndex = closerIndex.closerLine(
                      closer,
                      after: openingLineIndex
                  ) else {
                continue
            }
            let latex = lines[(openingLineIndex + 1)..<closingIndex].joined(separator: "\n")
            guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return DisplayCandidate(
                latexSource: latex,
                exactSource: lines[openingLineIndex...closingIndex].joined(separator: "\n"),
                endLineIndex: closingIndex
            )
        }
        return nil
    }

    private static func isOrdinaryBlockBoundary(_ line: String) -> Bool {
        if line.hasPrefix("#") {
            let markerCount = line.prefix(while: { $0 == "#" }).count
            if markerCount <= 6,
               line.dropFirst(markerCount).first?.isWhitespace == true {
                return true
            }
        }
        if ["- ", "* ", "+ "].contains(where: line.hasPrefix) {
            return true
        }

        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor].isNumber {
            cursor = line.index(after: cursor)
        }
        guard cursor > line.startIndex, cursor < line.endIndex,
              line[cursor] == "." || line[cursor] == ")" else {
            return false
        }
        let afterMarker = line.index(after: cursor)
        return afterMarker < line.endIndex && line[afterMarker].isWhitespace
    }

    /// Return content only when indentation is safely within CommonMark's
    /// three-column allowance. Tabs advance to the next four-column stop, so a
    /// leading tab or space-plus-tab is conservatively treated as indented code.
    private static func contentAfterCommonMarkIndent(in line: String) -> Substring? {
        var columns = 0
        var cursor = line.startIndex
        while cursor < line.endIndex {
            switch line[cursor] {
            case " ":
                columns += 1
            case "\t":
                columns += 4 - (columns % 4)
            default:
                return columns <= 3 ? line[cursor...] : nil
            }
            guard columns <= 3 else { return nil }
            cursor = line.index(after: cursor)
        }
        return line[cursor...]
    }

    private static func containsCodeSpanRun(length: Int, in line: String) -> Bool {
        var cursor = line.startIndex
        while cursor < line.endIndex {
            if line[cursor] == "`", !isEscaped(at: cursor, in: line) {
                let count = repeatedCharacterCount(in: line, from: cursor)
                if count == length { return true }
                cursor = line.index(cursor, offsetBy: count)
            } else {
                cursor = line.index(after: cursor)
            }
        }
        return false
    }

    private static func openingFence(in line: String) -> (character: Character, count: Int)? {
        guard let content = contentAfterCommonMarkIndent(in: line),
              let character = content.first,
              character == "`" || character == "~" else { return nil }
        let count = content.prefix(while: { $0 == character }).count
        guard count >= 3 else { return nil }
        return (character, count)
    }

    private static func isClosingFence(
        _ line: String,
        matching fence: (character: Character, count: Int)
    ) -> Bool {
        guard let content = contentAfterCommonMarkIndent(in: line) else { return false }
        let count = content.prefix(while: { $0 == fence.character }).count
        guard count >= fence.count else { return false }
        return content.dropFirst(count).allSatisfy { $0.isWhitespace }
    }

    private static func openingHTMLBlock(in line: String) -> HTMLBlockState? {
        guard let content = contentAfterCommonMarkIndent(in: line) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        for tag in ["script", "pre", "style", "textarea"] {
            if lower.hasPrefix("<\(tag)") {
                return .untilMarker("</\(tag)>", caseInsensitive: true)
            }
        }
        if trimmed.hasPrefix("<!--") {
            return .untilMarker("-->", caseInsensitive: false)
        }
        if trimmed.hasPrefix("<?") {
            return .untilMarker("?>", caseInsensitive: false)
        }
        if trimmed.hasPrefix("<![CDATA[") {
            return .untilMarker("]]>", caseInsensitive: false)
        }
        if trimmed.hasPrefix("<!"), trimmed.dropFirst(2).first?.isLetter == true {
            return .untilMarker(">", caseInsensitive: false)
        }

        let blockTags = [
            "address", "article", "aside", "base", "basefont", "blockquote", "body",
            "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir",
            "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
            "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head",
            "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu",
            "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param",
            "search", "section", "summary", "table", "tbody", "td", "tfoot", "th",
            "thead", "title", "tr", "track", "ul",
        ]
        if blockTags.contains(where: { tag in
            lower.hasPrefix("<\(tag)") || lower.hasPrefix("</\(tag)")
        }) {
            return .untilBlankLine
        }

        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") {
            return .untilBlankLine
        }
        return nil
    }

    private static func replacingInlineMath(
        in line: String,
        tokenBase: String,
        replacements: inout [String: String]
    ) -> String {
        var result = ""
        result.reserveCapacity(line.utf8.count)
        var cursor = line.startIndex
        var codeDelimiterLength: Int?

        while cursor < line.endIndex {
            if line[cursor] == "`", !isEscaped(at: cursor, in: line) {
                let runLength = repeatedCharacterCount(in: line, from: cursor)
                if codeDelimiterLength == nil {
                    codeDelimiterLength = runLength
                } else if codeDelimiterLength == runLength {
                    codeDelimiterLength = nil
                }
                let runEnd = line.index(cursor, offsetBy: runLength)
                result.append(contentsOf: line[cursor ..< runEnd])
                cursor = runEnd
                continue
            }

            guard codeDelimiterLength == nil else {
                result.append(line[cursor])
                cursor = line.index(after: cursor)
                continue
            }

            if line[cursor] == "]",
               let next = line.index(cursor, offsetBy: 1, limitedBy: line.endIndex),
               next < line.endIndex,
               line[next] == "(",
               let destinationEnd = inlineLinkDestinationEnd(in: line, openingParen: next) {
                let end = line.index(after: destinationEnd)
                result.append(contentsOf: line[cursor ..< end])
                cursor = end
                continue
            }

            if (matches(#"\\("#, in: line, at: cursor)
                || matches(#"\\)"#, in: line, at: cursor)),
               !isEscaped(at: cursor, in: line) {
                let end = line.index(cursor, offsetBy: 3)
                appendToken(
                    for: String(line[cursor ..< end]),
                    tokenBase: tokenBase,
                    replacements: &replacements,
                    to: &result
                )
                cursor = end
                continue
            }

            if (matches(#"\["#, in: line, at: cursor)
                || matches(#"\]"#, in: line, at: cursor)),
               !isEscaped(at: cursor, in: line) {
                let end = line.index(cursor, offsetBy: 2)
                appendToken(
                    for: String(line[cursor ..< end]),
                    tokenBase: tokenBase,
                    replacements: &replacements,
                    to: &result
                )
                cursor = end
                continue
            }

            if matches(#"\$"#, in: line, at: cursor),
               !isEscaped(at: cursor, in: line) {
                appendToken(
                    for: #"\$"#,
                    tokenBase: tokenBase,
                    replacements: &replacements,
                    to: &result
                )
                cursor = line.index(cursor, offsetBy: 2)
                continue
            }

            if matches(#"\("#, in: line, at: cursor),
               !isEscaped(at: cursor, in: line),
               let closeRange = nextUnescaped(#"\)"#, in: line, after: line.index(cursor, offsetBy: 2)) {
                let sourceRange = cursor ..< closeRange.upperBound
                appendToken(
                    for: String(line[sourceRange]),
                    tokenBase: tokenBase,
                    replacements: &replacements,
                    to: &result
                )
                cursor = closeRange.upperBound
                continue
            }

            if line[cursor] == "$",
               !isEscaped(at: cursor, in: line),
               !isAdjacentDollar(at: cursor, in: line) {
                let contentStart = line.index(after: cursor)
                if let close = nextSingleUnescapedDollar(in: line, from: contentStart) {
                    let latex = String(line[contentStart ..< close])
                    if isLikelyDollarMath(latex) {
                        let sourceRange = cursor ..< line.index(after: close)
                        appendToken(
                            for: String(line[sourceRange]),
                            tokenBase: tokenBase,
                            replacements: &replacements,
                            to: &result
                        )
                        cursor = line.index(after: close)
                        continue
                    }
                }
            }

            result.append(line[cursor])
            cursor = line.index(after: cursor)
        }

        return result
    }

    private static func appendToken(
        for source: String,
        tokenBase: String,
        replacements: inout [String: String],
        to result: inout String
    ) {
        let token = "\(tokenBase)\(replacements.count)z"
        replacements[token] = source
        result += token
    }

    private static func nextUnescaped(
        _ needle: String,
        in source: String,
        after start: String.Index
    ) -> Range<String.Index>? {
        var cursor = start
        while let range = source.range(of: needle, range: cursor ..< source.endIndex) {
            if !isEscaped(at: range.lowerBound, in: source) {
                return range
            }
            cursor = range.upperBound
        }
        return nil
    }

    private static func nextSingleUnescapedDollar(
        in source: String,
        from start: String.Index
    ) -> String.Index? {
        var cursor = start
        while cursor < source.endIndex {
            if source[cursor] == "$",
               !isEscaped(at: cursor, in: source),
               !isAdjacentDollar(at: cursor, in: source) {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func isLikelyDollarMath(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == source,
              !trimmed.contains("`"), !trimmed.contains("[") else { return false }
        if trimmed.contains("\\") || trimmed.contains("^") || trimmed.contains("_")
            || (trimmed.contains("{") && trimmed.contains("}")) {
            return true
        }
        if trimmed.contains(where: { "=+-*/<>".contains($0) })
            && trimmed.contains(where: { $0.isLetter || $0.isNumber }) {
            return true
        }
        if trimmed.allSatisfy({ $0.isNumber || ".,".contains($0) }) {
            return false
        }
        return trimmed.first?.isLetter == true
    }

    private static func inlineLinkDestinationEnd(
        in source: String,
        openingParen: String.Index
    ) -> String.Index? {
        var depth = 1
        var cursor = source.index(after: openingParen)
        while cursor < source.endIndex {
            if !isEscaped(at: cursor, in: source) {
                if source[cursor] == "(" {
                    depth += 1
                } else if source[cursor] == ")" {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func repeatedCharacterCount(in source: String, from start: String.Index) -> Int {
        let character = source[start]
        var count = 0
        var cursor = start
        while cursor < source.endIndex, source[cursor] == character {
            count += 1
            cursor = source.index(after: cursor)
        }
        return count
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

    private static func isAdjacentDollar(at index: String.Index, in source: String) -> Bool {
        let previousIsDollar = index > source.startIndex && source[source.index(before: index)] == "$"
        let next = source.index(after: index)
        let nextIsDollar = next < source.endIndex && source[next] == "$"
        return previousIsDollar || nextIsDollar
    }
}

nonisolated func markdownMathScannerDiagnostics(
    _ source: String
) -> MarkdownMathScannerDiagnostics {
    var diagnostics = MarkdownMathScannerDiagnostics()
    _ = MarkdownMathDelimiterRewriter.parserInput(source, diagnostics: &diagnostics)
    return diagnostics
}

private struct CMarkRestoration {
    let wiki: MarkdownWikiLinkRewriter.Restoration
    let math: MarkdownMathDelimiterRewriter.Restoration

    func restore(_ text: String) -> String {
        math.restore(wiki.restore(text))
    }

    func displayBlock(for node: UnsafeMutablePointer<cmark_node>)
        -> MarkdownMathDelimiterRewriter.Restoration.DisplayBlock? {
        guard cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH,
              let child = cmark_node_first_child(node),
              cmark_node_get_type(child) == CMARK_NODE_TEXT,
              cmark_node_next(child) == nil,
              let literal = cmark_node_get_literal(child) else {
            return nil
        }
        return math.displayBlock(for: String(cString: literal))
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
}

/// Shared parser setup: register GFM extensions, create parser, attach extensions, feed source.
private func cmarkParsedDocument(
    _ source: String,
    rewriteHTMLTables: Bool
) -> CMarkParsedDocument? {
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

    // Near-miss tables become GFM first so later wiki-pipe protection and
    // cmark-gfm see ordinary delimiter rows and cells.
    let tableSource = MarkdownTableMarkupRewriter.rewrite(
        source,
        rewriteHTMLTables: rewriteHTMLTables
    )
    // Inline math is opaque while CommonMark parses its TeX punctuation.
    // Wiki-link protection then applies its independent scoped tokens.
    let mathInput = MarkdownMathDelimiterRewriter.parserInput(tableSource)
    let parserInput = MarkdownWikiLinkRewriter.parserInput(mathInput.source)
    parserInput.source.withCString { ptr in
        cmark_parser_feed(parser, ptr, parserInput.source.utf8.count)
    }

    let doc = cmark_parser_finish(parser)
    cmark_parser_free(parser)
    guard let doc else { return nil }
    return CMarkParsedDocument(
        root: doc,
        restoration: CMarkRestoration(
            wiki: parserInput.restoration,
            math: mathInput.restoration
        )
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
                lineRange: sourceLineRange(for: node, restoration: parsed.restoration)
            ))
        }
        child = cmark_node_next(node)
    }
    return blocks
}

/// Fast parse with last block start line — used by the streaming incremental path.
nonisolated func parseCommonMarkFastWithLastLine(_ source: String) -> (blocks: [MarkdownBlock], lastBlockStartLine: Int) {
    guard let parsed = cmarkParsedDocument(source, rewriteHTMLTables: false) else { return ([], 1) }
    defer { cmark_node_free(parsed.root) }

    var blocks: [MarkdownBlock] = []
    var childCount = 0
    var lastNode: UnsafeMutablePointer<cmark_node>?
    var child = cmark_node_first_child(parsed.root)
    while let node = child {
        if let block = convertCMarkBlock(node, restoration: parsed.restoration) {
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

private func sourceLineRange(
    for node: UnsafeMutablePointer<cmark_node>,
    restoration: CMarkRestoration
) -> ClosedRange<Int>? {
    if let display = restoration.displayBlock(for: node) {
        return display.lineRange
    }

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

    if let display = restoration.displayBlock(for: node) {
        if display.rendersAsLatex {
            return .codeBlock(language: "latex", code: display.latexSource)
        }
        return .paragraph([.text(display.exactSource)])
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
    restoration: CMarkRestoration
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
