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
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var cursor = 0
        var blocks: [OrgBlock] = []

        while cursor < lines.count {
            let line = lines[cursor]

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
                if let heading = parseHeading(line) {
                    blocks.append(heading)
                    cursor += 1
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
                        blocks.append(block)
                        cursor = newCursor
                        continue
                    }
                    if trimmed.uppercased().hasPrefix("#+BEGIN_QUOTE") {
                        let (block, newCursor) = parseQuoteBlock(lines: lines, startCursor: cursor)
                        blocks.append(block)
                        cursor = newCursor
                        continue
                    }
                    if let keyword = parseKeyword(line) {
                        blocks.append(keyword)
                        cursor += 1
                        continue
                    }
                }
                if let comment = parseComment(line) {
                    blocks.append(comment)
                    cursor += 1
                    continue
                }
                // Not a comment or keyword — fall through to paragraph

            case "-":
                // - followed by space → list item; 5+ dashes → horizontal rule
                if isListItemStart(line) {
                    let (list, newCursor) = parseList(lines: lines, startCursor: cursor)
                    blocks.append(list)
                    cursor = newCursor
                    continue
                }
                if isHorizontalRule(line) {
                    blocks.append(.horizontalRule)
                    cursor += 1
                    continue
                }
                // Not list or rule — fall through to paragraph

            case "+":
                if isListItemStart(line) {
                    let (list, newCursor) = parseList(lines: lines, startCursor: cursor)
                    blocks.append(list)
                    cursor = newCursor
                    continue
                }

            case "|":
                let (block, newCursor) = parseTable(lines: lines, startCursor: cursor)
                blocks.append(block)
                cursor = newCursor
                continue

            case ":":
                let trimmed = Self.stripped(line)
                if isDrawerStart(trimmed[...]) {
                    let (block, newCursor) = parseDrawer(lines: lines, startCursor: cursor)
                    blocks.append(block)
                    cursor = newCursor
                    continue
                }

            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if isListItemStart(line) {
                    let (list, newCursor) = parseList(lines: lines, startCursor: cursor)
                    blocks.append(list)
                    cursor = newCursor
                    continue
                }

            default:
                break // Fall through to paragraph
            }

            // Default: paragraph — collect contiguous non-blank, non-structural lines
            let (paragraph, newCursor) = parseParagraph(lines: lines, startCursor: cursor)
            blocks.append(paragraph)
            // Safety: always advance at least one line to prevent infinite loops.
            cursor = max(newCursor, cursor + 1)
        }

        return blocks
    }

    // MARK: - Heading

    /// Parse a heading line: `* TODO [#A] Title :tag1:tag2:`
    private func parseHeading(_ line: Substring) -> OrgBlock? {
        // Trim only leading whitespace — trailing space matters for `* ` detection
        let leadTrimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        // Must start with stars followed by a space
        guard let firstNonStar = leadTrimmed.firstIndex(where: { $0 != "*" }) else { return nil }
        let level = leadTrimmed.distance(from: leadTrimmed.startIndex, to: firstNonStar)
        guard level > 0 else { return nil }
        guard firstNonStar < leadTrimmed.endIndex, leadTrimmed[firstNonStar] == " " else { return nil }

        var rest = String(leadTrimmed[leadTrimmed.index(after: firstNonStar)...])

        // Parse optional TODO keyword
        let todoKeywords = ["TODO", "DONE", "NEXT", "WAITING", "CANCELLED", "HOLD"]
        var keyword: String?
        for kw in todoKeywords where rest.hasPrefix(kw) {
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
    private func parseQuoteBlock(lines: [Substring], startCursor: Int) -> (OrgBlock, Int) {
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

        let innerSource = innerLines.joined(separator: "\n")
        let innerBlocks = parse(innerSource)

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

    private func parseList(lines: [Substring], startCursor: Int) -> (OrgBlock, Int) {
        var items: [OrgListItem] = []
        var cursor = startCursor
        var isOrdered = false

        while cursor < lines.count {
            let line = lines[cursor]
            if line.allSatisfy(\.isWhitespace) { break }
            guard let parsed = parseListItemLine(line) else { break }

            isOrdered = parsed.isOrdered

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

            let inlines = parseInlines(content)
            items.append(OrgListItem(bullet: parsed.bullet, checkbox: checkbox, content: inlines))
            cursor += 1
        }

        let kind: OrgListKind = isOrdered ? .ordered : .unordered
        return (.list(kind: kind, items: items), cursor)
    }

    // MARK: - Paragraph

    private func parseParagraph(lines: [Substring], startCursor: Int) -> (OrgBlock, Int) {
        var cursor = startCursor
        let firstLine = cursor

        while cursor < lines.count {
            let line = lines[cursor]
            if line.allSatisfy(\.isWhitespace) { break }
            if isStructuralLine(line) { break }
            cursor += 1
        }

        // Single-line fast path: skip join allocation
        let text: String
        if cursor - firstLine == 1 {
            text = String(lines[firstLine])
        } else {
            text = lines[firstLine..<cursor].joined(separator: " ")
        }
        let inlines = parseInlines(text)
        return (.paragraph(inlines), cursor)
    }

    /// Check if a line starts a new structural element.
    /// Uses first non-whitespace byte (UTF-8) for fast classification — avoids
    /// trimmingCharacters allocation for the vast majority of paragraph lines.
    private func isStructuralLine(_ line: Substring) -> Bool {
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
            return isDrawerStart(Self.stripped(line))
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

    /// Parse a drawer from `:NAME:` to `:END:`.
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
            b == 0x7E || b == 0x2B || b == 0x5B                    // ~ + [
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
