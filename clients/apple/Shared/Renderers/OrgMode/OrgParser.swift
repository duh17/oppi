// swiftlint:disable todo - Org-mode headline keyword examples, not unfinished work
/// Line-oriented recursive descent parser for org mode documents.
///
/// Conforms to `DocumentParser` — safe to call from any thread.
/// Produces `[OrgBlock]` AST matching org-syntax spec.
///
/// Strategy:
/// 1. Split input into lines
/// 2. Classify each line (heading, keyword, block delimiter, list item, etc.)
/// 3. Consume lines greedily, building block-level AST
/// 4. Parse inline markup within paragraph/heading text
///
/// Error recovery: malformed input is treated as plain paragraphs. Never crashes.
struct OrgParser: DocumentParser, Sendable {

    typealias Document = [OrgBlock]
    // MARK: - Allocation-free trim

    /// Strip leading/trailing ASCII whitespace returning Substring (no allocation).
    /// Foundation's trimmingCharacters returns String — allocates every call.
    @inline(__always)
    private static func stripped(_ s: Substring) -> Substring {
        let utf8 = s.utf8
        guard !utf8.isEmpty else { return s[s.endIndex...] }
        var lo = utf8.startIndex
        while lo < utf8.endIndex, utf8[lo] == 0x20 || utf8[lo] == 0x09 {
            utf8.formIndex(after: &lo)
        }
        guard lo < utf8.endIndex else { return s[s.endIndex...] }
        var hi = utf8.index(before: utf8.endIndex)
        while hi > lo, utf8[hi] == 0x20 || utf8[hi] == 0x09 {
            utf8.formIndex(before: &hi)
        }
        return s[lo...hi]
    }

    @inline(__always)
    private static func stripped(_ s: String) -> Substring {
        stripped(s[...])
    }

    nonisolated func parse(_ source: String) -> [OrgBlock] {
        parseLocated(source).map(\.block)
    }

    /// `\r\n` becomes `\n` before anything splits the source into lines, the
    /// same normalization `TaskSourceEdit`'s own line splitting already does
    /// per line (so line numbers the two agree on stay aligned). Left as is, a
    /// `\r` stuck to the end of every split line reaches a text view as its
    /// own paragraph break, breaking the document into far more visual lines
    /// than it has blocks. The common case has no `\r` at all, so this skips
    /// the allocation.
    @inline(__always)
    private static func normalizedLineEndings(_ source: String) -> String {
        guard source.utf8.contains(0x0D) else { return source }
        return source.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// The top-level blocks with the 1-based source line each starts on, for
    /// readers that edit the lines a block came from.
    nonisolated func parseLocated(_ source: String) -> [LocatedOrgBlock] {
        let lines = Self.normalizedLineEndings(source).split(separator: "\n", omittingEmptySubsequences: false)
        return parseBlocks(lines: lines, todoKeywords: scanTodoKeywords(lines))
    }

    /// The keywords `parse` classifies headings with: the file's `#+TODO:`
    /// declarations, or the defaults.
    nonisolated func todoKeywords(in source: String) -> OrgTodoKeywords {
        scanTodoKeywords(Self.normalizedLineEndings(source).split(separator: "\n", omittingEmptySubsequences: false))
    }

    /// Org applies `#+TODO:` to the whole file wherever the line sits, so the
    /// declarations are read before any heading is classified. A declaration
    /// quoted in a source block is code, not a setting.
    private func scanTodoKeywords(_ lines: [Substring]) -> OrgTodoKeywords {
        var declarations: [OrgBlock] = []
        var inSource = false
        for line in lines {
            guard let first = line.utf8.first, first == 0x23 || first == 0x20 || first == 0x09 else { continue }
            let trimmed = Self.stripped(line)
            guard trimmed.hasPrefix("#+") else { continue }
            let upper = trimmed.uppercased()
            if inSource {
                if upper.hasPrefix("#+END_SRC") { inSource = false }
                continue
            }
            if upper.hasPrefix("#+BEGIN_SRC") {
                inSource = true
                continue
            }
            guard let keyword = parseKeyword(line),
                  case let .keyword(key, _) = keyword,
                  OrgTodoKeywords.isDeclarationKey(key) else { continue }
            declarations.append(keyword)
        }
        return declarations.isEmpty ? .standard : OrgTodoKeywords.declared(in: declarations)
    }

    private func parseBlocks(lines: [Substring], todoKeywords: OrgTodoKeywords) -> [LocatedOrgBlock] {
        var cursor = 0
        var blocks: [LocatedOrgBlock] = []
        func add(_ block: OrgBlock) {
            blocks.append(LocatedOrgBlock(block: block, line: cursor + 1))
        }
        // Line a planning line may sit on: directly under a heading.
        var planningCursor = -1

        while cursor < lines.count {
            let line = lines[cursor]

            if cursor == planningCursor, let planning = parsePlanning(line) {
                add(planning)
                cursor += 1
                continue
            }

            // Fast-path: classify by first non-whitespace character.
            // Avoids running every parser on every line.
            guard let firstNonWS = line.first(where: { !$0.isWhitespace }) else {
                // Blank line — skip
                cursor += 1
                continue
            }

            switch firstNonWS {
            case "*":
                // Possible heading (stars + space)
                if let heading = parseHeading(line, todoKeywords: todoKeywords) {
                    add(heading)
                    cursor += 1
                    planningCursor = cursor
                    continue
                }
                // Not a heading — fall through to paragraph

            case "#":
                // # → comment, #+ → keyword or block delimiter
                let trimmed = Self.stripped(line)
                if trimmed.hasPrefix("#+") {
                    // Block delimiters take priority
                    if trimmed.uppercased().hasPrefix("#+BEGIN_SRC") {
                        let (block, newCursor) = parseCodeBlock(lines: lines, startCursor: cursor)
                        add(block)
                        cursor = newCursor
                        continue
                    }
                    if trimmed.uppercased().hasPrefix("#+BEGIN_QUOTE") {
                        let (block, newCursor) = parseQuoteBlock(
                            lines: lines, startCursor: cursor, todoKeywords: todoKeywords
                        )
                        add(block)
                        cursor = newCursor
                        continue
                    }
                    if let keyword = parseKeyword(line) {
                        add(keyword)
                        cursor += 1
                        continue
                    }
                }
                if let comment = parseComment(line) {
                    add(comment)
                    cursor += 1
                    continue
                }
                // Not a comment or keyword — fall through to paragraph

            case "-":
                // - followed by space → list item; 5+ dashes → horizontal rule
                if isListItemStart(line) {
                    let (list, newCursor) = parseList(lines: lines, startCursor: cursor)
                    add(list)
                    cursor = newCursor
                    continue
                }
                if isHorizontalRule(line) {
                    add(.horizontalRule)
                    cursor += 1
                    continue
                }
                // Not list or rule — fall through to paragraph

            case "+":
                if isListItemStart(line) {
                    let (list, newCursor) = parseList(lines: lines, startCursor: cursor)
                    add(list)
                    cursor = newCursor
                    continue
                }

            case "|":
                let (block, newCursor) = parseTable(lines: lines, startCursor: cursor)
                add(block)
                cursor = newCursor
                continue

            case ":":
                let trimmed = Self.stripped(line)
                if isDrawerStart(trimmed[...]), drawerHasEnd(lines: lines, startCursor: cursor) {
                    let (block, newCursor) = parseDrawer(lines: lines, startCursor: cursor)
                    add(block)
                    cursor = newCursor
                    continue
                }

            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if isListItemStart(line) {
                    let (list, newCursor) = parseList(lines: lines, startCursor: cursor)
                    add(list)
                    cursor = newCursor
                    continue
                }

            default:
                break // Fall through to paragraph
            }

            // Default: paragraph — collect contiguous non-blank, non-structural lines
            let (paragraph, newCursor) = parseParagraph(lines: lines, startCursor: cursor)
            add(paragraph)
            // Safety: always advance at least one line to prevent infinite loops.
            cursor = max(newCursor, cursor + 1)
        }

        return blocks
    }

    // MARK: - Heading

    /// Parse a heading line: `* TODO [#A] Title :tag1:tag2:`
    ///
    /// A headline starts in column 0: `  * item` is indented text (often a
    /// nested list item), never a heading, whatever follows the star.
    private func parseHeading(_ line: Substring, todoKeywords: OrgTodoKeywords) -> OrgBlock? {
        guard line.first == "*" else { return nil }
        // Trim only leading whitespace — trailing space matters for `* ` detection
        let leadTrimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        // Must start with stars followed by a space
        guard let firstNonStar = leadTrimmed.firstIndex(where: { $0 != "*" }) else { return nil }
        let level = leadTrimmed.distance(from: leadTrimmed.startIndex, to: firstNonStar)
        guard level > 0 else { return nil }
        guard firstNonStar < leadTrimmed.endIndex, leadTrimmed[firstNonStar] == " " else { return nil }

        var rest = String(leadTrimmed[leadTrimmed.index(after: firstNonStar)...])

        // Parse optional TODO keyword
        var keyword: String?
        for kw in todoKeywords.all where rest.hasPrefix(kw) {
            let afterKw = rest.index(rest.startIndex, offsetBy: kw.count)
            if afterKw == rest.endIndex || rest[afterKw] == " " {
                keyword = kw
                rest = afterKw < rest.endIndex ? String(rest[rest.index(after: afterKw)...]) : ""
                break
            }
        }

        // Parse optional priority: [#A]
        var priority: Character?
        if rest.hasPrefix("[#") {
            if let closeBracket = rest.firstIndex(of: "]") {
                let prioStart = rest.index(rest.startIndex, offsetBy: 2)
                if rest.distance(from: prioStart, to: closeBracket) == 1 {
                    priority = rest[prioStart]
                    let afterPrio = rest.index(after: closeBracket)
                    rest = afterPrio < rest.endIndex ? String(rest[afterPrio...]) : ""
                    if rest.hasPrefix(" ") {
                        rest = String(rest.dropFirst())
                    }
                }
            }
        }

        // Parse optional tags at end: `:tag1:tag2:`
        var tags: [String] = []
        let trimmedRest = Self.stripped(rest)
        if let tagResult = extractTagSection(String(trimmedRest)) {
            tags = tagResult.tags
            rest = tagResult.remainder
        }

        let titleText = Self.stripped(rest)
        let titleInlines = titleText.isEmpty ? [] : parseInlines(String(titleText))

        return .heading(level: level, keyword: keyword, priority: priority, title: titleInlines, tags: tags)
    }

    /// Extract tag section from end of heading line.
    /// Tags format: `:tag1:tag2:` — colon-separated, at end of line, preceded by whitespace.
    private func extractTagSection(_ text: String) -> (tags: [String], remainder: String)? {
        guard text.hasSuffix(":") else { return nil }

        // Walk backwards to find the start of the tag section.
        // Tag section is `:word:word:...:`  preceded by whitespace or at line start.
        var idx = text.index(before: text.endIndex)
        var colonCount = 0

        while idx >= text.startIndex {
            let ch = text[idx]
            if ch == ":" {
                colonCount += 1
                // Check if this is the start of the tag section
                if idx == text.startIndex || (idx > text.startIndex && text[text.index(before: idx)].isWhitespace) {
                    if colonCount >= 2 {
                        let tagString = String(text[idx...])
                        let remainder = String(Self.stripped(text[..<idx]))
                        let tagParts = tagString.split(separator: ":").map(String.init)
                        guard !tagParts.isEmpty else { return nil }
                        return (tags: tagParts, remainder: remainder)
                    }
                }
            } else if !ch.isLetter && !ch.isNumber && ch != "_" && ch != "@" {
                // Invalid character for tag — no tag section here
                return nil
            }
            if idx == text.startIndex { break }
            idx = text.index(before: idx)
        }

        return nil
    }

    // MARK: - Planning

    /// Parse `SCHEDULED: <ts> DEADLINE: <ts> CLOSED: [ts]`. Every token on the
    /// line must belong to a planning entry; anything else leaves the line to
    /// the paragraph parser, so prose that happens to start with `CLOSED:` is
    /// never swallowed.
    private func parsePlanning(_ line: Substring) -> OrgBlock? {
        guard let first = line.first(where: { $0 != " " && $0 != "\t" }),
              first == "S" || first == "D" || first == "C" else { return nil }
        guard let entries = OrgPlanningLine.parse(String(Self.stripped(line))) else { return nil }
        return .planning(entries.map { OrgPlanningEntry(kind: $0.kind, timestamp: $0.timestamp) })
    }

    // MARK: - Comment

    private func parseComment(_ line: Substring) -> OrgBlock? {
        let trimmed = Self.stripped(line)
        if trimmed == "#" {
            return .comment("")
        }
        if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("#+") {
            return .comment(String(trimmed.dropFirst(2)))
        }
        return nil
    }

    // MARK: - Horizontal Rule

    private func isHorizontalRule(_ line: Substring) -> Bool {
        let trimmed = Self.stripped(line)
        return trimmed.count >= 5 && trimmed.allSatisfy({ $0 == "-" })
    }

    // MARK: - Keyword

    /// Parse `#+KEY: value` lines.
    /// Block delimiters (BEGIN_SRC, BEGIN_QUOTE) are handled before this is called
    /// in the main parse loop. Remaining `#+` lines (including stray END_ lines)
    /// are treated as keywords.
    private func parseKeyword(_ line: Substring) -> OrgBlock? {
        let trimmed = Self.stripped(line)
        guard trimmed.hasPrefix("#+") else { return nil }

        let afterHash = String(trimmed.dropFirst(2))

        if let colonIdx = afterHash.firstIndex(of: ":") {
            let key = String(afterHash[..<colonIdx]).uppercased()
            let afterColon = afterHash.index(after: colonIdx)
            let value = afterColon < afterHash.endIndex
                ? String(Self.stripped(afterHash[afterColon...][...]))
                : ""
            return .keyword(key: key, value: value)
        }

        // No colon — e.g. `#+SOMETHING`
        let key = afterHash.uppercased()
        return .keyword(key: key, value: "")
    }

    // MARK: - Code Block

    /// Parse `#+begin_src lang ... #+end_src`
    private func parseCodeBlock(lines: [Substring], startCursor: Int) -> (OrgBlock, Int) {
        let startLine = Self.stripped(lines[startCursor])

        // Extract language from `#+begin_src lang`
        var language: String?
        let prefixLen = "#+begin_src".count
        if startLine.count > prefixLen {
            let afterPrefix = Self.stripped(startLine.dropFirst(prefixLen))
            if !afterPrefix.isEmpty {
                language = afterPrefix.split(separator: " ").first.map(String.init)
            }
        }

        var codeLines: [Substring] = []
        var cursor = startCursor + 1

        while cursor < lines.count {
            let trimmedUpper = Self.stripped(lines[cursor]).uppercased()
            if trimmedUpper == "#+END_SRC" {
                cursor += 1
                break
            }
            codeLines.append(lines[cursor])
            cursor += 1
        }

        let code = codeLines.joined(separator: "\n")
        return (.codeBlock(language: language, code: code), cursor)
    }

    // MARK: - Quote Block

    /// Parse `#+begin_quote ... #+end_quote`
    private func parseQuoteBlock(
        lines: [Substring],
        startCursor: Int,
        todoKeywords: OrgTodoKeywords
    ) -> (OrgBlock, Int) {
        var innerLines: [Substring] = []
        var cursor = startCursor + 1

        while cursor < lines.count {
            let trimmedUpper = Self.stripped(lines[cursor]).uppercased()
            if trimmedUpper == "#+END_QUOTE" {
                cursor += 1
                break
            }
            innerLines.append(lines[cursor])
            cursor += 1
        }

        let innerBlocks = parseBlocks(lines: innerLines, todoKeywords: todoKeywords).map(\.block)

        return (.quote(innerBlocks), cursor)
    }

    // MARK: - List

    private func isListItemStart(_ line: Substring) -> Bool {
        let trimmed = Self.stripped(line)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("+ ") { return true }
        return matchesOrderedBullet(trimmed[...])
    }

    private func matchesOrderedBullet(_ line: Substring) -> Bool {
        var idx = line.startIndex
        guard idx < line.endIndex, line[idx].isNumber else { return false }
        while idx < line.endIndex, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex, line[idx] == "." || line[idx] == ")" else { return false }
        let nextIdx = line.index(after: idx)
        guard nextIdx < line.endIndex, line[nextIdx] == " " else { return false }
        return true
    }

    private func parseListItemLine(_ line: Substring) -> (bullet: String, isOrdered: Bool, content: String)? {
        let trimmed = Self.stripped(line)

        if trimmed.hasPrefix("- ") {
            return (bullet: "-", isOrdered: false, content: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("+ ") {
            return (bullet: "+", isOrdered: false, content: String(trimmed.dropFirst(2)))
        }

        // Ordered: `1. text` or `1) text`
        var idx = trimmed.startIndex
        guard idx < trimmed.endIndex, trimmed[idx].isNumber else { return nil }
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            idx = trimmed.index(after: idx)
        }
        guard idx < trimmed.endIndex, trimmed[idx] == "." || trimmed[idx] == ")" else { return nil }
        let bulletEnd = trimmed.index(after: idx)
        let bullet = String(trimmed[..<bulletEnd])
        guard bulletEnd < trimmed.endIndex, trimmed[bulletEnd] == " " else { return nil }
        let content = String(trimmed[trimmed.index(after: bulletEnd)...])
        return (bullet: bullet, isOrdered: true, content: content)
    }

    /// Columns of leading space/tab before a line's first character (a tab
    /// counts as one column): how a list tells a nested item or continuation
    /// line from a sibling at the same level.
    private func indentOf(_ line: Substring) -> Int {
        var columns = 0
        for ch in line {
            guard ch == " " || ch == "\t" else { break }
            columns += 1
        }
        return columns
    }

    /// `term :: description`: Org's description-list separator, `::`
    /// surrounded by whitespace. nil when `content` has no such separator.
    private func splitDescriptionTerm(_ content: String) -> (term: String, description: String)? {
        guard let range = content.range(of: " :: ") else { return nil }
        return (String(content[content.startIndex..<range.lowerBound]), String(content[range.upperBound...]))
    }

    /// Parses a plain list at exactly `indent` columns (the first item's own
    /// indent, when the caller does not already know it). The list's kind
    /// comes from its first item, never its last: a bullet of the other kind
    /// at this same indent starts a new, sibling list instead of silently
    /// flipping this one's kind. A line indented deeper than the item that
    /// precedes it is that item's own region — a nested list, a continuation
    /// line, or both — parsed by `parseListRegion`.
    private func parseList(lines: [Substring], startCursor: Int, indent: Int? = nil) -> (OrgBlock, Int) {
        let indent = indent ?? indentOf(lines[startCursor])
        var items: [OrgListItem] = []
        var cursor = startCursor
        var isOrdered: Bool?

        while cursor < lines.count {
            let line = lines[cursor]
            if line.allSatisfy(\.isWhitespace) { break }
            guard indentOf(line) == indent else { break }
            guard let parsed = parseListItemLine(line) else { break }
            if let isOrdered, parsed.isOrdered != isOrdered { break }
            if isOrdered == nil { isOrdered = parsed.isOrdered }

            var content = parsed.content
            var checkbox: OrgCheckbox?
            if content.hasPrefix("[X] ") || content.hasPrefix("[x] ") {
                checkbox = .checked
                content = String(content.dropFirst(4))
            } else if content.hasPrefix("[ ] ") {
                checkbox = .unchecked
                content = String(content.dropFirst(4))
            } else if content.hasPrefix("[-] ") {
                checkbox = .partial
                content = String(content.dropFirst(4))
            }

            var term: [OrgInline]?
            if let split = splitDescriptionTerm(content) {
                term = parseInlines(split.term)
                content = split.description
            }

            let inlines = parseInlines(content)
            let itemLine = cursor + 1
            cursor += 1

            var children: [OrgBlock] = []
            if cursor < lines.count, !lines[cursor].allSatisfy(\.isWhitespace) {
                let childIndent = indentOf(lines[cursor])
                if childIndent > indent {
                    let (kids, newCursor) = parseListRegion(lines: lines, startCursor: cursor, indent: childIndent)
                    children = kids
                    cursor = newCursor
                }
            }

            items.append(OrgListItem(
                bullet: parsed.bullet, checkbox: checkbox, content: inlines,
                term: term, children: children, line: itemLine
            ))
        }

        let kind: OrgListKind = (isOrdered ?? false) ? .ordered : .unordered
        return (.list(kind: kind, items: items), cursor)
    }

    /// The indented region under one list item: at exactly `indent`, a line
    /// that starts a bullet becomes a nested list, and a run of lines that do
    /// not becomes one continuation paragraph, in whatever order the source
    /// has them. Stops at a blank line, a dedent below `indent`, or a line
    /// indented past `indent` (its own further-nested item is that block's
    /// problem, not this region's).
    private func parseListRegion(lines: [Substring], startCursor: Int, indent: Int) -> ([OrgBlock], Int) {
        var blocks: [OrgBlock] = []
        var cursor = startCursor
        while cursor < lines.count {
            let line = lines[cursor]
            if line.allSatisfy(\.isWhitespace) { break }
            guard indentOf(line) == indent else { break }
            if isListItemStart(line) {
                let (list, newCursor) = parseList(lines: lines, startCursor: cursor, indent: indent)
                blocks.append(list)
                cursor = newCursor
            } else {
                let (paragraph, newCursor) = parseContinuationParagraph(lines: lines, startCursor: cursor, indent: indent)
                blocks.append(paragraph)
                cursor = newCursor
            }
        }
        return (blocks, cursor)
    }

    /// A continuation line (or contiguous run of them) at exactly `indent`,
    /// joined with spaces the same way an ordinary paragraph joins its lines.
    private func parseContinuationParagraph(lines: [Substring], startCursor: Int, indent: Int) -> (OrgBlock, Int) {
        var cursor = startCursor
        while cursor < lines.count {
            let line = lines[cursor]
            if line.allSatisfy(\.isWhitespace) { break }
            guard indentOf(line) == indent, !isListItemStart(line) else { break }
            cursor += 1
        }
        let text = lines[startCursor..<cursor].map { String(Self.stripped($0)) }.joined(separator: " ")
        return (.paragraph(parseInlines(text)), cursor)
    }

    // MARK: - Paragraph

    private func parseParagraph(lines: [Substring], startCursor: Int) -> (OrgBlock, Int) {
        var cursor = startCursor
        let firstLine = cursor

        while cursor < lines.count {
            let line = lines[cursor]
            if line.allSatisfy(\.isWhitespace) { break }
            if isStructuralLine(line, lines: lines, cursor: cursor) { break }
            cursor += 1
        }

        // Single-line fast path: skip join allocation. Each line is stripped of
        // its own leading indentation first: `org-adapt-indentation` aligns
        // body text under a heading with spaces that carry no meaning here, and
        // left in place, 4 or more of them would read as a Markdown indented
        // code block once this paragraph is serialized.
        let text: String
        if cursor - firstLine == 1 {
            text = String(Self.stripped(lines[firstLine]))
        } else {
            text = lines[firstLine..<cursor].map { String(Self.stripped($0)) }.joined(separator: " ")
        }
        let inlines = parseInlines(text)
        return (.paragraph(inlines), cursor)
    }

    /// Check if a line starts a new structural element.
    /// Uses first non-whitespace byte (UTF-8) for fast classification — avoids
    /// trimmingCharacters allocation for the vast majority of paragraph lines.
    /// `lines`/`cursor` let a `:NAME:` line check for its own `:END:` before it
    /// is allowed to end the paragraph as a drawer would.
    private func isStructuralLine(_ line: Substring, lines: [Substring], cursor: Int) -> Bool {
        // Fast scan for first non-whitespace byte
        var firstByte: UInt8 = 0
        for b in line.utf8 {
            if b != 0x20 && b != 0x09 { // space, tab
                firstByte = b
                break
            }
        }
        guard firstByte != 0 else { return false }

        // Most paragraph lines start with a letter — fast reject
        if firstByte >= 0x61 && firstByte <= 0x7A { return false } // a-z
        if firstByte >= 0x41 && firstByte <= 0x5A { return false } // A-Z

        switch firstByte {
        case 0x2A: // *
            // A heading starts in column 0 — an indented star line never ends
            // a paragraph as a heading would.
            guard line.first == "*" else { return false }
            let trimmed = Self.stripped(line)
            guard let firstNonStar = trimmed.firstIndex(where: { $0 != "*" }) else { return false }
            return firstNonStar > trimmed.startIndex
                && firstNonStar < trimmed.endIndex
                && trimmed[firstNonStar] == " "
        case 0x23: // #
            let trimmed = Self.stripped(line)
            return trimmed == "#" || trimmed.hasPrefix("# ") || trimmed.hasPrefix("#+")
        case 0x2D: // -
            return isListItemStart(line) || isHorizontalRule(line)
        case 0x2B: // +
            return isListItemStart(line)
        case 0x7C: // |
            return true
        case 0x3A: // :
            return isDrawerStart(Self.stripped(line)) && drawerHasEnd(lines: lines, startCursor: cursor)
        case 0x30...0x39: // 0-9
            return isListItemStart(line)
        default:
            return false
        }
    }

    // MARK: - Table Parsing

    /// Parse an org table (lines starting with `|`).
    ///
    /// Org table format:
    /// ```
    /// | Header 1 | Header 2 |
    /// |----------+----------|
    /// | Cell 1   | Cell 2   |
    /// ```
    /// The separator row (`|---+---|`) divides headers from data rows.
    /// If no separator, the first row is treated as the header.
    private func parseTable(lines: [Substring], startCursor: Int) -> (OrgBlock, Int) {
        var cursor = startCursor
        var dataRows: [[String]] = []
        var separatorIndex: Int? = nil

        while cursor < lines.count {
            let trimmed = Self.stripped(lines[cursor])
            guard trimmed.hasPrefix("|") else { break }

            // Check if separator row: contains only |, -, +, spaces
            let isSeparator = trimmed.dropFirst().allSatisfy { $0 == "-" || $0 == "+" || $0 == "|" || $0 == " " }

            if isSeparator && trimmed.contains("-") {
                separatorIndex = dataRows.count
            } else {
                // Parse cells: split by `|`, trim, drop empty first/last
                let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                    .map { String(Self.stripped($0)) }
                // Drop leading/trailing empty strings from the split
                let cleaned: [String]
                if cells.first?.isEmpty == true && cells.last?.isEmpty == true {
                    cleaned = Array(cells.dropFirst().dropLast())
                } else if cells.first?.isEmpty == true {
                    cleaned = Array(cells.dropFirst())
                } else {
                    cleaned = cells
                }
                dataRows.append(cleaned)
            }
            cursor += 1
        }

        guard !dataRows.isEmpty else {
            return (.paragraph([.text("")]), cursor)
        }

        // First row (or row before separator) is the header
        let headerRowIndex = separatorIndex != nil ? 0 : 0
        let headerCells = dataRows[headerRowIndex].map { [OrgInline.text($0)] }

        let bodyStartIndex = separatorIndex != nil ? 1 : 1
        let bodyRows = dataRows[bodyStartIndex...].map { row in
            row.map { [OrgInline.text($0)] }
        }

        return (.table(headers: headerCells, rows: Array(bodyRows)), cursor)
    }

    // MARK: - Drawer Parsing

    /// Check if a line starts a drawer: `:NAME:` where NAME is word chars/hyphens.
    private func isDrawerStart(_ trimmed: Substring) -> Bool {
        guard trimmed.hasPrefix(":"),
              trimmed.hasSuffix(":"),
              trimmed.count > 2 else { return false }
        let name = trimmed.dropFirst().dropLast()
        // Must not be empty and must contain only word chars and hyphens.
        guard !name.isEmpty else { return false }
        // Exclude `:END:` — that's a closer, not a start.
        if name.uppercased() == "END" { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Whether some later line is `:END:`: an unterminated drawer is not a
    /// drawer at all, as Org treats it, so the rest of the file is never
    /// swallowed looking for a close that never comes.
    private func drawerHasEnd(lines: [Substring], startCursor: Int) -> Bool {
        var cursor = startCursor + 1
        while cursor < lines.count {
            if Self.stripped(lines[cursor]).uppercased() == ":END:" { return true }
            cursor += 1
        }
        return false
    }

    /// Parse a drawer from `:NAME:` to `:END:`. Callers check `drawerHasEnd`
    /// first.
    private func parseDrawer(lines: [Substring], startCursor: Int) -> (OrgBlock, Int) {
        let headerTrimmed = Self.stripped(lines[startCursor])
        let name = String(headerTrimmed.dropFirst().dropLast())
        var cursor = startCursor + 1
        var properties: [OrgDrawerProperty] = []

        while cursor < lines.count {
            let line = Self.stripped(lines[cursor])

            // End of drawer
            if line.uppercased() == ":END:" {
                cursor += 1
                break
            }

            // Property line: `:KEY: VALUE`
            if line.hasPrefix(":"), let colonIdx = line.dropFirst().firstIndex(of: ":") {
                let key = String(line[line.index(after: line.startIndex) ..< colonIdx])
                let valueStart = line.index(after: colonIdx)
                let value = String(Self.stripped(line[valueStart...][...]))
                if !key.isEmpty {
                    properties.append(OrgDrawerProperty(key: key, value: value))
                }
            }
            cursor += 1
        }

        return (.drawer(name: name, properties: properties), cursor)
    }

    // MARK: - Inline Parsing

    // MARK: - Inline Parsing

    /// Parse inline markup in text.
    ///
    /// Uses String.Index scanning to avoid O(n) Array(text) Character copy.
    /// Plain-text fast path bypasses scanning entirely for lines without markers.
    func parseInlines(_ text: String) -> [OrgInline] {
        guard !text.isEmpty else { return [] }

        // Fast path: if no markup markers or link brackets exist, return plain text.
        let hasMarkup = text.utf8.contains(where: { b in
            b == 0x2A || b == 0x2F || b == 0x5F || b == 0x3D ||  // * / _ =
            b == 0x7E || b == 0x2B || b == 0x5B || b == 0x3C       // ~ + [ <
        })
        if !hasMarkup {
            return [.text(text)]
        }

        // String.Index scanning — no Array(text) copy needed.
        var result: [OrgInline] = []
        var pos = text.startIndex
        var textStart = pos

        @inline(__always)
        func flushText() {
            if textStart < pos {
                result.append(.text(String(text[textStart..<pos])))
            }
        }

        while pos < text.endIndex {
            let ch = text[pos]

            // Try link: [[url][desc]] or [[url]]
            if ch == "[" {
                let next = text.index(after: pos)
                if next < text.endIndex, text[next] == "[" {
                    if let (link, newPos) = parseLinkAt(text: text, pos: pos) {
                        flushText()
                        result.append(link)
                        pos = newPos
                        textStart = pos
                        continue
                    }
                }
            }

            // Try timestamp (`<2026-11-11 Wed>`, `[2026-11-06 Fri 14:00]`) and
            // statistics cookie (`[2/5]`, `[40%]`).
            if ch == "[" || ch == "<" {
                if let (timestamp, newPos) = parseTimestampAt(text: text, pos: pos) {
                    flushText()
                    result.append(.timestamp(timestamp))
                    pos = newPos
                    textStart = pos
                    continue
                }
                if ch == "[", let (cookie, newPos) = parseCookieAt(text: text, pos: pos) {
                    flushText()
                    result.append(cookie)
                    pos = newPos
                    textStart = pos
                    continue
                }
            }

            // Try markup markers
            if isMarkupMarker(ch), canOpenMarkup(text: text, at: pos) {
                if ch == "=" || ch == "~" {
                    if let (inline, newPos) = parseVerbatimAt(text: text, pos: pos, marker: ch) {
                        flushText()
                        result.append(inline)
                        pos = newPos
                        textStart = pos
                        continue
                    }
                } else {
                    if let (inline, newPos) = parseMarkupAt(text: text, pos: pos, marker: ch) {
                        flushText()
                        result.append(inline)
                        pos = newPos
                        textStart = pos
                        continue
                    }
                }
            }

            pos = text.index(after: pos)
        }

        if textStart < text.endIndex {
            result.append(.text(String(text[textStart..<text.endIndex])))
        }

        return result
    }

    @inline(__always)
    private func isMarkupMarker(_ c: Character) -> Bool {
        switch c {
        case "*", "/", "_", "=", "~", "+": return true
        default: return false
        }
    }

    private func canOpenMarkup(text: String, at pos: String.Index) -> Bool {
        let next = text.index(after: pos)
        guard next < text.endIndex, !text[next].isWhitespace else { return false }
        if pos == text.startIndex { return true }
        let prev = text[text.index(before: pos)]
        return prev.isWhitespace || isPre(prev)
    }

    private func canCloseMarkup(text: String, at pos: String.Index) -> Bool {
        guard pos > text.startIndex, !text[text.index(before: pos)].isWhitespace else { return false }
        let next = text.index(after: pos)
        if next >= text.endIndex { return true }
        return text[next].isWhitespace || isPost(text[next])
    }

    @inline(__always)
    private func isPre(_ c: Character) -> Bool {
        switch c {
        case "(", "-", "'", "\"", "{": return true
        default: return false
        }
    }

    @inline(__always)
    private func isPost(_ c: Character) -> Bool {
        switch c {
        case "-", ".", ",", ":", ";", "!", "?", "'", "\"", ")", "}", "]", "\\": return true
        default: return false
        }
    }

    private func parseVerbatimAt(text: String, pos: String.Index, marker: Character) -> (OrgInline, String.Index)? {
        var end = text.index(after: pos)
        while end < text.endIndex {
            if text[end] == marker, canCloseMarkup(text: text, at: end) {
                let inner = text.index(after: pos)
                guard inner < end else { return nil }
                let content = String(text[inner..<end])
                let inline: OrgInline = marker == "=" ? .verbatim(content) : .code(content)
                return (inline, text.index(after: end))
            }
            end = text.index(after: end)
        }
        return nil
    }

    private func parseMarkupAt(text: String, pos: String.Index, marker: Character) -> (OrgInline, String.Index)? {
        var end = text.index(after: pos)
        while end < text.endIndex {
            if text[end] == marker, canCloseMarkup(text: text, at: end) {
                let inner = text.index(after: pos)
                guard inner < end else { return nil }
                let innerText = String(text[inner..<end])
                let innerInlines = parseInlines(innerText)
                let inline: OrgInline
                switch marker {
                case "*": inline = .bold(innerInlines)
                case "/": inline = .italic(innerInlines)
                case "_": inline = .underline(innerInlines)
                case "+": inline = .strikethrough(innerInlines)
                default: return nil
                }
                return (inline, text.index(after: end))
            }
            end = text.index(after: end)
        }
        return nil
    }

    private func parseTimestampAt(text: String, pos: String.Index) -> (OrgTimestamp, String.Index)? {
        OrgPlanningLine.timestamp(in: text, at: pos)
    }

    /// `[2/5]`, `[/]`, `[40%]`, `[%]`.
    private func parseCookieAt(text: String, pos: String.Index) -> (OrgInline, String.Index)? {
        var idx = text.index(after: pos)
        func skipDigits() {
            while idx < text.endIndex, text[idx].isASCII, text[idx].isNumber {
                idx = text.index(after: idx)
            }
        }
        skipDigits()
        guard idx < text.endIndex else { return nil }
        if text[idx] == "/" {
            idx = text.index(after: idx)
            skipDigits()
        } else if text[idx] == "%" {
            idx = text.index(after: idx)
        } else {
            return nil
        }
        guard idx < text.endIndex, text[idx] == "]" else { return nil }
        let content = String(text[text.index(after: pos)..<idx])
        return (.progress(content), text.index(after: idx))
    }

    private func parseLinkAt(text: String, pos: String.Index) -> (OrgInline, String.Index)? {
        let next = text.index(after: pos)
        guard next < text.endIndex, text[pos] == "[", text[next] == "[" else { return nil }

        var idx = text.index(after: next)
        let urlStart = idx

        while idx < text.endIndex {
            if text[idx] == "]" { break }
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex, text[idx] == "]" else { return nil }
        let url = String(text[urlStart..<idx])
        idx = text.index(after: idx)

        if idx < text.endIndex, text[idx] == "[" {
            idx = text.index(after: idx)
            let descStart = idx
            while idx < text.endIndex {
                if text[idx] == "]" { break }
                idx = text.index(after: idx)
            }
            guard idx < text.endIndex, text[idx] == "]" else { return nil }
            let descText = String(text[descStart..<idx])
            idx = text.index(after: idx)
            guard idx < text.endIndex, text[idx] == "]" else { return nil }
            idx = text.index(after: idx)

            let descInlines = parseInlines(descText)
            return (.link(url: url, description: descInlines), idx)
        }

        guard idx < text.endIndex, text[idx] == "]" else { return nil }
        idx = text.index(after: idx)

        return (.link(url: url, description: nil), idx)
    }
}
