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

    nonisolated func parse(_ source: String) -> [OrgBlock] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var cursor = 0
        var blocks: [OrgBlock] = []

        while cursor < lines.count {
            let line = lines[cursor]

            // Blank line — skip
            if line.allSatisfy(\.isWhitespace) {
                cursor += 1
                continue
            }

            // Heading: starts with one or more `*` followed by a space
            if let heading = parseHeading(line) {
                blocks.append(heading)
                cursor += 1
                continue
            }

            // Horizontal rule: 5+ dashes, nothing else (allow trailing whitespace)
            if isHorizontalRule(line) {
                blocks.append(.horizontalRule)
                cursor += 1
                continue
            }

            // Comment: `# ` at start of line (or just `#` alone)
            if let comment = parseComment(line) {
                blocks.append(comment)
                cursor += 1
                continue
            }

            // Block delimiters and keywords: `#+...`
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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

            // List item
            if isListItemStart(line) {
                let (list, newCursor) = parseList(lines: lines, startCursor: cursor)
                blocks.append(list)
                cursor = newCursor
                continue
            }

            // Default: paragraph — collect contiguous non-blank, non-structural lines
            let (paragraph, newCursor) = parseParagraph(lines: lines, startCursor: cursor)
            blocks.append(paragraph)
            // Safety: always advance at least one line to prevent infinite loops.
            // This fires when a line is structural but no parser claimed it
            // (e.g. stray #+end_src outside a block).
            cursor = max(newCursor, cursor + 1)
        }

        return blocks
    }

    // MARK: - Heading

    /// Parse a heading line: `* TODO [#A] Title :tag1:tag2:`
    private func parseHeading(_ line: String) -> OrgBlock? {
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
        for kw in todoKeywords {
            if rest.hasPrefix(kw) {
                let afterKw = rest.index(rest.startIndex, offsetBy: kw.count)
                if afterKw == rest.endIndex || rest[afterKw] == " " {
                    keyword = kw
                    rest = afterKw < rest.endIndex ? String(rest[rest.index(after: afterKw)...]) : ""
                    break
                }
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
        let trimmedRest = rest.trimmingCharacters(in: .whitespaces)
        if let tagResult = extractTagSection(trimmedRest) {
            tags = tagResult.tags
            rest = tagResult.remainder
        }

        let titleText = rest.trimmingCharacters(in: .whitespaces)
        let titleInlines = titleText.isEmpty ? [] : parseInlines(titleText)

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
                        let remainder = String(text[..<idx]).trimmingCharacters(in: .whitespaces)
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

    private func parseComment(_ line: String) -> OrgBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "#" {
            return .comment("")
        }
        if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("#+") {
            return .comment(String(trimmed.dropFirst(2)))
        }
        return nil
    }

    // MARK: - Horizontal Rule

    private func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 5 && trimmed.allSatisfy({ $0 == "-" })
    }

    // MARK: - Keyword

    /// Parse `#+KEY: value` lines.
    /// Block delimiters (BEGIN_SRC, BEGIN_QUOTE) are handled before this is called
    /// in the main parse loop. Remaining `#+` lines (including stray END_ lines)
    /// are treated as keywords.
    private func parseKeyword(_ line: String) -> OrgBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#+") else { return nil }

        let afterHash = String(trimmed.dropFirst(2))

        if let colonIdx = afterHash.firstIndex(of: ":") {
            let key = String(afterHash[..<colonIdx]).uppercased()
            let afterColon = afterHash.index(after: colonIdx)
            let value = afterColon < afterHash.endIndex
                ? String(afterHash[afterColon...]).trimmingCharacters(in: .whitespaces)
                : ""
            return .keyword(key: key, value: value)
        }

        // No colon — e.g. `#+SOMETHING`
        let key = afterHash.uppercased()
        return .keyword(key: key, value: "")
    }

    // MARK: - Code Block

    /// Parse `#+begin_src lang ... #+end_src`
    private func parseCodeBlock(lines: [String], startCursor: Int) -> (OrgBlock, Int) {
        let startLine = lines[startCursor].trimmingCharacters(in: .whitespaces)

        // Extract language from `#+begin_src lang`
        var language: String?
        let prefixLen = "#+begin_src".count
        if startLine.count > prefixLen {
            let afterPrefix = String(startLine.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
            if !afterPrefix.isEmpty {
                language = afterPrefix.split(separator: " ").first.map(String.init)
            }
        }

        var codeLines: [String] = []
        var cursor = startCursor + 1

        while cursor < lines.count {
            let trimmedUpper = lines[cursor].trimmingCharacters(in: .whitespaces).uppercased()
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
    private func parseQuoteBlock(lines: [String], startCursor: Int) -> (OrgBlock, Int) {
        var innerLines: [String] = []
        var cursor = startCursor + 1

        while cursor < lines.count {
            let trimmedUpper = lines[cursor].trimmingCharacters(in: .whitespaces).uppercased()
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

    private func isListItemStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("+ ") { return true }
        return matchesOrderedBullet(trimmed)
    }

    private func matchesOrderedBullet(_ line: String) -> Bool {
        var idx = line.startIndex
        guard idx < line.endIndex, line[idx].isNumber else { return false }
        while idx < line.endIndex, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex, (line[idx] == "." || line[idx] == ")") else { return false }
        let nextIdx = line.index(after: idx)
        guard nextIdx < line.endIndex, line[nextIdx] == " " else { return false }
        return true
    }

    private func parseListItemLine(_ line: String) -> (bullet: String, isOrdered: Bool, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

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
        guard idx < trimmed.endIndex, (trimmed[idx] == "." || trimmed[idx] == ")") else { return nil }
        let bulletEnd = trimmed.index(after: idx)
        let bullet = String(trimmed[..<bulletEnd])
        guard bulletEnd < trimmed.endIndex, trimmed[bulletEnd] == " " else { return nil }
        let content = String(trimmed[trimmed.index(after: bulletEnd)...])
        return (bullet: bullet, isOrdered: true, content: content)
    }

    private func parseList(lines: [String], startCursor: Int) -> (OrgBlock, Int) {
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

    private func parseParagraph(lines: [String], startCursor: Int) -> (OrgBlock, Int) {
        var paraLines: [String] = []
        var cursor = startCursor

        while cursor < lines.count {
            let line = lines[cursor]
            if line.allSatisfy(\.isWhitespace) { break }
            if isStructuralLine(line) { break }
            paraLines.append(line)
            cursor += 1
        }

        let text = paraLines.joined(separator: " ")
        let inlines = parseInlines(text)
        return (.paragraph(inlines), cursor)
    }

    /// Check if a line starts a new structural element.
    private func isStructuralLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }

        // Heading: stars followed by space
        if let firstNonStar = trimmed.firstIndex(where: { $0 != "*" }),
           firstNonStar > trimmed.startIndex,
           firstNonStar < trimmed.endIndex,
           trimmed[firstNonStar] == " " {
            return true
        }

        if trimmed.hasPrefix("#+") { return true }
        if trimmed == "#" || (trimmed.hasPrefix("# ") && !trimmed.hasPrefix("#+")) { return true }
        if isHorizontalRule(trimmed) { return true }
        if isListItemStart(trimmed) { return true }

        return false
    }

    // MARK: - Inline Parsing

    /// Parse inline markup in text.
    ///
    /// Org mode markup rules (spec §4.2):
    /// - `*bold*`, `/italic/`, `_underline_`, `=verbatim=`, `~code~`, `+strikethrough+`
    /// - Verbatim and code contain raw strings (no nesting)
    /// - Other markers can nest: `*/bold italic/*`
    /// - Pre: preceded by whitespace, line start, or punctuation
    /// - Post: followed by whitespace, line end, or punctuation
    func parseInlines(_ text: String) -> [OrgInline] {
        guard !text.isEmpty else { return [] }

        var result: [OrgInline] = []
        let chars = Array(text)
        var pos = 0
        var textBuf: [Character] = []

        func flushText() {
            if !textBuf.isEmpty {
                result.append(.text(String(textBuf)))
                textBuf.removeAll()
            }
        }

        while pos < chars.count {
            // Try link: [[url][desc]] or [[url]]
            if chars[pos] == "[" && pos + 1 < chars.count && chars[pos + 1] == "[" {
                if let (link, newPos) = parseLinkAt(chars: chars, pos: pos) {
                    flushText()
                    result.append(link)
                    pos = newPos
                    continue
                }
            }

            // Try markup markers
            let marker = chars[pos]
            if isMarkupMarker(marker) && canOpenMarkup(chars: chars, pos: pos) {
                if marker == "=" || marker == "~" {
                    if let (inline, newPos) = parseVerbatimAt(chars: chars, pos: pos, marker: marker) {
                        flushText()
                        result.append(inline)
                        pos = newPos
                        continue
                    }
                } else {
                    if let (inline, newPos) = parseMarkupAt(chars: chars, pos: pos, marker: marker) {
                        flushText()
                        result.append(inline)
                        pos = newPos
                        continue
                    }
                }
            }

            textBuf.append(chars[pos])
            pos += 1
        }

        flushText()
        return result
    }

    private func isMarkupMarker(_ c: Character) -> Bool {
        c == "*" || c == "/" || c == "_" || c == "=" || c == "~" || c == "+"
    }

    /// Can this position open a markup span?
    private func canOpenMarkup(chars: [Character], pos: Int) -> Bool {
        guard pos + 1 < chars.count, !chars[pos + 1].isWhitespace else { return false }
        if pos == 0 { return true }
        let prev = chars[pos - 1]
        return prev.isWhitespace || isPre(prev)
    }

    /// Can this position close a markup span?
    private func canCloseMarkup(chars: [Character], pos: Int) -> Bool {
        guard pos > 0, !chars[pos - 1].isWhitespace else { return false }
        if pos + 1 >= chars.count { return true }
        let next = chars[pos + 1]
        return next.isWhitespace || isPost(next)
    }

    /// Characters that can precede an opening marker (besides whitespace/start).
    private func isPre(_ c: Character) -> Bool {
        "(-'\"{".contains(c)
    }

    /// Characters that can follow a closing marker (besides whitespace/end).
    private func isPost(_ c: Character) -> Bool {
        "-.,:;!?'\")}]\\".contains(c)
    }

    /// Parse verbatim (`=text=`) or code (`~text~`). No nesting.
    private func parseVerbatimAt(chars: [Character], pos: Int, marker: Character) -> (OrgInline, Int)? {
        var end = pos + 1
        while end < chars.count {
            if chars[end] == marker && canCloseMarkup(chars: chars, pos: end) {
                let content = String(chars[(pos + 1)..<end])
                guard !content.isEmpty else { return nil }
                let inline: OrgInline = marker == "=" ? .verbatim(content) : .code(content)
                return (inline, end + 1)
            }
            end += 1
        }
        return nil
    }

    /// Parse nestable markup (`*bold*`, `/italic/`, `_underline_`, `+strikethrough+`).
    private func parseMarkupAt(chars: [Character], pos: Int, marker: Character) -> (OrgInline, Int)? {
        var end = pos + 1

        while end < chars.count {
            if chars[end] == marker && canCloseMarkup(chars: chars, pos: end) {
                let innerText = String(chars[(pos + 1)..<end])
                guard !innerText.isEmpty else { return nil }
                let innerInlines = parseInlines(innerText)
                let inline: OrgInline
                switch marker {
                case "*": inline = .bold(innerInlines)
                case "/": inline = .italic(innerInlines)
                case "_": inline = .underline(innerInlines)
                case "+": inline = .strikethrough(innerInlines)
                default: return nil
                }
                return (inline, end + 1)
            }
            end += 1
        }
        return nil
    }

    /// Parse a link: `[[url][description]]` or `[[url]]`
    private func parseLinkAt(chars: [Character], pos: Int) -> (OrgInline, Int)? {
        guard pos + 1 < chars.count, chars[pos] == "[", chars[pos + 1] == "[" else { return nil }

        var idx = pos + 2
        var url = ""

        // Read URL until `]`
        while idx < chars.count {
            if chars[idx] == "]" { break }
            url.append(chars[idx])
            idx += 1
        }
        guard idx < chars.count, chars[idx] == "]" else { return nil }
        idx += 1

        // Check for description: `[description]`
        if idx < chars.count && chars[idx] == "[" {
            idx += 1
            var descText = ""
            while idx < chars.count {
                if chars[idx] == "]" { break }
                descText.append(chars[idx])
                idx += 1
            }
            guard idx < chars.count, chars[idx] == "]" else { return nil }
            idx += 1
            guard idx < chars.count, chars[idx] == "]" else { return nil }
            idx += 1

            let descInlines = parseInlines(descText)
            return (.link(url: url, description: descInlines), idx)
        }

        // No description — closing `]`
        guard idx < chars.count, chars[idx] == "]" else { return nil }
        idx += 1

        return (.link(url: url, description: nil), idx)
    }
}
